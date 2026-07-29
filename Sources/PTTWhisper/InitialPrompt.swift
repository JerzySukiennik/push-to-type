import Foundation

/// Builds the text whisper is conditioned on before it starts decoding.
///
/// ## What this actually does
/// whisper is an autoregressive model: give it text that looks like it came just before
/// the audio, and it becomes far more likely to produce spellings that fit. That is the
/// only lever available for proper nouns — "GSP", "Gzowo", "three.js" are not in the
/// training data as a unit, so without a hint the model writes what it heard phonetically.
/// It is a bias, not a dictionary: a word in the prompt is *more likely*, never guaranteed.
///
/// ## Two things compete for the same budget
/// whisper keeps at most `n_text_ctx / 2` tokens — typically 224 — and it keeps the
/// **tail**. So the order here is deliberate: the vocabulary goes first and the previous
/// chunk's text last, because when a long dictation overflows the budget, losing the
/// glossary hurts less than losing the sentence currently being continued.
public struct InitialPrompt {

    /// Roughly the number of characters that fits whisper's prompt budget, leaving room
    /// for the continuation text. Deliberately conservative: an over-long prompt is
    /// silently truncated, which would drop terms without telling anyone.
    private static let vocabularyCharacterLimit = 600

    /// Terms the user wants spelled their way.
    public let vocabulary: [String]

    /// Text already transcribed from earlier chunks of the same utterance.
    public let continuation: String?

    public init(vocabulary: [String], continuation: String? = nil) {
        self.vocabulary = vocabulary
        self.continuation = continuation
    }

    /// The prompt string, or `nil` when there is nothing to condition on.
    public var text: String? {
        var parts: [String] = []

        if let glossary = Self.glossary(from: vocabulary) {
            parts.append(glossary)
        }
        if let continuation, !continuation.isEmpty {
            parts.append(continuation)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Formats the terms as a sentence.
    ///
    /// A bare comma-separated list conditions better than a heading like "Glossary:",
    /// because the list itself looks like ordinary transcript text — which is exactly what
    /// the model expects to be continuing.
    private static func glossary(from terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        var glossary = cleaned.joined(separator: ", ") + "."
        if glossary.count > vocabularyCharacterLimit {
            glossary = String(glossary.prefix(vocabularyCharacterLimit))
        }
        return glossary
    }

    /// Splits what the user typed into terms.
    ///
    /// Commas and newlines both separate, so the field accepts either a list or one word
    /// per line without the user having to be told which.
    public static func parseVocabulary(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
