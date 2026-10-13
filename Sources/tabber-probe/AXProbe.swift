import AppKit
import ApplicationServices
import TabberAX
import TabberCore

// tabber-probe ax: live checks of focus tracking and field reading.
//
//   tabber-probe ax [--seconds N] [--full] [--no-refresh]   print every snapshot the FocusTracker publishes
//     (--no-refresh: key presses are timed but don't call refreshSoon(), to isolate AX notifications)
//   tabber-probe ax once [--repeat N] [--markers]   read the focused field directly, with AX call counts and
//                                                   timing (--markers forces the text-marker path)
//     --app PID|BUNDLE --window TITLE [--role R] [--placeholder P] [--index N]: read the Nth matching element
//     in that window instead of the focused one (no focus change needed; handy when other windows keep
//     taking focus)
//   tabber-probe ax dump                     list the focused element's attributes and their values
//
// The watch mode also listens (listen-only) for key presses, calls refreshSoon() on each one, and prints how long
// after the key the changed snapshot arrived. This is a developer tool: it prints field text.

func runAXProbe(_ arguments: [String]) {
    setvbuf(stdout, nil, _IOLBF, 0)
    let options = AXProbeOptions(arguments)
    guard options.mode != "help" else {
        print("""
        usage: tabber-probe ax [--seconds N] [--full] [--no-refresh]   watch snapshots from FocusTracker
                 (--no-refresh: keys don't call refreshSoon(), to see what notifications alone deliver)
               tabber-probe ax once [--repeat N] [--markers]   direct reads with AX call counts and timing
                                                        (--markers: force the text-marker path)
                 [--app PID|BUNDLE --window TITLE [--role R] [--placeholder P] [--index N]]
                                                        read that element instead of the focused one
               tabber-probe ax dump                     attributes of the focused element
        """)
        return
    }
    guard AXPermission.isTrusted else {
        print("Accessibility permission is missing for this process. Requesting it…")
        AXPermission.requestTrust()
        exit(1)
    }
    if let seconds = options.seconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    }

    switch options.mode {
    case "once":
        // Reads are blocking IPC: keep them off the main thread like the real tracker does.
        Thread.detachNewThread {
            let reader = FieldReader()
            reader.forceTextMarkers = options.markers
            reader.frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var target: AXUIElement?
            if let app = options.app {
                target = AXProbeDump.findElement(app: app, window: options.window, role: options.role,
                                                 placeholder: options.placeholder, index: options.index)
                guard target != nil else { print("no matching element"); exit(1) }
            }
            for index in 0..<options.repeatCount {
                let start = DispatchTime.now()
                let outcome = target.map(reader.read(element:)) ?? reader.read()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                let header = String(format: "read %d: %d AX calls, %.1f ms", index + 1, reader.lastCallCount, ms)
                switch outcome {
                case .field(let snapshot): print(header + "\n" + AXProbeFormat.describe(snapshot, full: options.full))
                case .noField: print(header + ": no editable field focused")
                case .failed: print(header + ": read failed (app did not answer)")
                }
                if index + 1 < options.repeatCount { Thread.sleep(forTimeInterval: 0.1) }
            }
            exit(0)
        }
    case "dump":
        Thread.detachNewThread {
            AXProbeDump.dumpFocused()
            exit(0)
        }
    default:
        AXProbeWatch.run(options)
    }
    RunLoop.main.run()
}

struct AXProbeOptions {
    var mode = "watch"
    var seconds: Double?
    var full = false
    var repeatCount = 1
    var markers = false
    var refresh = true
    var app: String?
    var window: String?
    var role: String?
    var placeholder: String?
    var index = 0

    init(_ arguments: [String]) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "once", "dump", "help", "watch": mode = argument
            case "-h", "--help": mode = "help"
            case "--seconds": seconds = iterator.next().flatMap(Double.init)
            case "--full": full = true
            case "--markers": markers = true
            case "--no-refresh": refresh = false
            case "--app": app = iterator.next()
            case "--window": window = iterator.next()
            case "--role": role = iterator.next()
            case "--placeholder": placeholder = iterator.next()
            case "--index": index = iterator.next().flatMap(Int.init) ?? 0
            case "--repeat": repeatCount = max(1, iterator.next().flatMap(Int.init) ?? 1)
            default: print("ignoring unknown argument \(argument)")
            }
        }
    }
}

enum AXProbeWatch {
    nonisolated(unsafe) static var tracker: FocusTracker?
    nonisolated(unsafe) static var lastKeyAt: DispatchTime?
    nonisolated(unsafe) static var tap: CFMachPort?
    nonisolated(unsafe) static var refreshOnKeys = true

    static func run(_ options: AXProbeOptions) {
        let tracker = FocusTracker()
        self.tracker = tracker
        var count = 0
        tracker.onSnapshot = { snapshot in
            count += 1
            var latency = ""
            if let key = lastKeyAt {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - key.uptimeNanoseconds) / 1e6
                latency = String(format: "  (%.0f ms after last key)", ms)
            }
            let time = AXProbeFormat.clock.string(from: Date())
            guard let snapshot else {
                print("[\(time)] #\(count) no editable field\(latency)")
                return
            }
            print("[\(time)] #\(count)\(latency)\n" + AXProbeFormat.describe(snapshot, full: options.full))
        }
        refreshOnKeys = options.refresh
        installKeyListener()
        tracker.start()
        print("watching focus (Ctrl-C to quit)…")
    }

    /// Listen-only tap: each key press asks the tracker to re-read, as the app's keyboard monitor will.
    private static func installKeyListener() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .keyDown {
                    AXProbeWatch.lastKeyAt = .now()
                    if AXProbeWatch.refreshOnKeys { AXProbeWatch.tracker?.refreshSoon() }
                } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap = AXProbeWatch.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("(no key listener: event tap refused; refreshSoon() won't be exercised)")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

enum AXProbeFormat {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func describe(_ s: FieldSnapshot, full: Bool) -> String {
        var lines: [String] = []
        let subrole = s.subrole.map { "/\($0)" } ?? ""
        lines.append("  \(s.app.name) (\(s.app.bundleID), pid \(s.app.pid))  \(s.role)\(subrole)  field #\(String(s.field.elementHash, radix: 16))")
        var flags: [String] = []
        if s.isSecure { flags.append("SECURE") }
        if !s.isEditable { flags.append("read-only") }
        flags.append(s.isSingleLine ? "single-line" : "multi-line")
        if s.hasMarkedText { flags.append("marked-text") }
        if s.beforeIsTruncated { flags.append("truncated") }
        lines.append("  " + flags.joined(separator: ", ")
            + "  caret=\(s.caretOffset.map(String.init) ?? "?") sel=\(s.selectionLength)"
            + "  before=\(s.textBeforeCaret.utf16.count)u after=\(s.textAfterCaret.utf16.count)u")
        let before = full ? s.textBeforeCaret : String(s.textBeforeCaret.suffix(40))
        let after = full ? s.textAfterCaret : String(s.textAfterCaret.prefix(20))
        lines.append("  text: \(quote(before))|\(quote(after))")
        if let caret = s.caret {
            lines.append("  caret: \(rect(caret.rect)) \(caret.quality)   field: \(s.fieldFrame.map(rect) ?? "?")")
        } else {
            lines.append("  caret: none   field: \(s.fieldFrame.map(rect) ?? "?")")
        }
        if let style = s.style {
            let font = [style.fontName, style.fontFamily.map { "(\($0))" }, style.fontSize.map { String(format: "%.1fpt", $0) }]
                .compactMap { $0 }.joined(separator: " ")
            lines.append("  font: \(font.isEmpty ? "?" : font)   color: \(style.textColor.map(hex) ?? "?")")
        } else {
            lines.append("  font: none")
        }
        var meta: [String] = []
        if let title = s.windowTitle { meta.append("window \(quote(title))") }
        if let url = s.url { meta.append("url \(url.absoluteString)") }
        if let label = s.label { meta.append("label \(quote(label))") }
        if let placeholder = s.placeholder { meta.append("placeholder \(quote(placeholder))") }
        if !meta.isEmpty { lines.append("  " + meta.joined(separator: "  ")) }
        return lines.joined(separator: "\n")
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func rect(_ r: CGRect) -> String {
        String(format: "(%.1f, %.1f, %.1f×%.1f)", r.minX, r.minY, r.width, r.height)
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02x%02x%02x a%.2f", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255), c.a)
    }
}

/// Raw attribute dump of the focused element, for working out what an app exposes.
enum AXProbeDump {
    static func dumpFocused() {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(systemWide, "AXFocusedUIElement" as CFString, &value)
        // Like the reader: when the system-wide query fails, ask the frontmost app.
        if error != .success, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXFocusedUIElement" as CFString, &value)
        }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            print("no focused element (AXError \(error.rawValue))")
            return
        }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        print("focused element in pid \(pid) (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"))")
        dump(element, indent: "  ")

        var parent: AXUIElement? = element
        for level in 1...8 {
            guard let current = parent, let up = copy(current, "AXParent"), CFGetTypeID(up) == AXUIElementGetTypeID() else { break }
            let next = up as! AXUIElement
            let role = copy(next, "AXRole").map(describe) ?? "?"
            let url = copy(next, "AXURL").map(describe)
            let document = copy(next, "AXDocument").map(describe)
            print("  ancestor \(level): \(role)\(url.map { " AXURL=\($0)" } ?? "")\(document.map { " AXDocument=\($0)" } ?? "")")
            parent = next
        }
    }

    static func dump(_ element: AXUIElement, indent: String) {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        for name in (names as? [String] ?? []).sorted() {
            let rendered = copy(element, name).map(describe) ?? "—"
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            print("\(indent)\(name)\(settable.boolValue ? " (settable)" : ""): \(rendered)")
        }
        var parameterized: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &parameterized)
        print("\(indent)parameterized: \((parameterized as? [String] ?? []).sorted().joined(separator: ", "))")
    }

    /// Breadth-first search of a window for the Nth element with `role` (or `placeholder`).
    static func findElement(app: String, window: String?, role: String?, placeholder: String?, index: Int) -> AXUIElement? {
        let running = Int32(app).flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: app).first
        guard let running else { return nil }
        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1)
        let windows = (copy(appElement, "AXWindows") as? [AXUIElement]) ?? []
        guard let root = windows.first(where: { window == nil || ((copy($0, "AXTitle") as? String) ?? "").contains(window!) })
        else { return nil }
        var queue = [root]
        var matches: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            let matchesRole = role.map { (copy(element, "AXRole") as? String) == $0 } ?? true
            let matchesPlaceholder = placeholder.map { (copy(element, "AXPlaceholderValue") as? String) == $0 } ?? true
            if matchesRole, matchesPlaceholder, role != nil || placeholder != nil {
                matches.append(element)
                if matches.count > index { return matches[index] }
            }
            queue.append(contentsOf: (copy(element, "AXChildren") as? [AXUIElement]) ?? [])
        }
        return nil
    }

    static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func describe(_ value: CFTypeRef) -> String {
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() {
            let s = value as! CFString as String
            let shown = s.count > 80 ? String(s.prefix(80)) + "… (\(s.utf16.count)u)" : s
            return AXProbeFormat.quote(shown)
        }
        if type == AXUIElementGetTypeID() {
            return "<element \(copy(value as! AXUIElement, "AXRole").map { $0 as? String ?? "?" } ?? "?")>"
        }
        if type == CFArrayGetTypeID() { return "[\(CFArrayGetCount((value as! CFArray))) items]" }
        if type == AXValueGetTypeID() {
            let axValue = value as! AXValue
            switch AXValueGetType(axValue) {
            case .cfRange:
                var r = CFRange(); AXValueGetValue(axValue, .cfRange, &r); return "range(\(r.location), \(r.length))"
            case .cgRect:
                var r = CGRect.zero; AXValueGetValue(axValue, .cgRect, &r); return AXProbeFormat.rect(r)
            case .cgPoint:
                var p = CGPoint.zero; AXValueGetValue(axValue, .cgPoint, &p); return "point(\(p.x), \(p.y))"
            case .cgSize:
                var s = CGSize.zero; AXValueGetValue(axValue, .cgSize, &s); return "size(\(s.width), \(s.height))"
            default: return "AXValue"
            }
        }
        return String(describing: value).prefix(80).replacingOccurrences(of: "\n", with: " ")
    }
}
