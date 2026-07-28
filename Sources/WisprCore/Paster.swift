import AppKit
import ApplicationServices

public enum Paster {
    /// Copies text to the clipboard (always) and inserts into the focused
    /// text element if one exists. Returns true if an insertion happened.
    ///
    /// Insertion avoids synthesizing ⌘V: Electron apps process a synthetic
    /// ⌘V twice (key event + menu accelerator), pasting the text twice.
    /// AX insertion is tried first; otherwise the text is typed as Unicode
    /// keyboard events, which every app handles exactly once.
    @discardableResult
    public static func deliver(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let element = focusedTextElement() else { return false }
        if insertViaAX(text, into: element) {
            WisprLog.log("Paster: inserted via AX")
        } else {
            typeUnicode(text)
            WisprLog.log("Paster: typed as unicode events")
        }
        return true
    }

    private static func insertViaAX(_ text: String, into element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString,
                                             &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success
    }

    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        // keyboardSetUnicodeString only carries ~20 UTF-16 units per event.
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index..<min(index + 20, utf16.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.flags = []
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cgSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            up?.post(tap: .cgSessionEventTap)
            index += 20
        }
    }

    public static func focusedElementAcceptsText() -> Bool {
        focusedTextElement() != nil
    }

    /// Returns the focused UI element if it accepts text input.
    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return element
        }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String else { return nil }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox",
                                      "AXSearchField", "AXWebArea"]
        return textRoles.contains(role) ? element : nil
    }
}
