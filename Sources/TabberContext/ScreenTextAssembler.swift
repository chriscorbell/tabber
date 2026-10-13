import CoreGraphics
import Foundation

/// One line of text recognized on screen.
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    /// Recognizer confidence, 0...1.
    public var confidence: Float
    /// Bounding box in points, top-left origin, y down, in the same space as the field rect given to the assembler.
    public var box: CGRect

    public init(text: String, confidence: Float, box: CGRect) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// Turns raw OCR lines into the short, clean "Visible on screen" text for the prompt.
///
/// Steps: drop low-confidence lines, garbage, lines inside the field and lines that only echo the field's own text;
/// rank what's left by distance to the field (text above it, in its column, wins); keep the closest lines within a
/// character budget; then lay them out in reading order, merging wrapped lines into paragraphs. Only whitespace is
/// normalized; punctuation is kept as recognized.
public enum ScreenTextAssembler {
    public struct Options: Sendable, Equatable {
        public var minimumConfidence: Float = 0.4
        /// Lines shorter than this many points (fine print, badges) are dropped.
        public var minimumLineHeight: CGFloat = 5
        public var characterBudget = 1800
        /// Lines centred outside the field's column (the field's x-range widened by this margin) are ranked as if
        /// they were much farther away. Sidebars and toolbars live there.
        public var columnMargin: CGFloat = 160
        /// The column is at least this wide, so a narrow field still has a sensible column around it.
        public var minimumColumnWidth: CGFloat = 520
        /// Distance below the field counts this many times more than the same distance above it.
        public var belowWeight: CGFloat = 3
        /// Extra distance, in points, for a line outside the column, plus `offColumnWeight` per point of gap.
        public var offColumnPenalty: CGFloat = 600
        public var offColumnWeight: CGFloat = 2

        public init() {}
    }

    /// Returns the assembled text, or an empty string when nothing useful was recognized.
    /// - Parameters:
    ///   - field: The focused field's rect in the lines' coordinate space. Lines centred inside it are dropped.
    ///   - fieldText: The field's own text (before and after the caret), used to drop echoed lines.
    ///   - alsoKnown: Other text the prompt already has, such as the window title and URL. Lines that only repeat
    ///     it (a browser's tab title and address bar) are dropped too.
    public static func assemble(
        _ lines: [RecognizedLine],
        field: CGRect,
        fieldText: String,
        alsoKnown: [String] = [],
        options: Options = Options()
    ) -> String {
        let known = ([fieldText] + alsoKnown).joined(separator: "\n")
        let cleaned = clean(lines, field: field, echo: EchoFilter(fieldText: known), options: options)
        let selected = select(cleaned, field: field, options: options)
        return layout(selected)
    }

    // MARK: - Cleaning

    static func clean(_ lines: [RecognizedLine], field: CGRect, echo: EchoFilter, options: Options) -> [RecognizedLine] {
        let fieldZone = field.insetBy(dx: -2, dy: -2)
        let column = self.column(for: field, options: options)
        var out: [RecognizedLine] = []
        out.reserveCapacity(lines.count)
        for var line in lines {
            guard line.confidence >= options.minimumConfidence, line.box.height >= options.minimumLineHeight else { continue }
            line.text = normalizeWhitespace(line.text)
            guard !line.text.isEmpty else { continue }
            guard !fieldZone.contains(CGPoint(x: line.box.midX, y: line.box.midY)) else { continue }
            guard !isGarbage(line.text) else { continue }
            guard !echo.isEcho(line.text) else { continue }
            // A lone word outside the field's column is almost always UI chrome: a menu, tab or sidebar item.
            // Inside the column it may be a name or a greeting, so it stays.
            if !line.text.contains(" "), !inColumn(line.box, column) { continue }
            out.append(line)
        }
        return out
    }

    /// OCR noise: replacement characters, lines with almost no letters or digits, symbol soup, and lines dominated
    /// by words with digits inside lowercase letters ("qu81ity").
    static func isGarbage(_ text: String) -> Bool {
        if text.contains("\u{FFFD}") { return true }
        var alnum = 0, symbols = 0, total = 0
        for ch in text where !ch.isWhitespace {
            total += 1
            if ch.isLetter || ch.isNumber { alnum += 1 } else { symbols += 1 }
        }
        if alnum < 2 { return true }
        if Double(symbols) / Double(total) > 0.5 { return true }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        let mangled = words.filter(isMangledWord).count
        if mangled > 0, Double(mangled) / Double(words.count) > 0.3 { return true }
        return false
    }

    /// A lowercase letter, then digits, then a lowercase letter: the classic l/1, o/0 misread.
    private static func isMangledWord(_ word: Substring) -> Bool {
        let chars = Array(word)
        guard chars.count >= 3 else { return false }
        var i = 1
        while i < chars.count - 1 {
            if chars[i].isNumber, chars[i - 1].isLowercase {
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j < chars.count, chars[j].isLowercase { return true }
                i = j
            } else {
                i += 1
            }
        }
        return false
    }

    static func normalizeWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Ranking and budget

    static func column(for field: CGRect, options: Options) -> ClosedRange<CGFloat> {
        var lo = field.minX - options.columnMargin
        var hi = field.maxX + options.columnMargin
        let width = hi - lo
        if width < options.minimumColumnWidth {
            let grow = (options.minimumColumnWidth - width) / 2
            lo -= grow
            hi += grow
        }
        return lo...hi
    }

    /// A line belongs to the column when its centre is inside it.
    private static func inColumn(_ box: CGRect, _ column: ClosedRange<CGFloat>) -> Bool {
        column.contains(box.midX)
    }

    /// Effective distance from the field. Lower is closer.
    static func score(_ box: CGRect, field: CGRect, options: Options) -> CGFloat {
        let vertical: CGFloat
        if box.maxY <= field.minY {
            vertical = field.minY - box.maxY
        } else if box.minY >= field.maxY {
            vertical = (box.minY - field.maxY) * options.belowWeight
        } else {
            vertical = 0 // beside the field
        }
        let column = self.column(for: field, options: options)
        var horizontal: CGFloat = 0
        if !inColumn(box, column) {
            let gap = box.midX < column.lowerBound ? column.lowerBound - box.midX : box.midX - column.upperBound
            horizontal = options.offColumnPenalty + gap * options.offColumnWeight
        }
        return vertical + horizontal
    }

    /// The closest lines whose text fits the budget (each line costs its length plus a separator).
    static func select(_ lines: [RecognizedLine], field: CGRect, options: Options) -> [RecognizedLine] {
        let ranked = lines
            .map { (line: $0, score: score($0.box, field: field, options: options)) }
            .sorted { a, b in
                if a.score != b.score { return a.score < b.score }
                return a.line.box.maxY > b.line.box.maxY
            }
        var budget = options.characterBudget
        var out: [RecognizedLine] = []
        for (line, _) in ranked {
            let cost = line.text.count + 1
            if cost <= budget {
                out.append(line)
                budget -= cost
                continue
            }
            // The first line that doesn't fit ends the selection, cut at a word boundary if enough room is left.
            if budget >= 40 {
                var cut = line
                cut.text = truncate(line.text, to: budget - 1)
                if !cut.text.isEmpty { out.append(cut) }
            }
            break
        }
        return out
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space])
        }
        return String(head)
    }

    // MARK: - Layout

    private struct Block {
        var lines: [RecognizedLine]
        var frame: CGRect
        /// One-line blocks to the right of a line, by line index, read right after that line.
        var sideNotes: [Int: [RecognizedLine]] = [:]
    }

    /// Reading order: blocks top to bottom, side-by-side blocks left to right. Within a block, lines that fill the
    /// block's width were soft-wrapped and are joined with a space; shorter lines end a line of their own.
    static func layout(_ lines: [RecognizedLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let sorted = lines.sorted { a, b in
            if a.box.minY != b.box.minY { return a.box.minY < b.box.minY }
            return a.box.minX < b.box.minX
        }

        var blocks: [Block] = []
        for line in sorted {
            // The block this line continues: its last line sits right above, left-aligned with it (or, for centred
            // text, overlapping most of the wider line). Left alignment beats overlap, then the smaller gap wins, so
            // a short label above the end of a long line (a timestamp) doesn't capture the paragraph below it.
            var target: (index: Int, aligned: Bool, gap: CGFloat)?
            for i in blocks.indices {
                guard let last = blocks[i].lines.last else { continue }
                let h = max(last.box.height, line.box.height, 1)
                let gap = line.box.minY - last.box.maxY
                guard gap > -0.5 * h, gap < 0.9 * h else { continue }
                let leftAligned = abs(line.box.minX - last.box.minX) < 1.5 * h
                let overlap = min(line.box.maxX, last.box.maxX) - max(line.box.minX, last.box.minX)
                let overlapping = overlap > 0.5 * max(line.box.width, last.box.width)
                guard leftAligned || overlapping else { continue }
                if let t = target, t.aligned && !leftAligned || (t.aligned == leftAligned && t.gap <= gap) { continue }
                target = (i, leftAligned, gap)
            }
            if let i = target?.index {
                blocks[i].lines.append(line)
                blocks[i].frame = blocks[i].frame.union(line.box)
            } else {
                blocks.append(Block(lines: [line], frame: line.box))
            }
        }

        // A one-line block level with a line of a paragraph to its left is a side note on that line, like the time
        // next to a sender's name. It reads right after that line rather than after the whole paragraph.
        var removed = Set<Int>()
        for s in blocks.indices where blocks[s].lines.count == 1 {
            let note = blocks[s].lines[0]
            var best: (block: Int, line: Int, gap: CGFloat)?
            for m in blocks.indices where m != s && blocks[m].lines.count > 1 && !removed.contains(m) {
                for (k, line) in blocks[m].lines.enumerated() {
                    let h = max(line.box.height, note.box.height)
                    guard abs(line.box.midY - note.box.midY) < 0.6 * h, line.box.maxX <= note.box.minX else { continue }
                    let gap = note.box.minX - line.box.maxX
                    if best == nil || gap < best!.gap { best = (m, k, gap) }
                }
            }
            if let best {
                blocks[best.block].sideNotes[best.line, default: []].append(note)
                removed.insert(s)
            }
        }
        blocks = blocks.enumerated().filter { !removed.contains($0.offset) }.map(\.element)

        // Rows of blocks: blocks starting at about the same height read left to right.
        blocks.sort { $0.frame.minY < $1.frame.minY }
        var ordered: [Block] = []
        var row: [Block] = []
        var rowTop: CGFloat = 0
        var rowTolerance: CGFloat = 0
        for block in blocks {
            if !row.isEmpty, block.frame.minY - rowTop < rowTolerance {
                row.append(block)
            } else {
                ordered += row.sorted { $0.frame.minX < $1.frame.minX }
                row = [block]
                rowTop = block.frame.minY
                rowTolerance = max((block.lines.first?.box.height ?? 0) * 0.5, 1)
            }
        }
        ordered += row.sorted { $0.frame.minX < $1.frame.minX }

        return ordered.map(render).joined(separator: "\n")
    }

    private static func render(_ block: Block) -> String {
        let maxWidth = block.lines.map(\.box.width).max() ?? 0
        var out = ""
        for (i, line) in block.lines.enumerated() {
            if i > 0 {
                let previous = block.lines[i - 1]
                // Soft-wrapped when the previous line fills the block: in a wide block that's enough; in a narrow
                // one (a chat bubble) the next line must also continue in lowercase. Otherwise the break is real:
                // signatures, addresses, lists, headers. A line followed by side notes always ends there.
                let fills = previous.box.width >= 0.7 * maxWidth
                let continues = line.text.first?.isLowercase ?? false
                let wrapped = block.sideNotes[i - 1] == nil && fills && (maxWidth >= 240 || continues)
                if wrapped, out.hasSuffix("-"), let before = out.dropLast().last, before.isLetter {
                    // Hyphenated soft wrap: "well-" + "known".
                } else {
                    out += wrapped ? " " : "\n"
                }
            }
            out += line.text
            if let notes = block.sideNotes[i] {
                out += "\n" + notes.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "\n")
            }
        }
        return out
    }
}

/// Recognizes OCR lines that merely repeat the field's own text, so the prompt doesn't quote the user back to itself.
struct EchoFilter {
    private let normalized: String
    private let words: Set<Substring>
    private let bigrams: Set<String>

    init(fieldText: String) {
        let norm = EchoFilter.normalize(fieldText)
        // Padded so containment checks match whole words only.
        normalized = norm.isEmpty ? "" : " \(norm) "
        words = Set(norm.split(separator: " "))
        bigrams = EchoFilter.bigrams(of: norm)
    }

    /// A line is an echo when its normalized form occurs in the field's text as whole words, or when it has four or
    /// more words that are nearly all in the field's text and mostly in the same pairs (OCR rarely reproduces long
    /// text exactly: "I wi11 send").
    func isEcho(_ line: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        let norm = EchoFilter.normalize(line)
        guard !norm.isEmpty else { return false }
        if normalized.contains(" \(norm) ") { return true }
        let lineWords = norm.split(separator: " ")
        guard lineWords.count >= 4 else { return false }
        let known = lineWords.filter(words.contains).count
        guard Double(known) / Double(lineWords.count) >= 0.8 else { return false }
        let lineBigrams = EchoFilter.bigrams(of: norm)
        guard !lineBigrams.isEmpty else { return false }
        let shared = lineBigrams.intersection(bigrams).count
        return Double(shared) / Double(lineBigrams.count) >= 0.6
    }

    /// Case, accent and width folded; everything but letters and digits becomes a single space.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    private static func bigrams(of normalized: String) -> Set<String> {
        let words = normalized.split(separator: " ")
        guard words.count >= 2 else { return [] }
        var out = Set<String>()
        for i in 0..<(words.count - 1) {
            out.insert("\(words[i]) \(words[i + 1])")
        }
        return out
    }
}
