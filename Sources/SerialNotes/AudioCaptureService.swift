import AVFoundation
import CoreAudio
import ScreenCaptureKit
import SystemAudioTap
import os

/// Which capture path this session used — reported in session diagnostics.
enum AudioCapturePath: String, Codable, Sendable {
    case processTap
    case screenCaptureKit
}

/// Per-stream statistics captured during the session.
struct AudioStreamStats: Codable, Sendable {
    var bufferCount: Int = 0
    var sampleCount: Int = 0
    var sampleRate: Double = 0
    var voiceProcessingEnabled: Bool = false
}

struct AudioCaptureStats: Codable, Sendable {
    var path: AudioCapturePath?
    var system = AudioStreamStats()
    var mic = AudioStreamStats()
}

struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    /// Payload size in bytes. The feed pipeline's backlog accounting adds and
    /// subtracts this same value, so both sides must share one definition.
    var byteCount: Int {
        Int(buffer.frameLength) * MemoryLayout<Float>.size * Int(buffer.format.channelCount)
    }
}

/// Seam over the capture engine, so lifecycle tests can drive `RecordingState`
/// with a scripted capture. `AudioCaptureService` is the production conformer.
protocol AudioCapturing: Sendable {
    func startCapture(sessionDir: URL, callbacks: AudioCaptureCallbacks) async throws
    func stopCapture() async
    func currentStats() -> AudioCaptureStats
}

/// Per-session delivery targets for capture output. Captured **by value** at
/// `startCapture` (via the per-capture `CaptureContext`) — never read from
/// mutable service state at delivery time. A straggler callback from a previous
/// capture can therefore only reach its own session's (already finished) feed,
/// never the next session's.
struct AudioCaptureCallbacks: Sendable {
    let onSystemAudioBuffer: @Sendable (CapturedAudioBuffer) -> Void
    let onMicAudioBuffer: @Sendable (CapturedAudioBuffer) -> Void
    let onError: @Sendable (Error) -> Void
}

/// Per-capture home of every delivery-time sink — the WAV file handles, the
/// stream stats, and the session's callbacks. The IOProc block, the mic tap,
/// and the SCK relay each hold their capture's context by value, so a straggler
/// delivery from a stopped capture can only ever write into its own (already
/// closed) files and its own stats — never a successor's. `AudioCaptureService`
/// keeps only engine/tap lifetime state.
final class CaptureContext: @unchecked Sendable {
    enum Sink { case system, mic }

    let callbacks: AudioCaptureCallbacks
    private let lock = NSLock()
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    /// Session dir for the SCK path's lazily-created system.wav (see
    /// `ensureSystemFileForSCK`).
    private var sckSystemFileDir: URL?
    private let statsLock = OSAllocatedUnfairLock(initialState: AudioCaptureStats())

    init(callbacks: AudioCaptureCallbacks) {
        self.callbacks = callbacks
    }

    func setSystemFile(_ file: AVAudioFile) {
        lock.withLock { systemAudioFile = file }
    }

    func setMicFile(_ file: AVAudioFile) {
        lock.withLock { micAudioFile = file }
    }

    func setSCKSystemFileDir(_ dir: URL) {
        lock.withLock { sckSystemFileDir = dir }
    }

    /// Close the file handles. Stats stay readable (the service snapshots them
    /// for post-session diagnostics); further writes silently no-op.
    func closeFiles() {
        lock.withLock {
            systemAudioFile = nil
            micAudioFile = nil
            sckSystemFileDir = nil
        }
    }

    func write(_ buffer: AVAudioPCMBuffer, to sink: Sink) {
        lock.withLock {
            let file = sink == .system ? systemAudioFile : micAudioFile
            guard let file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                callbacks.onError(error)
            }
        }
    }

    var stats: AudioCaptureStats {
        statsLock.withLock { $0 }
    }

    func setPath(_ path: AudioCapturePath) {
        statsLock.withLock { $0.path = path }
    }

    func setMicVoiceProcessing(_ enabled: Bool) {
        statsLock.withLock { $0.mic.voiceProcessingEnabled = enabled }
    }

    @discardableResult
    func recordStats(frames: Int, rate: Double, sink: Sink) -> Bool {
        statsLock.withLock {
            let wasFirst: Bool
            switch sink {
            case .system:
                wasFirst = $0.system.bufferCount == 0
                $0.system.bufferCount += 1
                $0.system.sampleCount += frames
                $0.system.sampleRate = rate
            case .mic:
                wasFirst = $0.mic.bufferCount == 0
                $0.mic.bufferCount += 1
                $0.mic.sampleCount += frames
                $0.mic.sampleRate = rate
            }
            return wasFirst
        }
    }

    /// Convert CMSampleBuffer to AVAudioPCMBuffer, write it, and deliver it
    /// (SCK fallback only).
    func writeSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        to sink: Sink,
        callback: @Sendable (CapturedAudioBuffer) -> Void
    ) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd),
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Ensure we have float channel data (SCK should always deliver float32)
        guard let destPtr = pcmBuffer.floatChannelData?[0] else { return }

        let bytesToCopy = min(dataLength, Int(pcmBuffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame))
        memcpy(destPtr, dataPointer, bytesToCopy)

        // System audio (SCK path) creates system.wav lazily so the file header
        // is stamped with the rate actually delivered, not the requested 48 kHz.
        if sink == .system {
            ensureSystemFileForSCK(matching: format)
        }
        write(pcmBuffer, to: sink)

        callback(CapturedAudioBuffer(buffer: pcmBuffer))
    }

    /// Lazily create the SCK path's `system.wav` using the rate SCK *actually*
    /// delivers. The `SCStreamConfiguration` only requests a rate; SCK can
    /// resample to something else (notably 24 kHz on Bluetooth/HFP "call mode"),
    /// and stamping the header with the delivered rate keeps playback duration
    /// honest so the diarizer + ASR second pass aren't time-warped. Channels
    /// stay mono — only the rate is taken from the buffer.
    private func ensureSystemFileForSCK(matching deliveredFormat: AVAudioFormat) {
        lock.withLock {
            guard systemAudioFile == nil, let dir = sckSystemFileDir else { return }
            let writeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: deliveredFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) ?? deliveredFormat
            do {
                systemAudioFile = try AVAudioFile(
                    forWriting: dir.appendingPathComponent("system.wav"),
                    settings: writeFormat.settings
                )
                NSLog("[SerialNotes/Capture] SCK system.wav created at delivered rate \(deliveredFormat.sampleRate)")
            } catch {
                callbacks.onError(error)
            }
        }
    }
}

final class AudioCaptureService: NSObject, AudioCapturing, @unchecked Sendable {
    private var tapInfo = SystemAudioTapInfo(tapID: 0, aggregateDeviceID: 0)
    private var systemIOProcID: AudioDeviceIOProcID?
    private var micEngine: AVAudioEngine?

    // Fallback for when process tap is unavailable
    private var stream: SCStream?
    /// Per-capture SCK output/delegate relay — holds this session's context by
    /// value (SCStream's delegate is weak, so the service keeps the relay alive).
    private var sckRelay: SCKStreamRelay?

    /// The in-flight capture's sinks; nil between captures. All delivery paths
    /// hold this by value — the service never routes a buffer itself.
    private var activeContext: CaptureContext?
    /// Stats of the most recently *finished* capture, so `currentStats()` keeps
    /// answering after `stopCapture` (session.json is written post-teardown).
    private var lastStats = AudioCaptureStats()

    private static let sampleRate: Double = 48000
    private static let channelCount: AVAudioChannelCount = 1

    // Capture diagnostics — read after stopCapture() to write session.json.
    /// Snapshot of stats since the last startCapture() call.
    func currentStats() -> AudioCaptureStats {
        activeContext?.stats ?? lastStats
    }

    // MARK: - Public API

    func startCapture(sessionDir: URL, callbacks: AudioCaptureCallbacks) async throws {
        let context = CaptureContext(callbacks: callbacks)
        activeContext = context

        // Request mic permission upfront — accessing AVAudioEngine.inputNode
        // without permission can crash.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)

        if IsSystemAudioTapAvailable() {
            do {
                try startWithProcessTap(sessionDir: sessionDir, micGranted: micGranted, context: context)
                context.setPath(.processTap)
                return
            } catch {
                // Process tap failed — clean up partial state, fall through to SCK.
                // The context's file handles must be closed too: a system.wav the
                // tap path already created carries the TAP's sample rate, and if
                // it survived, ensureSystemFileForSCK would no-op and SCK audio
                // would be written into a wrong-rate (or format-mismatched) file.
                cleanupEngines()
                context.closeFiles()
            }
        }
        try await startWithScreenCaptureKit(sessionDir: sessionDir, micGranted: micGranted, context: context)
        context.setPath(.screenCaptureKit)
    }

    func stopCapture() async {
        cleanupEngines()

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        if let context = activeContext {
            lastStats = context.stats
            context.closeFiles()
            activeContext = nil
        }
        sckRelay = nil
    }

    // MARK: - Process Tap (Primary — triggers "System Audio Recording Only")

    private func startWithProcessTap(sessionDir: URL, micGranted: Bool, context: CaptureContext) throws {
        let info = CreateSystemAudioTap()
        guard info.tapID != 0, info.aggregateDeviceID != 0 else {
            NSLog("[SerialNotes/Capture] processTap path: tap creation returned zero IDs — falling back")
            throw AudioCaptureError.processTapFailed
        }
        tapInfo = info
        NSLog("[SerialNotes/Capture] processTap path: tap=\(info.tapID) agg=\(info.aggregateDeviceID)")

        // --- System Audio via raw AudioDeviceIOProc ---
        // AVAudioEngine + installTap doesn't reliably surface sub-tap audio
        // from a tap-aggregate device. Use a raw IOProc so the audio HAL
        // delivers buffers directly.
        //
        // Both starts can throw: the IOProc setup leaves a running real-time
        // thread + aggregate device behind on success, so a subsequent mic
        // failure must tear it all down before the throw propagates. The SCK
        // path mirrors this pattern.
        do {
            try startSystemAudioIOProc(sessionDir: sessionDir, aggDeviceID: info.aggregateDeviceID, context: context)
            try startMicrophoneEngine(sessionDir: sessionDir, micGranted: micGranted, context: context)
        } catch {
            cleanupEngines()
            throw error
        }
    }

    // MARK: - System Audio IOProc (raw HAL — bypasses AVAudioEngine)

    private func startSystemAudioIOProc(sessionDir: URL, aggDeviceID: AudioDeviceID, context: CaptureContext) throws {
        // Query the aggregate's input stream format so we know the rate the
        // tap is delivering at. The format is determined by the tap + clock
        // sub-device.
        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            aggDeviceID, &formatAddr, 0, nil, &formatSize, &streamFormat)
        guard formatStatus == noErr, streamFormat.mSampleRate > 0, streamFormat.mChannelsPerFrame > 0 else {
            NSLog("[SerialNotes/Capture] failed to query agg input format status=\(formatStatus) sr=\(streamFormat.mSampleRate) ch=\(streamFormat.mChannelsPerFrame)")
            throw AudioCaptureError.audioUnitConfigFailed
        }
        // The stream format tells us channel layout + interleaving, but its sample
        // rate can be a stale advertised value that doesn't match what the IOProc
        // actually delivers: with Bluetooth output (e.g. AirPods) the device clocks
        // at 24 kHz while the stream format still reports 48 kHz. The IOProc delivers
        // at the aggregate's *nominal* (running) rate, so trust that for the write
        // header — a wrong rate writes every system.wav at the wrong speed (pitched
        // up) and feeds time-warped audio to the diarizer + ASR.
        let streamFormatRate = streamFormat.mSampleRate
        let nominalRate = Self.nominalSampleRate(of: aggDeviceID)
        let sourceSampleRate = nominalRate ?? streamFormatRate
        let sourceChannels = AVAudioChannelCount(streamFormat.mChannelsPerFrame)
        let sourceIsInterleaved = (streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        NSLog("[SerialNotes/Capture] agg format: streamFormatRate=\(streamFormatRate) nominalRate=\(nominalRate.map { String($0) } ?? "nil") ch=\(sourceChannels) interleaved=\(sourceIsInterleaved) → using \(sourceSampleRate)")

        // Write file format: mono float32 at the source rate.
        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!

        let systemFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.wav"),
            settings: writeFormat.settings
        )
        context.setSystemFile(systemFile)

        // Per-cycle conversion buffer — sized for max expected frames.
        // The HAL block fires with whatever the device's IO block size is
        // (commonly 512–4096 frames).
        let pcmCapacity: AVAudioFrameCount = 8192

        let ioQueue = DispatchQueue(label: "com.serialnotes.system-ioproc", qos: .userInteractive)

        // The block captures only its capture's context — it never touches the
        // (shared, single-instance) service, so a straggler invocation across a
        // stop/start boundary cannot reach a successor's files or stats.
        let onSystemAudioBuffer = context.callbacks.onSystemAudioBuffer

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggDeviceID,
            ioQueue
        ) { (_, inputData, _, _, _) in
            let abl = inputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let firstBuffer = withUnsafePointer(to: inputData.pointee.mBuffers) { $0.pointee }
            guard let mData = firstBuffer.mData else { return }
            let channels = max(Int(firstBuffer.mNumberChannels), 1)
            let bytesPerFrame = MemoryLayout<Float>.size * (sourceIsInterleaved ? channels : 1)
            let totalBytes = Int(firstBuffer.mDataByteSize)
            let frameCount = totalBytes / max(bytesPerFrame, 1)
            guard frameCount > 0 else { return }

            guard let pcm = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: pcmCapacity) else { return }
            let writeFrames = min(frameCount, Int(pcmCapacity))
            pcm.frameLength = AVAudioFrameCount(writeFrames)
            guard let dest = pcm.floatChannelData?[0] else { return }

            let src = mData.bindMemory(to: Float.self, capacity: frameCount * channels)
            if channels == 1 {
                dest.update(from: src, count: writeFrames)
            } else if sourceIsInterleaved {
                // Mix interleaved multichannel down to mono by averaging.
                for f in 0..<writeFrames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += src[f * channels + c]
                    }
                    dest[f] = sum / Float(channels)
                }
            } else {
                // Non-interleaved multichannel in a single AudioBuffer: floatChannelData
                // isn't laid out for per-channel access here, so we take buffer 0's
                // contiguous span as a mono source. (Common for taps.)
                dest.update(from: src, count: writeFrames)
            }

            let isFirst = context.recordStats(frames: writeFrames, rate: sourceSampleRate, sink: .system)
            if isFirst {
                NSLog("[SerialNotes/Capture] system IOProc FIRST buffer frames=\(writeFrames) sr=\(sourceSampleRate)")
            }
            context.write(pcm, to: .system)
            onSystemAudioBuffer(CapturedAudioBuffer(buffer: pcm))
        }
        guard createStatus == noErr, let procID else {
            NSLog("[SerialNotes/Capture] AudioDeviceCreateIOProcIDWithBlock failed status=\(createStatus)")
            throw AudioCaptureError.audioUnitConfigFailed
        }
        systemIOProcID = procID

        let startStatus = AudioDeviceStart(aggDeviceID, procID)
        guard startStatus == noErr else {
            NSLog("[SerialNotes/Capture] AudioDeviceStart failed status=\(startStatus)")
            AudioDeviceDestroyIOProcID(aggDeviceID, procID)
            systemIOProcID = nil
            throw AudioCaptureError.audioUnitConfigFailed
        }
        NSLog("[SerialNotes/Capture] system IOProc started on aggDevice=\(aggDeviceID)")
    }

    // MARK: - ScreenCaptureKit Fallback

    private func startWithScreenCaptureKit(sessionDir: URL, micGranted: Bool, context: CaptureContext) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        // system.wav is created lazily on the first delivered sample buffer
        // (CaptureContext.ensureSystemFileForSCK) so its header is stamped with
        // the rate SCK *actually* delivers.
        context.setSCKSystemFileDir(sessionDir)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = false
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Int(Self.channelCount)
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let outputQueue = DispatchQueue(label: "com.serialnotes.audio-capture")
        // The relay holds this capture's context by value so SCK's delegate
        // paths (sample output *and* didStopWithError) are session-scoped.
        // SCStream's delegate is weak — the service retains it.
        let relay = SCKStreamRelay(context: context)
        let stream = SCStream(filter: filter, configuration: config, delegate: relay)
        try stream.addStreamOutput(relay, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        self.sckRelay = relay

        do {
            try startMicrophoneEngine(sessionDir: sessionDir, micGranted: micGranted, context: context)
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            self.sckRelay = nil
            throw error
        }
    }

    // MARK: - Microphone Engine

    private func startMicrophoneEngine(sessionDir: URL, micGranted: Bool, context: CaptureContext) throws {
        guard micGranted else { return }

        let micEng = AVAudioEngine()
        let micInputNode = micEng.inputNode
        disableVoiceProcessing(on: micInputNode, context: context)

        let micHwFormat = micInputNode.outputFormat(forBus: 0)
        guard micHwFormat.channelCount > 0, micHwFormat.sampleRate > 0 else {
            return // No mic available — continue with system audio only
        }

        let micTapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: micHwFormat.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )!

        let micFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("mic.wav"),
            settings: micTapFormat.settings
        )
        context.setMicFile(micFile)

        // The tap closure captures only the context — see the IOProc comment.
        let onMicAudioBuffer = context.callbacks.onMicAudioBuffer
        micInputNode.installTap(onBus: 0, bufferSize: 4096, format: micTapFormat) { buffer, _ in
            context.write(buffer, to: .mic)
            context.recordStats(frames: Int(buffer.frameLength), rate: micTapFormat.sampleRate, sink: .mic)
            if let ownedBuffer = Self.copyBuffer(buffer) {
                onMicAudioBuffer(CapturedAudioBuffer(buffer: ownedBuffer))
            }
        }
        try micEng.start()
        micEngine = micEng
    }

    private func disableVoiceProcessing(on inputNode: AVAudioInputNode, context: CaptureContext) {
        // VPIO engages the system Voice Processing AU, which ducks the default
        // output stream so AEC can use it as a reference. That ducking is
        // audible as Zoom/Meet/etc. dropping in volume during recording. We
        // capture system audio on its own tap stream and transcribe both sides
        // independently, so AEC on the mic isn't needed.
        if inputNode.isVoiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(false)
            } catch {
                NSLog("[SerialNotes/Capture] could not disable mic voice processing: \(error.localizedDescription)")
            }
        }
        context.setMicVoiceProcessing(inputNode.isVoiceProcessingEnabled)
    }

    // MARK: - Cleanup

    private func cleanupEngines() {
        if let procID = systemIOProcID, tapInfo.aggregateDeviceID != 0 {
            AudioDeviceStop(tapInfo.aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(tapInfo.aggregateDeviceID, procID)
        }
        systemIOProcID = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        if tapInfo.tapID != 0 {
            DestroySystemAudioTap(tapInfo)
            tapInfo = SystemAudioTapInfo(tapID: 0, aggregateDeviceID: 0)
        }
    }

    /// The device's nominal (running) sample rate — the true rate its IOProc
    /// delivers at. Preferred over a stream-format rate, which can advertise a
    /// stale value (notably Bluetooth output running at 24 kHz while reporting 48 kHz).
    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = buffer.frameLength
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData else {
            return nil
        }

        copy.frameLength = frameLength
        let frameCount = Int(frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            destination[channel].update(from: source[channel], count: frameCount)
        }
        return copy
    }

}

// MARK: - SCK relay (fallback)

/// Per-capture SCStream output + delegate. Holds its capture's context by value
/// so both sample delivery and `didStopWithError` are session-scoped — a
/// straggler from a stopped stream can't feed, write into, or error the next
/// session.
private final class SCKStreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let context: CaptureContext

    init(context: CaptureContext) {
        self.context = context
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }
        let rate = asbd.pointee.mSampleRate
        switch type {
        case .audio:
            context.writeSampleBuffer(sampleBuffer, to: .system, callback: context.callbacks.onSystemAudioBuffer)
            context.recordStats(frames: frames, rate: rate, sink: .system)
        case .microphone:
            context.writeSampleBuffer(sampleBuffer, to: .mic, callback: context.callbacks.onMicAudioBuffer)
            context.recordStats(frames: frames, rate: rate, sink: .mic)
        case .screen:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        context.callbacks.onError(error)
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case noDisplayFound
    case processTapFailed
    case audioUnitConfigFailed
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for audio capture."
        case .processTapFailed:
            return "Failed to create system audio tap. Check System Audio Recording permission in System Settings."
        case .audioUnitConfigFailed:
            return "Failed to configure audio input device."
        case .microphoneUnavailable:
            return "Microphone is unavailable. Check microphone permission in System Settings."
        }
    }
}
