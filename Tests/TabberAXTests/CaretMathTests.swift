import CoreGraphics
import Testing
@testable import TabberAX

private let field = CGRect(x: 100, y: 200, width: 400, height: 300)

@Suite struct CaretPlausibilityTests {
    @Test func acceptsACaretInsideTheField() {
        #expect(CaretMath.isPlausible(CGRect(x: 150, y: 220, width: 0, height: 16), field: field))
    }

    @Test func acceptsACaretJustOutsideTheField() {
        // Padding and focus rings: the slack is 60 pt.
        #expect(CaretMath.isPlausible(CGRect(x: 90, y: 190, width: 0, height: 16), field: field))
        #expect(!CaretMath.isPlausible(CGRect(x: 30, y: 220, width: 0, height: 16), field: field))
        #expect(!CaretMath.isPlausible(CGRect(x: 150, y: 600, width: 0, height: 16), field: field))
    }

    @Test func rejectsDegenerateRects() {
        #expect(!CaretMath.isPlausible(CGRect(x: 150, y: 220, width: 0, height: 0), field: field))
        #expect(!CaretMath.isPlausible(CGRect(x: 150, y: 220, width: 0, height: 0.5), field: field))
        #expect(!CaretMath.isPlausible(CGRect(x: 150, y: 220, width: 0, height: 250), field: nil))
        #expect(!CaretMath.isPlausible(CGRect(x: 0, y: 0, width: 0, height: 16), field: nil))
        #expect(!CaretMath.isPlausible(CGRect(x: CGFloat.nan, y: 220, width: 0, height: 16), field: field))
        #expect(!CaretMath.isPlausible(CGRect(x: 150, y: CGFloat.infinity, width: 0, height: 16), field: field))
    }

    @Test func rejectsTheWholeFrameOfAMultiLineField() {
        // Chromium answers some bounds queries with the element's frame.
        let box = CGRect(x: 232, y: 404, width: 538, height: 108)
        #expect(!CaretMath.isPlausible(CGRect(x: 232, y: 404, width: 0, height: 108), field: box))
        // A single-line field's caret can be nearly as tall as the field.
        let line = CGRect(x: 232, y: 530, width: 538, height: 38)
        #expect(CaretMath.isPlausible(CGRect(x: 288, y: 539, width: 0, height: 34), field: line))
    }

    @Test func withoutAFieldOnlyTheShapeIsChecked() {
        #expect(CaretMath.isPlausible(CGRect(x: 5000, y: 3000, width: 0, height: 18), field: nil))
    }

    @Test func characterSized() {
        #expect(CaretMath.isCharacterSized(CGRect(x: 0, y: 0, width: 7, height: 14)))
        #expect(CaretMath.isCharacterSized(CGRect(x: 0, y: 0, width: 28, height: 14)))   // a tab
        #expect(!CaretMath.isCharacterSized(CGRect(x: 0, y: 0, width: 344, height: 13))) // a newline spanning the line
    }
}

@Suite struct CaretRepairTests {
    @Test func repairsABottomLeftOriginRect() {
        let screenHeight: CGFloat = 1000
        let flipped = CGRect(x: 150, y: screenHeight - 236, width: 0, height: 16)   // Quartz y would be 220
        let fixed = CaretMath.repaired(flipped, field: field, primaryScreenHeight: screenHeight, scale: nil)
        #expect(fixed == CGRect(x: 150, y: 220, width: 0, height: 16))
    }

    @Test func repairsBackingPixelRects() {
        let pixels = CGRect(x: 300, y: 440, width: 0, height: 32)
        let fixed = CaretMath.repaired(pixels, field: field, primaryScreenHeight: nil, scale: 2)
        #expect(fixed == CGRect(x: 150, y: 220, width: 0, height: 16))
    }

    @Test func noRepairWhenNothingLandsOnTheField() {
        let wild = CGRect(x: 4000, y: 4000, width: 0, height: 16)
        #expect(CaretMath.repaired(wild, field: field, primaryScreenHeight: 1000, scale: 2) == nil)
        #expect(CaretMath.repaired(wild, field: nil, primaryScreenHeight: 1000, scale: 2) == nil)
    }
}

@Suite struct CaretFromCharacterTests {
    let character = CGRect(x: 200, y: 230, width: 7, height: 14)

    @Test func afterACharacter() {
        #expect(CaretMath.caret(after: character, rightToLeft: false) == CGRect(x: 207, y: 230, width: 0, height: 14))
        #expect(CaretMath.caret(after: character, rightToLeft: true) == CGRect(x: 200, y: 230, width: 0, height: 14))
    }

    @Test func beforeACharacter() {
        #expect(CaretMath.caret(before: character, rightToLeft: false) == CGRect(x: 200, y: 230, width: 0, height: 14))
        #expect(CaretMath.caret(before: character, rightToLeft: true) == CGRect(x: 207, y: 230, width: 0, height: 14))
    }

    @Test func collapsedDropsWidth() {
        #expect(CaretMath.caret(collapsed: CGRect(x: 10, y: 20, width: 3, height: 15)) == CGRect(x: 10, y: 20, width: 0, height: 15))
    }

    @Test func rightToLeftDetection() {
        #expect(CaretMath.textBeforeIsRightToLeft("שלום"))
        #expect(CaretMath.textBeforeIsRightToLeft("مرحبا، "))
        #expect(!CaretMath.textBeforeIsRightToLeft("hello"))
        #expect(!CaretMath.textBeforeIsRightToLeft("שלום\nhello"))
        #expect(!CaretMath.textBeforeIsRightToLeft("hello\n"))   // a new line decides nothing
        #expect(CaretMath.textBeforeIsRightToLeft("hello שלום 123"))
        #expect(!CaretMath.textBeforeIsRightToLeft(""))
    }
}

@Suite struct CollapsedCorrectionTests {
    // Measured in TextEdit on macOS 27: zero-length ranges come back exactly one line (13 pt) too high.

    @Test func movesACaretOffTheLineOfThePreviousNewline() {
        let reported = CGRect(x: 2802, y: 190, width: 0, height: 13)
        let newline = CGRect(x: 3020, y: 190, width: 400, height: 13)
        let fix = CaretMath.correctedCollapsed(reported, field: field.offsetBy(dx: 2700, dy: -49), previousNewline: newline)
        #expect(fix.corrected)
        #expect(fix.rect == CGRect(x: 2802, y: 203, width: 0, height: 13))
    }

    @Test func movesACaretThatSitsAboveTheField() {
        let textView = CGRect(x: 367, y: 230, width: 600, height: 300)
        let fix = CaretMath.correctedCollapsed(CGRect(x: 377, y: 217, width: 0, height: 13), field: textView, previousNewline: nil)
        #expect(fix.corrected)
        #expect(fix.rect == CGRect(x: 377, y: 230, width: 0, height: 13))
    }

    @Test func leavesACorrectCaretAlone() {
        // Safari reports the empty line after a newline correctly.
        let fix = CaretMath.correctedCollapsed(
            CGRect(x: 2601, y: 183, width: 0, height: 21), field: CGRect(x: 2592, y: 133, width: 538, height: 128),
            previousNewline: CGRect(x: 2750, y: 162, width: 5, height: 21)
        )
        #expect(!fix.corrected)
        #expect(fix.rect == CGRect(x: 2601, y: 183, width: 0, height: 21))
    }

    @Test func trustsChromiumWhoseNewlineStartsTheNextLine() {
        // Measured in Chrome: the newline is a zero-width rect at the start of the new line, and the caret is right.
        let fix = CaretMath.correctedCollapsed(
            CGRect(x: 241, y: 308, width: 0, height: 20), field: CGRect(x: 232, y: 258, width: 538, height: 128),
            previousNewline: CGRect(x: 241, y: 308, width: 0, height: 20)
        )
        #expect(!fix.corrected)
        #expect(fix.rect.minY == 308)
    }

    @Test func ignoresAZeroSizedNewline() {
        let fix = CaretMath.correctedCollapsed(CGRect(x: 120, y: 240, width: 0, height: 16), field: field, previousNewline: .zero)
        #expect(!fix.corrected)
    }
}

@Suite struct CaretEstimateTests {
    @Test func multiLineEstimateIsTheFirstLine() {
        let caret = CaretMath.estimatedCaret(field: field, isSingleLine: false, lineHeight: 20)
        #expect(caret == CGRect(x: 104, y: 204, width: 0, height: 20))
    }

    @Test func singleLineEstimateIsCentred() {
        let input = CGRect(x: 10, y: 10, width: 200, height: 30)
        let caret = CaretMath.estimatedCaret(field: input, isSingleLine: true, lineHeight: 18)
        #expect(caret.midY == input.midY)
        #expect(caret.height == 18)
    }

    @Test func estimateNeverExceedsATinyField() {
        let tiny = CGRect(x: 0, y: 0, width: 50, height: 12)
        #expect(CaretMath.estimatedCaret(field: tiny, isSingleLine: true, lineHeight: 40).height == 10)
    }

    @Test func singleLineHeuristic() {
        #expect(CaretMath.looksSingleLine(fieldHeight: 38, caretHeight: 20))
        #expect(!CaretMath.looksSingleLine(fieldHeight: 108, caretHeight: 17))
        #expect(!CaretMath.looksSingleLine(fieldHeight: 38, caretHeight: 0))
    }
}
