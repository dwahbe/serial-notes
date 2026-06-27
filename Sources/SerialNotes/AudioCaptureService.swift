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
}

final class AudioCaptureService: NSObject, @unchecked Sendable {
    private var tapInfo = SystemAudioTapInfo(tapID: 0, aggregateDeviceID: 0)
    private var systemIOProcID: AudioDeviceIOProcID?
    private var micEngine: AVAudioEngine?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private let lock = NSLock()
    private let statsLock = OSAllocatedUnfairLock(initialState: AudioCaptureStats())

    // Fallback for when process tap is unavailable
    private var stream: SCStream?
    /// Session dir for the SCK path's lazily-created system.wav (see
    /// `ensureSystemFileForSCK`). Set when SCK starts, cleared on stop.
    private var sckSystemFileDir: URL?

    private var onError: (@Sendable (Error) -> Void)?

    var onSystemAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    var onMicAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?

    private static let sampleRate: Double = 48000
    private static let channelCount: AVAudioChannelCount = 1

    // Capture diagnostics — read after stopCapture() to write session.json.
    /// Snapshot of stats since the last startCapture() call.
    func currentStats() -> AudioCaptureStats {
        statsLock.withLock { $0 }
    }

    // MARK: - Public API

    func startCapture(sessionDir: URL, onError: @escaping @Sendable (Error) -> Void) async throws {
        self.onError = onError
        statsLock.withLock { $0 = AudioCaptureStats() }

        // Request mic permission upfront — accessing AVAudioEngine.inputNode
        // without permission can crash.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)

        if IsSystemAudioTapAvailable() {
            do {
                try startWithProcessTap(sessionDir: sessionDir, micGranted: micGranted)
                statsLock.withLock { $0.path = .processTap }
                return
            } catch {
                // Process tap failed — clean up partial state, fall through to SCK
                cleanupEngines()
            }
        }
        try await startWithScreenCaptureKit(sessionDir: sessionDir, micGranted: micGranted)
        statsLock.withLock { $0.path = .screenCaptureKit }
    }

    func stopCapture() async {
        cleanupEngines()

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        lock.withLock {
            systemAudioFile = nil
            micAudioFile = nil
            sckSystemFileDir = nil
        }
        onError = nil
        onSystemAudioBuffer = nil
        onMicAudioBuffer = nil
    }

    // MARK: - Process Tap (Primary — triggers "System Audio Recording Only")

    private func startWithProcessTap(sessionDir: URL, micGranted: Bool) throws {
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
            try startSystemAudioIOProc(sessionDir: sessionDir, aggDeviceID: info.aggregateDeviceID)
            try startMicrophoneEngine(sessionDir: sessionDir, micGranted: micGranted)
        } catch {
            cleanupEngines()
            throw error
        }
    }

    // MARK: - System Audio IOProc (raw HAL — bypasses AVAudioEngine)

    private func startSystemAudioIOProc(sessionDir: URL, aggDeviceID: AudioDeviceID) throws {
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
        lock.withLock { systemAudioFile = systemFile }

        // Per-cycle conversion buffer — sized for max expected frames.
        // The HAL block fires with whatever the device's IO block size is
        // (commonly 512–4096 frames).
        let pcmCapacity: AVAudioFrameCount = 8192

        let ioQueue = DispatchQueue(label: "com.serialnotes.system-ioproc", qos: .userInteractive)

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggDeviceID,
            ioQueue
        ) { [weak self] (_, inputData, _, _, _) in
            guard let self else { return }
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

            let isFirst = recordStats(frames: writeFrames, rate: sourceSampleRate, side: .system)
            if isFirst {
                NSLog("[SerialNotes/Capture] system IOProc FIRST buffer frames=\(writeFrames) sr=\(sourceSampleRate)")
            }
            writeBuffer(pcm, for: \.systemAudioFile)
            if let callback = onSystemAudioBuffer {
                callback(CapturedAudioBuffer(buffer: pcm))
            }
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

    private func startWithScreenCaptureKit(sessionDir: URL, micGranted: Bool) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        // system.wav is created lazily on the first delivered sample buffer
        // (ensureSystemFileForSCK) so its header is stamped with the rate SCK
        // *actually* delivers. The config below only *requests* Self.sampleRate;
        // SCK can deliver something else — notably 24 kHz on Bluetooth/HFP "call
        // mode" — and a hardcoded 48 kHz header would write system.wav at the
        // wrong speed (pitched up) and time-warp the diarizer + ASR input. This
        // mirrors the process-tap path trusting the nominal (delivered) rate.
        lock.withLock { sckSystemFileDir = sessionDir }

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
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream

        do {
            try startMicrophoneEngine(sessionDir: sessionDir, micGranted: micGranted)
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            throw error
        }
    }

    // MARK: - Microphone Engine

    private func startMicrophoneEngine(sessionDir: URL, micGranted: Bool) throws {
        guard micGranted else { return }

        let micEng = AVAudioEngine()
        let micInputNode = micEng.inputNode
        disableVoiceProcessing(on: micInputNode)

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
        lock.withLock { micAudioFile = micFile }

        micInputNode.installTap(onBus: 0, bufferSize: 4096, format: micTapFormat) { [weak self] buffer, _ in
            self?.writeBuffer(buffer, for: \.micAudioFile)
            self?.recordStats(frames: Int(buffer.frameLength), rate: micTapFormat.sampleRate, side: .mic)
            if let callback = self?.onMicAudioBuffer,
               let ownedBuffer = Self.copyBuffer(buffer) {
                callback(CapturedAudioBuffer(buffer: ownedBuffer))
            }
        }
        try micEng.start()
        micEngine = micEng
    }

    private func disableVoiceProcessing(on inputNode: AVAudioInputNode) {
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
        let enabled = inputNode.isVoiceProcessingEnabled
        statsLock.withLock { $0.mic.voiceProcessingEnabled = enabled }
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

    // MARK: - Audio Writing

    private func writeBuffer(_ buffer: AVAudioPCMBuffer, for keyPath: KeyPath<AudioCaptureService, AVAudioFile?>) {
        lock.withLock {
            guard let file = self[keyPath: keyPath] else { return }
            do {
                try file.write(from: buffer)
            } catch {
                onError?(error)
            }
        }
    }

    private enum StreamSide { case system, mic }

    @discardableResult
    private func recordStats(frames: Int, rate: Double, side: StreamSide) -> Bool {
        statsLock.withLock {
            let wasFirst: Bool
            switch side {
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

    /// Convert CMSampleBuffer to AVAudioPCMBuffer and write (SCK fallback only)
    private func writeSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        to keyPath: KeyPath<AudioCaptureService, AVAudioFile?>,
        callback: ((@Sendable (CapturedAudioBuffer) -> Void))? = nil
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
        if keyPath == \AudioCaptureService.systemAudioFile {
            ensureSystemFileForSCK(matching: format)
        }
        writeBuffer(pcmBuffer, for: keyPath)

        if let callback {
            callback(CapturedAudioBuffer(buffer: pcmBuffer))
        }
    }

    /// Lazily create the SCK path's `system.wav` using the rate SCK *actually*
    /// delivers. The `SCStreamConfiguration` only requests `Self.sampleRate`;
    /// SCK can resample to something else (notably 24 kHz on Bluetooth/HFP "call
    /// mode"), and stamping the header with the delivered rate keeps playback
    /// duration honest so the diarizer + ASR second pass aren't time-warped.
    /// Channels stay mono (the stream is configured for one channel and the
    /// delivered buffers are mono) — only the rate is taken from the buffer.
    private func ensureSystemFileForSCK(matching deliveredFormat: AVAudioFormat) {
        lock.withLock {
            guard systemAudioFile == nil, let dir = sckSystemFileDir else { return }
            let writeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: deliveredFormat.sampleRate,
                channels: Self.channelCount,
                interleaved: false
            ) ?? deliveredFormat
            do {
                systemAudioFile = try AVAudioFile(
                    forWriting: dir.appendingPathComponent("system.wav"),
                    settings: writeFormat.settings
                )
                NSLog("[SerialNotes/Capture] SCK system.wav created at delivered rate \(deliveredFormat.sampleRate)")
            } catch {
                onError?(error)
            }
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

// MARK: - SCStreamOutput (fallback)

extension AudioCaptureService: SCStreamOutput {
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
            writeSampleBuffer(sampleBuffer, to: \.systemAudioFile, callback: onSystemAudioBuffer)
            recordStats(frames: frames, rate: rate, side: .system)
        case .microphone:
            writeSampleBuffer(sampleBuffer, to: \.micAudioFile, callback: onMicAudioBuffer)
            recordStats(frames: frames, rate: rate, side: .mic)
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate (fallback)

extension AudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
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
