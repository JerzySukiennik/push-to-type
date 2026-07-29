import Foundation

/// Rewrites a transcript according to a mode's instruction.
///
/// A protocol, not a concrete type, so the backend is a choice rather than a commitment.
/// Today it is Gemini; a local model behind the same method would drop in without the rest
/// of the app noticing, which is the point of keeping the seam here.
public protocol TextRefiner: Sendable {

    /// Applies `instruction` to `text` and returns the rewritten result.
    ///
    /// - Parameters:
    ///   - text: the raw transcript.
    ///   - instruction: the mode's prompt, e.g. "rewrite as a concise message".
    /// - Returns: the model's output, trimmed, ready to insert.
    /// - Throws: ``PTTError/refinementKeyMissing``, ``PTTError/refinementFailed(reason:)``,
    ///   ``PTTError/refinementEmpty``, or `CancellationError`.
    func refine(_ text: String, instruction: String) async throws -> String
}
