import OSLog

/// Centralised loggers.
///
/// Every module logs through one of these categories so that a single
/// `log stream --predicate 'subsystem == "com.gzowo.PushToType"'` shows the whole
/// dictation flow in order. Nothing is written to disk: `os.Logger` is free when no
/// one is listening, which matters for the "idle CPU ≈ 0" requirement.
public enum Log {
    private static let subsystem = "com.gzowo.PushToType"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let whisper = Logger(subsystem: subsystem, category: "whisper")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
}
