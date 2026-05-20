@preconcurrency import AVFoundation
import FluidAudio
import Foundation

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
    /// Falls through to lazy construction in `spliceSummarySections` if the
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
    private var cachedFinalAsrModels: AsrModels?
    private var finalAsrModelsTask: Task<AsrModels, Error>?

    private var pendingEntries: [TranscriptEntry] = []
    private var streamingEchoContext = EchoSuppressionContext()
    private var streamingEntryCount = 0
    private var streamingEntrySources = Set<AudioSide>()
    private var lastFlushedTimestamp: TimeInterval = 0
    private static let flushDelaySeconds: TimeInterval = 3.0
    private static let echoSuppressionLookbackSeconds: TimeInterval = 30 * 60
    private static let maxEchoSuppressionSystemEntries = 64
    private static let minimumFinalAudioDuration: TimeInterval = 1.0
    private static let diarizerProcessInterval: TimeInterval = 0.75
    private static let streamingErrorReportThreshold = 5

    private var modelsLoaded = false

    // MARK: - Model Lifecycle

    func downloadModelsIfNeeded() async throws {
        guard !modelsLoaded else {
            prefetchFinalAsrModelsIfNeeded()
            return
        }

        let micManager = StreamingEouAsrManager()
        let sysManager = StreamingEouAsrManager()
        try await micManager.loadModels()
        try await sysManager.loadModels()

        let sysDia = LSEENDDiarizer()
        try await sysDia.initialize()
        let micDia = LSEENDDiarizer()
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
        summarySettings: SummarySettings.Snapshot = .disabled
    ) async throws {
        guard modelsLoaded else {
            throw TranscriptionError.modelsNotLoaded
        }

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
        for clip in enrollments {
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

    func endSession(
        summarySettings: SummarySettings.Snapshot = .disabled,
        keepAudioFiles: Bool = true,
        summaryCutoff: TimeInterval? = nil
    ) async {
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

        let replacedWithHighAccuracyTranscript = await replaceTranscriptWithHighAccuracyVersion(header: finalHeader)

        // Streaming path: rewrite header with real duration in place, then close
        // the handle so the summary step can read the final file back.
        if !replacedWithHighAccuracyTranscript {
            if let handle = transcriptHandle {
                do {
                    try handle.seek(toOffset: 0)
                    handle.write(Data(finalHeader.utf8))
                } catch {
                    onError?(error)
                }
            }
            try? transcriptHandle?.close()
        }
        transcriptHandle = nil

        // Both paths leave a finalized transcript on disk — splice summary +
        // action items between the header and the first entry when requested.
        if let directory = sessionDirectory {
            await spliceSummarySections(
                sessionDirectory: directory,
                header: finalHeader,
                settings: summarySettings,
                summaryCutoff: summaryCutoff
            )
            if !keepAudioFiles {
                // Must run after high-accuracy ASR and summary splice — both read the raw audio.
                deleteAudioFiles(in: directory)
            }
        }

        sessionStart = nil
        sessionDate = nil
        sessionDirectory = nil
        rewriter = nil
        summarizer = nil
        activeSessionID = nil
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

    private func spliceSummarySections(
        sessionDirectory: URL,
        header: String,
        settings: SummarySettings.Snapshot,
        summaryCutoff: TimeInterval?
    ) async {
        guard settings.generateSummary || settings.generateActionItems else { return }
        // Prefer the prewarmed summarizer from startSession; fall back to a
        // fresh one if the user enabled summary after recording started.
        guard let summarizer = summarizer ?? TranscriptSummarizerFactory.make() else { return }

        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
        guard let fileText = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
        guard fileText.hasPrefix(header) else { return }

        let body = String(fileText.dropFirst(header.count))
        let summaryBody = TranscriptFormatter.summaryInput(from: body, cutoff: summaryCutoff)
        let trimmedSummaryBody = summaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummaryBody.isEmpty else { return }

        // Idempotency: if a previous endSession (or future regenerate-summary
        // call) already spliced sections in, skip rather than prepending a
        // second set and re-running FM on a transcript that already has them.
        if body.contains("## Summary\n") || body.contains("## Action items\n") {
            return
        }

        let result = await summarizer.summarize(
            transcript: trimmedSummaryBody,
            generateSummary: settings.generateSummary,
            generateActionItems: settings.generateActionItems
        )

        let sections = TranscriptFormatter.summarySections(result)
        guard !sections.isEmpty else { return }

        let newContent = header + sections + body
        do {
            try newContent.write(to: transcriptURL, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            NSLog("[SerialNotes/Summary] failed to write spliced transcript: \(error.localizedDescription)")
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
            if !state.micSeenPrimarySpeaker {
                label = "You"
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
        }
        if !data.isEmpty {
            handle.write(data)
        }
        lastFlushedTimestamp = newestProcessedTimestamp
    }

    private func replaceTranscriptWithHighAccuracyVersion(header: String) async -> Bool {
        guard let sessionDirectory else { return false }

        do {
            let entries = try await highAccuracyTranscriptEntries(sessionDirectory: sessionDirectory)
            guard !entries.isEmpty else { return false }

            let rendered = renderTranscript(header: header, entries: entries)
            guard rendered.entryCount > 0, rendered.text != header else { return false }
            guard shouldReplaceStreamingTranscript(with: rendered) else {
                NSLog("[SerialNotes/Transcription] keeping streaming transcript because final pass missed a recorded source")
                return false
            }

            try transcriptHandle?.close()
            transcriptHandle = nil

            let transcriptURL = sessionDirectory.appendingPathComponent("transcript.md")
            try rendered.text.write(to: transcriptURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[SerialNotes/Transcription] high-accuracy final transcript skipped: \(error.localizedDescription)")
            return false
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
        var transcript = header
        var renderedEntryCount = 0
        var renderedSources = Set<AudioSide>()
        var echoContext = EchoSuppressionContext()

        for entry in entries.sorted() {
            let shouldRender: Bool
            switch entry.source {
            case .system:
                echoContext.recordSystemEntry(
                    entry,
                    lookbackSeconds: Self.echoSuppressionLookbackSeconds,
                    maxEntries: Self.maxEchoSuppressionSystemEntries
                )
                shouldRender = true
            case .mic:
                shouldRender = !echoContext.shouldSuppressMicEntry(
                    entry,
                    lookbackSeconds: Self.echoSuppressionLookbackSeconds
                )
            }

            guard shouldRender else { continue }
            transcript += TranscriptFormatter.entry(
                speaker: entry.speaker,
                timestamp: entry.timestamp,
                text: entry.text
            )
            renderedEntryCount += 1
            renderedSources.insert(entry.source)
        }
        return RenderedTranscript(text: transcript, entryCount: renderedEntryCount, sources: renderedSources)
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
            try await AsrModels.downloadAndLoad(version: .v2)
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
