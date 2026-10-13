import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Finds which physical key produces a character in the current keyboard layout.
enum KeyboardLayout {
    /// The key that types `character` while Command is held, so a synthetic Cmd-V is a paste on
    /// Dvorak and other layouts that move V. Nil when no key produces it (non-Latin layouts, where the
    /// system falls back to the ANSI positions for shortcuts anyway).
    ///
    /// Text Input Sources must be called on the main thread.
    static func keyCodeForCommand(_ character: Character) -> CGKeyCode? {
        guard Thread.isMainThread else { return nil }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let target = String(character)
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for keyCode in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), commandState, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                )
                if status == noErr, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return keyCode
                }
            }
            return nil
        }
    }
}
