import Foundation

public enum TranscriptionJobStatus: String, Codable, Sendable {
    case processing, complete, partial, failed
}

/// One chapter of a long recording: where it starts and what it is about.
public struct TranscriptChapter: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: TimeInterval
    public let title: String

    public init(id: UUID = UUID(), start: TimeInterval, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }
}

/// Which generated document the user asked for.
public enum TranscriptOutputKind: String, Codable, Sendable, CaseIterable {
    case cleanTranscript, summary, report, chapters

    public var label: String {
        switch self {
        case .cleanTranscript: return "Clean transcript"
        case .summary: return "Summary"
        case .report: return "Report"
        case .chapters: return "Chapters"
        }
    }
}

/// One uploaded file's transcription and everything generated from it.
///
/// `sourcePath` is a REFERENCE, never a copy: the file is already on the
/// user's disk and copying two-hour recordings would cost gigabytes for
/// nothing. A moved source still shows its transcript; only playback fails.
public struct TranscriptionJob: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var sourcePath: String
    public var durationSeconds: Double
    public var status: TranscriptionJobStatus
    public var transcriptionModelID: String
    public var enhancementModelID: String
    public var language: String?
    public var diarizationRequested: Bool
    public var segments: [MeetingTranscriptSegment]
    public var speakerNames: [String: String]
    /// Map-phase output, cached so Summary, Report and Chapters each reduce
    /// from one shared condensation instead of re-running the expensive pass.
    public var mapNotes: [String]
    public var cleanTranscript: String
    public var summary: String
    public var actionItems: [String]
    public var decisions: [String]
    public var report: String
    public var chapters: [TranscriptChapter]
    /// User-facing reason the job is `.partial` or `.failed`, empty otherwise.
    public var failureNote: String

    public init(id: UUID = UUID(), title: String, createdAt: Date,
                sourcePath: String, durationSeconds: Double,
                status: TranscriptionJobStatus = .processing,
                transcriptionModelID: String, enhancementModelID: String,
                language: String? = nil, diarizationRequested: Bool,
                segments: [MeetingTranscriptSegment] = [],
                speakerNames: [String: String] = [:],
                mapNotes: [String] = [], cleanTranscript: String = "",
                summary: String = "", actionItems: [String] = [],
                decisions: [String] = [], report: String = "",
                chapters: [TranscriptChapter] = [], failureNote: String = "") {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourcePath = sourcePath
        self.durationSeconds = durationSeconds
        self.status = status
        self.transcriptionModelID = transcriptionModelID
        self.enhancementModelID = enhancementModelID
        self.language = language
        self.diarizationRequested = diarizationRequested
        self.segments = segments
        self.speakerNames = speakerNames
        self.mapNotes = mapNotes
        self.cleanTranscript = cleanTranscript
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.report = report
        self.chapters = chapters
        self.failureNote = failureNote
    }

    /// The filename without its extension, which is what a user recognises.
    public static func defaultTitle(sourcePath: String) -> String {
        let name = URL(fileURLWithPath: sourcePath)
            .deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? "Recording" : name
    }

    public func displayName(for speaker: MeetingSpeaker) -> String {
        switch speaker {
        case .you: return "You"
        case .others: return "Speaker"
        case .remote(let id): return speakerNames[id] ?? "Speaker \(id)"
        }
    }
}
