import ApplicationServices
import Foundation
import TabberCore
import Testing
@testable import TabberAX

private func snapshot(before: String = "Hello", caret: Int? = 5, at date: Date = Date()) -> FieldSnapshot {
    FieldSnapshot(
        app: AppIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 42),
        field: FieldIdentity(pid: 42, elementHash: 7, role: "AXTextArea"),
        role: "AXTextArea",
        textBeforeCaret: before,
        caretOffset: caret,
        capturedAt: date
    )
}

@Suite struct SnapshotComparisonTests {
    @Test func ignoresOnlyTheTimestamp() {
        let a = snapshot(at: Date(timeIntervalSince1970: 1))
        let b = snapshot(at: Date(timeIntervalSince1970: 2))
        #expect(a != b)
        #expect(SnapshotComparison.sameExceptTimestamp(a, b))
        #expect(!SnapshotComparison.sameExceptTimestamp(a, snapshot(before: "Hello!", caret: 6)))
        var moved = a
        moved.caret = CaretGeometry(rect: CGRect(x: 1, y: 2, width: 0, height: 14), quality: .exact)
        #expect(!SnapshotComparison.sameExceptTimestamp(a, moved))
    }

    @Test func nils() {
        #expect(SnapshotComparison.sameExceptTimestamp(nil, nil))
        #expect(!SnapshotComparison.sameExceptTimestamp(nil, snapshot()))
        #expect(!SnapshotComparison.sameExceptTimestamp(snapshot(), nil))
    }

    @Test func textStateTracksWhatAKeystrokeChanges() {
        let base = snapshot()
        var styled = base
        styled.style = TextStyle(fontSize: 12)
        styled.capturedAt = .distantFuture
        #expect(TextState(base) == TextState(styled))
        #expect(TextState(base) != TextState(snapshot(before: "Hello ", caret: 6)))
        #expect(TextState(nil) != TextState(base))
        #expect(TextState(nil) == TextState(nil))
    }
}

@Suite struct WebAccessibilityClassificationTests {
    @Test func electronApps() {
        let kind = WebAccessibilityEnabler.classify(bundleID: "com.tinyspeck.slackmacgap", bundlePath: "/Applications/Slack.app") {
            $0 == "/Applications/Slack.app/Contents/Frameworks/Electron Framework.framework"
        }
        #expect(kind == .electron)
    }

    @Test func knownChromiumBrowsers() {
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac.Dev",
                   "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
                   "com.operasoftware.OperaGX", "org.chromium.Chromium"] {
            #expect(WebAccessibilityEnabler.classify(bundleID: id, bundlePath: nil) { _ in false } == .chromiumBrowser)
        }
    }

    @Test func otherChromiumForksByBundleLayout() {
        let kind = WebAccessibilityEnabler.classify(bundleID: "net.example.fork", bundlePath: "/Applications/Fork.app") {
            $0 == "/Applications/Fork.app/Contents/Frameworks/Fork Framework.framework/Helpers"
        }
        #expect(kind == .chromiumBrowser)
    }

    @Test func everythingElse() {
        #expect(WebAccessibilityEnabler.classify(bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app") { _ in false } == .other)
        #expect(WebAccessibilityEnabler.classify(bundleID: nil, bundlePath: nil) { _ in true } == .other)
    }
}

@Suite struct AXCastTests {
    @Test func mismatchedTypesComeBackNil() {
        let number = 3 as CFNumber
        let string = "text" as CFString
        #expect(AXCast.string(number) == nil)
        #expect(AXCast.int(string) == nil)
        #expect(AXCast.bool(string) == nil)
        #expect(AXCast.element(string) == nil)
        #expect(AXCast.range(string) == nil)
        #expect(AXCast.rect(number) == nil)
        #expect(AXCast.textMarker(string) == nil)
        #expect(AXCast.textMarkerRange(number) == nil)
        #expect(AXCast.attributedString(string) == nil)
        #expect(AXCast.elements(string).isEmpty)
        #expect(AXCast.string(nil) == nil)
    }

    @Test func axValuesOfTheWrongKind() throws {
        var rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        let rectValue = try #require(AXValueCreate(.cgRect, &rect))
        #expect(AXCast.rect(rectValue) == rect)
        #expect(AXCast.range(rectValue) == nil)
        #expect(AXCast.point(rectValue) == nil)
        var range = CFRange(location: 5, length: 2)
        let rangeValue = try #require(AXValueCreate(.cfRange, &range))
        #expect(AXCast.range(rangeValue)?.location == 5)
        #expect(AXCast.rect(rangeValue) == nil)
    }

    @Test func booleansAndNumbers() {
        #expect(AXCast.bool(kCFBooleanTrue) == true)
        #expect(AXCast.bool(0 as CFNumber) == false)
        #expect(AXCast.int(12 as CFNumber) == 12)
        #expect(AXCast.nonEmptyString("  \n" as CFString) == nil)
        #expect(AXCast.nonEmptyString(" Notes " as CFString) == "Notes")
    }

    @Test func errorPlaceholdersFromBatchedReads() throws {
        var error = AXError.noValue
        let placeholder = try #require(AXValueCreate(.axError, &error))
        #expect(AXCast.isErrorOrNull(placeholder))
        #expect(AXCast.isErrorOrNull(kCFNull))
        #expect(!AXCast.isErrorOrNull("x" as CFString))
    }

    @Test func elementKeysCompareTheRemoteElement() {
        let a = AXUIElementCreateApplication(1)
        let b = AXUIElementCreateApplication(1)
        let c = AXUIElementCreateApplication(2)
        #expect(ElementKey(element: a) == ElementKey(element: b))
        #expect(ElementKey(element: a) != ElementKey(element: c))
        #expect(Set([ElementKey(element: a), ElementKey(element: b)]).count == 1)
    }
}
