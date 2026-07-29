import Foundation
import Observation
import PTTSettings
import PTTSupport

/// State and actions behind the Settings window.
///
/// The window itself owns no logic: downloads, hotkey registration and permission prompts
/// all live in the app, and reach the view through these closures. That keeps `PTTUI` free
/// of any dependency on the audio, whisper or hotkey modules.
@MainActor
@Observable
public final class SettingsViewModel {

    /// The store the view reads and writes directly.
    public let settings: SettingsStore

    /// In-flight download progress per model, 0…1.
    public private(set) var downloadProgress: [WhisperModel: Double] = [:]

    /// Models currently on disk.
    public private(set) var downloadedModels: Set<WhisperModel> = []

    /// Last error worth showing inline in the window.
    public private(set) var lastError: PTTError?

    /// Microphone and Accessibility status, refreshed when the window appears.
    public private(set) var isMicrophoneGranted = false
    public private(set) var isAccessibilityGranted = false

    /// `true` when a Gemini API key is stored, so the AI section can show its state.
    public private(set) var hasAPIKey: Bool = false

    // Injected behaviour.
    private let downloadModel: (WhisperModel) async -> Void
    private let deleteModel: (WhisperModel) -> Void
    private let onModesChanged: () -> Void
    private let refreshPermissions: () async -> (microphone: Bool, accessibility: Bool)
    private let requestMicrophone: () async -> Void
    private let requestAccessibility: () -> Void
    private let apiKeyState: () -> Bool
    private let saveAPIKey: (String) -> Void

    public init(
        settings: SettingsStore,
        downloadModel: @escaping (WhisperModel) async -> Void,
        deleteModel: @escaping (WhisperModel) -> Void,
        onModesChanged: @escaping () -> Void,
        refreshPermissions: @escaping () async -> (microphone: Bool, accessibility: Bool),
        requestMicrophone: @escaping () async -> Void,
        requestAccessibility: @escaping () -> Void,
        apiKeyState: @escaping () -> Bool,
        saveAPIKey: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.downloadModel = downloadModel
        self.deleteModel = deleteModel
        self.onModesChanged = onModesChanged
        self.refreshPermissions = refreshPermissions
        self.requestMicrophone = requestMicrophone
        self.requestAccessibility = requestAccessibility
        self.apiKeyState = apiKeyState
        self.saveAPIKey = saveAPIKey
        hasAPIKey = apiKeyState()
    }

    // MARK: - Models

    /// Refreshes what is on disk. Called when the window appears, not on a timer.
    public func refreshModels() {
        downloadedModels = Set(WhisperModel.allCases.filter(\.isDownloaded))
    }

    public func progress(for model: WhisperModel) -> Double? {
        downloadProgress[model]
    }

    public func setProgress(_ value: Double, for model: WhisperModel) {
        downloadProgress[model] = value
    }

    public func clearProgress(for model: WhisperModel) {
        downloadProgress[model] = nil
        refreshModels()
    }

    public func download(_ model: WhisperModel) {
        guard downloadProgress[model] == nil else { return }
        downloadProgress[model] = 0
        Task { await downloadModel(model) }
    }

    public func delete(_ model: WhisperModel) {
        deleteModel(model)
        refreshModels()
    }

    // MARK: - Modes

    /// Persists a changed mode and re-registers every shortcut.
    public func update(_ mode: DictationMode) {
        settings.updateMode(mode)
        onModesChanged()
    }

    /// Sets or clears a mode's shortcut, then re-registers.
    public func setHotkey(_ hotkey: HotkeyBinding?, for mode: DictationMode) {
        var updated = mode
        updated.hotkey = hotkey
        update(updated)
    }

    // MARK: - API key

    /// Stores the key (or clears it when blank) and refreshes the shown state.
    public func saveGeminiKey(_ key: String) {
        saveAPIKey(key)
        hasAPIKey = apiKeyState()
    }

    public func refreshAPIKeyState() {
        hasAPIKey = apiKeyState()
    }

    // MARK: - Permissions

    public func refreshPermissionStatus() async {
        let status = await refreshPermissions()
        isMicrophoneGranted = status.microphone
        isAccessibilityGranted = status.accessibility
    }

    public func askForMicrophone() {
        Task {
            await requestMicrophone()
            await refreshPermissionStatus()
        }
    }

    public func askForAccessibility() {
        requestAccessibility()
    }

    public func report(_ error: PTTError?) {
        lastError = error
    }
}
