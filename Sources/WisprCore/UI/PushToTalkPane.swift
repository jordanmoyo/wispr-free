import SwiftUI

struct PushToTalkPane: View {
    let context: MainWindowContext
    @ObservedObject var model: MainWindowModel

    @State private var hotkey: Int64 = 63
    @State private var activationMode: ActivationMode = .hold
    @State private var pillPosition: PillPosition = .bottomCenter
    @State private var deliveryRules: [DeliveryRule] = []
    @State private var showingAddRulePopover = false

    var body: some View {
        PaneScaffold(title: "Push to Talk") {
            VStack(alignment: .leading, spacing: 0) {
                keyCard
                    .padding(.bottom, 20)

                SettingsRow(title: "Activation",
                            caption: activationMode == .hold
                                ? "While holding, tap ⇧ to lock — press the key again to stop."
                                : nil) {
                    segmentedControl
                }
                SettingsRow(title: "Recording pill position",
                            caption: "Where the recording overlay appears while you speak") {
                    Picker("", selection: $pillPosition) {
                        ForEach(PillPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                Text("PER-APP DELIVERY")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 24)
                    .padding(.bottom, 6)

                deliveryRulesSection
            }
        }
        .onAppear {
            hotkey = context.settings.hotkeyKeyCode
            activationMode = context.settings.activationMode
            pillPosition = context.settings.pillPosition
            deliveryRules = context.settings.deliveryRules
        }
        .onChange(of: activationMode) { _, mode in
            context.settings.activationMode = mode
            context.actions.onActivationModeChange(mode)
        }
        .onChange(of: pillPosition) { _, position in
            context.settings.pillPosition = position
            context.actions.onPillPositionChange(position)
        }
    }

    private var keyCard: some View {
        VStack(spacing: 12) {
            Text(activationMode == .hold
                 ? "Hold this key to dictate anywhere"
                 : "Press this key to start and stop dictating")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Text(HotkeyOptions.option(for: hotkey).shortLabel)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(EdgeInsets(top: 14, leading: 40, bottom: 14, trailing: 40))
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            Menu("Change shortcut…") {
                ForEach(HotkeyOptions.all) { option in
                    Button {
                        hotkey = option.id
                        context.settings.hotkeyKeyCode = option.id
                        context.actions.onHotkeyChange(option.id)
                    } label: {
                        if option.id == hotkey {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
            .foregroundStyle(Theme.navy)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segment("Hold to talk", .hold)
            segment("Press to toggle", .toggle)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hairline))
    }

    private func segment(_ label: String, _ mode: ActivationMode) -> some View {
        Button {
            activationMode = mode
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(activationMode == mode ? .white : .clear)
                    .shadow(color: .black.opacity(activationMode == mode ? 0.1 : 0), radius: 1, y: 1))
        }
        .buttonStyle(.plain)
    }

    private var deliveryRulesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if deliveryRules.isEmpty {
                Text("No custom rules. Dictation types automatically everywhere by default.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 10)
            } else {
                ForEach($deliveryRules) { $rule in
                    DeliveryRuleRow(rule: $rule, onRemove: {
                        deliveryRules.removeAll { $0.bundleID == rule.bundleID }
                        persistDeliveryRules()
                    }, onPersist: persistDeliveryRules)
                }
            }
            HStack {
                Button("Add rule…") { showingAddRulePopover = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $showingAddRulePopover) {
                        AddRulePopover(existingBundleIDs: Set(deliveryRules.map(\.bundleID))) { app in
                            deliveryRules.append(DeliveryRule(
                                bundleID: app.bundleIdentifier,
                                displayName: app.displayName, mode: .insert))
                            persistDeliveryRules()
                            showingAddRulePopover = false
                        }
                    }
                Spacer()
            }
            .padding(.top, 10)
            Text("Tone adjusts AI cleanup per app — Casual relaxes the register, Formal polishes it. Type and press Return is refused in terminals and skipped if you switch apps while transcribing.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 8)
        }
    }

    private func persistDeliveryRules() {
        context.settings.deliveryRules = deliveryRules
        context.actions.onRulesChange()
    }
}

/// One delivery-rule row: mode picker, tone picker, remove button, and (when
/// `tone == .custom`) a free-text field for the custom instruction.
///
/// The custom-tone field edits a local `@State` copy of the text rather than
/// writing `rule.toneCustomText` on every keystroke. Sanitizing per-keystroke
/// (as an earlier version did) is actively harmful: `sanitizeCustomTone`
/// collapses whitespace runs, so the instant a space is the last-typed
/// character it gets dropped, SwiftUI re-reads the binding's `get`, and the
/// field visibly reverts — "warm, first person" could never be typed, only
/// pasted. Sanitizing exactly once, at submit or focus-loss, keeps the field
/// a normal text field while still writing a sanitized value to the model.
private struct DeliveryRuleRow: View {
    @Binding var rule: DeliveryRule
    let onRemove: () -> Void
    let onPersist: () -> Void

    @State private var rawCustomText: String = ""
    @FocusState private var customFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: rule.displayName, showDivider: rule.tone != .custom) {
                HStack(spacing: 8) {
                    Picker("", selection: $rule.mode) {
                        Text("Type automatically").tag(DeliveryMode.insert)
                        Text("Copy only").tag(DeliveryMode.copyOnly)
                        Text("Type and press Return").tag(DeliveryMode.insertAndSend)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .onChange(of: rule.mode) { _, _ in onPersist() }
                    Picker("", selection: $rule.tone) {
                        Text("Default tone").tag(TonePreset?.none)
                        Text("Casual").tag(TonePreset?.some(.casual))
                        Text("Formal").tag(TonePreset?.some(.formal))
                        Text("Custom…").tag(TonePreset?.some(.custom))
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .onChange(of: rule.tone) { _, _ in onPersist() }
                    Button("Remove", action: onRemove)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.destructive)
                }
            }
            if rule.tone == .custom {
                TextField("e.g. warm, first person, no emoji", text: $rawCustomText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 240)
                    .padding(.bottom, 13)
                    .focused($customFieldFocused)
                    .onAppear { rawCustomText = rule.toneCustomText ?? "" }
                    .onSubmit { commitCustomText() }
                    .onChange(of: customFieldFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { commitCustomText() }
                    }
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }

    /// Sanitizes the locally-edited text exactly once and writes it back to
    /// the rule (empty after sanitizing collapses to `nil`), then persists.
    /// Re-syncs `rawCustomText` to the sanitized value so a field that had
    /// e.g. trailing whitespace visibly reflects what got saved.
    private func commitCustomText() {
        let sanitized = DeliveryRule.sanitizeCustomTone(rawCustomText)
        rule.toneCustomText = sanitized.isEmpty ? nil : sanitized
        rawCustomText = sanitized
        onPersist()
    }
}
