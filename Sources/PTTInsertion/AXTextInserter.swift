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
            Log.insertion.debug("No focused element exposed to Accessibility")
            return false
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        guard isTextElement(focused) else {
            Log.insertion.debug("Focused element is not a text area")
            return false
        }

        // `AXSelectedText` is the only attribute that inserts *at the caret*. Writing
        // `AXValue` would replace the entire field's contents.
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableStatus == .success, settable.boolValue else {
            Log.insertion.debug("AXSelectedText is not settable here")
            return false
        }

        let status = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard status == .success else {
            Log.insertion.debug("AXSetAttributeValue failed with \(status.rawValue)")
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

    /// Accepts the roles that behave like editable text.
    ///
    /// Checking the role first avoids writing into something that merely happens to expose
    /// a selected-text attribute, such as a read-only web view.
    private func isTextElement(_ element: AXUIElement) -> Bool {
        guard let role = copyString(from: element, attribute: kAXRoleAttribute) else {
            return false
        }
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSearchFieldSubrole:
            return true
        default:
            // Web content reports AXTextArea inside AXWebArea in some browsers and a bare
            // AXGroup in others; the settability probe that follows is the real gate.
            return role == "AXTextField" || role == "AXTextArea"
        }
    }
}
