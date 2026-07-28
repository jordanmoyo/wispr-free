import AppKit

public final class StatusItemController {
    public enum Icon {
        case idle, recording, transcribing

        var symbolName: String {
            switch self {
            case .idle: return "waveform"
            case .recording: return "waveform.badge.mic"
            case .transcribing: return "ellipsis.circle"
            }
        }
    }

    private let statusItem: NSStatusItem
    public let menu = NSMenu()

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        setIcon(.idle)
    }

    public func setIcon(_ icon: Icon) {
        if icon == .idle {
            statusItem.button?.image = Self.idleGlyph
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: icon.symbolName,
                accessibilityDescription: "Wispr Free")
        }
    }

    // The brand waveform-pill mark, drawn as a template image so macOS tints
    // it for light/dark menu bars. Drawn in code (not a bundled bitmap) so it
    // renders crisp at any backing scale and at a size that matches
    // neighboring menu-bar icons.
    private static let idleGlyph: NSImage = {
        let canvas = NSSize(width: 22, height: 10)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let stroke: CGFloat = 1.5
            let pillRect = NSRect(origin: .zero, size: canvas)
                .insetBy(dx: stroke / 2, dy: stroke / 2)
            let pill = NSBezierPath(
                roundedRect: pillRect,
                xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            pill.lineWidth = stroke
            NSColor.black.setStroke()
            pill.stroke()

            // Bar height ratios from the brand mark (56/108/152/108/56 of 224).
            let heights: [CGFloat] = [2.2, 4.2, 5.9, 4.2, 2.2]
            let barWidth: CGFloat = 1.8
            let spacing: CGFloat = 1.4
            let totalWidth = CGFloat(heights.count) * barWidth
                + CGFloat(heights.count - 1) * spacing
            var x = (canvas.width - totalWidth) / 2
            NSColor.black.setFill()
            for height in heights {
                let bar = NSRect(
                    x: x, y: (canvas.height - height) / 2,
                    width: barWidth, height: height)
                NSBezierPath(
                    roundedRect: bar,
                    xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + spacing
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wispr Free"
        return image
    }()
}
