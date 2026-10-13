import Foundation

/// How long suggestions may be, in words. Mirrors the presets users understand.
public enum CompletionLength: String, CaseIterable, Codable, Sendable {
    case short, medium, long, veryLong

    public var wordRange: ClosedRange<Int> {
        switch self {
        case .short: 1...2
        case .medium: 2...4
        case .long: 4...7
        case .veryLong: 7...12
        }
    }

    public var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        case .veryLong: "Very long"
        }
    }
}

/// One request for a continuation of the text before the caret.
public struct CompletionRequest: Sendable, Equatable {
    public var id: UInt64
    /// Stable context placed before the user's text (app, title, screen text, instructions).
    /// Keep it identical across keystrokes in one field so the engine can reuse its cache.
    public var preamble: String
    /// The user's text before the caret. The prompt ends exactly here.
    public var text: String
    /// Text after the caret on the same line, for mid-line suggestions. May be empty.
    public var textAfter: String
    public var maxWords: Int
    public var minWords: Int
    /// Never produce a line break.
    public var singleLine: Bool
    /// Per-word log-probability floor below which the continuation is cut. `nil` uses the engine default.
    public var confidenceFloor: Double?
    /// Optional additive logit bias per word, used for personalization. Keys are lowercase words.
    public var wordBias: [String: Float]

    public init(
        id: UInt64,
        preamble: String,
        text: String,
        textAfter: String = "",
        maxWords: Int = 4,
        minWords: Int = 1,
        singleLine: Bool = true,
        confidenceFloor: Double? = nil,
        wordBias: [String: Float] = [:]
    ) {
        self.id = id
        self.preamble = preamble
        self.text = text
        self.textAfter = textAfter
        self.maxWords = maxWords
        self.minWords = minWords
        self.singleLine = singleLine
        self.confidenceFloor = confidenceFloor
        self.wordBias = wordBias
    }
}

public struct CompletionTimings: Sendable, Equatable {
    /// Tokens of the prompt that had to be evaluated (not reused from cache).
    public var promptTokensEvaluated: Int
    public var promptTokensReused: Int
    public var promptMs: Double
    public var firstTokenMs: Double
    public var totalMs: Double
    public var generatedTokens: Int

    public init(promptTokensEvaluated: Int = 0, promptTokensReused: Int = 0, promptMs: Double = 0, firstTokenMs: Double = 0, totalMs: Double = 0, generatedTokens: Int = 0) {
        self.promptTokensEvaluated = promptTokensEvaluated
        self.promptTokensReused = promptTokensReused
        self.promptMs = promptMs
        self.firstTokenMs = firstTokenMs
        self.totalMs = totalMs
        self.generatedTokens = generatedTokens
    }
}

public struct CompletionResult: Sendable, Equatable {
    public var requestID: UInt64
    /// Text to insert at the caret. Continues `request.text` exactly, including any leading space,
    /// and finishes a partially typed word when the caret is mid-word.
    public var text: String
    /// Mean log-probability per generated token.
    public var meanLogProb: Double
    /// Log-probability of the first word, the part most likely to be accepted.
    public var firstWordLogProb: Double
    /// Other likely first words, best first, for the alternatives picker.
    public var alternatives: [String]
    public var timings: CompletionTimings
    public var stopReason: StopReason
    /// Characters before the caret that `text` replaces (emoji shortcodes). Zero for continuations.
    public var replacing: Int = 0

    public enum StopReason: String, Sendable {
        case wordLimit, lineEnd, sentenceEnd, endOfText, lowConfidence, tokenLimit, cancelled, repetition
    }

    public init(requestID: UInt64, text: String, meanLogProb: Double = 0, firstWordLogProb: Double = 0, alternatives: [String] = [], timings: CompletionTimings = .init(), stopReason: StopReason = .wordLimit, replacing: Int = 0) {
        self.replacing = replacing
        self.requestID = requestID
        self.text = text
        self.meanLogProb = meanLogProb
        self.firstWordLogProb = firstWordLogProb
        self.alternatives = alternatives
        self.timings = timings
        self.stopReason = stopReason
    }
}

public enum CompletionError: Error, Sendable, Equatable {
    case modelNotLoaded
    case cancelled
    case contextTooLong
    case decodeFailed(Int32)
    case loadFailed(String)
}

/// What the session needs from a model. Implemented by `TabberEngine.LlamaEngine`, and by fakes in tests.
public protocol CompletionEngine: AnyObject, Sendable {
    /// Produces a continuation. Implementations cancel any older in-flight request when a new one starts.
    /// `onPartial` receives the growing text while decoding, on an arbitrary thread.
    func complete(_ request: CompletionRequest, onPartial: (@Sendable (String) -> Void)?) async throws -> CompletionResult

    /// Evaluates a prompt ahead of time so the next request only decodes the difference.
    func prewarm(preamble: String, text: String) async

    /// Cancels any in-flight work.
    func cancel()
}
