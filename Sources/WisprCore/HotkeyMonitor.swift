import AppKit
import CoreGraphics

public final class HotkeyMonitor {
    public var keyCode: Int64 = 63  // Fn
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    /// Fired when a Shift key is pressed while the hotkey is held — the
    /// hold-lock gesture. Shift is used (not Space, as some apps do)
    /// because the tap is .listenOnly and cannot swallow a real keystroke;
    /// a modifier emits no character into the focused field. Disabled when
    /// the hotkey itself is a Shift key.
    public var onLockTap: (() -> Void)?

    private static let shiftKeyCodes: Set<Int64> = [56, 60]
    private var shiftWasDown = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    public init() {}

    deinit {
        stop()
    }

    /// Returns false if the event tap could not be created (missing permissions).
    public func start() -> Bool {
        stop()
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            WisprLog.log("HotkeyMonitor: tapCreate returned nil (Input Monitoring not effective for this binary)")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        WisprLog.log("HotkeyMonitor: tap created and enabled (keyCode=\(keyCode))")
        return true
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        isDown = false
        shiftWasDown = false
    }

    private var eventsSeen = 0

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            WisprLog.log("HotkeyMonitor: tap disabled by OS (type=\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        eventsSeen += 1
        if eventsSeen <= 5 {
            WisprLog.log("HotkeyMonitor: event #\(eventsSeen) type=\(type.rawValue) code=\(code) flags=\(event.flags.rawValue)")
        }
        if type == .flagsChanged, Self.shiftKeyCodes.contains(code),
           !Self.shiftKeyCodes.contains(keyCode) {
            let shiftDown = event.flags.contains(.maskShift)
            if shiftDown && !shiftWasDown && isDown {
                DispatchQueue.main.async { [weak self] in self?.onLockTap?() }
            }
            shiftWasDown = shiftDown
        }
        if let mask = Self.modifierMasks[keyCode] {
            // Modifier keys never emit keyDown/keyUp — only flagsChanged.
            guard type == .flagsChanged, code == keyCode else { return }
            transition(down: event.flags.contains(mask))
        } else {
            guard code == keyCode else { return }
            switch type {
            case .keyDown: transition(down: true)
            case .keyUp: transition(down: false)
            default: break
            }
        }
    }

    private static let modifierMasks: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,      // right/left ⌘
        56: .maskShift, 60: .maskShift,          // left/right ⇧
        58: .maskAlternate, 61: .maskAlternate,  // left/right ⌥
        59: .maskControl, 62: .maskControl,      // left/right ⌃
        63: .maskSecondaryFn,                    // Fn
    ]

    private func transition(down: Bool) {
        guard down != isDown else { return }
        isDown = down
        WisprLog.log("HotkeyMonitor: transition \(down ? "DOWN" : "UP")")
        let callback = down ? onPress : onRelease
        DispatchQueue.main.async { callback?() }
    }
}
