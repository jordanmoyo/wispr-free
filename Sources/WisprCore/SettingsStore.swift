import Foundation

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
