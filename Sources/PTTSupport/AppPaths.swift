import Foundation

/// Filesystem locations the app owns.
///
/// Directories are created on demand rather than at launch: an app that has never
/// downloaded a model should not leave folders behind, and touching the disk during
/// `applicationDidFinishLaunching` is exactly the kind of work the startup budget
/// does not allow.
public enum AppPaths {

    /// Bundle identifier, falling back to a literal when running as a bare executable
    /// (e.g. `swift run` during development, where there is no Info.plist).
    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.gzowo.PushToType"
    }

    /// `~/Library/Application Support/PushToType`
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PushToType", isDirectory: true)
    }

    /// `~/Library/Application Support/PushToType/Models` — where GGML model files live.
    public static var models: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Scratch space for in-flight downloads, so a partial file is never mistaken for
    /// a usable model.
    public static var downloads: URL {
        applicationSupport.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Creates `url` if it does not exist. Returns the same URL for chaining.
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return url }
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
