import Foundation

public final class SettingsStore {
    private enum Keys {
        static let selectedModelID = "selectedModelID"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let cleanupEnabled = "cleanupEnabled"
        static let cleanupModelID = "cleanupModelID"
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
}
