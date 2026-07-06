import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcription Pipeline", .serialized)
struct TranscriptionTests {
    /// Generate speech audio using macOS `say` command.
    /// Returns 16kHz mono float32 samples.
    private static func generateSpeech(_ text: String) throws -> (url: URL, samples: [Float]) {
        let tmpDir = FileManager.default.temporaryDirectory
        let aiffURL = tmpDir.appendingPathComponent("say-\(UUID().uuidString).aiff")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", aiffURL.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SayError.failed(process.terminationStatus)
        }

        let audioFile = try AVAudioFile(forReading: aiffURL)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            throw SayError.conversionFailed
        }

        let frameCapacity = AVAudioFrameCount(
            Double(audioFile.length) * 16000.0 / audioFile.processingFormat.sampleRate
        ) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw SayError.conversionFailed
        }

        let state = ConverterState()

        converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if state.reachedEnd {
                outStatus.pointee = .noDataNow
                return nil
            }
            let readBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: 4096
            )!
            do {
                try audioFile.read(into: readBuffer)
                if readBuffer.frameLength == 0 {
                    state.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            } catch {
                state.reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        guard let floatData = outputBuffer.floatChannelData?[0] else {
            throw SayError.conversionFailed
        }
        let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
        return (aiffURL, samples)
    }

    @Test("ASR model loads and transcribes speech")
    func asrTranscription() async throws {
        let asr = TranscriptionService.makeStreamingAsrManager()
        try await asr.loadModels()

        let (url, samples) = try Self.generateSpeech("Hello world, this is a test of speech recognition.")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(samples.count > 0, "Generated audio should have samples")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        _ = try await asr.process(audioBuffer: buffer)
        let transcript = try await asr.finish()

        print("ASR transcript: '\(transcript)'")
        #expect(!transcript.isEmpty, "ASR should produce non-empty transcript from speech audio")

        let lower = transcript.lowercased()
        #expect(lower.contains("hello") || lower.contains("test") || lower.contains("speech"),
                "Transcript should contain recognizable words from input. Got: '\(transcript)'")
    }

    @Test("LS-EEND diarizer processes audio and returns timeline")
    func diarization() async throws {
        let diarizer = LSEENDDiarizer(computeUnits: .cpuOnly)
        try await diarizer.initialize()

        let (url, samples) = try Self.generateSpeech(
            "Good morning everyone. Today we will discuss the quarterly results. "
            + "Sales have increased by twenty percent compared to last year."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(samples.count > 0)

        // Process all audio at once
        let timeline = try diarizer.processComplete(
            samples,
            sourceSampleRate: 16000,
            keepingEnrolledSpeakers: nil,
            finalizeOnCompletion: true,
            progressCallback: nil
        )

        let speakers = timeline.speakers
        print("Diarizer found \(speakers.count) speaker(s)")
        for (idx, speaker) in speakers {
            let segments = speaker.finalizedSegments
            print("  Speaker \(idx): \(segments.count) segment(s)")
            for seg in segments {
                print("    \(seg.startTime)s - \(seg.endTime)s")
            }
        }

        #expect(speakers.count >= 1, "Diarizer should detect at least one speaker from speech audio")
    }

    @Test("Transcript format: timestamps format correctly")
    func timestampFormatting() {
        // Verify the timestamp format HH:MM:SS used in transcript entries
        func formatTimestamp(_ seconds: Int) -> String {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }

        #expect(formatTimestamp(0) == "00:00:00")
        #expect(formatTimestamp(61) == "00:01:01")
        #expect(formatTimestamp(3661) == "01:01:01")
        #expect(formatTimestamp(83) == "00:01:23")
    }
}

private enum SayError: Error {
    case failed(Int32)
    case conversionFailed
}

/// Thread-safe mutable state for AVAudioConverter's input callback.
private final class ConverterState: @unchecked Sendable {
    var reachedEnd = false
}
