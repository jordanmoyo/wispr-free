import AppKit
import ApplicationServices

public enum Paster {
    /// Copies text to the clipboard (always set) and, depending on `mode`,
    /// inserts it into the focused text element. Returns true if an
    /// insertion happened.
    ///
    /// - `.insert` (default): current behavior. AX insertion is tried
    ///   first; otherwise the text is typed as Unicode keyboard events,
    ///   which every app handles exactly once (unlike a synthesized ⌘V,
    ///   which Electron apps process twice — key event + menu accelerator —
    ///   pasting the text twice).
    /// - `.copyOnly`: pasteboard is set, nothing is inserted; returns false.
    /// - `.insertAndSend`: types the text (unicode events only — the AX
    ///   path is skipped so this always goes through the same keyboard
    ///   path as a terminal-safe check can reason about), waits 100ms,
    ///   re-verifies the frontmost app still matches `expectedFrontmost`
    ///   (focus may have moved on during typing), and only then simulates
    ///   Return. A mismatch skips the Return but still returns true (text
    ///   was typed).
    ///
    /// - Parameter conceal: true when the dictation target is a secure
    ///   text field (e.g. a password field). When true, the general
    ///   pasteboard is never written — not even transiently — and delivery
    ///   always goes through Unicode typing (the AX insert path is skipped
    ///   too: secure fields reject AX value setting anyway). Under
    ///   `.copyOnly` with `conceal == true`, nothing is delivered at all,
    ///   since copy-only's entire purpose is placing text on the clipboard.
    @discardableResult
    public static func deliver(
        _ text: String, mode: DeliveryMode = .insert, expectedFrontmost: String? = nil, conceal: Bool = false
    ) -> Bool {
        guard !text.isEmpty else { return false }

        if conceal {
            return deliverConcealed(text, mode: mode, expectedFrontmost: expectedFrontmost)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        switch mode {
        case .copyOnly:
            WisprLog.log("Paster: copyOnly, nothing inserted")
            return false
        case .insertAndSend:
            typeUnicode(text)
            WisprLog.log("Paster: typed as unicode events (insertAndSend)")
            usleep(100_000)
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard frontmost == expectedFrontmost else {
                WisprLog.log("Paster: frontmost changed (expected=\(expectedFrontmost ?? "nil") actual=\(frontmost ?? "nil")), skipping Return")
                return true
            }
            postReturn()
            WisprLog.log("Paster: sent Return")
            return true
        case .insert:
            // Some apps (Electron, web views, custom widgets) don't expose
            // their focused field through AX, so detection failing doesn't
            // mean there is no text field. Type anyway: whatever has
            // keyboard focus receives the events, and the clipboard copy
            // above remains as a manual fallback.
            guard let element = focusedTextElement() else {
                typeUnicode(text)
                WisprLog.log("Paster: no AX text element, typed as unicode events")
                return true
            }
            if insertViaAX(text, into: element) {
                WisprLog.log("Paster: inserted via AX")
            } else {
                typeUnicode(text)
                WisprLog.log("Paster: typed as unicode events")
            }
            return true
        }
    }

    /// Delivery path for a secure (password) target: never touches the
    /// general pasteboard, and always types via Unicode events (no AX
    /// insert — secure fields reject AX value setting anyway).
    private static func deliverConcealed(_ text: String, mode: DeliveryMode, expectedFrontmost: String?) -> Bool {
        switch mode {
        case .copyOnly:
            // Copy-only's whole purpose is placing text on the clipboard —
            // with that suppressed for a secure target, there's nothing
            // left to do.
            WisprLog.log("Paster: secure target: clipboard delivery suppressed")
            return false
        case .insert:
            typeUnicode(text)
            WisprLog.log("Paster: secure target: typed as unicode events, clipboard untouched")
            return true
        case .insertAndSend:
            typeUnicode(text)
            WisprLog.log("Paster: secure target: typed as unicode events, clipboard untouched")
            usleep(100_000)
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard frontmost == expectedFrontmost else {
                WisprLog.log("Paster: frontmost changed (expected=\(expectedFrontmost ?? "nil") actual=\(frontmost ?? "nil")), skipping Return")
                return true
            }
            postReturn()
            WisprLog.log("Paster: sent Return")
            return true
        }
    }

    /// Simulates pressing Return (keycode 36), no modifier flags.
    private static func postReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        down?.flags = []
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        up?.flags = []
        up?.post(tap: .cgSessionEventTap)
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
