import Accelerate
import Foundation
import TabberCore
import llama
import os

public struct EngineConfig: Sendable {
    public var contextSize: Int = 4096
    public var batchSize: Int = 512
    /// Layers to offload to Metal. Negative means all.
    public var gpuLayers: Int32 = -1
    /// The GPU does the work; one CPU thread is as fast and uses less energy.
    public var threads: Int32 = 1
    /// Maximum characters of the user's text kept in the prompt.
    public var maxTextChars = 3000
    /// Stop extending at a word boundary when the next word's first token is less likely than this.
    public var wordStartFloor: Double = 0.3
    /// Suppress the whole suggestion when its first new token is less likely than this.
    public var firstTokenFloor: Double = 0.04
    /// Hard cap on generated tokens per allowed word.
    public var tokensPerWord = 4
    /// Branches kept while choosing the first word. 1 means greedy. Forced to 1 for recurrent/hybrid models.
    public var beamWidth = 3
    /// Branches whose next token is less likely than this are dropped.
    public var minBranchProb: Double = 0.05
    /// Suppress the suggestion when its first word (including the word boundary) is less likely than this.
    public var firstWordFloor: Double = 0.0

    public init() {}

    public static var performanceCores: Int32 {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
        return Int32(max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}

/// Information about a loaded model.
public struct LoadedModelInfo: Sendable {
    public var path: String
    public var description: String
    public var parameterCount: UInt64
    public var sizeBytes: UInt64
    public var vocabSize: Int
    public var trainedContext: Int
    public var isRecurrentOrHybrid: Bool
    public var slidingWindow: Int
}

/// Runs a GGUF base model through llama.cpp and produces short continuations of the text before the caret.
///
/// Design:
/// - One llama context, one sequence. All work happens on a private serial queue.
/// - The prompt cache is reused between keystrokes: only tokens after the common prefix are evaluated.
/// - The partially typed word is removed from the prompt and re-imposed as a byte-level constraint on the
///   first generated tokens ("token healing"), so the model can pick natural tokens like " jumps" when the
///   user has typed " jum".
/// - Greedy decoding with probability cut-offs: stop at a word boundary when the next word is uncertain,
///   and suppress suggestions whose first token is unlikely.
public final class LlamaEngine: CompletionEngine, @unchecked Sendable {
    public let info: LoadedModelInfo
    public let config: EngineConfig

    let model: OpaquePointer
    let ctx: OpaquePointer
    let vocab: OpaquePointer
    let table: TokenTable
    private let queue = DispatchQueue(label: "tabber.engine", qos: .userInteractive)
    private let log = Logger(subsystem: "app.tabber", category: "engine")

    /// Tokens currently held in the context for sequence 0, in position order.
    var cached: [llama_token] = []
    private var canTrim = true
    /// Increments on every request and cancel. A running job stops when it no longer holds the latest ticket.
    private let ticketLock = OSAllocatedUnfairLock(initialState: UInt64(0))
    /// First tokens of " word" and " Word", cached because personalization asks for the same words often.
    private var firstTokenCache: [String: [Int32]] = [:]

    func firstTokens(of word: String) -> [Int32] {
        if let cached = firstTokenCache[word] { return cached }
        let tokens = [" " + word, " " + word.capitalized].compactMap { tokenize($0, addSpecial: false).first }
        if firstTokenCache.count > 20_000 { firstTokenCache.removeAll() }
        firstTokenCache[word] = tokens
        return tokens
    }

    /// Keeps the start of long texts stable so the cache survives typing.
    private var textCut: (anchor: String, offset: Int)?
    var batch: llama_batch
    /// Scratch copy of one logits row, so personalization biases never modify llama's own buffer.
    let logitScratch: UnsafeMutablePointer<Float>
    /// Tokens kept free after the prompt for the beam's branches and the greedy tail.
    static let generationHeadroom = 256

    private static let backendInit: Void = {
        llama_backend_init()
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            Logger(subsystem: "app.tabber", category: "llama").debug("\(String(cString: text), privacy: .public)")
        }, nil)
    }()

    public init(modelPath: String, config: EngineConfig = EngineConfig()) throws {
        _ = Self.backendInit
        self.config = config

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = config.gpuLayers
        guard let model = llama_model_load_from_file(modelPath, mparams) else {
            throw CompletionError.loadFailed("Could not load \(modelPath)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(config.contextSize)
        cparams.n_batch = UInt32(config.batchSize)
        cparams.n_ubatch = UInt32(config.batchSize)
        cparams.n_seq_max = UInt32(config.beamWidth + 1)
        cparams.kv_unified = true
        cparams.n_threads = config.threads
        cparams.n_threads_batch = config.threads
        cparams.swa_full = true
        cparams.no_perf = true
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw CompletionError.loadFailed("Could not create a context for \(modelPath)")
        }

        self.model = model
        self.ctx = ctx
        self.vocab = llama_model_get_vocab(model)
        self.table = TokenTable(vocab: vocab)
        self.batch = llama_batch_init(Int32(config.batchSize), 0, 1)
        self.logitScratch = .allocate(capacity: table.count)

        var desc = [CChar](repeating: 0, count: 256)
        llama_model_desc(model, &desc, desc.count)
        self.info = LoadedModelInfo(
            path: modelPath,
            description: String(cString: desc),
            parameterCount: llama_model_n_params(model),
            sizeBytes: llama_model_size(model),
            vocabSize: table.count,
            trainedContext: Int(llama_model_n_ctx_train(model)),
            isRecurrentOrHybrid: llama_model_is_recurrent(model) || llama_model_is_hybrid(model),
            slidingWindow: Int(llama_model_n_swa(model))
        )
    }

    deinit {
        logitScratch.deallocate()
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: - CompletionEngine

    public func complete(_ request: CompletionRequest, onPartial: (@Sendable (String) -> Void)?) async throws -> CompletionResult {
        let ticket = ticketLock.withLock { t -> UInt64 in t += 1; return t }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CompletionResult, Error>) in
                queue.async {
                    do {
                        cont.resume(returning: try self.run(request, ticket: ticket, onPartial: onPartial))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.ticketLock.withLock { t in if t == ticket { t += 1 } }
        }
    }

    public func prewarm(preamble: String, text: String) async {
        // Runs after any request in flight and yields to any newer one, without cancelling it.
        let ticket = ticketLock.withLock { $0 }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let plan = self.plan(preamble: preamble, text: text)
                _ = try? self.evaluate(prompt: plan.tokens, ticket: ticket)
                cont.resume()
            }
        }
    }

    public func cancel() {
        ticketLock.withLock { $0 += 1 }
    }

    /// Runs a request synchronously on the caller's thread. For tests and the bench tool.
    public func completeSync(_ request: CompletionRequest) throws -> CompletionResult {
        let ticket = ticketLock.withLock { t -> UInt64 in t += 1; return t }
        return try queue.sync { try run(request, ticket: ticket, onPartial: nil) }
    }

    func isCurrent(_ ticket: UInt64) -> Bool {
        ticketLock.withLock { $0 == ticket }
    }

    // MARK: - Prompt planning

    struct Plan {
        var tokens: [llama_token]
        /// Bytes the continuation must start with: the part of the user's text removed for token healing.
        var required: [UInt8]
        var keptText: String
    }

    func plan(preamble: String, text fullText: String) -> Plan {
        let text = stableWindow(fullText)

        // Choose where the prompt ends: before the partial word (and the space before it), before
        // trailing spaces, or before a trailing punctuation mark.
        var cut = text.endIndex
        let partial = TextRules.partialWord(before: text)
        if !partial.isEmpty {
            cut = partial.startIndex
            if cut > text.startIndex, text[text.index(before: cut)] == " " { cut = text.index(before: cut) }
        } else {
            while cut > text.startIndex, text[text.index(before: cut)] == " " || text[text.index(before: cut)] == "\t" {
                cut = text.index(before: cut)
            }
            if cut == text.endIndex, let last = text.last, !last.isNewline, !TextRules.isWordCharacter(last) {
                cut = text.index(before: cut)
            }
        }
        var required = Array(text[cut...].utf8)
        // Very long fragments (URLs, pasted tokens): keep only the tail constrained.
        if required.count > 48 {
            let keep = text[cut...].suffix(24)
            cut = keep.startIndex
            required = Array(keep.utf8)
        }
        var tokens = tokenize(preamble + text[..<cut], addSpecial: true)
        // Character budgets don't bound tokens for every script: shed the preamble, then old text.
        let budget = config.contextSize - Self.generationHeadroom - 8
        if tokens.count > budget {
            tokens = tokenize(String(text[..<cut]), addSpecial: true)
            var kept = text[..<cut]
            while tokens.count > budget, kept.count > 64 {
                kept = kept.suffix(kept.count * budget / max(tokens.count, 1) * 9 / 10)
                tokens = tokenize(String(kept), addSpecial: true)
            }
        }
        return Plan(tokens: tokens, required: required, keptText: text)
    }

    /// Cuts long text so that the start stays put while the user types, keeping the cache valid.
    private func stableWindow(_ text: String) -> String {
        let limit = config.maxTextChars
        guard text.count > limit else { textCut = nil; return text }
        if let cut = textCut, let r = text.range(of: cut.anchor, options: .backwards) {
            let tail = text[r.lowerBound...]
            if tail.count <= limit { return String(tail) }
        }
        // Leave room to grow: start three quarters of the limit back, at a word boundary.
        var start = text.index(text.endIndex, offsetBy: -(limit * 3 / 4))
        while start < text.endIndex, !text[start].isWhitespace { start = text.index(after: start) }
        while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
        let tail = text[start...]
        textCut = (String(tail.prefix(48)), 0)
        return String(tail)
    }

    func tokenize(_ s: String, addSpecial: Bool) -> [llama_token] {
        let utf8 = Array(s.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = utf8.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
            }
        }
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = utf8.withUnsafeBufferPointer { p in
                p.withMemoryRebound(to: CChar.self) {
                    llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
                }
            }
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    // MARK: - Evaluation

    /// Brings the context to hold exactly `prompt`, reusing the common prefix. Returns tokens evaluated.
    @discardableResult
    private func evaluate(prompt: [llama_token], ticket: UInt64) throws -> (evaluated: Int, reused: Int) {
        guard prompt.count + Self.generationHeadroom < config.contextSize else { throw CompletionError.contextTooLong }
        let mem = llama_get_memory(ctx)
        // Nothing but sequence 0 should survive between requests.
        for s in 1...Int32(max(1, config.beamWidth)) { llama_memory_seq_rm(mem, s, -1, -1) }

        var common = 0
        let limit = min(cached.count, prompt.count)
        while common < limit, cached[common] == prompt[common] { common += 1 }
        // Always evaluate at least the last token so fresh logits exist.
        if common == prompt.count { common = prompt.count - 1 }

        if common < cached.count {
            if !llama_memory_seq_rm(mem, 0, Int32(common), -1) {
                llama_memory_clear(mem, true)
                common = 0
            }
            cached.removeSubrange(common...)
        }

        var i = common
        while i < prompt.count {
            guard isCurrent(ticket) else { throw CompletionError.cancelled }
            let n = min(config.batchSize, prompt.count - i)
            batch.n_tokens = Int32(n)
            for j in 0..<n {
                batch.token[j] = prompt[i + j]
                batch.pos[j] = Int32(i + j)
                batch.n_seq_id[j] = 1
                batch.seq_id[j]![0] = 0
                batch.logits[j] = (i + j == prompt.count - 1) ? 1 : 0
            }
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                // Leave the cache consistent: drop whatever this batch may have added.
                llama_memory_clear(mem, true)
                cached.removeAll()
                throw CompletionError.decodeFailed(rc)
            }
            cached.append(contentsOf: prompt[i..<(i + n)])
            i += n
        }
        return (prompt.count - common, common)
    }

    func decodeOne(_ token: llama_token) throws {
        batch.n_tokens = 1
        batch.token[0] = token
        batch.pos[0] = Int32(cached.count)
        batch.n_seq_id[0] = 1
        batch.seq_id[0]![0] = 0
        batch.logits[0] = 1
        let rc = llama_decode(ctx, batch)
        guard rc == 0 else { throw CompletionError.decodeFailed(rc) }
        cached.append(token)
    }

    // MARK: - Generation

    private func run(_ request: CompletionRequest, ticket: UInt64, onPartial: (@Sendable (String) -> Void)?) throws -> CompletionResult {
        let start = DispatchTime.now()
        let plan = plan(preamble: request.preamble, text: request.text)
        guard !plan.tokens.isEmpty else { return CompletionResult(requestID: request.id, text: "", stopReason: .endOfText) }
        let (evaluated, reused) = try evaluate(prompt: plan.tokens, ticket: ticket)
        let promptMs = Self.ms(since: start)

        let promptLength = cached.count
        var search: SearchOutcome
        do {
            search = try searchCompletion(request: request, plan: plan, ticket: ticket, onPartial: onPartial)
        } catch {
            restoreCache(toPromptLength: promptLength)
            throw error
        }

        var text = search.text
        if let r = text.range(of: "\"\"\"") { text = String(text[..<r.lowerBound]) }
        if request.singleLine, let nl = text.firstIndex(where: { $0.isNewline }) { text = String(text[..<nl]) }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if Self.isRepetition(text, of: request.text) { text = ""; search.stop = .repetition }
        if !request.textAfter.isEmpty { text = Self.trimmingOverlap(text, with: request.textAfter) }
        text = Self.cuttingPlaceholders(text)

        return CompletionResult(
            requestID: request.id,
            text: text,
            meanLogProb: search.meanLogProb,
            firstWordLogProb: search.firstWordLogProb,
            alternatives: search.alternatives,
            timings: CompletionTimings(
                promptTokensEvaluated: evaluated,
                promptTokensReused: reused,
                promptMs: promptMs,
                firstTokenMs: search.firstTokenMs,
                totalMs: Self.ms(since: start),
                generatedTokens: search.generatedTokens
            ),
            stopReason: search.stop
        )
    }

    /// After a cancelled or failed search: drop branch sequences and anything past the prompt, so that
    /// `cached` matches llama's memory exactly.
    func restoreCache(toPromptLength length: Int) {
        let mem = llama_get_memory(ctx)
        for s in 1...Int32(max(1, config.beamWidth)) { llama_memory_seq_rm(mem, s, -1, -1) }
        if llama_memory_seq_rm(mem, 0, Int32(length), -1) {
            cached = Array(cached.prefix(length))
        } else {
            llama_memory_clear(mem, true)
            cached.removeAll()
        }
    }

    static func ms(since t: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6 }

    /// The part of the generated bytes the user hasn't typed yet, as valid UTF-8.
    func visibleText(_ out: [UInt8], requiredCount: Int) -> String {
        guard out.count > requiredCount else { return "" }
        var bytes = Array(out[requiredCount...])
        // Drop an incomplete trailing UTF-8 sequence.
        for _ in 0..<4 where !bytes.isEmpty {
            if Self.isValidUTF8(bytes) { break }
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var it = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    static func looksLikeAbbreviation(_ s: String) -> Bool {
        let lower = s.lowercased()
        for a in ["e.g.", "i.e.", "etc.", "mr.", "mrs.", "ms.", "dr.", "vs.", "approx.", "st."] where lower.hasSuffix(a) { return true }
        // A single letter followed by a period ("J.") is usually an initial.
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 {
            let chars = Array(trimmed)
            if chars[chars.count - 1] == ".", chars[chars.count - 2].isUppercase, chars.count == 2 || chars[chars.count - 3] == " " { return true }
        }
        return false
    }

    /// Mid-line: drop the end of the suggestion where it would repeat the text already after the caret.
    static func trimmingOverlap(_ suggestion: String, with after: String) -> String {
        let after = after.drop { $0 == " " }
        guard !after.isEmpty, !suggestion.isEmpty else { return suggestion }
        // The suggestion runs into the following text: cut before the overlap.
        let s = Array(suggestion), a = Array(after)
        for len in stride(from: min(s.count, a.count), through: 3, by: -1) where Array(s.suffix(len)) == Array(a.prefix(len)) {
            var cut = String(s.dropLast(len))
            while let last = cut.last, last == " " { cut.removeLast() }
            return cut
        }
        if let r = suggestion.range(of: String(after.prefix(12))), after.count >= 6 {
            var cut = String(suggestion[..<r.lowerBound])
            while let last = cut.last, last == " " { cut.removeLast() }
            return cut
        }
        return suggestion
    }

    /// Drops template placeholders ("[Job Title]", "{name}", "<Company>") and everything after them.
    static func cuttingPlaceholders(_ text: String) -> String {
        guard let r = text.range(of: #"[\[{<][A-Za-z][^\]}>\n]{0,40}([\]}>]|$)"#, options: .regularExpression) else { return text }
        var cut = String(text[..<r.lowerBound])
        while let last = cut.last, last == " " { cut.removeLast() }
        return cut
    }

    /// True when the suggestion just repeats the end of the text.
    static func isRepetition(_ suggestion: String, of text: String) -> Bool {
        let s = suggestion.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.count >= 12 else { return false }
        return text.suffix(300).lowercased().contains(s)
    }

    /// Maps word biases to the first token of " word" and "word".
    func wordBiasTokens(_ bias: [String: Float]) -> [Int32: Float] {
        guard !bias.isEmpty else { return [:] }
        var out: [Int32: Float] = [:]
        for (word, b) in bias {
            for first in firstTokens(of: word) { out[first, default: 0] = max(out[first, default: 0], b) }
        }
        return out
    }
}
