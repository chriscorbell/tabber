import Foundation

/// Masks likely secrets in context text (screen OCR, clipboard) before it goes into a prompt.
///
/// It errs on the side of redacting: a false positive costs a few words of context, a false negative can leak a
/// credential into a prompt. Everything is pure and deterministic.
public enum SecretRedactor {
    public static let placeholder = "[redacted]"

    /// Returns `text` with every likely secret replaced by `[redacted]`.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for rule in rules {
            out = rule.apply(to: out)
        }
        return out
    }

    /// True when `text` contains anything `redact` would mask.
    public static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    /// True for a single whitespace-free token that looks like a credential: an API key, a hash-like string, or a
    /// password-shaped word. URLs, e-mail addresses and paths are not treated as secrets (their contents still go
    /// through `redact`).
    public static func looksLikeSecretToken(_ text: String) -> Bool {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return false }
        if containsSecret(token) { return true }
        if isURLOrPathOrEmail(token) { return false }

        var lower = false, upper = false, digit = false, symbol = false
        var digits = 0
        for scalar in token.unicodeScalars {
            if CharacterSet.lowercaseLetters.contains(scalar) { lower = true }
            else if CharacterSet.uppercaseLetters.contains(scalar) { upper = true }
            else if CharacterSet.decimalDigits.contains(scalar) { digit = true; digits += 1 }
            else { symbol = true }
        }
        let classes = [lower, upper, digit, symbol].filter { $0 }.count
        let length = token.count

        // Long mixed letter/digit runs: API keys, access tokens, hex digests.
        if length >= 20, (lower || upper), digit {
            let ratio = Double(digits) / Double(length)
            if classes >= 3 || (ratio > 0.15 && ratio < 0.9) { return true }
        }
        // Long hex strings (hashes, raw keys).
        if length >= 32, token.allSatisfy({ $0.isHexDigit }) { return true }
        // Password-shaped: 8+ characters mixing at least three character classes.
        if length >= 8, classes >= 3, digit || symbol { return true }
        return false
    }

    // MARK: - Rules

    private struct Rule {
        let regex: NSRegularExpression
        /// Returns the replacement for a match, or nil to leave it alone.
        let replace: (_ match: NSTextCheckingResult, _ in: NSString) -> String?

        func apply(to text: String) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            let out = NSMutableString(string: text)
            for match in matches.reversed() {
                if let replacement = replace(match, ns) {
                    out.replaceCharacters(in: match.range, with: replacement)
                }
            }
            return out as String
        }
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func whole(_ pattern: String, _ options: NSRegularExpression.Options = []) -> Rule {
        Rule(regex: regex(pattern, options)) { _, _ in placeholder }
    }

    private static let rules: [Rule] = [
        // PEM private keys, including a key cut off before its END line.
        whole(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        // JSON Web Tokens: three base64url segments, the first one a JSON object.
        whole(#"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#),
        // AWS access key IDs.
        whole(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ABIA|ACCA)[A-Z0-9]{16}\b"#),
        // OpenAI / Anthropic / Stripe style keys: sk-..., sk_live_..., rk_test_...
        whole(#"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"#),
        whole(#"\b(?:sk|rk)-(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{16,}"#),
        // GitHub tokens.
        whole(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        whole(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        // Slack tokens.
        whole(#"\bxox[abposre]-[A-Za-z0-9-]{10,}"#),
        // Google API keys.
        whole(#"\bAIza[0-9A-Za-z_-]{35}"#),
        // Bearer tokens in headers.
        Rule(regex: regex(#"\b(Bearer\s+)[A-Za-z0-9._~+/=-]{16,}"#)) { m, s in
            s.substring(with: m.range(at: 1)) + placeholder
        },
        // key: value / key=value assignments of credentials.
        Rule(regex: regex(
            #"(?<![A-Za-z])((?:password|passwd|passphrase|pwd|passcode|secret|client[_-]?secret|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|private[_-]?key)\b["']?\s*[:=]\s*)("[^"\n]{3,}"|'[^'\n]{3,}'|[^\s"',;]{2,}[^\s"',;.:)\]])"#,
            [.caseInsensitive]
        )) { m, s in
            let value = s.substring(with: m.range(at: 2))
            if value == placeholder || value.hasPrefix("[redacted") { return nil }
            return s.substring(with: m.range(at: 1)) + placeholder
        },
        // Card numbers: 13 to 19 digits, optionally grouped by spaces or dashes, passing the Luhn check. Matches
        // maximal digit runs, then looks for a valid card inside (a run can also hold a date or an expiry).
        Rule(regex: regex(#"(?<![\d.,])\d(?:[ -]?\d){12,}"#)) { m, s in
            redactCards(inDigitRun: s.substring(with: m.range))
        },
        // IBANs, validated with the ISO 7064 mod-97 checksum.
        Rule(regex: regex(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#)) { m, s in
            isValidIBAN(s.substring(with: m.range)) ? placeholder : nil
        },
    ]

    // MARK: - Validators

    /// Replaces every card-number span inside a run of digit groups ("2024-01-15 4111 1111 1111 1111 12"),
    /// or returns nil when there is none.
    static func redactCards(inDigitRun run: String) -> String? {
        // Split into digit groups, remembering where each sits in the run.
        var groups: [(range: Range<String.Index>, digits: String)] = []
        var i = run.startIndex
        while i < run.endIndex {
            if run[i].isNumber {
                var j = i
                while j < run.endIndex, run[j].isNumber { j = run.index(after: j) }
                groups.append((i..<j, String(run[i..<j])))
                i = j
            } else {
                i = run.index(after: i)
            }
        }

        var spans: [Range<String.Index>] = []
        var start = 0
        while start < groups.count {
            var digits = ""
            var best: Int?
            for end in start..<groups.count {
                digits += groups[end].digits
                if digits.count > 19 { break }
                if isLikelyCardNumber(digits) { best = end }
            }
            if let end = best {
                spans.append(groups[start].range.lowerBound..<groups[end].range.upperBound)
                start = end + 1
            } else {
                start += 1
            }
        }
        guard !spans.isEmpty else { return nil }
        var out = run
        for span in spans.reversed() { out.replaceSubrange(span, with: placeholder) }
        return out
    }

    static func isLikelyCardNumber(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count), let first = digits.first, "23456".contains(first) else { return false }
        return luhn(digits)
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    static func isValidIBAN(_ raw: String) -> Bool {
        let iban = raw.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(iban.count) else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            if let d = ch.wholeNumberValue, ch.isASCII {
                remainder = (remainder * 10 + d) % 97
            } else if let ascii = ch.asciiValue, ch.isLetter {
                let value = Int(ascii) - 55 // A = 10
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    private static func isURLOrPathOrEmail(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("mailto:") { return true }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../") { return true }
        if let at = token.firstIndex(of: "@"), at != token.startIndex {
            let domain = token[token.index(after: at)...]
            if domain.contains("."), !domain.contains("@") { return true }
        }
        return false
    }
}
