import Foundation
import PTTSettings

/// A global press-and-hold shortcut.
///
/// The protocol exists so the dictation controller can be driven by a stub in tests and by
/// Carbon in production, without either knowing about the other.
@MainActor
public protocol HotkeyMonitoring: AnyObject {

    /// Called when the combination goes down.
    var onPress: (@MainActor () -> Void)? { get set }

    /// Called when it comes back up.
    var onRelease: (@MainActor () -> Void)? { get set }

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
