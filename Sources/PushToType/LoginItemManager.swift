import Foundation
import PTTSupport
import ServiceManagement

/// "Launch at Login", via the modern `SMAppService` API.
///
/// No helper bundle, no login-item plist, nothing to clean up on uninstall: registering the
/// main app is a single call, and macOS shows it in Login Items where the user can turn it
/// off without ever opening PushToType.
@MainActor
enum LoginItemManager {

    /// `true` when macOS will start the app at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Flips the setting.
    ///
    /// - Returns: the state afterwards. A failure is logged and reported by returning the
    ///   unchanged value — this is a convenience, never a reason to interrupt the user.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
            return enabled
        } catch {
            Log.app.error("Launch at login change failed: \(error.localizedDescription)")
            return isEnabled
        }
    }

    /// Toggles and returns the new state.
    @discardableResult
    static func toggle() -> Bool {
        setEnabled(!isEnabled)
    }
}
