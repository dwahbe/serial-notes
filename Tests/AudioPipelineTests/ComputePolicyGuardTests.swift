import Foundation
import Testing

/// Structural enforcement of the "CoreML inference must never dispatch to
/// the GPU" convention (see ModelComputePolicy / CLAUDE.md): sweeps the
/// Sources and Tests trees for constructions that silently inherit a
/// GPU-capable default configuration. Convention alone already drifted once
/// (bare constructors in the test target) — this makes the next drift a
/// test failure instead of a fault storm.
@Suite("Compute Policy Guard")
struct ComputePolicyGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ComputePolicyGuardTests.swift
        .deletingLastPathComponent()  // AudioPipelineTests
        .deletingLastPathComponent()  // Tests
    private static let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path

    private struct BannedPattern {
        let needle: String
        let reason: String
        /// File names where the pattern is the sanctioned implementation.
        let exemptFileNames: Set<String>
    }

    // Needles are split ("(" appended) so this file's own literals can't
    // trip the sweep in some future refactor that drops the self-exemption.
    private static let banned: [BannedPattern] = [
        .init(
            needle: "StreamingEouAsrManager(" + ")",
            reason: "bare init defaults to MLModelConfiguration() = .all (GPU); use TranscriptionService.makeStreamingAsrManager()",
            exemptFileNames: []
        ),
        .init(
            needle: "LSEENDDiarizer(" + ")",
            reason: "pass computeUnits: .cpuOnly explicitly so the units never track an upstream default",
            exemptFileNames: []
        ),
        .init(
            needle: "OfflineDiarizerModels.load(",
            reason: "upstream hardcodes GPU-capable units (ignores its configuration param); use OfflineDiarizerModelLoader.load()",
            exemptFileNames: []
        ),
        .init(
            needle: "MLModelConfiguration(" + ")",
            reason: "defaults to .all (GPU); route through ModelComputePolicy.configuration()",
            exemptFileNames: ["ModelComputePolicy.swift"]
        ),
    ]

    private static func swiftFiles(under directory: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("No FluidAudio/CoreML load site bypasses ModelComputePolicy")
    func noBannedConstructions() throws {
        var violations: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Tests") {
            guard file.standardizedFileURL.path != Self.selfPath else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            let lines = contents.components(separatedBy: "\n")
            for pattern in Self.banned where !pattern.exemptFileNames.contains(file.lastPathComponent) {
                for (index, line) in lines.enumerated() where line.contains(pattern.needle) {
                    // Comments may name banned APIs while explaining why
                    // they're banned — only executable lines count.
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                    violations.append("\(file.lastPathComponent):\(index + 1) uses \(pattern.needle) — \(pattern.reason)")
                }
            }

            // AsrModels.downloadAndLoad must pass configuration: explicitly
            // (its nil-default is safe today but tracks upstream, not us).
            var searchRange = contents.startIndex..<contents.endIndex
            while let match = contents.range(of: "AsrModels.downloadAndLoad(", range: searchRange) {
                let windowEnd = contents.index(match.upperBound, offsetBy: 120, limitedBy: contents.endIndex) ?? contents.endIndex
                if !contents[match.upperBound..<windowEnd].contains("configuration:") {
                    let lineNumber = contents[..<match.lowerBound].count(where: { $0 == "\n" }) + 1
                    violations.append("\(file.lastPathComponent):\(lineNumber) calls AsrModels.downloadAndLoad without configuration: — pass ModelComputePolicy.configuration()")
                }
                searchRange = match.upperBound..<contents.endIndex
            }
        }
        #expect(violations.isEmpty, "GPU-capable model loads outside ModelComputePolicy:\n\(violations.joined(separator: "\n"))")
    }

    @Test("Guard sweep actually sees the source tree")
    func sweepCoversSources() {
        // If the repo layout changes and the sweep silently scans nothing,
        // the guard above would pass vacuously — pin that it finds the known
        // policy files.
        let names = Set(Self.swiftFiles(under: "Sources").map(\.lastPathComponent))
        #expect(names.contains("ModelComputePolicy.swift"))
        #expect(names.contains("TranscriptionService.swift"))
    }
}
