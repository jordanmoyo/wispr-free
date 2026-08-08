import AppKit
import SwiftUI

public final class OverlayPill {
    private var panel: NSPanel?
    private let state = PillState()
    private var errorGeneration = 0

    /// Where the pill appears; set by AppController from settings before
    /// each show and when the user changes it in Settings.
    public var position: PillPosition = .bottomCenter

    /// Language reminder under the waveform ("EN", "FR", or "FT" for free
    /// transcription); set by AppController from settings before each show.
    public var languageBadge: String {
        get { state.languageBadge }
        set { state.languageBadge = newValue }
    }

    /// True while a meeting is recording, being set up, or being torn down.
    /// Consulted on every `show()` rather than cached, so the pill picks up
    /// the current state even when the panel is being reused.
    public var isMeetingActive: () -> Bool = { false }

    /// Whether the pill should be omitted from screen recordings and shares.
    ///
    /// During a meeting the user is typically sharing their screen with the
    /// people in the call, and Wispr's own HUD is not theirs to see — a
    /// "call detected" notice or an error message would be shared along with
    /// everything else. Outside a meeting the pill stays capturable, so
    /// recording a screencast of Wispr still shows it.
    ///
    /// `.none` is the standard AppKit mechanism for this; the window keeps
    /// rendering normally on the physical display. Verified empirically
    /// against both capture paths with a solid-colour probe panel of known
    /// area: under `.readOnly` a ScreenCaptureKit grab of the display
    /// contained 539,996 of the expected 540,000 probe pixels and a
    /// `screencapture` grab contained exactly 2,160,000 (the same area at 2×
    /// backing scale); under `.none` both contained zero. Conferencing apps
    /// screen-share through ScreenCaptureKit, so that is the path that
    /// decides what the other participants see.
    static func sharingType(meetingActive: Bool) -> NSWindow.SharingType {
        meetingActive ? .none : .readOnly
    }

    /// The pill's resting width. Everything except an error message is a
    /// fixed-size glyph or animation, so they all fit this.
    static let baseWidth: CGFloat = 200

    /// No error message may push the pill past this. A message this long is
    /// a bug in the message, not a pill that needs to be wider.
    static let maximumWidth: CGFloat = 460

    /// Chrome around the error text: 14pt of padding each side, the warning
    /// glyph, and the 8pt `HStack` spacing before the text (see `PillView`).
    private static let errorChromeWidth: CGFloat = 14 * 2 + 17 + 8

    /// Width the panel needs for the given phase.
    ///
    /// `PillView` renders error text on one line, so a message wider than
    /// the space left over is truncated with an ellipsis. At the resting
    /// width that leaves 147pt — enough for about 25 characters, which
    /// silently cut "No audio captured — check mic in System Settings →
    /// Sound" off after "check mic i…". These messages exist to tell the
    /// user what to do about a dictation that produced nothing, so the pill
    /// grows to fit them instead.
    static func width(for phase: PillState.Phase) -> CGFloat {
        guard case .error(let message) = phase else { return baseWidth }
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
        return min(maximumWidth, max(baseWidth, ceil(textWidth) + errorChromeWidth))
    }

    public init() {}

    public func showRecording() {
        errorGeneration += 1
        state.phase = .recording
        state.levels = []
        state.locked = false
        show()
    }

    public func pushLevel(_ level: Float) {
        state.pushLevel(level)
    }

    /// Marks the current recording as hold-locked (see `HotkeyMonitor.onLockTap`):
    /// the pill shows a lock glyph and the hotkey can be released without
    /// stopping the recording.
    public func showLocked() {
        state.showLocked()
    }

    public func showTranscribing() {
        errorGeneration += 1
        state.phase = .transcribing
    }

    /// Distinguishes the AI cleanup/directive-transform step from raw
    /// transcription: same brand-bars animation, plus a sparkle glyph.
    public func showCleaning() {
        errorGeneration += 1
        state.phase = .cleaning
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
        // Re-evaluated on every show, not just at creation: the panel is
        // reused across shows, and a meeting can start or end between two of
        // them.
        panel.sharingType = Self.sharingType(meetingActive: isMeetingActive())
        let size = NSSize(width: Self.width(for: state.phase), height: 52)
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
