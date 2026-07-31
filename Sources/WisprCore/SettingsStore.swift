import Foundation

/// How the push-to-talk key starts and stops a dictation.
public enum ActivationMode: String, CaseIterable {
    /// Hold the key down to record, release to transcribe.
    case hold
    /// Press once to start recording, press again to stop.
    case toggle
}

/// Where the recording pill overlay appears on screen.
public enum PillPosition: String, CaseIterable {
    case bottomCenter
    case topCenter
    case nearCursor

    public var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .nearCursor: return "Near cursor"
        }
    }
}

public final class SettingsStore {
    private enum Keys {
        static let selectedModelID = "selectedModelID"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupModelID = "cleanupModelID"
        static let pinnedLanguage = "pinnedLanguage"
        static let updateCheckEnabled = "updateCheckEnabled"
        static let historyEnabled = "historyEnabled"
        static let learningEnabled = "learningEnabled"
        static let deliveryRules = "deliveryRules"
        static let preRollEnabled = "preRollEnabled"
        static let feedbackSounds = "feedbackSounds"
        static let activationMode = "activationMode"
        static let pillPosition = "pillPosition"
        static let inputDeviceUID = "inputDeviceUID"
        static let retainAudio = "retainAudio"
        static let meetingRetentionGB = "meetingRetentionGB"
        static let meetingRetentionDays = "meetingRetentionDays"
        static let meetingAutoDetect = "meetingAutoDetect"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedModelID: String {
        get { defaults.string(forKey: Keys.selectedModelID) ?? "large-v3-turbo" }
        set { defaults.set(newValue, forKey: Keys.selectedModelID) }
    }

    public var hotkeyKeyCode: Int64 {
        get {
            let value = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int
            return value.map(Int64.init) ?? 63
        }
        set { defaults.set(Int(newValue), forKey: Keys.hotkeyKeyCode) }
    }

    public var cleanupEnabled: Bool {
        get { defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.cleanupEnabled) }
    }

    public var cleanupModelID: String {
        get { defaults.string(forKey: Keys.cleanupModelID) ?? "qwen3-4b" }
        set { defaults.set(newValue, forKey: Keys.cleanupModelID) }
    }

    /// Pinned dictation language code (e.g. "fr"), or nil for auto-detect.
    public var pinnedLanguage: String? {
        get { defaults.string(forKey: Keys.pinnedLanguage) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.pinnedLanguage)
            } else {
                defaults.removeObject(forKey: Keys.pinnedLanguage)
            }
        }
    }

    public var updateCheckEnabled: Bool {
        get { defaults.object(forKey: Keys.updateCheckEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.updateCheckEnabled) }
    }

    public var historyEnabled: Bool {
        get { defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.historyEnabled) }
    }

    /// Whether corrections are learned from edits and applied automatically
    /// (see `CorrectionStore` / `CorrectionApplier`).
    public var learningEnabled: Bool {
        get { defaults.object(forKey: Keys.learningEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.learningEnabled) }
    }

    /// Whether the recorder keeps a rolling 0.5 s pre-roll buffer so the
    /// last bit of audio before the hotkey is pressed is included in the
    /// transcription. Opt-in (default off) since it keeps the mic active
    /// continuously while Wispr runs.
    public var preRollEnabled: Bool {
        get { defaults.object(forKey: Keys.preRollEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.preRollEnabled) }
    }

    /// Whether a soft chime plays when recording starts and stops.
    public var feedbackSounds: Bool {
        get { defaults.object(forKey: Keys.feedbackSounds) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.feedbackSounds) }
    }

    /// Whether each dictation's raw audio is retained on disk (see
    /// `AudioArchiveStore`) so History can replay or re-transcribe it.
    /// Opt-in (default off) — audio is normally transcribed and discarded.
    public var retainAudio: Bool {
        get { defaults.object(forKey: Keys.retainAudio) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.retainAudio) }
    }

    /// Unknown stored values fail open to `.hold` (the historical behavior).
    public var activationMode: ActivationMode {
        get {
            guard let raw = defaults.string(forKey: Keys.activationMode),
                  let mode = ActivationMode(rawValue: raw) else { return .hold }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.activationMode) }
    }

    /// Unknown stored values fail open to `.bottomCenter` (the historical
    /// position).
    public var pillPosition: PillPosition {
        get {
            guard let raw = defaults.string(forKey: Keys.pillPosition),
                  let position = PillPosition(rawValue: raw) else { return .bottomCenter }
            return position
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.pillPosition) }
    }

    /// CoreAudio device UID of the preferred input device, or nil to follow
    /// the system default input.
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: Keys.inputDeviceUID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.inputDeviceUID)
            } else {
                defaults.removeObject(forKey: Keys.inputDeviceUID)
            }
        }
    }

    /// How many gigabytes of meeting audio to keep before the oldest tracks
    /// are pruned (see `MeetingAudioStore.enforceRetention`). Clamped to
    /// 1...100 on BOTH read and write, so a stray value can't silently
    /// disable retention (0 or negative) or let the store grow unbounded —
    /// clamping only on write left a value already sitting out-of-range in
    /// `UserDefaults` (a corrupted plist, a stray manual edit, a future
    /// build that once wrote a wider range) unclamped forever, since the
    /// getter only supplies `5` when the key is entirely ABSENT, not when
    /// it's present but out of range.
    public var meetingRetentionGB: Int {
        get { min(100, max(1, (defaults.object(forKey: Keys.meetingRetentionGB) as? Int) ?? 5)) }
        set { defaults.set(min(100, max(1, newValue)), forKey: Keys.meetingRetentionGB) }
    }

    /// `meetingRetentionGB` converted to bytes for `MeetingAudioStore`, which
    /// works in bytes, not gigabytes.
    public var meetingRetentionBytes: Int64 {
        Int64(meetingRetentionGB) * 1024 * 1024 * 1024
    }

    /// How many days of meeting audio to keep before the oldest tracks are
    /// pruned. Clamped to 1...3650 on BOTH read and write, for the same
    /// reason as `meetingRetentionGB`: a value already out of range in
    /// `UserDefaults` must not silently reach `MeetingAudioStore
    /// .enforceRetention` — a stored `0`, in particular, would push its
    /// cutoff to "now" and evict every meeting's audio outright.
    public var meetingRetentionDays: Int {
        get { min(3_650, max(1, (defaults.object(forKey: Keys.meetingRetentionDays) as? Int) ?? 90)) }
        set { defaults.set(min(3_650, max(1, newValue)), forKey: Keys.meetingRetentionDays) }
    }

    /// Whether `CallAppMonitor` polls for calls in progress and offers to
    /// record them. Default on; the offer itself still requires an explicit
    /// tap to start recording, so this only controls the passive polling.
    public var meetingAutoDetect: Bool {
        get { defaults.object(forKey: Keys.meetingAutoDetect) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.meetingAutoDetect) }
    }

    /// Per-app delivery rules (see `DeliveryRule`). Stored as JSON-encoded
    /// `Data` since `UserDefaults` has no native support for arrays of
    /// custom `Codable` structs. Missing or corrupt data fails open to an
    /// empty list (default `.insert` behavior everywhere) rather than
    /// throwing or crashing.
    public var deliveryRules: [DeliveryRule] {
        get {
            guard let data = defaults.data(forKey: Keys.deliveryRules),
                  let rules = try? JSONDecoder().decode([DeliveryRule].self, from: data) else {
                return []
            }
            return rules
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.deliveryRules)
        }
    }
}
