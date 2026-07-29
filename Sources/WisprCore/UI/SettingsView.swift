import SwiftUI
import ServiceManagement

public struct HotkeyOption: Identifiable, Equatable {
    public let id: Int64
    public let label: String
}

public enum HotkeyOptions {
    public static let all: [HotkeyOption] = [
        HotkeyOption(id: 63, label: "Fn (Globe)"),
        HotkeyOption(id: 54, label: "Right ⌘"),
        HotkeyOption(id: 61, label: "Right ⌥"),
        HotkeyOption(id: 96, label: "F5"),
        HotkeyOption(id: 105, label: "F13"),
    ]
}

/// Consolidated callbacks the Settings window reports back to its owner.
///
/// Later tasks add fields here; construct with named defaults so call sites
/// only need to specify the callbacks they care about.
public struct SettingsActions {
    public var onHotkeyChange: (Int64) -> Void
    public var onModelChange: (String) -> Void
    public var onCleanupToggle: (Bool) -> Void
    public var onCleanupModelChange: (String) -> Void
    public var onLanguageChange: (String?) -> Void
    public var onPreRollToggle: (Bool) -> Void
    public var onUpdateCheckToggle: (Bool) -> Void
    public var onRulesChange: () -> Void

    public init(
        onHotkeyChange: @escaping (Int64) -> Void = { _ in },
        onModelChange: @escaping (String) -> Void = { _ in },
        onCleanupToggle: @escaping (Bool) -> Void = { _ in },
        onCleanupModelChange: @escaping (String) -> Void = { _ in },
        onLanguageChange: @escaping (String?) -> Void = { _ in },
        onPreRollToggle: @escaping (Bool) -> Void = { _ in },
        onUpdateCheckToggle: @escaping (Bool) -> Void = { _ in },
        onRulesChange: @escaping () -> Void = {}
    ) {
        self.onHotkeyChange = onHotkeyChange
        self.onModelChange = onModelChange
        self.onCleanupToggle = onCleanupToggle
        self.onCleanupModelChange = onCleanupModelChange
        self.onLanguageChange = onLanguageChange
        self.onPreRollToggle = onPreRollToggle
        self.onUpdateCheckToggle = onUpdateCheckToggle
        self.onRulesChange = onRulesChange
    }
}

struct SettingsView: View {
    let settings: SettingsStore
    let modelStore: ModelStore
    let actions: SettingsActions

    @State private var hotkey: Int64
    @State private var modelID: String
    @State private var launchAtLogin: Bool
    @State private var cleanupEnabled: Bool
    @State private var cleanupModelID: String
    @State private var languageCode: String
    @State private var preRollEnabled: Bool
    @State private var updateCheckEnabled: Bool
    @State private var historyEnabled: Bool
    @State private var learningEnabled: Bool
    @State private var deliveryRules: [DeliveryRule]
    @State private var showingAddRulePopover = false

    init(settings: SettingsStore, modelStore: ModelStore, actions: SettingsActions) {
        self.settings = settings
        self.modelStore = modelStore
        self.actions = actions
        _hotkey = State(initialValue: settings.hotkeyKeyCode)
        _modelID = State(initialValue: settings.selectedModelID)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        _cleanupEnabled = State(initialValue: settings.cleanupEnabled)
        _cleanupModelID = State(initialValue: settings.cleanupModelID)
        // "" means Auto (nil in the store).
        _languageCode = State(initialValue: settings.pinnedLanguage ?? "")
        _preRollEnabled = State(initialValue: settings.preRollEnabled)
        _updateCheckEnabled = State(initialValue: settings.updateCheckEnabled)
        _historyEnabled = State(initialValue: settings.historyEnabled)
        _learningEnabled = State(initialValue: settings.learningEnabled)
        _deliveryRules = State(initialValue: settings.deliveryRules)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Text("General") }
            dictationTab
                .tabItem { Text("Dictation") }
            aiCleanupTab
                .tabItem { Text("AI Cleanup") }
            deliveryTab
                .tabItem { Text("Delivery") }
        }
    }

    private var generalTab: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Automatically check for updates", isOn: $updateCheckEnabled)
                    .onChange(of: updateCheckEnabled) { _, enabled in
                        settings.updateCheckEnabled = enabled
                        actions.onUpdateCheckToggle(enabled)
                    }
            }
            Section("Privacy") {
                Toggle("Save dictation history", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, enabled in
                        settings.historyEnabled = enabled
                    }
                Text("Keeps a local, searchable record of your dictations. Existing history stays until you clear it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Learn from your corrections", isOn: $learningEnabled)
                    .onChange(of: learningEnabled) { _, enabled in
                        settings.learningEnabled = enabled
                    }
                Text("Learns wrong→right word pairs when you edit past dictations. Existing corrections stay until you forget them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var dictationTab: some View {
        Form {
            Section("Push-to-talk key") {
                Picker("Hold to dictate", selection: $hotkey) {
                    ForEach(HotkeyOptions.all) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .onChange(of: hotkey) { _, newValue in
                    settings.hotkeyKeyCode = newValue
                    actions.onHotkeyChange(newValue)
                }
            }
            Section("Model") {
                Picker("Whisper model", selection: $modelID) {
                    ForEach(ModelRegistry.models) { model in
                        let installed = modelStore.isInstalled(model)
                        Text(model.displayName +
                             (installed ? "" : "  (↓ \(model.approxSizeMB) MB)"))
                            .tag(model.id)
                    }
                }
                .onChange(of: modelID) { _, newValue in
                    settings.selectedModelID = newValue
                    actions.onModelChange(newValue)
                }
                Text("Models download automatically on first use and are stored in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Dictation language", selection: $languageCode) {
                    Text("Auto-detect").tag("")
                    ForEach(TranscriptionOptions.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .onChange(of: languageCode) { _, newValue in
                    let pinned = newValue.isEmpty ? nil : newValue
                    settings.pinnedLanguage = pinned
                    actions.onLanguageChange(pinned)
                }
            }
            Section("Pre-roll") {
                // Unlike sibling toggles, this one doesn't write
                // settings.preRollEnabled here: AppController's
                // onPreRollToggle persists it AND applies it to the
                // Recorder only when the mic is actually granted.
                Toggle("Capture lead-in audio", isOn: $preRollEnabled)
                    .onChange(of: preRollEnabled) { _, enabled in
                        actions.onPreRollToggle(enabled)
                    }
                Text("Keeps the last half-second of audio before you press the hotkey. The microphone stays active while Wispr runs (small CPU cost).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var aiCleanupTab: some View {
        Form {
            Section("AI Cleanup") {
                Toggle("Enhance transcripts with AI", isOn: $cleanupEnabled)
                    .onChange(of: cleanupEnabled) { _, enabled in
                        settings.cleanupEnabled = enabled
                        actions.onCleanupToggle(enabled)
                    }
                Picker("Cleanup model", selection: $cleanupModelID) {
                    ForEach(CleanupModelRegistry.models, id: \.id) { model in
                        let installed = modelStore.isInstalled(model)
                        let size = String(format: "%.1f GB",
                                          Double(model.approxSizeMB) / 1000)
                        Text(model.displayName + (installed ? "" : "  (↓ \(size))"))
                            .tag(model.id)
                    }
                }
                .disabled(!cleanupEnabled)
                .onChange(of: cleanupModelID) { _, newValue in
                    settings.cleanupModelID = newValue
                    actions.onCleanupModelChange(newValue)
                }
                Text("A local LLM removes filler words and fixes punctuation — your audio and text never leave your Mac. Turn off to deliver raw transcriptions exactly as Whisper heard them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var deliveryTab: some View {
        Form {
            Section("Per-app delivery") {
                if deliveryRules.isEmpty {
                    Text("No custom rules. Dictation types automatically everywhere by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($deliveryRules) { $rule in
                        HStack {
                            Text(rule.displayName)
                            Spacer()
                            Picker("", selection: $rule.mode) {
                                Text("Type automatically").tag(DeliveryMode.insert)
                                Text("Copy only").tag(DeliveryMode.copyOnly)
                                Text("Type and press Return").tag(DeliveryMode.insertAndSend)
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            .onChange(of: rule.mode) { _, _ in
                                persistDeliveryRules()
                            }
                            Button("Remove") {
                                deliveryRules.removeAll { $0.bundleID == rule.bundleID }
                                persistDeliveryRules()
                            }
                        }
                    }
                }
                Button("Add rule…") {
                    showingAddRulePopover = true
                }
                .popover(isPresented: $showingAddRulePopover) {
                    AddRulePopover(existingBundleIDs: Set(deliveryRules.map(\.bundleID))) { app in
                        deliveryRules.append(DeliveryRule(
                            bundleID: app.bundleIdentifier, displayName: app.displayName, mode: .insert))
                        persistDeliveryRules()
                        showingAddRulePopover = false
                    }
                }
                Text("Type and press Return is refused in terminals and skipped if you switch apps while transcribing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func persistDeliveryRules() {
        settings.deliveryRules = deliveryRules
        actions.onRulesChange()
    }
}

/// A candidate running app offered in the "Add rule…" popover.
private struct DeliveryRuleCandidate: Identifiable {
    let bundleIdentifier: String
    let displayName: String
    var id: String { bundleIdentifier }
}

/// Popover listing running apps that don't already have a delivery rule,
/// for adding a new one.
private struct AddRulePopover: View {
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
