import Foundation
import Observation
import PTTSupport

/// Immutable view of the settings, safe to hand to actors.
///
/// Background work (capture, inference, insertion) reads a snapshot taken at the moment a
/// dictation starts. That guarantees a single dictation runs with one consistent
/// configuration even if the user changes a preference while holding the key, and it keeps
/// `UserDefaults` access on the main actor where it belongs.
public struct SettingsSnapshot: Sendable, Equatable {
    public var hotkey: HotkeyBinding
    public var model: WhisperModel
    public var language: Language
    public var streamingEnabled: Bool
    public var keepModelLoaded: Bool
    public var preferAccessibilityInsertion: Bool
    public var capitalizeFirstLetter: Bool
    public var appendTrailingSpace: Bool
    public var playFeedbackSounds: Bool
    public var showHUD: Bool
}

/// The app's preferences, observable by SwiftUI and persisted in `UserDefaults`.
///
/// Every property is a computed accessor over a typed key so that reads stay cheap and
/// writes stay in one place. `@Observable` gives per-property change tracking, so opening
/// the menu does not invalidate views that did not change.
@MainActor
@Observable
public final class SettingsStore {

    private let defaults: UserDefaults

    /// - Parameter defaults: injected so tests can run against an isolated suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    // MARK: Keys

    private enum Key {
        static let hotkey = "hotkey"
        static let model = "model"
        static let language = "language"
        static let streaming = "streamingEnabled"
        static let keepModelLoaded = "keepModelLoaded"
        static let preferAX = "preferAccessibilityInsertion"
        static let capitalize = "capitalizeFirstLetter"
        static let trailingSpace = "appendTrailingSpace"
        static let sounds = "playFeedbackSounds"
        static let showHUD = "showHUD"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.model: WhisperModel.default.rawValue,
            Key.language: Language.english.rawValue,
            Key.streaming: true,
            Key.keepModelLoaded: true,
            Key.preferAX: true,
            Key.capitalize: true,
            Key.trailingSpace: true,
            Key.sounds: false,
            Key.showHUD: true,
            Key.hasCompletedOnboarding: false,
        ])
    }

    // MARK: Hotkey

    /// The global push-to-talk combination. Invalid bindings (no modifier) are rejected on
    /// write, so a corrupted defaults file cannot leave the app with an unusable shortcut.
    public var hotkey: HotkeyBinding {
        get {
            guard let data = defaults.data(forKey: Key.hotkey),
                  let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data),
                  binding.isValid
            else { return .default }
            return binding
        }
        set {
            guard newValue.isValid else {
                Log.settings.error("Refusing to store modifier-less hotkey \(newValue.keyCode)")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.hotkey)
        }
    }

    // MARK: Speech

    /// Active model. Switching to an English-only model also pins the language to English,
    /// because any other choice would silently produce English anyway.
    public var model: WhisperModel {
        get { WhisperModel(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .default }
        set {
            defaults.set(newValue.rawValue, forKey: Key.model)
            if newValue.isEnglishOnly { language = .english }
        }
    }

    /// Transcription language. Selecting a non-English language while an English-only model
    /// is active upgrades the model to its multilingual counterpart rather than failing
    /// quietly at inference time.
    public var language: Language {
        get { Language(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english }
        set {
            if newValue != .english, model.isEnglishOnly {
                defaults.set(model.multilingualCounterpart.rawValue, forKey: Key.model)
            }
            defaults.set(newValue.rawValue, forKey: Key.language)
        }
    }

    /// Transcribe finished chunks while the key is still held, so only the tail remains to
    /// process on release.
    public var streamingEnabled: Bool {
        get { defaults.bool(forKey: Key.streaming) }
        set { defaults.set(newValue, forKey: Key.streaming) }
    }

    /// Keep the whisper context in memory between dictations. Costs the model's footprint
    /// while idle, saves roughly a second on every dictation after the first.
    public var keepModelLoaded: Bool {
        get { defaults.bool(forKey: Key.keepModelLoaded) }
        set { defaults.set(newValue, forKey: Key.keepModelLoaded) }
    }

    // MARK: Insertion

    /// Try the Accessibility path before falling back to the clipboard.
    public var preferAccessibilityInsertion: Bool {
        get { defaults.bool(forKey: Key.preferAX) }
        set { defaults.set(newValue, forKey: Key.preferAX) }
    }

    public var capitalizeFirstLetter: Bool {
        get { defaults.bool(forKey: Key.capitalize) }
        set { defaults.set(newValue, forKey: Key.capitalize) }
    }

    public var appendTrailingSpace: Bool {
        get { defaults.bool(forKey: Key.trailingSpace) }
        set { defaults.set(newValue, forKey: Key.trailingSpace) }
    }

    // MARK: Feedback

    public var playFeedbackSounds: Bool {
        get { defaults.bool(forKey: Key.sounds) }
        set { defaults.set(newValue, forKey: Key.sounds) }
    }

    public var showHUD: Bool {
        get { defaults.bool(forKey: Key.showHUD) }
        set { defaults.set(newValue, forKey: Key.showHUD) }
    }

    /// Set once the permissions walkthrough has been shown, so it never reappears.
    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: Snapshot

    /// Consistent, `Sendable` copy for background work.
    public var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            hotkey: hotkey,
            model: model,
            language: language,
            streamingEnabled: streamingEnabled,
            keepModelLoaded: keepModelLoaded,
            preferAccessibilityInsertion: preferAccessibilityInsertion,
            capitalizeFirstLetter: capitalizeFirstLetter,
            appendTrailingSpace: appendTrailingSpace,
            playFeedbackSounds: playFeedbackSounds,
            showHUD: showHUD
        )
    }
}
