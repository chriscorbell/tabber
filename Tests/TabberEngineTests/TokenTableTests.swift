import Foundation
import Testing
@testable import TabberEngine
import TabberCore

private let modelPath = NSHomeDirectory() + "/Library/Application Support/Tabber/Models/Qwen3-1.7B-Base.i1-Q4_K_M.gguf"

/// These run only when the small Qwen model is installed locally.
@Suite(.enabled(if: FileManager.default.fileExists(atPath: modelPath)), .serialized)
struct EngineTests {
    static let engine = try! LlamaEngine(modelPath: modelPath)

    @Test func consistentTokensIncludeWholeWord() {
        var found: [String] = []
        Self.engine.table.forEachConsistent(with: Array(" anythi".utf8)[...]) { t in
            found.append(String(decoding: Self.engine.table.bytes[Int(t)], as: UTF8.self))
        }
        #expect(found.contains(" anything"))
        #expect(found.contains(" any"))
    }

    @Test func healingCutsBeforeThePartialWord() {
        #expect(String(decoding: Self.engine.plan(preamble: "", text: "Thanks for the invit").required, as: UTF8.self) == " invit")
        #expect(String(decoding: Self.engine.plan(preamble: "", text: "See you ").required, as: UTF8.self) == " ")
        #expect(String(decoding: Self.engine.plan(preamble: "", text: "Hello,").required, as: UTF8.self) == ",")
    }

    @Test func finishesPartialWord() throws {
        let r = try Self.engine.completeSync(CompletionRequest(id: 1, preamble: "", text: "Please let me know if you need anythi"))
        #expect(r.text.hasPrefix("ng"))
    }

    @Test func continuesAfterTrailingSpaceWithoutDoubleSpace() throws {
        let r = try Self.engine.completeSync(CompletionRequest(id: 2, preamble: "", text: "The capital of France is "))
        #expect(!r.text.hasPrefix(" "))
        #expect(r.text.contains("Paris"))
    }

    @Test func reusesCacheAcrossKeystrokes() throws {
        _ = try Self.engine.completeSync(CompletionRequest(id: 3, preamble: "", text: "I'm writing to let you know that the meeting"))
        let r = try Self.engine.completeSync(CompletionRequest(id: 4, preamble: "", text: "I'm writing to let you know that the meeting is"))
        #expect(r.timings.promptTokensReused > 5)
        #expect(r.timings.promptTokensEvaluated <= 3)
    }

    @Test func cacheStaysConsistentAfterCancellation() async throws {
        let engine = Self.engine
        let text = "We should meet next week to talk about the roadmap and the hiring plan for the"
        // Start a request and cancel it while it is decoding.
        let task = Task { try await engine.complete(CompletionRequest(id: 10, preamble: "", text: text), onPartial: nil) }
        try await Task.sleep(nanoseconds: 3_000_000)
        engine.cancel()
        _ = try? await task.value
        // The next keystroke must still reuse the prompt and succeed.
        let r = try engine.completeSync(CompletionRequest(id: 11, preamble: "", text: text + " "))
        #expect(r.timings.promptTokensEvaluated < 10)
    }

    @Test func prewarmDoesNotCancelRunningRequest() async throws {
        let engine = Self.engine
        async let result = engine.complete(CompletionRequest(id: 12, preamble: "", text: "Thanks again for your help with the"), onPartial: nil)
        await engine.prewarm(preamble: "App: Mail\n\n", text: "Thanks again for your help with the")
        let r = try await result
        #expect(r.requestID == 12)
    }

    @Test func alternativesAreForTheSuggestedWord() throws {
        let r = try Self.engine.completeSync(CompletionRequest(id: 20, preamble: "", text: "Let's meet next week to discuss the"))
        // The typed "the" is complete, so alternatives are other next words, each starting with a space.
        #expect(!r.alternatives.isEmpty)
        #expect(r.alternatives.allSatisfy { $0.first == " " && !$0.hasPrefix(" the") })
    }

    @Test func placeholdersAreCut() {
        #expect(LlamaEngine.cuttingPlaceholders(" [Job Title] at [Company") == "")
        #expect(LlamaEngine.cuttingPlaceholders(" the role of [Job Title]") == " the role of")
        #expect(LlamaEngine.cuttingPlaceholders(" a < b") == " a < b")
        #expect(LlamaEngine.cuttingPlaceholders(" next week") == " next week")
    }

    @Test func midLineTrimsOverlap() {
        #expect(LlamaEngine.trimmingOverlap("the lazy dog", with: " dog jumped") == "the lazy")
        #expect(LlamaEngine.trimmingOverlap("quick brown", with: " fox") == "quick brown")
    }
}
