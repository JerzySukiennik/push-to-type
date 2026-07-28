import AppKit
import SwiftUI

/// Opens the app's two windows on demand and lets them go when they close.
///
/// A menu bar app has no window by default and should return to that state: each window is
/// built when asked for, and the reference is dropped in `windowWillClose`, so the SwiftUI
/// hierarchy and its observation machinery are deallocated rather than lingering.
///
/// Both windows activate the app while they are open — otherwise the user could not type
/// in them — and the app returns to accessory mode as soon as the last one closes.
@MainActor
public final class WindowPresenter: NSObject {

    private let model: SettingsViewModel
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingCompletion: (() -> Void)?

    public init(model: SettingsViewModel) {
        self.model = model
        super.init()
    }

    // MARK: - Settings

    /// Shows the settings window, or brings it forward if it is already open.
    public func showSettings() {
        if let settingsWindow {
            activate(settingsWindow)
            return
        }

        let window = makeWindow(
            title: "PushToType Settings",
            content: SettingsView(model: model)
        )
        settingsWindow = window
        activate(window)
    }

    // MARK: - Onboarding

    /// Shows the first-run permissions walkthrough.
    ///
    /// - Parameter completion: called when the user dismisses it, so the caller can record
    ///   that onboarding is done.
    public func showOnboarding(completion: @escaping () -> Void) {
        if let onboardingWindow {
            activate(onboardingWindow)
            return
        }
        onboardingCompletion = completion

        let window = makeWindow(
            title: "Welcome to PushToType",
            content: OnboardingView(model: model) { [weak self] in
                self?.closeOnboarding()
            }
        )
        onboardingWindow = window
        activate(window)
    }

    private func closeOnboarding() {
        onboardingWindow?.performClose(nil)
    }

    // MARK: - Plumbing

    private func makeWindow(title: String, content: some View) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension WindowPresenter: NSWindowDelegate {

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === settingsWindow {
            settingsWindow = nil
        }
        if window === onboardingWindow {
            onboardingWindow = nil
            onboardingCompletion?()
            onboardingCompletion = nil
        }

        // Back to a Dock-less background utility once nothing is on screen.
        if settingsWindow == nil, onboardingWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
