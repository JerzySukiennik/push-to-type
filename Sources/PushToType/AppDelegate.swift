import AppKit
import PTTAudio
import PTTHotkeys
import PTTInsertion
import PTTSettings
import PTTSupport
import PTTUI
import PTTWhisper

/// Composition root.
///
/// Everything is constructed here, once, and handed to whoever needs it. Nothing is a
/// singleton and nothing reaches for a global, so the dictation flow can be assembled
/// against stubs in a test without touching this file.
///
/// ## What happens at launch
/// Only three things: build the objects (cheap), put a glyph in the menu bar, and register
/// the hotkey. No model is loaded, no audio device is opened, no window is created, and
/// nothing touches the disk. Everything else is deferred to the first key press.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Long-lived services.
    private let settings = SettingsStore()
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let models = ModelManager()
    private let inserter = TextInsertionService()
    private let hud = HUDController()
    private let hotkeyMonitor: any HotkeyMonitoring = HotkeyMonitor()

    private var controller: DictationController!
    private var menuBar: MenuBarController!
    private var windows: WindowPresenter!
    private var viewModel: SettingsViewModel!

    /// Cached for the menu; refreshed when the menu is about to open.
    private var downloadedModelsCache: Set<WhisperModel> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar utility: no Dock icon, no app menu, no window on launch.
        NSApp.setActivationPolicy(.accessory)

        controller = DictationController(
            settings: settings,
            recorder: recorder,
            engine: engine,
            models: models,
            inserter: inserter,
            hud: hud
        )
        controller.onPhaseChange = { [weak self] phase in
            self?.menuBar.apply(phase: phase)
        }

        viewModel = makeSettingsViewModel()
        windows = WindowPresenter(model: viewModel)
        menuBar = MenuBarController(delegate: self)

        bindHotkey()

        // Deferred so it never delays the first frame of the menu bar item.
        Task { [models] in
            await models.cleanUpScratchFiles()
            await MainActor.run { self.refreshDownloadedModels() }
            await self.startFirstRunIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor.unregister()
        controller.shutDown()
    }

    /// Clicking the app in Finder while it is already running opens Settings rather than
    /// doing nothing, which is what users expect from a menu bar app with no windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showSettings()
        return true
    }

    // MARK: - Wiring

    private func bindHotkey() {
        hotkeyMonitor.onPress = { [weak self] in
            self?.controller.hotkeyPressed()
        }
        hotkeyMonitor.onRelease = { [weak self] in
            self?.controller.hotkeyReleased()
        }
        hotkeyMonitor.onCancel = { [weak self] in
            // The hold was a shortcut or a brush of the hand, not speech.
            self?.controller.cancelDictation()
        }
        register(settings.hotkey)

        // A modifier-only shortcut is invisible until the app is trusted for
        // Accessibility, and macOS gives no notification when that changes. Re-registering
        // on activation is the event-driven way to pick the grant up: the user has just
        // come back from System Settings, which is exactly when it matters.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.hotkey.isModifierOnly else { return }
                self.register(self.settings.hotkey)
            }
        }
    }

    /// Registers a binding, reporting failure through the HUD instead of a modal.
    @discardableResult
    private func register(_ binding: HotkeyBinding) -> Bool {
        do {
            try hotkeyMonitor.register(binding)
            return true
        } catch let error as PTTError {
            Log.app.error("Hotkey registration failed: \(error.message, privacy: .public)")
            hud.flash(.failed(error), for: .seconds(3))
            return false
        } catch {
            return false
        }
    }

    private func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(
            settings: settings,
            downloadModel: { [models, weak self] model in
                do {
                    try await models.download(model) { fraction in
                        Task { @MainActor in self?.viewModel.setProgress(fraction, for: model) }
                    }
                } catch let error as PTTError {
                    await MainActor.run { self?.viewModel.report(error) }
                } catch {
                    await MainActor.run {
                        self?.viewModel.report(
                            .modelDownloadFailed(
                                name: model.displayName,
                                reason: error.localizedDescription
                            )
                        )
                    }
                }
                await MainActor.run {
                    self?.viewModel.clearProgress(for: model)
                    self?.refreshDownloadedModels()
                }
            },
            deleteModel: { [models, engine, weak self] model in
                Task {
                    if await engine.currentModel == model { await engine.unload() }
                    try? await models.delete(model)
                    await MainActor.run { self?.refreshDownloadedModels() }
                }
            },
            applyHotkey: { [weak self] binding in
                self?.register(binding) ?? false
            },
            refreshPermissions: {
                (
                    microphone: MicrophonePermission.status == .granted,
                    accessibility: AccessibilityPermission.isTrusted
                )
            },
            requestMicrophone: {
                if MicrophonePermission.status == .denied {
                    // Once denied, only System Settings can undo it — the prompt will
                    // never appear again.
                    if let url = PTTError.microphoneDenied.settingsURL {
                        await MainActor.run { _ = NSWorkspace.shared.open(url) }
                    }
                } else {
                    await MicrophonePermission.request()
                }
            },
            requestAccessibility: {
                // The prompt only appears once per app version; the deep link is what
                // actually helps on every subsequent attempt.
                if !AccessibilityPermission.requestAccess() {
                    NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
                }
            }
        )
    }

    // MARK: - First run

    /// Shows the permissions walkthrough once, and only if something is missing.
    private func startFirstRunIfNeeded() async {
        guard !settings.hasCompletedOnboarding else { return }

        let needsMicrophone = MicrophonePermission.status != .granted
        let needsAccessibility = !AccessibilityPermission.isTrusted
        guard needsMicrophone || needsAccessibility else {
            settings.hasCompletedOnboarding = true
            return
        }

        windows.showOnboarding { [weak self] in
            self?.settings.hasCompletedOnboarding = true
        }
    }

    private func refreshDownloadedModels() {
        downloadedModelsCache = Set(WhisperModel.allCases.filter(\.isDownloaded))
        viewModel.refreshModels()
    }
}

// MARK: - Menu actions

extension AppDelegate: MenuBarControllerDelegate {

    var isLaunchAtLoginEnabled: Bool { LoginItemManager.isEnabled }

    var currentSettings: SettingsSnapshot { settings.snapshot }

    var downloadedModels: Set<WhisperModel> { downloadedModelsCache }

    func menuBar(didSelect model: WhisperModel) {
        settings.model = model
        // Fetch it now rather than at the next key press, so the first dictation with a
        // newly chosen model is not a surprise wait.
        if !model.isDownloaded {
            viewModel.download(model)
            windows.showSettings()
        } else {
            Task { try? await engine.load(model) }
        }
    }

    func menuBar(didSelect language: Language) {
        settings.language = language
    }

    func menuBarDidToggleLaunchAtLogin() {
        LoginItemManager.toggle()
    }

    func menuBarDidRequestSettings() {
        windows.showSettings()
    }

    func menuBarDidRequestUpdateCheck() {
        // Placeholder, as specified: PushToType ships no updater yet. Saying so plainly
        // beats a button that silently does nothing.
        let alert = NSAlert()
        alert.messageText = "You are up to date"
        alert.informativeText = """
            PushToType \(Bundle.main.shortVersion) does not check for updates yet. \
            Automatic updates will arrive in a future version.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    func menuBarDidRequestQuit() {
        NSApp.terminate(nil)
    }
}

extension Bundle {
    /// Marketing version, with a sane fallback when running outside a bundle.
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
