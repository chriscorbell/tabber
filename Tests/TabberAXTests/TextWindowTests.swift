import CoreFoundation
import Testing
@testable import TabberAX

@Suite struct TextWindowSpanTests {
    @Test func boundsTheReadAroundTheCaret() {
        let span = TextWindow.span(selection: CFRange(location: 5000, length: 0), totalLength: 9000, before: 4000, after: 1000)
        #expect(span.start == 1000)
        #expect(span.end == 6000)
        #expect(span.selectionStart == 5000)
        #expect(span.selectionEnd == 5000)
        #expect(span.beforeIsTruncated)
        #expect(span.range.location == 1000)
        #expect(span.range.length == 5000)
    }

    @Test func notTruncatedNearTheStart() {
        let span = TextWindow.span(selection: CFRange(location: 10, length: 0), totalLength: 30, before: 4000, after: 1000)
        #expect(span.start == 0)
        #expect(span.end == 30)
        #expect(!span.beforeIsTruncated)
    }

    @Test func coversASelection() {
        let span = TextWindow.span(selection: CFRange(location: 10, length: 5), totalLength: 100, before: 4, after: 3)
        #expect(span.start == 6)
        #expect(span.selectionEnd == 15)
        #expect(span.end == 18)
        #expect(span.beforeRange.location == 6 && span.beforeRange.length == 4)
        #expect(span.afterRange.location == 15 && span.afterRange.length == 3)
    }

    @Test func clampsSelectionsPastTheEnd() {
        // Apps sometimes report a caret beyond their text, or a negative length.
        let span = TextWindow.span(selection: CFRange(location: 50, length: 10), totalLength: 20, before: 100, after: 100)
        #expect(span.selectionStart == 20)
        #expect(span.selectionEnd == 20)
        #expect(span.end == 20)
        let negative = TextWindow.span(selection: CFRange(location: -3, length: -2), totalLength: 20, before: 5, after: 5)
        #expect(negative.selectionStart == 0)
        #expect(negative.selectionEnd == 0)
        #expect(negative.end == 5)
    }

    @Test func emptyField() {
        let span = TextWindow.span(selection: CFRange(location: 0, length: 0), totalLength: 0, before: 4000, after: 1000)
        #expect(span.length == 0)
        #expect(!span.beforeIsTruncated)
    }
}

@Suite struct TextWindowSplitTests {
    @Test func splitsFetchedTextAtTheSelection() {
        let span = TextWindow.span(selection: CFRange(location: 6, length: 2), totalLength: 11, before: 100, after: 100)
        let parts = TextWindow.split(fetched: "hello world", span: span)
        #expect(parts?.before == "hello ")
        #expect(parts?.after == "rld")
    }

    @Test func rejectsFetchedTextOfTheWrongLength() {
        let span = TextWindow.span(selection: CFRange(location: 3, length: 0), totalLength: 10, before: 100, after: 100)
        #expect(TextWindow.split(fetched: "short", span: span) == nil)
    }

    @Test func splitsTheWholeValueByUTF16Offsets() {
        // "é" as a precomposed scalar is 1 unit; the emoji is 2.
        let text = "café 😀 bar"
        let caret = Array("café 😀".utf16).count
        let parts = TextWindow.split(fullText: text, selection: CFRange(location: caret, length: 0), before: 100, after: 100)
        #expect(parts.before == "café 😀")
        #expect(parts.after == " bar")
        #expect(parts.span.selectionStart == caret)
    }

    @Test func windowedSplitOfTheWholeValue() {
        let parts = TextWindow.split(fullText: "abcdefghij", selection: CFRange(location: 5, length: 0), before: 2, after: 3)
        #expect(parts.before == "de")
        #expect(parts.after == "fgh")
        #expect(parts.span.beforeIsTruncated)
    }

    @Test func neverCutsASurrogatePair() {
        let units = Array("a😀b".utf16)   // a, high, low, b
        #expect(TextWindow.slice(units, from: 2, to: 4) == "b")    // starts on the low surrogate: skip it
        #expect(TextWindow.slice(units, from: 0, to: 2) == "a")    // ends after the high surrogate: drop it
        #expect(TextWindow.slice(units, from: 0, to: 3) == "a😀")
        #expect(TextWindow.slice(units, from: -5, to: 99) == "a😀b")
        #expect(TextWindow.slice(units, from: 3, to: 1) == "")
    }

    @Test func suffixAndPrefix() {
        let tail = TextWindow.suffix("0123456789", limit: 4)
        #expect(tail.text == "6789")
        #expect(tail.truncated)
        #expect(TextWindow.suffix("abc", limit: 4) == ("abc", false))
        #expect(TextWindow.prefix("0123456789", limit: 3) == "012")
        #expect(TextWindow.prefix("ab", limit: 3) == "ab")
    }
}

@Suite struct TextCleaningTests {
    @Test func turnsNonBreakingSpacesIntoSpaces() {
        #expect(TextWindow.clean("one\u{00A0}two\u{00A0}\u{00A0}three") == "one two  three")
    }

    @Test func keepsNarrowNoBreakSpace() {
        // U+202F is deliberate typography (French punctuation, times), not an editor artifact.
        #expect(TextWindow.clean("10\u{202F}h") == "10\u{202F}h")
    }

    @Test func stripsTrailingObjectReplacementCharacters() {
        #expect(TextWindow.clean("see attached\u{FFFC}\u{FFFC}") == "see attached")
        #expect(TextWindow.clean("a\u{FFFC}b") == "a\u{FFFC}b")
        #expect(TextWindow.clean("\u{FFFC}") == "")
    }

    @Test func cleaningKeepsUTF16LengthOfTheKeptText() {
        let raw = "x\u{00A0}y"
        #expect(TextWindow.clean(raw).utf16.count == raw.utf16.count)
    }
}

@Suite struct CharacterHelperTests {
    @Test func lastCharacterLengthCoversWholeGraphemes() {
        #expect(TextWindow.lastCharacterLength("abc") == 1)
        #expect(TextWindow.lastCharacterLength("hi 😀") == 2)
        #expect(TextWindow.lastCharacterLength("👨‍👩‍👧") == "👨‍👩‍👧".utf16.count)
        #expect(TextWindow.lastCharacterLength("") == 0)
        #expect(TextWindow.firstCharacterLength("😀x") == 2)
    }

    @Test func newlines() {
        #expect(TextWindow.endsWithNewline("line\n"))
        #expect(TextWindow.endsWithNewline("line\r\n"))
        #expect(TextWindow.endsWithNewline("para\u{2029}"))
        #expect(!TextWindow.endsWithNewline("line "))
        #expect(!TextWindow.endsWithNewline(""))
    }
}

@Suite struct ChromiumCaretAlignmentTests {
    private func align(_ value: String, _ marker: String) -> Int? {
        TextWindow.alignCaret(value: Array(value.utf16), markerTextBefore: Array(marker.utf16))
    }

    @Test func skipsBlockNewlinesTheMarkerTextLacks() {
        // Measured in Chrome: value "Conte\nQnte…", selection reported at 6 while the caret is after "Q".
        #expect(align("Conte\nQnteditaY", "ConteQ") == 7)
        #expect(align("one\ntwo\nthree", "onetwoth") == 10)
    }

    @Test func stopsBeforeANewlineAtTheCaret() {
        // At a block boundary the caret could be on either side; the caller decides by geometry.
        #expect(align("Conte\nQnte", "Conte") == 5)
        #expect(TextWindow.skipNewlines(Array("Conte\n\nQ".utf16), from: 5) == 7)
    }

    @Test func consistentFieldsAlignToTheSameOffset() {
        // A textarea: both sides count the newline.
        #expect(align("line one\nline two", "line one\nli") == 11)
        #expect(align("abc", "") == 0)
    }

    @Test func spacesAndNonBreakingSpacesMatch() {
        #expect(align("a\u{00A0}b\nc", "a bc") == 5)
    }

    @Test func refusesTextsThatDifferBeyondNewlines() {
        #expect(align("hello", "help") == nil)
        #expect(align("hi", "hiya") == nil)
    }
}
