import AppKit
import ApplicationServices
import TabberCore
import TabberOverlay

// tabber-probe overlay: live checks of the ghost-text window.
//
//   tabber-probe overlay demo   [--caret x,y,w,h] [--field x,y,w,h] [--font NAME] [--family NAME] [--size PT]
//                               [--color r,g,b | #rrggbb] [--midline] [--typing] [style options]
//   tabber-probe overlay follow [--verbose] [style options]
//
// Style options: --text "..." --lag N --mirror --grey --opacity X --scale X --offset PT --no-animate --seconds N
//
// Rects are global Quartz coordinates (top-left of the primary display, y down), like Accessibility reports.
// `follow` reads the focused field's caret and font with a minimal inline AX read every 100 ms and draws a
// fake ghost there. `--lag N` pretends the user typed N characters of the ghost that the app hasn't shown yet.
// `demo --typing` types through the ghost every 80 ms while the snapshot lags, hiding and re-showing at the end.

func runOverlayProbe(_ arguments: [String]) {
    let options = OverlayProbeOptions(arguments)
    if options.mode == "help" {
        print("""
        usage: tabber-probe overlay demo|follow [options]
          demo    draw a ghost at --caret x,y,w,h (Quartz) with --font/--family/--size/--color, optional --field, --midline,
                  --typing (type through the ghost every 80 ms, then fade out and back in)
          follow  draw a ghost at the focused text field's caret, refreshed every 100 ms (--verbose prints AX reads)
          common  --text "..." --lag N --mirror --grey --opacity X --scale X --offset PT --no-animate --seconds N
        """)
        return
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let probe = OverlayProbe(options: options)
        OverlayProbe.current = probe
        probe.start()
    }
    signal(SIGINT) { _ in exit(0) }
    app.run()
}

struct OverlayProbeOptions {
    var mode = "demo"
    var caret = CGRect(x: 600, y: 400, width: 1, height: 17)
    var field: CGRect?
    var fontName: String?
    var fontFamily: String?
    var fontSize: CGFloat?
    var color: RGBA?
    var midline = false
    var typing = false
    var text: String?
    var lag = 0
    var appearance = OverlayController.Appearance()
    var seconds: Double?
    var verbose = false

    init(_ args: [String]) {
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        if let first = args.first, !first.hasPrefix("--") {
            mode = first
            i = 1
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--caret": if let r = next().flatMap(Self.rect) { caret = r }
            case "--field": field = next().flatMap(Self.rect)
            case "--font": fontName = next()
            case "--family": fontFamily = next()
            case "--size": fontSize = next().flatMap(Double.init).map { CGFloat($0) }
            case "--color": color = next().flatMap(Self.color)
            case "--midline": midline = true
            case "--typing": typing = true
            case "--text": text = next()
            case "--lag": lag = next().flatMap(Int.init) ?? 0
            case "--mirror": appearance.forceMirror = true
            case "--grey": appearance.greyText = true
            case "--opacity": appearance.opacity = next().flatMap(Double.init) ?? 0.5
            case "--scale": appearance.fontScale = next().flatMap(Double.init) ?? 1
            case "--offset": appearance.verticalOffset = next().flatMap(Double.init) ?? 0
            case "--no-animate": appearance.animate = false
            case "--seconds": seconds = next().flatMap(Double.init)
            case "--verbose": verbose = true
            default: FileHandle.standardError.write("unknown option \(arg)\n".data(using: .utf8)!)
            }
            i += 1
        }
    }

    static func rect(_ s: String) -> CGRect? {
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func color(_ s: String) -> RGBA? {
        if s.hasPrefix("#"), s.count == 7, let n = UInt32(s.dropFirst(), radix: 16) {
            return RGBA(r: Double((n >> 16) & 0xFF) / 255, g: Double((n >> 8) & 0xFF) / 255, b: Double(n & 0xFF) / 255)
        }
        let v = s.split(separator: ",").compactMap { Double($0) }
        guard v.count >= 3 else { return nil }
        return RGBA(r: v[0], g: v[1], b: v[2], a: v.count > 3 ? v[3] : 1)
    }
}

@MainActor final class OverlayProbe {
    static var current: OverlayProbe?

    let options: OverlayProbeOptions
    let overlay = OverlayController()
    private let queue = DispatchQueue(label: "tabber.probe.ax")
    private var reading = false
    private var lastLog = ""

    init(options: OverlayProbeOptions) { self.options = options }

    func start() {
        if let seconds = options.seconds ?? (options.mode == "demo" ? 15 : nil) {
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
        }
        switch options.mode {
        case "follow":
            guard AXIsProcessTrusted() else {
                print("Accessibility permission is required for follow mode.")
                exit(1)
            }
            print("following the focused text field; Ctrl-C to stop")
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { OverlayProbe.current?.tick() }
            }
        default:
            showDemo()
        }
    }

    private func ghostText(after before: String) -> String {
        if let text = options.text { return text }
        return before.last == " " || before.isEmpty ? "jumps over the lazy dog" : " jumps over the lazy dog"
    }

    private func showDemo() {
        let before = "The quick brown fox"
        let field = FieldIdentity(pid: getpid(), elementHash: 1, role: "AXTextArea")
        let snapshot = FieldSnapshot(
            app: AppIdentity(bundleID: "probe", name: "probe", pid: getpid()),
            field: field,
            role: "AXTextArea",
            textBeforeCaret: before,
            textAfterCaret: options.midline ? " and the rest of the line" : "",
            fieldFrame: options.field,
            caret: CaretGeometry(rect: options.caret, quality: .exact),
            style: TextStyle(fontName: options.fontName, fontFamily: options.fontFamily, fontSize: options.fontSize, textColor: options.color)
        )
        var ghost = Ghost(requestID: 1, field: field, anchor: before, text: ghostText(after: before), consumed: options.lag)
        overlay.show(ghost: ghost, snapshot: snapshot, appearance: options.appearance)
        print("showing \(overlay.presentation.map { "\($0)" } ?? "nothing") at caret \(options.caret)")
        print(overlay.debugSummary)
        guard options.typing else { return }
        // The snapshot never catches up, so every step goes through the type-through shift.
        let appearance = options.appearance
        let overlay = self.overlay
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated {
                if ghost.consumed + 1 >= ghost.text.count {
                    overlay.hide(animated: appearance.animate)
                    ghost.consumed = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        MainActor.assumeIsolated { overlay.show(ghost: ghost, snapshot: snapshot, appearance: appearance) }
                    }
                    return
                }
                ghost.consumed += 1
                overlay.show(ghost: ghost, snapshot: snapshot, appearance: appearance)
            }
        }
    }

    func tick() {
        guard !reading else { return }
        reading = true
        let verbose = options.verbose
        queue.async {
            let read = FocusedFieldReader.read(verbose: verbose)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let probe = OverlayProbe.current else { return }
                    probe.reading = false
                    probe.apply(read)
                }
            }
        }
    }

    private func apply(_ read: FocusedFieldReader.Result) {
        guard let snapshot = read.snapshot, !snapshot.isSecure, snapshot.selectionLength == 0 else {
            overlay.hide(animated: options.appearance.animate)
            log(read.log)
            return
        }
        let before = snapshot.textBeforeCaret
        let ghost = Ghost(requestID: 1, field: snapshot.field, anchor: before, text: ghostText(after: before), consumed: options.lag)
        overlay.show(ghost: ghost, snapshot: snapshot, appearance: options.appearance)
        log(read.log + "\n  overlay: " + overlay.debugSummary)
    }

    private func log(_ text: String) {
        guard options.verbose, text != lastLog else { return }
        lastLog = text
        print(text)
    }
}

/// A minimal, self-contained read of the focused text field (the real one lives in TabberAX).
enum FocusedFieldReader {
    struct Result: @unchecked Sendable {
        var snapshot: FieldSnapshot?
        var log: String
    }

    static func read(verbose: Bool) -> Result {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else {
            return Result(snapshot: nil, log: "no focused element")
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return Result(snapshot: nil, log: "focus is ours") }
        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        guard let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else {
            return Result(snapshot: nil, log: "focused \(role) has no text range")
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return Result(snapshot: nil, log: "bad range") }

        let value: String = attribute(element, kAXValueAttribute) ?? ""
        let ns = value as NSString
        let location = min(max(range.location, 0), ns.length)
        let before = ns.substring(to: location)
        let after = ns.substring(from: min(location + range.length, ns.length))

        let zero = bounds(element, CFRange(location: location, length: 0))
        let prevIsBreak = before.last.map(\.isNewline) ?? true
        let previous = prevIsBreak ? nil : bounds(element, CFRange(location: location - 1, length: 1))
        let nextChar = (prevIsBreak && location < ns.length) ? bounds(element, CFRange(location: location, length: 1)) : nil

        var caret: CaretGeometry?
        if let p = previous {
            if let z = zero, abs(z.minX - p.maxX) < max(4, p.height) {
                caret = CaretGeometry(rect: CGRect(x: z.minX, y: p.minY, width: 1, height: p.height), quality: .exact)
            } else {
                caret = CaretGeometry(rect: CGRect(x: p.maxX, y: p.minY, width: 1, height: p.height), quality: .derived)
            }
        } else if let z = zero {
            caret = CaretGeometry(rect: CGRect(x: z.minX, y: z.minY, width: 1, height: z.height), quality: .exact)
        } else if let n = nextChar {
            caret = CaretGeometry(rect: CGRect(x: n.minX, y: n.minY, width: 1, height: n.height), quality: .derived)
        }

        let styleLocation = prevIsBreak ? location : location - 1
        let (style, styleLog) = textStyle(element, at: styleLocation, length: ns.length)

        var frame: CGRect?
        if let posValue: AXValue = attribute(element, kAXPositionAttribute), let sizeValue: AXValue = attribute(element, kAXSizeAttribute) {
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &pos)
            AXValueGetValue(sizeValue, .cgSize, &size)
            frame = CGRect(origin: pos, size: size)
        }

        let snapshot = FieldSnapshot(
            app: AppIdentity(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?", name: "", pid: pid),
            field: FieldIdentity(pid: pid, elementHash: CFHash(element), role: role),
            role: role,
            subrole: subrole,
            textBeforeCaret: before,
            textAfterCaret: after,
            selectionLength: range.length,
            caretOffset: location,
            isSecure: subrole == (kAXSecureTextFieldSubrole as String),
            isSingleLine: role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String),
            fieldFrame: frame,
            caret: caret,
            style: style
        )
        var log = ""
        if verbose {
            func r(_ rect: CGRect?) -> String {
                guard let rect else { return "nil" }
                return String(format: "(%.2f, %.2f, %.2f, %.2f)", rect.minX, rect.minY, rect.width, rect.height)
            }
            log = """
            \(role)\(subrole.map { "/" + $0 } ?? "") caret@\(location) of \(ns.length), frame \(r(frame))
              bounds(loc,0) \(r(zero))  bounds(prev) \(r(previous))  bounds(next) \(r(nextChar))
              caret \(r(caret?.rect)) \(caret.map { "\($0.quality)" } ?? "")  \(styleLog)
            """
        }
        return Result(snapshot: snapshot, log: log)
    }

    private static func textStyle(_ element: AXUIElement, at location: Int, length: Int) -> (TextStyle?, String) {
        guard length > 0 else { return (nil, "style: empty") }
        var range = CFRange(location: min(max(location, 0), length - 1), length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return (nil, "style: ?") }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFAttributedStringGetTypeID()
        else { return (nil, "style: no attributed string") }
        let attributed = raw as! CFAttributedString
        guard CFAttributedStringGetLength(attributed) > 0,
              let attrs = CFAttributedStringGetAttributes(attributed, 0, nil) as? [String: Any]
        else { return (nil, "style: no attributes") }
        var style = TextStyle()
        if let font = attrs["AXFont"] as? [String: Any] {
            style.fontName = font["AXFontName"] as? String
            style.fontFamily = font["AXFontFamily"] as? String
            style.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        if let any = attrs["AXForegroundColor"], CFGetTypeID(any as CFTypeRef) == CGColor.typeID {
            let cg = any as! CGColor
            // Apps hand over sRGB component values tagged as Generic RGB; converting would shift them. Take RGB as-is.
            let rgb = cg.colorSpace?.model == .rgb ? cg : cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            if let c = rgb?.components, c.count >= 3 {
                style.textColor = RGBA(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]), a: Double(c.count > 3 ? c[3] : 1))
            }
        }
        var color = style.textColor.map { String(format: "rgba(%.3f,%.3f,%.3f,%.2f)", $0.r, $0.g, $0.b, $0.a) } ?? "nil"
        if let any = attrs["AXForegroundColor"], CFGetTypeID(any as CFTypeRef) == CGColor.typeID {
            let cg = any as! CGColor
            color += " raw=\((cg.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")) in \(cg.colorSpace?.name.map { $0 as String } ?? "?")"
        }
        return (style, "style: name=\(style.fontName ?? "nil") family=\(style.fontFamily ?? "nil") size=\(style.fontSize.map { "\($0)" } ?? "nil") color=\(color)")
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard range.location >= 0, let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 1, rect.minX.isFinite else { return nil }
        return rect
    }
}
