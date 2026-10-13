import Foundation

/// Context gathered around the field, rendered into a prompt preamble for a base (non-chat) model.
public struct PromptContext: Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var domain: String?
    public var fieldLabel: String?
    public var authorName: String?
    /// Short notes the user wrote about themselves and how they write.
    public var instructions: String?
    /// Text recognized on screen near the field.
    public var screenText: String?
    /// Recently copied text.
    public var clipboard: String?
    /// Past writing by the same author, retrieved for similarity.
    public var examples: [String]

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        domain: String? = nil,
        fieldLabel: String? = nil,
        authorName: String? = nil,
        instructions: String? = nil,
        screenText: String? = nil,
        clipboard: String? = nil,
        examples: [String] = []
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
        self.fieldLabel = fieldLabel
        self.authorName = authorName
        self.instructions = instructions
        self.screenText = screenText
        self.clipboard = clipboard
        self.examples = examples
    }
}

/// Builds the preamble that precedes the user's text.
///
/// Base models continue documents, they don't follow orders. So the preamble reads like the header of a
/// document: short labelled facts, then quoted reference material, then a separator. The user's own text
/// always comes last and the prompt ends exactly at the caret.
///
/// Everything here should stay stable while the user types in one field, so the engine can keep its cache.
public enum PromptBuilder {
    public struct Limits: Sendable {
        public var screenTextChars = 1800
        public var clipboardChars = 600
        public var instructionsChars = 600
        public var exampleChars = 400
        public var maxExamples = 2
        public init() {}
    }

    public enum Style: String, Sendable, CaseIterable {
        /// Labelled facts, quoted reference blocks, then an opening quote for the user's text.
        case quoted
        /// `[Heading]` sections, the user's text under `[Text before cursor]`.
        case bracketed
        /// Only reference text, separated from the user's text by a blank line.
        case minimal
        /// Like `quoted`, but the user's text follows a plain label instead of an opening quote.
        case labeled
        /// First-person framing: the writer describes where they are typing, then their text.
        case firstPerson
    }

    public static func preamble(for c: PromptContext, style: Style = .quoted, limits: Limits = Limits()) -> String {
        switch style {
        case .quoted: return quoted(c, limits: limits)
        case .bracketed: return bracketed(c, limits: limits)
        case .minimal: return minimal(c, limits: limits)
        case .firstPerson: return firstPerson(c, limits: limits)
        case .labeled:
            let q = quoted(c, limits: limits)
            guard q.hasSuffix("Text being written:\n\"\"\"\n") else { return q }
            return String(q.dropLast(4)) + "\n"
        }
    }

    private static func bracketed(_ c: PromptContext, limits: Limits) -> String {
        var sections: [String] = []
        var info: [String] = []
        if let app = clean(c.appName) { info.append("Application: \(app)") }
        if let domain = clean(c.domain) { info.append("Website: \(domain)") }
        if let title = clean(c.windowTitle).map({ String($0.prefix(120)) }), title != c.appName { info.append("Window title: \(title)") }
        if let label = clean(c.fieldLabel).map({ String($0.prefix(80)) }) { info.append("Field: \(label)") }
        if let author = clean(c.authorName) { info.append("Author: \(author)") }
        if !info.isEmpty { sections.append("[General information]\n" + info.joined(separator: "\n")) }
        if let notes = clean(c.instructions).map({ String($0.prefix(limits.instructionsChars)) }) { sections.append("[About the author]\n\(notes)") }
        let examples = c.examples.compactMap { clean($0) }.prefix(limits.maxExamples)
        if !examples.isEmpty { sections.append("[Earlier writing by the author]\n" + examples.map { String($0.suffix(limits.exampleChars)) }.joined(separator: "\n---\n")) }
        if let screen = clean(c.screenText).map({ String($0.suffix(limits.screenTextChars)) }) { sections.append("[Screen context]\n\(screen)") }
        if let clip = clean(c.clipboard).map({ String($0.prefix(limits.clipboardChars)) }) { sections.append("[Clipboard]\n\(clip)") }
        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n") + "\n\n[Text before cursor]\n"
    }

    private static func firstPerson(_ c: PromptContext, limits: Limits) -> String {
        var out = "I'm writing this on my Mac. Here is some context, though not all of it may matter:\n"
        var facts: [String] = []
        if let author = clean(c.authorName) { facts.append("My name: \(author)") }
        if let app = clean(c.appName) { facts.append("App I'm typing in: \(app)") }
        if let title = clean(c.windowTitle).map({ String($0.prefix(100)) }), title != c.appName { facts.append("Window: \(title)") }
        if let domain = clean(c.domain) { facts.append("Website: \(domain)") }
        if let label = clean(c.fieldLabel).map({ String($0.prefix(80)) }) { facts.append("Field: \(label)") }
        if !facts.isEmpty { out += "\n" + facts.joined(separator: "\n") + "\n" }
        if let notes = clean(c.instructions).map({ String($0.prefix(limits.instructionsChars)) }) {
            out += "\nAbout me and how I write:\n\(notes)\n"
        }
        if let screen = clean(c.screenText).map({ String($0.suffix(limits.screenTextChars)) }) {
            out += "\nOn screen around where I'm typing:\n\(screen)\n"
        }
        let examples = c.examples.compactMap { clean($0) }.prefix(limits.maxExamples)
        if !examples.isEmpty {
            out += "\nOther things I've written:\n" + examples.map { String($0.suffix(limits.exampleChars)) }.joined(separator: "\n\n⋯\n\n") + "\n"
        }
        if let clip = clean(c.clipboard).map({ String($0.prefix(limits.clipboardChars)) }) {
            out += "\nWhat I just copied:\n\(clip)\n"
        }
        return out + "\nWhat I'm writing now:\n\n"
    }

    private static func minimal(_ c: PromptContext, limits: Limits) -> String {
        var parts: [String] = []
        if let screen = clean(c.screenText).map({ String($0.suffix(limits.screenTextChars)) }) { parts.append(screen) }
        if let clip = clean(c.clipboard).map({ String($0.prefix(limits.clipboardChars)) }) { parts.append(clip) }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n\n") + "\n\n---\n\n"
    }

    private static func quoted(_ c: PromptContext, limits: Limits) -> String {
        var lines: [String] = []

        var facts: [String] = []
        if let app = clean(c.appName) { facts.append("App: \(app)") }
        if let domain = clean(c.domain) { facts.append("Website: \(domain)") }
        if let title = clean(c.windowTitle).map({ String($0.prefix(120)) }), title != c.appName {
            facts.append("Window: \(title)")
        }
        if let label = clean(c.fieldLabel).map({ String($0.prefix(80)) }) { facts.append("Field: \(label)") }
        if let author = clean(c.authorName) { facts.append("Author: \(author)") }
        if !facts.isEmpty { lines.append(facts.joined(separator: "\n")) }

        if let notes = clean(c.instructions).map({ String($0.prefix(limits.instructionsChars)) }) {
            lines.append("About the author and their writing:\n\(notes)")
        }

        let examples = c.examples.compactMap { clean($0) }.prefix(limits.maxExamples)
        if !examples.isEmpty {
            let quoted = examples.map { "\"\"\"\n\(String($0.suffix(limits.exampleChars)))\n\"\"\"" }
            lines.append("Earlier writing by the same author:\n" + quoted.joined(separator: "\n"))
        }

        if let screen = clean(c.screenText).map({ String($0.suffix(limits.screenTextChars)) }) {
            lines.append("Visible on screen:\n\"\"\"\n\(screen)\n\"\"\"")
        }
        if let clip = clean(c.clipboard).map({ String($0.prefix(limits.clipboardChars)) }) {
            lines.append("Recently copied:\n\"\"\"\n\(clip)\n\"\"\"")
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n\n") + "\n\nText being written:\n\"\"\"\n"
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
