import AppKit
import SwiftUI

/// The single main window (history + learning + settings + about), sized
/// explicitly per the design. Deliberately NOT sized from
/// `NSHostingView.fittingSize`: that measurement returned 0×0 for the old
/// tabbed Settings window on macOS 26, collapsing it to an invisible
/// titlebar sliver (the "settings don't appear" bug this window replaces).
@MainActor
public final class MainWindowController {
    private var window: NSWindow?
    private let model: MainWindowModel
    private let makeView: () -> AnyView
    private var closeObserver: NSObjectProtocol?

    public init(model: MainWindowModel, settings: SettingsStore, modelStore: ModelStore,
                historyStore: HistoryStore, correctionStore: CorrectionStore,
                vocabularyStore: VocabularyStore, audioArchive: AudioArchiveStore,
                meetingStore: MeetingStore, meetingAudioStore: MeetingAudioStore,
                actions: SettingsActions, retranscribe: @escaping (HistoryEntry) -> Void,
                meetingsCoordinator: any MeetingsCoordinating) {
        self.model = model
        let context = MainWindowContext(
            settings: settings, modelStore: modelStore, historyStore: historyStore,
            correctionStore: correctionStore, vocabularyStore: vocabularyStore,
            audioArchive: audioArchive, meetingStore: meetingStore,
            meetingAudioStore: meetingAudioStore, actions: actions,
            retranscribe: retranscribe, meetingsCoordinator: meetingsCoordinator)
        makeView = { AnyView(MainWindowView(model: model, context: context)) }
    }

    public func show(tab: MainTab) {
        model.selectedTab = tab
        let targetWindow: NSWindow
        if let existing = window {
            targetWindow = existing
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable,
                            .fullSizeContentView],
                backing: .buffered, defer: false)
            newWindow.title = "Wispr Free"
            // The design draws its own chrome: traffic lights float over the
            // sidebar, no separate titlebar band.
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            // The design system is light-palette; pin the window so it looks
            // as designed regardless of system appearance.
            newWindow.appearance = NSAppearance(named: .aqua)
            newWindow.minSize = NSSize(width: 980, height: 640)
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = NSHostingView(rootView: makeView())
            newWindow.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow,
                queue: .main
            ) { _ in
                // Back to menu-bar-only once the window is gone.
                NSApp.setActivationPolicy(.accessory)
            }
            window = newWindow
            targetWindow = newWindow
        }
        // The app is a menu-bar accessory (LSUIElement); give it a Dock icon
        // and Cmd-Tab presence while the main window is open.
        NSApp.setActivationPolicy(.regular)
        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
