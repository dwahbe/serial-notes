@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Loads the offline diarizer's model bundle with `ModelComputePolicy`'s
/// compute units.
///
/// FluidAudio's `OfflineDiarizerModels.load` hardcodes `.all` for the
/// segmentation/embedding/PLDA models — its `configuration` parameter is
/// ignored — which re-admits GPU dispatch, the macOS 26.5.x fault-storm
/// trigger this app must avoid (see `ModelComputePolicy`). This mirrors that
/// loader through FluidAudio's public pieces (`DownloadUtils.loadModels` +
/// the public memberwise init). Safe while FluidAudio is pinned at 0.13.6;
/// if the pin ever moves, diff against upstream `OfflineDiarizerModels.load`
/// and prefer deleting this file once upstream respects the configuration.
enum OfflineDiarizerModelLoader {
    static func load() async throws -> OfflineDiarizerModels {
        let directory = OfflineDiarizerModels.defaultModelsDirectory()
        NSLog("[SerialNotes/OfflineDiarizer] loading models from %@ (computeUnits=%@)",
              directory.path, ModelComputePolicy.diagnosticsLabel)
        let loadStart = Date()

        let inferenceModels = try await DownloadUtils.loadModels(
            .diarizer,
            modelNames: [
                ModelNames.OfflineDiarizer.segmentationPath,
                ModelNames.OfflineDiarizer.embeddingPath,
                ModelNames.OfflineDiarizer.pldaRhoPath,
            ],
            directory: directory,
            computeUnits: ModelComputePolicy.computeUnits,
            variant: "offline"
        )
        guard let segmentation = inferenceModels[ModelNames.OfflineDiarizer.segmentationPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.segmentation)
        }
        guard let embedding = inferenceModels[ModelNames.OfflineDiarizer.embeddingPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.embedding)
        }
        guard let plda = inferenceModels[ModelNames.OfflineDiarizer.pldaRhoPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.pldaRho)
        }

        // Upstream deliberately keeps feature extraction on the CPU.
        let fbankModels = try await DownloadUtils.loadModels(
            .diarizer,
            modelNames: [ModelNames.OfflineDiarizer.fbankPath],
            directory: directory,
            computeUnits: .cpuOnly,
            variant: "offline"
        )
        guard let fbank = fbankModels[ModelNames.OfflineDiarizer.fbankPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.fbank)
        }

        let compilationDuration = Date().timeIntervalSince(loadStart)
        NSLog("[SerialNotes/OfflineDiarizer] models ready in %.1fs (inference=%@, fbank=cpuOnly)",
              compilationDuration, ModelComputePolicy.diagnosticsLabel)
        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: plda,
            pldaPsi: try loadPLDAPsi(from: directory),
            compilationDuration: compilationDuration
        )
    }

    /// Upstream's PLDA psi parse, replicated because it's `private` there.
    /// The tensor JSON ships alongside the models, so the format is pinned by
    /// the same version pin as the loader above.
    private static func loadPLDAPsi(from directory: URL) throws -> [Double] {
        let candidatePaths = [
            directory.appendingPathComponent("plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-coreml/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-offline/plda-parameters.json", isDirectory: false),
        ]
        guard let parametersURL = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw OfflineDiarizationError.processingFailed("PLDA parameters file not found in \(directory.path)")
        }

        let data = try Data(contentsOf: parametersURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let root = jsonObject as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psiInfo = tensors["psi"] as? [String: Any],
            let base64 = psiInfo["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
        else {
            throw OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters")
        }

        let floatCount = decoded.count / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            throw OfflineDiarizationError.processingFailed("PLDA psi tensor is empty")
        }

        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { destination in
            decoded.copyBytes(to: destination)
        }

        return floats.map { Double($0) }
    }
}
