import CoreGraphics
import TabberCore
import Testing
@testable import TabberInput

private let visible = InterceptState(
    ghostVisible: true,
    acceptWord: .tab,
    acceptAll: .keyAboveTab,
    dismissWithEscape: true,
    hotkeys: [.forceActivate: .forceActivate, .pauseInApp: .pauseInApp]
)

private var hidden: InterceptState {
    var state = visible
    state.ghostVisible = false
    return state
}

/// Flags as a real keyboard reports them, with the device-dependent and non-coalesced bits set.
private func flags(_ modifiers: CGEventFlags..., noise: Bool = true) -> CGEventFlags {
    var result: CGEventFlags = noise ? [.maskNonCoalesced] : []
    if noise { result.insert(CGEventFlags(rawValue: 0x20)) } // a device-dependent left-modifier bit
    for m in modifiers { result.formUnion(m) }
    return result
}

/// Wraps the interceptor in a reference so `#expect` can call its mutating methods.
private final class Harness {
    var interceptor = KeyInterceptor()

    func down(_ keyCode: UInt16, _ eventFlags: CGEventFlags = flags(), _ chars: String = "", repeat isRepeat: Bool = false, state: InterceptState = visible) -> KeyDecision {
        interceptor.keyDown(keyCode: keyCode, flags: eventFlags, characters: chars, isRepeat: isRepeat, state: state)
    }

    func up(_ keyCode: UInt16) -> Bool {
        interceptor.keyUp(keyCode: keyCode)
    }
}

private func once(_ keyCode: UInt16, _ eventFlags: CGEventFlags = flags(), _ chars: String = "", state: InterceptState = visible) -> KeyDecision {
    Harness().down(keyCode, eventFlags, chars, state: state)
}

@Suite struct ModifierMatching {
    @Test func ignoresCapsLockFnNumpadAndDeviceBits() {
        let noisy: CGEventFlags = [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced, CGEventFlags(rawValue: 0x1 | 0x8 | 0x20)]
        #expect(KeyBinding.Modifiers(eventFlags: noisy) == [])
        #expect(KeyBinding.tab.matches(keyCode: 48, flags: noisy))
    }

    @Test func mapsTheFourModifiers() {
        #expect(KeyBinding.Modifiers(eventFlags: .maskCommand) == .command)
        #expect(KeyBinding.Modifiers(eventFlags: .maskAlternate) == .option)
        #expect(KeyBinding.Modifiers(eventFlags: .maskControl) == .control)
        #expect(KeyBinding.Modifiers(eventFlags: .maskShift) == .shift)
        #expect(KeyBinding.Modifiers(eventFlags: [.maskCommand, .maskAlternate, .maskControl, .maskShift]) == [.command, .option, .control, .shift])
    }

    @Test func bareTabMatchesOnlyBareTab() {
        #expect(KeyBinding.tab.matches(keyCode: 48, flags: flags()))
        #expect(!KeyBinding.tab.matches(keyCode: 48, flags: flags(.maskShift)))
        #expect(!KeyBinding.tab.matches(keyCode: 48, flags: flags(.maskAlternate)))
        #expect(!KeyBinding.tab.matches(keyCode: 48, flags: flags(.maskCommand)))
        #expect(!KeyBinding.tab.matches(keyCode: 50, flags: flags()))
    }

    @Test func hotkeysNeedTheirExactModifiers() {
        #expect(KeyBinding.forceActivate.matches(keyCode: 50, flags: flags(.maskControl)))
        #expect(!KeyBinding.forceActivate.matches(keyCode: 50, flags: flags(.maskControl, .maskShift)))
        #expect(KeyBinding.pauseInApp.matches(keyCode: 50, flags: flags(.maskControl, .maskAlternate, .maskCommand)))
        #expect(!KeyBinding.pauseInApp.matches(keyCode: 50, flags: flags(.maskControl, .maskAlternate)))
    }
}

@Suite struct Classification {
    @Test func acceptKeysAreSwallowedOnlyWhileAGhostIsVisible() {
        #expect(once(48, flags(), "\t") == .swallow(.accept(.word)))
        #expect(once(50, flags(), "`") == .swallow(.accept(.all)))
        #expect(once(48, flags(), "\t", state: hidden) == .pass(.editing))
        #expect(once(50, flags(), "`", state: hidden) == .pass(.typed("`")))
    }

    @Test func modifiedTabPassesThrough() {
        // Option-Tab is the documented way to send a real Tab.
        #expect(once(48, flags(.maskAlternate), "\t") == .pass(.editing))
        #expect(once(48, flags(.maskShift), "\u{19}") == .pass(.editing))
        #expect(once(48, flags(.maskCommand), "\t") == .pass(.editing))
    }

    @Test func escapeDismissesOnlyWhenEnabledAndVisible() {
        #expect(once(53, flags(), "\u{1B}") == .swallow(.dismiss))
        #expect(once(53, flags(), "\u{1B}", state: hidden) == .pass(.editing))
        var noDismiss = visible
        noDismiss.dismissWithEscape = false
        #expect(once(53, flags(), "\u{1B}", state: noDismiss) == .pass(.editing))
        #expect(once(53, flags(.maskShift), "\u{1B}") == .pass(.editing))
    }

    @Test func hotkeysAreAlwaysSwallowed() {
        #expect(once(50, flags(.maskControl), "`", state: hidden) == .swallow(.hotkey(.forceActivate)))
        #expect(once(50, flags(.maskControl, .maskAlternate, .maskCommand), "`", state: hidden) == .swallow(.hotkey(.pauseInApp)))
        #expect(once(50, flags(.maskControl), "`") == .swallow(.hotkey(.forceActivate)))
    }

    @Test func unboundStateSwallowsNothing() {
        let empty = InterceptState(ghostVisible: true)
        for keyCode: UInt16 in [48, 50, 53] {
            #expect(once(keyCode, flags(), "x", state: empty).swallow == false)
        }
    }

    @Test func printableTextIsTyped() {
        #expect(once(0, flags(), "a") == .pass(.typed("a")))
        #expect(once(0, flags(.maskShift), "A") == .pass(.typed("A")))
        #expect(once(49, flags(), " ") == .pass(.typed(" ")))
        #expect(once(31, flags(.maskAlternate), "ø") == .pass(.typed("ø")))
        #expect(once(18, flags(.maskShift, .maskAlphaShift), "!") == .pass(.typed("!")))
        #expect(once(83, flags(.maskNumericPad), "1") == .pass(.typed("1")))
        #expect(once(0, flags(), "👍🏽") == .pass(.typed("👍🏽")))
    }

    @Test func editingKeysAndShortcutsAreEditing() {
        let cases: [(UInt16, CGEventFlags, String)] = [
            (51, flags(), "\u{7F}"),           // backspace
            (117, flags(.maskSecondaryFn), "\u{F728}"), // forward delete
            (36, flags(), "\r"),               // return
            (76, flags(.maskNumericPad), "\u{3}"), // keypad enter
            (123, flags(.maskNumericPad, .maskSecondaryFn), "\u{F702}"), // left arrow
            (126, flags(.maskShift, .maskNumericPad, .maskSecondaryFn), "\u{F700}"),
            (115, flags(.maskSecondaryFn), "\u{F729}"), // home
            (122, flags(.maskSecondaryFn), "\u{F704}"), // F1
            (0, flags(.maskCommand), "a"),     // Cmd-A
            (8, flags(.maskControl), "\u{3}"), // Ctrl-C
            (9, flags(.maskCommand, .maskShift), "v"),
        ]
        for (keyCode, eventFlags, chars) in cases {
            #expect(once(keyCode, eventFlags, chars) == .pass(.editing), "keyCode \(keyCode)")
        }
    }

    @Test func emptyControlAndPrivateUseCharactersAreNotText() {
        #expect(KeyInterceptor.printableText("") == nil)
        #expect(KeyInterceptor.printableText("\u{1B}") == nil)
        #expect(KeyInterceptor.printableText("\u{7F}") == nil)
        #expect(KeyInterceptor.printableText("\u{85}") == nil)
        #expect(KeyInterceptor.printableText("\u{F70F}") == nil)
        #expect(KeyInterceptor.printableText("a\u{F700}") == nil)
        #expect(KeyInterceptor.printableText("é") == "é")
        // An unknown key that produces a private-use character is editing, not text.
        #expect(once(10, flags(), "\u{F8FF}") == .pass(.editing))
    }
}

@Suite struct RepeatsAndKeyUps {
    @Test func holdingTabKeepsAcceptingWords() {
        let h = Harness()
        #expect(h.down(48, flags(), "\t") == .swallow(.accept(.word)))
        #expect(h.down(48, flags(), "\t", repeat: true) == .swallow(.acceptRepeat))
        // The suggestion ran out while Tab is held: keep swallowing instead of typing tabs.
        #expect(h.down(48, flags(), "\t", repeat: true, state: hidden) == .swallow(nil))
        #expect(h.up(48))
        #expect(!h.up(48))
    }

    @Test func acceptAllDoesNotFireOnRepeat() {
        let h = Harness()
        #expect(h.down(50, flags(), "`") == .swallow(.accept(.all)))
        #expect(h.down(50, flags(), "`", repeat: true) == .swallow(nil))
        #expect(h.down(50, flags(), "`", repeat: true, state: hidden) == .swallow(nil))
        #expect(h.up(50))
    }

    @Test func hotkeyAndEscapeFireOnce() {
        let h = Harness()
        #expect(h.down(50, flags(.maskControl), "`", state: hidden) == .swallow(.hotkey(.forceActivate)))
        #expect(h.down(50, flags(.maskControl), "`", repeat: true, state: hidden) == .swallow(nil))
        #expect(h.down(53, flags(), "\u{1B}") == .swallow(.dismiss))
        #expect(h.down(53, flags(), "\u{1B}", repeat: true, state: hidden) == .swallow(nil))
    }

    @Test func repeatsOfAKeyTheAppGotKeepGoingToTheApp() {
        let h = Harness()
        // Tab held before any ghost appeared: the app got the press, so it gets the repeats too.
        #expect(h.down(48, flags(), "\t", state: hidden) == .pass(.editing))
        #expect(h.down(48, flags(), "\t", repeat: true) == .pass(.editing))
        #expect(!h.up(48))
        #expect(h.down(0, flags(), "a", repeat: true) == .pass(.typed("a")))
    }

    @Test func aStaleHeldKeyHealsOnTheNextPress() {
        let h = Harness()
        _ = h.down(48, flags(), "\t") // keyUp lost
        #expect(h.down(48, flags(), "\t", state: hidden) == .pass(.editing))
        #expect(!h.up(48))
    }

    @Test func onlySwallowedKeysHaveTheirKeyUpSwallowed() {
        let h = Harness()
        _ = h.down(0, flags(), "a")
        _ = h.down(48, flags(), "\t")
        #expect(!h.up(0))
        #expect(h.up(48))
        #expect(h.interceptor.held.isEmpty)
    }
}

@Suite struct InterceptStateFromSettings {
    @Test func usesTheSettingsBindings() {
        var settings = TabberSettings()
        let state = InterceptState(settings: settings, ghostVisible: true)
        #expect(state.acceptWord == .tab)
        #expect(state.acceptAll == .keyAboveTab)
        #expect(state.dismissWithEscape)
        #expect(state.hotkeys == [.forceActivate: .forceActivate, .pauseInApp: .pauseInApp])

        settings.escapeBehavior = .passThrough
        settings.pauseInAppKey = nil
        let other = InterceptState(settings: settings, ghostVisible: false)
        #expect(!other.dismissWithEscape)
        #expect(other.hotkeys == [.forceActivate: .forceActivate])
    }
}

@Suite struct AlternativePickTests {
    @Test func digitsPickOnlyWhileShown() {
        var state = InterceptState()
        #expect(KeyInterceptor.alternativePick(characters: "2", modifiers: [], state: state) == nil)
        state.alternativesShown = 3
        #expect(KeyInterceptor.alternativePick(characters: "2", modifiers: [], state: state) == .pickAlternative(2))
        #expect(KeyInterceptor.alternativePick(characters: "4", modifiers: [], state: state) == nil)
        #expect(KeyInterceptor.alternativePick(characters: "2", modifiers: .command, state: state) == nil)
        #expect(KeyInterceptor.alternativePick(characters: "a", modifiers: [], state: state) == nil)
    }
}
