import Foundation

/// A global key combination, stored in the units Carbon's `RegisterEventHotKey` expects.
///
/// The type lives in `PTTSettings` rather than `PTTHotkeys` because both the settings UI
/// and the hotkey monitor need it, and neither should depend on the other. It is a plain
/// `Sendable` value type, so it can cross actor boundaries without ceremony.
public struct HotkeyBinding: Codable, Equatable, Sendable {

    /// Virtual key code (`kVK_*`), independent of the active keyboard layout.
    public var keyCode: UInt32

    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘T — the documented default.
    public static let `default` = HotkeyBinding(keyCode: KeyCode.t, modifiers: .command)

    /// A binding is only usable globally if it carries at least one modifier; otherwise
    /// it would swallow a bare key press in every app on the system.
    public var isValid: Bool { !modifiers.isEmpty }

    // MARK: Modifiers

    /// Carbon modifier flags. Raw values match `<Carbon/Events.h>` so the mask can be
    /// handed to `RegisterEventHotKey` unchanged.
    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 0x0100)  // cmdKey
        public static let shift = Modifiers(rawValue: 0x0200)    // shiftKey
        public static let option = Modifiers(rawValue: 0x0800)   // optionKey
        public static let control = Modifiers(rawValue: 0x1000)  // controlKey

        /// Symbols in the order macOS uses in menus: ⌃⌥⇧⌘.
        var symbols: String {
            var out = ""
            if contains(.control) { out += "⌃" }
            if contains(.option) { out += "⌥" }
            if contains(.shift) { out += "⇧" }
            if contains(.command) { out += "⌘" }
            return out
        }
    }

    // MARK: Display

    /// Menu-style representation, e.g. `⌘T` or `⌃⌥Space`.
    public var displayString: String {
        modifiers.symbols + KeyCode.displayName(for: keyCode)
    }
}

/// The subset of `kVK_*` constants the app names directly, plus a display table.
///
/// Duplicating the constants here keeps `PTTSettings` free of a Carbon import; the values
/// are fixed hardware codes that have not changed since the ADB era.
public enum KeyCode {
    public static let t: UInt32 = 0x11
    public static let space: UInt32 = 0x31
    public static let escape: UInt32 = 0x35
    public static let `return`: UInt32 = 0x24
    public static let tab: UInt32 = 0x30
    public static let delete: UInt32 = 0x33

    /// Layout-independent label for a virtual key code.
    ///
    /// Letters and digits are resolved through the current keyboard layout so a Polish or
    /// Dvorak user sees the key they actually press; everything else uses a fixed table.
    public static func displayName(for keyCode: UInt32) -> String {
        if let special = specialNames[keyCode] { return special }
        if let character = LayoutTranslator.character(for: keyCode) { return character }
        return "Key \(keyCode)"
    }

    private static let specialNames: [UInt32: String] = [
        0x31: "Space",
        0x35: "⎋",
        0x24: "↩",
        0x30: "⇥",
        0x33: "⌫",
        0x75: "⌦",
        0x7B: "←",
        0x7C: "→",
        0x7D: "↓",
        0x7E: "↑",
        0x73: "Home",
        0x77: "End",
        0x74: "Page Up",
        0x79: "Page Down",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]
}
