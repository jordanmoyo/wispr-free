import SwiftUI

struct MicrophonePane: View {
    let context: MainWindowContext

    @StateObject private var levelMonitor = MicLevelMonitor()
    @State private var devices: [AudioInputDevice] = []
    /// "" means system default (nil in the store).
    @State private var selectedUID = ""
    @State private var preRollEnabled = false

    var body: some View {
        PaneScaffold(title: "Microphone") {
            VStack(spacing: 0) {
                SettingsRow(title: "Input device") {
                    Picker("", selection: $selectedUID) {
                        Text("System default").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                levelRow

                SettingsRow(title: "Capture lead-in audio",
                            caption: "Keeps the last half-second before you press the key — the mic stays active while Wispr Free runs",
                            showDivider: false) {
                    ThemeToggle(isOn: $preRollEnabled)
                }
            }
        }
        .onAppear {
            devices = AudioInputDevices.all()
            selectedUID = context.settings.inputDeviceUID ?? ""
            preRollEnabled = context.settings.preRollEnabled
            levelMonitor.start(deviceUID: context.settings.inputDeviceUID)
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: selectedUID) { _, uid in
            let stored = uid.isEmpty ? nil : uid
            context.settings.inputDeviceUID = stored
            context.actions.onInputDeviceChange(stored)
            levelMonitor.start(deviceUID: stored)
        }
        .onChange(of: preRollEnabled) { _, enabled in
            // Persistence handled by AppController, which also gates the
            // recorder on mic permission (see onPreRollToggle).
            context.actions.onPreRollToggle(enabled)
        }
    }

    private var levelRow: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Input level")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(levelMonitor.available ? "speak to test" : "microphone unavailable")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Theme.navy, Theme.gold],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * CGFloat(levelMonitor.level)))
                            .animation(.linear(duration: 0.08), value: levelMonitor.level)
                    }
                }
                .frame(height: 8)
            }
            .padding(.vertical, 13)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}
