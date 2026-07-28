import Foundation
import PTTSupport

/// How the transcript reached its destination. Surfaced for logging and for the HUD's
/// "pasted" hint, which explains why the clipboard briefly changed.
public enum InsertionMethod: Sendable, Equatable {
    /// Written straight into the focused element with the Accessibility API.
    case accessibility
    /// Placed on the pasteboard and pasted with a synthetic ⌘V.
    case clipboard
}

/// One way of delivering text to the focused field.
@MainActor
public protocol TextInserting: AnyObject {
    /// Attempts to insert `text`.
    ///
    /// - Returns: `true` when the text was placed. A `false` return is a *routine*
    ///   "this strategy does not apply here" and lets the service try the next one;
    ///   genuine failures throw.
    func insert(_ text: String) async throws -> Bool
}
