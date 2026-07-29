import SwiftUI

/// Everything the panes need, bundled so pane initializers stay short.
struct MainWindowContext {
    let settings: SettingsStore
    let modelStore: ModelStore
    let historyStore: HistoryStore
    let correctionStore: CorrectionStore
    let actions: SettingsActions
}

/// The unified main window: sidebar navigation (Dictation / Settings /
/// Info) plus the selected pane, per the "Wispr Free App" design.
struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    let context: MainWindowContext

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .history: HistoryPane(context: context)
        case .learning: LearningPane(context: context)
        case .general: GeneralPane(context: context)
        case .pushToTalk: PushToTalkPane(context: context, model: model)
        case .microphone: MicrophonePane(context: context)
        case .languageModel: LanguageModelPane(context: context)
        case .privacy: PrivacyPane(context: context)
        case .about: AboutPane()
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top inset clears the real traffic lights (the window uses a
            // transparent titlebar, so they float over the sidebar).
            Spacer().frame(height: 36)

            HStack(spacing: 10) {
                BrandIcon(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Wispr Free")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(model.statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.statusColor)
                        .lineLimit(1)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 12))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MainTab.groups, id: \.label) { group in
                        Text(group.label.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        ForEach(group.tabs, id: \.self) { tab in
                            SidebarItem(
                                label: tab.label,
                                selected: model.selectedTab == tab,
                                action: { model.selectedTab = tab })
                        }
                        Spacer().frame(height: 10)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            Rectangle().fill(Theme.sidebarBorder).frame(height: 1)
            HStack {
                Text("v\(appVersion) · on-device")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Circle().fill(model.dotColor).frame(width: 8, height: 8)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
        .frame(width: 220)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.sidebarBorder).frame(width: 1)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

private struct SidebarItem: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Theme.text)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Theme.navy
                          : hovering ? Theme.navy.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
