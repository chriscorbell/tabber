import Foundation

/// A suggestion on screen, anchored to the text it continues.
public struct Ghost: Equatable, Sendable {
    public var requestID: UInt64
    public var field: FieldIdentity
    /// The text before the caret that the suggestion continues.
    public var anchor: String
    /// The full suggestion.
    public var text: String
    /// How many characters of `text` are already in the field (typed through or accepted).
    public var consumed: Int
    /// Alternative first words offered by the engine.
    public var alternatives: [String]
    /// Characters before the caret this ghost replaces when accepted (emoji shortcodes). Zero for continuations.
    public var replacing: Int

    public init(requestID: UInt64, field: FieldIdentity, anchor: String, text: String, consumed: Int = 0, alternatives: [String] = [], replacing: Int = 0) {
        self.replacing = replacing
        self.requestID = requestID
        self.field = field
        self.anchor = anchor
        self.text = text
        self.consumed = consumed
        self.alternatives = alternatives
    }

    public var remainder: Substring { text.dropFirst(consumed) }
    public var isExhausted: Bool { consumed >= text.count }

    /// The text the field should contain before the caret when the ghost is shown as-is.
    public var expectedTextBeforeCaret: String { anchor + text.prefix(consumed) }
}

public enum AcceptKind: Sendable, Equatable {
    case word
    case all
}

/// Inputs to the session.
public enum SessionEvent: Sendable {
    /// A fresh read of the focused field. `nil` when nothing editable is focused.
    case snapshot(FieldSnapshot?)
    /// The user typed printable text (from the keyboard hook, before the app shows it).
    case typed(String)
    /// The user pressed a key that edits or moves the caret without typing (Backspace, arrows, Return...).
    case editingKey
    /// The accept shortcut was pressed while a ghost was visible.
    case accept(AcceptKind)
    /// Esc while a ghost was visible.
    case dismiss
    /// The engine finished a request.
    case completion(CompletionResult)
    /// The engine failed a request.
    case completionFailed(requestID: UInt64)
    /// Mouse click or app switch: anything that may move the caret elsewhere.
    case pointerOrFocusChange
}

/// Outputs of the session. The coordinator performs them in order.
public enum SessionEffect: Sendable, Equatable {
    case show(Ghost, FieldSnapshot)
    case hide
    case request(CompletionRequest)
    case cancelRequest
    /// Type this text at the caret.
    case insert(String)
    /// Delete this many characters before the caret, then type the text.
    case replace(deleting: Int, text: String)
}

/// Knobs the session reads on every event. Built from user settings for the focused app.
public struct SessionPolicy: Sendable, Equatable {
    public var enabled: Bool = true
    public var length: CompletionLength = .medium
    public var allowMidLine: Bool = false
    public var includeTrailingSpace: Bool = false
    public var includeTrailingPunctuation: Bool = true
    /// Minimum characters of text before the caret before suggesting.
    public var minimumContext: Int = 3
    /// Ignore single-line fields narrower than this (search boxes, form fields). Zero disables.
    public var minimumSingleLineWidth: CGFloat = 220
    /// Preamble for prompts in this field.
    public var preamble: String = ""
    public var confidenceFloor: Double? = nil
    public var wordBias: [String: Float] = [:]
    /// Suggest even when heuristics say no (force-activate shortcut).
    public var forced: Bool = false

    public init() {}
}

/// The pure state machine behind the ghost: when to ask for a suggestion, when to show it,
/// how typing through and accepting advance it, and when it goes away.
///
/// It never touches the system. Feed it events with `handle(_:now:)` and perform the returned effects.
public struct Session: Sendable {
    public private(set) var ghost: Ghost?
    public private(set) var lastSnapshot: FieldSnapshot?
    public private(set) var pending: CompletionRequest?
    public var policy = SessionPolicy()

    private var nextRequestID: UInt64 = 1
    /// When we last advanced the ghost ourselves, ahead of the app publishing the change.
    private var optimisticAt: Date?
    /// Text the user dismissed a suggestion for; no new suggestion until the text changes.
    private var dismissedAt: (field: FieldIdentity, text: String)?
    /// Set when a key changed the field and the app hasn't published the change yet. Results that
    /// arrive meanwhile are held and fitted to the next snapshot instead of the stale one.
    private var awaitingSnapshot = false
    private var heldResult: CompletionResult?
    /// Visible ghost text is held while the app catches up with our own insertions.
    private static let publishLag: TimeInterval = 0.6
    /// Characters of anchor used to recognise the ghost's text in a sliding window.
    private static let anchorTail = 160

    public init() {}

    /// The remainder Tab would accept right now, if any. The keyboard hook reads this to decide whether to swallow keys.
    public var acceptableRemainder: Substring? {
        guard let ghost, !ghost.isExhausted else { return nil }
        return ghost.remainder
    }

    public mutating func handle(_ event: SessionEvent, now: Date = Date()) -> [SessionEffect] {
        switch event {
        case .snapshot(let snapshot):
            return handleSnapshot(snapshot, now: now)
        case .typed(let typed):
            return handleTyped(typed, now: now)
        case .editingKey, .pointerOrFocusChange:
            // The text or caret changes in ways a pending result can't anticipate: drop it, the next snapshot asks again.
            var effects: [SessionEffect] = []
            if ghost != nil { effects.append(.hide) }
            if pending != nil { effects.append(.cancelRequest) }
            ghost = nil
            pending = nil
            heldResult = nil
            optimisticAt = nil
            awaitingSnapshot = true
            return effects
        case .accept(let kind):
            return handleAccept(kind, now: now)
        case .dismiss:
            guard let ghost else { return [] }
            dismissedAt = (ghost.field, ghost.expectedTextBeforeCaret)
            self.ghost = nil
            var effects: [SessionEffect] = [.hide]
            if pending != nil { pending = nil; effects.append(.cancelRequest) }
            return effects
        case .completion(let result):
            return handleCompletion(result, now: now)
        case .completionFailed(let id):
            if pending?.id == id { pending = nil }
            return []
        }
    }

    // MARK: - Snapshots

    private mutating func handleSnapshot(_ snapshot: FieldSnapshot?, now: Date) -> [SessionEffect] {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        awaitingSnapshot = false
        var effects: [SessionEffect] = []

        guard let snapshot else {
            if ghost != nil { effects.append(.hide) }
            if pending != nil { effects.append(.cancelRequest) }
            ghost = nil
            pending = nil
            return effects
        }

        // New field: start over.
        if let previous, previous.field != snapshot.field {
            if ghost != nil { effects.append(.hide) }
            ghost = nil
            optimisticAt = nil
            dismissedAt = nil
        }

        if var ghost, ghost.field == snapshot.field {
            switch Self.locate(ghost: ghost, in: snapshot.textBeforeCaret) {
            case .some(let k):
                // When the app hasn't caught up with what we already typed or inserted, keep the ghost where it is.
                let lagging = k < ghost.consumed && optimisticAt.map { now.timeIntervalSince($0) < Self.publishLag } == true
                if !lagging {
                    ghost.consumed = k
                    optimisticAt = nil
                }
                if ghost.isExhausted || !isEligible(snapshot) {
                    self.ghost = nil
                    effects.append(.hide)
                    if isEligible(snapshot) { effects += requestIfNeeded(for: snapshot) }
                } else {
                    self.ghost = ghost
                    effects.append(.show(ghost, snapshot))
                }
                return effects
            case .none:
                self.ghost = nil
                optimisticAt = nil
                effects.append(.hide)
            }
        }

        // We already asked for the text we just inserted, and the app hasn't published it yet: keep waiting.
        if let request = pending, request.text.count > snapshot.textBeforeCaret.count,
           request.text.hasPrefix(snapshot.textBeforeCaret),
           let optimisticAt, now.timeIntervalSince(optimisticAt) < Self.publishLag {
            awaitingSnapshot = true
            return effects
        }
        if let held = heldResult, let request = pending, held.requestID == request.id {
            let shown = apply(held, for: request)
            if !shown.isEmpty { return effects + shown }
        }
        heldResult = nil

        if isEligible(snapshot) {
            effects += requestIfNeeded(for: snapshot)
        } else if pending != nil {
            pending = nil
            effects.append(.cancelRequest)
        }
        return effects
    }

    /// Finds how much of the ghost the field's text already contains.
    /// Returns `k` such that the text before the caret ends with `anchor + ghost.text.prefix(k)`.
    static func locate(ghost: Ghost, in textBeforeCaret: String) -> Int? {
        let anchorTail = String(ghost.anchor.suffix(Self.anchorTail))
        let chars = Array(ghost.text)
        // Prefer the longest match: the user may have typed several characters at once.
        for k in stride(from: chars.count, through: 0, by: -1) {
            let candidate = anchorTail + String(chars[0..<k])
            if textBeforeCaret.hasSuffix(candidate) { return k }
        }
        return nil
    }

    private func isEligible(_ s: FieldSnapshot) -> Bool {
        guard policy.enabled, s.isEditable, !s.isSecure, s.selectionLength == 0, !s.hasMarkedText else { return false }
        if policy.forced { return !s.textBeforeCaret.isEmpty }
        if Self.isAddressOrSearchField(s) { return false }
        let trimmed = s.textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= policy.minimumContext else { return false }
        if !policy.allowMidLine, !s.caretAtEndOfLine { return false }
        if TextRules.caretInsideWord(before: s.textBeforeCaret, after: s.textAfterCaret) { return false }
        if s.isSingleLine, policy.minimumSingleLineWidth > 0, let frame = s.fieldFrame, frame.width < policy.minimumSingleLineWidth {
            return false
        }
        // Right after a line break in a new paragraph, wait for the first word.
        if let last = s.textBeforeCaret.last, last.isNewline { return false }
        // A bare list bullet ("- ", "* ", "1. ") gives the model nothing to go on.
        if Self.endsWithBareBullet(s.textBeforeCaret) { return false }
        if let d = dismissedAt, d.field == s.field, d.text == s.textBeforeCaret { return false }
        return true
    }

    /// Recipient, search, and address fields: Tab or Return there means something else and prose doesn't belong.
    static func isAddressOrSearchField(_ s: FieldSnapshot) -> Bool {
        if s.role == "AXSearchField" || s.subrole == "AXSearchField" { return true }
        if let id = s.identifier?.lowercased(),
           ["mail.tofield", "mail.ccfield", "mail.bccfield", "mail.replytofield", "mail.fromfield"].contains(id)
            || id.hasSuffix("recipient") || id.hasSuffix("recipients") || id == "search" || id.hasPrefix("search") {
            return true
        }
        guard s.isSingleLine else { return false }
        let names = [s.label, s.placeholder].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let exact: Set<String> = ["to", "to:", "cc", "cc:", "bcc", "bcc:", "from", "from:", "recipients", "add recipients",
                                  "url", "address", "address and search bar", "email", "e-mail", "username", "find"]
        return names.contains { n in
            exact.contains(n) || n.hasPrefix("search") || n.hasPrefix("to:") || n.hasPrefix("find ")
        }
    }

    static func endsWithBareBullet(_ text: String) -> Bool {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        if ["-", "*", "•", "–"].contains(t) { return true }
        if t.count <= 4, t.hasSuffix("."), t.dropLast().allSatisfy(\.isNumber), !t.dropLast().isEmpty { return true }
        return false
    }

    private mutating func requestIfNeeded(for snapshot: FieldSnapshot) -> [SessionEffect] {
        if let pending, pending.text == snapshot.textBeforeCaret { return [] }
        let request = makeRequest(text: snapshot.textBeforeCaret, after: String(snapshot.restOfLine), snapshot: snapshot)
        var effects: [SessionEffect] = []
        if pending != nil { effects.append(.cancelRequest) }
        pending = request
        effects.append(.request(request))
        return effects
    }

    private mutating func makeRequest(text: String, after: String, snapshot: FieldSnapshot) -> CompletionRequest {
        defer { nextRequestID += 1 }
        var range = policy.length.wordRange
        // Mid-line suggestions must fit in front of existing text: keep them short.
        if !after.trimmingCharacters(in: .whitespaces).isEmpty { range = min(range.lowerBound, 2)...min(range.upperBound, 2) }
        return CompletionRequest(
            id: nextRequestID,
            preamble: policy.preamble,
            text: text,
            textAfter: after,
            maxWords: range.upperBound,
            minWords: range.lowerBound,
            singleLine: true,
            confidenceFloor: policy.confidenceFloor,
            wordBias: policy.wordBias
        )
    }

    // MARK: - Typing through

    private mutating func handleTyped(_ typed: String, now: Date) -> [SessionEffect] {
        dismissedAt = nil
        guard !typed.isEmpty else { return [] }
        awaitingSnapshot = true
        guard var ghost else { return [] }
        if ghost.replacing == 0, ghost.remainder.hasPrefix(typed) {
            ghost.consumed += typed.count
            optimisticAt = now
            if ghost.isExhausted {
                self.ghost = nil
                return [.hide]
            }
            self.ghost = ghost
            if let snapshot = lastSnapshot { return [.show(ghost, snapshot)] }
            return []
        }
        // Typed something else: the suggestion is wrong now. Hide right away rather than waiting for the app.
        self.ghost = nil
        optimisticAt = nil
        var effects: [SessionEffect] = [.hide]
        if pending != nil { pending = nil; heldResult = nil; effects.append(.cancelRequest) }
        return effects
    }

    // MARK: - Accepting

    private mutating func handleAccept(_ kind: AcceptKind, now: Date) -> [SessionEffect] {
        guard var ghost, !ghost.isExhausted else { return [] }
        if ghost.replacing > 0 {
            self.ghost = nil
            optimisticAt = now
            awaitingSnapshot = true
            return [.replace(deleting: ghost.replacing, text: ghost.text), .hide]
        }
        let remainder = ghost.remainder
        let chunk: Substring
        switch kind {
        case .all:
            chunk = remainder
        case .word:
            chunk = TextRules.nextChunk(
                of: remainder,
                includeTrailingPunctuation: policy.includeTrailingPunctuation,
                includeTrailingSpace: policy.includeTrailingSpace
            )
        }
        guard !chunk.isEmpty else { return [] }
        ghost.consumed += chunk.count
        optimisticAt = now
        awaitingSnapshot = true
        var effects: [SessionEffect] = [.insert(String(chunk))]

        if ghost.isExhausted {
            self.ghost = nil
            effects.append(.hide)
            // Ask for the next suggestion right away, against the text we know the field will hold.
            if var snapshot = lastSnapshot {
                snapshot.textBeforeCaret = ghost.expectedTextBeforeCaret
                if isEligible(snapshot) {
                    let request = makeRequest(text: snapshot.textBeforeCaret, after: String(snapshot.restOfLine), snapshot: snapshot)
                    if pending != nil { effects.append(.cancelRequest) }
                    pending = request
                    effects.append(.request(request))
                }
            }
        } else {
            self.ghost = ghost
            if let snapshot = lastSnapshot { effects.append(.show(ghost, snapshot)) }
        }
        return effects
    }

    // MARK: - Results

    private mutating func handleCompletion(_ result: CompletionResult, now: Date) -> [SessionEffect] {
        guard let request = pending, request.id == result.requestID else { return [] }
        if awaitingSnapshot {
            heldResult = result
            return []
        }
        return apply(result, for: request)
    }

    /// Shows a result if it still fits the latest snapshot, possibly after text typed meanwhile.
    private mutating func apply(_ result: CompletionResult, for request: CompletionRequest) -> [SessionEffect] {
        pending = nil
        heldResult = nil
        guard let snapshot = lastSnapshot else { return [] }
        let text = result.text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var ghost = Ghost(
            requestID: result.requestID,
            field: snapshot.field,
            anchor: request.text,
            text: text,
            alternatives: result.alternatives,
            replacing: result.replacing
        )
        if ghost.replacing > 0, snapshot.textBeforeCaret != request.text { return [] }
        // The user may have kept typing while the model worked. Fit the result to the current text.
        if snapshot.textBeforeCaret != request.text {
            guard let k = Self.locate(ghost: ghost, in: snapshot.textBeforeCaret), k < text.count else {
                return []
            }
            ghost.consumed = k
        }
        guard isEligible(snapshot) || policy.forced else { return [] }
        self.ghost = ghost
        return [.show(ghost, snapshot)]
    }
}
