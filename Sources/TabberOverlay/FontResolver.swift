import AppKit
import CoreText
import TabberCore

/// Turns the style an app reports at the caret into the font the ghost is drawn in.
enum FontResolver {
    /// - Parameters:
    ///   - caretHeight: used to sanity-check (or derive) the size.
    ///   - scale: the user's font-size correction for this app.
    static func font(for style: TextStyle?, caretHeight: CGFloat?, scale: CGFloat = 1) -> NSFont {
        var base = baseFont(name: style?.fontName, family: style?.fontFamily)
        if style?.fontName == nil, style?.fontFamily == nil, let size = style?.fontSize, let sample = style?.widthSample {
            base = matchFamily(sample, size: size) ?? base
        }
        let unit = metrics(of: base).scaled(to: 1)
        var size = GhostLayout.fontSize(reported: style?.fontSize, caretHeight: caretHeight, unitLineHeight: unit.lineHeight)
        if scale.isFinite, scale > 0 { size *= scale }
        size = GhostLayout.clamp(size, 6...96)
        return base.withSize(size)
    }

    static func metrics(of font: NSFont) -> FontMetrics {
        let ct = font as CTFont
        return FontMetrics(
            pointSize: font.pointSize,
            ascent: CTFontGetAscent(ct),
            descent: CTFontGetDescent(ct),
            leading: CTFontGetLeading(ct)
        )
    }

    /// The typeface, at an arbitrary size: the exact face when the name resolves, else the family, else the system font.
    /// When the name and family disagree (Word reports a fake "Helvetica" name with the real family), the family wins.
    static func baseFont(name: String?, family: String?) -> NSFont {
        let size: CGFloat = 12
        let name = name?.trimmingCharacters(in: .whitespaces).nonEmpty
        let family = family.map(cleanFamily)?.nonEmpty

        let named = name.flatMap { namedFont($0, size: size) }
        if let family {
            if let named, matches(named, family: family) { return named }
            // A generic family ("sans-serif") with a concrete name: the name is what it resolved to.
            if let generic = genericFont(family, size: size, like: named) { return named ?? generic }
            if let byFamily = familyFont(family, like: named, size: size) { return byFamily }
        }
        if let named { return named }
        return NSFont.systemFont(ofSize: size)
    }

    // MARK: - Matching by width

    /// Common web and system families, checked when an app reports only a size.
    static let candidateFamilies = [
        "Helvetica", "Arial", "Georgia", "Times New Roman", "Verdana", "Trebuchet MS", "Menlo",
        "Courier New", "Inter", "Roboto", "Open Sans", "Lato", "Avenir Next", "Palatino",
    ]

    private static let matchCache = NSCache<NSString, NSFont>()

    /// The family whose rendering of the sample is closest to its measured width, if clearly better than the system font.
    static func matchFamily(_ sample: WidthSample, size: CGFloat) -> NSFont? {
        let positions = sample.offsets.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value * 4))" }.joined(separator: ",")
        let key = "\(sample.text)|\(Int(sample.width * 4))|\(Int(size * 4))|\(positions)" as NSString
        if let hit = matchCache.object(forKey: key) { return hit }
        // Mean distance, in points, between where the font would put each measured position and where the app did.
        let total = sample.text.utf16.count
        let points = sample.offsets.sorted { $0.key < $1.key } + [(key: total, value: sample.width)]
        func error(_ font: NSFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample.text, attributes: [.font: font]))
            let sum = points.reduce(CGFloat(0)) { acc, p in
                let x = p.key == total ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : CTLineGetOffsetForStringIndex(line, p.key, nil)
                return acc + abs(x - p.value)
            }
            return sum / CGFloat(points.count)
        }
        let system = NSFont.systemFont(ofSize: size)
        let systemError = error(system)
        var best: (font: NSFont, error: CGFloat)?
        for family in candidateFamilies {
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else { continue }
            let e = error(font)
            if e < (best?.error ?? .infinity) { best = (font, e) }
        }
        // Positions are often rounded to whole points, so allow about half a point of error on average.
        let tolerance = max(0.75, sample.width * 0.006)
        guard let best, best.error < tolerance, best.error + 0.3 < systemError else { return nil }
        let result = best.font.withSize(12)
        matchCache.setObject(result, forKey: key)
        return result
    }

    // MARK: - Helpers

    private static func namedFont(_ name: String, size: CGFloat) -> NSFont? {
        if let generic = genericFont(name, size: size, like: nil) { return generic }
        if name.hasPrefix(".") {
            // Private system UI faces (".SFNS-Semibold", ".SFUI-Regular"): ask for the system font instead.
            if name.hasPrefix(".AppleSystemUIFont"), let font = NSFont(name: name, size: size) { return font }
            return NSFont.systemFont(ofSize: size, weight: weight(fromStyleName: name))
        }
        return NSFont(name: name, size: size)
    }

    /// CSS generic families and the names browsers use for the system font.
    private static func genericFont(_ family: String, size: CGFloat, like named: NSFont?) -> NSFont? {
        let traits = named.map { NSFontManager.shared.traits(of: $0) } ?? []
        let weight: NSFont.Weight = traits.contains(.boldFontMask) ? .bold : .regular
        switch family.lowercased() {
        case "-apple-system", "system-ui", "blinkmacsystemfont", "ui-sans-serif", "apple system", "system font", "sf pro", "sf pro text", "sf pro display":
            return NSFont.systemFont(ofSize: size, weight: weight)
        case "ui-monospace", "sf mono":
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "ui-serif", "new york":
            if let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) { return NSFont(descriptor: d, size: size) }
            return nil
        case "ui-rounded":
            if let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) }
            return nil
        case "sans-serif":
            return familyFont("Helvetica", like: named, size: size)
        case "serif":
            return familyFont("Times", like: named, size: size)
        case "monospace":
            return familyFont("Menlo", like: named, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "cursive":
            return familyFont("Apple Chancery", like: named, size: size)
        default:
            return nil
        }
    }

    private static func familyFont(_ family: String, like named: NSFont?, size: CGFloat) -> NSFont? {
        let manager = NSFontManager.shared
        guard manager.availableMembers(ofFontFamily: family) != nil else { return nil }
        var traits: NSFontTraitMask = []
        var weight = 5
        if let named {
            traits = manager.traits(of: named).intersection([.boldFontMask, .italicFontMask])
            weight = manager.weight(of: named)
        }
        return manager.font(withFamily: family, traits: traits, weight: weight, size: size)
            ?? manager.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    private static func matches(_ font: NSFont, family: String) -> Bool {
        let wanted = family.lowercased()
        if font.familyName?.lowercased() == wanted { return true }
        if font.displayName?.lowercased().hasPrefix(wanted) == true { return true }
        // Localized family names (e.g. a Japanese family reported in Japanese).
        if let localized = CTFontCopyLocalizedName(font as CTFont, kCTFontFamilyNameKey, nil) as String?, localized.lowercased() == wanted {
            return true
        }
        return false
    }

    /// A CSS font-family list ("'Segoe UI', Roboto, sans-serif") becomes its first installed entry.
    private static func cleanFamily(_ raw: String) -> String {
        let entries = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
        guard entries.count > 1 else { return entries.first ?? "" }
        for entry in entries {
            if NSFontManager.shared.availableMembers(ofFontFamily: entry) != nil { return entry }
            if genericFont(entry, size: 12, like: nil) != nil { return entry }
        }
        return entries[0]
    }

    private static func weight(fromStyleName name: String) -> NSFont.Weight {
        let n = name.lowercased()
        if n.contains("black") || n.contains("heavy") { return .heavy }
        if n.contains("semibold") || n.contains("demi") { return .semibold }
        if n.contains("bold") { return .bold }
        if n.contains("medium") { return .medium }
        if n.contains("light") { return .light }
        if n.contains("thin") { return .thin }
        return .regular
    }
}

/// Measures and shapes text in one font with CoreText, so measured widths match drawn widths.
final class TextMeasurer {
    let font: NSFont
    private var cache: [Substring: CGFloat] = [:]

    init(font: NSFont) { self.font = font }

    func width(_ text: Substring) -> CGFloat {
        if text.isEmpty { return 0 }
        if let cached = cache[text] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text), attributes: [.font: font]))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[text] = w
        return w
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
