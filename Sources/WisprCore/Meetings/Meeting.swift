import Foundation

/// Who spoke a transcript segment. The local user is known by construction
/// (the mic track); remote speakers come from diarization, and `others` is
/// the fallback when diarization is unavailable or failed.
public enum MeetingSpeaker: Codable, Hashable, Sendable {
    case you
    case remote(String)
    case others
}

public struct MeetingTranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let speaker: MeetingSpeaker
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(id: UUID = UUID(), speaker: MeetingSpeaker,
                start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, processing, complete, partial, failed
}

public struct Meeting: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let startedAt: Date
    public var durationSeconds: Double
    public var status: MeetingStatus
    public var segments: [MeetingTranscriptSegment]
    public var summary: String
    public var actionItems: [String]
    public var decisions: [String]
    public var userNotes: String
    public var enhancedNotes: String
    /// Diarization speaker id → user-visible display name.
    public var speakerNames: [String: String]
    /// Bundle id of the call app when auto-detection identified one.
    public var appBundleID: String?
    /// Persisted for a future cross-meeting speaker-recognition feature.
    public var speakerEmbeddings: [String: [Float]]?

    public init(id: UUID = UUID(), title: String, startedAt: Date,
                durationSeconds: Double = 0, status: MeetingStatus = .recording,
                segments: [MeetingTranscriptSegment] = [], summary: String = "",
                actionItems: [String] = [], decisions: [String] = [],
                userNotes: String = "", enhancedNotes: String = "",
                speakerNames: [String: String] = [:], appBundleID: String? = nil,
                speakerEmbeddings: [String: [Float]]? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.status = status
        self.segments = segments
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.userNotes = userNotes
        self.enhancedNotes = enhancedNotes
        self.speakerNames = speakerNames
        self.appBundleID = appBundleID
        self.speakerEmbeddings = speakerEmbeddings
    }

    /// Display name for a speaker, honouring user renames.
    public func displayName(for speaker: MeetingSpeaker) -> String {
        switch speaker {
        case .you: return "You"
        case .others: return "Others"
        case .remote(let id): return speakerNames[id] ?? "Speaker \(id)"
        }
    }

    /// Default title from an optional detected app name plus the start time,
    /// e.g. "Zoom — 30 July, 09:14" or "Meeting — 30 July, 09:14".
    public static func defaultTitle(appName: String?, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM, HH:mm"
        return "\(appName ?? "Meeting") — \(formatter.string(from: startedAt))"
    }
}
