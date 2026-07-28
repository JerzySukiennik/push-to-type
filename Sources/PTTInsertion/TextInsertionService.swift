import AppKit
import PTTSettings
import PTTSupport

/// Delivers a transcript to whatever text field currently has focus, trying the least
/// intrusive strategy first.
///
/// The chain is Accessibility → clipboard. Each link answers "did you handle it?"; the
/// service walks down until one says yes, and only reports failure when the whole chain
/// declines. Strategies are injected, so a test can assert the ordering without any real
/// windows on screen.
@MainActor
public final class TextInsertionService {

    private let accessibility: any TextInserting
    private let clipboard: any TextInserting

    /// The strategy that handled the most recent insertion, for logging and the HUD.
    public private(set) var lastMethod: InsertionMethod?

    public init(
        accessibility: any TextInserting = AXTextInserter(),
        clipboard: any TextInserting = ClipboardInserter()
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
    }

    /// Inserts `text` into the focused field.
    ///
    /// - Parameter preferAccessibility: when `false`, skips straight to the clipboard.
    ///   Some users prefer that: it is one predictable behaviour everywhere instead of a
    ///   strategy that silently varies per app.
    /// - Throws: ``PTTError/accessibilityDenied`` when the app is not trusted, or
    ///   ``PTTError/insertionFailed(reason:)`` when nothing could deliver the text.
    public func insert(_ text: String, preferAccessibility: Bool = true) async throws {
        guard !text.isEmpty else { return }
        try AccessibilityPermission.require()

        if preferAccessibility {
            do {
                if try await accessibility.insert(text) {
                    lastMethod = .accessibility
                    return
                }
            } catch let error as PTTError where error == .accessibilityDenied {
                throw error
            } catch {
                // A strategy that blew up is not fatal — the next one may still work.
                Log.insertion.error("Accessibility insertion failed: \(error.localizedDescription)")
            }
        }

        if try await clipboard.insert(text) {
            lastMethod = .clipboard
            return
        }

        throw PTTError.insertionFailed(reason: "no text field accepted the transcript")
    }
}
