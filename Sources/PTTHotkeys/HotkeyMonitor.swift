import PTTSettings
import PTTSupport

/// The hotkey, whichever shape it takes.
///
/// A binding is either modifiers with a key or modifiers alone, and the two can only be
/// observed by different mechanisms (see ``CarbonHotkeyMonitor`` and
/// ``ModifierHotkeyMonitor``). This routes to the right one and presents a single object
/// to the rest of the app, so the composition root and the state machine never branch on
/// the shape of a shortcut.
///
/// Both implementations are kept alive and only one is ever registered, which makes
/// switching between shapes in Settings a plain re-registration with the same rollback
/// behaviour as any other change.
@MainActor
public final class HotkeyMonitor: HotkeyMonitoring {

    public var onPress: (@MainActor () -> Void)? {
        didSet { propagateCallbacks() }
    }
    public var onRelease: (@MainActor () -> Void)? {
        didSet { propagateCallbacks() }
    }
    public var onCancel: (@MainActor () -> Void)? {
        didSet { propagateCallbacks() }
    }

    public var binding: HotkeyBinding? { active?.binding }

    private let carbon: any HotkeyMonitoring
    private let modifiersOnly: any HotkeyMonitoring
    private var active: (any HotkeyMonitoring)?

    /// - Parameters are injected so tests can drive the routing without touching Carbon or
    ///   AppKit event monitors.
    public init(
        carbon: any HotkeyMonitoring = CarbonHotkeyMonitor(),
        modifiersOnly: any HotkeyMonitoring = ModifierHotkeyMonitor()
    ) {
        self.carbon = carbon
        self.modifiersOnly = modifiersOnly
    }

    public func register(_ binding: HotkeyBinding) throws {
        let target = binding.isModifierOnly ? modifiersOnly : carbon

        // Releasing the other mechanism first matters: leaving a Carbon hot key registered
        // would keep consuming that combination system-wide after the user moved to a
        // modifier-only shortcut.
        if active !== target { active?.unregister() }

        try target.register(binding)
        active = target
        propagateCallbacks()
    }

    public func unregister() {
        active?.unregister()
        active = nil
    }

    /// Keeps whichever implementation is live pointed at the current callbacks.
    private func propagateCallbacks() {
        active?.onPress = onPress
        active?.onRelease = onRelease
        active?.onCancel = onCancel
    }
}
