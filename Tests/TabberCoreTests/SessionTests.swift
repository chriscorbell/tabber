import Foundation
import Testing
@testable import TabberCore

private let app = AppIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 42)
private let field = FieldIdentity(pid: 42, elementHash: 7, role: "AXTextArea")

private func snap(_ before: String, after: String = "", field: FieldIdentity = field) -> FieldSnapshot {
    FieldSnapshot(app: app, field: field, role: "AXTextArea", textBeforeCaret: before, textAfterCaret: after,
                  caret: CaretGeometry(rect: CGRect(x: 100, y: 100, width: 1, height: 16), quality: .exact))
}

private func requests(_ effects: [SessionEffect]) -> [CompletionRequest] {
    effects.compactMap { if case .request(let r) = $0 { return r } else { return nil } }
}

private func shown(_ effects: [SessionEffect]) -> Ghost? {
    effects.compactMap { if case .show(let g, _) = $0 { return g } else { return nil } }.last
}

private func inserted(_ effects: [SessionEffect]) -> String? {
    effects.compactMap { if case .insert(let s) = $0 { return s } else { return nil } }.first
}

@Suite struct SessionTests {
    @Test func requestsThenShowsSuggestion() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("Hello, how are")))).first)
        #expect(r.text == "Hello, how are")
        let effects = s.handle(.completion(CompletionResult(requestID: r.id, text: " you doing today")))
        let g = try #require(shown(effects))
        #expect(g.remainder == " you doing today")
        #expect(s.acceptableRemainder == " you doing today")
    }

    @Test func noRequestInEmptyOrSecureField() {
        var s = Session()
        #expect(requests(s.handle(.snapshot(snap("")))).isEmpty)
        var secure = snap("my password is")
        secure.isSecure = true
        #expect(requests(s.handle(.snapshot(secure))).isEmpty)
    }

    @Test func noRequestMidLineUnlessAllowed() {
        var s = Session()
        #expect(requests(s.handle(.snapshot(snap("Hello there", after: " friend")))).isEmpty)
        s.policy.allowMidLine = true
        #expect(!requests(s.handle(.snapshot(snap("Hello there", after: " friend")))).isEmpty)
    }

    @Test func noRequestInsideWord() {
        var s = Session()
        s.policy.allowMidLine = true
        #expect(requests(s.handle(.snapshot(snap("Hello th", after: "ere")))).isEmpty)
    }

    @Test func typingThroughAdvancesWithoutNewRequest() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("See you")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " tomorrow morning")))
        let typed = s.handle(.typed(" to"))
        #expect(shown(typed)?.remainder == "morrow morning")
        // The app catches up: same ghost, no request.
        let effects = s.handle(.snapshot(snap("See you to")))
        #expect(requests(effects).isEmpty)
        #expect(shown(effects)?.remainder == "morrow morning")
    }

    @Test func laggingSnapshotDoesNotRewindGhost() throws {
        var s = Session()
        let t0 = Date()
        let r = try #require(requests(s.handle(.snapshot(snap("See you")), now: t0)).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " tomorrow")), now: t0)
        _ = s.handle(.typed(" t"), now: t0)
        _ = s.handle(.typed("o"), now: t0)
        // The app has only published the first character so far.
        let effects = s.handle(.snapshot(snap("See you ")), now: t0.addingTimeInterval(0.05))
        #expect(shown(effects)?.remainder == "morrow")
    }

    @Test func divergingTypingHidesAndRequestsAgain() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("See you")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " tomorrow")))
        let typedEffects = s.handle(.typed(" n"))
        #expect(typedEffects.contains(.hide))
        #expect(s.ghost == nil)
        let effects = s.handle(.snapshot(snap("See you n")))
        #expect(requests(effects).first?.text == "See you n")
    }

    @Test func acceptWordInsertsNextWordOnly() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("The quick")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " brown fox jumps")))
        let e1 = s.handle(.accept(.word))
        #expect(inserted(e1) == " brown")
        #expect(shown(e1)?.remainder == " fox jumps")
        let e2 = s.handle(.accept(.all))
        #expect(inserted(e2) == " fox jumps")
        // Exhausted: asks for the next suggestion against the predicted text.
        #expect(requests(e2).first?.text == "The quick brown fox jumps")
    }

    @Test func acceptFinishesPartialWord() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("Thanks for the invit")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: "ation to the party")))
        #expect(inserted(s.handle(.accept(.word))) == "ation")
    }

    @Test func resultFitsTextTypedWhileGenerating() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("I will")))).first)
        // The user typed " se" before the result came back.
        _ = s.handle(.snapshot(snap("I will se")))
        // A newer request is pending now, so the old result is ignored.
        let stale = s.handle(.completion(CompletionResult(requestID: r.id, text: " send it")))
        #expect(shown(stale) == nil)
        let r2 = try #require(s.pending)
        let fresh = s.handle(.completion(CompletionResult(requestID: r2.id, text: "nd it now")))
        #expect(shown(fresh)?.remainder == "nd it now")
    }

    @Test func dismissSuppressesUntilTextChanges() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("Let me know")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " if you need anything")))
        #expect(s.handle(.dismiss).contains(.hide))
        #expect(requests(s.handle(.snapshot(snap("Let me know")))).isEmpty)
        _ = s.handle(.typed(" w"))
        #expect(!requests(s.handle(.snapshot(snap("Let me know w")))).isEmpty)
    }

    @Test func fieldChangeHidesGhost() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("Hello there")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " friend")))
        let other = FieldIdentity(pid: 42, elementHash: 8, role: "AXTextArea")
        let effects = s.handle(.snapshot(snap("Other text here", field: other)))
        #expect(effects.contains(.hide))
        #expect(requests(effects).first?.text == "Other text here")
    }

    @Test func slidingWindowStillMatchesGhost() throws {
        var s = Session()
        let long = String(repeating: "word ", count: 100) + "and then"
        let r = try #require(requests(s.handle(.snapshot(snap(long)))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " some more")))
        _ = s.handle(.typed(" s"))
        // The reader returns a window that slid forward by a few characters.
        let slid = String(long.dropFirst(10)) + " s"
        #expect(shown(s.handle(.snapshot(snap(slid))))?.remainder == "ome more")
    }
}

@Suite struct TextRulesTests {
    @Test func nextChunk() {
        #expect(TextRules.nextChunk(of: " brown fox") == " brown")
        #expect(TextRules.nextChunk(of: "ation to") == "ation")
        #expect(TextRules.nextChunk(of: " dog. Then") == " dog.")
        #expect(TextRules.nextChunk(of: " dog. Then", includeTrailingPunctuation: false) == " dog")
        #expect(TextRules.nextChunk(of: " dog then", includeTrailingSpace: true) == " dog ")
        #expect(TextRules.nextChunk(of: ", and") == ",")
        #expect(TextRules.nextChunk(of: "\nNext") == "\n")
    }

    @Test func partialWord() {
        #expect(TextRules.partialWord(before: "Hello wor") == "wor")
        #expect(TextRules.partialWord(before: "Hello ") == "")
        #expect(TextRules.partialWord(before: "don't") == "don't")
    }

    @Test func wordCount() {
        #expect(TextRules.wordCount(" a quick  test") == 3)
        #expect(TextRules.wordCount("") == 0)
    }

    @Test func domainMatching() {
        var o = AppOverride()
        o.enabled = false
        #expect(TabberSettings.matchDomain("mail.google.com", in: ["*.google.com": o]) != nil)
        #expect(TabberSettings.matchDomain("google.com", in: ["google.*": o]) != nil)
        #expect(TabberSettings.matchDomain("example.org", in: ["*.google.com": o]) == nil)
    }
}

@Suite struct EmojiTests {
    @Test func shortcodes() {
        #expect(EmojiSuggester.suggestion(before: "That's great :jo")?.emoji == "😂")
        #expect(EmojiSuggester.suggestion(before: "That's great :joy")?.replacing == 4)
        #expect(EmojiSuggester.suggestion(before: "press :cmd")?.emoji == "⌘")
        #expect(EmojiSuggester.suggestion(before: "at 12:30") == nil)
        #expect(EmojiSuggester.suggestion(before: "see http://x") == nil)
        #expect(EmojiSuggester.suggestion(before: "hello :q") == nil)
    }

    @Test func emoticons() {
        #expect(EmojiSuggester.suggestion(before: "thanks :)")?.emoji == "🙂")
        #expect(EmojiSuggester.suggestion(before: "f(:)") == nil)
    }

    @Test func acceptReplaces() throws {
        var s = Session()
        let snapshot = FieldSnapshot(app: AppIdentity(bundleID: "a", name: "A", pid: 1), field: FieldIdentity(pid: 1, elementHash: 1, role: "AXTextArea"), role: "AXTextArea", textBeforeCaret: "so good :joy")
        let r = try #require(s.handle(.snapshot(snapshot)).compactMap { if case .request(let r) = $0 { return r } else { return nil } }.first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: "😂", replacing: 4)))
        #expect(s.handle(.accept(.word)).contains(.replace(deleting: 4, text: "😂")))
    }
}

@Suite struct GateTests {
    @Test func bareBullets() {
        #expect(Session.endsWithBareBullet("Notes:\n- "))
        #expect(Session.endsWithBareBullet("Todo\n12. "))
        #expect(!Session.endsWithBareBullet("Notes:\n- buy milk"))
        #expect(!Session.endsWithBareBullet("I paid 12."))
    }
}

@Suite struct ReviewRegressionTests {
    @Test func returnDropsPendingResult() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("- buy milk")))).first)
        let e = s.handle(.editingKey)
        #expect(e.contains(.cancelRequest))
        #expect(shown(s.handle(.completion(CompletionResult(requestID: r.id, text: " and eggs")))) == nil)
        #expect(s.acceptableRemainder == nil)
    }

    @Test func mismatchedTypingDropsPendingResult() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("Hello wor")))).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: "ld peace")))
        _ = s.handle(.typed("k"))
        #expect(s.acceptableRemainder == nil)
    }

    @Test func resultDuringTypingIsFittedToNextSnapshot() throws {
        var s = Session()
        let r = try #require(requests(s.handle(.snapshot(snap("I will")))).first)
        _ = s.handle(.typed(" s"))
        // Result arrives before the app publishes " s": held, not shown against the stale text.
        #expect(shown(s.handle(.completion(CompletionResult(requestID: r.id, text: " send it")))) == nil)
        let effects = s.handle(.snapshot(snap("I will s")))
        #expect(shown(effects)?.remainder == "end it")
        #expect(requests(effects).isEmpty)
    }

    @Test func speculativeResultAfterAcceptAllSurvivesLag() throws {
        var s = Session()
        let t0 = Date()
        let r = try #require(requests(s.handle(.snapshot(snap("The quick")), now: t0)).first)
        _ = s.handle(.completion(CompletionResult(requestID: r.id, text: " brown fox")), now: t0)
        let next = try #require(requests(s.handle(.accept(.all), now: t0)).first)
        #expect(next.text == "The quick brown fox")
        _ = s.handle(.completion(CompletionResult(requestID: next.id, text: " jumps over")), now: t0)
        // Lagging snapshot first: no new request, still waiting.
        let lag = s.handle(.snapshot(snap("The quick")), now: t0.addingTimeInterval(0.02))
        #expect(requests(lag).isEmpty)
        // Then the real one: the speculative result shows.
        let real = s.handle(.snapshot(snap("The quick brown fox")), now: t0.addingTimeInterval(0.05))
        #expect(shown(real)?.remainder == " jumps over")
    }
}

@Suite struct FieldKindTests {
    @Test func recipientAndSearchFieldsAreSkipped() {
        var s = FieldSnapshot(app: AppIdentity(bundleID: "com.apple.MobileSMS", name: "Messages", pid: 1), field: FieldIdentity(pid: 1, elementHash: 2, role: "AXTextField"), role: "AXTextField", label: "To:", textBeforeCaret: "Running a few", isSingleLine: true)
        #expect(Session.isAddressOrSearchField(s))
        s.label = "Message"
        #expect(!Session.isAddressOrSearchField(s))
        s.label = nil; s.placeholder = "Search mail"
        #expect(Session.isAddressOrSearchField(s))
    }
}
