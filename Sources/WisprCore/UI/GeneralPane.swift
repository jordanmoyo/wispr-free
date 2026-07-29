import SwiftUI
import ServiceManagement

struct GeneralPane: View {
    let context: MainWindowContext

    @State private var launchAtLogin = false
    @State private var feedbackSounds = false
    @State private var updateCheckEnabled = true

    var body: some View {
        PaneScaffold(title: "General") {
            VStack(spacing: 0) {
                SettingsRow(title: "Launch at login",
                            caption: "Start Wispr Free when you log in") {
                    ThemeToggle(isOn: $launchAtLogin)
                }
                SettingsRow(title: "Feedback sounds",
                            caption: "Soft chime when recording starts and stops") {
                    ThemeToggle(isOn: $feedbackSounds)
                }
                SettingsRow(title: "Check for updates automatically",
                            caption: "A daily, anonymous version check against GitHub releases",
                            showDivider: false) {
                    ThemeToggle(isOn: $updateCheckEnabled)
                }
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            feedbackSounds = context.settings.feedbackSounds
            updateCheckEnabled = context.settings.updateCheckEnabled
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: feedbackSounds) { _, enabled in
            context.settings.feedbackSounds = enabled
        }
        .onChange(of: updateCheckEnabled) { _, enabled in
            context.settings.updateCheckEnabled = enabled
            context.actions.onUpdateCheckToggle(enabled)
        }
    }
}
