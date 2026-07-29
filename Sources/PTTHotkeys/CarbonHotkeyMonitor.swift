import Carbon.HIToolbox
import Foundation
import PTTSettings
import PTTSupport

/// Global hotkey backed by Carbon's `RegisterEventHotKey`.
///
/// ## Why Carbon and not a CGEventTap
/// A `CGEventTap` is the other way to see keys system-wide, and it is the wrong tool here:
/// it requires Accessibility permission before the app can do anything at all, it puts a
/// callback in the path of *every* keystroke on the machine, and the system disables taps
/// that respond too slowly. `RegisterEventHotKey` costs nothing while idle, needs no
/// permission, and — crucially for push-to-talk — reports both press and release.
///
/// ## Trade-off, stated plainly
/// While registered, the combination is consumed system-wide: with the default ⌘T, apps
/// that use ⌘T for "new tab" stop receiving it. That is inherent to a global hotkey, and
/// it is why the shortcut is configurable.
@MainActor
public final class CarbonHotkeyMonitor: HotkeyMonitoring {

    public var onPress: (@MainActor () -> Void)?
    public var onRelease: (@MainActor () -> Void)?

    /// Never called: a registered Carbon hot key is unambiguous. It exists to satisfy
    /// ``HotkeyMonitoring``, whose cancel path only modifier-only bindings can reach.
    public var onCancel: (@MainActor () -> Void)?

    public private(set) var binding: HotkeyBinding?

    // Carbon handles. `nonisolated(unsafe)` because `deinit` must release them and runs
    // outside the main actor; every *mutation* still happens in main-actor methods, and
    // deinit only runs once the last reference is gone, so no concurrent access exists.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandler: EventHandlerRef?

    /// Identifies our hot key in the Carbon event stream.
    private static let signature: OSType = 0x5054_5459  // 'PTTY'
    private static let identifier: UInt32 = 1

    public init() {}

    deinit {
        // `unregister()` is main-actor isolated and deinit may run anywhere, so the Carbon
        // handles are released directly. Both calls are safe on any thread.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Registration

    public func register(_ binding: HotkeyBinding) throws {
        // Carbon's hot key table is keyed by virtual key code, so a modifier-only binding
        // cannot be expressed here at all — ``ModifierHotkeyMonitor`` handles those.
        guard binding.isValid, !binding.isModifierOnly else {
            throw PTTError.hotkeyRegistrationFailed(status: -1)
        }

        let previous = self.binding
        unregister()

        do {
            try installHandlerIfNeeded()
            try installHotKey(binding)
            self.binding = binding
            Log.hotkey.info("Registered \(binding.displayString, privacy: .public)")
        } catch {
            // Roll back to the previous, known-good binding so a bad choice in Settings
            // never leaves the app without a shortcut.
            if let previous, previous != binding {
                try? installHandlerIfNeeded()
                try? installHotKey(previous)
                self.binding = previous
            }
            throw error
        }
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        binding = nil
    }

    // MARK: - Carbon plumbing

    /// Installs the application-wide handler once. It outlives individual registrations,
    /// so changing the shortcut does not churn event handlers.
    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            eventTypes.count,
            &eventTypes,
            context,
            &eventHandler
        )

        guard status == noErr else {
            throw PTTError.hotkeyRegistrationFailed(status: status)
        }
    }

    private func installHotKey(_ binding: HotkeyBinding) throws {
        guard let keyCode = binding.keyCode else {
            throw PTTError.hotkeyRegistrationFailed(status: -1)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        var reference: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            binding.modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            Log.hotkey.error("RegisterEventHotKey failed with \(status)")
            throw PTTError.hotkeyRegistrationFailed(status: status)
        }
        hotKeyRef = reference
    }

    /// Called from the C handler on the main thread.
    fileprivate func handle(kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed: onPress?()
        case kEventHotKeyReleased: onRelease?()
        default: break
        }
    }

    /// Bridges from the C callback back onto the main actor.
    ///
    /// Split out of the callback itself because a `@convention(c)` closure's parameters
    /// are `sending`, and a `sending` value cannot be captured by another closure. As an
    /// ordinary function parameter the pointer carries no such restriction.
    fileprivate nonisolated static func dispatch(kind: UInt32, context: UnsafeMutableRawPointer) {
        let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
        // Carbon delivers application event-target handlers on the main thread.
        MainActor.assumeIsolated {
            monitor.handle(kind: kind)
        }
    }
}

/// Carbon event callback.
///
/// C function pointers cannot capture context, so the monitor arrives through `userData`.
/// Carbon dispatches application event-target handlers on the main thread, which is why
/// `assumeIsolated` is sound here.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    CarbonHotkeyMonitor.dispatch(kind: GetEventKind(event), context: userData)
    return noErr
}
