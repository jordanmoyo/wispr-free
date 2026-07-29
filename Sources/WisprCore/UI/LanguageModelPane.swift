import SwiftUI

struct LanguageModelPane: View {
    let context: MainWindowContext

    @State private var modelID = ""
    @State private var cleanupEnabled = true
    @State private var cleanupModelID = ""
    @State private var autoDetect = true
    /// Language shown in the picker when auto-detect is off ("en" default).
    @State private var languageCode = "en"

    var body: some View {
        PaneScaffold(
            title: "Language & Model",
            subtitle: "Models run entirely on this Mac. Nothing you say is sent anywhere."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                modelCards
                    .padding(.bottom, 24)

                SettingsRow(title: "Detect language automatically",
                            caption: "Switch between languages mid-dictation") {
                    ThemeToggle(isOn: $autoDetect)
                }
                SettingsRow(title: "Primary language",
                            caption: autoDetect ? "Used only when auto-detect is off" : nil) {
                    Picker("", selection: $languageCode) {
                        ForEach(TranscriptionOptions.languages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(autoDetect)
                    .opacity(autoDetect ? 0.5 : 1)
                }

                Text("AI CLEANUP")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 24)
                    .padding(.bottom, 6)

                SettingsRow(title: "Enhance transcripts with AI",
                            caption: "A local LLM removes filler words and fixes punctuation — never translates") {
                    ThemeToggle(isOn: $cleanupEnabled)
                }
                .padding(.bottom, 10)

                cleanupModelCards
                    .disabled(!cleanupEnabled)
                    .opacity(cleanupEnabled ? 1 : 0.5)
            }
        }
        .onAppear {
            modelID = context.settings.selectedModelID
            cleanupEnabled = context.settings.cleanupEnabled
            cleanupModelID = context.settings.cleanupModelID
            let pinned = context.settings.pinnedLanguage
            autoDetect = pinned == nil
            languageCode = pinned ?? "en"
        }
        .onChange(of: autoDetect) { _, auto in
            let pinned = auto ? nil : languageCode
            context.settings.pinnedLanguage = pinned
            context.actions.onLanguageChange(pinned)
        }
        .onChange(of: languageCode) { _, code in
            guard !autoDetect else { return }
            context.settings.pinnedLanguage = code
            context.actions.onLanguageChange(code)
        }
        .onChange(of: cleanupEnabled) { _, enabled in
            context.settings.cleanupEnabled = enabled
            context.actions.onCleanupToggle(enabled)
        }
    }

    private var modelCards: some View {
        VStack(spacing: 10) {
            ForEach(ModelRegistry.models) { model in
                ModelCard(
                    name: model.displayName,
                    desc: modelDescription(sizeMB: model.approxSizeMB,
                                           installed: context.modelStore.isInstalled(model)),
                    tag: tag(selected: model.id == modelID,
                             installed: context.modelStore.isInstalled(model),
                             sizeLabel: "\(model.approxSizeMB) MB"),
                    selected: model.id == modelID
                ) {
                    modelID = model.id
                    context.settings.selectedModelID = model.id
                    context.actions.onModelChange(model.id)
                }
            }
        }
    }

    private var cleanupModelCards: some View {
        VStack(spacing: 10) {
            ForEach(CleanupModelRegistry.models, id: \.id) { model in
                let sizeGB = String(format: "%.1f GB", Double(model.approxSizeMB) / 1000)
                ModelCard(
                    name: model.displayName,
                    desc: modelDescription(sizeMB: model.approxSizeMB,
                                           installed: context.modelStore.isInstalled(model)),
                    tag: tag(selected: model.id == cleanupModelID,
                             installed: context.modelStore.isInstalled(model),
                             sizeLabel: sizeGB),
                    selected: model.id == cleanupModelID
                ) {
                    cleanupModelID = model.id
                    context.settings.cleanupModelID = model.id
                    context.actions.onCleanupModelChange(model.id)
                }
            }
        }
    }

    private func modelDescription(sizeMB: Int, installed: Bool) -> String {
        let size = sizeMB >= 1000
            ? String(format: "%.1f GB", Double(sizeMB) / 1000)
            : "\(sizeMB) MB"
        return installed ? "\(size) · installed" : "\(size) · downloads on first use"
    }

    private func tag(selected: Bool, installed: Bool, sizeLabel: String) -> String {
        if selected { return "Active" }
        return installed ? "Installed" : "↓ \(sizeLabel)"
    }
}

private struct ModelCard: View {
    let name: String
    let desc: String
    let tag: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(tag)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                    .background(Capsule().fill(selected ? Theme.navy : Theme.sidebar))
                    .foregroundStyle(selected ? Theme.gold : Color(red: 0x55 / 255, green: 0x55 / 255, blue: 0x5c / 255))
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.paleNavy : .white))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.navy : Theme.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
