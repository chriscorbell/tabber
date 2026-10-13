import CoreGraphics
import Testing
@testable import TabberContext

/// Recognized lines from a real capture: a mail thread page in Chrome (tab strip, address bar, sidebar, two
/// messages with sender/date headers) above a reply field holding the user's draft.
@Suite struct LiveCaptureFixtureTests {
    private func l(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Float) -> RecognizedLine {
        RecognizedLine(text: t, confidence: c, box: CGRect(x: x, y: y, width: w, height: h))
    }

    private func assembled() -> String {
        let lines = [
            l("• • • v 0 Re: Q3 launch timeline - Mail × | 9 Mail", 12.2, 10.2, 411.6, 21.2, 1.00),
            l("× € Mail", 571.9, 11.4, 89.3, 20.7, 1.00),
            l("× • Mail", 810.7, 10.1, 87.9, 21.5, 1.00),
            l("< → C © File /tmp/tabber-ctx-scratch/thread2.html", 15.7, 52.1, 425.6, 22.8, 0.50),
            l("Compose", 20.6, 105.4, 66.9, 24.4, 1.00),
            l("Inbox", 20.9, 134.1, 41.9, 20.9, 1.00),
            l("Starred", 20.9, 161.9, 52.4, 21.1, 1.00),
            l("Snoozed", 20.9, 189.9, 62.8, 20.9, 1.00),
            l("Sent", 20.9, 217.7, 38.4, 20.9, 1.00),
            l("Drafts", 20.9, 245.5, 45.4, 21.1, 1.00),
            l("Spam", 20.9, 273.5, 43.6, 22.6, 1.00),
            l("Dinner on Saturday?", 237.2, 111.5, 209.3, 29.6, 1.00),
            l("Priya Raman", 235.5, 165.4, 94.2, 22.8, 1.00),
            l("Wed, Oct 7, 6:02 PM", 886.0, 163.5, 117.0, 23.2, 1.00),
            l("to me", 237.2, 186.4, 36.6, 13.9, 1.00),
            l("Hey! Marco and I are hosting a small dinner on Saturday around 7:30. Would you and Jess like to come? We are making", 237.2, 207.3, 753.5, 22.9, 1.00),
            l("paella and there will be a vegetarian option.", 235.5, 228.2, 279.1, 22.9, 1.00),
            l("Priya Raman", 237.2, 285.7, 92.4, 21.2, 1.00),
            l("Wed, Oct 7, 6:15 PM", 886.0, 283.9, 118.6, 21.1, 1.00),
            l("to me", 237.2, 304.8, 36.6, 14.0, 1.00),
            l("Also, could you bring that lemon tart you made last time? Everyone is still talking about it. Parking is easiest on Elm Street", 237.2, 327.2, 762.2, 21.1, 1.00),
            l("behind the bakery.", 236.9, 345.8, 122.7, 23.7, 1.00),
            l("Last synced 8:15:31 PM", 237.2, 391.9, 136.0, 19.2, 1.00),
            l("Hi Sarah,", 249.4, 444.1, 64.5, 21.0, 1.00),
            l("Thanks for the update. Let's go with", 249.4, 477.0, 225.0, 19.4, 1.00),
            l("Send Discard", 239.0, 578.3, 99.4, 15.7, 1.00),
        ]
        return ScreenTextAssembler.assemble(
            lines,
            field: CGRect(x: 240, y: 436, width: 782, height: 132),
            fieldText: "Hi Sarah,\n\nThanks for the update. Let's go with ",
            alsoKnown: ["Mail - Google Chrome", "file:///tmp/tabber-ctx-scratch/thread2.html"]
        )
    }

    @Test func headersReadInOrder() {
        let text = assembled()
        #expect(text.contains("Priya Raman\nWed, Oct 7, 6:02 PM\nto me\nHey! Marco"), "\(text)")
        #expect(text.contains("Priya Raman\nWed, Oct 7, 6:15 PM\nto me\nAlso, could"), "\(text)")
    }

    @Test func wrappedParagraphsAreJoined() {
        let text = assembled()
        #expect(text.contains("We are making paella and there will be a vegetarian option."))
        #expect(text.contains("Parking is easiest on Elm Street behind the bakery."))
    }

    @Test func chromeSidebarAndDraftAreDropped() {
        let text = assembled()
        for noise in ["Compose", "Inbox", "Starred", "File /tmp", "Thanks for the update"] {
            #expect(!text.contains(noise), "\(noise)")
        }
    }
}
