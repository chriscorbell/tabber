import AppKit
import TabberCore
import TabberInput

// tabber-probe input: live checks of the event tap and text insertion.
//
//   tabber-probe input [--method keystrokes|paste|characterByCharacter] [--text "..."] [--seconds N]
//                      [--keycode N] [--post hid|session|annotated] [--hidden] [--delay MS] [--all-sends-tab] [--chunk N]
//   tabber-probe input taps     list other processes' event taps
//
// Runs the keyboard monitor as if a ghost were visible (Tab accepts a word, the key above Tab accepts all,
// Esc dismisses, Ctrl-` and Ctrl-Opt-Cmd-` are hotkeys) and prints every classified event. An accept
// inserts --text (default " world", `\n` and `\t` unescaped) with --method. --hidden runs with no ghost
// visible, so only hotkeys are swallowed. With --method paste it also checks the clipboard comes back
// unchanged. --keycode and --post change the virtual key and post location of Unicode events. --delay waits
// before inserting, like a busy coordinator would (handy for holding a modifier during the insertion).
// --all-sends-tab makes accept-all call passThroughTab() instead of inserting. --chunk sets UTF-16 units per event.

func runInputProbe(_ arguments: [String]) {
    let options = InputProbeOptions(arguments)
    setvbuf(stdout, nil, _IOLBF, 0)

    switch options.mode {
    case "help":
        print("""
        usage: tabber-probe input [options]
          --method keystrokes|paste|characterByCharacter   how accepts insert --text (default keystrokes)
          --text "..."      text inserted on accept (default " world"; \\n and \\t are unescaped)
          --hidden          no ghost visible: only hotkeys are swallowed
          --keycode N       virtual key of Unicode events (default 0)
          --post hid|session|annotated   where events are posted (default annotated)
          --delay MS        wait before inserting
          --all-sends-tab   accept-all sends a real Tab with passThroughTab()
          --chunk N         UTF-16 units per Unicode event (default 20)
          --seconds N       exit after N seconds
        tabber-probe input taps    list other processes' event taps
        """)
        return
    case "taps":
        let taps = EventTapDiagnostics.allTaps()
        for tap in taps {
            let kind = tap.filters ? "active" : "listen-only"
            print("pid \(tap.pid) \(tap.processName): \(kind), \(tap.enabled ? "enabled" : "disabled"), mask 0x\(String(tap.eventsOfInterest, radix: 16))")
        }
        print("\(EventTapDiagnostics.activeTaps().count) active taps in other processes, \(taps.count) taps total")
        return
    default:
        break
    }

    let secure = KeyboardMonitor.isSecureInputEnabled
    print("secure input: \(secure)\(secure ? " (pid \(KeyboardMonitor.secureInputProcessID.map(String.init) ?? "?"))" : "")")
    print("clipboard access: \(TextInserter.clipboardAccess)")

    var insertOptions = TextInserter.Options()
    if let keyCode = options.keyCode { insertOptions.unicodeKeyCode = keyCode }
    if let location = options.location { insertOptions.postLocation = location }
    if let chunk = options.chunk { insertOptions.maxUnitsPerEvent = chunk }
    let inserter = TextInserter(options: insertOptions)
    let monitor = KeyboardMonitor()
    monitor.update(InterceptState(
        ghostVisible: !options.hidden,
        acceptWord: .tab,
        acceptAll: .keyAboveTab,
        dismissWithEscape: true,
        hotkeys: [.forceActivate: .forceActivate, .pauseInApp: .pauseInApp]
    ))
    // The user's clipboard before any paste, to check it comes back.
    let clipboardBefore = options.method == .paste ? PasteboardSnapshot.capture(.general) : nil
    monitor.onEvent = { event in
        print("event \(InputProbe.describe(event))")
        guard case .accept(let kind) = event else { return }
        if kind == .all, options.allSendsTab {
            inserter.passThroughTab()
            print("pass through Tab")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.delay) {
            inserter.insert(options.text, method: options.method)
            print("insert \(options.text.debugDescription) via \(options.method.rawValue)")
            guard let before = clipboardBefore else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let marked = NSPasteboard.general.types?.contains(PasteboardMarker.transient) ?? false
                print("clipboard during paste: transient marker \(marked)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let restored = PasteboardSnapshot.capture(.general) == before
                print("clipboard restored: \(restored) (\(before.items.count) items)")
            }
        }
    }

    do {
        try monitor.start()
    } catch {
        print("error: \(error) (is Accessibility permission granted?)")
        exit(1)
    }
    print("ready: ghost \(options.hidden ? "hidden" : "visible"), accepts insert \(options.text.debugDescription) via \(options.method.rawValue)")

    if let seconds = options.seconds {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            monitor.stop()
            print("done")
            exit(0)
        }
    }
    signal(SIGINT) { _ in exit(0) }
    RunLoop.main.run()
}

enum InputProbe {
    static func describe(_ event: KeyEvent) -> String {
        switch event {
        case .typed(let text): "typed(\(text.debugDescription))"
        case .accept(let kind): "accept(\(kind))"
        default: "\(event)"
        }
    }
}

struct InputProbeOptions {
    var mode = "run"
    var method = InsertionMethod.keystrokes
    var text = " world"
    var hidden = false
    var keyCode: CGKeyCode?
    var location: CGEventTapLocation?
    var seconds: Double?
    var delay: TimeInterval = 0
    var allSendsTab = false
    var chunk: Int?

    init(_ args: [String]) {
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "help", "--help", "-h": mode = "help"
            case "taps": mode = "taps"
            case "--method":
                if let value = next(), let parsed = InsertionMethod(rawValue: value) { method = parsed } else { mode = "help" }
            case "--text":
                text = (next() ?? text).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            case "--hidden": hidden = true
            case "--all-sends-tab": allSendsTab = true
            case "--chunk": chunk = next().flatMap { Int($0) }.map { max($0, 2) }
            case "--keycode": keyCode = next().flatMap { CGKeyCode($0) }
            case "--post":
                switch next() {
                case "hid": location = .cghidEventTap
                case "session": location = .cgSessionEventTap
                case "annotated": location = .cgAnnotatedSessionEventTap
                default: mode = "help"
                }
            case "--seconds": seconds = next().flatMap(Double.init)
            case "--delay": delay = (next().flatMap(Double.init) ?? 0) / 1000
            default: mode = "help"
            }
            i += 1
        }
    }
}
