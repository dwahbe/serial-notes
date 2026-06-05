import AVFoundation
import Foundation

// MARK: - Sidecar model

/// Persistent, text-only metadata describing the unrecognized system-side speakers
/// detected in a recording, written as `speakers.json` in the session folder. The
/// privacy-sensitive *audio* clips are kept separately in the app-support pending
/// area (see `SpeakerClipExtractor.pendingDirectory`) so this can live in the user's
/// storage folder without violating the "only transcript.md is kept" promise.
struct SpeakerSidecar: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var sessionStartedAt: Date
    var speakers: [DetectedSpeaker]
}

enum SpeakerState: String, Codable, Sendable {
    case pending
    case named
    case skipped
}

/// One unrecognized speaker the diarizer found on the system (remote) side.
struct DetectedSpeaker: Codable, Equatable, Sendable, Identifiable {
    /// The rendered "Person N" label as it appears in transcript.md. Read back from
    /// the actor's `speakerLabels` map — never reconstructed from the diarizer index,
    /// since "Person N" numbering is assignment-order, not the index.
    var label: String
    /// The diarizer slot index — used only to name the clip file uniquely per session.
    var speakerIndex: Int
    var totalSpeechSeconds: Double
    /// The sample rate of the source `system.wav` the clip was cut from.
    var sampleRate: Double
    /// The time ranges (seconds from session start) used to build the clip.
    var segments: [Segment]
    /// A short transcript excerpt so the user can tell who "Person N" is.
    var sampleText: String
    /// Filename of the extracted clip inside the session's pending-speakers directory.
    var clipFile: String
    var state: SpeakerState
    /// Set once the user names this speaker.
    var resolvedName: String?

    var id: Int { speakerIndex }
}

struct Segment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

// MARK: - Extraction + transcript helpers

/// Pure helpers + WAV I/O for turning diarized system-side speakers into short
/// enrollment clips, plus the transcript-relabel and name-sanitization logic used
/// when a speaker is named. Deliberately free of UI / actor state so it is unit
/// testable and can be called from the `TranscriptionService` actor and the
/// `@MainActor MeetingSessionsStore` alike.
enum SpeakerClipExtractor {
    static let sidecarFileName = "speakers.json"

    /// Minimum total speech a speaker must have before we bother extracting a clip.
    static let minSpeechSeconds: Double = 3
    /// Drop diarized segments shorter than this — too little signal for enrollment.
    static let minSegmentSeconds: Double = 0.6
    /// Cap the total extracted clip length; more than this adds no diarizer value.
    static let maxClipSeconds: Double = 12
    /// Merge same-speaker segments separated by less than this gap.
    static let mergeGapSeconds: Double = 0.3

    // MARK: Paths

    private static var appSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("SerialNotes", isDirectory: true)
            .appendingPathComponent("pending-speakers", isDirectory: true)
    }

    /// Per-session directory holding the extracted clips, keyed by the session folder
    /// name. Lives in app support, never in the user's storage folder.
    static func pendingDirectory(forSessionFolder folder: String) -> URL {
        appSupportRoot.appendingPathComponent(folder, isDirectory: true)
    }

    static func clipURL(sessionFolder folder: String, clipFile: String) -> URL {
        pendingDirectory(forSessionFolder: folder).appendingPathComponent(clipFile)
    }

    static func sidecarURL(inSessionDirectory directory: URL) -> URL {
        directory.appendingPathComponent(sidecarFileName)
    }

    static func clipFileName(forSpeakerIndex index: Int) -> String {
        "speaker-\(index).wav"
    }

    // MARK: Sidecar read / write

    static func loadSidecar(inSessionDirectory directory: URL) -> SpeakerSidecar? {
        let url = sidecarURL(inSessionDirectory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpeakerSidecar.self, from: data)
    }

    static func writeSidecar(_ sidecar: SpeakerSidecar, inSessionDirectory directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: sidecarURL(inSessionDirectory: directory), options: .atomic)
    }

    /// Reap the whole pending-clip directory for a session (called when no pending
    /// speakers remain, or when the user dismisses a session).
    static func reapPendingClips(forSessionFolder folder: String) {
        try? FileManager.default.removeItem(at: pendingDirectory(forSessionFolder: folder))
    }

    /// Delete pending-clip directories whose contents are older than `maxAge`.
    /// Bounds growth from sessions the user never acts on. Best-effort.
    static func sweepStalePendingClips(olderThan maxAge: TimeInterval = 30 * 24 * 60 * 60) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: appSupportRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: Clip selection (pure)

    /// Choose the audio frame ranges to cut for one speaker: merge adjacent segments,
    /// drop ones shorter than `minSeconds`, walk chronologically, and cap the total at
    /// `maxSeconds`. Converts seconds→frames with the source file's own sample rate.
    static func clipFrames(
        forSegments segments: [Segment],
        sampleRate: Double,
        minSeconds: Double = minSegmentSeconds,
        maxSeconds: Double = maxClipSeconds
    ) -> [(start: Int, end: Int)] {
        guard sampleRate > 0 else { return [] }

        let merged = mergedSegments(segments)
        var frames: [(start: Int, end: Int)] = []
        var accumulated = 0.0

        for seg in merged where seg.duration >= minSeconds {
            if accumulated >= maxSeconds { break }
            let remaining = maxSeconds - accumulated
            let usedEnd = seg.duration <= remaining ? seg.end : seg.start + remaining
            let startFrame = Int((seg.start * sampleRate).rounded())
            let endFrame = Int((usedEnd * sampleRate).rounded())
            guard endFrame > startFrame else { continue }
            frames.append((start: startFrame, end: endFrame))
            accumulated += usedEnd - seg.start
        }
        return frames
    }

    /// Merge overlapping / near-adjacent segments after sorting chronologically.
    static func mergedSegments(_ segments: [Segment]) -> [Segment] {
        let sorted = segments
            .map { Segment(start: max(0, $0.start), end: max(max(0, $0.start), $0.end)) }
            .sorted { $0.start < $1.start }

        var merged: [Segment] = []
        for seg in sorted {
            if var last = merged.last, seg.start <= last.end + mergeGapSeconds {
                last.end = max(last.end, seg.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    // MARK: WAV I/O

    /// The sample rate of a WAV, or nil if it can't be opened. Used so clip-frame math
    /// runs against the file's real rate (system.wav is not guaranteed 48 kHz).
    static func sampleRate(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.processingFormat.sampleRate
    }

    /// Cut the given frame ranges from `source` and write them, concatenated, to
    /// `destination` as a mono float32 WAV. Seeks per range (never loads the whole
    /// multi-hundred-MB file). Creates the destination's parent directory.
    static func writeClip(from source: URL, frames: [(start: Int, end: Int)], to destination: URL) throws {
        guard !frames.isEmpty else { return }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let totalFrames = input.length

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)

        let chunkCapacity: AVAudioFrameCount = 16_384
        for frame in frames.sorted(by: { $0.start < $1.start }) {
            let start = AVAudioFramePosition(max(0, frame.start))
            let end = AVAudioFramePosition(min(Int(totalFrames), frame.end))
            guard end > start else { continue }
            input.framePosition = start

            var remaining = AVAudioFrameCount(end - start)
            while remaining > 0 {
                let toRead = min(remaining, chunkCapacity)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else { break }
                try input.read(into: buffer, frameCount: toRead)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= buffer.frameLength
            }
        }
    }

    // MARK: Name sanitization

    /// Normalize a user-entered speaker name before it is written into Markdown or
    /// stored as a profile: single line, control characters and Markdown metacharacters
    /// stripped (the latter would corrupt transcript headers / the entry grammar),
    /// whitespace collapsed. Returns nil when nothing usable remains.
    static func sanitizedName(_ raw: String) -> String? {
        // Normalize every whitespace character (incl. tabs / newlines) to a plain space
        // first, so they survive the control-character strip below as word separators.
        let spaced = String(raw.map { $0.isWhitespace ? " " : $0 })
        let scalars = spaced.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        // Strip characters that would break the `**Name** (HH:MM:SS):` header grammar
        // or render as Markdown.
        let forbidden: Set<Character> = ["*", "_", "`", "[", "]", "(", ")", "#", "<", ">", "|"]
        let cleaned = String(String.UnicodeScalarView(scalars)).filter { !forbidden.contains($0) }
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: Transcript parsing (shared grammar: TranscriptFormatter.parseEntryHeader)

    /// One parsed speaker-entry: its label, start timestamp, and a representative text
    /// (the inline body, or the following non-blank line for block-form entries).
    struct ParsedEntry: Equatable, Sendable {
        var label: String
        var timestamp: Double
        var text: String
    }

    /// Parse a finalized transcript into its speaker entries in a single pass. Block-form
    /// headers (`**Label** (ts):` with the body on the next line) get that next line as
    /// their text. Non-header lines (summary, action items, headings) are ignored.
    static func parseEntries(_ transcript: String) -> [ParsedEntry] {
        let lines = transcript.components(separatedBy: "\n")
        var entries: [ParsedEntry] = []
        var i = 0
        while i < lines.count {
            guard let header = TranscriptFormatter.parseEntryHeader(lines[i]) else { i += 1; continue }
            var text = header.inlineBody
            if text.isEmpty {
                // Block-form: the body is the next non-blank line that isn't itself a header.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, TranscriptFormatter.parseEntryHeader(lines[j]) == nil {
                    text = lines[j].trimmingCharacters(in: .whitespaces)
                }
            }
            entries.append(ParsedEntry(label: header.label, timestamp: header.timestamp, text: text))
            i += 1
        }
        return entries
    }

    /// True if `transcript` contains a speaker-entry header for `label`. Used to gate
    /// extraction so we never offer a speaker whose lines were all dropped as echo.
    static func transcriptContainsSpeaker(_ transcript: String, label: String) -> Bool {
        parseEntries(transcript).contains { $0.label == label }
    }

    /// The start timestamps (seconds) of every surviving entry for `label`.
    static func entryTimestamps(for label: String, in transcript: String) -> [Double] {
        parseEntries(transcript).filter { $0.label == label }.map(\.timestamp)
    }

    /// Relabel a named speaker everywhere it appears in a finalized transcript:
    /// the `**<oldLabel>** (ts):` speaker-entry headers (exact, leading-token swap) **and**
    /// the Summary / Action-items region above the first speaker entry, where the label
    /// shows up as plain prose ("Person 1 raised the budget question") or a bold
    /// action-item owner (`- [ ] **Person 1** — …`). The prose pass is whole-word so
    /// "Person 1" never clobbers "Person 10"/"Person 12", and is scoped to the pre-entry
    /// region so a quote in the body that literally says the label is left intact.
    /// Idempotent: a no-op once `oldLabel` no longer appears.
    static func relabelSpeaker(in transcript: String, from oldLabel: String, to newName: String) -> String {
        let oldPrefix = "**\(oldLabel)** ("
        let newPrefix = "**\(newName)** ("
        let lines = transcript.components(separatedBy: "\n")
        var reachedBody = false
        let rewritten = lines.map { line -> String in
            // A genuine speaker-entry header marks the start of the transcript body; once
            // we're in the body we only ever swap headers, never spoken prose.
            if TranscriptFormatter.parseEntryHeader(line)?.label != nil {
                reachedBody = true
                guard TranscriptFormatter.parseEntryHeader(line)?.label == oldLabel,
                      line.hasPrefix(oldPrefix) else { return line }
                return newPrefix + line.dropFirst(oldPrefix.count)
            }
            // Header + Summary + Action-items region: replace whole-word label references
            // (covers both summary bullets and bold `**Person N**` action-item owners).
            guard !reachedBody else { return line }
            return replacingWholeWord(oldLabel, with: newName, in: line)
        }
        return rewritten.joined(separator: "\n")
    }

    /// Replace whole-word occurrences of `word` with `replacement` in a single line.
    /// Word boundaries keep "Person 1" from matching inside "Person 10"; the bold `**`
    /// around an action-item owner are non-word characters, so `**Person 1**` still
    /// matches. Both operands are escaped so a name with regex/template metacharacters
    /// (e.g. `$`) is treated literally.
    static func replacingWholeWord(_ word: String, with replacement: String, in line: String) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..., in: line),
            withTemplate: template
        )
    }

    /// A short, human-readable excerpt of what `label` said — the longest entry text,
    /// truncated. Handles block-form entries. Returns "" if nothing is found.
    static func sampleText(for label: String, in transcript: String, maxLength: Int = 140) -> String {
        let best = parseEntries(transcript)
            .filter { $0.label == label }
            .map(\.text)
            .max(by: { $0.count < $1.count }) ?? ""
        return truncated(best, to: maxLength)
    }

    static func truncated(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return text.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Echo-aware segment selection

    /// Restrict diarizer segments to those overlapping a surviving transcript entry's
    /// timestamp (within `tolerance`). This keeps the extracted clip to audio the echo
    /// filter *kept* — so a phantom system speaker (the local user's echo) whose lines
    /// were mostly dropped doesn't contribute its echoed audio to an enrollment clip.
    static func segmentsCovering(_ segments: [Segment], timestamps: [Double], tolerance: Double = 1.5) -> [Segment] {
        guard !timestamps.isEmpty else { return [] }
        return segments.filter { segment in
            timestamps.contains { $0 >= segment.start - tolerance && $0 <= segment.end + tolerance }
        }
    }
}
