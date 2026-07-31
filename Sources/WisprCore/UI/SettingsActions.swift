import SwiftUI
import AppKit

public struct HotkeyOption: Identifiable, Equatable {
    public let id: Int64
    public let label: String
    /// Short lowercase form for the sidebar status line ("hold fn to talk").
    public let shortLabel: String
}

public enum HotkeyOptions {
    public static let all: [HotkeyOption] = [
        HotkeyOption(id: 63, label: "Fn (Globe)", shortLabel: "fn"),
        HotkeyOption(id: 54, label: "Right ⌘", shortLabel: "right ⌘"),
        HotkeyOption(id: 61, label: "Right ⌥", shortLabel: "right ⌥"),
        HotkeyOption(id: 96, label: "F5", shortLabel: "F5"),
        HotkeyOption(id: 105, label: "F13", shortLabel: "F13"),
    ]

    public static func option(for keyCode: Int64) -> HotkeyOption {
        all.first { $0.id == keyCode } ?? all[0]
    }
}

/// Consolidated callbacks the main window reports back to its owner.
///
/// Construct with named defaults so call sites only need to specify the
/// callbacks they care about.
public struct SettingsActions {
    public var onHotkeyChange: (Int64) -> Void
    public var onModelChange: (String) -> Void
    public var onCleanupToggle: (Bool) -> Void
    public var onCleanupModelChange: (String) -> Void
    public var onLanguageChange: (String?) -> Void
    public var onPreRollToggle: (Bool) -> Void
    public var onUpdateCheckToggle: (Bool) -> Void
    public var onRulesChange: () -> Void
    public var onActivationModeChange: (ActivationMode) -> Void
    public var onPillPositionChange: (PillPosition) -> Void
    public var onInputDeviceChange: (String?) -> Void
    /// Applied immediately so toggling detection off/on takes effect without
    /// relaunching — see `AppController.applyMeetingAutoDetect`.
    public var onMeetingAutoDetectToggle: (Bool) -> Void

    public init(
        onHotkeyChange: @escaping (Int64) -> Void = { _ in },
        onModelChange: @escaping (String) -> Void = { _ in },
        onCleanupToggle: @escaping (Bool) -> Void = { _ in },
        onCleanupModelChange: @escaping (String) -> Void = { _ in },
        onLanguageChange: @escaping (String?) -> Void = { _ in },
        onPreRollToggle: @escaping (Bool) -> Void = { _ in },
        onUpdateCheckToggle: @escaping (Bool) -> Void = { _ in },
        onRulesChange: @escaping () -> Void = {},
        onActivationModeChange: @escaping (ActivationMode) -> Void = { _ in },
        onPillPositionChange: @escaping (PillPosition) -> Void = { _ in },
        onInputDeviceChange: @escaping (String?) -> Void = { _ in },
        onMeetingAutoDetectToggle: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onHotkeyChange = onHotkeyChange
        self.onModelChange = onModelChange
        self.onCleanupToggle = onCleanupToggle
        self.onCleanupModelChange = onCleanupModelChange
        self.onLanguageChange = onLanguageChange
        self.onPreRollToggle = onPreRollToggle
        self.onUpdateCheckToggle = onUpdateCheckToggle
        self.onRulesChange = onRulesChange
        self.onActivationModeChange = onActivationModeChange
        self.onPillPositionChange = onPillPositionChange
        self.onInputDeviceChange = onInputDeviceChange
        self.onMeetingAutoDetectToggle = onMeetingAutoDetectToggle
    }
}

/// A candidate running app offered in the "Add rule…" popover.
struct DeliveryRuleCandidate: Identifiable {
    let bundleIdentifier: String
    let displayName: String
    var id: String { bundleIdentifier }
}

/// Popover listing running apps that don't already have a delivery rule,
/// for adding a new one.
struct AddRulePopover: View {
    let existingBundleIDs: Set<String>
    let onSelect: (DeliveryRuleCandidate) -> Void

    private var candidates: [DeliveryRuleCandidate] {
        var seen = Set<String>()
        var result: [DeliveryRuleCandidate] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !existingBundleIDs.contains(bundleID),
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(DeliveryRuleCandidate(
                bundleIdentifier: bundleID, displayName: app.localizedName ?? bundleID))
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        List(candidates) { candidate in
            Button(candidate.displayName) {
                onSelect(candidate)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 260, height: 300)
    }
}
