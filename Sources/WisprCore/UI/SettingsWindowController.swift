import AppKit
import SwiftUI

public final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    public init(settings: SettingsStore, modelStore: ModelStore,
                onHotkeyChange: @escaping (Int64) -> Void,
                onModelChange: @escaping (String) -> Void,
                onCleanupToggle: @escaping (Bool) -> Void,
                onCleanupModelChange: @escaping (String) -> Void) {
        makeView = {
            AnyView(SettingsView(settings: settings, modelStore: modelStore,
                                 onHotkeyChange: onHotkeyChange,
                                 onModelChange: onModelChange,
                                 onCleanupToggle: onCleanupToggle,
                                 onCleanupModelChange: onCleanupModelChange))
        }
    }

    public func show() {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            newWindow.title = "Wispr Settings"
            newWindow.contentView = NSHostingView(rootView: makeView())
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
