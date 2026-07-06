import CoreML
import FluidAudio
import Foundation
import Testing

@testable import SerialNotes

extension StreamingEouAsrManager {
    /// `configuration` is non-Sendable and can't cross the actor boundary;
    /// tests only need its (Sendable) compute units.
    fileprivate var computeUnitsForTesting: MLComputeUnits {
        configuration.computeUnits
    }
}

/// Pins the GPU-exclusion policy for CoreML inference. Regressing any of
/// these re-admits GPU dispatch during recordings, which triggers the
/// macOS 26.5.x system-wide GPU fault storms — see ModelComputePolicy.
@Suite("Model Compute Policy")
struct ModelComputePolicyTests {
    /// Tests run in parallel — each gets its own defaults suite so one
    /// test's domain wipe can't race another's write.
    private func withSuiteDefaults(_ name: String = #function, _ body: (UserDefaults) -> Void) {
        let suiteName = "ModelComputePolicyTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("Default excludes the GPU")
    func defaultExcludesGPU() {
        withSuiteDefaults { defaults in
            #expect(ModelComputePolicy.resolveComputeUnits(defaults: defaults) == .cpuAndNeuralEngine)
        }
    }

    @Test("Escape hatch is opt-in and re-admits the GPU")
    func escapeHatch() {
        withSuiteDefaults { defaults in
            #expect(defaults.bool(forKey: ModelComputePolicy.allowGPUDefaultsKey) == false)
            defaults.set(true, forKey: ModelComputePolicy.allowGPUDefaultsKey)
            #expect(ModelComputePolicy.resolveComputeUnits(defaults: defaults) == .all)
            defaults.set(false, forKey: ModelComputePolicy.allowGPUDefaultsKey)
            #expect(ModelComputePolicy.resolveComputeUnits(defaults: defaults) == .cpuAndNeuralEngine)
        }
    }

    @Test("Process-wide resolution and configuration agree and exclude the GPU")
    func processResolutionExcludesGPU() {
        // The test process never sets inference.allowGPU, so the once-per-
        // process resolution must land on the safe value, and every
        // configuration handed to a model load must carry it.
        #expect(ModelComputePolicy.computeUnits == .cpuAndNeuralEngine)
        #expect(ModelComputePolicy.configuration().computeUnits == .cpuAndNeuralEngine)
        #expect(ModelComputePolicy.diagnosticsLabel == "cpuAndNeuralEngine")
    }

    @Test("Configurations are fresh instances, not a shared mutable one")
    func configurationsAreFresh() {
        #expect(ModelComputePolicy.configuration() !== ModelComputePolicy.configuration())
    }

    @Test("Production streaming-ASR factory carries the policy units")
    func streamingFactoryCarriesPolicy() async {
        let manager = TranscriptionService.makeStreamingAsrManager()
        #expect(await manager.computeUnitsForTesting == .cpuAndNeuralEngine)
    }

    @Test("Diagnostics labels cover every compute-units case")
    func labelMapping() {
        #expect(ModelComputePolicy.label(for: .cpuOnly) == "cpuOnly")
        #expect(ModelComputePolicy.label(for: .cpuAndGPU) == "cpuAndGPU")
        #expect(ModelComputePolicy.label(for: .cpuAndNeuralEngine) == "cpuAndNeuralEngine")
        #expect(ModelComputePolicy.label(for: .all) == "all")
    }

    /// End-to-end proof that the CPU+ANE path actually loads and compiles on
    /// the running OS (downloads models on first run — hence the gate).
    /// Run: `SERIAL_ASR_SMOKE=1 swift test --filter ModelComputePolicyTests`
    @Test(
        "Streaming models load under the policy configuration",
        .enabled(if: ProcessInfo.processInfo.environment["SERIAL_ASR_SMOKE"] == "1")
    )
    func streamingModelsLoadUnderPolicy() async throws {
        let manager = TranscriptionService.makeStreamingAsrManager()
        try await manager.loadModels()
        #expect(await manager.computeUnitsForTesting == .cpuAndNeuralEngine)
    }
}
