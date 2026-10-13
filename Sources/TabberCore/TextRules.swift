import Foundation

/// Character-level rules shared by the engine, the session, and insertion.
public enum TextRules {
    /// Characters that continue a word: letters, digits, marks, apostrophes, connector punctuation.
    public static func isWordCharacter(_ c: Character) -> Bool {
        if c == "'" || c == "’" || c == "_" { return true }
        return c.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    public static func isWhitespace(_ c: Character) -> Bool { c.isWhitespace }

    /// Punctuation that commonly sticks to the end of a word.
    public static func isTrailingPunctuation(_ c: Character) -> Bool {
        ".,;:!?…)]}\"”’»%".contains(c)
    }

    public static func isSentenceEnd(_ c: Character) -> Bool { ".!?…。！？".contains(c) }

    /// Scripts written without spaces between words, where one "word" must come from segmentation.
    public static func isSpacelessScript(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        switch s {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK
             0x0E00...0x0E7F, // Thai
             0x0E80...0x0EFF, // Lao
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF: // Khmer
            return true
        default:
            return false
        }
    }

    /// The partial word immediately before the caret (empty when the caret follows a space or punctuation).
    public static func partialWord(before text: String) -> Substring {
        var start = text.endIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            if isWordCharacter(text[prev]) && !isSpacelessScript(text[prev]) {
                start = prev
            } else {
                break
            }
        }
        return text[start...]
    }

    /// True when the caret is inside a word: a word character on both sides.
    public static func caretInsideWord(before: String, after: String) -> Bool {
        guard let l = before.last, let r = after.first else { return false }
        return isWordCharacter(l) && isWordCharacter(r)
    }

    /// Splits the next acceptable chunk off a suggestion remainder.
    ///
    /// A chunk is any leading whitespace plus one whitespace-delimited word. When the caret is mid-word,
    /// the first chunk finishes that word. Trailing punctuation and a single trailing space are included
    /// according to the options.
    public static func nextChunk(
        of remainder: Substring,
        includeTrailingPunctuation: Bool = true,
        includeTrailingSpace: Bool = false
    ) -> Substring {
        var i = remainder.startIndex
        // Leading whitespace, but never past a newline: a newline is its own chunk.
        while i < remainder.endIndex, remainder[i].isWhitespace, !remainder[i].isNewline { i = remainder.index(after: i) }
        if i < remainder.endIndex, remainder[i].isNewline, i == remainder.startIndex {
            return remainder[remainder.startIndex...remainder.startIndex]
        }
        let wordStart = i
        guard wordStart < remainder.endIndex else { return remainder }

        // Spaceless scripts: one segmented word at a time.
        if isSpacelessScript(remainder[wordStart]) {
            let rest = String(remainder[wordStart...])
            var firstWordEnd = rest.endIndex
            rest.enumerateSubstrings(in: rest.startIndex..<rest.endIndex, options: .byWords) { _, range, _, stop in
                firstWordEnd = range.upperBound
                stop = true
            }
            var end = remainder.index(wordStart, offsetBy: rest.distance(from: rest.startIndex, to: firstWordEnd))
            while end < remainder.endIndex, isTrailingPunctuation(remainder[end]) || "、，。！？".contains(remainder[end]) {
                end = remainder.index(after: end)
            }
            return remainder[remainder.startIndex..<end]
        }

        var end = wordStart
        while end < remainder.endIndex, !remainder[end].isWhitespace { end = remainder.index(after: end) }

        if !includeTrailingPunctuation {
            // Keep a pure-punctuation chunk intact, otherwise strip punctuation off the end.
            var trimmed = end
            while trimmed > wordStart, isTrailingPunctuation(remainder[remainder.index(before: trimmed)]) {
                trimmed = remainder.index(before: trimmed)
            }
            if trimmed > wordStart { end = trimmed }
        }

        if includeTrailingSpace, end < remainder.endIndex, remainder[end] == " " {
            end = remainder.index(after: end)
        }
        return remainder[remainder.startIndex..<end]
    }

    /// Number of whitespace-delimited words in a string.
    public static func wordCount(_ s: some StringProtocol) -> Int {
        var count = 0
        var inWord = false
        for c in s {
            if c.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
            if isSpacelessScript(c) { count += 1; inWord = false }
        }
        return count
    }

    /// Joins an insertion onto existing text without doubling spaces.
    public static func normalizedInsertion(_ chunk: String, after existing: String) -> String {
        guard let last = existing.last else {
            return String(chunk.drop { $0 == " " })
        }
        if last.isWhitespace, chunk.first == " " {
            return String(chunk.drop { $0 == " " })
        }
        return chunk
    }
}
