import AppKit
import SwiftUI

public final class OverlayPill {
    private var panel: NSPanel?
    private let state = PillState()
    private var errorGeneration = 0

    /// Where the pill appears; set by AppController from settings before
    /// each show and when the user changes it in Settings.
    public var position: PillPosition = .bottomCenter

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
        let size = NSSize(width: 200, height: 44)
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let origin: NSPoint
            switch position {
            case .bottomCenter:
                origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 60)
            case .topCenter:
                origin = NSPoint(x: frame.midX - size.width / 2,
                                 y: frame.maxY - size.height - 24)
            case .nearCursor:
                // Just below the pointer, clamped so the pill never leaves
                // the visible screen area.
                let x = min(max(mouse.x - size.width / 2, frame.minX + 8),
                            frame.maxX - size.width - 8)
                let y = min(max(mouse.y - size.height - 28, frame.minY + 8),
                            frame.maxY - size.height - 8)
                origin = NSPoint(x: x, y: y)
            }
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }
}
