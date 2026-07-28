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

struct SettingsView: View {
    let settings: SettingsStore
    let modelStore: ModelStore
    let onHotkeyChange: (Int64) -> Void
    let onModelChange: (String) -> Void

    @State private var hotkey: Int64
    @State private var modelID: String
    @State private var launchAtLogin: Bool

    init(settings: SettingsStore, modelStore: ModelStore,
         onHotkeyChange: @escaping (Int64) -> Void,
         onModelChange: @escaping (String) -> Void) {
        self.settings = settings
        self.modelStore = modelStore
        self.onHotkeyChange = onHotkeyChange
        self.onModelChange = onModelChange
        _hotkey = State(initialValue: settings.hotkeyKeyCode)
        _modelID = State(initialValue: settings.selectedModelID)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        Form {
            Section("Push-to-talk key") {
                Picker("Hold to dictate", selection: $hotkey) {
                    ForEach(HotkeyOptions.all) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .onChange(of: hotkey) { _, newValue in
                    settings.hotkeyKeyCode = newValue
                    onHotkeyChange(newValue)
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
                    onModelChange(newValue)
                }
                Text("Models download automatically on first use and are stored in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }
}
