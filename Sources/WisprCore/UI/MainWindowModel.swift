import SwiftUI

/// Sidebar destinations of the unified main window, grouped as in the
/// design: Dictation, Settings, Info.
public enum MainTab: String, CaseIterable {
    case history, meetings, learning
    case general, pushToTalk, microphone, languageModel, privacy
    case about

    var label: String {
        switch self {
        case .history: return "History"
        case .meetings: return "Meetings"
        case .learning: return "Learning"
        case .general: return "General"
        case .pushToTalk: return "Push to Talk"
        case .microphone: return "Microphone"
        case .languageModel: return "Language & Model"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    static let groups: [(label: String, tabs: [MainTab])] = [
        ("Dictation", [.history, .meetings, .learning]),
        ("Settings", [.general, .pushToTalk, .microphone, .languageModel, .privacy]),
        ("Info", [.about]),
    ]
}

/// What the dictation pipeline is doing right now, for the sidebar header.
public enum ActivityStatus {
    case ready, recording, transcribing, cleaning
}

/// Shared state between AppController (which drives activity/hotkey) and
/// the main window's SwiftUI hierarchy.
@MainActor
public final class MainWindowModel: ObservableObject {
    @Published public var selectedTab: MainTab = .history
    @Published public var activity: ActivityStatus = .ready
    /// Display label of the current push-to-talk key (e.g. "fn").
    @Published public var hotkeyLabel: String = "fn"
    /// Activation phrasing for the status line ("hold" vs "press").
    @Published public var activationVerb: String = "hold"

    public init() {}

    var statusText: String {
        switch activity {
        case .ready: return "Ready — \(activationVerb) \(hotkeyLabel) to talk"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        }
    }

    var statusColor: Color {
        switch activity {
        case .ready: return Theme.secondaryText
        case .recording: return Theme.darkGold
        case .transcribing, .cleaning: return Theme.navy
        }
    }

    var dotColor: Color {
        activity == .ready ? Theme.green : Theme.gold
    }
}
