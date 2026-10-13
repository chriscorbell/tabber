import Foundation

/// Turns the strings apps put in AXURL and AXDocument into URLs.
enum URLExtraction {
    /// Schemes that never identify a site worth keying settings or context on. Data URLs can also be huge.
    private static let ignoredSchemes: Set<String> = ["about", "data", "javascript", "blob", "chrome", "edge", "brave"]

    static func url(fromString raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 4096 else { return nil }

        // AXDocument is sometimes a bare path.
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        if text.hasPrefix("~/") { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }

        if let schemeEnd = text.range(of: ":"), text[..<schemeEnd.lowerBound].allSatisfy(isSchemeCharacter),
           !text[..<schemeEnd.lowerBound].isEmpty {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            if ignoredSchemes.contains(scheme) { return nil }
            let hasAuthority = text[schemeEnd.upperBound...].hasPrefix("//")
            // "localhost:3000/x" parses with "localhost" as the scheme; treat a bare host:port as a host.
            if !hasAuthority, !["mailto", "file", "tel", "news"].contains(scheme) {
                return hostLike(text) ? webURL("https://" + text) : nil
            }
            guard let url = parse(text) else { return nil }
            if ["http", "https"].contains(scheme), (url.host ?? "").isEmpty { return nil }
            return url
        }

        return hostLike(text) ? webURL("https://" + text) : nil
    }

    private static func webURL(_ text: String) -> URL? {
        guard let url = parse(text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func parse(_ text: String) -> URL? {
        if let url = URL(string: text) { return url }
        // Unescaped spaces and similar: escape what URL(string:) rejects and try again.
        let allowed = CharacterSet.urlFragmentAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "#%"))
        return text.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    /// "example.com", "example.com/path", "localhost:3000".
    private static func hostLike(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let host = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.split(separator: ":").first.map(String.init) ?? ""
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return false }
        return host == "localhost" || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix("."))
    }

    private static func isSchemeCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "+" || c == "-" || c == ".")
    }
}
