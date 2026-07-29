import AppKit
import ApplicationServices
import PTTSettings
import PTTSupport

/// Watches for modifiers held on their own — ⌃⌥ by default.
///
/// ## Why this is a second implementation rather than a flag on the first
/// `RegisterEventHotKey` cannot express "no key": Carbon's hot key table is keyed by
/// virtual key code, and passing a modifier's own code registers the physical key, not the
/// state. The only way to see modifiers as a held state is to observe `flagsChanged`
/// events, which is a fundamentally different mechanism — passive rather than exclusive.
///
/// ## What that buys
/// Nothing is taken away from other applications. A Carbon hot key *consumes* its
/// combination system-wide; this monitor only listens, so every other app still sees ⌃⌥
/// exactly as before. That is the whole reason modifier-only push-to-talk is worth the
/// extra implementation.
///
/// ## What it costs
/// `NSEvent.addGlobalMonitorForEvents` delivers nothing until the app is trusted for
/// Accessibility. With a modifier-only binding that permission is therefore required for
/// the shortcut itself, not just for inserting text.
///
/// ## Guarding against false starts
/// Holding ⌃⌥ is also how a user *begins* pressing ⌃⌥⌘F, and hands rest on keys. Three
/// rules keep those out of the dictation flow:
///
/// 1. The modifier set must match **exactly** — gaining ⌘ cancels rather than continues.
/// 2. Any ordinary key pressed during the hold cancels: that is a shortcut, not speech.
/// 3. A hold shorter than ``minimumHold`` cancels, so brushing the keys costs nothing.
@MainActor
public final class ModifierHotkeyMonitor: HotkeyMonitoring {

    public var onPress: (@MainActor () -> Void)?
    public var onRelease: (@MainActor () -> Void)?
    public var onCancel: (@MainActor () -> Void)?

    public private(set) var binding: HotkeyBinding?

    /// Shorter holds are treated as a slip of the hand rather than a dictation.
    ///
    /// 220 ms is comfortably longer than the time it takes to pass through ⌃⌥ on the way
    /// to a bigger chord, and far shorter than anyone can hold a key and start speaking.
    public static let minimumHold: TimeInterval = 0.22

    /// All modifiers the monitor compares against; anything else (caps lock, function,
    /// numeric pad) is noise for this purpose.
    private static let tracked: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private nonisolated(unsafe) var flagsMonitors: [Any] = []
    private nonisolated(unsafe) var keyMonitors: [Any] = []

    /// When the modifiers went down, or `nil` when they are not held.
    private var engagedAt: Date?

    public init() {}

    deinit {
        for monitor in flagsMonitors + keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Registration

    public func register(_ binding: HotkeyBinding) throws {
        guard binding.isModifierOnly, binding.isValid else {
            throw PTTError.hotkeyRegistrationFailed(status: -1)
        }

        unregister()
        self.binding = binding

        // Global monitors see other applications' events; local ones see our own windows,
        // which the global monitor deliberately excludes. Both are installed so the
        // shortcut behaves identically whether or not PushToType's settings window happens
        // to be in front.
        //
        // Only `modifierFlags` — a `Sendable` option set — is read out of the event, so
        // the `NSEvent` itself never crosses a concurrency boundary.
        let observe: @Sendable (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.flagsChanged(to: flags) }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: observe) {
            flagsMonitors.append(global)
        }

        let localHandler: @Sendable (NSEvent) -> NSEvent? = { event in
            observe(event)
            return event
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: localHandler) {
            flagsMonitors.append(local)
        }

        if !AccessibilityTrust.isTrusted {
            Log.hotkey.warning("Modifier-only hotkey needs Accessibility; it will not fire yet")
        }
        Log.hotkey.info("Watching \(binding.displayString, privacy: .public)")
    }

    public func unregister() {
        for monitor in flagsMonitors + keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagsMonitors = []
        keyMonitors = []
        engagedAt = nil
        binding = nil
    }

    // MARK: - State

    /// Reacts to a change in the modifier keys.
    private func flagsChanged(to flags: NSEvent.ModifierFlags) {
        guard let binding else { return }
        let current = flags.intersection(Self.tracked)
        let required = binding.modifiers.appKitFlags

        if engagedAt == nil {
            if current == required { engage() }
            return
        }

        if current == required { return }  // nothing changed for us

        if current.isSuperset(of: required) {
            // The user added ⌘ or ⇧: this is the start of a larger shortcut.
            finish(cancelled: true, reason: "the shortcut grew")
        } else {
            finish(cancelled: false, reason: "released")
        }
    }

    private func engage() {
        engagedAt = Date()
        installKeyGuard()
        onPress?()
    }

    /// Ends the hold, delivering or discarding depending on `cancelled` and on how long it
    /// lasted.
    private func finish(cancelled: Bool, reason: String) {
        guard let engagedAt else { return }
        let held = Date().timeIntervalSince(engagedAt)
        self.engagedAt = nil
        removeKeyGuard()

        if cancelled || held < Self.minimumHold {
            Log.hotkey.debug("Hold discarded after \(held, format: .fixed(precision: 3)) s (\(reason, privacy: .public))")
            onCancel?()
        } else {
            onRelease?()
        }
    }

    /// While the modifiers are held, any ordinary key press means the user is typing a
    /// shortcut. The guard exists only for the duration of the hold, so no key monitor is
    /// installed during the 99.9% of the time nothing is happening.
    private func installKeyGuard() {
        let cancel: @Sendable (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(cancelled: true, reason: "a key was pressed")
            }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: cancel) {
            keyMonitors.append(global)
        }

        let localHandler: @Sendable (NSEvent) -> NSEvent? = { event in
            cancel(event)
            return event
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: localHandler) {
            keyMonitors.append(local)
        }
    }

    private func removeKeyGuard() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors = []
    }
}

extension HotkeyBinding.Modifiers {
    /// The AppKit flags equivalent to this Carbon mask.
    var appKitFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// Minimal trust probe, so `PTTHotkeys` can warn without depending on `PTTInsertion`.
enum AccessibilityTrust {
    static var isTrusted: Bool { AXIsProcessTrusted() }
}
