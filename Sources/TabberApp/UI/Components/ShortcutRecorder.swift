import AppKit
import Carbon.HIToolbox
import SwiftUI
import TabberCore

/// Click, then press a key combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var binding: KeyBinding?
    /// Hotkeys that work everywhere need ⌃, ⌥ or ⌘ so they don't swallow normal typing.
    var requiresModifier = false

    @EnvironmentObject private var state: AppState
    @State private var recording = false
    @State private var liveModifiers: KeyBinding.Modifiers = []
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    @State private var shake: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                label
                    .frame(minWidth: 92)
                    .frame(height: 22)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(recording ? 0.04 : (hovering ? 0.09 : 0.06)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(recording ? 1 : 0), lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .modifier(ShakeEffect(travel: shake))
            .accessibilityLabel(binding.map { "Shortcut \(KeyGlyphs.string($0))" } ?? "No shortcut")
            .accessibilityHint("Click, then press the keys to use")

            Button {
                binding = nil
            } label: {
                Icon(.x, size: 11, weight: 2.5)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear shortcut")
            .accessibilityLabel("Clear shortcut")
            .opacity(binding != nil && !recording ? 1 : 0)
            .disabled(binding == nil || recording)
        }
        .animation(.easeOut(duration: 0.15), value: recording)
        .onDisappear(perform: stop)
    }

    @ViewBuilder
    private var label: some View {
        if recording {
            Text(liveModifiers.isEmpty ? "Type shortcut" : KeyGlyphs.modifiers(liveModifiers))
                .font(.system(size: 12, weight: liveModifiers.isEmpty ? .regular : .medium))
                .foregroundStyle(liveModifiers.isEmpty ? .secondary : .primary)
        } else if let binding {
            KeyComboText(parts: KeyGlyphs.parts(binding))
        } else {
            Text("Not set")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        liveModifiers = []
        state.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let swallow = MainActor.assumeIsolated { handle(event) }
            return swallow ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        if recording { state.isRecordingShortcut = false }
        recording = false
        liveModifiers = []
    }

    /// Returns true when the event was used by the recorder.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = KeyBinding.Modifiers(flags)
        switch event.type {
        case .flagsChanged:
            liveModifiers = modifiers
            return true
        case .keyDown:
            let code = Int(event.keyCode)
            if modifiers.isEmpty, code == kVK_Escape {
                stop()
                return true
            }
            if modifiers.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
                binding = nil
                stop()
                return true
            }
            let reservedBypass = code == kVK_Tab && modifiers == .option
            let missingModifier = requiresModifier && modifiers.subtracting(.shift).isEmpty
            if reservedBypass || missingModifier {
                reject()
                return true
            }
            binding = KeyBinding(keyCode: event.keyCode, modifiers: modifiers)
            stop()
            return true
        default:
            return false
        }
    }

    private func reject() {
        NSSound.beep()
        withAnimation(.linear(duration: 0.3)) { shake += 1 }
    }
}

/// A short horizontal shake, for a rejected shortcut.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(travel * .pi * 4), y: 0))
    }
}

/// Key glyphs in a row, with small marks (` ^ ´) enlarged so they read at a glance.
struct KeyComboText: View {
    let parts: [String]
    var fontSize: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                let small = KeyGlyphs.isSmallMark(part)
                Text(part)
                    .font(.system(size: small ? fontSize * 1.35 : fontSize, weight: small ? .semibold : .medium, design: small ? .monospaced : .rounded))
                    .baselineOffset(small ? -fontSize * 0.3 : 0)
            }
        }
        .foregroundStyle(.primary)
    }
}
