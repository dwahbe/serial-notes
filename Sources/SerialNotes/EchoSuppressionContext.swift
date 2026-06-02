import Foundation

/// One streaming-ASR utterance, ordered by timestamp then by source side so
/// renderings interleave deterministically when mic + system finalize at the
/// same time.
struct TranscriptEntry: Comparable, Sendable {
    let source: AudioSide
    let speaker: String
    let text: String
    let timestamp: TimeInterval

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp == rhs.timestamp {
            return lhs.source.sortOrder < rhs.source.sortOrder
        }
        return lhs.timestamp < rhs.timestamp
    }
}

/// Tracks recent system-audio utterances and tells us when an incoming mic
/// utterance is likely an echo of remote speech (e.g., the mic picked up a
/// participant talking through the laptop speakers).
///
/// Two callers — the streaming pipeline (`TranscriptionService`) keeps one
/// long-lived context across the session, and the final high-accuracy render
/// pass builds a fresh one. Both apply the same n-gram containment heuristic
/// from `TranscriptTextProcessing.isLikelyEcho`.
struct EchoSuppressionContext {
    private var systemEntries: [TranscriptEntry] = []
    private var systemWords: [String] = []
    private var systemBigrams: Set<String> = []
    private var systemTrigrams: Set<String> = []

    mutating func reset() {
        systemEntries = []
        systemWords = []
        systemBigrams = []
        systemTrigrams = []
    }

    mutating func recordSystemEntry(
        _ entry: TranscriptEntry,
        lookbackSeconds: TimeInterval,
        maxEntries: Int
    ) {
        systemEntries.append(entry)
        pruneEntries(relativeTo: entry.timestamp, lookbackSeconds: lookbackSeconds)
        if systemEntries.count > maxEntries {
            systemEntries.removeFirst(systemEntries.count - maxEntries)
        }
        rebuildCache()
    }

    mutating func shouldSuppressMicEntry(
        _ entry: TranscriptEntry,
        lookbackSeconds: TimeInterval
    ) -> Bool {
        if pruneEntries(relativeTo: entry.timestamp, lookbackSeconds: lookbackSeconds) {
            rebuildCache()
        }
        return TranscriptTextProcessing.isLikelyEcho(
            micText: entry.text,
            systemWords: systemWords,
            systemBigrams: systemBigrams,
            systemTrigrams: systemTrigrams
        )
    }

    @discardableResult
    private mutating func pruneEntries(
        relativeTo timestamp: TimeInterval,
        lookbackSeconds: TimeInterval
    ) -> Bool {
        let cutoff = timestamp - lookbackSeconds
        let originalCount = systemEntries.count
        systemEntries.removeAll { $0.timestamp < cutoff }
        return systemEntries.count != originalCount
    }

    private mutating func rebuildCache() {
        systemWords = systemEntries.flatMap { TranscriptTextProcessing.normalizedWords($0.text) }
        systemBigrams = TranscriptTextProcessing.shingles(from: systemWords, size: 2)
        systemTrigrams = TranscriptTextProcessing.shingles(from: systemWords, size: 3)
    }
}

/// Dominance-aware cross-channel echo removal for a fully-collected transcript.
///
/// `EchoSuppressionContext` works incrementally and one-directional (suppress mic
/// entries that echo system). It can't catch two real failure modes seen with
/// laptop-speaker calls:
///   1. The remote party bleeds from the speakers into the mic. The mic diarizer
///      splits that bleed into its own speaker ("Voice N"), so the echo is never
///      flagged as a mic-vs-system overlap on the *primary* mic speaker.
///   2. The local user loops back through the meeting app into the system capture,
///      minting a phantom system speaker ("Person N") — and system entries are
///      never suppressed at all.
///
/// Both cases share a structure: the echo lands on a *non-dominant* speaker of one
/// channel while the real utterance lives on the *opposite* channel. Given the full
/// entry list (the final high-accuracy render pass has it), we can use the diarizer's
/// own separation: keep the dominant speaker on each channel unconditionally, and drop
/// a non-dominant speaker's entry when its words are largely contained in nearby
/// opposite-channel speech. A genuine second in-room speaker — non-dominant but not
/// duplicating the other channel — is preserved.
enum CrossChannelEchoFilter {
    static func filterEchoes(
        _ entries: [TranscriptEntry],
        windowSeconds: TimeInterval,
        containmentThreshold: Double,
        minWords: Int
    ) -> [TranscriptEntry] {
        guard entries.count > 1 else { return entries }

        // Normalize every entry's text exactly once; the dominance tally and the
        // per-entry containment checks below both reuse this. Re-splitting inside the
        // filter (especially for each candidate's opposite-channel `nearbyWords`) made
        // this O(n²) over the session's text on long meetings.
        let words = entries.map { TranscriptTextProcessing.normalizedWords($0.text) }
        let dominant = dominantSpeakers(in: entries, words: words)

        // Index entries by channel so each candidate only scans the opposite side.
        var indicesBySource: [AudioSide: [Int]] = [:]
        for index in entries.indices {
            indicesBySource[entries[index].source, default: []].append(index)
        }

        return entries.indices.filter { index in
            let entry = entries[index]
            // The dominant (real) speaker on a channel is always kept — this is the
            // guarantee that genuine speech can never be dropped as "echo".
            guard dominant[entry.source] != entry.speaker else { return true }

            let entryWords = words[index]
            guard entryWords.count >= minWords else { return true }

            let opposite: AudioSide = entry.source == .mic ? .system : .mic
            let nearbyWords = (indicesBySource[opposite] ?? [])
                .filter { abs(entries[$0].timestamp - entry.timestamp) <= windowSeconds }
                .flatMap { words[$0] }
            guard !nearbyWords.isEmpty else { return true }

            let size = entryWords.count >= 6 ? 3 : 2
            let entryShingles = TranscriptTextProcessing.shingles(from: entryWords, size: size)
            let oppositeShingles = TranscriptTextProcessing.shingles(from: nearbyWords, size: size)
            guard !entryShingles.isEmpty, !oppositeShingles.isEmpty else { return true }

            let matches = entryShingles.filter { oppositeShingles.contains($0) }.count
            let containment = Double(matches) / Double(entryShingles.count)
            return containment < containmentThreshold
        }.map { entries[$0] }
    }

    /// Collapse the mic channel to a single "You" speaker, matching the Me/Them model
    /// that passive recorders (Granola, Notion) ship. During a remote call any extra
    /// mic speaker is acoustic bleed, not a second person, so labelling it "Voice N" is
    /// misleading. Run this AFTER `filterEchoes` — collapsing first would make echo
    /// lines part of the dominant "You" speaker, which the filter never drops.
    ///
    /// `enrolledMicNames` (voices the user explicitly enrolled on the mic side) are
    /// preserved, and `collapseToYou` is false for pure in-person recordings (no system
    /// audio) so genuinely co-located speakers keep distinct labels.
    static func normalizeMicLabels(
        _ entries: [TranscriptEntry],
        collapseToYou: Bool,
        enrolledMicNames: Set<String>
    ) -> [TranscriptEntry] {
        guard collapseToYou else { return entries }
        return entries.map { entry in
            guard entry.source == .mic, !enrolledMicNames.contains(entry.speaker) else { return entry }
            return TranscriptEntry(
                source: entry.source,
                speaker: "You",
                text: entry.text,
                timestamp: entry.timestamp
            )
        }
    }

    /// The speaker with the most spoken words on each channel — treated as the real
    /// participant for that side. Echo speakers are, by definition, the quieter ones.
    /// `words[i]` is the pre-normalized word list for `entries[i]`, computed once by
    /// the caller and shared with the containment pass.
    private static func dominantSpeakers(
        in entries: [TranscriptEntry],
        words: [[String]]
    ) -> [AudioSide: String] {
        var wordsBySpeaker: [AudioSide: [String: Int]] = [:]
        for index in entries.indices {
            let entry = entries[index]
            wordsBySpeaker[entry.source, default: [:]][entry.speaker, default: 0] += words[index].count
        }
        return wordsBySpeaker.compactMapValues { counts in
            counts.max { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key > rhs.key }
                return lhs.value < rhs.value
            }?.key
        }
    }
}
