import Foundation

/// How dictated text is delivered into the target app.
public enum DeliveryMode: String, Codable, CaseIterable, Sendable {
    /// Type/insert automatically (current default behavior).
    case insert
    /// Only place text on the pasteboard; never type or insert it.
    case copyOnly
    /// Type the text, then simulate pressing Return.
    case insertAndSend
}

/// A per-app register (formality) preference applied to LLM cleanup.
public enum TonePreset: String, Codable, CaseIterable, Sendable {
    case casual, formal

    public var displayName: String {
        switch self {
        case .casual: return "Casual"
        case .formal: return "Formal"
        }
    }
}

/// A per-app override of the default delivery behavior.
public struct DeliveryRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let displayName: String
    public var mode: DeliveryMode
    /// Optional register preference. `nil` (the default, and what
    /// pre-0.5 persisted JSON without this key decodes to) means no tone
    /// adjustment is applied.
    public var tone: TonePreset?

    public init(bundleID: String, displayName: String, mode: DeliveryMode, tone: TonePreset? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.mode = mode
        self.tone = tone
    }
}

/// Resolves the delivery mode to use for a given dictation, combining
/// per-app rules with runtime safety degradations (frontmost-app mismatch,
/// terminal apps). Fails open: unknown/missing rules always default to
/// `.insert`.
public enum DeliveryPolicy {
    /// Terminal apps process Return as command submission; insert-and-send
    /// is never safe there, so it's silently degraded to plain insert.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    /// The rule-configured mode for `target`, ignoring runtime degradations.
    /// No matching rule (or no target) defaults to `.insert`.
    public static func ruleMode(rules: [DeliveryRule], target: String?) -> DeliveryMode {
        guard let target else { return .insert }
        return rules.first(where: { $0.bundleID == target })?.mode ?? .insert
    }

    /// The mode to actually use, after degrading `ruleMode` for runtime
    /// safety: if the frontmost app no longer matches the dictation target,
    /// deliver copy-only regardless of configured mode; otherwise, refuse
    /// insert-and-send in terminal apps (falls back to plain insert).
    public static func effectiveMode(rules: [DeliveryRule], target: String?, frontmost: String?) -> DeliveryMode {
        let mode = ruleMode(rules: rules, target: target)
        guard let target else { return mode }
        if frontmost != target { return .copyOnly }
        if mode == .insertAndSend && terminalBundleIDs.contains(target) { return .insert }
        return mode
    }
}
