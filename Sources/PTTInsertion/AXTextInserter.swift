import AppKit
import ApplicationServices
import PTTSupport

/// Inserts text directly into the focused element using the Accessibility API.
///
/// This is the preferred path because it touches nothing the user owns: no pasteboard, no
/// synthetic keystrokes, no undo-history surprises. Setting `AXSelectedText` replaces the
/// current selection — and an empty selection is just the caret, so the same call performs
/// an insertion.
///
/// It does not work everywhere. Electron apps, terminals and most games either do not
/// expose a text element or report the attribute as read-only. Those cases return `false`
/// (not an error) so the service can fall back to the clipboard.
@MainActor
public final class AXTextInserter: TextInserting {

    /// How long to wait for another app to answer an Accessibility request.
    ///
    /// The default is 6 seconds — long enough that a busy app would visibly hang the
    /// dictation. Half a second is generous for an attribute read, and expiring simply
    /// means falling back to the clipboard.
    private static let messagingTimeout: Float = 0.5

    public init() {}

    public func insert(_ text: String) async throws -> Bool {
        try AccessibilityPermission.require()
        guard !text.isEmpty else { return true }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        guard let focused = copyElement(from: systemWide, attribute: kAXFocusedUIElementAttribute)
        else {
            // Logged at info, not debug: falling back to the clipboard is visible to the
            // user as a flicker, and `os_log` does not persist debug messages, so a
            // debug-level reason for a user-visible behaviour cannot be read back later.
            Log.insertion.info("Falling back to the clipboard: no focused element exposed")
            return false
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        // `AXSelectedText` is the only attribute that inserts *at the caret*. Writing
        // `AXValue` would replace the entire field's contents.
        //
        // Settability is the whole test. An earlier version also required the element's
        // role to be one of a handful of known text roles, which turned out to reject more
        // than it protected: web views, cross-platform toolkits and search fields all
        // report roles that are not on any sensible list, while a read-only element
        // answers this probe with `false` anyway.
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableStatus == .success, settable.boolValue else {
            Log.insertion.info(
                """
                Falling back to the clipboard: AXSelectedText not settable on \
                \(self.role(of: focused) ?? "an element with no role", privacy: .public)
                """
            )
            return false
        }

        let status = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard status == .success else {
            Log.insertion.info(
                "Falling back to the clipboard: AXSetAttributeValue returned \(status.rawValue)"
            )
            return false
        }

        Log.insertion.info("Inserted \(text.count) characters via Accessibility")
        return true
    }

    // MARK: - Element inspection

    private func copyElement(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    /// The element's Accessibility role, for the log. Knowing which role an app reports is
    /// the only way to find out why a particular app falls back to the clipboard.
    private func role(of element: AXUIElement) -> String? {
        copyString(from: element, attribute: kAXRoleAttribute)
    }
}
