import Foundation
import Testing

/// Structural enforcement of the "CoreML inference must never dispatch to
/// the GPU" convention (see ModelComputePolicy / CLAUDE.md): sweeps the
/// Sources and Tests trees for constructions that silently inherit a
/// GPU-capable default configuration. Convention alone already drifted once
/// (bare constructors in the test target) — this makes the next drift a
/// test failure instead of a fault storm.
@Suite("Compute Policy Guard")
struct ComputePolicyGuardTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ComputePolicyGuardTests.swift
        .deletingLastPathComponent()  // AudioPipelineTests
        .deletingLastPathComponent()  // Tests
    private static let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path

    private struct BannedPattern {
        let needle: String
        let reason: String
        /// File names where the pattern is the sanctioned implementation.
        let exemptFileNames: Set<String>
        /// A match directly preceded by one of these is part of a longer
        /// identifier naming a different (vetted) API, not the banned one.
        let exemptWhenPrecededBy: [String]

        init(
            needle: String,
            reason: String,
            exemptFileNames: Set<String> = [],
            exemptWhenPrecededBy: [String] = []
        ) {
            self.needle = needle
            self.reason = reason
            self.exemptFileNames = exemptFileNames
            self.exemptWhenPrecededBy = exemptWhenPrecededBy
        }
    }

    /// Calls that are safe only when a specific argument is passed explicitly —
    /// their upstream defaults are (or could silently become) GPU-capable.
    private struct RequiredArgumentPattern {
        let call: String
        let requiredArgument: String
        let reason: String
        /// An argument spelling that satisfies `requiredArgument` textually
        /// but reverts to the GPU-capable upstream default at runtime.
        let forbiddenArgument: String?
        let forbiddenReason: String?

        init(
            call: String,
            requiredArgument: String,
            reason: String,
            forbiddenArgument: String? = nil,
            forbiddenReason: String? = nil
        ) {
            self.call = call
            self.requiredArgument = requiredArgument
            self.reason = reason
            self.forbiddenArgument = forbiddenArgument
            self.forbiddenReason = forbiddenReason
        }
    }

    // Needles are split (concatenated pieces) so this file's own literals
    // can't trip the sweep in some future refactor that drops the
    // self-exemption. Matching runs on whitespace-condensed text (see
    // sweepableText), so a multi-line reformat of a call can't hide it.
    private static let banned: [BannedPattern] = [
        .init(
            needle: "StreamingEouAsrManager(" + ")",
            reason: "bare init defaults to MLModelConfiguration() = .all (GPU); use TranscriptionService.makeStreamingAsrManager()"
        ),
        .init(
            needle: "LSEENDDiarizer(" + "variant:",
            reason: "the loading convenience init has no computeUnits parameter; use LSEENDDiarizer() + initialize(variant:computeUnits:)"
        ),
        .init(
            needle: "MLModelConfiguration(" + ")",
            reason: "defaults to .all (GPU); route through ModelComputePolicy.configuration()",
            exemptFileNames: ["ModelComputePolicy.swift"]
        ),
        // The families below are banned outright: every entry point defaults
        // (or nil-resolves) to GPU-capable compute units upstream, and no
        // repo path routes them through ModelComputePolicy — the repo has
        // zero call sites, so any occurrence is a violation.
        .init(
            needle: "OfflineSortformer" + "Diarizer",
            reason: "initialize(modelPath:) / initializeFromHuggingFace default computeUnits: .all (GPU); no vetted call path"
        ),
        .init(
            needle: "Sortformer" + "Models",
            reason: "load/loadFromHuggingFace auto-resolve nil computeUnits to GPU-capable units (also matches OfflineSortformerModels — same family); no vetted call path"
        ),
        .init(
            needle: "Cohere" + "Pipeline",
            reason: "loads with computeUnits: .all (GPU) by default; no vetted call path"
        ),
        // No "(" so downloadIfNeeded is caught too; OfflineDiarizerModels has
        // no download members (checked against 0.15.5), so no collision.
        .init(
            needle: "DiarizerModels" + ".download",
            reason: "download/downloadIfNeeded default to .all (GPU) off-CI; no vetted call path"
        ),
        .init(
            needle: "DiarizerModels" + ".load(",
            reason: "defaults to .all (GPU) off-CI; no vetted call path (OfflineDiarizerModels.load is the vetted API, swept separately)",
            exemptWhenPrecededBy: ["Offline"]
        ),
    ]

    private static let requiredArguments: [RequiredArgumentPattern] = [
        .init(
            call: "AsrModels.downloadAndLoad(",
            requiredArgument: "configuration:",
            reason: "its nil-default is safe today but tracks upstream, not us — pass ModelComputePolicy.configuration()"
        ),
        .init(
            call: "OfflineDiarizerModels.load(",
            requiredArgument: "configuration:",
            reason: "nil configuration means .all (GPU) upstream — pass ModelComputePolicy.configuration()",
            forbiddenArgument: "configuration:" + "nil",
            forbiddenReason: "satisfies the argument check but upstream resolves nil to .all (GPU) — pass ModelComputePolicy.configuration()"
        ),
        .init(
            call: ".initialize(" + "variant:",
            requiredArgument: "computeUnits:",
            reason: "pass computeUnits: .cpuOnly explicitly so the units never track an upstream default"
        ),
        .init(
            call: "LSEENDModel.loadFromHuggingFace(",
            requiredArgument: "computeUnits:",
            reason: "pass computeUnits: .cpuOnly explicitly so the units never track an upstream default"
        ),
    ]

    /// All whitespace removed — applied to sources and needles alike, so
    /// matching is immune to line breaks and indentation inside a call.
    private static func condensed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// Comment-only lines may name banned APIs while explaining why they're
    /// banned — drop them, then condense what remains for needle matching.
    /// (Line numbers don't survive condensing; violations report per file.)
    private static func sweepableText(_ contents: String) -> String {
        condensed(
            contents
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        )
    }

    /// True when `argument` appears in `window` as a complete token — not as
    /// a prefix of a longer identifier (so "configuration:nil" can't match
    /// a variable like "configuration: nilFallback").
    private static func containsArgumentToken(_ window: Substring, _ argument: String) -> Bool {
        var searchRange = window.startIndex..<window.endIndex
        while let match = window.range(of: argument, range: searchRange) {
            searchRange = match.upperBound..<window.endIndex
            guard match.upperBound < window.endIndex else { return true }
            let next = window[match.upperBound]
            if !(next.isLetter || next.isNumber || next == "_") { return true }
        }
        return false
    }

    private static func violations(inFileNamed fileName: String, contents: String) -> [String] {
        let text = sweepableText(contents)
        var violations: [String] = []

        for pattern in banned where !pattern.exemptFileNames.contains(fileName) {
            let needle = condensed(pattern.needle)
            var searchRange = text.startIndex..<text.endIndex
            while let match = text.range(of: needle, range: searchRange) {
                searchRange = match.upperBound..<text.endIndex
                let exempt = pattern.exemptWhenPrecededBy.contains {
                    text[..<match.lowerBound].hasSuffix($0)
                }
                guard !exempt else { continue }
                violations.append("\(fileName) uses \(pattern.needle) — \(pattern.reason)")
                break
            }
        }

        for pattern in requiredArguments {
            let call = condensed(pattern.call)
            var searchRange = text.startIndex..<text.endIndex
            while let match = text.range(of: call, range: searchRange) {
                searchRange = match.upperBound..<text.endIndex
                let windowEnd = text.index(match.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
                let window = text[match.upperBound..<windowEnd]
                if !window.contains(condensed(pattern.requiredArgument)) {
                    violations.append("\(fileName) calls \(pattern.call)…) without \(pattern.requiredArgument) — \(pattern.reason)")
                }
                if let forbidden = pattern.forbiddenArgument,
                    containsArgumentToken(window, condensed(forbidden)) {
                    violations.append("\(fileName) calls \(pattern.call)…) with \(forbidden) — \(pattern.forbiddenReason ?? pattern.reason)")
                }
            }
        }

        return violations
    }

    private static func swiftFiles(under directory: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("No FluidAudio/CoreML load site bypasses ModelComputePolicy")
    func noBannedConstructions() throws {
        var violations: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Tests") {
            guard file.standardizedFileURL.path != Self.selfPath else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            violations += Self.violations(inFileNamed: file.lastPathComponent, contents: contents)
        }
        #expect(violations.isEmpty, "GPU-capable model loads outside ModelComputePolicy:\n\(violations.joined(separator: "\n"))")
    }

    @Test("Condensed needles still fire on the production load sites")
    func needlesFireOnCurrentSources() throws {
        // If condensing ever breaks needle matching, the sweep above goes
        // vacuously green — pin that the live, policy-routed call sites still
        // match the call needles (their arguments are what keep them legal).
        let sources = Self.repoRoot.appendingPathComponent("Sources/SerialNotes", isDirectory: true)
        let transcription = try String(
            contentsOf: sources.appendingPathComponent("TranscriptionService.swift"), encoding: .utf8)
        #expect(Self.sweepableText(transcription).contains(Self.condensed(".initialize(" + "variant:")))
        #expect(Self.sweepableText(transcription).contains(Self.condensed("StreamingEouAsrManager(" + "configuration:")))
        let identifier = try String(
            contentsOf: sources.appendingPathComponent("OfflineSpeakerIdentifier.swift"), encoding: .utf8)
        #expect(Self.sweepableText(identifier).contains(Self.condensed("OfflineDiarizerModels.load(" + "configuration:")))
    }

    @Test("Sweep flags reformatted and nil-configured load sites")
    func sweepFlagsCondensedViolations() {
        // A multi-line reformat and `configuration: nil` both defeated the
        // pre-condensing sweep — pin that each is now caught. (Canary needles
        // are split like the pattern table's, for the same reason.)
        let reformattedNil = [
            "let models = try await OfflineDiarizer" + "Models",
            "    .load(",
            "        configuration: nil",
            "    )",
        ].joined(separator: "\n")
        #expect(!Self.violations(inFileNamed: "Canary.swift", contents: reformattedNil).isEmpty)

        let reformattedBareInit = ["let manager = StreamingEouAsrManager" + "(", ")"].joined(separator: "\n")
        #expect(!Self.violations(inFileNamed: "Canary.swift", contents: reformattedBareInit).isEmpty)

        let bannedFamilies = [
            "let d = OfflineSortformer" + "Diarizer()",
            "let m = try await Sortformer" + "Models.load(config: c)",
            "let p = Cohere" + "Pipeline()",
            "let m = try await Diarizer" + "Models.download()",
            "let m = try await Diarizer" + "Models.downloadIfNeeded()",
            "let m = try await Diarizer" + "Models.load()",
        ]
        for canary in bannedFamilies {
            #expect(
                !Self.violations(inFileNamed: "Canary.swift", contents: canary).isEmpty,
                "unswept GPU-defaulting family: \(canary)"
            )
        }

        // The vetted call stays clean — the DiarizerModels.load ban must not
        // collide with its Offline-prefixed namesake.
        let vetted = "let m = try await OfflineDiarizer"
            + "Models.load(configuration: ModelComputePolicy.configuration())"
        #expect(Self.violations(inFileNamed: "Canary.swift", contents: vetted).isEmpty)
    }

    @Test("Guard sweep actually sees the source tree")
    func sweepCoversSources() throws {
        // If the repo layout changes and the sweep silently scans nothing,
        // the guard above would pass vacuously — pin that every app source
        // file is in the swept set (listed independently, non-recursively).
        let sweptNames = Set(Self.swiftFiles(under: "Sources").map(\.lastPathComponent))
        let appSourceNames = try FileManager.default.contentsOfDirectory(
            at: Self.repoRoot.appendingPathComponent("Sources/SerialNotes", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map(\.lastPathComponent)
        #expect(!appSourceNames.isEmpty)
        let missing = Set(appSourceNames).subtracting(sweptNames)
        #expect(missing.isEmpty, "Sources/SerialNotes files invisible to the sweep: \(missing.sorted())")
        #expect(sweptNames.contains("ModelComputePolicy.swift"))
        #expect(sweptNames.contains("TranscriptionService.swift"))
    }
}
