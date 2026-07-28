import AppKit

/// Entry point.
///
/// `NSApplication` is started by hand rather than through `@main` on a SwiftUI `App`:
/// PushToType owns its status item, its floating panel and its activation policy, none of
/// which fit the `MenuBarExtra` scene model without fighting it. Twelve lines of AppKit is
/// the honest version.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// Set before `run()` so the Dock never briefly shows an icon on launch.
application.setActivationPolicy(.accessory)
application.run()
