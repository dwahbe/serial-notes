import FluidAudio
import Foundation

/// One speaker discovered by the offline diarization pass: a cluster of speech
/// segments plus a representative (L2-normalized) voice embedding to match
/// against enrolled profiles.
struct OfflineSpeakerCluster: Sendable, Equatable {
    /// The diarizer's own speaker id for this recording ("0", "1", …). Not a
    /// stable cross-meeting identity — only meaningful within one result.
    let id: String
    /// Centroid embedding, L2-normalized. Empty only if the diarizer produced
    /// no usable embedding for this speaker.
    let embedding: [Float]
    /// Speech spans in seconds from the start of the recording, sorted.
    let segments: [Span]

    struct Span: Sendable, Equatable {
        let start: Double
        let end: Double
        var duration: Double { max(0, end - start) }
    }

    var totalSpeechSeconds: Double { segments.reduce(0) { $0 + $1.duration } }
}

/// A detected speaker paired with the identity decision for it.
struct IdentifiedSpeaker: Sendable, Equatable {
    let cluster: OfflineSpeakerCluster
    let decision: SpeakerIdentityMatcher.Decision
}

/// Post-meeting speaker re-diarization, wrapping FluidAudio's
/// `OfflineDiarizerManager` (VBx clustering). Unlike the live `LSEENDDiarizer`,
/// this produces a per-speaker embedding we can score against enrolled voices —
/// the missing piece that lets `SpeakerIdentityMatcher` reject an unknown voice
/// instead of inheriting a known name.
///
/// It owns one manager and serializes access (the manager loads its own CoreML
/// models, separate from the streaming/ASR models, downloaded lazily on first
/// use). Runs entirely on-device.
actor OfflineSpeakerIdentifier {
    private let config: OfflineDiarizerConfig
    // The Sendable model bundle is cached here and reused across the meeting's
    // diarization + every enrollment clip. The non-Sendable `OfflineDiarizerManager`
    // is created per call inside `diarize(_:models:config:)`, which is `nonisolated`
    // so the manager never crosses the actor boundary (it isn't Sendable).
    private var models: OfflineDiarizerModels?
    /// A shared in-flight load prevents every profile embedding from independently
    /// downloading/compiling the same model bundle during finalization.
    private var modelLoadTask: Task<OfflineDiarizerModels, Error>?
    /// Avoid hammering a failed download once per saved profile and again for the
    /// meeting pass. A later recording may retry after this short cooldown.
    private var retryAfterModelLoadFailure: Date?
    private static let modelLoadRetryCooldown: TimeInterval = 60

    init(config: OfflineDiarizerConfig = .default) {
        self.config = config
    }

    /// Download + compile the offline models if needed. Idempotent; the first
    /// call may block on a network fetch (~tens of MB from Hugging Face).
    func prepareModels() async throws {
        _ = try await loadedModels()
    }

    /// True only after the model bundle has been loaded into memory. The app-quit
    /// path uses this to avoid turning termination into the first model download or
    /// compile opportunity.
    func hasLoadedModels() -> Bool {
        models != nil
    }

    /// Re-diarize a full recording into speaker clusters with embeddings.
    /// `url` may be any sample rate — the manager resamples to 16 kHz mono.
    func clusters(inRecordingAt url: URL) async throws -> [OfflineSpeakerCluster] {
        try Task.checkCancellation()
        let result = try await Self.diarize(url, models: loadedModels(), config: config)
        try Task.checkCancellation()
        return Self.clusters(from: result)
    }

    /// Diarize a recording into final speakers using the calibrated over-segment →
    /// merge strategy. Default VBx clustering collapses distinct speakers into one
    /// (especially on Bluetooth-mixed audio), so we force an over-segmentation
    /// (`min: 2`) and then merge clusters whose centroids sit within `mergeThreshold`
    /// cosine — i.e. one speaker the diarizer split into fragments. Calibration on
    /// real audio: same speaker ≈ 0.96, different ≤ 0.31, so 0.5 separates cleanly.
    /// Final speakers below `minSpeechSeconds` are dropped as noise; results are
    /// returned longest-talking first.
    func speakers(
        inRecordingAt url: URL,
        maxSpeakers: Int = 6,
        mergeThreshold: Float = 0.5,
        minSpeechSeconds: Double = 20
    ) async throws -> [OfflineSpeakerCluster] {
        try Task.checkCancellation()
        let overSegment = OfflineDiarizerConfig.default.withSpeakers(min: 2, max: maxSpeakers)
        let result = try await Self.diarize(url, models: loadedModels(), config: overSegment)
        try Task.checkCancellation()
        // Merge first. A real speaker can be over-split into several individually
        // short fragments; filtering first loses that speaker permanently. Noise still
        // falls out after merging because it remains below the final duration floor.
        return Self.mergeAndFilter(
            Self.clusters(from: result),
            threshold: mergeThreshold,
            minSpeechSeconds: minSpeechSeconds
        )
    }

    /// The full identity pass: diarize the recording into final speakers, then match
    /// each against the enrolled `candidates` with a confidence-gated cosine decision
    /// (auto-name / suggest / anonymous). An empty `candidates` list leaves every
    /// speaker anonymous. `matcher` carries the thresholds (defaults to calibrated).
    func identifySpeakers(
        inRecordingAt url: URL,
        candidates: [SpeakerIdentityMatcher.Candidate],
        matcher: SpeakerIdentityMatcher = SpeakerIdentityMatcher()
    ) async throws -> [IdentifiedSpeaker] {
        try Task.checkCancellation()
        return try await speakers(inRecordingAt: url).map {
            IdentifiedSpeaker(cluster: $0, decision: matcher.match($0.embedding, against: candidates))
        }
    }

    /// A single representative embedding for an enrollment clip, taken from its
    /// dominant (longest-talking) speaker. Returns nil if no speech was found —
    /// e.g. a clip shorter than the diarizer's segmentation window. Used to turn
    /// a saved `.other` voice profile into something matchable.
    func enrollmentEmbedding(forClipAt url: URL) async throws -> [Float]? {
        try Task.checkCancellation()
        let result = try await Self.diarize(url, models: loadedModels(), config: config)
        try Task.checkCancellation()
        return Self.clusters(from: result)
            .max(by: { $0.totalSpeechSeconds < $1.totalSpeechSeconds })
            .flatMap { $0.embedding.isEmpty ? nil : $0.embedding }
    }

    /// Lazily load + cache the Sendable model bundle.
    private func loadedModels() async throws -> OfflineDiarizerModels {
        try Task.checkCancellation()
        if let models { return models }
        if let retryAfterModelLoadFailure, Date() < retryAfterModelLoadFailure {
            throw OfflineDiarizationError.modelNotLoaded("offline-diarizer (retry deferred after a recent load failure)")
        }

        let task: Task<OfflineDiarizerModels, Error>
        if let modelLoadTask {
            task = modelLoadTask
        } else {
            // Not OfflineDiarizerModels.load() — that hardcodes GPU-capable
            // compute units; the loader applies ModelComputePolicy.
            let newTask = Task { try await OfflineDiarizerModelLoader.load() }
            modelLoadTask = newTask
            task = newTask
        }

        do {
            let loaded = try await task.value
            try Task.checkCancellation()
            models = loaded
            modelLoadTask = nil
            retryAfterModelLoadFailure = nil
            return loaded
        } catch {
            modelLoadTask = nil
            retryAfterModelLoadFailure = Date().addingTimeInterval(Self.modelLoadRetryCooldown)
            throw error
        }
    }

    /// Runs one diarization. `nonisolated` and taking only Sendable arguments, so
    /// the non-Sendable manager lives entirely within this call and never escapes
    /// to the actor.
    private nonisolated static func diarize(
        _ url: URL,
        models: OfflineDiarizerModels,
        config: OfflineDiarizerConfig
    ) async throws -> DiarizationResult {
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(url)
        try Task.checkCancellation()
        return result
    }

    /// Group a diarization result's segments by speaker and pair each speaker
    /// with its centroid embedding. Pure + side-effect-free so it can be unit
    /// tested without loading models.
    static func clusters(from result: DiarizationResult) -> [OfflineSpeakerCluster] {
        var spansBySpeaker: [String: [OfflineSpeakerCluster.Span]] = [:]
        // Fallback embedding (the first segment's) only used if the pipeline
        // didn't publish a centroid for this speaker — it normally does.
        var fallbackEmbedding: [String: [Float]] = [:]

        for segment in result.segments {
            let span = OfflineSpeakerCluster.Span(
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
            spansBySpeaker[segment.speakerId, default: []].append(span)
            if fallbackEmbedding[segment.speakerId] == nil, !segment.embedding.isEmpty {
                fallbackEmbedding[segment.speakerId] = segment.embedding
            }
        }

        return spansBySpeaker
            .map { id, spans in
                OfflineSpeakerCluster(
                    id: id,
                    embedding: result.speakerDatabase?[id] ?? fallbackEmbedding[id] ?? [],
                    segments: spans.sorted { $0.start < $1.start }
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// Agglomeratively merge clusters whose centroids meet or exceed `threshold` cosine,
    /// combining their segments and duration-weighting their embeddings — collapses
    /// one speaker the diarizer over-split into fragments back into a single speaker.
    /// Pure + side-effect-free for unit testing.
    static func merge(_ clusters: [OfflineSpeakerCluster], threshold: Float) -> [OfflineSpeakerCluster] {
        var groups = clusters
        while groups.count > 1 {
            var best: (i: Int, j: Int, sim: Float)?
            for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let sim = SpeakerIdentityMatcher.cosineSimilarity(groups[i].embedding, groups[j].embedding)
                    if sim >= threshold, best == nil || sim > best!.sim { best = (i, j, sim) }
                }
            }
            guard let b = best else { break }
            groups[b.i] = combine(groups[b.i], groups[b.j])
            groups.remove(at: b.j)
        }
        return groups
    }

    /// Production post-processing, factored out so the "merge before duration
    /// filtering" invariant is directly unit-testable without loading models.
    static func mergeAndFilter(
        _ clusters: [OfflineSpeakerCluster],
        threshold: Float,
        minSpeechSeconds: Double
    ) -> [OfflineSpeakerCluster] {
        merge(clusters, threshold: threshold)
            .filter { $0.totalSpeechSeconds >= minSpeechSeconds }
            .sorted { $0.totalSpeechSeconds > $1.totalSpeechSeconds }
    }

    /// Combine two clusters: union of segments (time-sorted), duration-weighted +
    /// re-normalized centroid. Keeps the first cluster's id.
    private static func combine(_ a: OfflineSpeakerCluster, _ b: OfflineSpeakerCluster) -> OfflineSpeakerCluster {
        let wa = Float(max(a.totalSpeechSeconds, 0.001))
        let wb = Float(max(b.totalSpeechSeconds, 0.001))
        let dim = max(a.embedding.count, b.embedding.count)
        var emb = [Float](repeating: 0, count: dim)
        for k in 0..<dim {
            let av = k < a.embedding.count ? a.embedding[k] : 0
            let bv = k < b.embedding.count ? b.embedding[k] : 0
            emb[k] = (av * wa + bv * wb) / (wa + wb)
        }
        let norm = max(emb.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        emb = emb.map { $0 / norm }
        let segments = (a.segments + b.segments).sorted { $0.start < $1.start }
        return OfflineSpeakerCluster(id: a.id, embedding: emb, segments: segments)
    }
}
