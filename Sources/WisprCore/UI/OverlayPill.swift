import AppKit
import SwiftUI

public final class OverlayPill {
    private var panel: NSPanel?
    private let state = PillState()
    private var errorGeneration = 0

    public init() {}

    public func showRecording() {
        errorGeneration += 1
        state.phase = .recording
        state.levels = []
        show()
    }

    public func pushLevel(_ level: Float) {
        state.pushLevel(level)
    }

    public func showTranscribing() {
        errorGeneration += 1
        state.phase = .transcribing
    }

    public func showError(_ message: String) {
        errorGeneration += 1
        let gen = errorGeneration
        state.phase = .error(message)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if self.errorGeneration == gen && self.state.phase == .error(message) {
                self.hide()
            }
        }
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: PillView(state: state))
            let newPanel = NSPanel(contentRect: .zero,
                                   styleMask: [.nonactivatingPanel, .borderless],
                                   backing: .buffered, defer: false)
            newPanel.isFloatingPanel = true
            newPanel.level = .statusBar
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = true
            newPanel.hidesOnDeactivate = false
            newPanel.ignoresMouseEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.contentView = hosting
            panel = newPanel
        }
        guard let panel else { return }
        panel.setContentSize(NSSize(width: 200, height: 44))
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - 100, y: frame.minY + 60)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }
}
