import Foundation
import PTTSettings

/// A global press-and-hold shortcut.
///
/// The protocol exists so the dictation controller can be driven by a stub in tests, by
/// Carbon for key combinations, and by a passive flags monitor for modifier-only
/// shortcuts — without any of them knowing about the others.
@MainActor
public protocol HotkeyMonitoring: AnyObject {

    /// Called when the combination goes down.
    var onPress: (@MainActor () -> Void)? { get set }

    /// Called when it comes back up, and the dictation should be delivered.
    var onRelease: (@MainActor () -> Void)? { get set }

    /// Called when the hold turned out not to be a dictation after all, and whatever was
    /// recorded should be thrown away.
    ///
    /// Only modifier-only bindings can produce this. Holding ⌃⌥ is *also* the first half
    /// of pressing ⌃⌥⌘F, and a hand resting on the keys for 80 ms is not a dictation. The
    /// monitor recognises both and withdraws instead of delivering a bogus transcript.
    var onCancel: (@MainActor () -> Void)? { get set }

    /// The binding currently registered, if any.
    var binding: HotkeyBinding? { get }

    /// Registers `binding`, replacing whatever was registered before.
    ///
    /// - Throws: ``PTTError/hotkeyRegistrationFailed(status:)`` when the combination is
    ///   already claimed by another application.
    func register(_ binding: HotkeyBinding) throws

    /// Releases the shortcut, letting other apps see it again.
    func unregister()
}
