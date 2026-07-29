import AppKit

/// Entry point.
///
/// `NSApplication` is started by hand rather than through `@main` on a SwiftUI `App`:
/// PushToType owns its status item, its floating panel and its activation policy, none of
/// which fit the `MenuBarExtra` scene model without fighting it. Twelve lines of AppKit is
/// the honest version.

// Two maintenance switches, handled before any UI exists.
//
// "Launch at Login" is `SMAppService.mainApp`, which only the app itself can register —
// there is no external command for it. Exposing it as a flag is what lets the installer
// script turn it on without the user having to find the menu item, and lets it be turned
// off again the same way.
if CommandLine.arguments.contains("--register-login-item") {
    let enabled = LoginItemManager.setEnabled(true)
    print(enabled ? "Launch at Login: enabled" : "Launch at Login: could not be enabled")
    exit(enabled ? 0 : 1)
}

if CommandLine.arguments.contains("--unregister-login-item") {
    let enabled = LoginItemManager.setEnabled(false)
    print(enabled ? "Launch at Login: still enabled" : "Launch at Login: disabled")
    exit(enabled ? 1 : 0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// Set before `run()` so the Dock never briefly shows an icon on launch.
application.setActivationPolicy(.accessory)
application.run()
