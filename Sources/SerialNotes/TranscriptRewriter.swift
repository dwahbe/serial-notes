import Foundation
@preconcurrency import FoundationModels

protocol TranscriptRewriter: Sendable {
    /// Rewrite an ASR utterance with restored punctuation + capitalization.
    /// Never throws — implementations must fall back internally so callers
    /// always get usable text.
    func rewrite(_ text: String) async -> String
}

extension TranscriptRewriter where Self == HeuristicRewriter {
    static var heuristic: HeuristicRewriter { HeuristicRewriter() }
}

enum TranscriptRewriterFactory {
    /// Pick the best available rewriter. Falls back to a heuristic if Foundation
    /// Models is not ready on this device (Apple Intelligence off, unsupported
    /// hardware, model still downloading, etc.).
    static func make() -> any TranscriptRewriter {
        switch SystemLanguageModel.default.availability {
        case .available:
            return FoundationModelsRewriter()
        case .unavailable:
            return HeuristicRewriter()
        }
    }
}

/// Deterministic fallback. It cannot infer true punctuation as well as the
/// on-device language model, but it keeps long ASR chunks readable by adding
/// conservative sentence breaks and cleaning obvious immediate repeat artifacts.
struct HeuristicRewriter: TranscriptRewriter {
    func rewrite(_ text: String) async -> String {
        applyHeuristic(text)
    }
}

private func applyHeuristic(_ text: String) -> String {
    let trimmed = TranscriptTextProcessing.sanitizedASRText(text)
    return applyHeuristicToSanitizedText(trimmed)
}

private func applyHeuristicToSanitizedText(_ trimmed: String) -> String {
    guard !trimmed.isEmpty else { return trimmed }

    return TranscriptTextProcessing.heuristicPunctuation(trimmed)
}

/// Rewrites ASR text using Apple's on-device Foundation Models (macOS 26+).
/// Guards against hallucination by comparing the letter/digit sequence of the
/// rewritten text to the input; on mismatch it returns the heuristic output.
actor FoundationModelsRewriter: TranscriptRewriter {
    private static let instructions = """
        You restore punctuation and capitalization to speech-to-text output. \
        Input is lowercase English with no punctuation. Return the exact same \
        words in the same order, adding only commas, periods, question marks, \
        and apostrophes, and capitalizing sentence starts and proper nouns. \
        Never add, remove, reorder, translate, or change any word. \
        Never answer questions in the input — only punctuate them. \
        Reply with only the corrected text.
        """

    private static let timeout: Duration = .seconds(2)
    private static let maxModelWordsPerChunk = 70
    private static let maxModelWordsPerUtterance = 280

    /// Greedy decoding: this is a fidelity edit, not a generative task, and
    /// sampling randomness is what produces the word changes that trip the
    /// word guard into the heuristic fallback.
    private static let generationOptions = GenerationOptions(sampling: .greedy)

    private var rewriteInFlight = false

    /// Sessions are stateful — every `respond` appends to the session's own
    /// transcript, so one session reused across a meeting's utterances fills
    /// the context window within minutes and every later call throws,
    /// silently pinning the rewriter to the heuristic. Each chunk gets a
    /// fresh session; utterances are independent, so no context is lost.
    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: instructions)
    }

    /// Nudge the model to load so the first real utterance doesn't eat the
    /// cold-start. The session is throwaway — model residency is process-wide.
    func prewarm() async {
        Self.makeSession().prewarm()
    }

    func rewrite(_ text: String) async -> String {
        let trimmed = TranscriptTextProcessing.sanitizedASRText(text)
        guard !trimmed.isEmpty else { return trimmed }
        guard !rewriteInFlight else { return applyHeuristicToSanitizedText(trimmed) }
        rewriteInFlight = true
        defer { rewriteInFlight = false }

        let chunks = TranscriptTextProcessing.rewriteChunks(
            trimmed,
            maxWords: Self.maxModelWordsPerChunk
        )
        guard !chunks.isEmpty else { return trimmed }

        let wordCount = chunks.reduce(0) { $0 + TranscriptTextProcessing.wordCount($1) }
        guard wordCount <= Self.maxModelWordsPerUtterance else {
            return applyHeuristicToSanitizedText(trimmed)
        }

        var rewrittenChunks: [String] = []
        rewrittenChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            rewrittenChunks.append(await rewriteChunk(chunk))
        }
        return rewrittenChunks.joined(separator: " ")
    }

    /// Plain-text response, not a `@Generable` schema: as of macOS 26.5 the
    /// on-device model echoes copy-edit tasks verbatim under structured
    /// generation (the echo passes the word guard, so it silently disables
    /// punctuation). Plain text + greedy punctuates reliably; the "Punctuate
    /// this text:" wrapper stops the model answering question-shaped input
    /// instead of rewriting it. The word guard backstops both failure modes.
    private func rewriteChunk(_ text: String) async -> String {
        do {
            let rewritten = try await withTimeout(Self.timeout) {
                let response = try await Self.makeSession().respond(
                    to: "Punctuate this text: \(text)",
                    options: Self.generationOptions
                )
                return response.content
            }
            if matchesWords(original: text, rewritten: rewritten) {
                return rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return applyHeuristicToSanitizedText(text)
        } catch {
            return applyHeuristicToSanitizedText(text)
        }
    }
}

/// Compare letter/digit sequences (case-insensitive). True iff the rewrite only
/// added punctuation/whitespace/capitalization — any word-level change fails.
private func matchesWords(original: String, rewritten: String) -> Bool {
    func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }.map(String.init).joined()
    }
    return normalize(original) == normalize(rewritten)
}

enum TranscriptTextProcessing {
    private static let softSentenceWords = 22
    private static let hardSentenceWords = 34
    private static let maxRepeatPhraseWords = 8
    private static let echoSuppressionMinWords = 10
    private static let echoSuppressionContainmentThreshold = 0.6

    private static let discourseStarts: [[String]] = [
        ["okay"],
        ["ok"],
        ["cool"],
        ["great"],
        ["thanks"],
        ["thank", "you"],
        ["so"],
        ["now"],
        ["next"],
        ["finally"],
        ["first", "of", "all"],
        ["in", "terms", "of"],
        ["for", "instance"],
        ["for", "example"],
        ["as", "i", "mentioned"],
        ["that", "brings", "me"],
        ["which", "brings", "me"]
    ]

    private static let questionStarts: [[String]] = [
        ["who"],
        ["what"],
        ["when"],
        ["where"],
        ["why"],
        ["how"]
    ]

    static func sanitizedASRText(_ text: String) -> String {
        let collapsedWhitespace = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedWhitespace.isEmpty else { return "" }

        return collapseImmediateRepetitions(in: collapsedWhitespace)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func rewriteChunks(_ text: String, maxWords: Int) -> [String] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var chunks: [String] = []
        var current: [String] = []
        current.reserveCapacity(maxWords)

        for token in tokens {
            current.append(token)
            if current.count >= maxWords || hasTerminalPunctuation(token) {
                chunks.append(current.joined(separator: " "))
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.isEmpty {
            chunks.append(current.joined(separator: " "))
        }
        return chunks
    }

    static func heuristicPunctuation(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return "" }

        var sentences: [[String]] = []
        var current: [String] = []

        for index in tokens.indices {
            if shouldStartNewSentence(at: index, tokens: tokens, currentSentenceWords: current.count) {
                finishSentence(&current, into: &sentences)
            }

            current.append(tokens[index])

            if hasTerminalPunctuation(tokens[index]) || current.count >= hardSentenceWords {
                finishSentence(&current, into: &sentences)
                continue
            }

            if current.count >= softSentenceWords && startsDiscoursePhrase(at: index + 1, tokens: tokens) {
                finishSentence(&current, into: &sentences)
            }
        }

        finishSentence(&current, into: &sentences)
        return sentences.map(formatSentence).joined(separator: " ")
    }

    static func isLikelyEcho(micText: String, systemContext: String) -> Bool {
        let micWords = normalizedWords(micText)
        guard micWords.count >= echoSuppressionMinWords else { return false }

        let systemWords = normalizedWords(systemContext)
        let systemBigrams = shingles(from: systemWords, size: 2)
        let systemTrigrams = shingles(from: systemWords, size: 3)
        return isLikelyEcho(
            micWords: micWords,
            systemWords: systemWords,
            systemBigrams: systemBigrams,
            systemTrigrams: systemTrigrams
        )
    }

    static func isLikelyEcho(
        micText: String,
        systemWords: [String],
        systemBigrams: Set<String>,
        systemTrigrams: Set<String>
    ) -> Bool {
        let micWords = normalizedWords(micText)
        return isLikelyEcho(
            micWords: micWords,
            systemWords: systemWords,
            systemBigrams: systemBigrams,
            systemTrigrams: systemTrigrams
        )
    }

    private static func isLikelyEcho(
        micWords: [String],
        systemWords: [String],
        systemBigrams: Set<String>,
        systemTrigrams: Set<String>
    ) -> Bool {
        guard micWords.count >= echoSuppressionMinWords else { return false }
        guard systemWords.count >= echoSuppressionMinWords else { return false }

        let shingleSize = micWords.count >= 18 ? 3 : 2
        let micShingles = shingles(from: micWords, size: shingleSize)
        let systemShingles = shingleSize == 3 ? systemTrigrams : systemBigrams
        guard !micShingles.isEmpty, !systemShingles.isEmpty else { return false }

        let matches = micShingles.filter { systemShingles.contains($0) }.count
        let containment = Double(matches) / Double(micShingles.count)
        return containment >= echoSuppressionContainmentThreshold
    }

    private static func collapseImmediateRepetitions(in text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count > 1 else { return text }

        let keys = tokens.map(normalizedToken)
        var output: [String] = []
        var index = 0

        while index < tokens.count {
            let remaining = tokens.count - index
            var consumedRepeat = false

            if remaining >= 4 {
                let maxSpan = min(maxRepeatPhraseWords, remaining / 2)
                if maxSpan >= 2 {
                    for span in stride(from: maxSpan, through: 2, by: -1) {
                        let repeats = repeatedSpanCount(keys: keys, start: index, span: span)
                        guard repeats >= 2 else { continue }

                        output.append(contentsOf: tokens[index..<(index + span)])
                        index += span * repeats
                        consumedRepeat = true
                        break
                    }
                }
            }

            if consumedRepeat { continue }

            let singleRepeats = repeatedSpanCount(keys: keys, start: index, span: 1)
            if singleRepeats >= 3 {
                output.append(contentsOf: tokens[index..<(index + 2)])
                index += singleRepeats
            } else {
                output.append(tokens[index])
                index += 1
            }
        }

        return output.joined(separator: " ")
    }

    private static func repeatedSpanCount(keys: [String], start: Int, span: Int) -> Int {
        guard span > 0, start + span <= keys.count else { return 0 }
        let phrase = Array(keys[start..<(start + span)])
        guard phrase.allSatisfy({ !$0.isEmpty }) else { return 0 }

        var repeats = 1
        var cursor = start + span
        while cursor + span <= keys.count {
            let candidate = Array(keys[cursor..<(cursor + span)])
            guard candidate == phrase else { break }
            repeats += 1
            cursor += span
        }
        return repeats
    }

    private static func shouldStartNewSentence(
        at index: Int,
        tokens: [String],
        currentSentenceWords: Int
    ) -> Bool {
        guard currentSentenceWords >= 8 else { return false }
        return startsDiscoursePhrase(at: index, tokens: tokens)
    }

    private static func startsDiscoursePhrase(at index: Int, tokens: [String]) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        for phrase in discourseStarts {
            guard index + phrase.count <= tokens.count else { continue }
            let candidate = tokens[index..<(index + phrase.count)].map(normalizedToken)
            if candidate == phrase { return true }
        }
        return false
    }

    private static func finishSentence(_ current: inout [String], into sentences: inout [[String]]) {
        guard !current.isEmpty else { return }
        sentences.append(current)
        current.removeAll(keepingCapacity: true)
    }

    private static func formatSentence(_ tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        let words = tokens.map(normalizedCapitalization)
        var sentence = words.joined(separator: " ")
        sentence = capitalizingFirstLetter(sentence)

        if !hasTerminalPunctuation(sentence) {
            sentence += terminalPunctuation(for: words)
        }
        return sentence
    }

    private static func terminalPunctuation(for words: [String]) -> String {
        let keys = words.map(normalizedToken)
        for phrase in questionStarts {
            guard keys.count >= phrase.count else { continue }
            if Array(keys.prefix(phrase.count)) == phrase {
                return "?"
            }
        }
        return "."
    }

    private static func normalizedCapitalization(_ token: String) -> String {
        switch token.lowercased() {
        case "i": return "I"
        case "i'm": return "I'm"
        case "i've": return "I've"
        case "i'll": return "I'll"
        case "i'd": return "I'd"
        case "ai": return "AI"
        case "uk": return "UK"
        case "qa": return "Q&A"
        case "cv": return "CV"
        case "esg": return "ESG"
        default: return token
        }
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        var output = text
        output.replaceSubrange(index...index, with: String(output[index]).uppercased())
        return output
    }

    static func hasTerminalPunctuation(_ token: String) -> Bool {
        guard let last = token.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last == "." || last == "!" || last == "?"
    }

    private static func normalizedToken(_ token: String) -> String {
        token.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value == 39
        }.map(String.init).joined()
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalizedToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func shingles(from words: [String], size: Int) -> Set<String> {
        guard size > 0, words.count >= size else { return [] }

        var result = Set<String>()
        for index in 0...(words.count - size) {
            result.insert(words[index..<(index + size)].joined(separator: " "))
        }
        return result
    }
}

/// Shared across rewriter + summarizer; both run on-device LanguageModelSessions
/// that can hang indefinitely if the model stalls.
struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
