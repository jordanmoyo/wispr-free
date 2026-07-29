import AppKit
import ApplicationServices
import AVFoundation
import UniformTypeIdentifiers

@MainActor
public final class AppController: NSObject {
    private let settings = SettingsStore()
    private let modelStore = ModelStore.defaultStore()
    private let historyStore = HistoryStore.defaultStore()
    private let correctionStore = CorrectionStore.defaultStore()
    private let vocabularyStore = VocabularyStore.defaultStore()
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let pill = OverlayPill()
    private let statusItem = StatusItemController()
    private lazy var transcriber = Transcriber(modelStore: modelStore)
    private lazy var cleanupEngine = CleanupEngine(
        backend: MLXCleanupBackend(cacheDirectory: modelStore.cleanupCacheDirectory))
    private lazy var updateChecker = UpdateChecker(
        transport: GitHubUpdateTransport(), currentVersion: currentAppVersion())

    private enum Phase { case idle, recording, transcribing }
    private var phase: Phase = .idle
    private var modelReady = false
    private var recordingStart: Date?
    /// Cached mic-permission result from `bootstrap()`. `preRollEnabled` on
    /// the recorder is only ever flipped on when this is true — enabling it
    /// without a granted mic would just fail to start the idle engine, and
    /// the setting still persists so the next bootstrap applies it.
    private var micGranted = false
    private let windowModel = MainWindowModel()
    private var mainWindow: MainWindowController?
    private var loadEpoch = 0
    private var availableUpdate: String?
    private var updateTimer: Timer?

    public override init() {
        super.init()
    }

    public func start() {
        buildMenu()
        hotkey.keyCode = settings.hotkeyKeyCode
        // In toggle mode the press both starts and stops; the release is
        // ignored. In hold mode (default), press starts and release stops.
        // The mode is read per-event so a settings change applies to the
        // very next key press without rewiring.
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            if self.settings.activationMode == .toggle, self.phase == .recording {
                self.endRecording()
            } else {
                self.beginRecording()
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if self.settings.activationMode == .hold {
                self.endRecording()
            }
        }
        pill.position = settings.pillPosition
        recorder.preferredInputDeviceUID = settings.inputDeviceUID
        syncWindowModelStatusLine()
        scheduleUpdateChecks()

        Task { await self.bootstrap() }
    }

    private func syncWindowModelStatusLine() {
        windowModel.hotkeyLabel = HotkeyOptions.option(for: settings.hotkeyKeyCode).shortLabel
        windowModel.activationVerb = settings.activationMode == .hold ? "hold" : "press"
    }

    /// Soft feedback chime on recording start/stop, if enabled in Settings.
    private func playFeedbackSound(start: Bool) {
        guard settings.feedbackSounds else { return }
        NSSound(named: start ? "Pop" : "Tink")?.play()
    }

    /// CFBundleShortVersionString is nil in `swift test`/dev runs (no bundle
    /// Info.plist), so we fall back to "0.0.0" — dev builds then never see
    /// an update as "newer" (a false negative that's acceptable since dev
    /// runs aren't shipped builds users would update).
    private func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func bootstrap() async {
        WisprLog.log("bootstrap: begin (hotkey keyCode=\(settings.hotkeyKeyCode))")
        let micOK = await Permissions.microphoneGranted()
        micGranted = micOK
        Permissions.requestInputMonitoring()
        let axOK = Permissions.accessibilityGranted()
        let tapOK = hotkey.start()
        WisprLog.log("bootstrap: micOK=\(micOK) axOK=\(axOK) tapOK=\(tapOK)")

        if !micOK { Permissions.openSystemSettings(pane: .microphone) }
        if !axOK { Permissions.openSystemSettings(pane: .accessibility) }
        if !tapOK {
            pill.showError("Grant Input Monitoring, then relaunch Wispr Free")
            Permissions.openSystemSettings(pane: .inputMonitoring)
        }

        if micOK && settings.preRollEnabled {
            recorder.preRollEnabled = true
        }

        await loadSelectedModel()

        // Fire-and-forget: an update check must never delay or block bootstrap.
        Task { await self.performUpdateCheck() }
    }

    // MARK: - Update check

    private func scheduleUpdateChecks() {
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.performUpdateCheck() }
        }
        timer.tolerance = 3600
        updateTimer = timer
    }

    private func performUpdateCheck() async {
        guard settings.updateCheckEnabled else { return }
        let outcome = await updateChecker.check()
        switch outcome {
        case .updateAvailable(let version):
            availableUpdate = version
            buildMenu()
            WisprLog.log("update check: available=\(version)")
        case .upToDate:
            availableUpdate = nil
            buildMenu()
            WisprLog.log("update check: available=none")
        case .notModified:
            // Not a fresh answer — leave any already-known availableUpdate
            // untouched rather than erasing it.
            WisprLog.log("update check: not modified, availableUpdate unchanged")
        case .failed:
            WisprLog.log("update check: failed, availableUpdate unchanged")
        }
    }

    private func loadSelectedModel() async {
        guard let model = ModelRegistry.model(id: settings.selectedModelID)
                ?? ModelRegistry.models.first else { return }
        loadEpoch += 1
        let epoch = loadEpoch
        modelReady = false
        statusItem.setIcon(.transcribing)
        WisprLog.log("model load: begin id=\(model.id)")
        do {
            try await transcriber.load(model: model)
            guard epoch == loadEpoch else { return }
            modelReady = true
            statusItem.setIcon(.idle)
            buildMenu()
            WisprLog.log("model load: ready id=\(model.id)")
        } catch {
            guard epoch == loadEpoch else { return }
            statusItem.setIcon(.idle)
            pill.showError("Model load failed: \(model.displayName)")
            WisprLog.log("model load: FAILED id=\(model.id) error=\(error)")
        }
    }

    private func beginRecording() {
        WisprLog.log("hotkey PRESS: phase=\(phase) modelReady=\(modelReady)")
        guard phase == .idle else { return }
        guard modelReady else {
            pill.showError("Model still loading…")
            return
        }
        do {
            try recorder.start()
        } catch {
            pill.showError("Microphone unavailable")
            WisprLog.log("recorder start FAILED: \(error)")
            return
        }
        phase = .recording
        recordingStart = Date()
        statusItem.setIcon(.recording)
        windowModel.activity = .recording
        playFeedbackSound(start: true)
        pill.position = settings.pillPosition
        pill.languageBadge = Self.languageBadge(for: settings.pinnedLanguage)
        pill.showRecording()
        recorder.onLevel = { [weak self] level in self?.pill.pushLevel(level) }
    }

    private func endRecording() {
        WisprLog.log("hotkey RELEASE: phase=\(phase)")
        guard phase == .recording else { return }
        // Captured now, at hotkey release, rather than inside the delivery
        // Task below: by the time that Task runs, focus may have already
        // moved on to Wispr's own UI (e.g. the pill), which would attribute
        // the dictation to the wrong app or miss that the field being
        // dictated into was a secure one.
        let target = NSWorkspace.shared.frontmostApplication
        let isSecureTarget = isSecureTextFieldFocused()
        playFeedbackSound(start: false)
        let result = recorder.stop()
        let samples = result.samples
        WisprLog.log("recorded \(samples.count) samples, session=\(result.sessionSampleCount) " +
                     "(\(String(format: "%.2f", Recorder.duration(of: samples)))s)")
        let heldSeconds = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        guard DictationGate.shouldTranscribe(sampleCount: result.sessionSampleCount) else {
            phase = .idle
            statusItem.setIcon(.idle)
            windowModel.activity = .ready
            if result.sessionSampleCount == 0 && heldSeconds >= 1.0 {
                // Mic delivered nothing despite a real hold (e.g. Bluetooth
                // headset input that never engages) — never fail silently.
                pill.showError("No audio captured — check mic in System Settings → Sound")
            } else {
                pill.hide()
            }
            return
        }
        phase = .transcribing
        statusItem.setIcon(.transcribing)
        windowModel.activity = .transcribing
        pill.showTranscribing()

        Task {
            do {
                let text = try await transcriber.transcribe(samples: samples, language: settings.pinnedLanguage)
                WisprLog.log("transcribed \(text.count) chars")
                // Captured before cleanup mutates the text below, so history
                // can record what was actually said alongside what was
                // delivered.
                let rawText = text
                var cleanedText = text
                // A trailing spoken directive ("… make this a bullet list")
                // is stripped either way; with cleanup enabled the remaining
                // content goes through the LLM transform instead of the
                // normal cleanup. Fail-open: a failed transform returns its
                // input, and with cleanup disabled the stripped content just
                // continues down the normal path.
                let directive = DirectiveDetector.detect(rawText)
                if let directive {
                    cleanedText = directive.content
                    WisprLog.log("directive detected: \(directive.directive.rawValue)")
                }
                if !cleanedText.isEmpty && settings.cleanupEnabled {
                    if let directive {
                        cleanedText = await cleanupEngine.transform(
                            cleanedText, directive: directive.directive, modelID: settings.cleanupModelID)
                        WisprLog.log("transform returned \(cleanedText.count) chars")
                    } else {
                        let hints = settings.learningEnabled ? await correctionStore.topPairs(limit: 20) : []
                        let vocabulary = Array(await vocabularyStore.all().suffix(50))
                        // Tone is resolved from the target app's delivery
                        // rule and applies only to normal cleanup — a
                        // directive transform already dictates its own shape.
                        let tone = settings.deliveryRules.first { $0.bundleID == target?.bundleIdentifier }?.tone
                        cleanedText = await cleanupEngine.clean(
                            cleanedText, modelID: settings.cleanupModelID,
                            hints: hints, vocabulary: vocabulary, tone: tone)
                        WisprLog.log("cleanup returned \(cleanedText.count) chars")
                    }
                }
                var appliedCorrections: [String] = []
                if !cleanedText.isEmpty && settings.learningEnabled {
                    let pairs = await correctionStore.topPairs(limit: .max)
                    let (correctedText, applied) = CorrectionApplier.apply(pairs, to: cleanedText)
                    cleanedText = correctedText
                    appliedCorrections = applied
                    if !applied.isEmpty { WisprLog.log("corrections applied: \(applied.joined(separator: ", "))") }
                }
                // Deterministic spoken formatting ("new paragraph" → "\n\n")
                // runs last, after cleanup and corrections, so it works even
                // with cleanup disabled. History stores the formatted text.
                cleanedText = FormattingCommands.apply(cleanedText)
                var delivered = false
                var suppressedSecureCopy = false
                if !cleanedText.isEmpty {
                    let mode = DeliveryPolicy.effectiveMode(
                        rules: settings.deliveryRules,
                        target: target?.bundleIdentifier,
                        frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                    WisprLog.log("delivery mode: \(mode.rawValue)")
                    let pasted = Paster.deliver(
                        cleanedText, mode: mode, expectedFrontmost: target?.bundleIdentifier, conceal: isSecureTarget)
                    delivered = (mode != .copyOnly) && pasted
                    // Concealed + copyOnly delivers nothing anywhere (no
                    // clipboard, no typing, no history) — tell the user
                    // rather than letting the dictation vanish silently.
                    suppressedSecureCopy = isSecureTarget && mode == .copyOnly
                    WisprLog.log("delivered: pasted=\(pasted) delivered=\(delivered)")
                }
                if suppressedSecureCopy {
                    self.pill.showError("Nothing delivered — secure field")
                } else {
                    self.pill.hide()
                }
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
                self.recordHistory(target: target, isSecureTarget: isSecureTarget, rawText: rawText,
                                   cleanedText: cleanedText, sessionSampleCount: result.sessionSampleCount,
                                   delivered: delivered, appliedCorrections: appliedCorrections)
            } catch {
                self.pill.showError("Transcription failed")
                WisprLog.log("transcribe FAILED: \(error)")
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
            }
        }
    }

    /// Fire-and-forget: history is a convenience feature and must never
    /// delay or block the dictation pipeline, which is why phases have
    /// already been reset to `.idle` by the time this is called.
    /// `isSecureTarget` is a snapshot taken at hotkey release (see
    /// `endRecording`), not recomputed here — by the time this fire-and-
    /// forget path runs, focus may have moved on and re-checking would give
    /// a stale answer for the field that was actually dictated into.
    private func recordHistory(
        target: NSRunningApplication?, isSecureTarget: Bool, rawText: String,
        cleanedText: String, sessionSampleCount: Int, delivered: Bool,
        appliedCorrections: [String]
    ) {
        guard settings.historyEnabled, !isSecureTarget else { return }
        guard !cleanedText.isEmpty else { return }
        let entry = HistoryEntry(
            id: UUID(),
            date: Date(),
            appName: target?.localizedName ?? "Unknown",
            appBundleID: target?.bundleIdentifier ?? "unknown",
            rawText: rawText,
            cleanedText: cleanedText,
            // Excludes pre-roll seed audio: only time captured after the
            // hotkey was pressed counts toward the recorded duration.
            durationSeconds: Double(sessionSampleCount) / AudioResampler.targetSampleRate,
            wordCount: cleanedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
            delivered: delivered,
            appliedCorrections: appliedCorrections.isEmpty ? nil : appliedCorrections)
        Task { await self.historyStore.append(entry) }
    }

    /// Whether the currently focused UI element is a secure text field
    /// (e.g. a password field) — dictation history must not capture text
    /// entered into one.
    ///
    /// The historical Carbon check for this, `IsSecureEventInputSet()`, no
    /// longer exists in the macOS SDK: no header declares it, it isn't
    /// linkable (`swiftc -framework Carbon` fails to find it), and it isn't
    /// `dlsym`-resolvable at runtime either. Only the private SPI
    /// `_CGSIsSecureEventInputSet` remains (visible in CoreGraphics.tbd),
    /// which we won't depend on. Instead, use the AX API — already
    /// available via the Accessibility permission this app requires for
    /// pasting — to ask whether the focused element itself is a secure text
    /// field. Any AX failure (no focused element, attribute not supported)
    /// falls open, per the global fail-open rule.
    private func isSecureTextFieldFocused() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        // An unresponsive target app must never block hotkey release for
        // the default ~6s AX messaging timeout.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else { return false }
        return subrole == kAXSecureTextFieldSubrole as String
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = statusItem.menu
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Wispr Free",
                                  action: #selector(openMainWindow),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        if let availableUpdate {
            let updateItem = NSMenuItem(
                title: "Update available: \(availableUpdate) — View release…",
                action: #selector(openReleasePage),
                keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        // Language: Free transcription (auto-detect), English, or French.
        let languageParent = NSMenuItem(title: "Language: \(languageLabel)",
                                        action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let languageChoices: [(title: String, code: String?)] = [
            ("Free transcription", nil), ("English", "en"), ("French", "fr"),
        ]
        for choice in languageChoices {
            let item = NSMenuItem(title: choice.title,
                                  action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.code
            item.state = settings.pinnedLanguage == choice.code ? .on : .off
            languageMenu.addItem(item)
        }
        languageParent.submenu = languageMenu
        menu.addItem(languageParent)

        let modelParent = NSMenuItem(title: "Model: \(currentModelName)",
                                     action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for model in ModelRegistry.models {
            let installed = modelStore.isInstalled(model)
            let suffix = installed ? "" : "  (↓ \(model.approxSizeMB) MB)"
            let item = NSMenuItem(title: model.displayName + suffix,
                                  action: #selector(selectModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == settings.selectedModelID ? .on : .off
            modelMenu.addItem(item)
        }
        modelParent.submenu = modelMenu
        menu.addItem(modelParent)

        menu.addItem(.separator())
        let cleanupToggle = NSMenuItem(title: "AI Cleanup",
                                       action: #selector(toggleCleanup),
                                       keyEquivalent: "")
        cleanupToggle.target = self
        cleanupToggle.state = settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanupToggle)

        let cleanupParent = NSMenuItem(title: "Cleanup model: \(currentCleanupModelName)",
                                       action: nil, keyEquivalent: "")
        let cleanupMenu = NSMenu()
        for model in CleanupModelRegistry.models {
            let installed = modelStore.isInstalled(model)
            let sizeGB = String(format: "%.1f", Double(model.approxSizeMB) / 1000)
            let suffix = installed ? "" : "  (↓ \(sizeGB) GB)"
            let item = NSMenuItem(title: model.displayName + suffix,
                                  action: #selector(selectCleanupModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == settings.cleanupModelID ? .on : .off
            cleanupMenu.addItem(item)
        }
        cleanupParent.submenu = cleanupMenu
        menu.addItem(cleanupParent)

        menu.addItem(.separator())
        let importItem = NSMenuItem(title: "Transcribe Audio File…",
                                    action: #selector(importAudioFile),
                                    keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let historyItem = NSMenuItem(title: "History…",
                                     action: #selector(openHistory),
                                     keyEquivalent: "y")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Wispr Free", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Initials shown under the recording pill's waveform: the pinned
    /// language's code ("EN", "FR", …), or "FT" for free transcription
    /// (auto-detect).
    static func languageBadge(for pinned: String?) -> String {
        guard let pinned, !pinned.isEmpty else { return "FT" }
        return String(pinned.prefix(2)).uppercased()
    }

    private var languageLabel: String {
        guard let pinned = settings.pinnedLanguage else { return "Free" }
        return TranscriptionOptions.languages.first { $0.code == pinned }?.name
            ?? pinned.uppercased()
    }

    private var currentModelName: String {
        ModelRegistry.models.first { $0.id == settings.selectedModelID }?.displayName
            ?? settings.selectedModelID
    }

    private var currentCleanupModelName: String {
        CleanupModelRegistry.models.first { $0.id == settings.cleanupModelID }?.displayName
            ?? settings.cleanupModelID
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        settings.pinnedLanguage = sender.representedObject as? String
        buildMenu()
        WisprLog.log("pinned language changed: \(settings.pinnedLanguage ?? "auto")")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.selectedModelID = id
        buildMenu()
        Task { await self.loadSelectedModel() }
    }

    @objc private func toggleCleanup() {
        settings.cleanupEnabled.toggle()
        buildMenu()
        if !settings.cleanupEnabled {
            Task { await cleanupEngine.unload() }
        }
        WisprLog.log("cleanup enabled=\(settings.cleanupEnabled)")
    }

    @objc private func selectCleanupModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.cleanupModelID = id
        buildMenu()
        // Unload now; the next dictation lazy-loads the new model.
        Task { await cleanupEngine.unload() }
        WisprLog.log("cleanup model selected id=\(id)")
    }

    /// Menu entry point for transcribing an existing audio file into
    /// History. Checked at action time rather than disabling the item on
    /// state changes: a dictation in flight makes this a logged no-op.
    @objc private func importAudioFile() {
        guard phase == .idle else {
            WisprLog.log("audio import ignored: phase=\(phase)")
            return
        }
        guard modelReady else {
            pill.showError("Transcription model still loading — try again shortly")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel is modal, but the global hotkey tap listens in
        // .commonModes and still fires while it is up — a dictation may
        // have started (and still be recording) by the time Open is
        // clicked. Never clobber it: its endRecording guard checks for
        // .recording, so overwriting phase here would lose the dictation
        // and leave the recorder running.
        guard phase == .idle else {
            WisprLog.log("audio import skipped: dictation started while panel was open")
            return
        }
        transcribeAudioFile(at: url)
    }

    /// Runs the imported file through the same transcribe → cleanup →
    /// corrections → formatting pipeline as live dictation, but nothing is
    /// typed anywhere: the result lands only in History (bundle ID
    /// "wispr.file-import", delivered=false), which opens when done.
    private func transcribeAudioFile(at url: URL) {
        phase = .transcribing
        statusItem.setIcon(.transcribing)
        windowModel.activity = .transcribing
        pill.showTranscribing()
        Task {
            do {
                // Decode off the main actor — a long file is real CPU work.
                let samples = try await Task.detached(priority: .userInitiated) {
                    try AudioFileImporter.loadSamples(url: url)
                }.value
                let text = try await transcriber.transcribe(samples: samples, language: settings.pinnedLanguage)
                WisprLog.log("file import transcribed \(text.count) chars from \(samples.count) samples")
                let rawText = text
                var cleanedText = text
                if !cleanedText.isEmpty && settings.cleanupEnabled {
                    let hints = settings.learningEnabled ? await correctionStore.topPairs(limit: 20) : []
                    let vocabulary = Array(await vocabularyStore.all().suffix(50))
                    cleanedText = await cleanupEngine.clean(
                        cleanedText, modelID: settings.cleanupModelID, hints: hints, vocabulary: vocabulary)
                }
                var appliedCorrections: [String] = []
                if !cleanedText.isEmpty && settings.learningEnabled {
                    let pairs = await correctionStore.topPairs(limit: .max)
                    let (correctedText, applied) = CorrectionApplier.apply(pairs, to: cleanedText)
                    cleanedText = correctedText
                    appliedCorrections = applied
                }
                cleanedText = FormattingCommands.apply(cleanedText)
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
                guard !cleanedText.isEmpty else {
                    // History is the only output channel for an import —
                    // an empty transcript must not look like success.
                    self.pill.showError("No speech detected in file")
                    return
                }
                self.pill.hide()
                // Recorded regardless of the History toggle: an import is
                // an explicit request whose only destination is History,
                // unlike passively captured live dictation.
                let entry = HistoryEntry(
                    id: UUID(),
                    date: Date(),
                    appName: FileManager.default.displayName(atPath: url.path),
                    appBundleID: "wispr.file-import",
                    rawText: rawText,
                    cleanedText: cleanedText,
                    durationSeconds: Double(samples.count) / AudioResampler.targetSampleRate,
                    wordCount: cleanedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
                    delivered: false,
                    appliedCorrections: appliedCorrections.isEmpty ? nil : appliedCorrections)
                // Awaited (unlike live dictation's fire-and-forget) so
                // the entry is already there when History opens below.
                await self.historyStore.append(entry)
                self.showMainWindow(tab: .history)
            } catch {
                WisprLog.log("audio import FAILED: \(error)")
                if case WisprError.audioFileTooLong = error {
                    self.pill.showError("Audio file too long (max 30 minutes)")
                } else {
                    self.pill.showError("Couldn't read audio file")
                }
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
            }
        }
    }

    @objc private func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/jordanmoyo/wispr-free/releases/latest")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        showMainWindow(tab: .general)
    }

    /// Reopen entry point (Dock icon / Finder double-click while running):
    /// bring up the main window on whatever tab it last showed.
    @objc public func openMainWindow() {
        showMainWindow(tab: windowModel.selectedTab)
    }

    @objc private func openHistory() {
        showMainWindow(tab: .history)
    }

    private func showMainWindow(tab: MainTab) {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                model: windowModel, settings: settings, modelStore: modelStore,
                historyStore: historyStore, correctionStore: correctionStore,
                vocabularyStore: vocabularyStore,
                actions: makeSettingsActions())
        }
        mainWindow?.show(tab: tab)
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            onHotkeyChange: { [weak self] keyCode in
                guard let self else { return }
                self.hotkey.keyCode = keyCode
                self.syncWindowModelStatusLine()
                if !self.hotkey.start() {
                    self.pill.showError("Grant Input Monitoring, then relaunch Wispr Free")
                    Permissions.openSystemSettings(pane: .inputMonitoring)
                }
            },
            onModelChange: { [weak self] _ in
                guard let self else { return }
                self.buildMenu()
                Task { await self.loadSelectedModel() }
            },
            onCleanupToggle: { [weak self] enabled in
                guard let self else { return }
                self.buildMenu()
                if !enabled {
                    Task { await self.cleanupEngine.unload() }
                }
            },
            onCleanupModelChange: { [weak self] _ in
                guard let self else { return }
                self.buildMenu()
                // Lazy reload on next dictation, same as the menu path.
                Task { await self.cleanupEngine.unload() }
            },
            onLanguageChange: { [weak self] pinned in
                self?.buildMenu()
                WisprLog.log("pinned language changed: \(pinned ?? "auto")")
            },
            onPreRollToggle: { [weak self] enabled in
                guard let self else { return }
                self.settings.preRollEnabled = enabled
                // The setting always persists; the recorder only picks
                // it up here when the mic is confirmed granted. If mic
                // status is unknown/false, the next bootstrap applies it
                // (see `bootstrap()`).
                if self.micGranted {
                    self.recorder.preRollEnabled = enabled
                }
                WisprLog.log("pre-roll enabled=\(enabled) micGranted=\(self.micGranted)")
            },
            onUpdateCheckToggle: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    // Immediate check rather than waiting up to 24h for
                    // the next scheduled tick.
                    Task { await self.performUpdateCheck() }
                } else {
                    self.availableUpdate = nil
                    self.buildMenu()
                }
            },
            onRulesChange: { [weak self] in
                WisprLog.log("delivery rules changed: count=\(self?.settings.deliveryRules.count ?? 0)")
            },
            onActivationModeChange: { [weak self] mode in
                guard let self else { return }
                self.syncWindowModelStatusLine()
                WisprLog.log("activation mode: \(mode.rawValue)")
            },
            onPillPositionChange: { [weak self] position in
                guard let self else { return }
                self.pill.position = position
                WisprLog.log("pill position: \(position.rawValue)")
            },
            onInputDeviceChange: { [weak self] uid in
                guard let self else { return }
                self.recorder.preferredInputDeviceUID = uid
                WisprLog.log("input device: \(uid ?? "system default")")
            })
    }
}
