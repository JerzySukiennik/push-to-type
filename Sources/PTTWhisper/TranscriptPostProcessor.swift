import Foundation

/// Cleans raw whisper output into something worth typing into a text field.
///
/// whisper emits bracketed annotations for non-speech audio (`[BLANK_AUDIO]`, `(wind
/// blowing)`, `♪♪♪`), leading spaces on every segment, and occasionally doubled spaces
/// where segments join. None of that belongs in the user's document, and none of it can be
/// switched off in the C API — so it is stripped here, in one pure, testable place.
public struct TranscriptPostProcessor: Sendable {

    /// Capitalise the first letter of the result.
    public var capitalizeFirstLetter: Bool
    /// Append a single trailing space so consecutive dictations do not run together.
    public var appendTrailingSpace: Bool

    public init(capitalizeFirstLetter: Bool = true, appendTrailingSpace: Bool = true) {
        self.capitalizeFirstLetter = capitalizeFirstLetter
        self.appendTrailingSpace = appendTrailingSpace
    }

    /// Annotations whisper produces for non-speech audio. Matched case-insensitively and
    /// removed wholesale; a transcript that is *only* annotations becomes empty, which the
    /// caller turns into `.emptyTranscript`.
    private static let annotationPattern = try! NSRegularExpression(
        pattern: #"[\[\(][^\]\)]{0,40}[\]\)]|♪+"#,
        options: [.caseInsensitive]
    )

    private static let whitespaceRuns = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    /// Two or more dots. whisper writes these when the speaker hesitates, and a spoken
    /// pause routinely comes back as `......` — faithful to the audio, wrong for a
    /// sentence someone is about to send.
    private static let dotRuns = try! NSRegularExpression(pattern: #"\.{2,}"#)

    /// A space that drifted in front of its punctuation, and repeated commas.
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.!?;:…])"#)
    private static let commaRuns = try! NSRegularExpression(pattern: #"(,\s*){2,}"#)

    /// Hesitation left dangling at the end: the key was released during a pause, so the
    /// trailing ellipsis is an artefact of stopping, not something the speaker meant.
    private static let trailingHesitation = try! NSRegularExpression(pattern: #"[\s,…]+$"#)

    /// Applies the full clean-up chain. Returns an empty string when nothing survives.
    public func process(_ raw: String) -> String {
        var text = raw

        text = Self.annotationPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )

        // whisper puts every segment on its own line; a dictated sentence should not
        // arrive with newlines in the middle of it.
        text = text.replacingOccurrences(of: "\n", with: " ")

        text = Self.whitespaceRuns.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )

        // Hesitation clean-up, in order: long dot runs become one ellipsis, duplicated
        // commas collapse, punctuation loses the space that drifted in front of it, and
        // anything left dangling at the very end goes.
        text = Self.replace(Self.dotRuns, in: text, with: "…")
        text = Self.replace(Self.commaRuns, in: text, with: ", ")
        text = Self.replace(Self.spaceBeforePunctuation, in: text, with: "$1")
        text = Self.replace(Self.trailingHesitation, in: text, with: "")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if capitalizeFirstLetter, let first = text.first, first.isLowercase {
            text.replaceSubrange(
                text.startIndex...text.startIndex,
                with: String(first).uppercased()
            )
        }

        if appendTrailingSpace {
            text += " "
        }

        return text
    }

    private static func replace(
        _ expression: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Joins streamed chunks. Chunks arrive already trimmed, so a single space is the
    /// right separator — except where the next chunk starts with punctuation.
    public static func join(_ chunks: [String]) -> String {
        var result = ""
        for chunk in chunks {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if result.isEmpty {
                result = piece
            } else if let first = piece.first, ",.!?;:".contains(first) {
                result += piece
            } else {
                result += " " + piece
            }
        }
        return result
    }
}
