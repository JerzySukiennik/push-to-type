import AppKit
import PTTSettings
import PTTSupport

/// Everything the menu can ask the app to do.
///
/// A protocol rather than a pile of closures: it keeps the wiring in one readable place in
/// the composition root and makes the menu's dependencies explicit.
@MainActor
public protocol MenuBarControllerDelegate: AnyObject {
    func menuBar(didSelect model: WhisperModel)
    func menuBar(didSelect language: Language)
    func menuBarDidToggleLaunchAtLogin()
    func menuBarDidRequestSettings()
    func menuBarDidRequestUpdateCheck()
    func menuBarDidRequestQuit()

    /// Reflected as a checkmark; read only when the menu opens.
    var isLaunchAtLoginEnabled: Bool { get }
    /// Drives the header line and the model checkmarks.
    var currentSettings: SettingsSnapshot { get }
    /// Models present on disk, so the menu can mark what still needs downloading.
    var downloadedModels: Set<WhisperModel> { get }
}

/// The status bar item and its menu.
///
/// The menu is rebuilt in `menuNeedsUpdate(_:)`, i.e. only when it is about to be shown.
/// Nothing observes settings while the menu is closed, which is what keeps a background
/// app at zero CPU between dictations.
@MainActor
public final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private weak var delegate: (any MenuBarControllerDelegate)?

    private var phase: DictationPhase = .idle

    public init(delegate: any MenuBarControllerDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("PushToType")
        apply(phase: .idle)
    }

    deinit {
        // The status item must be removed explicitly or its slot stays reserved.
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    /// Updates the menu bar glyph. Called on every state change; cheap because it only
    /// swaps an image.
    public func apply(phase: DictationPhase) {
        self.phase = phase
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: phase.menuBarSymbol,
            accessibilityDescription: phase.hudText.isEmpty ? "PushToType" : phase.hudText
        )
        button.image?.isTemplate = true
    }

    // MARK: - Actions

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? WhisperModel else { return }
        delegate?.menuBar(didSelect: model)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? Language else { return }
        delegate?.menuBar(didSelect: language)
    }

    @objc private func toggleLaunchAtLogin() {
        delegate?.menuBarDidToggleLaunchAtLogin()
    }

    @objc private func openSettings() {
        delegate?.menuBarDidRequestSettings()
    }

    @objc private func checkForUpdates() {
        delegate?.menuBarDidRequestUpdateCheck()
    }

    @objc private func quit() {
        delegate?.menuBarDidRequestQuit()
    }
}

// MARK: - Menu construction

extension MenuBarController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard let delegate else { return }
        let settings = delegate.currentSettings
        let downloaded = delegate.downloadedModels

        menu.removeAllItems()

        menu.addItem(header(for: settings))
        menu.addItem(.separator())

        menu.addItem(languageItem(settings: settings))
        menu.addItem(modelItem(settings: settings, downloaded: downloaded))
        menu.addItem(hotkeyItem(settings: settings))
        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = delegate.isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit PushToType",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Status line: what the app is doing, or how to make it do something.
    private func header(for settings: SettingsSnapshot) -> NSMenuItem {
        let title: String
        switch phase {
        case .idle, .inserted, .limitReached:
            title = "Hold \(settings.hotkey.displayString) to dictate"
        case .listening:
            title = "Listening…"
        case .transcribing:
            title = "Transcribing…"
        case .refining(let mode):
            title = "\(mode)…"
        case .downloading(let model, let progress):
            title = "Downloading \(model) — \(Int(progress * 100))%"
        case .failed(let error):
            title = error.title
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func languageItem(settings: SettingsSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for language in Language.available(for: settings.model) {
            let entry = NSMenuItem(
                title: language.displayName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = language
            entry.state = language == settings.language ? .on : .off
            submenu.addItem(entry)
        }

        if settings.model.isEnglishOnly {
            submenu.addItem(.separator())
            let hint = NSMenuItem(
                title: "Switch to a multilingual model for more",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            submenu.addItem(hint)
        }

        item.submenu = submenu
        return item
    }

    private func modelItem(
        settings: SettingsSnapshot,
        downloaded: Set<WhisperModel>
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for model in WhisperModel.allCases {
            let suffix = downloaded.contains(model) ? "" : "  ⬇︎ \(model.displaySize)"
            let entry = NSMenuItem(
                title: model.displayName + suffix,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = model
            entry.state = model == settings.model ? .on : .off
            entry.toolTip = model.subtitle
            submenu.addItem(entry)
        }

        item.submenu = submenu
        return item
    }

    private func hotkeyItem(settings: SettingsSnapshot) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Hotkey: \(settings.hotkey.displayString)",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }
}
