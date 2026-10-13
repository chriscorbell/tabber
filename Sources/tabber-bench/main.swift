import Foundation
import TabberCore
import TabberEngine

// tabber-bench: measures suggestion quality and latency by simulating a user typing real passages.
//
//   tabber-bench simulate --model <path.gguf> [--model ...] [--passages bench/passages.json]
//                         [--length short|medium|long] [--no-context] [--floor 0.12] [--limit N]
//   tabber-bench complete --model <path.gguf> --text "..." [--preamble "..."]
//
// The simulated user reads the ghost text and presses Tab once per word while the next word matches what
// they meant to write, otherwise types the next character. Savings = 1 - keystrokes / characters.

struct Passage: Decodable {
    var id: String
    var app: String?
    var title: String?
    var domain: String?
    var screen: String?
    var text: String
}

struct Options {
    var command = "simulate"
    var models: [String] = []
    var passages = "bench/passages.json"
    var length: CompletionLength = .medium
    var useContext = true
    var floor: Double?
    var firstFloor: Double?
    var limit = Int.max
    var text = ""
    var preamble = ""
    var verbose = false
    var only: String?
    var threads: Int32?
    var beam: Int?
    var style: PromptBuilder.Style = .quoted
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("--") { o.command = first; args.removeFirst() }
    var i = 0
    func next() -> String { i += 1; return i < args.count ? args[i] : "" }
    while i < args.count {
        switch args[i] {
        case "--model": o.models.append(next())
        case "--passages": o.passages = next()
        case "--length": o.length = CompletionLength(rawValue: next()) ?? .medium
        case "--no-context": o.useContext = false
        case "--floor": o.floor = Double(next())
        case "--first-floor": o.firstFloor = Double(next())
        case "--limit": o.limit = Int(next()) ?? .max
        case "--text": o.text = next()
        case "--preamble": o.preamble = next()
        case "--only": o.only = next()
        case "--threads": o.threads = Int32(next())
        case "--beam": o.beam = Int(next())
        case "--prompt-style": o.style = PromptBuilder.Style(rawValue: next()) ?? .quoted
        case "-v", "--verbose": o.verbose = true
        default: FileHandle.standardError.write("unknown argument \(args[i])\n".data(using: .utf8)!)
        }
        i += 1
    }
    return o
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func preamble(for p: Passage, useContext: Bool, style: PromptBuilder.Style) -> String {
    guard useContext else { return "" }
    return PromptBuilder.preamble(for: PromptContext(appName: p.app, windowTitle: p.title, domain: p.domain, screenText: p.screen), style: style)
}

struct Stats {
    var chars = 0
    var keystrokes = 0
    var tabs = 0
    var requests = 0
    var shown = 0
    var acceptedWords = 0
    var shownWords = 0
    var firstWordHits = 0
    var latencies: [Double] = []
    var promptEval: [Double] = []
}

func simulate(engine: LlamaEngine, passages: [Passage], options: Options) -> Stats {
    var total = Stats()
    var engineConfigFloor = options.floor
    _ = engineConfigFloor
    for p in passages.prefix(options.limit) {
        var s = Stats()
        let truth = Array(p.text)
        let pre = preamble(for: p, useContext: options.useContext, style: options.style)
        var typed = ""
        var pos = 0
        var remainder: Substring = ""   // the ghost currently on screen
        var nextID: UInt64 = 1
        // Start after the first word, as people rarely get suggestions in an empty field.
        while pos < truth.count, !(truth[pos] == " " && typed.count >= 3) {
            typed.append(truth[pos]); pos += 1; s.keystrokes += 1
        }
        while pos < truth.count {
            let rest = String(truth[pos...])
            if remainder.isEmpty {
                var req = CompletionRequest(id: nextID, preamble: pre, text: typed, maxWords: options.length.wordRange.upperBound, minWords: options.length.wordRange.lowerBound)
                if let f = options.floor { req.confidenceFloor = log(f) }
                nextID += 1
                if let result = try? engine.completeSync(req) {
                    s.requests += 1
                    s.latencies.append(result.timings.totalMs)
                    s.promptEval.append(Double(result.timings.promptTokensEvaluated))
                    remainder = Substring(result.text)
                    if !result.text.isEmpty {
                        s.shown += 1
                        s.shownWords += TextRules.wordCount(result.text)
                        let first = TextRules.nextChunk(of: Substring(result.text))
                        if rest.hasPrefix(first) { s.firstWordHits += 1 }
                    }
                    if options.verbose {
                        let ok = rest.hasPrefix(result.text) ? "✓" : " "
                        print("  \(ok) …\(typed.suffix(40).replacingOccurrences(of: "\n", with: "⏎"))⟨\(result.text)⟩  \(String(format: "%.0fms", result.timings.totalMs)) [\(result.stopReason.rawValue)]")
                    }
                }
            }
            // Accept words while they match what the user meant to write.
            var accepted = false
            while !remainder.isEmpty {
                let chunk = TextRules.nextChunk(of: remainder)
                let restNow = String(truth[pos...])
                guard !chunk.isEmpty, restNow.hasPrefix(chunk) else { break }
                // A chunk must end at a real word boundary of the intended text, or at the end of it.
                let endIdx = pos + chunk.count
                if endIdx < truth.count, TextRules.isWordCharacter(truth[endIdx]), let lastC = chunk.last, TextRules.isWordCharacter(lastC) { break }
                typed += chunk
                pos += chunk.count
                remainder = remainder.dropFirst(chunk.count)
                s.tabs += 1
                s.keystrokes += 1
                s.acceptedWords += 1
                accepted = true
            }
            if accepted { if remainder.isEmpty { continue } else { remainder = ""; continue } }
            guard pos < truth.count else { break }
            // Type one character; keep the ghost if it still matches.
            let c = truth[pos]
            typed.append(c); pos += 1; s.keystrokes += 1
            if remainder.first == c { remainder = remainder.dropFirst() } else { remainder = "" }
        }
        s.chars = truth.count
        let saving = 1 - Double(s.keystrokes) / Double(max(1, s.chars))
        print(String(format: "%@  saved %4.1f%%  shown %3d/%3d  accepted %3d words  p50 %4.0fms p95 %4.0fms", p.id.padding(toLength: 22, withPad: " ", startingAt: 0), saving * 100, s.shown, s.requests, s.acceptedWords, percentile(s.latencies, 0.5), percentile(s.latencies, 0.95)))
        total.chars += s.chars
        total.keystrokes += s.keystrokes
        total.tabs += s.tabs
        total.requests += s.requests
        total.shown += s.shown
        total.acceptedWords += s.acceptedWords
        total.shownWords += s.shownWords
        total.firstWordHits += s.firstWordHits
        total.latencies += s.latencies
        total.promptEval += s.promptEval
    }
    return total
}

let options = parse()
switch options.command {
case "complete":
    for path in options.models {
        let engine = try LlamaEngine(modelPath: path)
        let r = try engine.completeSync(CompletionRequest(id: 1, preamble: options.preamble, text: options.text, maxWords: options.length.wordRange.upperBound, minWords: options.length.wordRange.lowerBound))
        print("\(engine.info.description): ⟨\(r.text)⟩ \(r.stopReason) \(String(format: "%.1fms", r.timings.totalMs)) eval=\(r.timings.promptTokensEvaluated)")
    }
case "simulate":
    let data = try Data(contentsOf: URL(fileURLWithPath: options.passages))
    var passages = try JSONDecoder().decode([Passage].self, from: data)
    if let only = options.only { passages = passages.filter { $0.id.contains(only) } }
    for path in options.models {
        var config = EngineConfig()
        if let f = options.floor { config.wordStartFloor = f }
        if let f = options.firstFloor { config.firstWordFloor = f }
        if let t = options.threads { config.threads = t }
        if let b = options.beam { config.beamWidth = b }
        let loadStart = Date()
        let engine = try LlamaEngine(modelPath: path, config: config)
        print("== \(URL(fileURLWithPath: path).lastPathComponent) — \(engine.info.description), loaded in \(String(format: "%.1fs", Date().timeIntervalSince(loadStart))), hybrid=\(engine.info.isRecurrentOrHybrid) swa=\(engine.info.slidingWindow)")
        let t = simulate(engine: engine, passages: passages, options: options)
        let saving = 1 - Double(t.keystrokes) / Double(max(1, t.chars))
        let precision = Double(t.acceptedWords) / Double(max(1, t.shownWords))
        print(String(format: "TOTAL saved %.1f%%  requests %d  shown %.0f%%  first-word right %.0f%%  word precision %.0f%%  latency p50 %.0fms p90 %.0fms p99 %.0fms  eval tokens p50 %.0f", saving * 100, t.requests, Double(t.shown) / Double(max(1, t.requests)) * 100, Double(t.firstWordHits) / Double(max(1, t.shown)) * 100, precision * 100, percentile(t.latencies, 0.5), percentile(t.latencies, 0.9), percentile(t.latencies, 0.99), percentile(t.promptEval, 0.5)))
    }
default:
    print("usage: tabber-bench simulate|complete --model <path> ...")
}
