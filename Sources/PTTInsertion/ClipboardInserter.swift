import AppKit
import PTTSupport

/// Fallback insertion: put the text on the pasteboard, synthesise ⌘V, put the pasteboard
/// back the way it was.
///
/// Used only when the Accessibility path reports that it cannot reach the focused element
/// (Electron apps, terminals, some web views). The pasteboard belongs to the user, so
/// every item and every type is captured before the write and restored afterwards —
/// including images and file promises, not just the string a naïve implementation would
/// save.
///
/// The restore is deliberately delayed: the target app reads the pasteboard asynchronously
/// after receiving ⌘V, and restoring immediately would race it into pasting the *old*
/// contents.
@MainActor
public final class ClipboardInserter: TextInserting {

    /// Time given to the frontmost app to service the paste before the pasteboard is
    /// restored. Long enough for slow Electron apps, short enough that a user pressing ⌘V
    /// themselves right afterwards still gets their own clipboard back.
    private static let restoreDelay: Duration = .milliseconds(400)

    /// Gap between the synthetic key-down and key-up.
    private static let keystrokeGap: Duration = .milliseconds(12)

    /// Virtual key code for `V`.
    private static let keyCodeV: CGKeyCode = 0x09

    public init() {}

    public func insert(_ text: String) async throws -> Bool {
        try AccessibilityPermission.require()
        guard !text.isEmpty else { return true }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(into: pasteboard)
            throw PTTError.insertionFailed(reason: "the pasteboard rejected the transcript")
        }

        do {
            try postPasteShortcut()
        } catch {
            snapshot.restore(into: pasteboard)
            throw error
        }

        // Restore on a detached task so the caller — and the HUD — is not held up.
        Task { [snapshot] in
            try? await Task.sleep(for: Self.restoreDelay)
            await MainActor.run { snapshot.restore(into: NSPasteboard.general) }
        }

        Log.insertion.info("Inserted \(text.count) characters via the clipboard")
        return true
    }

    // MARK: - Synthetic ⌘V

    private func postPasteShortcut() throws {
        // A private event source keeps the synthetic keys out of the user's own key state,
        // so a physically held modifier cannot combine with ours.
        guard let source = CGEventSource(stateID: .privateState) else {
            throw PTTError.insertionFailed(reason: "could not create an event source")
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.keyCodeV, keyDown: false)
        else {
            throw PTTError.insertionFailed(reason: "could not create the paste keystroke")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        // A short gap: some apps ignore a key-up that arrives in the same event batch.
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// A complete copy of the pasteboard: every item, every type, every payload.
private struct PasteboardSnapshot: Sendable {

    /// One entry per pasteboard item, mapping type identifier to its data.
    private let items: [[String: Data]]
    private let changeCount: Int

    init(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [String: Data] = [:]
            for type in item.types {
                // Promised types (file promises, lazily rendered images) return nil here.
                // There is no way to preserve those without resolving the promise, which
                // could be arbitrarily expensive — they are skipped, and the rest survives.
                if let data = item.data(forType: type) {
                    contents[type.rawValue] = data
                }
            }
            return contents
        }
    }

    /// Puts the captured contents back.
    ///
    /// If the user copied something else in the meantime, the newer clipboard wins: the
    /// change count tells us the pasteboard moved on, and clobbering a fresh copy would be
    /// worse than losing the restore.
    func restore(into pasteboard: NSPasteboard) {
        guard pasteboard.changeCount == changeCount + 1 else {
            Log.insertion.debug("Pasteboard changed meanwhile; leaving it alone")
            return
        }
        guard !items.isEmpty else {
            pasteboard.clearContents()
            return
        }

        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        pasteboard.clearContents()
        pasteboard.writeObjects(restored)
    }
}
