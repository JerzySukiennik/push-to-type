import AppKit
import PTTSupport
import SwiftUI

/// Shows and hides the floating status pill.
///
/// ## Why the panel is created and destroyed each time
/// An idle background app should own no windows: a retained `NSPanel` keeps a window
/// server connection, a backing store and a SwiftUI hosting view alive for something the
/// user sees for two seconds at a time. Creating the panel costs well under a millisecond,
/// which is invisible next to the audio engine start that happens alongside it.
///
/// ## Why it never steals focus
/// `NSPanel` with `.nonactivatingPanel`, `ignoresMouseEvents`, and no key/main status: the
/// user is dictating *into another app*, and anything that moved focus would defeat the
/// entire purpose.
@MainActor
public final class HUDController {

    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.16

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?
    private var dismissTask: Task<Void, Never>?

    /// Set by the owner; when `false` the controller does nothing at all.
    public var isEnabled: Bool = true

    public init() {}

    /// Shows `phase`, creating the panel if necessary, and cancels any pending auto-hide.
    public func show(_ phase: DictationPhase) {
        guard isEnabled else { return }
        dismissTask?.cancel()
        dismissTask = nil

        let view = HUDView(phase: phase)

        if let hostingView {
            hostingView.rootView = view
            resize(hostingView)
        } else {
            makePanel(with: view)
        }
    }

    /// Shows `phase`, then fades out after `duration`.
    public func flash(_ phase: DictationPhase, for duration: Duration = .milliseconds(1200)) {
        show(phase)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Fades the panel out and releases it.
    public func hide() {
        dismissTask?.cancel()
        dismissTask = nil

        guard let panel else { return }
        self.panel = nil
        hostingView = nil

        // The teardown is scheduled as a main-actor task rather than in
        // `runAnimationGroup`'s completion handler: that handler is `@Sendable`, and an
        // `NSPanel` cannot legally be captured by one.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.fadeOutDuration * 1000) + 20))
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    // MARK: - Panel construction

    private func makePanel(with view: HUDView) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the SwiftUI view draws its own, shaped to the corners
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Above normal windows and full-screen apps, below the menu bar itself.
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.alphaValue = 0

        self.panel = panel
        self.hostingView = hosting

        resize(hosting)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1
        }
    }

    /// Keeps the panel centred horizontally and a third of the way up the active screen —
    /// out of the way of both the menu bar and the Dock, and close to where the eye
    /// already is when typing.
    private func resize(_ hosting: NSHostingView<HUDView>) {
        guard let panel else { return }

        let size = hosting.intrinsicContentSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            panel.setContentSize(size)
            return
        }

        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.28
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
