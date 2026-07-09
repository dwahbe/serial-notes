import Foundation

/// One streaming-ASR utterance, ordered by timestamp then by source side so
/// renderings interleave deterministically when mic + system finalize at the
/// same time.
struct TranscriptEntry: Comparable, Sendable {
    let source: AudioSide
    let speaker: String
    let text: String
    let timestamp: TimeInterval
    /// When the utterance's audio ends. Lets `TranscriptTurnMerger` measure true
    /// silence between consecutive entries instead of start-to-start distance.
    /// Defaults to `timestamp` when the producer has no end timing, which makes
    /// gap measurements overestimate — merging then errs toward keeping blocks
    /// separate. Only the final-pass segmenter supplies exact speech times;
    /// streaming entries stamp `timestamp` at the EOU-window *midpoint*, so
    /// their measured gaps are approximate (roughly half of silence + speech) —
    /// tolerable on the rare paths that render streaming entries, and the
    /// summary-cutoff boundary is enforced separately in `mergedTurns`.
    let end: TimeInterval

    init(
        source: AudioSide,
        speaker: String,
        text: String,
        timestamp: TimeInterval,
        end: TimeInterval? = nil
    ) {
        self.source = source
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.end = max(end ?? timestamp, timestamp)
    }

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
/// Used by the streaming pipeline (`TranscriptionService`), which keeps one
/// long-lived context across the session and applies the n-gram containment
/// heuristic from `TranscriptTextProcessing.isLikelyEcho`. The final
/// high-accuracy render pass instead uses the dominance-aware
/// `CrossChannelEchoFilter` below.
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

    /// Collapse the mic channel to a single primary speaker — the user's preferred
    /// name, or "You" when unset (`primaryName`) — matching the Me/Them model that
    /// passive recorders (Granola, Notion) ship. During a remote call any extra mic
    /// speaker is acoustic bleed, not a second person, so labelling it "Voice N" is
    /// misleading. Run this AFTER `filterEchoes` — collapsing first would relabel
    /// every mic entry (echoes included) to `primaryName`, making that one label the
    /// dominant mic speaker, and `filterEchoes` never drops a channel's dominant speaker.
    ///
    /// `enrolledMicNames` (voices the user explicitly enrolled on the mic side) are
    /// preserved, and `collapseToPrimary` is false for pure in-person recordings (no
    /// system audio) so genuinely co-located speakers keep distinct labels.
    static func normalizeMicLabels(
        _ entries: [TranscriptEntry],
        collapseToPrimary: Bool,
        primaryName: String = "You",
        enrolledMicNames: Set<String>
    ) -> [TranscriptEntry] {
        guard collapseToPrimary else { return entries }
        return entries.map { entry in
            guard entry.source == .mic, !enrolledMicNames.contains(entry.speaker) else { return entry }
            return TranscriptEntry(
                source: entry.source,
                speaker: primaryName,
                text: entry.text,
                timestamp: entry.timestamp,
                end: entry.end
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
