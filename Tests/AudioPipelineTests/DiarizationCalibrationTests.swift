import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

/// A labeled calibration set. Each `solo` entry is one recording of ONE known voice
/// (system.wav path); `multi` entries are known-count multi-speaker recordings.
struct CalibManifest: Codable {
    struct Solo: Codable { let path: String; let speaker: String; var condition: String? }
    struct Multi: Codable { let path: String; var knownCount: Int?; var condition: String? }
    var solo: [Solo]
    var multi: [Multi]?
}

/// Manual calibration probes — NOT CI tests. All gated behind SERIAL_DIARIZATION_CALIB=1.
/// `--filter` matches the METHOD name (e.g. `calibrateRecurringHost`), not the display title.
@Suite("Diarization calibration (manual)")
struct DiarizationCalibrationTests {
    /// Agglomeratively merge clusters whose centroids exceed `threshold` cosine —
    /// collapses one speaker the diarizer over-split into fragments back into one.
    /// Duration-weighted centroid, re-normalized.
    static func mergeByCosine(_ clusters: [OfflineSpeakerCluster], threshold: Float)
        -> [(emb: [Float], secs: Double, members: Int)] {
        var g = clusters.map { (emb: $0.embedding, secs: $0.totalSpeechSeconds, members: 1) }
        while g.count > 1 {
            var best: (i: Int, j: Int, sim: Float)?
            for i in 0..<g.count {
                for j in (i + 1)..<g.count {
                    let sim = SpeakerIdentityMatcher.cosineSimilarity(g[i].emb, g[j].emb)
                    if sim > threshold, best == nil || sim > best!.sim { best = (i, j, sim) }
                }
            }
            guard let b = best else { break }
            let wi = Float(g[b.i].secs), wj = Float(g[b.j].secs)
            var m = [Float](repeating: 0, count: g[b.i].emb.count)
            for k in 0..<m.count { m[k] = (g[b.i].emb[k] * wi + g[b.j].emb[k] * wj) / (wi + wj) }
            let norm = max(m.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
            m = m.map { $0 / norm }
            let merged = (emb: m, secs: g[b.i].secs + g[b.j].secs, members: g[b.i].members + g[b.j].members)
            g.remove(at: b.j); g.remove(at: b.i); g.append(merged)
        }
        return g
    }

    // MARK: - Recurring-host calibration (over-segment → merge → cross-clip match)

    @Test("Recurring-host calibration")
    func calibrateRecurringHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SERIAL_DIARIZATION_CALIB"] == "1", let clipsCSV = env["SERIAL_CALIB_CLIPS"] else { return }
        let paths = clipsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let minSecs = Double(env["SERIAL_CALIB_MIN_SECONDS"] ?? "20") ?? 20
        let mergeT = Float(env["SERIAL_CALIB_MERGE"] ?? "0.5") ?? 0.5
        let reportPath = env["SERIAL_CALIB_REPORT"] ?? "/tmp/serial-calib/recurring-report.txt"

        var report = "=== Recurring-host calibration (over-segment min2-max6 → merge≥\(mergeT)) ===\n"
        struct Cl { let clip: Int; let id: String; let secs: Double; let emb: [Float] }
        var all: [Cl] = []
        let config = OfflineDiarizerConfig.default.withSpeakers(min: 2, max: 6)
        for (i, p) in paths.enumerated() {
            let raw = (try? await OfflineSpeakerIdentifier(config: config).clusters(inRecordingAt: URL(fileURLWithPath: p))) ?? []
            let kept = raw.filter { $0.totalSpeechSeconds >= minSecs }
            let merged = Self.mergeByCosine(kept, threshold: mergeT).filter { $0.secs >= minSecs }.sorted { $0.secs > $1.secs }
            report += "\n[clip \(i + 1)] raw=\(raw.count) kept=\(kept.count) → merged=\(merged.count) speakers: "
                + merged.enumerated().map { String(format: "M%d=%.0fs(%dfrag)", $0.offset, $0.element.secs, $0.element.members) }.joined(separator: ", ") + "\n"
            for (k, m) in merged.enumerated() { all.append(Cl(clip: i, id: "c\(i + 1).M\(k)", secs: m.secs, emb: m.emb)) }
        }

        var within: [Float] = [], cross: [(String, String, Float)] = []
        for a in 0..<all.count {
            for b in (a + 1)..<all.count {
                let sim = SpeakerIdentityMatcher.cosineSimilarity(all[a].emb, all[b].emb)
                if all[a].clip == all[b].clip { within.append(sim) } else { cross.append((all[a].id, all[b].id, sim)) }
            }
        }
        cross.sort { $0.2 > $1.2 }
        report += "\n[cross-clip] (host↔host = top = genuine; rest impostor)\n"
        for (x, y, s) in cross { report += String(format: "  %@ ↔ %@ = %.3f\n", x, y, s) }
        report += "\n[within-clip] different people, same episode (impostor): "
            + within.sorted(by: >).map { String(format: "%.2f", $0) }.joined(separator: ", ") + "\n"
        if let genuine = cross.first {
            let imp = cross.dropFirst().map { $0.2 } + within
            let maxImp = imp.max() ?? 0
            report += String(format: "\nGENUINE host↔host: %.3f   MAX IMPOSTOR: %.3f   GAP: %.3f → %@\n",
                             genuine.2, maxImp, genuine.2 - maxImp, genuine.2 - maxImp > 0.2 ? "CLEAN ✓" : "weak")
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: reportPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print(report)
        #expect(!all.isEmpty)
    }

    // MARK: - Identity thresholds from a labeled manifest (solo recordings)

    @Test("Calibrate identity thresholds from a labeled manifest")
    func calibrateThresholds() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SERIAL_DIARIZATION_CALIB"] == "1", let manifestPath = env["SERIAL_CALIB_MANIFEST"] else { return }
        guard let mdata = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let manifest = try? JSONDecoder().decode(CalibManifest.self, from: mdata) else {
            Issue.record("could not read/parse manifest at \(manifestPath)"); return
        }
        let reportPath = env["SERIAL_CALIB_REPORT"] ?? "/tmp/serial-calib/identity-report.txt"
        let id = OfflineSpeakerIdentifier()
        var report = "=== Identity threshold calibration ===\n"

        struct Sample { let speaker: String; let condition: String; let emb: [Float] }
        var samples: [Sample] = []
        for s in manifest.solo {
            guard let emb = (try? await id.enrollmentEmbedding(forClipAt: URL(fileURLWithPath: s.path))) ?? nil else {
                report += "  [warn] no embedding: \(s.path)\n"; continue
            }
            samples.append(Sample(speaker: s.speaker, condition: s.condition ?? "?", emb: emb))
        }
        report += "solo samples: \(samples.count)  speakers: " + Set(samples.map(\.speaker)).sorted().joined(separator: ", ") + "\n"

        var genuine: [Float] = [], impostor: [Float] = []
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let c = SpeakerIdentityMatcher.cosineSimilarity(samples[i].emb, samples[j].emb)
                if samples[i].speaker == samples[j].speaker { genuine.append(c) } else { impostor.append(c) }
            }
        }
        func stats(_ a: [Float]) -> String {
            guard !a.isEmpty else { return "n=0" }
            let s = a.sorted(); return String(format: "n=%d min=%.3f mean=%.3f max=%.3f", a.count, s.first!, a.reduce(0, +) / Float(a.count), s.last!)
        }
        report += "\n[genuine]  \(stats(genuine))\n[impostor] \(stats(impostor))\n"
        func far(_ t: Float) -> Float { impostor.isEmpty ? 0 : Float(impostor.filter { $0 >= t }.count) / Float(impostor.count) }
        func frr(_ t: Float) -> Float { genuine.isEmpty ? 0 : Float(genuine.filter { $0 < t }.count) / Float(genuine.count) }
        report += "\n[sweep] t  FAR  FRR\n"
        for t in stride(from: Float(0.2), through: 0.8, by: 0.05) {
            report += String(format: "  %.2f  %.2f  %.2f\n", t, far(t), frr(t))
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: reportPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print(report)
        #expect(!samples.isEmpty)
    }

    // MARK: - Production speakers() integration check

    @Test("Production speakers integration")
    func productionSpeakers() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SERIAL_DIARIZATION_CALIB"] == "1", let wav = env["SERIAL_CALIB_WAV"] else { return }
        let speakers = try await OfflineSpeakerIdentifier().speakers(inRecordingAt: URL(fileURLWithPath: wav))
        let summary = speakers.map { String(format: "%.0fs", $0.totalSpeechSeconds) }.joined(separator: ", ")
        let line = "production speakers(\(URL(fileURLWithPath: wav).lastPathComponent)): \(speakers.count) → \(summary)"
        try? line.write(toFile: "/tmp/serial-calib/production-report.txt", atomically: true, encoding: .utf8)
        print(line)
        #expect(!speakers.isEmpty)
    }

    // MARK: - End-to-end re-attribution on a real transcript

    @Test("Re-attribute real call integration")
    func reattributeRealCall() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SERIAL_DIARIZATION_CALIB"] == "1",
              let wav = env["SERIAL_CALIB_WAV"],
              let transcriptPath = env["SERIAL_CALIB_TRANSCRIPT"],
              let transcript = try? String(contentsOfFile: transcriptPath, encoding: .utf8)
        else { return }
        let micLabel = env["SERIAL_CALIB_MIC"] ?? "You"

        let before = Dictionary(grouping: SpeakerClipExtractor.parseEntries(transcript), by: \.label)
            .mapValues(\.count)
        let identified = try await OfflineSpeakerIdentifier()
            .identifySpeakers(inRecordingAt: URL(fileURLWithPath: wav), candidates: [])
        let rewritten = SpeakerReattribution.reattribute(
            transcript: transcript, speakers: identified, micLabels: [micLabel])
        let after = Dictionary(grouping: SpeakerClipExtractor.parseEntries(rewritten), by: \.label)
            .mapValues(\.count)

        let report = """
            offline speakers: \(identified.count)
            labels BEFORE: \(before.sorted { $0.key < $1.key })
            labels AFTER:  \(after.sorted { $0.key < $1.key })
            (mic label '\(micLabel)' should be unchanged; system 'Person 1' should fan out)
            """
        try? report.write(toFile: "/tmp/serial-calib/reattribute-report.txt", atomically: true, encoding: .utf8)
        print(report)
        #expect(!identified.isEmpty)
    }
}
