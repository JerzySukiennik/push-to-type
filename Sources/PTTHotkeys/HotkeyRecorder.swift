import AppKit
import PTTSettings
import PTTSupport

/// Captures the next key combination the user presses, for the Settings shortcut field.
///
/// Deliberately a **local** monitor: it only sees events while PushToType's own settings
/// window is key, so no system-wide tap ever exists for this. The global hotkey stays the
/// only thing that watches keys outside the app.
@MainActor
public final class HotkeyRecorder {

    /// `true` while waiting for a combination.
    public private(set) var isRecording = false

    /// `nonisolated(unsafe)` so `deinit` can remove the monitor; it is only ever assigned
    /// from main-actor methods, and deinit runs when no other reference survives.
    private nonisolated(unsafe) var monitor: Any?
    private var completion: ((HotkeyBinding?) -> Void)?

    public init() {}

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Starts listening.
    ///
    /// - Parameter completion: the captured binding, or `nil` if the user pressed Escape
    ///   or chose a combination with no modifiers (which would be unusable globally).
    public func start(completion: @escaping (HotkeyBinding?) -> Void) {
        stop()
        self.completion = completion
        isRecording = true

        // Only the two `Sendable` values the recorder needs are read out of the event, so
        // the `NSEvent` itself never crosses a concurrency boundary. Every key press is
        // swallowed while recording — that is the point of a shortcut field.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.consume(keyCode: keyCode, flags: flags)
            }
            return nil
        }
    }

    /// Stops listening without reporting a result.
    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        completion = nil
    }

    /// Turns a key press into a binding and ends recording.
    private func consume(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }

        if keyCode == KeyCode.escape {
            finish(with: nil)
            return
        }

        let modifiers = HotkeyBinding.Modifiers(carbonFlags: flags)
        guard !modifiers.isEmpty else {
            // A bare key would be swallowed system-wide; refuse it and keep recording.
            NSSound.beep()
            return
        }

        finish(with: HotkeyBinding(keyCode: keyCode, modifiers: modifiers))
    }

    private func finish(with binding: HotkeyBinding?) {
        let completion = self.completion
        stop()
        completion?(binding)
    }
}

extension HotkeyBinding.Modifiers {
    /// Converts AppKit's modifier flags into the Carbon mask `RegisterEventHotKey` wants.
    init(carbonFlags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyBinding.Modifiers = []
        if carbonFlags.contains(.command) { modifiers.insert(.command) }
        if carbonFlags.contains(.shift) { modifiers.insert(.shift) }
        if carbonFlags.contains(.option) { modifiers.insert(.option) }
        if carbonFlags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}
