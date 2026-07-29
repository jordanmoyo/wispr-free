import AppKit
import SwiftUI

public final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    public init(settings: SettingsStore, modelStore: ModelStore, actions: SettingsActions) {
        makeView = {
            AnyView(SettingsView(settings: settings, modelStore: modelStore, actions: actions))
        }
    }

    public func show() {
        let targetWindow: NSWindow
        if let existing = window {
            targetWindow = existing
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            newWindow.title = "Wispr Settings"
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
            targetWindow = newWindow
        }

        let hostingView = NSHostingView(rootView: makeView())
        // Track SwiftUI's preferred size so the window grows/shrinks when the
        // user switches to a taller tab (fittingSize alone is a one-shot
        // measurement of the initially selected tab).
        hostingView.sizingOptions = [.preferredContentSize]
        targetWindow.contentView = hostingView
        targetWindow.setContentSize(hostingView.fittingSize)

        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
