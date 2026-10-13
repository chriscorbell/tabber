import Foundation

/// Emoji from shortcodes (":joy" → 😂), emoticons (":)" → 🙂), and Mac key names (":cmd" → ⌘).
public enum EmojiSuggester {
    public struct Suggestion: Equatable, Sendable {
        /// Characters before the caret that the emoji replaces.
        public var replacing: Int
        public var emoji: String
        public var alternatives: [String]
    }

    static let keySymbols: [(String, String)] = [
        ("cmd", "⌘"), ("command", "⌘"), ("opt", "⌥"), ("option", "⌥"), ("alt", "⌥"), ("shift", "⇧"),
        ("ctrl", "⌃"), ("control", "⌃"), ("return", "↩"), ("enter", "⌤"), ("tab", "⇥"), ("esc", "⎋"),
        ("delete", "⌫"), ("del", "⌫"), ("caps", "⇪"), ("fn", "🌐"),
    ]

    static let emoticons: [String: String] = [
        ":)": "🙂", ":-)": "🙂", ":D": "😄", ":-D": "😄", ";)": "😉", ";-)": "😉", ":(": "🙁", ":-(": "🙁",
        ":P": "😛", ":-P": "😛", ":p": "😛", "<3": "❤️", ":O": "😮", ":o": "😮", ":'(": "😢", "xD": "😆",
        "XD": "😆", ":|": "😐", ":/": "😕", ":-/": "😕", "B)": "😎", "</3": "💔", ":*": "😘", "^^": "😊",
    ]

    private static let index: [(name: String, emoji: String, rank: Int)] = {
        var all = keySymbols.enumerated().map { (name: $0.element.0, emoji: $0.element.1, rank: -100 + $0.offset) }
        all += EmojiTable.entries.map { (name: $0.0, emoji: $0.1, rank: $0.2) }
        return all.sorted { $0.name < $1.name }
    }()

    /// The emoji for the end of `text`, if it ends with a shortcode or an emoticon at a word boundary.
    public static func suggestion(before text: String, emoticons allowEmoticons: Bool = true) -> Suggestion? {
        if allowEmoticons {
            for (face, emoji) in emoticons where text.hasSuffix(face) {
                let before = text.dropLast(face.count)
                if before.isEmpty || before.last!.isWhitespace {
                    return Suggestion(replacing: face.count, emoji: emoji, alternatives: [])
                }
            }
        }
        // ":" + at least two shortcode characters, after the start or whitespace.
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let query = text[text.index(after: colon)...]
        guard query.count >= 2, query.count <= 32,
              query.allSatisfy({ ($0.isLetter && $0.isASCII && $0.isLowercase) || $0.isNumber || "_+-".contains($0) }) else { return nil }
        if colon > text.startIndex, !text[text.index(before: colon)].isWhitespace, !"([{\"'".contains(text[text.index(before: colon)]) { return nil }

        let q = String(query)
        var matches: [(emoji: String, score: Int)] = []
        var seen = Set<String>()
        // Binary search the first name >= query, then walk the names with that prefix.
        var lo = 0, hi = index.count
        while lo < hi { let mid = (lo + hi) / 2; if index[mid].name < q { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < index.count, index[i].name.hasPrefix(q) {
            let e = index[i]
            let exact = e.name == q ? -1_000_000 : 0
            if !seen.contains(e.emoji) {
                seen.insert(e.emoji)
                matches.append((e.emoji, exact + e.rank + e.name.count * 50))
            }
            i += 1
        }
        guard !matches.isEmpty else { return nil }
        matches.sort { $0.score < $1.score }
        return Suggestion(replacing: q.count + 1, emoji: matches[0].emoji, alternatives: matches.dropFirst().prefix(4).map(\.emoji))
    }
}
