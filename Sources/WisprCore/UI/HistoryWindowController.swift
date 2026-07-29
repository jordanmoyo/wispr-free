import AppKit
import SwiftUI

/// Follows `SettingsWindowController`'s rebuild-on-show pattern: a cached
/// `NSWindow` whose `contentView` is replaced with a fresh
/// `NSHostingView(rootView:)` on every `show()`, so the view's `@State`
/// re-syncs with the stores each time the window is reopened.
///
/// Unlike Settings, this window is resizable (`.resizable` in `styleMask`).
/// That's deliberate friction with `NSHostingView.sizingOptions =
/// [.preferredContentSize]`: that option makes the window track SwiftUI's
/// *preferred* content size, which fights the user the moment they drag an
/// edge — the next state change (e.g. selecting a row) would snap the frame
/// back. So the initial size (640×520 per the brief) is set once when the
/// window is created and never touched again; resizing after that is left
/// entirely to the user/AppKit.
public final class HistoryWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    public init(historyStore: HistoryStore, correctionStore: CorrectionStore, settings: SettingsStore) {
        makeView = {
            AnyView(HistoryView(historyStore: historyStore, correctionStore: correctionStore, settings: settings))
        }
    }

    public func show() {
        let targetWindow: NSWindow
        if let existing = window {
            targetWindow = existing
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            newWindow.title = "Wispr History"
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
            targetWindow = newWindow
        }

        // No `sizingOptions = .preferredContentSize` here — see the type
        // doc comment: this window is resizable and must not have its frame
        // fought over by SwiftUI's preferred-size tracking.
        let hostingView = NSHostingView(rootView: makeView())
        targetWindow.contentView = hostingView

        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
