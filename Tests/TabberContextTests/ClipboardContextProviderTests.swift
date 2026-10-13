import Foundation
import Testing
@testable import TabberContext

private final class FakePasteboard: PasteboardSource {
    var changeCount = 0
    var types: [String] = ["public.utf8-plain-text"]
    var contents: String? = nil
    var access: ClipboardContextProvider.Access = .allowed
    var reads = 0

    var string: String? {
        reads += 1
        return contents
    }

    func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
        changeCount += 1
        contents = text
        self.types = types
    }
}

private final class Clock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
}

@Suite struct ClipboardRulesTests {
    let config = ClipboardContextProvider.Configuration()

    private func process(_ s: String?, types: [String] = ["public.utf8-plain-text"]) -> String? {
        ClipboardContextProvider.process(types: types, string: s, configuration: config)
    }

    @Test func plainTextPassesThroughTrimmed() {
        #expect(process("  Meeting moved to Thursday at 3pm.\n") == "Meeting moved to Thursday at 3pm.")
    }

    @Test func markedItemsAreSkippedWithoutReadingThem() {
        var read = false
        func contents() -> String? { read = true; return "secret" }
        for marker in ClipboardContextProvider.defaultSkippedTypes {
            let out = ClipboardContextProvider.process(
                types: ["public.utf8-plain-text", marker], string: contents(), configuration: config
            )
            #expect(out == nil)
        }
        #expect(!read)
    }

    @Test func emptyAndSecretTokensAreSkipped() {
        #expect(process(nil) == nil)
        #expect(process("   \n") == nil)
        #expect(process("x8Kq2mPz9LwR4vNt7YbC3dFg") == nil)
        #expect(process("sk-proj-abc123DEF456ghi789JKL") == nil)
        #expect(process("Tr0ub4dor&3") == nil)
        // A single plain word or a URL is fine.
        #expect(process("Thursday") == "Thursday")
        #expect(process("https://example.com/docs/setup") == "https://example.com/docs/setup")
    }

    @Test func longTextIsTruncated() {
        let long = String(repeating: "word ", count: 2000)
        let out = process(long)
        #expect(out?.count == 4000)
    }

    @Test func secretsInsideTextAreRedacted() {
        #expect(process("Here is the login. password: hunter2 thanks") == "Here is the login. password: [redacted] thanks")
    }

    @Test func textThatIsOnlySecretsIsSkipped() {
        #expect(process("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----") == nil)
    }
}

@Suite struct ClipboardProviderTests {
    private func make(_ pb: FakePasteboard, _ clock: Clock, promptOK: Bool = false) -> ClipboardContextProvider {
        var config = ClipboardContextProvider.Configuration()
        config.pollInterval = 0 // no background timer in tests
        config.readWhenItWouldPrompt = promptOK
        return ClipboardContextProvider(configuration: config, source: pb, now: { clock.now })
    }

    @Test func contentFromBeforeLaunchIsNotRecent() {
        let pb = FakePasteboard()
        pb.copy("old stuff copied yesterday")
        let p = make(pb, Clock())
        #expect(p.recentText(maxAge: 60) == nil)
        #expect(pb.reads == 0)
    }

    @Test func recentCopyIsReturnedUntilItAges() {
        let pb = FakePasteboard(), clock = Clock()
        let p = make(pb, clock)
        pb.copy("Order #4471 ships Monday")
        p.poll()
        clock.now += 30
        #expect(p.recentText(maxAge: 60) == "Order #4471 ships Monday")
        clock.now += 31
        #expect(p.recentText(maxAge: 60) == nil)
    }

    @Test func eachCopyIsReadOnce() {
        let pb = FakePasteboard(), clock = Clock()
        let p = make(pb, clock)
        pb.copy("first thing")
        #expect(p.recentText(maxAge: 60) == "first thing")
        #expect(p.recentText(maxAge: 60) == "first thing")
        #expect(pb.reads == 1)
        pb.copy("second thing")
        #expect(p.recentText(maxAge: 60) == "second thing")
        #expect(pb.reads == 2)
    }

    @Test func noReadWhenItWouldPromptOrIsDenied() {
        let pb = FakePasteboard(), clock = Clock()
        pb.access = .prompts
        let p = make(pb, clock)
        pb.copy("hello there")
        #expect(p.recentText(maxAge: 60) == nil)
        #expect(pb.reads == 0)

        let allowing = make(pb, clock, promptOK: true)
        pb.copy("hello again")
        #expect(allowing.recentText(maxAge: 60) == "hello again")

        pb.access = .denied
        let denied = make(pb, clock, promptOK: true)
        pb.copy("and again")
        #expect(denied.recentText(maxAge: 60) == nil)
    }

    @Test func concealedCopiesAreSkipped() {
        let pb = FakePasteboard(), clock = Clock()
        let p = make(pb, clock)
        pb.copy("correct horse battery staple", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        #expect(p.recentText(maxAge: 60) == nil)
        #expect(pb.reads == 0)
    }
}
