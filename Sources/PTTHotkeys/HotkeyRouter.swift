import PTTSettings
import PTTSupport

/// Registers one shortcut per dictation mode and reports which mode fired.
///
/// The app has more than one shortcut now — raw, plus a shortcut for each refined mode —
/// and they are not all the same shape: raw is usually modifiers held alone (a
/// ``ModifierHotkeyMonitor``), while a refined mode like ⌃⌥P is a key combination (a
/// ``CarbonHotkeyMonitor``). The router owns one monitor per active mode, hands each a
/// unique Carbon id so their events do not cross, and forwards every callback tagged with
/// the mode's id so the controller knows what to do with the transcript.
@MainActor
public final class HotkeyRouter {

    /// A mode's identity paired with the shortcut that triggers it.
    public struct Binding: Sendable {
        public let modeID: String
        public let hotkey: HotkeyBinding
        public init(modeID: String, hotkey: HotkeyBinding) {
            self.modeID = modeID
            self.hotkey = hotkey
        }
    }

    /// Callbacks carry the id of the mode whose shortcut fired.
    public var onPress: (@MainActor (String) -> Void)?
    public var onRelease: (@MainActor (String) -> Void)?
    public var onCancel: (@MainActor (String) -> Void)?

    private var monitors: [any HotkeyMonitoring] = []

    public init() {}

    /// Replaces every registration with the given set.
    ///
    /// - Returns: the shortcuts that could not be registered — a duplicate of one already
    ///   in the set, or a combination the system refused — so the caller can surface them.
    @discardableResult
    public func setBindings(_ bindings: [Binding]) -> [String] {
        unregisterAll()

        var rejected: [String] = []
        var claimed = Set<String>()
        var nextCarbonID: UInt32 = 1

        for binding in bindings where binding.hotkey.isValid {
            let label = binding.hotkey.displayString

            // Two modes on one shortcut is a user mistake, not a crash: keep the first and
            // report the rest, rather than letting both fire.
            guard !claimed.contains(label) else {
                rejected.append(label)
                continue
            }

            let monitor: any HotkeyMonitoring
            if binding.hotkey.isModifierOnly {
                monitor = ModifierHotkeyMonitor()
            } else {
                monitor = CarbonHotkeyMonitor(identifier: nextCarbonID)
                nextCarbonID += 1
            }

            let modeID = binding.modeID
            monitor.onPress = { [weak self] in self?.onPress?(modeID) }
            monitor.onRelease = { [weak self] in self?.onRelease?(modeID) }
            monitor.onCancel = { [weak self] in self?.onCancel?(modeID) }

            do {
                try monitor.register(binding.hotkey)
                monitors.append(monitor)
                claimed.insert(label)
            } catch {
                Log.hotkey.error("Could not register \(label, privacy: .public): \(error)")
                rejected.append(label)
            }
        }

        return rejected
    }

    public func unregisterAll() {
        for monitor in monitors { monitor.unregister() }
        monitors = []
    }
}
