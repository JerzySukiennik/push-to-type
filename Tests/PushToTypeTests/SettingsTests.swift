import Foundation
import Testing

@testable import PTTSettings

@Suite("Settings")
struct SettingsTests {

    /// A store backed by a throwaway defaults suite, so tests never touch the real app's
    /// preferences.
    @MainActor
    private func makeStore(function: String = #function) -> SettingsStore {
        let suite = "com.gzowo.PushToType.tests.\(function)"
        UserDefaults().removePersistentDomain(forName: suite)
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Defaults are ⌃⌥ held alone, base.en, English")
    @MainActor
    func hasSensibleDefaults() {
        let store = makeStore()
        #expect(store.hotkey == .default)
        #expect(store.hotkey.displayString == "⌃⌥")
        #expect(store.hotkey.isModifierOnly)
        #expect(store.model == .baseEn)
        #expect(store.language == .english)
        #expect(store.streamingEnabled)
    }

    @Test("A modifier-less hotkey is rejected")
    @MainActor
    func rejectsBareKeys() {
        let store = makeStore()
        store.hotkey = HotkeyBinding(keyCode: KeyCode.t, modifiers: [])
        #expect(store.hotkey == .default, "the previous binding must survive")
    }

    @Test("A single modifier held alone is rejected")
    @MainActor
    func rejectsOneModifierAlone() {
        let store = makeStore()
        // ⌥ on its own is part of ordinary typing; accepting it would start a dictation
        // several times a minute.
        store.hotkey = HotkeyBinding(keyCode: nil, modifiers: .option)
        #expect(store.hotkey == .default)

        #expect(HotkeyBinding(keyCode: nil, modifiers: [.control, .option]).isValid)
        #expect(!HotkeyBinding(keyCode: nil, modifiers: .control).isValid)
    }

    @Test("Both shapes survive a round trip through defaults")
    @MainActor
    func persistsBothShapes() {
        let store = makeStore()

        let combination = HotkeyBinding(keyCode: KeyCode.space, modifiers: [.control, .option])
        store.hotkey = combination
        #expect(store.hotkey == combination)
        #expect(!store.hotkey.isModifierOnly)

        let modifiersOnly = HotkeyBinding(keyCode: nil, modifiers: [.command, .shift])
        store.hotkey = modifiersOnly
        #expect(store.hotkey == modifiersOnly)
        #expect(store.hotkey.displayString == "⇧⌘")
    }

    @Test("A key combination is displayed the way a menu would show it")
    func displaysCombination() {
        let binding = HotkeyBinding(keyCode: KeyCode.space, modifiers: [.control, .option])
        #expect(binding.displayString == "⌃⌥Space")
    }

    @Test("Choosing an English-only model pins the language to English")
    @MainActor
    func englishOnlyModelPinsLanguage() {
        let store = makeStore()
        store.model = .base
        store.language = .polish
        #expect(store.language == .polish)

        store.model = .baseEn
        #expect(store.language == .english)
    }

    @Test("Choosing another language upgrades an English-only model")
    @MainActor
    func languageUpgradesModel() {
        let store = makeStore()
        store.model = .baseEn
        store.language = .german
        #expect(store.model == .base, "must switch to the multilingual counterpart")
        #expect(store.language == .german)
    }

    @Test("The snapshot mirrors the live store")
    @MainActor
    func snapshotMatches() {
        let store = makeStore()
        store.streamingEnabled = false
        store.appendTrailingSpace = false

        let snapshot = store.snapshot
        #expect(snapshot.model == store.model)
        #expect(snapshot.hotkey == store.hotkey)
        #expect(!snapshot.streamingEnabled)
        #expect(!snapshot.appendTrailingSpace)
    }

    @Test("Model catalog points at reachable files")
    func modelCatalogIsConsistent() {
        for model in WhisperModel.allCases {
            #expect(model.fileName == "ggml-\(model.rawValue).bin")
            #expect(model.downloadURL.absoluteString.hasSuffix(model.fileName))
            #expect(model.approximateBytes > 0)
            #expect(model.isEnglishOnly == model.rawValue.hasSuffix(".en"))
        }
        #expect(WhisperModel.baseEn.multilingualCounterpart == .base)
        #expect(WhisperModel.base.multilingualCounterpart == .base)
    }

    @Test("English-only models offer only English")
    func languageAvailability() {
        #expect(Language.available(for: .baseEn) == [.english])
        #expect(Language.available(for: .base).count > 1)
        #expect(Language.auto.isAutomatic)
    }
}
