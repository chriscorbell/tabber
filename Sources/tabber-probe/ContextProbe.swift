import AppKit
import ApplicationServices
import Foundation
import TabberContext
import TabberCore

// tabber-probe context [screen] [--pid P] [--delay S] [--lines] [--repeat N] [--watch S]
//   Reads the focused field with a minimal inline Accessibility query, then captures and recognizes the text
//   around it, printing timings and the result. Focus a text field in another app first (or use --delay), or
//   pass --pid to read that app's focused field even while it is in the background.
// tabber-probe context clipboard [--watch S] [--max-age S] [--allow-prompt]
//   Shows the pasteboard access state and prints recently copied text as it changes.
// tabber-probe context warmup
//   Times ScreenContextProvider.warmUp() (slow only the first time this binary uses Vision on this OS build).
// tabber-probe context redact <text>
//   Prints the text after secret redaction.

func runContextProbe(_ arguments: [String]) {
    var args = arguments
    let mode = args.first.map { $0.hasPrefix("--") ? "screen" : $0 } ?? "screen"
    if args.first == mode { args.removeFirst() }

    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    switch mode {
    case "screen":
        let delay = value("--delay").flatMap(Double.init) ?? 0
        let repeats = value("--repeat").flatMap(Int.init) ?? 1
        let showLines = args.contains("--lines")
        let pid = value("--pid").flatMap(Int32.init)
        let watch = value("--watch").flatMap(Double.init)
        Task.detached {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            if let watch {
                await ContextProbe.watch(pid: pid, seconds: watch)
            } else {
                await ContextProbe.screen(pid: pid, showLines: showLines, repeats: repeats)
            }
            exit(0)
        }
    case "clipboard":
        let watch = value("--watch").flatMap(Double.init) ?? 15
        let maxAge = value("--max-age").flatMap(Double.init) ?? 60
        ContextProbe.clipboard(watch: watch, maxAge: maxAge, allowPrompt: args.contains("--allow-prompt"))
    case "warmup":
        Task.detached {
            let t = Date()
            await ScreenContextProvider.warmUp()
            print(String(format: "warm-up took %.0f ms", Date().timeIntervalSince(t) * 1000))
            exit(0)
        }
    case "redact":
        print(SecretRedactor.redact(args.joined(separator: " ")))
        exit(0)
    default:
        print("usage: tabber-probe context [screen|clipboard|redact] [options]")
        exit(1)
    }
    RunLoop.main.run()
}

private enum ContextProbe {
    static func ms(_ t: TimeInterval) -> String { String(format: "%.0f ms", t * 1000) }

    static func screen(pid: pid_t?, showLines: Bool, repeats: Int) async {
        print("screen recording permitted: \(ScreenContextProvider.isPermitted)")
        print("accessibility trusted: \(AXIsProcessTrusted())")
        guard let snapshot = FocusedField.read(pid: pid) else {
            print("no focused text field (focus one in another app, or pass --delay 3)")
            return
        }
        let frame = snapshot.fieldFrame.map { "\($0)" } ?? "unknown"
        print("app: \(snapshot.app.name) (\(snapshot.app.bundleID), pid \(snapshot.app.pid))")
        print("field: \(snapshot.role)\(snapshot.subrole.map { "/\($0)" } ?? "") frame \(frame)")
        print("window: \(snapshot.windowTitle ?? "-")")
        print("field text: \(snapshot.textBeforeCaret.count) chars before caret, \(snapshot.textAfterCaret.count) after")

        let provider = ScreenContextProvider()
        guard provider.isEligible(snapshot) else {
            print("not eligible for capture (secure field, excluded app, secure input on, or no permission)")
            return
        }

        // Cold path: a full capture and recognition, bypassing the cache.
        for run in 1...max(1, repeats) {
            let t0 = Date()
            guard let report = await provider.captureNow(for: snapshot) else {
                print("capture failed (no window found for the field?)")
                return
            }
            let total = Date().timeIntervalSince(t0)
            print("\n— capture \(run): total \(ms(total)) = window+capture \(ms(report.captureDuration)) + OCR \(ms(report.recognitionDuration)) (+ assembly)")
            print("window \(report.windowID) \(report.windowFrame)")
            print("region \(report.region) → \(report.pixelWidth)×\(report.pixelHeight) px")
            print("recognized \(report.recognizedLines.count) lines → \(report.text.count) chars")
            if run == 1 {
                if showLines {
                    print("\n— raw lines (confidence, window-local box):")
                    for line in report.recognizedLines {
                        let b = line.box
                        print(String(format: "  %.2f  (%6.1f,%6.1f %6.1f×%5.1f)  ", line.confidence, b.minX, b.minY, b.width, b.height) + line.text)
                    }
                }
                print("\n— screen text:\n\(report.text)\n—")
            }
        }

        // Cached path, as the coordinator uses it.
        let t1 = Date()
        let first = await provider.screenText(for: snapshot)
        let firstCall = Date().timeIntervalSince(t1)
        print("\nscreenText first call: \(ms(firstCall)), returned \(first == nil ? "nil (capture started in background)" : "\(first!.count) chars")")
        var text = first
        while text == nil, Date().timeIntervalSince(t1) < 5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            text = await provider.screenText(for: snapshot)
        }
        print("background capture landed after \(ms(Date().timeIntervalSince(t1)))")
        let n = 1000
        let t2 = Date()
        for _ in 0..<n { _ = await provider.screenText(for: snapshot) }
        let per = Date().timeIntervalSince(t2) / Double(n)
        print(String(format: "screenText cached call: %.1f µs average over %d calls, %d chars", per * 1e6, n, text?.count ?? 0))
    }

    /// Calls screenText every 250 ms like a typing session would, printing whenever the returned text changes.
    static func watch(pid: pid_t?, seconds: TimeInterval) async {
        guard let snapshot = FocusedField.read(pid: pid) else {
            print("no focused text field")
            return
        }
        let provider = ScreenContextProvider()
        let start = Date()
        var last: String?
        var calls = 0
        var slowest: TimeInterval = 0
        print("watching \(snapshot.app.name) for \(Int(seconds)) s")
        while Date().timeIntervalSince(start) < seconds {
            let t = Date()
            let text = await provider.screenText(for: snapshot)
            slowest = max(slowest, Date().timeIntervalSince(t))
            calls += 1
            if text != last {
                let similarity = TextSimilarity.jaccard(last ?? "", text ?? "")
                let head = (text ?? "nil").split(separator: "\n").prefix(2).joined(separator: " | ")
                print(String(format: "t=%5.1f s  %4d chars  jaccard vs previous %.2f  %@", Date().timeIntervalSince(start),
                             text?.count ?? 0, similarity, String(head.prefix(110))))
                last = text
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        print("\(calls) calls, slowest \(ms(slowest))")
    }

    static func clipboard(watch: TimeInterval, maxAge: TimeInterval, allowPrompt: Bool) {
        var config = ClipboardContextProvider.Configuration()
        config.readWhenItWouldPrompt = allowPrompt
        let provider = ClipboardContextProvider(configuration: config)
        print("pasteboard access: \(provider.access)")
        print("change count: \(NSPasteboard.general.changeCount)")
        print("watching for \(Int(watch)) s; copy something…")
        provider.startMonitoring()
        var last: Int?
        let deadline = Date().addingTimeInterval(watch)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let (count, changedAt) = provider.poll()
            if count != last {
                last = count
                if let changedAt {
                    let text = provider.recentText(maxAge: maxAge)
                    print("[\(count)] changed \(String(format: "%.1f", Date().timeIntervalSince(changedAt))) s ago → \(text.map { "\"\($0.prefix(200))\"" } ?? "nil")")
                }
            }
            if Date() > deadline { exit(0) }
        }
    }
}

/// A minimal, self-contained read of the focused field (the real one lives in TabberAX).
private enum FocusedField {
    static func read(pid requested: pid_t?) -> FieldSnapshot? {
        var element: AXUIElement?
        if requested == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 1)
            element = attribute(system, kAXFocusedUIElementAttribute)
        }
        if element == nil {
            // The system-wide query can fail (kAXErrorCannotComplete); ask the app directly instead.
            guard let pid = requested ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            // Chromium and Electron only build their web accessibility tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            element = attribute(app, kAXFocusedUIElementAttribute)
            if element == nil {
                Thread.sleep(forTimeInterval: 0.5)
                element = attribute(app, kAXFocusedUIElementAttribute)
            }
            if element == nil, requested != nil {
                // A background app has no focused element. For probing, take its first text area instead.
                element = firstTextArea(in: app)
                if element != nil { print("(app has no focused element; using its first AXTextArea)") }
            }
        }
        guard let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        var frame: CGRect?
        if let posValue: AXValue = attribute(element, kAXPositionAttribute),
           let sizeValue: AXValue = attribute(element, kAXSizeAttribute) {
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue, .cgSize, &size)
            frame = CGRect(origin: origin, size: size)
        }

        let value: String = attribute(element, kAXValueAttribute) ?? ""
        var before = value, after = ""
        if let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            AXValueGetValue(rangeValue, .cfRange, &range)
            let utf16 = value.utf16
            if range.location >= 0, range.location <= utf16.count {
                let idx = utf16.index(utf16.startIndex, offsetBy: range.location)
                before = String(value[..<idx])
                after = String(value[idx...])
            }
        }

        let app = AXUIElementCreateApplication(pid)
        var windowTitle: String?
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
            windowTitle = attribute(window, kAXTitleAttribute)
        }
        let running = NSRunningApplication(processIdentifier: pid)
        return FieldSnapshot(
            app: AppIdentity(bundleID: running?.bundleIdentifier ?? "?", name: running?.localizedName ?? "?", pid: pid),
            field: FieldIdentity(pid: pid, elementHash: UInt(CFHash(element)), role: role),
            role: role,
            subrole: subrole,
            windowTitle: windowTitle,
            textBeforeCaret: before,
            textAfterCaret: after,
            isSecure: subrole == (kAXSecureTextFieldSubrole as String),
            fieldFrame: frame
        )
    }

    private static func firstTextArea(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if (attribute(element, kAXRoleAttribute) as String?) == (kAXTextAreaRole as String) { return element }
            queue += (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}
