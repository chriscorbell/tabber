import AppKit
import TabberCore

/// Reads font and color out of the attributes of an AX attributed string.
enum TextStyleParser {
    static let axFont = NSAttributedString.Key("AXFont")
    static let axForegroundColor = NSAttributedString.Key("AXForegroundColor")

    static func style(from attributes: [NSAttributedString.Key: Any]) -> TextStyle? {
        var style = TextStyle()

        // Remote apps send the AX keys. NSFont/NSColor show up when the string comes from an in-process view.
        if let font = attributes[.font] as? NSFont {
            style.fontName = font.fontName
            style.fontFamily = font.familyName
            style.fontSize = font.pointSize
        } else if let font = attributes[axFont] as? [String: Any] {
            style.fontName = font["AXFontName"] as? String
            style.fontFamily = font["AXFontFamily"] as? String
            if let size = font["AXFontSize"] as? NSNumber, size.doubleValue.isFinite, size.doubleValue > 0 {
                style.fontSize = CGFloat(size.doubleValue)
            }
            if style.fontName == nil { style.fontName = font["AXVisibleName"] as? String }
        }

        if let raw = attributes[axForegroundColor], let color = cgColor(raw) {
            style.textColor = rgba(color)
        } else if let color = attributes[.foregroundColor] as? NSColor {
            style.textColor = rgba(color)
        }

        let isEmpty = style.fontName == nil && style.fontFamily == nil && style.fontSize == nil && style.textColor == nil
        return isEmpty ? nil : style
    }

    static func cgColor(_ value: Any) -> CGColor? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == CGColor.typeID else { return nil }
        return (object as! CGColor)
    }

    static func rgba(_ color: CGColor) -> RGBA? {
        // WebKit (and the AX bridge generally) tags colors as Generic RGB while the components are the page's
        // sRGB values: converting would lighten them (#ffd27a arrives as 1.0/0.82/0.48 and would become #ffd98c).
        if color.colorSpace?.name == ("kCGColorSpaceGenericRGB" as CFString), let c = color.components, c.count >= 3 {
            return RGBA(r: unit(c[0]), g: unit(c[1]), b: unit(c[2]), a: unit(c.count >= 4 ? c[3] : color.alpha))
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
           let c = converted.components, c.count >= 3 {
            return RGBA(r: unit(c[0]), g: unit(c[1]), b: unit(c[2]), a: unit(c.count >= 4 ? c[3] : converted.alpha))
        }
        // Gray colors that refuse conversion (e.g. pattern-less generic gray without a profile).
        if color.numberOfComponents == 2, let c = color.components {
            return RGBA(r: unit(c[0]), g: unit(c[0]), b: unit(c[0]), a: unit(c[1]))
        }
        return nil
    }

    static func rgba(_ color: NSColor) -> RGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGBA(
            r: unit(srgb.redComponent), g: unit(srgb.greenComponent),
            b: unit(srgb.blueComponent), a: unit(srgb.alphaComponent)
        )
    }

    private static func unit(_ value: CGFloat) -> Double {
        value.isFinite ? min(max(Double(value), 0), 1) : 0
    }
}
