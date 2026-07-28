import ApplicationServices
import Foundation
import PTTSupport

/// Accessibility ("control your computer") authorisation.
///
/// Required for both insertion strategies: the Accessibility API needs it to reach another
/// app's text field, and `CGEvent.post` needs it to synthesise ⌘V. Unlike the microphone,
/// macOS gives no callback when the switch is flipped — so the app re-checks when it is
/// activated rather than polling on a timer.
public enum AccessibilityPermission {

    /// Current trust state. Never prompts, so it is safe to call on every dictation.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its "grant access" prompt.
    ///
    /// The prompt appears at most once per app version; afterwards macOS silently returns
    /// the current state, which is why ``openSystemSettings()`` exists as the follow-up.
    @discardableResult
    public static func requestAccess() -> Bool {
        // Spelled literally: `kAXTrustedCheckOptionPrompt` is exported as a mutable global,
        // which Swift 6 refuses to read from concurrent code. The string it holds is API.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.insertion.info("Accessibility trusted: \(trusted, privacy: .public)")
        return trusted
    }

    /// Deep link to the exact pane the user needs.
    public static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }

    /// Throws the typed error when access is missing, so callers can branch on one thing.
    public static func require() throws {
        guard isTrusted else { throw PTTError.accessibilityDenied }
    }
}
