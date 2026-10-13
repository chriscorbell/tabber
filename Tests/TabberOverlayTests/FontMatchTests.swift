import AppKit
import Testing
import TabberCore
@testable import TabberOverlay

@Suite struct FontMatchTests {
    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func sample(_ text: String, _ font: NSFont, rounded: Bool) -> WidthSample {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let units = Array(text.utf16)
        var offsets: [Int: CGFloat] = [:]
        for i in units.indices where i > 0 && units[i - 1] == 0x20 {
            let x = CTLineGetOffsetForStringIndex(line, i, nil)
            offsets[i] = rounded ? x.rounded() : x
        }
        let w = width(text, font)
        return WidthSample(text: text, width: rounded ? w.rounded() : w, offsets: offsets)
    }

    @Test func picksFamilyFromWordPositions() throws {
        let text = "the final agenda for the"
        // Arial is metric-compatible with Helvetica, so either is a correct answer for it.
        let accepted = ["Georgia": ["Georgia"], "Verdana": ["Verdana"], "Menlo": ["Menlo"], "Helvetica": ["Helvetica", "Arial"]]
        for (family, ok) in accepted {
            let font = try #require(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 16))
            let got = FontResolver.matchFamily(sample(text, font, rounded: true), size: 16)?.familyName
            #expect(got.map(ok.contains) == true, "\(family) matched \(got ?? "nothing")")
        }
    }

    @Test func chromeMeasurementsPickGeorgia() {
        // Measured in Chrome for a 16px Georgia textarea: word starts are rounded to whole points.
        let s = WidthSample(text: "the final agenda for the", width: 163, offsets: [4: 26, 10: 62, 17: 117, 21: 141])
        #expect(FontResolver.matchFamily(s, size: 16)?.familyName == "Georgia")
    }

    @Test func keepsSystemFontWhenItFits() {
        let text = "send you the final agenda"
        let system = NSFont.systemFont(ofSize: 15)
        #expect(FontResolver.matchFamily(sample(text, system, rounded: false), size: 15) == nil)
    }
}
