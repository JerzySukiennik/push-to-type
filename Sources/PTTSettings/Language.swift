import Foundation

/// Transcription language.
///
/// whisper takes an ISO-639-1 code, or `"auto"` to detect from the first seconds of audio.
/// Detection costs one extra encoder pass, so it is offered but not the default.
public enum Language: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case english = "en"
    case polish = "pl"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case ukrainian = "uk"
    case czech = "cs"
    case swedish = "sv"
    case norwegian = "no"
    case danish = "da"
    case finnish = "fi"
    case turkish = "tr"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"

    public var id: String { rawValue }

    /// The code handed to `whisper_full_params.language`.
    public var whisperCode: String { rawValue }

    /// `true` when whisper should run its language-detection pass.
    public var isAutomatic: Bool { self == .auto }

    /// Localised name from the system, so the picker follows the user's locale.
    public var displayName: String {
        guard self != .auto else { return "Automatic" }
        return Locale.current.localizedString(forLanguageCode: rawValue)?.capitalized
            ?? rawValue.uppercased()
    }

    /// Languages that make sense for a given model. English-only models cannot detect or
    /// transcribe anything else, so the picker collapses to a single entry.
    public static func available(for model: WhisperModel) -> [Language] {
        model.isEnglishOnly ? [.english] : allCases
    }
}
