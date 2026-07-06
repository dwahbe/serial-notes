@preconcurrency import CoreML
import Foundation

/// Central compute-units policy for every FluidAudio CoreML model load.
///
/// `MLModelConfiguration()` defaults to `.all`, which lets CoreML dispatch
/// inference to the GPU. On macOS 26.5.x that sustained load triggers
/// system-wide GPU MMU-fault restarts (bug_type 284 `gpuEvent-*.ips` under
/// `/Library/Logs/DiagnosticReports/`) that drop every process's in-flight
/// command buffers — WindowServer glitches and Chromium apps (Arc, Claude
/// Desktop) corrupt their canvases mid-meeting. CPU+ANE is FluidAudio's own
/// intended fast path (`AsrModels.defaultConfiguration()` — "avoid GPU
/// dispatch"), so excluding the GPU costs nothing. Never construct a
/// FluidAudio manager or model with its default configuration — route every
/// load through this policy.
enum ModelComputePolicy {
    /// Hidden escape hatch (no UI) to re-test GPU dispatch after a macOS
    /// driver fix: `defaults write <bundle-id> inference.allowGPU -bool YES`.
    ///
    /// Blast radius: flips the streaming ASR pair, the second-pass
    /// `AsrModels`, and the offline diarizer's segmentation/embedding/PLDA
    /// models to `.all`. Deliberately exempt (pinned `.cpuOnly` regardless):
    /// the LS-EEND diarizers (documented fastest on CPU) and the offline
    /// fbank front-end (upstream keeps feature extraction on the CPU).
    static let allowGPUDefaultsKey = "inference.allowGPU"

    /// Resolved once per process — models load once, so session.json always
    /// reports the value the models actually loaded with. Toggling the escape
    /// hatch takes effect at the next launch.
    static let computeUnits: MLComputeUnits = {
        let units = resolveComputeUnits()
        NSLog("[SerialNotes/ML] inference computeUnits=%@", label(for: units))
        return units
    }()

    /// A fresh configuration per load — `MLModelConfiguration` is mutable, so
    /// a shared instance could be mutated by one consumer under another.
    static func configuration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        // Mirrors MLModelConfigurationUtils.defaultConfiguration; only
        // relevant when the escape hatch re-admits the GPU.
        config.allowLowPrecisionAccumulationOnGPU = true
        config.computeUnits = computeUnits
        return config
    }

    /// Written into `session.json` so a future fault storm can be correlated
    /// with the compute units that were live during the recording.
    static var diagnosticsLabel: String {
        label(for: computeUnits)
    }

    static func resolveComputeUnits(defaults: UserDefaults = .standard) -> MLComputeUnits {
        defaults.bool(forKey: allowGPUDefaultsKey) ? .all : .cpuAndNeuralEngine
    }

    static func label(for units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "unknown"
        }
    }
}
