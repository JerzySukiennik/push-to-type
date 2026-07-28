import Foundation

/// The single error type that crosses module boundaries.
///
/// Modules never surface `NSError`, `OSStatus` or C return codes to their callers —
/// they map them here, attaching the underlying description so the log keeps the detail
/// while the UI keeps a sentence a human can act on.
///
/// Every case answers three questions: what happened (`title`), why the user should care
/// (`message`), and what to do about it (`recovery` + optional `recoveryAction`).
public enum PTTError: Error, Sendable, Equatable {

    // MARK: Permissions

    /// Microphone access has been denied or restricted.
    case microphoneDenied
    /// The app is not trusted for Accessibility, so text cannot be inserted.
    case accessibilityDenied

    // MARK: Model

    /// The selected model file is not on disk and has not been downloaded yet.
    case modelMissing(name: String)
    /// The model download failed (network, disk, or a truncated file).
    case modelDownloadFailed(name: String, reason: String)
    /// whisper.cpp refused to initialise the context for this file.
    case modelLoadFailed(name: String)

    // MARK: Capture

    /// No usable input device, or `AVAudioEngine` refused to start.
    case audioEngineFailed(reason: String)
    /// The user held the key but nothing audible was captured.
    case emptyRecording

    // MARK: Inference

    /// `whisper_full` returned a non-zero status.
    case transcriptionFailed(reason: String)
    /// Inference produced only whitespace or whisper's blank-audio marker.
    case emptyTranscript

    // MARK: Insertion

    /// Neither the Accessibility path nor the clipboard fallback could place the text.
    case insertionFailed(reason: String)

    // MARK: Hotkey

    /// The requested key combination could not be registered (usually already taken).
    case hotkeyRegistrationFailed(status: Int32)
}

extension PTTError {

    /// Short, HUD-sized headline.
    public var title: String {
        switch self {
        case .microphoneDenied:          "Microphone access needed"
        case .accessibilityDenied:       "Accessibility access needed"
        case .modelMissing:              "Model not downloaded"
        case .modelDownloadFailed:       "Download failed"
        case .modelLoadFailed:           "Model could not be loaded"
        case .audioEngineFailed:         "Recording failed"
        case .emptyRecording:            "Nothing recorded"
        case .transcriptionFailed:       "Transcription failed"
        case .emptyTranscript:           "No speech detected"
        case .insertionFailed:           "Could not insert text"
        case .hotkeyRegistrationFailed:  "Hotkey unavailable"
        }
    }

    /// One sentence of detail, safe to show in a menu or an alert body.
    public var message: String {
        switch self {
        case .microphoneDenied:
            "PushToType cannot record until microphone access is granted."
        case .accessibilityDenied:
            "PushToType cannot type into other apps until Accessibility access is granted."
        case .modelMissing(let name):
            "The speech model “\(name)” is missing."
        case .modelDownloadFailed(let name, let reason):
            "Downloading “\(name)” failed: \(reason)"
        case .modelLoadFailed(let name):
            "The file for “\(name)” is unreadable or corrupted."
        case .audioEngineFailed(let reason):
            "The audio input could not be started: \(reason)"
        case .emptyRecording:
            "The microphone captured only silence."
        case .transcriptionFailed(let reason):
            "The speech engine returned an error: \(reason)"
        case .emptyTranscript:
            "No words were recognised in the recording."
        case .insertionFailed(let reason):
            "The transcript could not be delivered: \(reason)"
        case .hotkeyRegistrationFailed(let status):
            "The shortcut is already in use by another app (error \(status))."
        }
    }

    /// What the user can do next. `nil` when the app already recovered on its own.
    public var recovery: String? {
        switch self {
        case .microphoneDenied:
            "Open System Settings › Privacy & Security › Microphone and enable PushToType."
        case .accessibilityDenied:
            "Open System Settings › Privacy & Security › Accessibility and enable PushToType."
        case .modelMissing, .modelDownloadFailed:
            "Choose Model from the menu bar to download it again."
        case .modelLoadFailed:
            "Choose Model from the menu bar and re-download the file."
        case .audioEngineFailed:
            "Check that an input device is connected and selected in Sound settings."
        case .emptyRecording, .emptyTranscript:
            "Hold the shortcut, speak, and release it once you have finished."
        case .transcriptionFailed:
            "Try again. If it keeps failing, switch to another model."
        case .insertionFailed:
            "Click into a text field before dictating."
        case .hotkeyRegistrationFailed:
            "Pick a different shortcut in Settings."
        }
    }

    /// Errors the user can only fix in System Settings get a deep link.
    public var settingsURL: URL? {
        switch self {
        case .microphoneDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibilityDenied:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        default:
            nil
        }
    }

    /// `true` for conditions that are part of normal use (a slip of the finger,
    /// a silent room) rather than something the user must act on. These get a brief
    /// HUD flash instead of a persistent error state.
    public var isBenign: Bool {
        switch self {
        case .emptyRecording, .emptyTranscript: true
        default: false
        }
    }
}

extension PTTError: LocalizedError {
    public var errorDescription: String? { title }
    public var failureReason: String? { message }
    public var recoverySuggestion: String? { recovery }
}
