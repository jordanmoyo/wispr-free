import SwiftUI

/// Design tokens from the "Wispr Free App" Claude Design mockup. The main
/// window pins its appearance to light (`MainWindowController` sets
/// `.aqua`), so these are fixed values, not dynamic colors.
enum Theme {
    static let navy = Color(red: 0x2d / 255, green: 0x35 / 255, blue: 0x61 / 255)
    static let deepNavy = Color(red: 0x1f / 255, green: 0x23 / 255, blue: 0x47 / 255)
    static let pillNavy = Color(red: 0x1a / 255, green: 0x1d / 255, blue: 0x3a / 255)
    static let gold = Color(red: 0xf5 / 255, green: 0xc5 / 255, blue: 0x18 / 255)
    static let darkGold = Color(red: 0xb8 / 255, green: 0x94 / 255, blue: 0x0f / 255)
    static let text = Color(red: 0x1d / 255, green: 0x1d / 255, blue: 0x1f / 255)
    static let secondaryText = Color(red: 0x8a / 255, green: 0x8a / 255, blue: 0x92 / 255)
    static let tertiaryText = Color(red: 0x7a / 255, green: 0x7a / 255, blue: 0x82 / 255)
    static let sidebar = Color(red: 0xf0 / 255, green: 0xf0 / 255, blue: 0xf3 / 255)
    static let card = Color(red: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf7 / 255)
    static let border = Color(red: 0xdc / 255, green: 0xdc / 255, blue: 0xe1 / 255)
    static let hairline = Color(red: 0xec / 255, green: 0xec / 255, blue: 0xef / 255)
    static let sidebarBorder = Color(red: 0xe0 / 255, green: 0xe0 / 255, blue: 0xe5 / 255)
    static let destructive = Color(red: 0xc0 / 255, green: 0x39 / 255, blue: 0x2b / 255)
    static let green = Color(red: 0x28 / 255, green: 0xc8 / 255, blue: 0x40 / 255)
    static let paleNavy = Color(red: 0xf7 / 255, green: 0xf8 / 255, blue: 0xfc / 255)
    static let lightLavender = Color(red: 0xc9 / 255, green: 0xcc / 255, blue: 0xe0 / 255)
}

/// The brand mark (navy rounded square, gold pill, navy waveform bars),
/// drawn in SwiftUI so it renders crisp at any size.
struct BrandIcon: View {
    var size: CGFloat

    var body: some View {
        let unit = size / 1024
        ZStack {
            RoundedRectangle(cornerRadius: 185 * unit, style: .continuous)
                .fill(Theme.deepNavy)
            Capsule()
                .fill(Theme.gold)
                .frame(width: 500 * unit, height: 188 * unit)
            HStack(spacing: 28 * unit) {
                ForEach([48, 84, 120, 84, 48], id: \.self) { height in
                    Capsule()
                        .fill(Theme.pillNavy)
                        .frame(width: 24 * unit, height: CGFloat(height) * unit)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A settings row: title + optional caption on the left, any control on the
/// right, hairline divider below (per the mockup's 13px-padded rows).
struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    var showDivider = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 16)
                control()
            }
            .padding(.vertical, 13)
            if showDivider {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }
}

/// The mockup's 38×22 navy toggle switch.
struct ThemeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Theme.navy : Color(red: 0xd1 / 255, green: 0xd1 / 255, blue: 0xd6 / 255))
                .frame(width: 38, height: 22)
            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityAddTraits(.isButton)
    }
}

/// Pane scaffold: 20pt bold title, optional subtitle, content below, all in
/// the mockup's 24/28pt padding and 640pt max content width.
struct PaneScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, subtitle == nil ? 20 : 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.bottom, 20)
                }
                content()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white)
    }
}

/// Secondary button per the mockup (#f0f0f3 fill, 7pt radius).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Theme.sidebar.opacity(configuration.isPressed ? 0.6 : 1)))
    }
}

/// Outlined destructive button per the mockup.
struct DestructiveOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.destructive)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(configuration.isPressed ? Theme.destructive.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }
}
