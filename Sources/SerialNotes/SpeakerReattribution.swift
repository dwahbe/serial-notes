import Foundation

/// Reassigns system-side transcript entries to the offline pass's speakers by
/// timestamp, then relabels them. This is what splits a single streaming "Person 1"
/// label (the live diarizer often merges remote speakers) back into the distinct
/// people the offline pass found.
///
/// Mic-side entries — those whose label is in `micLabels` (the user's "You" /
/// preferred name) — are left untouched: only remote/system speakers are re-diarized,
/// matching the source-based split the rest of the app uses.
enum SpeakerReattribution {
    /// Do not guess across a long diarization gap. Speech the offline diarizer did
    /// not cover is moved into a separate leftover namespace rather than assigning
    /// a possibly confirmed identity to it.
    static let maximumGapSeconds: TimeInterval = 2
    /// Labels retained from the live/high-accuracy diarizer are not in the same
    /// namespace as offline "Person N" labels. Any system entry the offline pass
    /// cannot safely cover is moved into this explicit namespace so it cannot be
    /// silently conflated with an offline anonymous speaker.
    static let leftoverSpeakerPrefix = "Unknown speaker"

    struct LabeledSpeaker: Equatable {
        /// Stable within one offline result; lets sidecar construction associate a
        /// label with its cluster without relying on parallel-array positions.
        let clusterID: String
        let label: String
        let segments: [OfflineSpeakerCluster.Span]
    }

    struct ReattributionResult: Equatable {
        let entries: [TranscriptEntry]
        /// Original live/high-accuracy label → rendered leftover label. The caller
        /// uses this to build sidecar clips from the live diarizer timeline, keeping
        /// unmatched speakers nameable when the offline pass drops a short speaker.
        let leftoverLabelsByOriginalLabel: [String: String]
    }

    /// Assign each identified speaker a display label: a confirmed match keeps the
    /// matched name; suggested/anonymous speakers get a stable "Person N" numbered by
    /// speech volume (callers pass speakers sorted longest-talking first).
    static func labelSpeakers(_ speakers: [IdentifiedSpeaker], personPrefix: String = "Person") -> [LabeledSpeaker] {
        var personN = 0
        return speakers.map { speaker in
            switch speaker.decision {
            case let .confirmed(_, name, _):
                return LabeledSpeaker(
                    clusterID: speaker.cluster.id,
                    label: name,
                    segments: speaker.cluster.segments
                )
            case .suggested, .anonymous:
                personN += 1
                return LabeledSpeaker(
                    clusterID: speaker.cluster.id,
                    label: "\(personPrefix) \(personN)",
                    segments: speaker.cluster.segments
                )
            }
        }
    }

    /// The speaker active at `time`: the one whose segments cover it, else the nearest
    /// segment boundary within `maximumGapSeconds`. Long gaps are deliberately left
    /// unattributed rather than force-labeling a brief/missed speaker as someone else.
    static func speaker(
        at time: TimeInterval,
        among speakers: [LabeledSpeaker],
        maximumGapSeconds: TimeInterval = SpeakerReattribution.maximumGapSeconds
    ) -> LabeledSpeaker? {
        if let covering = speakers.first(where: { $0.segments.contains { $0.start <= time && time <= $0.end } }) {
            return covering
        }
        func distance(to segment: OfflineSpeakerCluster.Span) -> Double {
            if time < segment.start { return segment.start - time }
            if time > segment.end { return time - segment.end }
            return 0
        }
        let nearest = speakers.compactMap { speaker -> (speaker: LabeledSpeaker, distance: Double)? in
            guard let distance = speaker.segments.map(distance).min() else { return nil }
            return (speaker, distance)
        }.min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= maximumGapSeconds else { return nil }
        return nearest.speaker
    }

    /// Re-attribute final transcript entries while their original sub-second ASR
    /// timings and source channel are still available. This is the production path;
    /// it avoids parsing the lossy whole-second Markdown timestamps and cannot relabel
    /// mic entries as remote speakers.
    static func reattribute(_ entries: [TranscriptEntry], speakers: [IdentifiedSpeaker]) -> [TranscriptEntry] {
        reattributeEntries(entries, speakers: speakers).entries
    }

    /// Re-attribute final transcript entries and report any system-side labels the
    /// offline diarizer did not cover. Covered entries receive an offline label;
    /// uncovered system entries receive a disjoint "Unknown speaker N" label grouped
    /// by their original live-diarizer label, so they neither collide with offline
    /// "Person N" labels nor become impossible for the sidecar path to find.
    static func reattributeEntries(_ entries: [TranscriptEntry], speakers: [IdentifiedSpeaker]) -> ReattributionResult {
        let labeled = labelSpeakers(speakers)
        guard !labeled.isEmpty else {
            return ReattributionResult(entries: entries, leftoverLabelsByOriginalLabel: [:])
        }

        var usedLabels = Set(labeled.map(\.label))
        usedLabels.formUnion(entries.map(\.speaker))
        var leftoverLabelsByOriginalLabel: [String: String] = [:]
        var nextLeftoverIndex = 0

        func nextLeftoverLabel() -> String {
            repeat {
                nextLeftoverIndex += 1
                let label = "\(leftoverSpeakerPrefix) \(nextLeftoverIndex)"
                if !usedLabels.contains(label) {
                    usedLabels.insert(label)
                    return label
                }
            } while true
        }

        let reattributed = entries.map { entry in
            guard entry.source == .system else {
                return entry
            }
            if let speaker = speaker(at: entry.timestamp, among: labeled) {
                return TranscriptEntry(
                    source: entry.source,
                    speaker: speaker.label,
                    text: entry.text,
                    timestamp: entry.timestamp,
                    end: entry.end
                )
            }
            let leftoverLabel = leftoverLabelsByOriginalLabel[entry.speaker] ?? {
                let label = nextLeftoverLabel()
                leftoverLabelsByOriginalLabel[entry.speaker] = label
                return label
            }()
            return TranscriptEntry(
                source: entry.source,
                speaker: leftoverLabel,
                text: entry.text,
                timestamp: entry.timestamp,
                end: entry.end
            )
        }
        return ReattributionResult(entries: reattributed, leftoverLabelsByOriginalLabel: leftoverLabelsByOriginalLabel)
    }

    /// Markdown parser regression helper. Production uses the exact-entry overload
    /// above so it can preserve source channel + sub-second timing.
    static func reattribute(transcript: String, speakers: [IdentifiedSpeaker], micLabels: Set<String>) -> String {
        let labeled = labelSpeakers(speakers)
        guard !labeled.isEmpty else { return transcript }

        var usedLabels = Set(labeled.map(\.label))
        usedLabels.formUnion(SpeakerClipExtractor.parseEntries(transcript).map(\.label))
        var leftoverLabelsByOriginalLabel: [String: String] = [:]
        var nextLeftoverIndex = 0

        func nextLeftoverLabel() -> String {
            repeat {
                nextLeftoverIndex += 1
                let label = "\(leftoverSpeakerPrefix) \(nextLeftoverIndex)"
                if !usedLabels.contains(label) {
                    usedLabels.insert(label)
                    return label
                }
            } while true
        }

        let rewritten = transcript.components(separatedBy: "\n").map { line -> String in
            guard let header = TranscriptFormatter.parseEntryHeader(line) else { return line }
            if micLabels.contains(header.label) { return line }
            let newLabel: String
            if let speaker = speaker(at: header.timestamp, among: labeled) {
                newLabel = speaker.label
            } else {
                newLabel = leftoverLabelsByOriginalLabel[header.label] ?? {
                    let label = nextLeftoverLabel()
                    leftoverLabelsByOriginalLabel[header.label] = label
                    return label
                }()
            }
            return TranscriptFormatter.replacingEntryHeaderLabel(
                in: line, from: header.label, to: newLabel
            ) ?? line
        }
        return rewritten.joined(separator: "\n")
    }
}
