import AppKit
import ApplicationServices
import TabberCore

/// The result of one read of the focused field.
public enum FieldReadOutcome: Sendable {
    case field(FieldSnapshot)
    /// Nothing editable is focused, or the focused app is excluded.
    case noField
    /// The app didn't answer (timeout, busy, mid-teardown). The previous state is still the best guess.
    case failed
}

/// Reads the focused text field into a `FieldSnapshot`.
///
/// Not thread-safe: create and use it on one thread. `FocusTracker` runs it on its own AX thread; never use it
/// on the main thread, because every read is synchronous IPC with another app.
public final class FieldReader {
    public var configuration: FocusTracker.Configuration
    /// The frontmost app, asked for its focused element when the system-wide query fails.
    public var frontmostPID: pid_t?

    /// Diagnostics: read text and caret through text markers even when the app offers UTF-16 ranges.
    public var forceTextMarkers = false

    /// AX calls made by the most recent `read()`.
    public var lastCallCount: Int { lastCount }

    /// The element the most recent `.field` outcome was read from.
    private(set) var lastElement: AXUIElement?

    let client = AXClient()
    private let systemWide = AXUIElementCreateSystemWide()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let ownBundleID = "app.tabber.Tabber"

    private var lastCount = 0
    private var apps: [pid_t: AppIdentity] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var infos: [ElementKey: ElementInfo] = [:]
    private var containerTargets: [ElementKey: (target: AXUIElement?, at: TimeInterval)] = [:]
    private var windowTitles: [ElementKey: (title: String?, at: TimeInterval)] = [:]
    private var urls: [ElementKey: (url: URL?, at: TimeInterval)] = [:]
    private var styleCache: (key: StyleKey, style: TextStyle?, at: TimeInterval)?
    private var noBatchPIDs: Set<pid_t> = []
    private var webKinds: [pid_t: WebAccessibilityEnabler.Kind] = [:]
    /// Chromium fields whose selection offsets were checked against their value: true once they disagreed (then
    /// for good). A "consistent" verdict expires, since a field can gain block breaks later.
    private var needsRealign: [ElementKey: (needed: Bool, at: TimeInterval)] = [:]

    public init(configuration: FocusTracker.Configuration = .init()) {
        self.configuration = configuration
        AXUIElementSetMessagingTimeout(systemWide, FocusTracker.messagingTimeout)
    }

    // MARK: - Reading

    /// Reads the focused field.
    public func read() -> FieldReadOutcome {
        client.resetCount()
        defer { lastCount = client.callCount }
        lastElement = nil

        let (focused, failed) = focusedElement()
        guard let focused else { return failed ? .failed : .noField }
        return readResolving(focused)
    }

    /// Reads `element` as if it were focused (for probes and checks of a known field).
    public func read(element: AXUIElement) -> FieldReadOutcome {
        client.resetCount()
        defer { lastCount = client.callCount }
        lastElement = nil
        return readResolving(element)
    }

    private func readResolving(_ focused: AXUIElement) -> FieldReadOutcome {
        guard let pid = focused.pid else { return .noField }
        let app = appIdentity(pid)
        if isExcluded(app) { return .noField }

        guard let info = info(for: focused) else { return .failed }
        let target: AXUIElement
        let targetInfo: ElementInfo
        switch info.kind {
        case .text, .generic:
            target = focused
            targetInfo = info
        case .container:
            guard let found = editableTarget(inContainer: focused), let foundInfo = self.info(for: found) else {
                return .noField
            }
            target = found
            targetInfo = foundInfo
        case .ignored:
            return .noField
        }

        guard let snapshot = readField(target, info: targetInfo, app: app) else { return .failed }
        lastElement = target
        return .field(snapshot)
    }

    /// Drops everything cached about a process (call when it quits).
    public func forget(pid: pid_t) {
        apps[pid] = nil
        appElements[pid] = nil
        webKinds[pid] = nil
        noBatchPIDs.remove(pid)
    }

    func appElement(_ pid: pid_t) -> AXUIElement {
        if let element = appElements[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, FocusTracker.messagingTimeout)
        appElements[pid] = element
        return element
    }

    private func focusedElement() -> (AXUIElement?, failed: Bool) {
        let (value, error) = client.copyResult(systemWide, AXName.focusedUIElement)
        if let element = AXCast.element(value) { return (element, false) }
        guard let pid = frontmostPID else { return (nil, error == .cannotComplete) }
        let (appValue, appError) = client.copyResult(appElement(pid), AXName.focusedUIElement)
        if let element = AXCast.element(appValue) { return (element, false) }
        return (nil, error == .cannotComplete || appError == .cannotComplete)
    }

    private func appIdentity(_ pid: pid_t) -> AppIdentity {
        if let app = apps[pid] { return app }
        let running = NSRunningApplication(processIdentifier: pid)
        webKinds[pid] = WebAccessibilityEnabler.classify(bundleID: running?.bundleIdentifier, bundlePath: running?.bundleURL?.path) {
            FileManager.default.fileExists(atPath: $0)
        }
        let app = AppIdentity(
            bundleID: running?.bundleIdentifier ?? "",
            name: running?.localizedName ?? "",
            pid: pid
        )
        apps[pid] = app
        return app
    }

    private func isExcluded(_ app: AppIdentity) -> Bool {
        if configuration.includeOwnProcess, app.pid == ownPID { return false }
        return app.pid == ownPID || app.bundleID == Self.ownBundleID || configuration.excludedBundleIDs.contains(app.bundleID)
    }

    // MARK: - Element classification

    private enum Kind {
        /// A standard text role.
        case text
        /// Some other role whose value is editable text (web contenteditable, Mail's compose web area).
        case generic
        /// A container that may hold the real field (web areas, groups, scroll areas).
        case container
        case ignored
    }

    /// Things about an element that don't change while it lives.
    private struct ElementInfo {
        var role: String
        var subrole: String?
        var isSecure: Bool
        var kind: Kind
        var isEditable: Bool
        var multiLine: Bool?
        var placeholder: String?
        var label: String?
        var identifier: String?
        /// Web content (WebKit or Chromium DOM), whose geometry quirks differ from TextKit's.
        var isWeb: Bool
    }

    private static let textRoles: Set<String> = [AXName.textField, AXName.textArea, AXName.comboBox, AXName.searchField]
    private static let containerRoles: Set<String> = [AXName.webArea, AXName.group, AXName.scrollArea, "AXSplitGroup", "AXLayoutArea"]
    private static let ignoredRoles: Set<String> = [
        "AXStaticText", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXSlider", "AXImage", "AXLink", "AXRow", "AXCell", "AXTable",
        "AXOutline", "AXList", "AXTabGroup", "AXToolbar", "AXWindow", "AXApplication", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXScrollBar", "AXValueIndicator", "AXHeading", "AXSheet", "AXDrawer",
        "AXSplitter", "AXProgressIndicator", "AXBusyIndicator", "AXLevelIndicator", "AXRuler", "AXBrowser",
    ]
    private static let staticAttributes = [
        AXName.role, AXName.subrole, AXName.roleDescription, AXName.placeholder, AXName.title,
        AXName.description, AXName.titleUIElement, AXName.multiLine, AXName.editable, AXName.editableAncestor,
        "AXIdentifier", "AXDOMIdentifier",
    ]

    /// WebKit and Chromium list DOM attributes on every web element (Safari returns nil for the editable ancestor
    /// of a field's own root, so the attribute's presence is the signal, not its value).
    private static func isDOMElement(_ names: [String]) -> Bool {
        names.contains { $0 == "AXDOMIdentifier" || $0 == "AXDOMClassList" || $0 == AXName.editableAncestor }
    }

    private func info(for element: AXUIElement) -> ElementInfo? {
        let key = ElementKey(element: element)
        if let cached = infos[key] { return cached }

        let values = copy(element, Self.staticAttributes)
        guard let role = AXCast.string(values[AXName.role]) else { return nil }
        let subrole = AXCast.string(values[AXName.subrole])
        let roleDescription = AXCast.string(values[AXName.roleDescription])?.lowercased() ?? ""
        let isSecure = role == AXName.secureTextField || subrole == AXName.secureTextField
            || roleDescription.contains("secure") || roleDescription.contains("password")

        var kind: Kind
        var isEditable = true
        let editableAncestor = AXCast.element(values[AXName.editableAncestor])
        if Self.textRoles.contains(role) || subrole == AXName.searchField || role == AXName.secureTextField {
            kind = .text
            // Read-only text views (Terminal, logs) keep their text role but refuse value writes.
            isEditable = client.isSettable(element, AXName.value) ?? true
        } else if AXCast.bool(values[AXName.editable]) == true {
            kind = .generic
        } else if let editableAncestor {
            // Web content inside an editable region: the region's root is the field.
            kind = CFEqual(editableAncestor, element) ? .generic : .container
        } else if Self.ignoredRoles.contains(role) {
            kind = .ignored
        } else if role == AXName.webArea, client.isSettable(element, AXName.value) == true,
                  AXCast.string(client.copy(element, AXName.value)) != nil {
            // An editable document, like Mail's compose body. Only web areas qualify: Chromium reports a settable
            // empty value on every plain group of its own UI.
            kind = .generic
        } else {
            kind = Self.containerRoles.contains(role) ? .container : .ignored
        }
        if isSecure, kind == .ignored { kind = .text }

        var label = AXCast.nonEmptyString(values[AXName.title]) ?? AXCast.nonEmptyString(values[AXName.description])
        if label == nil, kind != .ignored, kind != .container, let titleElement = AXCast.element(values[AXName.titleUIElement]) {
            let titleValues = copy(titleElement, [AXName.value, AXName.title])
            label = AXCast.nonEmptyString(titleValues[AXName.value]) ?? AXCast.nonEmptyString(titleValues[AXName.title])
        }

        let info = ElementInfo(
            role: role,
            subrole: subrole,
            isSecure: isSecure,
            kind: kind,
            isEditable: isEditable,
            multiLine: AXCast.bool(values[AXName.multiLine]),
            placeholder: AXCast.nonEmptyString(values[AXName.placeholder]),
            label: label,
            identifier: AXCast.nonEmptyString(values["AXIdentifier"]) ?? AXCast.nonEmptyString(values["AXDOMIdentifier"]),
            isWeb: editableAncestor != nil || (kind != .ignored && Self.isDOMElement(client.attributeNames(element)))
        )
        if infos.count > 128 { infos.removeAll(keepingCapacity: true) }
        infos[key] = info
        return info
    }

    /// The editable field inside a focused container: the container's editable ancestor (web), its own focused
    /// element, or a bounded search for a child holding a caret. Cached briefly, since the search is costly.
    private func editableTarget(inContainer container: AXUIElement) -> AXUIElement? {
        let key = ElementKey(element: container)
        let now = Self.now
        if let cached = containerTargets[key], now - cached.at < 2 { return cached.target }

        var target: AXUIElement?
        let values = copy(container, [AXName.editableAncestor, AXName.focusedUIElement])
        for attribute in [AXName.editableAncestor, AXName.focusedUIElement] {
            guard let candidate = AXCast.element(values[attribute]), !CFEqual(candidate, container),
                  let kind = info(for: candidate)?.kind, kind == .text || kind == .generic else { continue }
            target = candidate
            break
        }
        if target == nil { target = searchForCaret(in: container) }

        if containerTargets.count > 32 { containerTargets.removeAll(keepingCapacity: true) }
        containerTargets[key] = (target, now)
        return target
    }

    /// Breadth-first search, at most 4 levels and 40 elements, for a focused text element with a collapsed selection.
    /// Only for native containers (a scroll view reporting focus for its text view): browsers report a focused
    /// web field directly, and searching a page would cost dozens of calls for nothing.
    private func searchForCaret(in root: AXUIElement) -> AXUIElement? {
        guard AXCast.string(client.copy(root, AXName.role)) != AXName.webArea else { return nil }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let values = copy(element, [AXName.role, AXName.selectedTextRange, AXName.focused, AXName.children])
            if depth > 0, let role = AXCast.string(values[AXName.role]), Self.textRoles.contains(role),
               let range = AXCast.range(values[AXName.selectedTextRange]), range.length == 0,
               AXCast.bool(values[AXName.focused]) == true {
                return element
            }
            if depth < 4 {
                queue.append(contentsOf: AXCast.elements(values[AXName.children]).prefix(20).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: - Field contents

    private struct TextRead {
        /// Exactly as the app reported it; cleaned only when building the snapshot.
        var before: String
        var after: String
        var beforeIsTruncated: Bool
        var caretOffset: Int?
        var selectionLength: Int
        var markers: MarkerSelection?
    }

    private struct MarkerSelection {
        var range: AXTextMarkerRange
        var start: AXTextMarker
        var end: AXTextMarker
    }

    private static let dynamicAttributes = [
        AXName.selectedTextRange, AXName.numberOfCharacters, AXName.position, AXName.size,
        AXName.markedRange, AXName.markedRangeAlt, AXName.window,
    ]

    private func readField(_ element: AXUIElement, info: ElementInfo, app: AppIdentity) -> FieldSnapshot? {
        let values = copy(element, Self.dynamicAttributes)
        var frame: CGRect?
        if let origin = AXCast.point(values[AXName.position]), let size = AXCast.size(values[AXName.size]) {
            let rect = CGRect(origin: origin, size: size)
            if CaretMath.isUsableFrame(rect) { frame = rect }
        }
        let windowTitle = title(ofWindow: AXCast.element(values[AXName.window]))
        let url = pageURL(for: element)
        let identity = FieldIdentity(pid: app.pid, elementHash: CFHash(element), role: info.role)

        if info.isSecure {
            // Never read anything that could be the secret, not even its length.
            return FieldSnapshot(
                app: app, field: identity, role: info.role, subrole: info.subrole, windowTitle: windowTitle, url: url,
                placeholder: info.placeholder, label: info.label, identifier: info.identifier, textBeforeCaret: "", textAfterCaret: "",
                isSecure: true, isEditable: info.isEditable, isSingleLine: true, fieldFrame: frame
            )
        }

        var text: TextRead?
        var hasMarkedText = false
        if !forceTextMarkers, let selection = AXCast.range(values[AXName.selectedTextRange]) {
            text = readText(element, selection: selection, count: AXCast.int(values[AXName.numberOfCharacters]))
            if let read = text, info.isWeb, (webKinds[app.pid] ?? .other) != .other {
                text = realignChromiumCaret(element, read, count: AXCast.int(values[AXName.numberOfCharacters]))
            }
            let marked = AXCast.range(values[AXName.markedRange]) ?? AXCast.range(values[AXName.markedRangeAlt])
            hasMarkedText = (marked?.length ?? 0) > 0
        }
        if text == nil, let markerText = readTextWithMarkers(element) {
            text = markerText
            hasMarkedText = markedTextWithMarkers(element)
        }
        if text == nil, let value = AXCast.string(client.copy(element, AXName.value)) {
            // No caret information at all: the best we can say is what the field holds, caret unknown.
            let tail = TextWindow.suffix(value, limit: configuration.textWindowBefore)
            text = TextRead(before: tail.text, after: "", beforeIsTruncated: tail.truncated, caretOffset: nil, selectionLength: 0)
        }
        guard let text else { return nil }

        let fixedSingleLine = Self.singleLineByRole(info)
        var caret = caretGeometry(element, text: text, frame: frame, isSingleLine: fixedSingleLine ?? false, isWeb: info.isWeb)
        let style = textStyle(element, text: text, caret: caret)
        // An estimate sized to the field's font is a better guess than the default line height.
        if caret?.quality == .estimated, let frame, let size = style?.fontSize {
            caret = CaretGeometry(
                rect: CaretMath.estimatedCaret(field: frame, isSingleLine: fixedSingleLine ?? false, lineHeight: size * 1.25),
                quality: .estimated
            )
        }

        let isSingleLine: Bool
        if let fixedSingleLine {
            isSingleLine = fixedSingleLine
        } else if let caret, caret.quality > .estimated, let frame {
            isSingleLine = CaretMath.looksSingleLine(fieldHeight: frame.height, caretHeight: caret.rect.height)
        } else {
            isSingleLine = false
        }

        return FieldSnapshot(
            app: app,
            field: identity,
            role: info.role,
            subrole: info.subrole,
            windowTitle: windowTitle,
            url: url,
            placeholder: info.placeholder,
            label: info.label,
            identifier: info.identifier,
            textBeforeCaret: TextWindow.clean(text.before),
            textAfterCaret: TextWindow.clean(text.after),
            beforeIsTruncated: text.beforeIsTruncated,
            selectionLength: text.selectionLength,
            caretOffset: text.caretOffset,
            isSecure: false,
            isEditable: info.isEditable,
            isSingleLine: isSingleLine,
            hasMarkedText: hasMarkedText,
            fieldFrame: frame,
            caret: caret,
            style: style
        )
    }

    private static func singleLineByRole(_ info: ElementInfo) -> Bool? {
        if info.role == AXName.textField || info.role == AXName.comboBox || info.role == AXName.searchField
            || info.subrole == AXName.searchField {
            return true
        }
        if info.role == AXName.textArea { return false }
        return info.multiLine.map { !$0 }
    }

    /// Text around a known UTF-16 selection. Prefers one bounded `AXStringForRange` read when the app reports
    /// its length; falls back to reading the whole value.
    private func readText(_ element: AXUIElement, selection: CFRange, count: Int?) -> TextRead? {
        let before = configuration.textWindowBefore
        let after = configuration.textWindowAfter
        if let count, count >= 0 {
            let span = TextWindow.span(selection: selection, totalLength: count, before: before, after: after)
            func result(_ b: String, _ a: String) -> TextRead {
                TextRead(
                    before: b, after: a, beforeIsTruncated: span.beforeIsTruncated, caretOffset: span.selectionStart,
                    selectionLength: span.selectionEnd - span.selectionStart
                )
            }
            if span.length == 0 { return result("", "") }
            if let fetched = AXCast.string(client.parameterized(element, AXName.stringForRange, range: span.range)),
               let parts = TextWindow.split(fetched: fetched, span: span) {
                return result(parts.before, parts.after)
            }
            // The combined read came back a different length than asked: read each side on its own.
            let b = span.beforeRange.length > 0
                ? AXCast.string(client.parameterized(element, AXName.stringForRange, range: span.beforeRange)) : ""
            let a = span.afterRange.length > 0
                ? AXCast.string(client.parameterized(element, AXName.stringForRange, range: span.afterRange)) : ""
            if let b, let a { return result(b, a) }
        }
        guard let value = AXCast.string(client.copy(element, AXName.value)) else { return nil }
        let parts = TextWindow.split(fullText: value, selection: selection, before: before, after: after)
        return TextRead(
            before: parts.before, after: parts.after, beforeIsTruncated: parts.span.beforeIsTruncated,
            caretOffset: parts.span.selectionStart, selectionLength: parts.span.selectionEnd - parts.span.selectionStart
        )
    }

    /// Chromium's rich-text editors report selection offsets that skip the newlines between blocks, while their
    /// value and `AXStringForRange` include them, so past the first paragraph the caret lands too early. Text
    /// markers share the selection's coordinates: align the marker text before the caret with the value to find
    /// the real offset. Fields that turn out consistent (plain textareas) are remembered and skipped.
    private func realignChromiumCaret(_ element: AXUIElement, _ text: TextRead, count: Int?) -> TextRead {
        let key = ElementKey(element: element)
        if let verdict = needsRealign[key], !verdict.needed, Self.now - verdict.at < 5 { return text }
        guard let caret = text.caretOffset else { return text }
        // Without a newline before the caret (or right after it) there is nothing to be off by.
        let newlineNearCaret = text.before.unicodeScalars.contains(where: TextWindow.isNewline)
            || text.after.unicodeScalars.first.map(TextWindow.isNewline) == true
        guard newlineNearCaret, let count, count <= 20_000,
              let markers = selectionMarkers(element),
              let fieldRange = AXCast.textMarkerRange(client.parameterized(element, AXName.textMarkerRangeForElement, element)),
              let markerBefore = string(element, from: AXTextMarkerRangeCopyStartMarker(fieldRange), to: markers.start),
              let value = AXCast.string(client.copy(element, AXName.value)) else { return text }

        let units = Array(value.utf16)
        guard var index = TextWindow.alignCaret(value: units, markerTextBefore: Array(markerBefore.utf16)) else { return text }
        if index < units.count, TextWindow.isNewlineUnit(units[index]), caretStartsLine(element, markers) == true {
            index = TextWindow.skipNewlines(units, from: index)
        }
        if index == caret {
            // Newlines before the caret that both sides count: this field's offsets look consistent. A field that
            // has needed realigning keeps being checked: right after a keystroke Chromium's value and markers can
            // briefly agree by accident.
            if needsRealign[key]?.needed != true, text.before.unicodeScalars.contains(where: TextWindow.isNewline) {
                needsRealign[key] = (false, Self.now)
            }
            return text
        }
        if needsRealign.count > 64 { needsRealign.removeAll(keepingCapacity: true) }
        needsRealign[key] = (true, Self.now)
        let parts = TextWindow.split(
            fullText: value, selection: CFRange(location: index, length: text.selectionLength),
            before: configuration.textWindowBefore, after: configuration.textWindowAfter
        )
        return TextRead(
            before: parts.before, after: parts.after, beforeIsTruncated: parts.span.beforeIsTruncated,
            caretOffset: parts.span.selectionStart, selectionLength: parts.span.selectionEnd - parts.span.selectionStart
        )
    }

    /// Whether the caret is past a block break, by the markers' screen geometry: on the same line as the next
    /// character, or (failing that) on a lower line than the previous one. Rects that aren't character-sized (Chrome
    /// answers some boundary queries with the whole element) don't count.
    private func caretStartsLine(_ element: AXUIElement, _ markers: MarkerSelection) -> Bool? {
        guard let caret = AXCast.rect(client.parameterized(element, AXName.boundsForMarkerRange, markers.range)),
              caret.height >= 1, caret.height < CaretMath.maxCaretHeight else { return nil }
        func characterRect(_ r: CGRect?) -> CGRect? {
            guard let r, r.height >= 1, r.height < CaretMath.maxCaretHeight, r.width > 0, CaretMath.isCharacterSized(r) else { return nil }
            return r
        }
        if let next = AXCast.textMarker(client.parameterized(element, AXName.nextMarker, markers.end)),
           let r = characterRect(markerBounds(element, from: markers.end, to: next)) {
            return abs(r.minY - caret.minY) < max(2, caret.height / 2)
        }
        if let previous = AXCast.textMarker(client.parameterized(element, AXName.previousMarker, markers.start)),
           let r = characterRect(markerBounds(element, from: previous, to: markers.start)) {
            return caret.minY >= r.maxY - 1
        }
        return nil
    }

    /// WebKit and Chromium rich-text editors that expose a selection only as text markers.
    private func readTextWithMarkers(_ element: AXUIElement) -> TextRead? {
        guard let markers = selectionMarkers(element) else { return nil }
        let selection = markers.range

        var fieldStart: AXTextMarker?
        var fieldEnd: AXTextMarker?
        if let fieldRange = AXCast.textMarkerRange(client.parameterized(element, AXName.textMarkerRangeForElement, element)) {
            fieldStart = AXTextMarkerRangeCopyStartMarker(fieldRange)
            fieldEnd = AXTextMarkerRangeCopyEndMarker(fieldRange)
        } else {
            let values = copy(element, [AXName.startTextMarker, AXName.endTextMarker])
            fieldStart = AXCast.textMarker(values[AXName.startTextMarker])
            fieldEnd = AXCast.textMarker(values[AXName.endTextMarker])
        }
        guard fieldStart != nil || fieldEnd != nil else { return nil }

        let before = fieldStart.flatMap { string(element, from: $0, to: markers.start) } ?? ""
        let after = fieldEnd.flatMap { string(element, from: markers.end, to: $0) } ?? ""
        let selectionLength = AXCast.int(client.parameterized(element, AXName.lengthForMarkerRange, selection)) ?? 0
        let tail = TextWindow.suffix(before, limit: configuration.textWindowBefore)
        return TextRead(
            before: tail.text,
            after: TextWindow.prefix(after, limit: configuration.textWindowAfter),
            beforeIsTruncated: tail.truncated,
            caretOffset: before.utf16.count,
            selectionLength: max(0, selectionLength),
            markers: markers
        )
    }

    private func markedTextWithMarkers(_ element: AXUIElement) -> Bool {
        guard let marked = AXCast.textMarkerRange(client.copy(element, AXName.markedTextMarkerRange)) else { return false }
        return (AXCast.int(client.parameterized(element, AXName.lengthForMarkerRange, marked)) ?? 1) > 0
    }

    private func markerRange(_ element: AXUIElement, from start: AXTextMarker, to end: AXTextMarker) -> AXTextMarkerRange {
        AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
    }

    private func string(_ element: AXUIElement, from start: AXTextMarker, to end: AXTextMarker) -> String? {
        if let s = AXCast.string(client.parameterized(element, AXName.stringForMarkerRange, markerRange(element, from: start, to: end))) {
            return s
        }
        // Some builds only accept ranges they made themselves.
        let ordered = client.parameterized(element, AXName.rangeForUnorderedMarkers, [start, end] as CFArray)
        guard let range = AXCast.textMarkerRange(ordered) else { return nil }
        return AXCast.string(client.parameterized(element, AXName.stringForMarkerRange, range))
    }

    // MARK: - Caret geometry

    private func caretGeometry(
        _ element: AXUIElement, text: TextRead, frame: CGRect?, isSingleLine: Bool, isWeb: Bool
    ) -> CaretGeometry? {
        let screenHeight = DisplayInfo.primaryHeight
        let scale = frame.flatMap { DisplayInfo.scale(at: CGPoint(x: $0.midX, y: $0.midY)) }
        func accept(_ rect: CGRect?, _ quality: CaretQuality) -> CaretGeometry? {
            guard let rect else { return nil }
            if CaretMath.isPlausible(rect, field: frame) { return CaretGeometry(rect: rect, quality: quality) }
            if let fixed = CaretMath.repaired(rect, field: frame, primaryScreenHeight: screenHeight, scale: scale) {
                return CaretGeometry(rect: fixed, quality: min(quality, .derived))
            }
            return nil
        }

        let previousLength = TextWindow.lastCharacterLength(text.before)
        let previousIsNewline = TextWindow.endsWithNewline(text.before)
        let rightToLeft = CaretMath.textBeforeIsRightToLeft(text.before)

        let atLineStart = (text.caretOffset == 0 && text.before.isEmpty) || previousIsNewline
        let next = text.after.unicodeScalars.first
        let nextLength = TextWindow.firstCharacterLength(text.after)
        let nextIsNewline = next.map(TextWindow.isNewline) ?? false
        let nextRightToLeft = next.map { !TextWindow.isNewline($0) && CaretMath.isRightToLeft($0) } ?? false
        // On an empty line the next character is a newline. Only TextKit puts that on the caret's own line (as a
        // wide rect); WebKit and Chromium place it on the following line. So an empty line asks the collapsed range
        // first and uses the newline's leading edge only as a fallback. Web engines map every offset of an empty
        // paragraph onto the next one, so at a line start they are asked for their own caret rect first.
        func nextCharacterUsable(_ r: CGRect) -> Bool {
            nextIsNewline ? r.width > 0.5 : CaretMath.isCharacterSized(r)
        }

        if text.markers == nil, let caret = text.caretOffset {
            // a) Trailing edge of the previous character: the most dependable rect in nearly every app. Not after a
            //    newline, which TextKit places at the end of the line above the caret.
            if !atLineStart, previousLength > 0, caret >= previousLength,
               let r = bounds(element, CFRange(location: caret - previousLength, length: previousLength)),
               CaretMath.isCharacterSized(r),
               let g = accept(CaretMath.caret(after: r, rightToLeft: rightToLeft), .exact) {
                return g
            }
            // c) At the start of a line with text, the leading edge of its first character.
            func nextCharacter() -> CaretGeometry? {
                guard atLineStart, nextLength > 0,
                      let r = bounds(element, CFRange(location: caret, length: nextLength)), nextCharacterUsable(r) else { return nil }
                return accept(CaretMath.caret(before: r, rightToLeft: nextRightToLeft), .derived)
            }
            if isWeb, atLineStart, let markers = selectionMarkers(element),
               let r = AXCast.rect(client.parameterized(element, AXName.boundsForMarkerRange, markers.range)), r.height > 0,
               let g = accept(CaretMath.caret(collapsed: r), .exact) {
                return g
            }
            if !nextIsNewline, let g = nextCharacter() { return g }
            // b) The collapsed range at the caret. TextKit reports these a line too high, so check native text
            //    against what must hold: the caret is below a newline before it, and not above the field.
            if let r = bounds(element, CFRange(location: caret, length: 0)), r.height > 0 {
                if isWeb {
                    if let g = accept(CaretMath.caret(collapsed: r), .exact) { return g }
                } else {
                    var newline: CGRect?
                    if previousIsNewline, caret >= previousLength {
                        newline = bounds(element, CFRange(location: caret - previousLength, length: previousLength))
                    }
                    let fix = CaretMath.correctedCollapsed(r, field: frame, previousNewline: newline)
                    if let g = accept(fix.rect, fix.corrected ? .derived : .exact) { return g }
                }
            }
            if nextIsNewline, let g = nextCharacter() { return g }
        }

        // d) Text markers: the previous character, the next one at the start of a line with text, the selection
        //    itself, then an empty line's newline.
        if let markers = text.markers ?? selectionMarkers(element) {
            if !atLineStart, previousLength > 0,
               let previous = AXCast.textMarker(client.parameterized(element, AXName.previousMarker, markers.start)),
               let r = markerBounds(element, from: previous, to: markers.start), r.width > 0, CaretMath.isCharacterSized(r),
               let g = accept(CaretMath.caret(after: r, rightToLeft: rightToLeft), .exact) {
                return g
            }
            func nextCharacter() -> CaretGeometry? {
                guard atLineStart, nextLength > 0,
                      let following = AXCast.textMarker(client.parameterized(element, AXName.nextMarker, markers.end)),
                      let r = markerBounds(element, from: markers.end, to: following), nextCharacterUsable(r) else { return nil }
                return accept(CaretMath.caret(before: r, rightToLeft: nextRightToLeft), .derived)
            }
            if !nextIsNewline, let g = nextCharacter() { return g }
            if let r = AXCast.rect(client.parameterized(element, AXName.boundsForMarkerRange, markers.range)), r.height > 0,
               let g = accept(CaretMath.caret(collapsed: r), .exact) {
                return g
            }
            if nextIsNewline, let g = nextCharacter() { return g }
        }

        // e) A guess from the frame.
        guard let frame else { return nil }
        return CaretGeometry(
            rect: CaretMath.estimatedCaret(field: frame, isSingleLine: isSingleLine, lineHeight: nil),
            quality: .estimated
        )
    }

    private func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        AXCast.rect(client.parameterized(element, AXName.boundsForRange, range: range))
    }

    private func markerBounds(_ element: AXUIElement, from start: AXTextMarker, to end: AXTextMarker) -> CGRect? {
        AXCast.rect(client.parameterized(element, AXName.boundsForMarkerRange, markerRange(element, from: start, to: end)))
    }

    /// The selection as text markers. The attribute is document-wide, so it only describes this field while the
    /// field has focus.
    private func selectionMarkers(_ element: AXUIElement) -> MarkerSelection? {
        let values = copy(element, [AXName.selectedTextMarkerRange, AXName.focused])
        guard AXCast.bool(values[AXName.focused]) != false,
              let range = AXCast.textMarkerRange(values[AXName.selectedTextMarkerRange]) else { return nil }
        return MarkerSelection(
            range: range, start: AXTextMarkerRangeCopyStartMarker(range), end: AXTextMarkerRangeCopyEndMarker(range)
        )
    }

    // MARK: - Style

    private struct StyleKey: Equatable {
        var element: ElementKey
        var line: Int
    }

    /// The font and color of the character before the caret (after it at the start of the text). Cached per
    /// caret line for a few seconds, since it rarely changes while typing along a line.
    private func textStyle(_ element: AXUIElement, text: TextRead, caret: CaretGeometry?) -> TextStyle? {
        let line = caret.map { Int(($0.rect.minY).rounded()) } ?? Int.min
        let key = StyleKey(element: ElementKey(element: element), line: line)
        let now = Self.now
        // A miss is retried soon: right after focus moves, apps often answer before the text is laid out.
        if let cached = styleCache, cached.key == key, now - cached.at < (cached.style == nil ? 0.5 : 3) {
            return cached.style
        }

        // New text takes the style of the character before the caret. A newline there often carries no
        // attributes, so prefer the character after it, and fall back to the newline only when nothing else exists.
        let previousLength = TextWindow.lastCharacterLength(text.before)
        let nextLength = TextWindow.firstCharacterLength(text.after)
        let previousIsNewline = TextWindow.endsWithNewline(text.before)
        let nextIsNewline = text.after.unicodeScalars.first.map(TextWindow.isNewline) ?? false
        var candidates: [(CharacterSide, Int)] = []
        if previousLength > 0, !previousIsNewline { candidates.append((.previous, previousLength)) }
        if nextLength > 0, !nextIsNewline { candidates.append((.next, nextLength)) }
        if previousLength > 0, previousIsNewline { candidates.append((.previous, previousLength)) }

        var style: TextStyle?
        for (side, length) in candidates.prefix(2) {
            guard let attributed = attributedCharacter(element, text: text, side: side, length: length),
                  attributed.length > 0 else { continue }
            style = TextStyleParser.style(from: attributed.attributes(at: 0, effectiveRange: nil))
            if style != nil { break }
        }
        if var s = style, s.fontName == nil, s.fontFamily == nil, s.fontSize != nil {
            s.widthSample = widthSample(element, text: text, caret: caret)
            style = s
        }
        styleCache = (key, style, now)
        return style
    }

    /// Measures up to 24 characters before the caret on its line, when they render on one visual line.
    private func widthSample(_ element: AXUIElement, text: TextRead, caret: CaretGeometry?) -> WidthSample? {
        guard let offset = text.caretOffset, let caret else { return nil }
        let lineUnits = Array(text.before.utf16.reversed().prefix { $0 != 0x0A && $0 != 0x0D }.reversed())
        let count = min(24, lineUnits.count)
        guard count >= 6, offset >= count,
              let rect = bounds(element, CFRange(location: offset - count, length: count)),
              rect.width > 4, rect.height < max(caret.rect.height, 1) * 1.6 else { return nil }
        let units = Array(lineUnits.suffix(count))
        let sample = String(decoding: units, as: UTF16.self)
        guard !sample.contains("\t") else { return nil }
        // Where each word starts: the pattern of advances tells typefaces apart even when total widths match.
        var offsets: [Int: CGFloat] = [:]
        let starts = units.indices.filter { $0 > 0 && units[$0 - 1] == 0x20 && units[$0] != 0x20 }.suffix(6)
        for i in starts {
            if let r = bounds(element, CFRange(location: offset - count + i, length: 1)), abs(r.minY - rect.minY) < rect.height / 2 {
                offsets[i] = r.minX - rect.minX
            }
        }
        return WidthSample(text: sample, width: rect.width, offsets: offsets)
    }

    private enum CharacterSide { case previous, next }

    private func attributedCharacter(_ element: AXUIElement, text: TextRead, side: CharacterSide, length: Int) -> NSAttributedString? {
        if let markers = text.markers {
            let range: AXTextMarkerRange?
            switch side {
            case .previous:
                range = AXCast.textMarker(client.parameterized(element, AXName.previousMarker, markers.start))
                    .map { markerRange(element, from: $0, to: markers.start) }
            case .next:
                range = AXCast.textMarker(client.parameterized(element, AXName.nextMarker, markers.end))
                    .map { markerRange(element, from: markers.end, to: $0) }
            }
            guard let range else { return nil }
            return AXCast.attributedString(client.parameterized(element, AXName.attributedStringForMarkerRange, range))
        }
        guard let caret = text.caretOffset else { return nil }
        let range = side == .previous
            ? CFRange(location: caret - length, length: length)
            : CFRange(location: caret + text.selectionLength, length: length)
        guard range.location >= 0 else { return nil }
        return AXCast.attributedString(client.parameterized(element, AXName.attributedStringForRange, range: range))
    }

    // MARK: - Window title and URL

    private func title(ofWindow window: AXUIElement?) -> String? {
        guard let window else { return nil }
        let key = ElementKey(element: window)
        let now = Self.now
        if let cached = windowTitles[key], now - cached.at < 1 { return cached.title }
        let title = AXCast.nonEmptyString(client.copy(window, AXName.title))
        if windowTitles.count > 32 { windowTitles.removeAll(keepingCapacity: true) }
        windowTitles[key] = (title, now)
        return title
    }

    /// The nearest AXURL (web areas in Safari and Chromium) or AXDocument (document windows) above the field.
    private func pageURL(for element: AXUIElement) -> URL? {
        let key = ElementKey(element: element)
        let now = Self.now
        if let cached = urls[key], now - cached.at < 1 { return cached.url }

        var found: URL?
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            let values = copy(node, [AXName.url, AXName.document, AXName.parent, AXName.role])
            if let url = AXCast.url(values[AXName.url]) ?? AXCast.url(values[AXName.document]) {
                found = url
                break
            }
            let role = AXCast.string(values[AXName.role])
            if role == AXName.windowRole || role == AXName.applicationRole { break }
            current = AXCast.element(values[AXName.parent])
        }
        if urls.count > 32 { urls.removeAll(keepingCapacity: true) }
        urls[key] = (found, now)
        return found
    }

    // MARK: - Helpers

    /// Batched attribute read, remembering processes that don't implement the batched call.
    private func copy(_ element: AXUIElement, _ attributes: [String]) -> [String: CFTypeRef] {
        let pid = element.pid ?? 0
        if !noBatchPIDs.contains(pid) {
            if let values = client.copyMany(element, attributes) { return values }
            // The batched call failing on a live element means the app doesn't support it.
            if client.copyResult(element, AXName.role).value != nil { noBatchPIDs.insert(pid) } else { return [:] }
        }
        return client.copyEach(element, attributes)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
