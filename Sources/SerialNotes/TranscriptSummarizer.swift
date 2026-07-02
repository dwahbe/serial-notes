import Foundation
@preconcurrency import FoundationModels

/// One action item extracted from a transcript. `owner` is non-nil only when
/// the transcript explicitly names a responsible person or group — never inferred.
struct ActionItem: Sendable, Equatable {
    let task: String
    let owner: String?
}

struct SummaryResult: Sendable, Equatable {
    let summary: [String]
    let actionItems: [ActionItem]

    static let empty = SummaryResult(summary: [], actionItems: [])

    var isEmpty: Bool { summary.isEmpty && actionItems.isEmpty }
}

protocol TranscriptSummarizer: Sendable {
    /// Returns a best-effort summary. Sections the caller didn't request are
    /// returned empty. On any internal failure, the corresponding section is
    /// empty — never throws.
    func summarize(
        transcript: String,
        generateSummary: Bool,
        generateActionItems: Bool
    ) async -> SummaryResult

    /// Optional warm-up — gives the underlying model a chance to load so the
    /// real call at session end doesn't pay cold-start latency. Default no-op
    /// for implementations that don't need it.
    func prewarm() async
}

extension TranscriptSummarizer {
    func prewarm() async {}
}

enum TranscriptSummarizerFactory {
    /// Returns `nil` when Foundation Models is unavailable on this device.
    /// Callers should skip the summary step entirely rather than fall back —
    /// a fabricated summary is worse than none.
    static func make() -> (any TranscriptSummarizer)? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsSummarizer()
        case .unavailable:
            return nil
        }
    }
}

// MARK: - Generable schemas

@Generable
struct MeetingSummary {
    @Guide(description: "3 to 6 short bullet points capturing the main topics, decisions, and outcomes. Each bullet is one sentence. Plain text — do not start bullets with '-' or '*'.")
    let bullets: [String]
}

@Generable
struct GeneratedActionItem {
    @Guide(description: "What needs to be done, in one short sentence.")
    let task: String
    @Guide(description: "The responsible person or group if explicitly named, such as 'Dylan', 'Everyone', or 'John, Lily, and Bella'. Empty string if no owner was named — never infer.")
    let owner: String
}

@Generable
struct GeneratedActionItemList {
    @Guide(description: "Final consolidated future-work action items. Empty list when nothing was committed to.")
    let items: [GeneratedActionItem]
}

// MARK: - Foundation Models implementation

actor FoundationModelsSummarizer: TranscriptSummarizer {
    private static let summaryInstructions = """
        You write concise meeting summaries from speaker-labeled transcripts. \
        Produce 3 to 6 short bullet points capturing the main topics, decisions, \
        and outcomes. Each bullet is one plain sentence. Do not invent details \
        not present in the transcript. Do not include action items here — those \
        are handled separately.
        """

    private static let actionItemInstructions = """
        You extract final, concrete action items from speaker-labeled meeting \
        transcripts. An action item is future work someone committed to after \
        the meeting, not an in-meeting facilitation step, discussion prompt, \
        draft idea, or already-completed activity. Prefer the final decision \
        or assignment over earlier brainstorming. Merge repeated mentions and \
        near-duplicates into one clear item. If the transcript assigns one task \
        to a group, return one group-owned item rather than one item per person. \
        Preserve deadlines when stated. For each item, set 'owner' only when \
        the transcript explicitly names the responsible person or group — \
        otherwise leave 'owner' empty. Do not infer owners from context. Return \
        a short list; return an empty list when nothing was committed to.
        """

    private static let perCallTimeout: Duration = .seconds(15)
    /// Word-count fallback limits, used when token counting is unavailable
    /// (pre-26.4) or fails. Conservative proxies for the 4096-token window.
    private static let singlePassMaxWords = 2500
    private static let chunkMaxWords = 1500
    /// Context-window headroom withheld from the input budget: instructions,
    /// the injected generation schema, and the generated output all share the
    /// window with the prompt.
    private static let reservedContextTokens = 1024
    /// Per-chunk token density can run hotter than the whole-transcript
    /// average the word cap is derived from.
    private static let chunkTokenSafetyFactor = 0.9
    private static let minChunkWords = 200
    private static let maxSummaryBullets = 6
    private static let maxActionItems = 12
    private static let minBulletCharacters = 3

    /// Sessions are stateful — every `respond` appends to the session's own
    /// transcript, so a session reused across calls burns context window on
    /// earlier chunks and eventually throws `exceededContextWindowSize`.
    /// Each request gets a fresh session; chunks are independent, so no
    /// useful context is lost.
    private static func makeSummarySession() -> LanguageModelSession {
        LanguageModelSession(instructions: summaryInstructions)
    }

    private static func makeActionSession() -> LanguageModelSession {
        LanguageModelSession(instructions: actionItemInstructions)
    }

    /// Loads the model and primes each instruction prefix so the real calls at
    /// session end don't eat cold-start latency (~200–500ms). The sessions are
    /// throwaway — model residency is process-wide, which is where the cost is.
    func prewarm() async {
        Self.makeSummarySession().prewarm()
        Self.makeActionSession().prewarm()
    }

    func summarize(
        transcript: String,
        generateSummary: Bool,
        generateActionItems: Bool
    ) async -> SummaryResult {
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .empty }
        guard generateSummary || generateActionItems else { return .empty }

        switch await plan(body: body) {
        case .singlePass:
            async let summary = generateSummary ? singlePassSummary(body) : []
            async let actions = generateActionItems ? singlePassActions(body) : []
            return SummaryResult(summary: await summary, actionItems: await actions)
        case .chunked(let maxWords):
            let chunks = SummarizerTextProcessing.speakerTurnChunks(body, maxWords: maxWords)
            async let summary = generateSummary ? mapReduceSummary(chunks) : []
            async let actions = generateActionItems ? mapReduceActions(chunks) : []
            return SummaryResult(summary: await summary, actionItems: await actions)
        }
    }

    // MARK: Pass planning

    private enum SummaryPlan {
        case singlePass
        case chunked(maxWords: Int)
    }

    /// Decide single-pass vs map-reduce. On 26.4+ this measures real tokens
    /// against the model's context window — precise both ways (token-dense
    /// transcripts that would overflow at 2500 words get chunked; token-light
    /// ones avoid a needless reduce pass) and it scales automatically when a
    /// newer OS grows `contextSize`. Pre-26.4, or if counting fails, falls
    /// back to the word-count limits.
    private func plan(body: String) async -> SummaryPlan {
        let wordCount = SummarizerTextProcessing.wordCount(body)
        if #available(macOS 26.4, *),
            let measured = await tokenBasedPlan(body: body, wordCount: wordCount)
        {
            return measured
        }
        return wordCount <= Self.singlePassMaxWords
            ? .singlePass
            : .chunked(maxWords: Self.chunkMaxWords)
    }

    @available(macOS 26.4, *)
    private func tokenBasedPlan(body: String, wordCount: Int) async -> SummaryPlan? {
        let model = SystemLanguageModel.default
        let inputBudget = model.contextSize - Self.reservedContextTokens
        guard inputBudget > 0, wordCount > 0 else { return nil }
        guard let bodyTokens = try? await model.tokenCount(for: body), bodyTokens > 0 else {
            return nil
        }
        if bodyTokens <= inputBudget { return .singlePass }
        let maxWords = SummarizerTextProcessing.tokenDerivedChunkWords(
            bodyTokens: bodyTokens,
            wordCount: wordCount,
            inputTokenBudget: inputBudget,
            safetyFactor: Self.chunkTokenSafetyFactor,
            minWords: Self.minChunkWords
        )
        return .chunked(maxWords: maxWords)
    }

    // MARK: Summary

    private func singlePassSummary(_ body: String) async -> [String] {
        let bullets = await requestSummary(body)
        return sanitizeBullets(bullets)
    }

    private func mapReduceSummary(_ chunks: [String]) async -> [String] {
        var intermediate: [String] = []
        for chunk in chunks {
            let bullets = await requestSummary(chunk)
            intermediate.append(contentsOf: bullets)
        }
        guard !intermediate.isEmpty else { return [] }

        let joined = intermediate.map { "- \($0)" }.joined(separator: "\n")
        let reducePrompt = """
            Combine these per-section bullets into one final summary of 3 to 6 \
            bullets capturing the meeting's main topics and decisions. Remove \
            redundancy. Keep each bullet to one sentence.

            \(joined)
            """
        let reduced = await requestSummary(reducePrompt)
        return sanitizeBullets(reduced.isEmpty ? intermediate : reduced)
    }

    private func requestSummary(_ text: String) async -> [String] {
        do {
            return try await withTimeout(Self.perCallTimeout) {
                let response = try await Self.makeSummarySession().respond(
                    to: text,
                    generating: MeetingSummary.self
                )
                return response.content.bullets
            }
        } catch {
            return []
        }
    }

    // MARK: Action items

    private func singlePassActions(_ body: String) async -> [ActionItem] {
        let raw = await requestActionItems(body)
        return sanitizeActionItems(raw)
    }

    private func mapReduceActions(_ chunks: [String]) async -> [ActionItem] {
        var collected: [GeneratedActionItem] = []
        for chunk in chunks {
            collected.append(contentsOf: await requestActionItems(chunk))
        }
        let sanitized = sanitizeActionItems(collected)
        guard sanitized.count > 1 else { return sanitized }

        let joined = sanitized.enumerated().map { index, item in
            let owner = item.owner.map { "[\($0)] " } ?? ""
            return "\(index + 1). \(owner)\(item.task)"
        }.joined(separator: "\n")
        let reducePrompt = """
            Consolidate these candidate action items into the final meeting action \
            item list. Merge duplicates and near-duplicates. Prefer the final \
            commitment over earlier exploratory wording. Remove in-meeting \
            facilitation steps or tasks already completed during the call. If \
            several people share one assignment, keep it as one group-owned item. \
            Keep deadlines. Return only final future work.

            \(joined)
            """
        let reduced = sanitizeActionItems(await requestActionItems(reducePrompt))
        return reduced.isEmpty ? sanitized : reduced
    }

    private func requestActionItems(_ text: String) async -> [GeneratedActionItem] {
        do {
            return try await withTimeout(Self.perCallTimeout) {
                let response = try await Self.makeActionSession().respond(
                    to: text,
                    generating: GeneratedActionItemList.self
                )
                return response.content.items
            }
        } catch {
            return []
        }
    }

    // MARK: Sanitization

    private func sanitizeBullets(_ bullets: [String]) -> [String] {
        let cleaned = bullets
            .map { stripBulletPrefix($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= Self.minBulletCharacters }
        return Array(cleaned.prefix(Self.maxSummaryBullets))
    }

    private func sanitizeActionItems(_ items: [GeneratedActionItem]) -> [ActionItem] {
        ActionItemPostProcessing.sanitize(items, maxItems: Self.maxActionItems, minCharacters: Self.minBulletCharacters)
    }

    private func stripBulletPrefix(_ s: String) -> String {
        ActionItemPostProcessing.stripBulletPrefix(s)
    }

}

enum ActionItemPostProcessing {
    static func sanitize(
        _ items: [GeneratedActionItem],
        maxItems: Int,
        minCharacters: Int
    ) -> [ActionItem] {
        var seen = Set<String>()
        var out: [ActionItem] = []
        for item in items {
            let task = stripBulletPrefix(item.task).trimmingCharacters(in: .whitespacesAndNewlines)
            guard task.count >= minCharacters else { continue }
            let trimmedOwner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner: String? = trimmedOwner.isEmpty ? nil : trimmedOwner
            let key = normalize("\(owner ?? "") \(task)")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(ActionItem(task: task, owner: owner))
            guard out.count < maxItems else { break }
        }
        return out
    }

    static func stripBulletPrefix(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, first == "-" || first == "*" || first == "•" {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " "
        }.map(String.init).joined()
    }
}

// MARK: - Shared text processing

enum SummarizerTextProcessing {
    /// Below this many words (headers included) the transcript is background
    /// noise or a stray recording, not a meeting — the model fabricates a
    /// generic one rather than summarizing. Callers skip the summary pass
    /// entirely: a fabricated summary is worse than none.
    static let minSummaryInputWords = 50

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Convert a per-call input token budget into a word cap for
    /// `speakerTurnChunks`, scaled by the transcript's measured
    /// words-per-token density. `safetyFactor` absorbs chunks whose density
    /// runs hotter than the whole-transcript average.
    static func tokenDerivedChunkWords(
        bodyTokens: Int,
        wordCount: Int,
        inputTokenBudget: Int,
        safetyFactor: Double,
        minWords: Int
    ) -> Int {
        guard bodyTokens > 0, wordCount > 0, inputTokenBudget > 0 else { return minWords }
        let wordsPerToken = Double(wordCount) / Double(bodyTokens)
        let words = Int(Double(inputTokenBudget) * wordsPerToken * safetyFactor)
        return max(words, minWords)
    }

    /// Split a markdown transcript on speaker-turn boundaries (`**Speaker** (...):`),
    /// packing turns into chunks up to `maxWords`. Falls back to a single chunk
    /// when no turn markers are found.
    static func speakerTurnChunks(_ text: String, maxWords: Int) -> [String] {
        let turns = splitOnSpeakerTurns(text)
        guard !turns.isEmpty else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for turn in turns {
            let turnWords = wordCount(turn)
            if !current.isEmpty && currentWords + turnWords > maxWords {
                chunks.append(current.joined(separator: "\n\n"))
                current.removeAll(keepingCapacity: true)
                currentWords = 0
            }
            current.append(turn)
            currentWords += turnWords
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n\n"))
        }
        return chunks
    }

    private static func splitOnSpeakerTurns(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var turns: [[String]] = []
        var current: [String] = []

        for line in lines {
            if line.hasPrefix("**") && current.isEmpty == false && hasSpeakerHeader(line) {
                turns.append(current)
                current = [line]
            } else if line.hasPrefix("**") && current.isEmpty && hasSpeakerHeader(line) {
                current.append(line)
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            turns.append(current)
        }

        return turns
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func hasSpeakerHeader(_ line: String) -> Bool {
        // `**Speaker** (HH:MM:SS):` heuristic — sufficient to detect turn starts.
        guard line.hasPrefix("**") else { return false }
        guard let closing = line.range(of: "** (") else { return false }
        return line[closing.upperBound...].contains("):")
    }
}

// withTimeout + TimeoutError live in TranscriptRewriter.swift — both run
// on-device LanguageModelSessions that need the same stall protection.
