import Foundation

/// One way of dictating: a shortcut, a name, and — optionally — an instruction that a
/// language model applies to the transcript before it is inserted.
///
/// The raw, offline dictation everything started with is just a mode whose
/// ``refinementPrompt`` is empty: nothing is sent anywhere and the transcript is inserted
/// verbatim. A mode *with* a prompt sends the transcript and the prompt to the refiner and
/// inserts what comes back. Unifying the two means the whole pipeline — hotkey → record →
/// transcribe → (refine) → insert — has exactly one shape, and "raw" is not a special case
/// threaded through it but the default value of one field.
public struct DictationMode: Codable, Equatable, Sendable, Identifiable {

    /// Stable identity, kept across renames and prompt edits so a mode's key material and
    /// registered hotkey survive the user changing its label.
    public let id: String

    /// Shown in the HUD and the settings list.
    public var name: String

    /// The shortcut that starts this mode, or `nil` for a mode with no shortcut yet.
    public var hotkey: HotkeyBinding?

    /// The instruction handed to the language model, or empty for raw offline dictation.
    ///
    /// Empty is meaningful, not missing: it is what keeps the default mode fully offline.
    public var refinementPrompt: String

    public init(id: String, name: String, hotkey: HotkeyBinding?, refinementPrompt: String) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.refinementPrompt = refinementPrompt
    }

    /// `true` when this mode sends the transcript to the refiner.
    public var isRefined: Bool {
        !refinementPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `true` when the mode can actually be triggered.
    public var isActive: Bool {
        hotkey?.isValid ?? false
    }

    // MARK: - Defaults

    /// Stable id of the built-in raw mode, so it can be found and kept in sync with the
    /// user's primary shortcut.
    public static let rawModeID = "raw"

    /// The modes a fresh install starts with.
    ///
    /// Raw is ⌃⌥ held alone — the same default the app always had, and fully offline. The
    /// two AI modes come pre-bound to ⌃⌥P and ⌃⌥M, which is what the user asked for. Until
    /// a Gemini key is entered they fire an honest "no API key" message rather than doing
    /// anything, so the shortcuts are ready the moment the key is.
    public static let defaults: [DictationMode] = [
        DictationMode(
            id: rawModeID,
            name: "Raw",
            hotkey: .default,
            refinementPrompt: ""
        ),
        DictationMode(
            id: "prompt",
            name: "Prompt",
            hotkey: HotkeyBinding(keyCode: KeyCode.p, modifiers: [.control, .option]),
            refinementPrompt: """
                Przepisz poniższy tekst jako zwięzły, precyzyjny prompt do modelu AI. \
                Usuń wahanie i dygresje, zostaw samą treść polecenia. Zachowaj język \
                oryginału.
                """
        ),
        DictationMode(
            id: "message",
            name: "Wiadomość",
            hotkey: HotkeyBinding(keyCode: KeyCode.m, modifiers: [.control, .option]),
            refinementPrompt: """
                Przepisz poniższy tekst jako naturalną, uprzejmą wiadomość. Popraw \
                interpunkcję i płynność, nie zmieniaj sensu ani tonu. Zachowaj język \
                oryginału.
                """
        ),
    ]
}
