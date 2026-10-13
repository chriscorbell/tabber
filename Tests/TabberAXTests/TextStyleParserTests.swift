import AppKit
import TabberCore
import Testing
@testable import TabberAX

@Suite struct TextStyleParserTests {
    @Test func axFontAndGenericRGBColor() throws {
        // As WebKit and Chromium send it: sRGB values tagged with the Generic RGB profile.
        let space = try #require(CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString))
        let color = try #require(CGColor(colorSpace: space, components: [1.0, 0.8235294, 0.4784314, 1.0]))
        let attributes: [NSAttributedString.Key: Any] = [
            TextStyleParser.axFont: ["AXFontName": "Georgia", "AXFontFamily": "Georgia", "AXFontSize": NSNumber(value: 18)],
            TextStyleParser.axForegroundColor: color,
        ]
        let style = try #require(TextStyleParser.style(from: attributes))
        #expect(style.fontName == "Georgia")
        #expect(style.fontFamily == "Georgia")
        #expect(style.fontSize == 18)
        let rgba = try #require(style.textColor)
        #expect(Int((rgba.r * 255).rounded()) == 0xff)
        #expect(Int((rgba.g * 255).rounded()) == 0xd2)
        #expect(Int((rgba.b * 255).rounded()) == 0x7a)
        #expect(rgba.a == 1)
    }

    @Test func sizeOnlyFont() throws {
        // Chromium sends only the size.
        let style = try #require(TextStyleParser.style(from: [TextStyleParser.axFont: ["AXFontSize": NSNumber(value: 15)]]))
        #expect(style.fontSize == 15)
        #expect(style.fontName == nil)
        #expect(style.textColor == nil)
    }

    @Test func visibleNameStandsInForAMissingFontName() throws {
        let style = try #require(TextStyleParser.style(from: [TextStyleParser.axFont: ["AXVisibleName": "Helvetica Neue"]]))
        #expect(style.fontName == "Helvetica Neue")
    }

    @Test func srgbColorsConvert() throws {
        let color = try #require(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.2, 0.4, 0.6, 0.5]))
        let rgba = try #require(TextStyleParser.rgba(color))
        #expect(abs(rgba.r - 0.2) < 0.001 && abs(rgba.g - 0.4) < 0.001 && abs(rgba.b - 0.6) < 0.001)
        #expect(abs(rgba.a - 0.5) < 0.001)
    }

    @Test func grayColors() throws {
        let rgba = try #require(TextStyleParser.rgba(CGColor(gray: 0.5, alpha: 1)))
        #expect(abs(rgba.r - rgba.g) < 0.001 && abs(rgba.g - rgba.b) < 0.001)
    }

    @Test func appKitAttributes() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let style = try #require(TextStyleParser.style(from: [.font: font, .foregroundColor: NSColor.red]))
        #expect(style.fontSize == 13)
        #expect(style.fontName == font.fontName)
        #expect(style.textColor?.r ?? 0 > 0.9)
    }

    @Test func wrongTypesAreIgnored() {
        let attributes: [NSAttributedString.Key: Any] = [
            TextStyleParser.axFont: "not a dictionary",
            TextStyleParser.axForegroundColor: "not a color",
            .font: 12,
        ]
        #expect(TextStyleParser.style(from: attributes) == nil)
        #expect(TextStyleParser.style(from: [:]) == nil)
        #expect(TextStyleParser.style(from: [TextStyleParser.axFont: ["AXFontSize": NSNumber(value: Double.nan)]]) == nil)
    }
}
