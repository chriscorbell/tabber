import CoreGraphics
import Testing
@testable import TabberContext

/// Lines are laid out like a mail window: a message column from x = 300 to 1100, a sidebar at x = 20...200, and the
/// reply field at the bottom of the column.
@Suite struct ScreenTextAssemblerTests {
    let field = CGRect(x: 300, y: 800, width: 800, height: 120)

    private func line(_ text: String, x: CGFloat = 300, y: CGFloat, width: CGFloat? = nil, height: CGFloat = 16,
                      confidence: Float = 0.95) -> RecognizedLine {
        RecognizedLine(text: text, confidence: confidence,
                       box: CGRect(x: x, y: y, width: width ?? CGFloat(text.count) * 7, height: height))
    }

    private func assemble(_ lines: [RecognizedLine], fieldText: String = "", budget: Int = 1800) -> String {
        var options = ScreenTextAssembler.Options()
        options.characterBudget = budget
        return ScreenTextAssembler.assemble(lines, field: field, fieldText: fieldText, options: options)
    }

    @Test func readingOrderIsTopToBottomThenLeftToRight() {
        let lines = [
            line("Thanks for the update on the launch plan.", y: 500),
            line("10:42 AM", x: 1000, y: 400),
            line("Sarah Chen", x: 300, y: 400),
            line("Re: Launch plan", y: 300),
        ]
        #expect(assemble(lines) == "Re: Launch plan\nSarah Chen\n10:42 AM\nThanks for the update on the launch plan.")
    }

    @Test func wrappedLinesMergeIntoParagraphs() {
        let lines = [
            line("Hi Chris, I looked at the numbers you sent", y: 400, width: 760),
            line("over and the forecast looks right to me. Can", y: 420, width: 770),
            line("we ship on Friday?", y: 440, width: 300),
            // A paragraph gap (more than a line height) starts a new paragraph.
            line("Best, Sarah", y: 490, width: 200),
        ]
        #expect(assemble(lines) == """
        Hi Chris, I looked at the numbers you sent over and the forecast looks right to me. Can we ship on Friday?
        Best, Sarah
        """)
    }

    @Test func shortLinesKeepTheirBreaks() {
        let lines = [
            line("Sarah Chen", y: 400, width: 120),
            line("Product Manager", y: 420, width: 180),
            line("Acme Inc.", y: 440, width: 100),
        ]
        #expect(assemble(lines) == "Sarah Chen\nProduct Manager\nAcme Inc.")
    }

    @Test func hyphenatedWrapJoinsWithoutSpace() {
        let lines = [
            line("This is a well-", y: 400, width: 760),
            line("known issue.", y: 420, width: 760),
        ]
        #expect(assemble(lines) == "This is a well-known issue.")
    }

    @Test func dropsLowConfidenceGarbageAndFieldInterior() {
        let lines = [
            line("Real sentence here.", y: 600),
            line("blurry nonsense", y: 620, confidence: 0.2),
            line("|||", y: 640),
            line("•", y: 660),
            line("The qu81ity is go0d", y: 680),
            line("\u{FFFD}\u{FFFD}abc", y: 700),
            // Inside the reply field.
            line("Typed text in the field", y: 840),
        ]
        #expect(assemble(lines) == "Real sentence here.")
    }

    @Test func echoOfTheFieldsOwnTextIsDropped() {
        let fieldText = "Thanks Sarah, I will send the report tomorrow morning."
        let lines = [
            line("Can you send the report?", y: 600),
            line("I will send the report tomorrow", y: 700),          // exact substring
            line("Thanks Sarah, I wi11 send the report", y: 720),      // OCR-mangled near copy
            line("Hi", y: 740),                                       // not a whole word of the field text
        ]
        #expect(assemble(lines, fieldText: fieldText) == "Can you send the report?\nHi")
    }

    @Test func echoMatchesWholeWordsOnly() {
        let echo = EchoFilter(fieldText: "this is it")
        #expect(!echo.isEcho("hi"))
        #expect(echo.isEcho("This is"))
        #expect(echo.isEcho("IS IT!"))
    }

    @Test func loneWordsOutsideTheColumnAreChrome() {
        let lines = [
            line("Inbox", x: 20, y: 300),
            line("Starred", x: 20, y: 330),
            line("Sarah", x: 300, y: 600),
            line("Hello there friend", x: 300, y: 620),
        ]
        #expect(assemble(lines) == "Sarah\nHello there friend")
    }

    @Test func budgetKeepsTheTextClosestToTheField() {
        // 30 lines of 49 characters, top to bottom; only the last ones fit.
        var lines: [RecognizedLine] = []
        for i in 0..<30 {
            let text = String(format: "Line %02d of the message body, padded to length.", i)
            lines.append(line(text, y: CGFloat(100 + i * 22), width: 400))
        }
        let out = assemble(lines, budget: 200)
        #expect(out.count <= 200)
        #expect(out.contains("Line 29"))
        #expect(out.contains("Line 27"))
        #expect(!out.contains("Line 20"))
        // Still in reading order.
        let a = out.range(of: "Line 27")!.lowerBound, b = out.range(of: "Line 29")!.lowerBound
        #expect(a < b)
    }

    @Test func budgetTruncatesTheBoundaryLineAtAWord() {
        let lines = [
            line("Far away line with quite a lot of words in it for sure", y: 300),
            line("Near line just above the field.", y: 760),
        ]
        let out = assemble(lines, budget: 80)
        #expect(out.count <= 80)
        #expect(out.hasSuffix("Near line just above the field."))
        #expect(out.hasPrefix("Far away line"))
        #expect(!out.hasSuffix(" "))
    }

    @Test func inColumnTextOutranksSidebarText() {
        let lines = [
            line("Sidebar entry close to the field", x: 20, y: 780, width: 180),
            line("Message text farther up in the column", x: 300, y: 400),
        ]
        let out = assemble(lines, budget: 45)
        #expect(out == "Message text farther up in the column")
    }

    @Test func textAboveOutranksTextBelow() {
        let lines = [
            line("Text forty points above", y: 800 - 40 - 16),
            line("Text forty points below", y: 920 + 40),
        ]
        #expect(assemble(lines, budget: 30) == "Text forty points above")
        #expect(ScreenTextAssembler.score(lines[0].box, field: field, options: .init())
            < ScreenTextAssembler.score(lines[1].box, field: field, options: .init()))
    }

    @Test func punctuationIsKeptAndOnlyWhitespaceNormalized() {
        let lines = [line("  It's $25 —  50% off:\tdon't   miss it! (today)  ", y: 600)]
        #expect(assemble(lines) == "It's $25 — 50% off: don't miss it! (today)")
    }

    /// Taken from a live capture of a mail thread: the sender's header, the date at the right of the sender's name,
    /// and the message right below with a small gap.
    @Test func timestampBesideASendersNameReadsRightAfterIt() {
        let lines = [
            line("Mon, Oct 5, 9:12 AM", x: 890, y: 166, width: 115, height: 19),
            line("Chris Corbell", x: 240, y: 170, width: 91, height: 15),
            line("to Sarah, Dev", x: 238, y: 185, width: 79, height: 13),
            line("Hi Sarah, can you confirm whether we're still on track for the October 21st launch? I'd like to",
                 x: 240, y: 212, width: 724, height: 17),
            line("agency by Friday.", x: 238, y: 232, width: 113, height: 18),
        ]
        #expect(ScreenTextAssembler.layout(lines) == """
        Chris Corbell
        Mon, Oct 5, 9:12 AM
        to Sarah, Dev
        Hi Sarah, can you confirm whether we're still on track for the October 21st launch? I'd like to agency by Friday.
        """)
    }

    @Test func timestampBesideALaterLineOfABlockReadsAfterThatLine() {
        // From a live capture: the heading merged into the sender's block, so the time sits beside its second line.
        let lines = [
            line("Dinner on Saturday?", x: 237, y: 111, width: 209, height: 30),
            line("Priya Raman", x: 235, y: 165, width: 94, height: 23),
            line("Wed, Oct 7, 6:02 PM", x: 886, y: 163, width: 117, height: 23),
            line("to me", x: 237, y: 186, width: 37, height: 14),
        ]
        #expect(ScreenTextAssembler.layout(lines) == "Dinner on Saturday?\nPriya Raman\nWed, Oct 7, 6:02 PM\nto me")
    }

    @Test func lowercaseAfterAShortLineIsNotAWrap() {
        let lines = [
            line("Chris Corbell", y: 400, width: 91),
            line("to Sarah, Dev", y: 416, width: 79),
            line("Long paragraph line that fills the whole column width here", y: 440, width: 700),
        ]
        #expect(ScreenTextAssembler.layout(lines).hasPrefix("Chris Corbell\nto Sarah, Dev\n"))
    }

    @Test func browserTitleAndAddressBarAreDropped() {
        let lines = [
            line("S Re: Q3 launch timeline - Mail ×", x: 300, y: 13),
            line("• File /tmp/scratch/thread.html", x: 300, y: 57),
            line("Mostly yes, the beta went well.", x: 300, y: 400),
        ]
        var options = ScreenTextAssembler.Options()
        options.characterBudget = 1800
        let out = ScreenTextAssembler.assemble(
            lines, field: field, fieldText: "",
            alsoKnown: ["Re: Q3 launch timeline – Mail - Google Chrome", "file:///tmp/scratch/thread.html"],
            options: options
        )
        #expect(out == "Mostly yes, the beta went well.")
    }

    @Test func emptyInputGivesEmptyText() {
        #expect(assemble([]) == "")
        #expect(assemble([line("x", y: 100)]) == "")
    }
}
