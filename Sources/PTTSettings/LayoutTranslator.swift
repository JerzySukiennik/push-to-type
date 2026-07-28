import Carbon.HIToolbox
import Foundation

/// Turns a virtual key code into the character the *current* keyboard layout produces.
///
/// Only used to label the hotkey in menus and in the recorder field. The hotkey itself is
/// always registered by key code, so changing layouts moves the label, not the shortcut —
/// which is the same behaviour as system menu items.
enum LayoutTranslator {

    /// Uppercased character for `keyCode` with no modifiers applied, or `nil` when the key
    /// produces no printable output (function keys, dead keys, media keys).
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue()
        else { return nil }

        guard let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0

            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,  // no modifiers: we want the key's own label
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )

            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}
