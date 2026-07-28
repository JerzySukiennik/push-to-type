import Foundation
import PTTSupport

/// What the app is doing right now, as far as the user is concerned.
///
/// Lives in `PTTUI` because it is a presentation model: the menu bar icon, the HUD and the
/// accessibility announcements are all derived from it. The controller in the app target
/// owns the authoritative state machine and publishes this.
public enum DictationPhase: Sendable, Equatable {

    /// Waiting for the hotkey. Nothing is allocated, nothing is running.
    case idle

    /// Recording. `level` is the current input peak, 0…1, for the meter.
    case listening(level: Float)

    /// The key is up and inference is finishing.
    case transcribing

    /// A model file is being fetched. `progress` is 0…1.
    case downloading(model: String, progress: Double)

    /// Something went wrong; shown briefly, then back to `.idle`.
    case failed(PTTError)

    /// Text was inserted. Used for a short confirmation flash.
    case inserted(characters: Int)

    /// `true` while the user is expected to keep holding the key.
    public var isActive: Bool {
        switch self {
        case .listening, .transcribing, .downloading: true
        case .idle, .failed, .inserted: false
        }
    }

    /// Line shown in the HUD.
    public var hudText: String {
        switch self {
        case .idle: ""
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .downloading(let model, let progress):
            "Downloading \(model) — \(Int(progress * 100))%"
        case .failed(let error): error.title
        case .inserted: "Inserted"
        }
    }

    /// Leading glyph for the HUD.
    public var hudSymbol: String {
        switch self {
        case .idle: ""
        case .listening: "🎤"
        case .transcribing: "⚙️"
        case .downloading: "⬇️"
        case .failed: "⚠️"
        case .inserted: "✓"
        }
    }

    /// SF Symbol for the menu bar item.
    public var menuBarSymbol: String {
        switch self {
        case .idle, .inserted: "mic"
        case .listening: "mic.fill"
        case .transcribing: "waveform"
        case .downloading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
