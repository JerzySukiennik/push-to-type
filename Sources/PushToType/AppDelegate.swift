import AppKit
import PTTAudio
import PTTHotkeys
import PTTInsertion
import PTTRefine
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
    private let hotkeys = HotkeyRouter()

    private var controller: DictationController!
    private var menuBar: MenuBarController!
    private var windows: WindowPresenter!
    private var viewModel: SettingsViewModel!

    /// Cached for the menu; refreshed when the menu is about to open.
    private var downloadedModelsCache: Set<WhisperModel> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one instance may run. Two would each register the global shortcuts and each
        // process the same dictation — the transcript gets inserted twice, overlapping into
        // nonsense. This is not hypothetical: a stale copy surviving a reinstall did exactly
        // that. The newest launch wins, so a fresh build or a click always takes over.
        Self.terminateOtherInstances()

        // A menu bar utility: no Dock icon, no app menu, no window on launch.
        NSApp.setActivationPolicy(.accessory)

        // Without a main menu, an LSUIElement app's text fields do not respond to ⌘X/⌘C/⌘V
        // /⌘A: those shortcuts are routed through the Edit menu, and there was none. The
        // menu is invisible while the app is an accessory, and appears at the top only when
        // a window is open — which is exactly when the shortcuts are wanted.
        NSApp.mainMenu = Self.makeMainMenu()

        // The refiner reads the model and key on demand, so both take effect on the next
        // dictation without rebuilding anything.
        let refiner = GeminiRefiner(
            modelProvider: { SettingsStore.currentGeminiModel() }
        )

        controller = DictationController(
            settings: settings,
            recorder: recorder,
            engine: engine,
            models: models,
            inserter: inserter,
            hud: hud,
            refiner: refiner
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
        hotkeys.unregisterAll()
        controller.shutDown()
    }

    /// Clicking the app in Finder while it is already running opens Settings rather than
    /// doing nothing, which is what users expect from a menu bar app with no windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showSettings()
        return true
    }

    // MARK: - Single instance

    /// Terminates any other running copy of PushToType, so exactly one is live.
    ///
    /// Matched by bundle identifier, which every copy shares regardless of the path it was
    /// launched from — the case that bit us, where a copy left over from `build/` kept
    /// running alongside the one in `/Applications`. `forceTerminate` because the other
    /// instance is a background agent with nothing to save.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard !others.isEmpty else { return }
        Log.app.info("Terminating \(others.count) other instance(s)")
        for app in others { app.forceTerminate() }
    }

    // MARK: - Menu

    /// The minimal main menu that makes standard editing shortcuts work.
    ///
    /// An app menu is required as the first item — macOS treats it specially — but it can
    /// be almost empty. The Edit menu is the point: its items wire ⌘X/⌘C/⌘V/⌘A to the
    /// first responder, so a text field finally accepts a paste.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit PushToType",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu

        return mainMenu
    }

    // MARK: - Wiring

    private func bindHotkey() {
        // The router hands back a mode id; the controller is driven by the matching mode.
        hotkeys.onPress = { [weak self] modeID in
            guard let self, let mode = self.mode(for: modeID) else { return }
            self.controller.hotkeyPressed(mode: mode)
        }
        hotkeys.onRelease = { [weak self] modeID in
            self?.controller.hotkeyReleased(modeID: modeID)
        }
        hotkeys.onCancel = { [weak self] modeID in
            // The hold was a shortcut or a brush of the hand, not speech.
            self?.controller.cancelDictation(modeID: modeID)
        }
        registerModes()

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
                self?.registerModes()
            }
        }
    }

    /// Registers every active mode's shortcut with the router.
    ///
    /// Called on launch, on activation (to pick up a fresh Accessibility grant), and
    /// whenever the modes change in Settings. Any shortcut the router could not claim is
    /// flashed once so the user knows a mode is not listening.
    func registerModes() {
        let bindings = settings.modes.compactMap { mode -> HotkeyRouter.Binding? in
            guard let hotkey = mode.hotkey, hotkey.isValid else { return nil }
            return HotkeyRouter.Binding(modeID: mode.id, hotkey: hotkey)
        }
        let rejected = hotkeys.setBindings(bindings)
        if let clash = rejected.first {
            hud.flash(.failed(.hotkeyRegistrationFailed(status: -1)), for: .seconds(3))
            Log.app.error("Shortcut unavailable: \(clash, privacy: .public)")
        }
    }

    /// Finds the mode a router callback refers to.
    private func mode(for id: String) -> DictationMode? {
        settings.modes.first { $0.id == id }
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
            onModesChanged: { [weak self] in
                self?.registerModes()
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
            },
            apiKeyState: { APIKeyStore.hasKey },
            saveAPIKey: { key in APIKeyStore.setGeminiKey(key) }
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
