import AppKit
import TabberCore

/// Holds suggestions back right after a likely typo, so the model doesn't build on the mistake.
///
/// Only looks at the last finished word, ignores short and capitalized words (names, acronyms), and
/// caches verdicts because the same word is checked on every keystroke until the next one starts.
@MainActor
final class TypoGuard {
    private var cache: [String: Bool] = [:]
    private let checker = NSSpellChecker.shared

    /// True when the word just before the caret (or the one before a trailing space) looks misspelled.
    func suspectsTypo(before text: String) -> Bool {
        guard let word = lastWord(in: text), word.count >= 4,
              word.first?.isLowercase == true, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        if let hit = cache[word] { return hit }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let misspelled = range.location != NSNotFound
        if cache.count > 2000 { cache.removeAll() }
        cache[word] = misspelled
        return misspelled
    }

    /// A spelling fix for the last finished word: how many characters to replace and what with.
    /// The text after the word (a space or punctuation) is kept.
    func correction(before text: String) -> (replacing: Int, text: String)? {
        guard suspectsTypo(before: text), let word = lastWord(in: text) else { return nil }
        guard let range = text.range(of: word, options: .backwards) else { return nil }
        let tail = String(text[range.upperBound...])
        let nsText = text as NSString
        let nsRange = NSRange(range, in: text)
        let language = checker.language()
        // Only the system's confident autocorrection, not its list of guesses: a wrong fix is worse than none.
        guard let fixed = checker.correction(forWordRange: nsRange, in: nsText as String, language: language, inSpellDocumentWithTag: 0),
              fixed.lowercased() != word.lowercased(), !fixed.contains(" ") else { return nil }
        return (word.count + tail.count, fixed + tail)
    }

    /// The last complete word: the one followed by a single space or punctuation at the end of the text.
    private func lastWord(in text: String) -> String? {
        var end = text.endIndex
        // Only judge finished words: there must be a space or punctuation after it.
        guard let last = text.last, last == " " || TextRules.isTrailingPunctuation(last) else { return nil }
        while end > text.startIndex, !TextRules.isWordCharacter(text[text.index(before: end)]) { end = text.index(before: end) }
        var start = end
        while start > text.startIndex, TextRules.isWordCharacter(text[text.index(before: start)]) { start = text.index(before: start) }
        guard start < end, text.distance(from: end, to: text.endIndex) <= 2 else { return nil }
        return String(text[start..<end])
    }
}
