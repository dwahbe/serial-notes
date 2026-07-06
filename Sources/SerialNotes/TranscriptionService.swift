@preconcurrency import AVFoundation
import FluidAudio
import Foundation

struct FinalizedSessionResult: Sendable {
    let pendingSpeakerCount: Int
    let manualNotesCommitted: Bool
}

actor TranscriptionService {
    // MARK: - Callbacks (set by RecordingState)

    /// Called when a transcription error occurs. Delivered off-main; caller hops to main if needed.
    var onError: (@Sendable (Error) -> Void)?

    func setCallbacks(onError: (@Sendable (Error) -> Void)?) {
        self.onError = onError
    }

    // MARK: - FluidAudio components

    private var sideStates: [AudioSide: SideState] = [
        .mic: SideState(),
        .system: SideState()
    ]

    // MARK: - Session state

    private var transcriptHandle: FileHandle?
    private var sessionStart: Date?
    private var sessionDate: Date?
    private var sessionDirectory: URL?
    private var rewriter: (any TranscriptRewriter)?
    /// Constructed at session start when the user has summary or action items
    /// enabled, so the underlying LanguageModelSessions can prewarm during the
    /// recording instead of paying ~200–500ms cold-start each at session end.
    /// Falls through to lazy construction in `spliceTopSections` if the
    /// user toggled summary on after recording started.
    private var summarizer: (any TranscriptSummarizer)?
    private var activeSessionID: UUID?
    private var activeRewriteTaskCount = 0
    /// Timestamps of utterances whose rewrite is still in flight. `flushOldEntries`
    /// will not advance past the minimum value here, so a slow rewrite for an
    /// older utterance can still land in `pendingEntries` before its slot flushes.
    private var inflightRewriteTimestamps: [TimeInterval] = []
    private var rewriteDrainContinuations: [CheckedContinuation<Void, Never>] = []
    /// Handles for in-flight rewrite tasks. Drained on session end so a wedged
    /// Foundation Models call can't keep running into the next session.
    private var rewriteTasks: [Task<Void, Never>] = []
    private static let rewriteDrainTimeout: Duration = .seconds(5)
    private static let leftoverSpeakerIndexOffset = 10_000
    private var cachedFinalAsrModels: AsrModels?
    private var finalAsrModelsTask: Task<AsrModels, Error>?

    private var pendingEntries: [TranscriptEntry] = []
    /// The exact entries that survived the streaming/final-ASR pipeline. Retained only
    /// through finalization so offline re-attribution never has to recover timing and
    /// channel ownership from the lossy Markdown rendering.
    private var finalTranscriptEntries: [TranscriptEntry] = []
    /// Names enrolled on the mic side this session. Preserved when the final render
    /// collapses the mic channel to a single primary speaker during remote calls.
    private var enrolledMicNames: Set<String> = []
    /// The label for the user's own (mic) voice — their preferred name, or "You"
    /// when unset. Drives the streaming default mic label and the final-render
    /// collapse target. Set at session start, reset to "You" on session end.
    private var micPrimaryName = "You"
    private var streamingEchoContext = EchoSuppressionContext()
    private var streamingEntryCount = 0
    private var streamingEntrySources = Set<AudioSide>()
    private var lastFlushedTimestamp: TimeInterval = 0
    private static let flushDelaySeconds: TimeInterval = 3.0
    private static let echoSuppressionLookbackSeconds: TimeInterval = 30 * 60
    private static let maxEchoSuppressionSystemEntries = 64
    // Final-render cross-channel echo filter (see CrossChannelEchoFilter). Window
    // is generous because echo can finalize tens of seconds after its source when
    // the two channels' EOU segmentation drifts; the dominance guard keeps it safe.
    private static let echoFilterWindowSeconds: TimeInterval = 45
    // Verbatim echo lands near 1.0 containment; coincidental shared filler ("sounds
    // good", "i think so") lands around 0.5. Keep the threshold above that filler
    // band, and never judge utterances shorter than 4 words — too little signal to
    // tell a real short turn from an echo, so dropping them loses genuine speech.
    private static let echoFilterContainmentThreshold = 0.7
    private static let echoFilterMinWords = 4
    private static let minimumFinalAudioDuration: TimeInterval = 1.0
    private static let diarizerProcessInterval: TimeInterval = 0.75
    private static let streamingErrorReportThreshold = 5

    private var modelsLoaded = false

    // MARK: - Model Lifecycle

    /// The production streaming-ASR construction path — tests pin its compute
    /// units, so route any new manager creation through here.
    static func makeStreamingAsrManager() -> StreamingEouAsrManager {
        StreamingEouAsrManager(configuration: ModelComputePolicy.configuration())
    }

    func downloadModelsIfNeeded() async throws {
        guard !modelsLoaded else {
            prefetchFinalAsrModelsIfNeeded()
            return
        }

        let micManager = Self.makeStreamingAsrManager()
        let sysManager = Self.makeStreamingAsrManager()
        try await micManager.loadModels()
        try await sysManager.loadModels()

        // Explicit .cpuOnly (also FluidAudio's default, and its documented
        // fastest units for LS-EEND) so no load site inherits a GPU-capable
        // default — see ModelComputePolicy.
        let sysDia = LSEENDDiarizer(computeUnits: .cpuOnly)
        try await sysDia.initialize()
        let micDia = LSEENDDiarizer(computeUnits: .cpuOnly)
        try await micDia.initialize()

        sideStates[.mic]?.asr = micManager
        sideStates[.system]?.asr = sysManager
        sideStates[.mic]?.diarizer = micDia
        sideStates[.system]?.diarizer = sysDia
        modelsLoaded = true
        prefetchFinalAsrModelsIfNeeded()
    }

    // MARK: - Session Lifecycle

    func startSession(
        sessionDirectory: URL,
        sessionStart: Date,
        enrollments: [EnrollmentClip] = [],
        summarySettings: SummarySettings.Snapshot = .disabled,
        micPrimaryName: String = "You"
    ) async throws {
        guard modelsLoaded else {
            throw TranscriptionError.modelsNotLoaded
        }
        self.micPrimaryName = micPrimaryName

        for side in AudioSide.allCases {
            await sideStates[side]?.asr?.reset()
            sideStates[side]?.diarizer?.reset()
            sideStates[side]?.resetSession()
        }
        activeSessionID = UUID()
        activeRewriteTaskCount = 0
        inflightRewriteTimestamps.removeAll()
        rewriteTasks.removeAll()
        resumeRewriteDrainContinuations()

        // Prime diarizers with saved voice profiles so known speakers get named.
        enrolledMicNames = []
        for clip in enrollments {
            if clip.side == .mic { enrolledMicNames.insert(clip.name) }
            let diarizer = sideStates[clip.side]?.diarizer
            do {
                _ = try diarizer?.enrollSpeaker(
                    withSamples: clip.samples,
                    sourceSampleRate: clip.sampleRate,
                    named: clip.name
                )
            } catch {
                // Priming is best-effort — a bad clip shouldn't block the session.
                onError?(error)
            }
        }

        self.sessionStart = sessionStart
        self.sessionDate = sessionStart
        self.sessionDirectory = sessionDirectory
        pendingEntries = []
        finalTranscriptEntries = []
        streamingEchoContext.reset()
        streamingEntryCount = 0
        streamingEntrySources = []
        lastFlushedTimestamp = 0

        // The EOU callbacks installed below dispatch into `handleUtterance`,
        // which reads `self.rewriter`. Assign the rewriter (and any prewarm)
        // before installing the callbacks so the first utterance can never see
        // a nil rewriter — a future reorder would silently regress to heuristic
        // punctuation on session start.
        let newRewriter = TranscriptRewriterFactory.make()
        rewriter = newRewriter
        if let fm = newRewriter as? FoundationModelsRewriter {
            Task.detached { await fm.prewarm() }
        }

        // Prewarm summarizer in parallel — the real call lands at session end,
        // but loading the LanguageModelSessions during recording hides
        // ~200–500ms of cold-start each from the user-visible "Generating
        // summary…" wait.
        if summarySettings.generateSummary || summarySettings.generateActionItems,
           let newSummarizer = TranscriptSummarizerFactory.make() {
            summarizer = newSummarizer
            Task.detached { await newSummarizer.prewarm() }
        } else {
            summarizer = nil
        }

        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        transcriptHandle = handle

        // Write placeholder header with duration=0. Rewritten on endSession
        // with final duration — header byte-length is fixed, so seek+write works.
        let header = TranscriptFormatter.header(date: sessionStart, duration: 0)
        handle.write(Data(header.utf8))

        // ASR callbacks (rewriter must already be assigned — see comment above).
        let micAsr = sideStates[.mic]?.asr
        let systemAsr = sideStates[.system]?.asr
        await micAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleUtterance(text, source: .mic) }
        }
        await systemAsr?.setEouCallback { [weak self] text in
            guard let self else { return }
            Task { await self.handleUtterance(text, source: .system) }
        }
    }

    /// Returns the number of unrecognized system-side speakers for which an
    /// enrollment clip + `speakers.json` entry was written (0 when none / not
    /// applicable). The caller uses it to decide whether to offer post-meeting naming.
    @discardableResult
    func endSession(
        summarySettings: SummarySettings.Snapshot = .disabled,
        keepAudioFiles: Bool = true,
        summaryCutoff: TimeInterval? = nil,
        manualNotesMarkdown: String? = nil,
        extractSpeakers: Bool = true,
        performOfflineIdentity: Bool = true,
        speakerCandidates: [SpeakerIdentityMatcher.Candidate] = [],
        offlineIdentifier: OfflineSpeakerIdentifier? = nil,
        offlineIdentityTimeout: Duration? = nil,
        requirePreparedOfflineModels: Bool = false,
        onPhase: (@Sendable (FinalizationPhase) -> Void)? = nil
    ) async -> FinalizedSessionResult {
        onPhase?(.finishingTranscript)
        for side in AudioSide.allCases {
            do {
                if let text = try await sideStates[side]?.asr?.finish() {
                    enqueueFinalUtterance(text, source: side)
                }
            } catch {
                await handleStreamingASRError(error, source: side, stage: "finish")
            }
        }

        await drainRewriteTasks()
        for side in AudioSide.allCases {
            _ = try? sideStates[side]?.diarizer?.process()
            _ = try? sideStates[side]?.diarizer?.finalizeSession()
        }

        flushAllEntries()

        let duration = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        let finalHeader = TranscriptFormatter.header(date: sessionDate ?? sessionStart ?? Date(), duration: duration)

        onPhase?(.improvingTranscript)
        let highAccuracyRender = await highAccuracyTranscript(header: finalHeader)

        var pendingTranscriptWrite: String?
        var needsStreamingHeaderRewrite = false
        if let highAccuracyRender {
            try? transcriptHandle?.close()
            transcriptHandle = nil
            finalTranscriptEntries = highAccuracyRender.entries
            pendingTranscriptWrite = highAccuracyRender.text
        } else {
            try? transcriptHandle?.close()
            needsStreamingHeaderRewrite = true
        }
        transcriptHandle = nil

        // Both paths leave a finalized transcript on disk — splice manual notes,
        // summary, and action items between the header and the first entry when
        // requested.
        var pendingSpeakerCount = 0
        var manualNotesCommitted = false
        if let directory = sessionDirectory {
            // Offline identity pass: re-diarize the system audio, re-attribute the
            // transcript's "Person N" labels to the speakers it actually finds, and
            // build the speaker sidecar. Runs BEFORE the summary (so the summary sees
            // the corrected labels) and before audio cleanup (it reads system.wav).
            // Returns nil if it couldn't run (no system audio / models unavailable),
            // in which case we fall back to the streaming-diarizer extraction below.
            var offlinePassRan = false
            if performOfflineIdentity, let offlineIdentifier {
                onPhase?(.identifyingSpeakers)
                if let count = await runOfflineIdentityPass(
                    directory: directory,
                    identifier: offlineIdentifier,
                    candidates: speakerCandidates,
                    header: finalHeader,
                    transcriptEntries: finalTranscriptEntries,
                    extractSpeakerClips: extractSpeakers,
                    timeout: offlineIdentityTimeout,
                    requirePreparedModels: requirePreparedOfflineModels
                ) {
                    pendingSpeakerCount = count
                    offlinePassRan = true
                    pendingTranscriptWrite = nil
                    needsStreamingHeaderRewrite = false
                }
            }

            // If the offline pass did not write a re-attributed render, put the
            // high-accuracy transcript or final streaming header on disk now. This
            // avoids redundant writes on the successful offline path while keeping
            // the summary/fallback steps' "read transcript.md" contract intact.
            if let pendingTranscriptWrite {
                writeTranscript(pendingTranscriptWrite, in: directory)
            } else if needsStreamingHeaderRewrite {
                rewriteTranscriptHeader(finalHeader, in: directory)
            }

            // Only announce the summary stage when the splice will actually run a
            // model call — otherwise the bar would dwell on a no-op.
            if summarySettings.generateSummary || summarySettings.generateActionItems {
                onPhase?(.summarizing)
            }
            manualNotesCommitted = await spliceTopSections(
                sessionDirectory: directory,
                header: finalHeader,
                settings: summarySettings,
                summaryCutoff: summaryCutoff,
                manualNotesMarkdown: manualNotesMarkdown
            )
            onPhase?(.wrappingUp)
            // Streaming-diarizer fallback — only for normal stops when the offline
            // pass didn't run (no system audio, unavailable models, or timeout).
            // App quit keeps clip extraction off, so it skips this path too.
            if extractSpeakers, !offlinePassRan,
               let transcript = try? String(
                   contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8
               ) {
                pendingSpeakerCount = extractUnnamedSystemSpeakers(in: directory, transcript: transcript)
            }
            if !keepAudioFiles {
                // Must run after high-accuracy ASR, the offline pass, summary splice, and
                // clip extraction — all read the raw audio.
                deleteAudioFiles(in: directory)
            }
        }

        sessionStart = nil
        sessionDate = nil
        sessionDirectory = nil
        rewriter = nil
        summarizer = nil
        activeSessionID = nil
        enrolledMicNames = []
        micPrimaryName = "You"
        finalTranscriptEntries = []
        return FinalizedSessionResult(
            pendingSpeakerCount: pendingSpeakerCount,
            manualNotesCommitted: manualNotesCommitted
        )
    }

    // MARK: - Offline identity pass

    /// Re-diarize the saved system audio into final speakers, re-attribute the
    /// transcript's labels to them, and write the speaker sidecar. Returns the number
    /// of speakers offered for naming (suggested + anonymous), or nil if the pass
    /// couldn't run (no system audio / models unavailable) so the caller can fall back.
    private func runOfflineIdentityPass(
        directory: URL,
        identifier: OfflineSpeakerIdentifier,
        candidates: [SpeakerIdentityMatcher.Candidate],
        header: String,
        transcriptEntries: [TranscriptEntry],
        extractSpeakerClips: Bool,
        timeout: Duration?,
        requirePreparedModels: Bool
    ) async -> Int? {
        let systemURL = directory.appendingPathComponent("system.wav")
        guard FileManager.default.fileExists(atPath: systemURL.path) else { return nil }
        if requirePreparedModels {
            guard await identifier.hasLoadedModels() else {
                NSLog("[SerialNotes/Speakers] offline identity skipped on quit: models were not prepared")
                return nil
            }
        }

        let identified: [IdentifiedSpeaker]
        do {
            if let timeout {
                guard let result = try await Self.identifySpeakersWithTimeout(
                    identifier: identifier,
                    systemURL: systemURL,
                    candidates: candidates,
                    timeout: timeout
                ) else {
                    NSLog("[SerialNotes/Speakers] offline identity timed out after %.1fs; leaving transcript on the cheaper finalized path",
                          timeout.secondsValue)
                    return nil
                }
                identified = result
            } else {
                identified = try await identifier.identifySpeakers(inRecordingAt: systemURL, candidates: candidates)
            }
        } catch {
            NSLog("[SerialNotes/Speakers] offline identity pass failed: \(error.localizedDescription)")
            return nil
        }
        // An empty output is not a successful identity pass: the streaming diarizer
        // can still offer clips for short speakers that the offline 20-second noise
        // floor intentionally excludes.
        guard !identified.isEmpty else { return nil }

        // Re-attribute only the system entries, using their exact ASR times before
        // Markdown truncates them to whole seconds. This also makes mic exclusion
        // source-based rather than coupled to a particular display-name set.
        let reattribution = SpeakerReattribution.reattributeEntries(transcriptEntries, speakers: identified)
        let reattributedEntries = reattribution.entries
        let reattributedTranscript = renderEntries(header: header, entries: reattributedEntries)
        guard writeTranscript(reattributedTranscript, in: directory) else { return nil }

        guard extractSpeakerClips else { return 0 }
        return writeOfflineSidecar(
            directory: directory,
            identified: identified,
            transcriptEntries: reattributedEntries,
            systemURL: systemURL,
            leftoverLabelsByOriginalLabel: reattribution.leftoverLabelsByOriginalLabel
        )
    }

    private nonisolated static func identifySpeakersWithTimeout(
        identifier: OfflineSpeakerIdentifier,
        systemURL: URL,
        candidates: [SpeakerIdentityMatcher.Candidate],
        timeout: Duration
    ) async throws -> [IdentifiedSpeaker]? {
        let work = Task.detached(priority: .utility) {
            try await identifier.identifySpeakers(inRecordingAt: systemURL, candidates: candidates)
        }
        let outcome = await withCheckedContinuation { continuation in
            let gate = OfflineIdentityRaceGate(continuation)
            Task {
                do {
                    await gate.resume(.success(try await work.value))
                } catch {
                    await gate.resume(.failure(SendableError(error: error)))
                }
            }
            Task {
                do {
                    try await Task.sleep(for: timeout)
                    await gate.resume(.timedOut)
                } catch {
                    // The sleeper is intentionally best-effort; cancellation means
                    // some other outcome already won or the process is terminating.
                }
            }
        }

        switch outcome {
        case let .success(speakers):
            return speakers
        case let .failure(error):
            throw error.error
        case .timedOut:
            work.cancel()
            return nil
        }
    }

    /// Turn the offline pass's speakers into a `speakers.json` sidecar (+ clips for the
    /// ones the user can name). Confirmed matches are already named in the transcript,
    /// so they're recorded as `.named` without a clip; suggested/anonymous get a clip
    /// and are offered. Returns the count offered (suggested + anonymous).
    private func writeOfflineSidecar(
        directory: URL,
        identified: [IdentifiedSpeaker],
        transcriptEntries: [TranscriptEntry],
        systemURL: URL,
        leftoverLabelsByOriginalLabel: [String: String]
    ) -> Int {
        guard let sampleRate = SpeakerClipExtractor.sampleRate(of: systemURL), sampleRate > 0 else { return 0 }
        let sessionFolder = directory.lastPathComponent
        var labelsByClusterID: [String: String] = [:]
        for labeled in SpeakerReattribution.labelSpeakers(identified) {
            if labelsByClusterID[labeled.clusterID] == nil {
                labelsByClusterID[labeled.clusterID] = labeled.label
            } else {
                NSLog("[SerialNotes/Speakers] duplicate offline cluster id %@ while labeling speakers; keeping first label",
                      labeled.clusterID)
            }
        }

        var detected: [DetectedSpeaker] = []
        var nameableCount = 0
        for (index, speaker) in identified.enumerated() {
            let totalSpeech = speaker.cluster.totalSpeechSeconds
            guard totalSpeech >= SpeakerClipExtractor.minSpeechSeconds else { continue }
            guard let label = labelsByClusterID[speaker.cluster.id] else {
                assertionFailure("Offline speaker label missing for cluster \(speaker.cluster.id)")
                continue
            }
            let allSegments = speaker.cluster.segments.map { Segment(start: $0.start, end: $0.end) }

            // Only offer speech that remains in the final transcript. The final ASR
            // echo filter can intentionally remove a local voice looped into the
            // system channel; do not turn that removed echo into a phantom profile.
            let matchingEntries = SpeakerClipExtractor.survivingSystemEntries(
                for: label, in: transcriptEntries
            )
            guard !matchingEntries.isEmpty else { continue }
            let segs = SpeakerClipExtractor.segmentsCovering(
                allSegments, timestamps: matchingEntries.map(\.timestamp)
            )
            let survivingSpeech = segs.reduce(0) { $0 + $1.duration }
            guard survivingSpeech >= SpeakerClipExtractor.minSpeechSeconds else { continue }

            let state: SpeakerState
            let resolved: String?
            let suggested: String?
            switch speaker.decision {
            case let .confirmed(_, name, _): state = .named; resolved = name; suggested = nil
            case let .suggested(_, name, _): state = .suggested; resolved = nil; suggested = name
            case .anonymous: state = .pending; resolved = nil; suggested = nil
            }

            // Only speakers the user might name need an extracted clip.
            var clipFile = ""
            if state != .named {
                let frames = SpeakerClipExtractor.clipFrames(forSegments: segs, sampleRate: sampleRate)
                guard !frames.isEmpty else { continue }
                clipFile = SpeakerClipExtractor.clipFileName(forSpeakerIndex: index)
                let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: sessionFolder, clipFile: clipFile)
                do {
                    try SpeakerClipExtractor.writeClip(from: systemURL, frames: frames, to: clipURL)
                } catch {
                    NSLog("[SerialNotes/Speakers] clip extract failed for \(label): \(error.localizedDescription)")
                    continue
                }
            }

            detected.append(DetectedSpeaker(
                label: label,
                speakerIndex: index,
                totalSpeechSeconds: survivingSpeech,
                sampleRate: sampleRate,
                segments: segs,
                sampleText: SpeakerClipExtractor.truncated(
                    matchingEntries.map(\.text).max(by: { $0.count < $1.count }) ?? "",
                    to: 140
                ),
                clipFile: clipFile,
                state: state,
                resolvedName: resolved,
                suggestedName: suggested))
            if state == .pending || state == .suggested {
                nameableCount += 1
            }
        }

        let leftoverDetected = extractLeftoverStreamingSpeakers(
            directory: directory,
            transcriptEntries: transcriptEntries,
            originalToLeftoverLabel: leftoverLabelsByOriginalLabel,
            systemURL: systemURL,
            sampleRate: sampleRate
        )
        detected.append(contentsOf: leftoverDetected)
        nameableCount += leftoverDetected.count

        // A fully-confirmed meeting needs no naming UI — skip the sidecar entirely.
        guard detected.contains(where: { $0.state != .named }) else { return 0 }
        detected.sort { $0.speakerIndex < $1.speakerIndex }
        let sidecar = SpeakerSidecar(
            version: SpeakerSidecar.currentVersion,
            sessionStartedAt: sessionStart ?? sessionDate ?? Date(),
            speakers: detected)
        do {
            try SpeakerClipExtractor.writeSidecar(sidecar, inSessionDirectory: directory)
        } catch {
            NSLog("[SerialNotes/Speakers] failed to write speakers.json: \(error.localizedDescription)")
            SpeakerClipExtractor.reapPendingClips(forSessionFolder: sessionFolder)
            return 0
        }
        return nameableCount
    }

    private func extractLeftoverStreamingSpeakers(
        directory: URL,
        transcriptEntries: [TranscriptEntry],
        originalToLeftoverLabel: [String: String],
        systemURL: URL,
        sampleRate: Double
    ) -> [DetectedSpeaker] {
        guard !originalToLeftoverLabel.isEmpty,
              let systemState = sideStates[.system],
              let diarizer = systemState.diarizer else { return [] }

        let sessionFolder = directory.lastPathComponent
        var detected: [DetectedSpeaker] = []
        for speaker in diarizer.timeline.speakers.values.sorted(by: { $0.index < $1.index }) {
            guard speaker.name == nil,
                  let originalLabel = systemState.speakerLabels[speaker.index],
                  let leftoverLabel = originalToLeftoverLabel[originalLabel] else { continue }

            let matchingEntries = SpeakerClipExtractor.survivingSystemEntries(
                for: leftoverLabel, in: transcriptEntries
            )
            guard !matchingEntries.isEmpty else { continue }

            let allSegments = (speaker.finalizedSegments + speaker.tentativeSegments)
                .map { Segment(start: Double($0.startTime), end: Double($0.endTime)) }
            let survivingSegments = SpeakerClipExtractor.segmentsCovering(
                allSegments, timestamps: matchingEntries.map(\.timestamp)
            )
            let survivingDuration = survivingSegments.reduce(0) { $0 + $1.duration }
            guard survivingDuration >= SpeakerClipExtractor.minSpeechSeconds else { continue }

            let frames = SpeakerClipExtractor.clipFrames(forSegments: survivingSegments, sampleRate: sampleRate)
            guard !frames.isEmpty else { continue }

            let sidecarIndex = Self.leftoverSpeakerIndexOffset + speaker.index
            let clipFile = SpeakerClipExtractor.clipFileName(forSpeakerIndex: sidecarIndex)
            let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: sessionFolder, clipFile: clipFile)
            do {
                try SpeakerClipExtractor.writeClip(from: systemURL, frames: frames, to: clipURL)
            } catch {
                NSLog("[SerialNotes/Speakers] failed to extract leftover clip for \(leftoverLabel): \(error.localizedDescription)")
                continue
            }

            detected.append(DetectedSpeaker(
                label: leftoverLabel,
                speakerIndex: sidecarIndex,
                totalSpeechSeconds: survivingDuration,
                sampleRate: sampleRate,
                segments: survivingSegments,
                sampleText: SpeakerClipExtractor.truncated(
                    matchingEntries.map(\.text).max(by: { $0.count < $1.count }) ?? "",
                    to: 140
                ),
                clipFile: clipFile,
                state: .pending,
                resolvedName: nil
            ))
        }
        return detected
    }

    /// Cut a short enrollment clip for each unrecognized system-side speaker (`name == nil`)
    /// that has enough speech and actually appears in the finalized transcript, writing the
    /// clips to the app-support pending area and a `speakers.json` sidecar to the session
    /// folder. Returns the number of speakers written. Called from `endSession` while
    /// `system.wav` and the diarizer timeline are both still available.
    private func extractUnnamedSystemSpeakers(in directory: URL, transcript: String) -> Int {
        guard let systemState = sideStates[.system],
              let diarizer = systemState.diarizer else { return 0 }

        let systemURL = directory.appendingPathComponent("system.wav")
        guard FileManager.default.fileExists(atPath: systemURL.path),
              let sampleRate = SpeakerClipExtractor.sampleRate(of: systemURL),
              sampleRate > 0 else { return 0 }

        // Parse the finalized transcript once and bucket entries by their rendered label.
        let entriesByLabel = Dictionary(grouping: SpeakerClipExtractor.parseEntries(transcript), by: \.label)
        let sessionFolder = directory.lastPathComponent
        var detected: [DetectedSpeaker] = []

        for speaker in diarizer.timeline.speakers.values {
            // Recognized voices already carry a name; only unknown speakers are offered.
            guard speaker.name == nil else { continue }
            guard Double(speaker.speechDuration) >= SpeakerClipExtractor.minSpeechSeconds else { continue }
            // Use the rendered label string (assignment-order "Person N"), not the index.
            // Require the label to actually appear in the transcript (lines dropped as echo
            // never reach disk, so the speaker is genuinely present).
            guard let label = systemState.speakerLabels[speaker.index],
                  let labelEntries = entriesByLabel[label], !labelEntries.isEmpty else { continue }

            // Restrict the clip to segments around lines that survived the echo filter, so a
            // phantom system speaker (the local user's voice echoed onto the system channel)
            // whose lines were mostly dropped doesn't contribute its echoed audio. Gate on
            // the *surviving* speech, not the raw diarizer timeline.
            let allSegments = (speaker.finalizedSegments + speaker.tentativeSegments)
                .map { Segment(start: Double($0.startTime), end: Double($0.endTime)) }
            let survivingSegments = SpeakerClipExtractor.segmentsCovering(
                allSegments, timestamps: labelEntries.map(\.timestamp)
            )
            let survivingDuration = survivingSegments.reduce(0) { $0 + $1.duration }
            guard survivingDuration >= SpeakerClipExtractor.minSpeechSeconds else { continue }

            let frames = SpeakerClipExtractor.clipFrames(forSegments: survivingSegments, sampleRate: sampleRate)
            guard !frames.isEmpty else { continue }

            let clipFile = SpeakerClipExtractor.clipFileName(forSpeakerIndex: speaker.index)
            let clipURL = SpeakerClipExtractor.clipURL(sessionFolder: sessionFolder, clipFile: clipFile)
            do {
                try SpeakerClipExtractor.writeClip(from: systemURL, frames: frames, to: clipURL)
            } catch {
                NSLog("[SerialNotes/Speakers] failed to extract clip for \(label): \(error.localizedDescription)")
                continue
            }

            let sampleText = labelEntries.map(\.text).max(by: { $0.count < $1.count }) ?? ""
            detected.append(DetectedSpeaker(
                label: label,
                speakerIndex: speaker.index,
                totalSpeechSeconds: survivingDuration,
                sampleRate: sampleRate,
                segments: survivingSegments,
                sampleText: SpeakerClipExtractor.truncated(sampleText, to: 140),
                clipFile: clipFile,
                state: .pending,
                resolvedName: nil
            ))
        }

        guard !detected.isEmpty else { return 0 }
        detected.sort { $0.speakerIndex < $1.speakerIndex }

        let sidecar = SpeakerSidecar(
            version: SpeakerSidecar.currentVersion,
            sessionStartedAt: sessionStart ?? sessionDate ?? Date(),
            speakers: detected
        )
        do {
            try SpeakerClipExtractor.writeSidecar(sidecar, inSessionDirectory: directory)
        } catch {
            NSLog("[SerialNotes/Speakers] failed to write speakers.json: \(error.localizedDescription)")
            SpeakerClipExtractor.reapPendingClips(forSessionFolder: sessionFolder)
            return 0
        }
        return detected.count
    }

    private func deleteAudioFiles(in directory: URL) {
        let fm = FileManager.default
        for name in ["system.wav", "mic.wav"] {
            let url = directory.appendingPathComponent(name)
            do {
                try fm.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already absent (e.g., mic permission denied so mic.wav never opened) — fine.
            } catch {
                NSLog("[SerialNotes/Transcription] failed to delete \(name): \(error.localizedDescription)")
            }
        }
    }

    /// Splices manual notes + summary + action items between the header and the
    /// first entry. Returns whether non-empty manual notes ended up in
    /// transcript.md (freshly spliced or already present) — false when the notes
    /// were empty, the transcript was unreadable, or the write failed.
    private func spliceTopSections(
        sessionDirectory: URL,
        header: String,
        settings: SummarySettings.Snapshot,
        summaryCutoff: TimeInterval?,
        manualNotesMarkdown: String?
    ) async -> Bool {
        let manualSection = TranscriptFormatter.manualNotesSection(manualNotesMarkdown)
        let hasNotes = !manualSection.isEmpty
        let shouldGenerateSummary = settings.generateSummary || settings.generateActionItems
        guard hasNotes || shouldGenerateSummary else { return false }

        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
        guard let fileText = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return false }
        guard fileText.hasPrefix(header) else { return false }

        let body = String(fileText.dropFirst(header.count))

        // Idempotency is per section: a previous endSession (or future
        // regenerate-summary call) skips only what it already spliced, so
        // pending notes still land above an existing generated block instead of
        // being reported as a failure.
        if body.contains("## Notes\n") {
            return hasNotes
        }
        if body.contains("## Summary\n") || body.contains("## Action items\n") {
            guard hasNotes else { return false }
            return write(header + manualSection + body, to: transcriptURL)
        }

        var result = SummaryResult.empty
        if shouldGenerateSummary,
           let summarizer = summarizer ?? TranscriptSummarizerFactory.make() {
            let summaryBody = TranscriptFormatter.summaryInput(from: body, cutoff: summaryCutoff)
            let trimmedSummaryBody = summaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if SummarizerTextProcessing.wordCount(trimmedSummaryBody) >= SummarizerTextProcessing.minSummaryInputWords {
                result = await summarizer.summarize(
                    transcript: trimmedSummaryBody,
                    generateSummary: settings.generateSummary,
                    generateActionItems: settings.generateActionItems
                )
            }
        }

        let sections = TranscriptFormatter.topSections(manualNotes: manualNotesMarkdown, summary: result)
        guard !sections.isEmpty else { return false }
        return write(header + sections + body, to: transcriptURL) && hasNotes
    }

    private func write(_ content: String, to transcriptURL: URL) -> Bool {
        do {
            try content.write(to: transcriptURL, atomically: true, encoding: String.Encoding.utf8)
            return true
        } catch {
            NSLog("[SerialNotes/Transcription] failed to write spliced transcript: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Audio Input

    func processMicAudio(_ captured: CapturedAudioBuffer) async {
        await processAudio(captured, source: .mic)
    }

    func processSystemAudio(_ captured: CapturedAudioBuffer) async {
        await processAudio(captured, source: .system)
    }

    private func processAudio(_ captured: CapturedAudioBuffer, source: AudioSide) async {
        let state = sideState(for: source)
        guard let asr = state.asr else { return }
        let buffer = captured.buffer
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let sampleRate = buffer.format.sampleRate

        if state.sampleRate == 0 { state.sampleRate = sampleRate }
        state.samplesProcessed += frameCount

        if let diarizer = state.diarizer {
            do {
                try addAudio(buffer, to: diarizer, sourceSampleRate: sampleRate)
                state.diarizerSamplesSinceProcess += frameCount
                if shouldProcessDiarizer(samplesSinceProcess: state.diarizerSamplesSinceProcess, sampleRate: sampleRate) {
                    _ = try diarizer.process()
                    state.diarizerSamplesSinceProcess = 0
                }
            } catch {
                handleDiarizerError(error, source: source, state: state)
            }
        }

        do {
            _ = try await asr.process(audioBuffer: buffer)
            state.streamingASRConsecutiveFailures = 0
        } catch {
            await handleStreamingASRError(error, source: source, stage: "process")
        }
    }

    private func handleDiarizerError(_ error: Error, source: AudioSide, state: SideState) {
        state.diarizerConsecutiveFailures += 1
        NSLog(
            "[SerialNotes/Transcription] live diarizer \(source.logName) failed (\(state.diarizerConsecutiveFailures) consecutive): \(diagnosticDescription(for: error))"
        )

        // Speaker labels are best-effort. Avoid surfacing raw Core ML errors in
        // the UI; the ASR path can still produce a transcript without diarizer
        // output, and `LSEENDDiarizer` clears pending audio on failed process().
    }

    private func handleStreamingASRError(_ error: Error, source: AudioSide, stage: String) async {
        let state = sideState(for: source)
        state.streamingASRConsecutiveFailures += 1
        NSLog(
            "[SerialNotes/Transcription] live ASR \(source.logName) \(stage) failed (\(state.streamingASRConsecutiveFailures) consecutive): \(diagnosticDescription(for: error))"
        )

        // FluidAudio's streaming manager keeps its buffered audio if Core ML
        // throws during prediction. Reset this side so the next callback starts
        // from fresh audio instead of retrying the same failed chunk forever.
        await state.asr?.reset()
        state.lastUtteranceEndSamples = state.samplesProcessed

        guard state.streamingASRConsecutiveFailures == Self.streamingErrorReportThreshold else {
            return
        }
        onError?(TranscriptionError.streamingTranscriptionDegraded)
    }

    private nonisolated func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    // MARK: - EOU Handlers

    private func handleUtterance(_ text: String, source: AudioSide) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = sideState(for: source)
        let currentSamples = state.samplesProcessed
        let previousEndSamples = state.lastUtteranceEndSamples
        state.lastUtteranceEndSamples = currentSamples
        let sampleRate = state.sampleRate
        let asr = state.asr
        await asr?.reset()

        if !trimmed.isEmpty {
            let midpoint = midpointTime(
                lastEndSamples: previousEndSamples,
                currentSamples: currentSamples,
                sampleRate: sampleRate
            )
            let speaker = currentSpeaker(for: source, at: midpoint)
            enqueueRewrittenEntry(source: source, speaker: speaker, text: trimmed, timestamp: midpoint)
        }
    }

    private func enqueueFinalUtterance(_ text: String, source: AudioSide) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousEndSamples: Int
        let currentSamples: Int
        let sampleRate: Double
        let state = sideState(for: source)
        previousEndSamples = state.lastUtteranceEndSamples
        currentSamples = state.samplesProcessed
        sampleRate = state.sampleRate
        state.lastUtteranceEndSamples = currentSamples

        let midpoint = midpointTime(
            lastEndSamples: previousEndSamples,
            currentSamples: currentSamples,
            sampleRate: sampleRate
        )
        let speaker = currentSpeaker(for: source, at: midpoint)
        enqueueRewrittenEntry(source: source, speaker: speaker, text: trimmed, timestamp: midpoint)
    }

    private func enqueueRewrittenEntry(
        source: AudioSide,
        speaker: String,
        text: String,
        timestamp: TimeInterval
    ) {
        guard let sessionID = activeSessionID else { return }
        let rewriter = rewriter
        activeRewriteTaskCount += 1
        inflightRewriteTimestamps.append(timestamp)
        let task = Task.detached { [weak self] in
            let restored = await rewriter?.rewrite(text) ?? text
            // If endSession cancelled us mid-rewrite, the entry is still valid
            // (heuristic punctuation kicked in inside the rewriter on
            // cancellation), but skip the actor write — the session is already
            // tearing down and we don't want to race the splice or final
            // render. The drain has already accounted for our slot.
            if Task.isCancelled { return }
            let entry = TranscriptEntry(source: source, speaker: speaker, text: restored, timestamp: timestamp)
            await self?.appendRewrittenEntry(entry, sessionID: sessionID)
            await self?.rewriteTaskFinished(sessionID: sessionID)
        }
        rewriteTasks.append(task)
    }

    private func appendRewrittenEntry(_ entry: TranscriptEntry, sessionID: UUID) {
        // Stale rewrite from a prior session: its tracker was already wiped by
        // startSession's removeAll. Don't remove anything here — a same-valued
        // timestamp in the new session would otherwise have its slot stolen.
        guard sessionID == activeSessionID else { return }
        if let idx = inflightRewriteTimestamps.firstIndex(of: entry.timestamp) {
            inflightRewriteTimestamps.remove(at: idx)
        }
        // Defensive — with the in-flight floor in flushOldEntries, this guard
        // should be unreachable. Keep it as belt-and-braces so a regression can't
        // double-write.
        guard entry.timestamp >= lastFlushedTimestamp else { return }
        pendingEntries.append(entry)
        flushOldEntries()
    }

    private func drainRewriteTasks() async {
        guard activeRewriteTaskCount > 0 else {
            rewriteTasks.removeAll()
            return
        }

        // Race the natural drain against a hard timeout. Drain resumes when
        // every detached rewrite calls `rewriteTaskFinished`. The timeout is
        // a safety net so a wedged on-device FM call can't hang the user's
        // "Stop" press indefinitely. On timeout we cancel the remaining tasks
        // and resume any waiting continuations so endSession can proceed.
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await self?.awaitNaturalDrain()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: Self.rewriteDrainTimeout)
                return true
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }

        if timedOut {
            NSLog("[SerialNotes/Transcription] rewrite drain timed out after %.1fs — cancelling %d pending task(s)",
                  Double(Self.rewriteDrainTimeout.components.seconds),
                  activeRewriteTaskCount)
            cancelOutstandingRewriteTasks()
        } else {
            rewriteTasks.removeAll()
        }
    }

    private func awaitNaturalDrain() async {
        await withCheckedContinuation { continuation in
            rewriteDrainContinuations.append(continuation)
        }
    }

    private func cancelOutstandingRewriteTasks() {
        for task in rewriteTasks { task.cancel() }
        rewriteTasks.removeAll()
        // The cancelled detached tasks short-circuit before calling
        // rewriteTaskFinished, so reset the bookkeeping inline and resume
        // anything still waiting on the drain continuation.
        activeRewriteTaskCount = 0
        inflightRewriteTimestamps.removeAll()
        resumeRewriteDrainContinuations()
    }

    private func rewriteTaskFinished(sessionID: UUID) {
        guard sessionID == activeSessionID else { return }
        activeRewriteTaskCount = max(0, activeRewriteTaskCount - 1)
        guard activeRewriteTaskCount == 0 else { return }
        resumeRewriteDrainContinuations()
    }

    private func resumeRewriteDrainContinuations() {
        let continuations = rewriteDrainContinuations
        rewriteDrainContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    // MARK: - Speaker Lookup

    private func currentSpeaker(for source: AudioSide, at time: TimeInterval) -> String {
        guard let diarizer = sideStates[source]?.diarizer else {
            return labelForSpeaker(0, source: source)
        }
        if let (idx, name) = speakerInfo(in: diarizer, at: time) {
            if let name, !name.isEmpty { return name }
            return labelForSpeaker(idx, source: source)
        }
        return labelForSpeaker(0, source: source)
    }

    /// Find the diarizer's best guess of who was speaking at `time`, along with
    /// the enrolled name if one was primed at session start.
    /// Preference: segment covering time → most recently ended segment.
    private nonisolated func speakerInfo(in diarizer: LSEENDDiarizer, at time: TimeInterval) -> (index: Int, name: String?)? {
        let timeline = diarizer.timeline
        let timeFloat = Float(time)

        for (_, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments {
                if segment.startTime <= timeFloat && timeFloat <= segment.endTime {
                    return (segment.speakerIndex, speaker.name)
                }
            }
        }

        var bestMatch: (index: Int, name: String?, endTime: Float)?
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments
            where segment.endTime <= timeFloat {
                if bestMatch == nil || segment.endTime > bestMatch!.endTime {
                    bestMatch = (segment.speakerIndex, speaker.name, segment.endTime)
                }
            }
        }
        return bestMatch.map { ($0.index, $0.name) }
    }

    private func labelForSpeaker(_ speakerIndex: Int, source: AudioSide) -> String {
        let state = sideState(for: source)
        if let label = state.speakerLabels[speakerIndex] { return label }

        let label: String
        switch source {
        case .system:
            label = "Person \(state.nextSystemPersonNumber)"
            state.nextSystemPersonNumber += 1
        case .mic:
            // The first mic voice is assumed to be the user — unless their own
            // voice is enrolled, in which case the diarizer names them via the
            // enrollment match and an unmatched mic index is someone *else* in
            // the room, who must not inherit the primary name. (On calls the
            // final render still collapses stray "Voice N" mic labels back to
            // the primary name — see normalizeMicLabels.)
            if !state.micSeenPrimarySpeaker && enrolledMicNames.isEmpty {
                label = micPrimaryName
                state.micSeenPrimarySpeaker = true
            } else {
                label = "Voice \(state.nextMicVoiceNumber)"
                state.nextMicVoiceNumber += 1
            }
        }

        state.speakerLabels[speakerIndex] = label
        return label
    }

    // MARK: - Transcript Flushing

    private func flushOldEntries() {
        let cutoff = max(lastFlushedTimestamp, currentAudioTime() - Self.flushDelaySeconds)
        // Hold back any entry at or after the earliest in-flight rewrite's timestamp
        // — otherwise the rewrite, when it eventually arrives, would be silently
        // dropped by writeEntries' `>= lastFlushedTimestamp` guard.
        let inflightFloor = inflightRewriteTimestamps.min() ?? .greatestFiniteMagnitude

        let ready = pendingEntries
            .filter { $0.timestamp <= cutoff && $0.timestamp < inflightFloor }
            .sorted()
        pendingEntries.removeAll { $0.timestamp <= cutoff && $0.timestamp < inflightFloor }

        writeEntries(ready)
    }

    private func flushAllEntries() {
        let sorted = pendingEntries.sorted()
        pendingEntries.removeAll()
        writeEntries(sorted)
    }

    private func writeEntries(_ entries: [TranscriptEntry]) {
        guard let handle = transcriptHandle else { return }
        var data = Data()
        var newestProcessedTimestamp = lastFlushedTimestamp
        for entry in entries {
            guard entry.timestamp >= lastFlushedTimestamp else { continue }
            newestProcessedTimestamp = max(newestProcessedTimestamp, entry.timestamp)
            guard shouldWriteEntry(entry) else { continue }
            let line = TranscriptFormatter.entry(
                speaker: entry.speaker,
                timestamp: entry.timestamp,
                text: entry.text
            )
            data.append(Data(line.utf8))
            streamingEntryCount += 1
            streamingEntrySources.insert(entry.source)
            finalTranscriptEntries.append(entry)
        }
        if !data.isEmpty {
            handle.write(data)
        }
        lastFlushedTimestamp = newestProcessedTimestamp
    }

    /// Build a high-accuracy render if it covers every source the streaming
    /// transcript captured. The caller owns writing it so the offline identity pass
    /// can replace labels from the returned exact entries before summaries are made.
    private func highAccuracyTranscript(header: String) async -> RenderedTranscript? {
        guard let sessionDirectory else { return nil }

        do {
            let entries = try await highAccuracyTranscriptEntries(sessionDirectory: sessionDirectory)
            guard !entries.isEmpty else { return nil }

            let rendered = renderTranscript(header: header, entries: entries)
            guard rendered.entryCount > 0, rendered.text != header else { return nil }
            guard shouldReplaceStreamingTranscript(with: rendered) else {
                NSLog("[SerialNotes/Transcription] keeping streaming transcript because final pass missed a recorded source")
                return nil
            }
            return rendered
        } catch {
            NSLog("[SerialNotes/Transcription] high-accuracy final transcript skipped: \(error.localizedDescription)")
            return nil
        }
    }

    private func highAccuracyTranscriptEntries(sessionDirectory: URL) async throws -> [TranscriptEntry] {
        let models = try await finalAsrModels()

        let micURL = sessionDirectory.appendingPathComponent("mic.wav")
        let systemURL = sessionDirectory.appendingPathComponent("system.wav")
        async let micEntries = highAccuracyEntriesIfPresent(
            from: micURL,
            models: models,
            asrSource: .microphone,
            transcriptSource: .mic
        )
        async let systemEntries = highAccuracyEntriesIfPresent(
            from: systemURL,
            models: models,
            asrSource: .system,
            transcriptSource: .system
        )

        let entries = try await (micEntries, systemEntries)
        return (entries.0 + entries.1).sorted()
    }

    private func highAccuracyEntriesIfPresent(
        from url: URL,
        models: AsrModels,
        asrSource: AudioSource,
        transcriptSource: AudioSide
    ) async throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard finalAudioIsLongEnough(url) else {
            NSLog("[SerialNotes/Transcription] skipping final ASR for short audio file: \(url.lastPathComponent)")
            return []
        }

        do {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let result = try await manager.transcribe(url, source: asrSource)
            return finalEntries(from: result, source: transcriptSource)
        } catch ASRError.invalidAudioData {
            NSLog("[SerialNotes/Transcription] skipping final ASR for invalid audio file: \(url.lastPathComponent)")
            return []
        }
    }

    private func finalEntries(from result: ASRResult, source: AudioSide) -> [TranscriptEntry] {
        FinalTranscriptSegmenter.segments(from: result).map { segment in
            return TranscriptEntry(
                source: source,
                speaker: currentSpeaker(for: source, at: segment.midpoint),
                text: segment.text,
                timestamp: segment.start
            )
        }
    }

    private func renderTranscript(header: String, entries: [TranscriptEntry]) -> RenderedTranscript {
        // The final pass holds every entry, so we can use dominance-aware
        // cross-channel echo removal instead of the streaming path's incremental,
        // one-directional heuristic — this also catches system-side echo of the
        // local user (phantom "Person N") that the streaming filter can't touch.
        let sorted = entries.sorted()
        let filtered = CrossChannelEchoFilter.filterEchoes(
            sorted,
            windowSeconds: Self.echoFilterWindowSeconds,
            containmentThreshold: Self.echoFilterContainmentThreshold,
            minWords: Self.echoFilterMinWords
        )

        // On a remote call (system audio present), collapse the mic to the single
        // primary speaker (the user's preferred name, or "You") so any echo the filter
        // missed isn't surfaced as a phantom "Voice N". Must run after the filter — see
        // normalizeMicLabels. In-person sessions (no system audio) skip this so
        // co-located speakers keep distinct labels.
        let systemAudioActive = sorted.contains { $0.source == .system }
        let kept = CrossChannelEchoFilter.normalizeMicLabels(
            filtered,
            collapseToPrimary: systemAudioActive,
            primaryName: micPrimaryName,
            enrolledMicNames: enrolledMicNames
        )

        return RenderedTranscript(
            text: renderEntries(header: header, entries: kept),
            entryCount: kept.count,
            sources: Set(kept.map(\.source)),
            entries: kept
        )
    }

    /// Render an already-filtered/attributed set of exact entries without applying
    /// echo filtering again. Used after offline re-attribution, which must preserve
    /// the final render's source membership while only changing system labels.
    private func renderEntries(header: String, entries: [TranscriptEntry]) -> String {
        var transcript = header
        for entry in entries.sorted() {
            transcript += TranscriptFormatter.entry(
                speaker: entry.speaker,
                timestamp: entry.timestamp,
                text: entry.text
            )
        }
        return transcript
    }

    @discardableResult
    private func writeTranscript(_ text: String, in directory: URL?) -> Bool {
        guard let directory else { return false }
        do {
            try text.write(
                to: directory.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            onError?(error)
            return false
        }
    }

    private func rewriteTranscriptHeader(_ header: String, in directory: URL) {
        do {
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("transcript.md"))
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            handle.write(Data(header.utf8))
        } catch {
            onError?(error)
        }
    }

    private func shouldReplaceStreamingTranscript(with rendered: RenderedTranscript) -> Bool {
        guard streamingEntryCount > 0 else { return true }
        return streamingEntrySources.isSubset(of: rendered.sources)
    }

    private func shouldWriteEntry(_ entry: TranscriptEntry) -> Bool {
        switch entry.source {
        case .system:
            streamingEchoContext.recordSystemEntry(
                entry,
                lookbackSeconds: Self.echoSuppressionLookbackSeconds,
                maxEntries: Self.maxEchoSuppressionSystemEntries
            )
            return true
        case .mic:
            return !streamingEchoContext.shouldSuppressMicEntry(
                entry,
                lookbackSeconds: Self.echoSuppressionLookbackSeconds
            )
        }
    }

    // MARK: - Final ASR

    private func prefetchFinalAsrModelsIfNeeded() {
        guard cachedFinalAsrModels == nil else { return }
        guard finalAsrModelsTask == nil else { return }
        finalAsrModelsTask = Task {
            try await AsrModels.downloadAndLoad(
                configuration: ModelComputePolicy.configuration(),
                version: .v2
            )
        }
    }

    private func finalAsrModels() async throws -> AsrModels {
        if let cachedFinalAsrModels {
            return cachedFinalAsrModels
        }
        prefetchFinalAsrModelsIfNeeded()
        guard let task = finalAsrModelsTask else {
            throw TranscriptionError.modelsNotLoaded
        }

        do {
            let models = try await task.value
            cachedFinalAsrModels = models
            finalAsrModelsTask = nil
            return models
        } catch {
            finalAsrModelsTask = nil
            throw error
        }
    }

    // MARK: - Helpers

    private func sideState(for source: AudioSide) -> SideState {
        if let state = sideStates[source] { return state }
        let state = SideState()
        sideStates[source] = state
        return state
    }

    private func addAudio(
        _ buffer: AVAudioPCMBuffer,
        to diarizer: LSEENDDiarizer,
        sourceSampleRate: Double
    ) throws {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let data = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: frameCount)
        try diarizer.addAudio(samples, sourceSampleRate: sourceSampleRate)
    }

    private nonisolated func shouldProcessDiarizer(
        samplesSinceProcess: Int,
        sampleRate: Double
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        return samplesSinceProcess >= Int(sampleRate * Self.diarizerProcessInterval)
    }

    private func currentAudioTime() -> TimeInterval {
        let times = AudioSide.allCases.map { source -> TimeInterval in
            guard let state = sideStates[source] else { return 0 }
            guard state.sampleRate > 0 else { return 0 }
            return TimeInterval(state.samplesProcessed) / state.sampleRate
        }
        // Use the leading stream as the session clock so one active side can flush while the other is silent or unavailable.
        return times.max() ?? 0
    }

    private nonisolated func finalAudioIsLongEnough(_ url: URL) -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return false }
            let duration = Double(audioFile.length) / sampleRate
            return duration >= Self.minimumFinalAudioDuration
        } catch {
            return false
        }
    }

    private nonisolated func midpointTime(
        lastEndSamples: Int,
        currentSamples: Int,
        sampleRate: Double
    ) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let midSample = (lastEndSamples + currentSamples) / 2
        return TimeInterval(midSample) / sampleRate
    }

}

// MARK: - Supporting Types

enum AudioSide: CaseIterable, Hashable, Sendable {
    case mic
    case system

    var sortOrder: Int {
        switch self {
        case .system: return 0
        case .mic: return 1
        }
    }

    var logName: String {
        switch self {
        case .mic: return "mic"
        case .system: return "system"
        }
    }
}

private final class SideState {
    var asr: StreamingEouAsrManager?
    var diarizer: LSEENDDiarizer?
    var samplesProcessed = 0
    var sampleRate: Double = 0
    var lastUtteranceEndSamples = 0
    var diarizerSamplesSinceProcess = 0
    var speakerLabels: [Int: String] = [:]
    var nextSystemPersonNumber = 1
    var micSeenPrimarySpeaker = false
    var nextMicVoiceNumber = 2
    var streamingASRConsecutiveFailures = 0
    var diarizerConsecutiveFailures = 0

    func resetSession() {
        samplesProcessed = 0
        sampleRate = 0
        lastUtteranceEndSamples = 0
        diarizerSamplesSinceProcess = 0
        speakerLabels = [:]
        nextSystemPersonNumber = 1
        micSeenPrimarySpeaker = false
        nextMicVoiceNumber = 2
        streamingASRConsecutiveFailures = 0
        diarizerConsecutiveFailures = 0
    }
}

private struct RenderedTranscript {
    let text: String
    let entryCount: Int
    let sources: Set<AudioSide>
    let entries: [TranscriptEntry]
}

private struct SendableError: @unchecked Sendable {
    let error: any Error
}

private enum OfflineIdentityRaceOutcome: Sendable {
    case success([IdentifiedSpeaker])
    case failure(SendableError)
    case timedOut
}

private actor OfflineIdentityRaceGate {
    private var didResume = false
    private let continuation: CheckedContinuation<OfflineIdentityRaceOutcome, Never>

    init(_ continuation: CheckedContinuation<OfflineIdentityRaceOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: OfflineIdentityRaceOutcome) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: outcome)
    }
}

private extension Duration {
    var secondsValue: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

// TranscriptEntry + EchoSuppressionContext live in EchoSuppressionContext.swift —
// both the streaming pipeline (this actor) and the final-render pass need them.

enum TranscriptionError: LocalizedError {
    case modelsNotLoaded
    case streamingTranscriptionDegraded

    static func userFacingDescription(for error: Error) -> String {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError.localizedDescription
        }

        let description = error.localizedDescription
        if isCoreMLPredictionFailure(description) {
            return TranscriptionError.streamingTranscriptionDegraded.localizedDescription
        }
        return description
    }

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "Transcription models have not been downloaded yet."
        case .streamingTranscriptionDegraded:
            return "Live transcription hit repeated model errors. Recording will continue, but the transcript may be incomplete."
        }
    }

    private static func isCoreMLPredictionFailure(_ description: String) -> Bool {
        let lowercased = description.lowercased()
        return lowercased.contains("ml program") && lowercased.contains("prediction")
    }
}

/// A single voice enrollment, handed to the transcription service at session start
/// so the diarizer can label matching voices by name instead of "Person N" / "You".
struct EnrollmentClip: Sendable {
    let name: String
    let side: AudioSide
    let samples: [Float]
    let sampleRate: Double
}
