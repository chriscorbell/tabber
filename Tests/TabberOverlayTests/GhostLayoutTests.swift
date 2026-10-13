import AppKit
import Testing
import TabberCore
@testable import TabberOverlay

/// Every character is 10 pt wide: wrapping arithmetic stays readable.
private let mono: (Substring) -> CGFloat = { CGFloat($0.count) * 10 }
private let helvetica13 = FontMetrics(pointSize: 13, ascent: 10.01, descent: 2.99, leading: 0)
private let field = FieldIdentity(pid: 1, elementHash: 1, role: "AXTextArea")
private let systemFamily = NSFont.systemFont(ofSize: 12).familyName

@Suite struct ScreenSpaceTests {
    // The primary display is 2560×1440 points; a 2048×1152 display sits to its right, bottom-aligned
    // (AppKit origin 2560, 288), so in Quartz it spans y 0...1152.
    let primaryHeight: CGFloat = 1440

    @Test func convertsQuartzToAppKitAgainstThePrimaryHeight() {
        let r = ScreenSpace.appKitRect(fromQuartz: CGRect(x: 100, y: 200, width: 50, height: 20), primaryHeight: primaryHeight)
        #expect(r == CGRect(x: 100, y: 1220, width: 50, height: 20))
    }

    @Test func secondaryDisplayToTheRightLandsInsideIt() {
        let secondaryAppKit = CGRect(x: 2560, y: 288, width: 2048, height: 1152)
        let caretLine = CGRect(x: 3020.33, y: 194, width: 150, height: 16)  // as TextEdit reported it there
        let r = ScreenSpace.appKitRect(fromQuartz: caretLine, primaryHeight: primaryHeight)
        #expect(r.minY == 1230)
        #expect(secondaryAppKit.contains(r))
        // The union of both screens is 1440 tall too here, but a display above the primary would make the
        // union taller: converting must not depend on it.
        #expect(ScreenSpace.quartzRect(fromAppKit: secondaryAppKit, primaryHeight: primaryHeight) == CGRect(x: 2560, y: 0, width: 2048, height: 1152))
    }

    @Test func displayAbovePrimaryHasNegativeQuartzY() {
        let above = CGRect(x: 0, y: 1440, width: 1920, height: 1080)  // AppKit
        let q = ScreenSpace.quartzRect(fromAppKit: above, primaryHeight: primaryHeight)
        #expect(q == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let caret = CGRect(x: 300, y: -500, width: 1, height: 18)
        #expect(above.contains(ScreenSpace.appKitRect(fromQuartz: caret, primaryHeight: primaryHeight)))
    }

    @Test func roundTrips() {
        let q = CGRect(x: -812.25, y: 1033.5, width: 77.75, height: 19)
        let back = ScreenSpace.quartzRect(fromAppKit: ScreenSpace.appKitRect(fromQuartz: q, primaryHeight: 900), primaryHeight: 900)
        #expect(back == q)
    }

    @Test func integralFrameExpandsOutward() {
        let r = ScreenSpace.integralFrame(containing: CGRect(x: 10.3, y: 20.7, width: 5.2, height: 3.1))
        #expect(r == CGRect(x: 10, y: 20, width: 6, height: 4))
    }
}

@Suite struct BaselineTests {
    @Test func extraLineHeightSitsAboveTheGlyphs() {
        // TextEdit, Helvetica 13: caret 194...210; the native baseline measured at 207.0.
        let caret = CGRect(x: 0, y: 194, width: 1, height: 16)
        #expect(abs(GhostLayout.baseline(caret: caret, metrics: helvetica13) - 207.01) < 0.001)
    }

    @Test func shortCaretCentresTheGlyphBox() {
        // Georgia 20 in a 22 pt caret: the glyph box (22.72) is taller than the caret.
        let georgia20 = FontMetrics(pointSize: 20, ascent: 18.34, descent: 4.38, leading: 0)
        let caret = CGRect(x: 0, y: 254, width: 1, height: 22)
        #expect(abs(GhostLayout.baseline(caret: caret, metrics: georgia20) - 271.98) < 0.001)
    }

    @Test func wholePointRectsGetHalfAPointBack() {
        let caret = CGRect(x: 287, y: 419, width: 1, height: 19)
        let menlo15 = FontMetrics(pointSize: 15, ascent: 13.92, descent: 3.54, leading: 0)
        let plain = GhostLayout.baseline(caret: caret, metrics: menlo15)
        #expect(GhostLayout.baseline(caret: caret, metrics: menlo15, wholePointRect: true) == plain + 0.5)
    }

    @Test func verticalOffsetMovesDown() {
        let caret = CGRect(x: 0, y: 100, width: 1, height: 16)
        let base = GhostLayout.baseline(caret: caret, metrics: helvetica13)
        #expect(GhostLayout.baseline(caret: caret, metrics: helvetica13, verticalOffset: 1.5) == base + 1.5)
    }

    @Test func snapsToDevicePixels() {
        #expect(GhostLayout.pixelAligned(207.01, scale: 2) == 207)
        #expect(GhostLayout.pixelAligned(434.46, scale: 2) == 434.5)
        #expect(GhostLayout.pixelAligned(10.4, scale: 1) == 10)
    }

    @Test func linePitchFollowsTheFontWithinCaretBounds() {
        #expect(GhostLayout.linePitch(caretHeight: 16, metrics: helvetica13) == 16)  // font line 13 < caret
        let tall = FontMetrics(pointSize: 30, ascent: 30, descent: 10.98, leading: 0)
        #expect(GhostLayout.linePitch(caretHeight: 30, metrics: tall) == 37.5)       // capped at 1.25×
        #expect(GhostLayout.linePitch(caretHeight: 41, metrics: tall) == 41)
    }
}

@Suite struct FontSizeTests {
    @Test func keepsAPlausibleReportedSize() {
        #expect(GhostLayout.fontSize(reported: 13, caretHeight: 16, unitLineHeight: 1.0) == 13)
        #expect(GhostLayout.fontSize(reported: 20, caretHeight: 22, unitLineHeight: 1.136) == 20)
    }

    @Test func derivesTheSizeWhenTheReportDisagreesWithTheCaret() {
        // A zoomed page: CSS px says 12, the caret is 40 tall.
        #expect(GhostLayout.fontSize(reported: 12, caretHeight: 40, unitLineHeight: 1.0) == 40)
        // A default style on a tiny caret.
        #expect(abs(GhostLayout.fontSize(reported: 24, caretHeight: 14, unitLineHeight: 1.17) - 14 / 1.17) < 0.001)
    }

    @Test func derivesTheSizeWhenNoneIsReported() {
        #expect(abs(GhostLayout.fontSize(reported: nil, caretHeight: 18, unitLineHeight: 1.19) - 18 / 1.19) < 0.001)
    }

    @Test func clampsAndDefaults() {
        #expect(GhostLayout.fontSize(reported: nil, caretHeight: 300, unitLineHeight: 1.2) == 72)
        #expect(GhostLayout.fontSize(reported: nil, caretHeight: 4, unitLineHeight: 1.2) == 8)
        #expect(GhostLayout.fontSize(reported: 120, caretHeight: nil, unitLineHeight: 1.2) == 72)
        #expect(GhostLayout.fontSize(reported: nil, caretHeight: nil, unitLineHeight: 1.2) == 13)
        #expect(GhostLayout.fontSize(reported: 0, caretHeight: .nan, unitLineHeight: 1.2) == 13)
    }
}

@Suite struct TypeThroughTests {
    let ghost = Ghost(requestID: 1, field: field, anchor: "The quick brown fox", text: " jumps over", consumed: 3)

    @Test func lagIsTheConsumedTextTheSnapshotLacks() {
        #expect(GhostLayout.lagText(ghost: ghost, textBeforeCaret: "The quick brown fox") == " ju")
        #expect(GhostLayout.lagText(ghost: ghost, textBeforeCaret: "The quick brown fox j") == "u")
    }

    @Test func noLagOnceTheAppCaughtUp() {
        #expect(GhostLayout.lagText(ghost: ghost, textBeforeCaret: "The quick brown fox ju") == "")
        var fresh = ghost
        fresh.consumed = 0
        #expect(GhostLayout.lagText(ghost: fresh, textBeforeCaret: "The quick brown fox") == "")
    }

    @Test func noShiftWhenTheTextNoLongerMatches() {
        #expect(GhostLayout.lagText(ghost: ghost, textBeforeCaret: "Something else") == "")
    }

    @Test func worksWithLongAnchorsInASlidingWindow() {
        let anchor = String(repeating: "lorem ipsum ", count: 40) + "The end"
        let long = Ghost(requestID: 2, field: field, anchor: anchor, text: " is near", consumed: 4)
        let window = String(anchor.suffix(100)) + " i"   // the field's text window starts mid-anchor
        #expect(GhostLayout.lagText(ghost: long, textBeforeCaret: window) == "s ")
    }

    @Test func shiftIsTheWidthOfTheLag() {
        // With a 10 pt font, " ju" moves the drawing 30 pt right of the snapshot's caret.
        #expect(mono(GhostLayout.lagText(ghost: ghost, textBeforeCaret: "The quick brown fox")) == 30)
    }
}

@Suite struct WrappingTests {
    func input(_ text: String, startX: CGFloat = 0, right: CGFloat = 100, wrap: Bool = true, bottom: CGFloat? = nil, maxLines: Int = 3) -> GhostLayout.LineInput {
        GhostLayout.LineInput(
            text: text, startX: startX, baseline: 100, rightEdge: right, lineStartX: 0,
            linePitch: 16, maxLines: maxLines, bottomLimit: bottom, allowWrap: wrap
        )
    }

    @Test func fitsOnTheCaretLine() {
        let lines = GhostLayout.lines(input(" jumps", startX: 20), metrics: helvetica13, measure: mono)
        #expect(lines == [LineFragment(text: " jumps", origin: CGPoint(x: 20, y: 100), width: 60)])
    }

    @Test func breaksAtWordBoundariesOntoFollowingLines() {
        let lines = GhostLayout.lines(input("hello world again"), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["hello", "world", "again"])
        #expect(lines.map(\.origin) == [CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 116), CGPoint(x: 0, y: 132)])
    }

    @Test func trailingSpacesHangPastTheEdge() {
        let lines = GhostLayout.lines(input("abcdefghij klm"), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["abcdefghij", "klm"])
    }

    @Test func aWordThatDoesNotFitAfterTheCaretMovesToTheNextLine() {
        let lines = GhostLayout.lines(input(" jumps over", startX: 70), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["jumps over"])
        #expect(lines.first?.origin == CGPoint(x: 0, y: 116))
    }

    @Test func stopsAfterThreeLines() {
        let lines = GhostLayout.lines(input("one two three four five six seven", right: 60), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["one", "two", "three"])
    }

    @Test func singleLineFieldsTruncateAtTheEdge() {
        let words = GhostLayout.lines(input("hello world again", wrap: false), metrics: helvetica13, measure: mono)
        #expect(words.map(\.text) == ["hello"])
        let oneWord = GhostLayout.lines(input("supercalifragilistic", wrap: false), metrics: helvetica13, measure: mono)
        #expect(oneWord.map(\.text) == ["supercalif"])
    }

    @Test func aWordLongerThanALineIsCut() {
        let lines = GhostLayout.lines(input(" abcdefghijklmnop", startX: 50), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["abcdefghij", "klmnop"])
    }

    @Test func linesBelowTheFieldAreDropped() {
        // Second baseline 116 + descent 2.99 is past the field's bottom at 110.
        let lines = GhostLayout.lines(input("hello world", bottom: 110), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["hello"])
    }

    @Test func lineBreaksAndTabsBecomeSpaces() {
        let lines = GhostLayout.lines(input("a\tb\nc"), metrics: helvetica13, measure: mono)
        #expect(lines.map(\.text) == ["a b c"])
    }

    @Test func boundsCoverEveryLine() throws {
        let lines = GhostLayout.lines(input("hello world"), metrics: helvetica13, measure: mono)
        let box = try #require(GhostLayout.bounds(of: lines, metrics: helvetica13))
        #expect(box.minY < 100 - helvetica13.ascent)
        #expect(box.maxY > 116 + helvetica13.descent)
        #expect(box.minX < 0 && box.maxX > 50)
    }
}

@Suite struct LineStartTests {
    let fieldFrame = CGRect(x: 60, y: 0, width: 600, height: 300)

    @Test func caretMinusTheLineWidth() {
        let x = GhostLayout.estimatedLineStart(caretX: 100, textBeforeCaret: "first\nabc", fieldFrame: fieldFrame, measure: mono)
        #expect(x == 70)
    }

    @Test func rejectsSoftWrappedLinesAndTabs() {
        let wrapped = String(repeating: "x", count: 80)   // 800 pt can't sit left of a caret at 300
        #expect(GhostLayout.estimatedLineStart(caretX: 300, textBeforeCaret: wrapped, fieldFrame: fieldFrame, measure: mono) == nil)
        #expect(GhostLayout.estimatedLineStart(caretX: 100, textBeforeCaret: "a\tb", fieldFrame: fieldFrame, measure: mono) == nil)
        #expect(GhostLayout.estimatedLineStart(caretX: 100, textBeforeCaret: "abc", fieldFrame: nil, measure: mono) == nil)
    }

    @Test func wholePointCaretsNarrowTheLineStart() {
        // True line start 162.0. Safari floors carets: 287.3 → 287, then 294.6 → 294.
        let first = GhostLayout.refinedLineStart(previous: nil, caretX: 287, lineWidth: 125.3)
        #expect(abs(first.lowerBound - 161.7) < 0.001 && abs(first.upperBound - 162.7) < 0.001)
        let second = GhostLayout.refinedLineStart(previous: first, caretX: 294, lineWidth: 132.6)
        #expect(abs(second.lowerBound - 161.7) < 0.001 && abs(second.upperBound - 162.4) < 0.001)
        #expect(second.contains(162.0))
        // A contradicting read (font changed, line moved) starts over.
        let reset = GhostLayout.refinedLineStart(previous: second, caretX: 400, lineWidth: 10)
        #expect(reset == 390...391)
    }

    @Test func detectsWholePointRects() {
        #expect(GhostLayout.isWholePointRect(CGRect(x: 287, y: 153, width: 2, height: 16)))
        #expect(!GhostLayout.isWholePointRect(CGRect(x: 221.33, y: 240, width: 0, height: 16)))
    }
}

@Suite struct TintTests {
    let black = RGBA(r: 0.11, g: 0.11, b: 0.12)
    let white = RGBA(r: 0.9, g: 0.9, b: 0.9)

    @Test func translucentHostColorInLightMode() {
        #expect(GhostTint.color(host: black, opacity: 0.5, grey: false) == RGBA(r: 0.11, g: 0.11, b: 0.12, a: 0.5))
    }

    @Test func neutralGreyWhenUnknownFaintOrRequested() {
        #expect(GhostTint.color(host: nil, opacity: 0.5, grey: false) == GhostTint.neutralGrey)
        #expect(GhostTint.color(host: RGBA(r: 0, g: 0, b: 0, a: 0.2), opacity: 0.5, grey: false) == GhostTint.neutralGrey)
        #expect(GhostTint.color(host: black, opacity: 0.5, grey: true) == GhostTint.neutralGrey)
    }

    @Test func darkModeBlendsTowardTheImpliedBackground() {
        // Dark text implies a white page: same look as 50% black on white, but opaque, so it stays
        // readable when the app draws the page dark and the text light.
        let onWhite = GhostTint.color(host: black, opacity: 0.5, grey: false, darkSystem: true)
        #expect(abs(onWhite.r - 0.555) < 0.001 && onWhite.a == 1)
        let onBlack = GhostTint.color(host: white, opacity: 0.5, grey: false, darkSystem: true)
        #expect(abs(onBlack.r - 0.45) < 0.001 && onBlack.a == 1)
    }
}

@Suite struct MirrorTests {
    @Test func contextIsTheTailOfTheCaretLine() {
        #expect(GhostLayout.mirrorContext(textBeforeCaret: "first line\nThe quick") == "The quick")
        let long = "Please find attached the quarterly report for review"
        let tail = GhostLayout.mirrorContext(textBeforeCaret: long)
        #expect(tail.hasPrefix("…"))
        #expect(tail.count <= 31)
        #expect(long.hasSuffix(tail.dropFirst()))
        #expect(tail.dropFirst().first != " ")
    }

    let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let size = CGSize(width: 200, height: 26)

    @Test func cardGoesBelowTheCaretLine() {
        let line = CGRect(x: 400, y: 300, width: 1, height: 16)
        let frame = GhostLayout.mirrorCardFrame(size: size, line: line, field: nil, alignX: 350, screen: screen)
        #expect(frame == CGRect(x: 350, y: 322, width: 200, height: 26))
    }

    @Test func flipsAboveAtTheScreenBottomAndClampsX() {
        let line = CGRect(x: 1400, y: 880, width: 1, height: 16)
        let frame = GhostLayout.mirrorCardFrame(size: size, line: line, field: nil, alignX: 1380, screen: screen)
        #expect(frame == CGRect(x: 1236, y: 848, width: 200, height: 26))
    }

    @Test func fallsBackToTheFieldAndNeedsAnAnchor() {
        let fieldFrame = CGRect(x: 30, y: 148, width: 503, height: 68)
        let frame = GhostLayout.mirrorCardFrame(size: size, line: nil, field: fieldFrame, alignX: nil, screen: screen)
        #expect(frame == CGRect(x: 30, y: 222, width: 200, height: 26))
        #expect(GhostLayout.mirrorCardFrame(size: size, line: nil, field: nil, alignX: nil, screen: screen) == nil)
    }
}

@Suite @MainActor struct PresentationTests {
    func snapshot(caret: CaretGeometry?, after: String = "") -> FieldSnapshot {
        FieldSnapshot(
            app: AppIdentity(bundleID: "test", name: "test", pid: 1),
            field: field, role: "AXTextArea",
            textBeforeCaret: "The quick brown fox", textAfterCaret: after,
            caret: caret
        )
    }
    let exact = CaretGeometry(rect: CGRect(x: 10, y: 10, width: 1, height: 16), quality: .exact)

    @Test func inlineAtAGoodCaretAtTheEndOfTheLine() {
        #expect(OverlayController.presentation(for: snapshot(caret: exact, after: "  \nnext"), appearance: .init()) == .inline)
        let derived = CaretGeometry(rect: exact.rect, quality: .derived)
        #expect(OverlayController.presentation(for: snapshot(caret: derived), appearance: .init()) == .inline)
    }

    @Test func mirrorOtherwise() {
        #expect(OverlayController.presentation(for: snapshot(caret: nil), appearance: .init()) == .mirror)
        let estimated = CaretGeometry(rect: exact.rect, quality: .estimated)
        #expect(OverlayController.presentation(for: snapshot(caret: estimated), appearance: .init()) == .mirror)
        #expect(OverlayController.presentation(for: snapshot(caret: exact, after: " jumps"), appearance: .init()) == .mirror)
        #expect(OverlayController.presentation(for: snapshot(caret: exact), appearance: .init(forceMirror: true)) == .mirror)
    }
}

@Suite struct FontResolverTests {
    @Test func usesTheNamedFace() {
        #expect(FontResolver.baseFont(name: "Helvetica", family: "Helvetica").fontName == "Helvetica")
        #expect(FontResolver.baseFont(name: "Georgia", family: nil).familyName == "Georgia")
    }

    @Test func familyWinsWhenTheNameDisagrees() {
        // Word reports a fake "Helvetica" with the real family alongside.
        #expect(FontResolver.baseFont(name: "Helvetica", family: "Georgia").familyName == "Georgia")
        #expect(FontResolver.baseFont(name: "Helvetica-Bold", family: "Georgia").fontName == "Georgia-Bold")
    }

    @Test func fallsBackToFamilyThenSystem() {
        #expect(FontResolver.baseFont(name: nil, family: "Menlo").familyName == "Menlo")
        #expect(FontResolver.baseFont(name: "NoSuchFont-Regular", family: nil).familyName == systemFamily)
        #expect(FontResolver.baseFont(name: nil, family: "'No Such', Georgia, serif").familyName == "Georgia")
    }

    @Test func mapsSystemAndGenericNames() {
        #expect(FontResolver.baseFont(name: ".SFNS-Regular", family: ".AppleSystemUIFont").familyName == systemFamily)
        #expect(FontResolver.baseFont(name: nil, family: "system-ui").familyName == systemFamily)
        #expect(FontResolver.baseFont(name: "Georgia", family: "serif").familyName == "Georgia")
    }

    @Test func sizeComesFromTheStyleOrTheCaret() {
        let reported = FontResolver.font(for: TextStyle(fontName: "Helvetica", fontSize: 13), caretHeight: 16)
        #expect(reported.pointSize == 13)
        let zoomed = FontResolver.font(for: TextStyle(fontName: "Helvetica", fontSize: 12), caretHeight: 40)
        #expect(abs(zoomed.pointSize - 40) < 0.01)   // Helvetica's line height is 1.0 em
        let scaled = FontResolver.font(for: TextStyle(fontName: "Helvetica", fontSize: 13), caretHeight: 16, scale: 1.5)
        #expect(scaled.pointSize == 19.5)
    }
}
