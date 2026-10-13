import CoreGraphics
import Foundation
import Testing
@testable import TabberContext

@Suite struct TextSimilarityTests {
    @Test func jaccardOfWordSets() {
        #expect(TextSimilarity.jaccard("Hello world", "hello, WORLD!") == 1)
        #expect(TextSimilarity.jaccard("alpha beta", "gamma delta") == 0)
        #expect(TextSimilarity.jaccard("", "") == 1)
        #expect(abs(TextSimilarity.jaccard("one two three four", "one two three five") - 0.6) < 1e-9)
        // Single characters are OCR noise and don't count.
        #expect(TextSimilarity.words("a b cd") == ["cd"])
    }
}

@Suite struct ScreenTextStabilityTests {
    let policy = ScreenTextStability(minimumHold: 20, changeThreshold: 0.7)
    let thread = "Hi Chris thanks for sending the forecast numbers over yesterday afternoon we can ship Friday"

    @Test func firstCaptureIsAlwaysAdopted() {
        #expect(policy.shouldReplace(current: nil, age: 0, with: thread))
        #expect(policy.shouldReplace(current: nil, age: 0, with: ""))
    }

    @Test func identicalTextIsKept() {
        #expect(!policy.shouldReplace(current: thread, age: 300, with: thread))
    }

    @Test func ocrJitterAndClocksAreHeld() {
        let clock = thread + " last synced 7:45:12 PM"
        let ticked = thread + " last synced 7:46:40 PM"
        #expect(TextSimilarity.jaccard(clock, ticked) >= 0.7)
        #expect(!policy.shouldReplace(current: clock, age: 5, with: ticked))
        #expect(!policy.shouldReplace(current: clock, age: 300, with: ticked))
    }

    @Test func smallRealChangesWaitForTheHold() {
        let history = thread + " Marco asked whether the venue confirmed parking passes and catering menus for "
            + "both evenings including vegetarian options dessert tables coffee service lighting rehearsal schedules"
        let newMessage = history + " Priya: sounds good see you there tomorrow"
        #expect(TextSimilarity.jaccard(history, newMessage) >= 0.7)
        #expect(!policy.shouldReplace(current: history, age: 5, with: newMessage))
        #expect(policy.shouldReplace(current: history, age: 21, with: newMessage))
    }

    @Test func clearlyChangedContentReplacesAtOnce() {
        let other = "Quarterly planning agenda budget review hiring roadmap offsite logistics"
        #expect(policy.shouldReplace(current: thread, age: 1, with: other))
        #expect(policy.shouldReplace(current: "", age: 1, with: other))
        #expect(policy.shouldReplace(current: thread, age: 1, with: ""))
    }
}

@Suite struct CaptureScheduleTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let frame = CGRect(x: 100, y: 500, width: 600, height: 40)

    @Test func dueAtFirstThenSpacedAndBackingOff() {
        var s = CaptureSchedule(baseInterval: 4, maxInterval: 16)
        #expect(s.isDue(now: t0, frame: frame))
        s.started(now: t0, frame: frame)
        #expect(!s.isDue(now: t0 + 3.9, frame: frame))
        #expect(s.isDue(now: t0 + 4, frame: frame))

        s.finished(changed: false) // nothing changed: wait 8 s next time
        #expect(!s.isDue(now: t0 + 7, frame: frame))
        #expect(s.isDue(now: t0 + 8, frame: frame))
        s.finished(changed: false)
        s.finished(changed: false)
        #expect(s.interval == 16) // capped
        s.finished(changed: true)
        #expect(s.interval == 4)
    }

    @Test func movedFieldIsDueAfterTheBaseInterval() {
        var s = CaptureSchedule(baseInterval: 4, maxInterval: 16)
        s.started(now: t0, frame: frame)
        s.finished(changed: false)
        let scrolled = frame.offsetBy(dx: 0, dy: -200)
        #expect(!s.isDue(now: t0 + 2, frame: scrolled))
        #expect(s.isDue(now: t0 + 4, frame: scrolled))
        #expect(!s.isDue(now: t0 + 4, frame: frame.offsetBy(dx: 0, dy: 3)))
    }
}

@Suite struct CaptureRegionTests {
    @Test func regionSpansTheWindowAboveAndALittleBelowTheField() throws {
        let r = try #require(CaptureRegion.make(
            field: CGRect(x: 100, y: 600, width: 800, height: 40),
            windowSize: CGSize(width: 1000, height: 800),
            nativeScale: 2
        ))
        #expect(r.rect == CGRect(x: 0, y: 0, width: 1000, height: 760))
        #expect(r.scale == 2)
        #expect(r.pixelWidth == 2000)
    }

    @Test func heightAboveIsLimited() throws {
        let r = try #require(CaptureRegion.make(
            field: CGRect(x: 100, y: 1300, width: 800, height: 40),
            windowSize: CGSize(width: 1000, height: 1400),
            nativeScale: 2
        ))
        #expect(r.rect.minY == 400)
        #expect(r.rect.maxY == 1400, "\(r.rect)") // 1340 + 120, clamped to the window
    }

    @Test func wideWindowsGetABandCentredOnTheField() throws {
        let r = try #require(CaptureRegion.make(
            field: CGRect(x: 2000, y: 600, width: 400, height: 40),
            windowSize: CGSize(width: 3000, height: 800),
            nativeScale: 2
        ))
        #expect(r.rect.width == 1600)
        #expect(r.rect.minX == 1400) // centred on x = 2200
        #expect(r.scale == 1.25)
        #expect(r.pixelWidth == 2000)
    }

    @Test func bandIsClampedToTheWindowEdge() throws {
        let r = try #require(CaptureRegion.make(
            field: CGRect(x: 2800, y: 600, width: 150, height: 40),
            windowSize: CGSize(width: 3000, height: 800),
            nativeScale: 2
        ))
        #expect(r.rect.maxX == 3000)
    }

    @Test func tallFieldsOnlyReadAbove() throws {
        let r = try #require(CaptureRegion.make(
            field: CGRect(x: 0, y: 300, width: 1000, height: 500),
            windowSize: CGSize(width: 1000, height: 900),
            nativeScale: 2
        ))
        #expect(r.rect == CGRect(x: 0, y: 0, width: 1000, height: 300))
    }

    @Test func nothingToReadAboveAFullWindowEditor() {
        #expect(CaptureRegion.make(
            field: CGRect(x: 0, y: 8, width: 1000, height: 1600),
            windowSize: CGSize(width: 1000, height: 900),
            nativeScale: 2
        ) == nil)
        // A field outside the window.
        #expect(CaptureRegion.make(
            field: CGRect(x: 2000, y: 100, width: 100, height: 20),
            windowSize: CGSize(width: 1000, height: 900),
            nativeScale: 2
        ) == nil)
    }
}
