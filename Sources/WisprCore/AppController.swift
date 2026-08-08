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
    private let audioArchive = AudioArchiveStore.defaultStore()
    private let meetingStore = MeetingStore.defaultStore()
    private let meetingAudioStore = MeetingAudioStore.defaultStore()
    private let transcriptionStore = TranscriptionJobStore.defaultStore()
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let pill = OverlayPill()
    private let statusItem = StatusItemController()
    private lazy var transcriber = Transcriber(modelStore: modelStore)
    /// Hoisted out of `cleanupEngine`'s initializer so `CleanupBackendGenerator`
    /// (the meeting summarizer/enhancer's text backend) can share the exact
    /// same `MLXCleanupBackend` instance rather than constructing a second
    /// one — the backend owns a single loaded MLX model, and two instances
    /// would double the memory footprint and load time for no benefit.
    private lazy var cleanupBackend = MLXCleanupBackend(cacheDirectory: modelStore.cleanupCacheDirectory)
    private lazy var cleanupEngine = CleanupEngine(backend: cleanupBackend)
    private lazy var updateChecker = UpdateChecker(
        transport: GitHubUpdateTransport(), currentVersion: currentAppVersion())
    private let meetingDiarizer = FluidAudioDiarizer()
    private let callMonitor = CallAppMonitor()

    private enum Phase { case idle, recording, transcribing }
    private var phase: Phase = .idle
    private var modelReady = false
    /// Whether the current hold-mode recording has been "locked" via the
    /// shift-tap gesture (`HotkeyMonitor.onLockTap`) — while true, releasing
    /// the hotkey does not stop the recording; pressing it again does.
    private var holdLocked = false
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

    // MARK: - Meetings

    /// Owns all meeting-recording state and logic (the recorder, the
    /// setup/stop-coalescing flags, the pipeline-run chain, the registered
    /// `MeetingsViewModel`) — extracted out of `AppController` specifically
    /// so it can be constructed on its own in a test, with fakes substituted
    /// for the recorder and the pipeline. See `MeetingsCoordinatorImpl`'s
    /// doc comment for why that extraction was necessary (in short:
    /// `StatusItemController.init()` has a real, visible side effect, which
    /// rules out constructing a full `AppController` in a test).
    ///
    /// `lazy`, not a plain stored property, because its factory closures
    /// below capture `self` — only valid once `self` is fully initialized.
    private lazy var meetingsCoordinator = MeetingsCoordinatorImpl(
        meetingStore: meetingStore,
        meetingAudioStore: meetingAudioStore,
        settings: settings,
        meetingDiarizer: meetingDiarizer,
        recorderFactory: { [self] id, micURL, systemURL in
            // Captured strongly (`[self]`), not weakly: `meetingsCoordinator`
            // is an AppController-owned property with the same lifetime as
            // AppController itself — a long-lived singleton, constructed
            // once in `main.swift`, alive until process exit. A cycle here
            // never leaks, unlike the `[weak self]` closures handed to
            // OTHER long-lived collaborators (`hotkey`/`pill`) elsewhere in
            // this file, which use `weak` as defensive style since those
            // objects don't themselves hold a reference back to this one.
            MeetingRecorder(meetingID: id,
                             micSource: MeetingMicSource(deviceUID: self.settings.inputDeviceUID),
                             systemSource: SystemAudioSource(),
                             micURL: micURL, systemURL: systemURL)
        },
        pipelineFactory: { [self] diarizer in self.makePipeline(diarizer: diarizer) },
        dictationPhaseIdle: { [weak self] in self?.phase == .idle },
        showError: { [weak self] message in self?.pill.showError(message) },
        setStatusIcon: { [weak self] icon in self?.statusItem.setIcon(icon) },
        rebuildMenu: { [weak self] in self?.buildMenu() },
        showMeetingsWindow: { [weak self] in self?.showMainWindow(tab: .meetings) })

    /// Read by `beginRecording()` to refuse dictation while a meeting is
    /// recording, being set up, or being torn down, and evaluated by
    /// `meetingStartRefusal` to refuse a second meeting while one is already
    /// active.
    var meetingRecordingActive: Bool { meetingsCoordinator.meetingRecordingActive }

    // MARK: - Transcribe
    //
    // `AppController` is itself the Transcribe pane's coordinator (see the
    // `TranscriptionCoordinating` extension below): a run needs the Whisper
    // pipeline, the MLX backend and the dictation phase machine, all of which
    // live here. Only the fields a run's own lifetime needs are stored.

    /// The single in-flight transcription run, so `cancel()` can stop it and
    /// `start(request:)` can refuse a second one. Cleared by the run's own
    /// `defer`, whether it succeeded, failed, or was cancelled — leaving it
    /// set would refuse every later run for the rest of the session.
    private var transcriptionRun: Task<Void, Never>?
    /// Which job `transcriptionRun` is transcribing. Kept alongside the task
    /// so `register(model:)` can tell a pane opened mid-run which job is
    /// live, and `delete(id:)` can tell whether the row being deleted is the
    /// one being worked on.
    private var transcriptionRunJobID: UUID?
    /// Claimed synchronously, before `start(request:)`'s first `await`, and
    /// released once that call has fully resolved. `transcriptionRun` alone
    /// cannot gate re-entrancy: it is not assigned until after the job row
    /// has been written, and the main actor is free across that await, so two
    /// overlapping `start` calls would both observe `transcriptionRun == nil`
    /// and both begin a run. The `TranscriptionViewModel.startInFlight` /
    /// `MeetingsCoordinatorImpl.startMeetingTask` precedent: mutate the flag
    /// BEFORE the await, not after.
    private var transcriptionStartInFlight = false
    /// Weak, like `MeetingsCoordinatorImpl.meetingsModel`: the coordinator
    /// must never be the thing keeping a closed Transcribe pane's view model
    /// alive.
    private weak var transcriptionModel: TranscriptionViewModel?

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
            if self.settings.activationMode == .hold, self.phase == .recording, self.holdLocked {
                self.endRecording()
                return
            }
            if self.settings.activationMode == .toggle, self.phase == .recording {
                self.endRecording()
            } else {
                self.beginRecording()
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if self.settings.activationMode == .hold {
                guard !self.holdLocked else { return }
                self.endRecording()
            }
        }
        hotkey.onLockTap = { [weak self] in
            guard let self, self.settings.activationMode == .hold, self.phase == .recording,
                  !self.holdLocked else { return }
            self.holdLocked = true
            self.pill.showLocked()
            WisprLog.log("hold-lock engaged")
        }
        pill.position = settings.pillPosition
        recorder.preferredInputDeviceUID = settings.inputDeviceUID
        syncWindowModelStatusLine()
        scheduleUpdateChecks()

        applyMeetingAutoDetect(settings.meetingAutoDetect)

        Task { await self.bootstrap() }
    }

    /// Starts or stops `callMonitor` to match `meetingAutoDetect`. Called
    /// once from `start()` at launch, and again from
    /// `SettingsActions.onMeetingAutoDetectToggle` whenever the Privacy pane
    /// toggle changes — `CallAppMonitor.start()`/`stop()` are both
    /// idempotent, so applying the same value twice is harmless, and this is
    /// what makes the toggle take effect immediately instead of requiring a
    /// relaunch.
    private func applyMeetingAutoDetect(_ enabled: Bool) {
        guard enabled else {
            callMonitor.stop()
            return
        }
        callMonitor.isRecordingProvider = { [weak self] in
            guard let self else { return true }
            return self.meetingRecordingActive || self.phase != .idle
        }
        callMonitor.onDetected = { [weak self] app in
            guard let self else { return }
            self.notifyCallDetected(app)
        }
        callMonitor.start()
    }

    /// Offers to record a detected call. Deliberately passive: it tells the
    /// user Wispr noticed and how to start, and never begins recording on
    /// its own — recording a call without an explicit press would be the
    /// wrong default.
    private func notifyCallDetected(_ app: CallApp) {
        pill.showError("\(app.name) call detected — Record Meeting from the menu bar")
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
        // Keeps the pill out of a screen share for the duration of a meeting;
        // see `OverlayPill.sharingType(meetingActive:)`.
        pill.isMeetingActive = { [weak self] in self?.meetingRecordingActive ?? false }
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
        await meetingsCoordinator.reconcileAtLaunch()

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
        guard !meetingRecordingActive else {
            pill.showError(Self.dictationBlockedMessage())
            return
        }
        guard phase == .idle else { return }
        guard modelReady else {
            pill.showError("Model still loading…")
            return
        }
        holdLocked = false
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
        holdLocked = false
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
        // Handed audio with no speech in it, Whisper does not return nothing —
        // it returns a fluent sentence from its subtitle-heavy training data,
        // which would be typed into the user's document as if they had said
        // it. Checking the audio first is the only way to keep that out.
        let quality = AudioQualityGate.classify(samples)
        if let message = quality.userMessage {
            WisprLog.log("refusing to transcribe: \(quality) " +
                         "(peak=\(Recorder.peakAmplitude(of: samples)), " +
                         "voicedFrames=\(AudioQualityGate.voicedFrameCount(samples)))")
            phase = .idle
            statusItem.setIcon(.idle)
            windowModel.activity = .ready
            pill.showError(message)
            return
        }
        phase = .transcribing
        statusItem.setIcon(.transcribing)
        windowModel.activity = .transcribing
        pill.showTranscribing()

        Task {
            do {
                let transcript = try await transcriber.transcribe(
                    samples: samples, language: settings.pinnedLanguage)
                let text = transcript.text
                WisprLog.log("transcribed \(text.count) chars "
                    + "(confidence=\(transcript.confidence.map { "\($0)" } ?? "none"))")
                // Second line of defence, after the audio gate: what came
                // back may still be text the user never said. Nothing is
                // typed, copied, or written to history in that case — the
                // pill says so instead of the dictation vanishing silently.
                if let refusal = DictationPlausibility.refusal(
                    for: text, quality: quality, confidence: transcript.confidence) {
                    WisprLog.log("refusing transcript (\(refusal)): \(text.prefix(60))")
                    self.pill.showError(refusal.userMessage)
                    self.phase = .idle
                    self.statusItem.setIcon(.idle)
                    self.windowModel.activity = .ready
                    return
                }
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
                    self.pill.showCleaning()
                    self.windowModel.activity = .cleaning
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
                        let rule = settings.deliveryRules.first { $0.bundleID == target?.bundleIdentifier }
                        let tone = rule?.tone
                        let customToneText = rule?.tone == .custom ? rule?.toneCustomText : nil
                        cleanedText = await cleanupEngine.clean(
                            cleanedText, modelID: settings.cleanupModelID,
                            hints: hints, vocabulary: vocabulary, tone: tone, customToneText: customToneText)
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
                                   cleanedText: cleanedText, samples: samples,
                                   sessionSampleCount: result.sessionSampleCount,
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
        cleanedText: String, samples: [Float], sessionSampleCount: Int, delivered: Bool,
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
        let retainAudio = settings.retainAudio
        Task {
            await self.historyStore.append(entry)
            if retainAudio {
                await self.audioArchive.save(samples: samples, id: entry.id)
            }
        }
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

        let meetingsItem = NSMenuItem(title: "Meetings…",
                                      action: #selector(openMeetings),
                                      keyEquivalent: "")
        meetingsItem.target = self
        menu.addItem(meetingsItem)

        let recordItem = NSMenuItem(
            title: meetingRecordingActive ? "Stop Meeting" : "Record Meeting",
            action: #selector(toggleMeetingRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)
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
        // Same exclusion the hotkey path applies. Not just tidiness: this
        // path sets the menu-bar icon to `.transcribing` and then, on every
        // exit, to `.idle` — which silently erased the `.recording` icon of a
        // meeting still in progress. Nothing re-asserts it, so the app went
        // on capturing mic and system audio behind an idle indicator.
        guard !meetingRecordingActive else {
            pill.showError(Self.dictationBlockedMessage())
            return
        }
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
                // A silent file would make Whisper hallucinate ("you") —
                // refuse it with the same message as an empty transcript.
                guard Recorder.peakAmplitude(of: samples) >= Recorder.silencePeakThreshold else {
                    WisprLog.log("file import is digital silence, refusing")
                    self.phase = .idle
                    self.statusItem.setIcon(.idle)
                    self.windowModel.activity = .ready
                    self.pill.showError("No speech detected in file")
                    return
                }
                let text = try await transcriber.transcribe(
                    samples: samples, language: settings.pinnedLanguage).text
                WisprLog.log("file import transcribed \(text.count) chars from \(samples.count) samples")
                // An imported file may legitimately be a quiet recording, so
                // unlike live dictation its audio is not held to a speech
                // floor, and its confidence is not held to one either: the
                // user picked this file and expects a transcript, and the
                // output lands in History rather than in their document. A
                // subtitle sign-off coming back from a stretch of it is no
                // more real here than anywhere else, though.
                if let refusal = DictationPlausibility.refusal(for: text, quality: .speech) {
                    WisprLog.log("file import refused (\(refusal)): \(text.prefix(60))")
                    self.phase = .idle
                    self.statusItem.setIcon(.idle)
                    self.windowModel.activity = .ready
                    self.pill.showError("No speech detected in file")
                    return
                }
                let rawText = text
                let (cleanedText, appliedCorrections) = await self.cleanupAndCorrect(rawText)
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
                if self.settings.retainAudio {
                    await self.audioArchive.save(samples: samples, id: entry.id)
                }
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

    /// Shared tail of the file-import and re-transcribe pipelines: cleanup
    /// (if enabled) → learned corrections (if enabled) → deterministic
    /// spoken formatting. Pulled out of `transcribeAudioFile` so
    /// `retranscribe` doesn't duplicate it — unlike live dictation's
    /// `endRecording`, neither path has a spoken directive or a per-app tone
    /// to apply, so this omits both.
    private func cleanupAndCorrect(_ text: String) async -> (cleanedText: String, appliedCorrections: [String]) {
        var cleanedText = text
        if !cleanedText.isEmpty && settings.cleanupEnabled {
            self.pill.showCleaning()
            self.windowModel.activity = .cleaning
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
        return (cleanedText, appliedCorrections)
    }

    /// Re-runs a past History dictation's archived audio through the same
    /// transcribe → cleanup → corrections → formatting pipeline as
    /// `transcribeAudioFile`, appending a new entry rather than mutating the
    /// original (bundle ID "wispr.retranscribe", delivered=false). Nothing
    /// is typed anywhere — same as a file import, History is the only
    /// output channel. Called from the History pane via the main window
    /// context's `retranscribe` closure.
    private func retranscribe(entry: HistoryEntry) {
        // See `importAudioFile` — this path drives the same status icon and
        // would leave a live meeting's indicator showing idle.
        guard !meetingRecordingActive else {
            pill.showError(Self.dictationBlockedMessage())
            return
        }
        guard phase == .idle else {
            pill.showError("Busy — finish the current dictation first")
            return
        }
        guard modelReady else {
            pill.showError("Transcription model still loading — try again shortly")
            return
        }
        // Claimed synchronously, before the Task's first `await` — the
        // same ordering `transcribeAudioFile`/`importAudioFile` use. The
        // guards above run on the main actor with no intervening
        // suspension point, so two rapid taps can't both pass them and
        // race into two concurrent pipelines / duplicate entries.
        phase = .transcribing
        statusItem.setIcon(.transcribing)
        windowModel.activity = .transcribing
        pill.showTranscribing()
        Task {
            guard let url = await self.audioArchive.url(for: entry.id) else {
                // A brief transcribing flash here is fine — the busy claim
                // above is what matters; this just unwinds it correctly.
                self.pill.showError("Audio no longer available")
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
                return
            }
            do {
                // Decode off the main actor — a long recording is real CPU work.
                let samples = try await Task.detached(priority: .userInitiated) {
                    try AudioFileImporter.loadSamples(url: url)
                }.value
                let text = try await transcriber.transcribe(
                    samples: samples, language: settings.pinnedLanguage).text
                WisprLog.log("retranscribe: \(text.count) chars from \(samples.count) samples")
                let rawText = text
                let (cleanedText, appliedCorrections) = await self.cleanupAndCorrect(rawText)
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
                guard !cleanedText.isEmpty else {
                    self.pill.showError("No speech detected in file")
                    return
                }
                self.pill.hide()
                let newEntry = HistoryEntry(
                    id: UUID(),
                    date: Date(),
                    appName: entry.appName,
                    appBundleID: "wispr.retranscribe",
                    rawText: rawText,
                    cleanedText: cleanedText,
                    durationSeconds: entry.durationSeconds,
                    wordCount: cleanedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
                    delivered: false,
                    appliedCorrections: appliedCorrections.isEmpty ? nil : appliedCorrections)
                await self.historyStore.append(newEntry)
                if self.settings.retainAudio {
                    await self.audioArchive.save(samples: samples, id: newEntry.id)
                }
                self.showMainWindow(tab: .history)
            } catch {
                WisprLog.log("retranscribe FAILED: \(error)")
                self.pill.showError("Couldn't read audio file")
                self.phase = .idle
                self.statusItem.setIcon(.idle)
                self.windowModel.activity = .ready
            }
        }
    }

    @objc private func openMeetings() {
        showMainWindow(tab: .meetings)
    }

    /// Thin wrapper: all the actual routing (registered pane vs. direct
    /// coordinator call + pill fallback) lives on `MeetingsCoordinatorImpl
    /// .toggleRecording()` now — see its doc comment. Kept here only because
    /// `@objc` selectors require an `NSObject` target, and
    /// `MeetingsCoordinatorImpl` need not be one.
    @objc private func toggleMeetingRecording() {
        Task { await self.meetingsCoordinator.toggleRecording() }
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
                vocabularyStore: vocabularyStore, audioArchive: audioArchive,
                meetingStore: meetingStore, meetingAudioStore: meetingAudioStore,
                transcriptionStore: transcriptionStore,
                actions: makeSettingsActions(),
                retranscribe: { [weak self] entry in self?.retranscribe(entry: entry) },
                meetingsCoordinator: meetingsCoordinator,
                transcriptionCoordinator: self)
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
            },
            onMeetingAutoDetectToggle: { [weak self] enabled in
                guard let self else { return }
                self.applyMeetingAutoDetect(enabled)
                WisprLog.log("meeting auto-detect: \(enabled)")
            })
    }
}

// MARK: - Meetings decision helpers

extension AppController {
    /// The reason a meeting cannot start, or nil if it can. Ordered so the
    /// cheapest fix is reported first. An already-active meeting is NOT a
    /// refusal — the caller returns the running meeting's id instead.
    /// `nonisolated` (pure function of its arguments, no actor state) so
    /// tests can call it synchronously without hopping onto the main actor.
    nonisolated static func meetingStartRefusal(
        dictationPhaseIdle: Bool,
        meetingActive: Bool,
        micGranted: Bool,
        screenCapture: ScreenCaptureAvailability) -> MeetingStartFailure? {
        if !dictationPhaseIdle { return .dictationInProgress }
        if meetingActive { return nil }
        if !micGranted { return .micDenied }
        switch screenCapture {
        case .granted: return nil
        case .denied: return .screenRecordingDenied
        case .unavailable: return .screenCaptureUnavailable
        }
    }

    nonisolated static func dictationBlockedMessage() -> String {
        "Recording a meeting — dictation is paused"
    }

    /// The outcome of racing an async operation against a fixed timeout.
    enum TimeoutOutcome<T: Sendable>: Sendable {
        case completed(T)
        case timedOut
    }

    /// Races `operation` against `seconds`. Exists because a call into
    /// ScreenCaptureKit (`SCShareableContent`/`SCStream`, reached via
    /// `SystemAudioSource.permissionGranted()`/`MeetingRecorder.start()`)
    /// can block indefinitely if `replayd` is wedged — without a bound
    /// here, that single stuck call would hold `meetingSetupInProgress`/
    /// `startMeetingTask` open forever, permanently refusing dictation and
    /// coalescing every future "Record Meeting" tap into the dead attempt,
    /// with no escape short of quitting the app.
    ///
    /// Deliberately NOT built on `withTaskGroup`: a group implicitly awaits
    /// every child task before it returns, even one that lost the race and
    /// was merely asked (via `cancelAll()`) to cancel cooperatively. None of
    /// the calls this wraps check `Task.isCancelled`, so a group-based race
    /// would still block THIS function on the very call it exists to bound
    /// — defeating the whole point (caught by a test hanging during this
    /// task's implementation, not by inspection). Instead, `operation` and
    /// the timer run as two fully independent, unstructured tasks racing to
    /// resume one continuation exactly once (`TimeoutResumeBox`); the loser
    /// is simply abandoned and keeps running in the background, unawaited.
    /// A caller whose `operation` creates a resource (a running `SCStream`,
    /// say) is responsible for tearing that down itself if it ever resolves
    /// late; a pure probe like `permissionGranted()` has nothing to clean up
    /// and can simply be treated as failed. See `startRecorderBounded` for
    /// the resource-owning case.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval, operation: @escaping @Sendable () async -> T
    ) async -> TimeoutOutcome<T> {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<TimeoutOutcome<T>, Never>) in
            let box = TimeoutResumeBox(continuation: continuation)
            Task {
                let value = await operation()
                await box.resolve(.completed(value))
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                await box.resolve(.timedOut)
            }
        }
    }
}

// MARK: - MeetingsCoordinating (moved to MeetingsCoordinatorImpl)
//
// `startMeeting`/`stopMeeting`/`finishStopping`/`reprocess`/`enhanceNotes`/
// `deleteMeeting`/`register(model:)`, and the `deleteMeetingSafely` helper
// this replaced, all now live on `MeetingsCoordinatorImpl` — see its doc
// comment for why (a review's "add the injectable recorder/coordinator
// seam" instruction, since `AppController` itself cannot safely be
// constructed in a test).


// MARK: - Meetings private helpers

extension AppController {
    /// Builds a pipeline sharing the app's existing MLX backend and Whisper
    /// pipeline. Diarization degrades to `NullDiarizer` when the models
    /// cannot be loaded, so a meeting is never lost to a missing download.
    private func makePipeline(diarizer: (any MeetingDiarizing)? = nil) -> MeetingPipeline {
        MeetingPipeline(
            store: meetingStore,
            audioStore: meetingAudioStore,
            transcriber: transcriber,
            diarizer: diarizer ?? meetingDiarizer,
            generator: CleanupBackendGenerator(backend: cleanupBackend,
                                              modelID: settings.cleanupModelID))
    }

    // `runProcessing`/`runEnhanceNotes`/`startRecorderBounded`/
    // `startMeetingTimer`/`stopMeetingTimer` all moved to
    // `MeetingsCoordinatorImpl` along with the rest of the meetings state
    // they close over. `makePipeline` above stays here — it's what
    // `pipelineFactory` (passed into the coordinator's initializer) calls.
}

// MARK: - TimeoutResumeBox

/// Resumes a `CheckedContinuation` exactly once, whichever of two racing
/// unstructured tasks calls `resolve` first — see `AppController.withTimeout`
/// for why this is an actor holding a plain continuation rather than a
/// `withTaskGroup` race. An actor (not a lock) because `resolve` is called
/// from ordinary `async` task bodies, not synchronous code, and this
/// project's Swift 6 mode rejects an `NSLock` taken directly inside an
/// `async func`.
private actor TimeoutResumeBox<T: Sendable> {
    private var continuation: CheckedContinuation<AppController.TimeoutOutcome<T>, Never>?

    init(continuation: CheckedContinuation<AppController.TimeoutOutcome<T>, Never>) {
        self.continuation = continuation
    }

    /// No-ops if already resolved — the second (losing) caller's result is
    /// simply discarded.
    func resolve(_ outcome: AppController.TimeoutOutcome<T>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}

// MARK: - TranscriptionCoordinating

/// A transcriber that can be pointed at a specific Whisper model, which is
/// what a PER-JOB model choice needs — `MeetingSegmentTranscribing` alone
/// describes a transcriber whose model somebody else already picked.
/// `Transcriber` conforms; a test conforms a spy to it and asserts which
/// model id a run actually asked for.
public protocol ModelLoadingTranscribing: MeetingSegmentTranscribing {
    func load(model: WhisperModel) async throws
}

extension Transcriber: ModelLoadingTranscribing {}

extension AppController: TranscriptionCoordinating {
    /// Starts one file transcribing, or says why it cannot.
    ///
    /// The refusals are ordered cheapest-fix-first, the same rule
    /// `meetingStartRefusal` follows. Nothing here touches
    /// `statusItem.setIcon` — deliberately. `importAudioFile` does, and an
    /// earlier version of that path set `.idle` on exit and so silently
    /// erased a live meeting's recording indicator while the app went on
    /// capturing (see its comment, and `MeetingMutualExclusionTests`). A
    /// transcription run has the Transcribe pane's own progress bar; it has
    /// no business repainting the menu bar.
    public func start(request: TranscriptionRequest)
        async -> Result<UUID, TranscriptionStartFailure> {
        guard phase == .idle else { return .failure(.dictationInProgress) }
        guard !meetingRecordingActive else { return .failure(.meetingInProgress) }
        // A model that isn't on disk yet would be downloaded by
        // `transcriber.load` inside the run — gigabytes, with no progress
        // reporting and no cancellation check, behind a bar that reads
        // "0% · Transcribing". Refuse up front and name the download instead.
        if let requested = ModelRegistry.model(id: request.transcriptionModelID),
           !modelStore.isInstalled(requested) {
            WisprLog.log("transcription start refused: model not installed "
                + "\(requested.id)")
            return .failure(.modelNotInstalled(requested.displayName))
        }
        // `modelReady` tracks the DICTATION model's load, so it only gates a
        // run that actually uses it. A run on any other model gets its own
        // `Transcriber` (see `runTranscriber(for:)`) and waits for nothing.
        guard request.transcriptionModelID != settings.selectedModelID || modelReady else {
            return .failure(.modelLoading)
        }
        guard transcriptionRun == nil, !transcriptionStartInFlight else {
            return .failure(.alreadyRunning)
        }
        transcriptionStartInFlight = true
        defer { transcriptionStartInFlight = false }

        // The reader is built BEFORE the row exists. It is what rejects a
        // file that is too long or cannot be decoded, and a row created first
        // would be orphaned by that rejection: a permanently `.processing`
        // job for a file that never started.
        let reader: AudioFileReader
        do {
            reader = try AudioFileReader(url: request.sourceURL)
        } catch WisprError.audioFileTooLong {
            WisprLog.log("transcription start refused: file too long")
            return .failure(.fileTooLong)
        } catch WisprError.audioFileUnreadable(let reason) {
            WisprLog.log("transcription start refused: unreadable (\(reason))")
            return .failure(.fileUnreadable(reason))
        } catch {
            WisprLog.log("transcription start refused: \(error)")
            return .failure(.fileUnreadable(error.localizedDescription))
        }

        let job = Self.makeJob(request: request,
                               durationSeconds: reader.durationSeconds)
        await transcriptionStore.upsert(job)

        let store = transcriptionStore
        let diarizer: (any MeetingDiarizing)? = request.diarize ? meetingDiarizer : nil
        let runTranscriber = self.runTranscriber(for: request)
        transcriptionRunJobID = job.id
        transcriptionRun = Task { [weak self] in
            defer {
                self?.transcriptionRun = nil
                self?.transcriptionRunJobID = nil
                // Without this the pane's `isRunning` stays true forever and
                // Start never re-enables — the run is over either way, so the
                // bar must come down on success, failure AND cancellation.
                self?.transcriptionModel?.syncActive(id: nil)
                self?.transcriptionModel?.updateProgress(nil)
            }
            await Self.performTranscriptionRun(
                jobID: job.id, request: request, audio: reader,
                transcriber: runTranscriber, diarizer: diarizer, store: store,
                progress: { progress in
                    Task { @MainActor in
                        self?.transcriptionModel?.updateProgress(progress)
                    }
                })
        }
        WisprLog.log("transcription start: job=\(job.id) "
            + "model=\(request.transcriptionModelID) "
            + "document=\(request.enhancementModelID) "
            + "diarize=\(request.diarize) seconds=\(reader.durationSeconds)")
        return .success(job.id)
    }

    /// Cancellation is cooperative: `MeetingTranscriber` breaks between
    /// chunks and `TranscriptionPipeline` then stores what it had as
    /// `.partial`. Deliberately NOT awaited — a chunk is ten minutes of
    /// audio, so awaiting would leave the Cancel button dead for minutes.
    public func cancel() async {
        guard let run = transcriptionRun else { return }
        WisprLog.log("transcription cancel requested: job="
            + "\(transcriptionRunJobID?.uuidString ?? "none")")
        run.cancel()
    }

    public func generate(kind: TranscriptOutputKind, jobID: UUID) async {
        // `performGenerate` loads THIS job's document model into the SHARED
        // `MLXCleanupBackend`, which evicts whatever dictation had loaded.
        // `CleanupEngine` shares that backend instance and is not told, so
        // its `ensureLoadStarted` short-circuits on a non-nil `loadTask` and
        // every later dictation would silently clean up with this job's
        // model. Unloading the engine on both sides of the call makes the
        // next dictation reload the user's own model lazily — the same
        // principle `runTranscriber(for:)` holds for Whisper.
        let jobModelID = await transcriptionStore.job(id: jobID)?.enhancementModelID
        let repoints = Self.generateRepointsCleanupModel(
            jobModelID: jobModelID, dictationModelID: settings.cleanupModelID)
        if repoints { await cleanupEngine.unload() }
        await Self.performGenerate(
            kind: kind, jobID: jobID, store: transcriptionStore,
            backend: cleanupBackend,
            progress: { [weak self] fraction in
                Task { @MainActor in
                    self?.transcriptionModel?.updateProgress(
                        TranscriptionProgress.make(stage: .generating,
                                                   stageFraction: fraction,
                                                   diarizationEnabled: false))
                }
            })
        if repoints { await cleanupEngine.unload() }
        transcriptionModel?.updateProgress(nil)
    }

    /// Removes the row, cancelling this job's own run first. The store's
    /// `update(id:)` already refuses to resurrect a deleted row, so the
    /// cancel is not what makes the delete safe — it is what stops the app
    /// spending another hour transcribing audio for a job the user just threw
    /// away.
    public func delete(id: UUID) async {
        if transcriptionRunJobID == id {
            transcriptionRun?.cancel()
        }
        await transcriptionStore.delete(id: id)
    }

    /// Mirrors `MeetingsCoordinatorImpl.register(model:)`: a pane opened
    /// while a run is already going shows that run rather than a stale idle
    /// state.
    @MainActor public func register(model: TranscriptionViewModel) {
        transcriptionModel = model
        model.syncActive(id: transcriptionRunJobID)
    }

    // MARK: Testable seams
    //
    // `AppController` itself cannot be constructed in a test —
    // `StatusItemController.init()` calls `NSStatusBar.system
    // .statusItem(withLength:)`, a real side effect with no test-only
    // alternative (see `MeetingsCoordinatorImpl`'s doc comment). So the two
    // decisions that must be provably right — that a run uses the model the
    // REQUEST named, and that the row records the request's own choices —
    // live in `nonisolated static` functions a test can call directly with
    // spies, and `start`/`generate` above are the straight-line code that
    // calls them.

    /// Whether generating a document for this job would leave the shared
    /// cleanup backend holding a model dictation did not ask for.
    ///
    /// True only when the job names a model AND it differs from the one
    /// dictation is set to: a job with no recorded model cannot repoint
    /// anything, and unloading when the two agree would throw away a warm
    /// model for nothing, adding a load to the next dictation.
    nonisolated static func generateRepointsCleanupModel(
        jobModelID: String?, dictationModelID: String) -> Bool {
        guard let jobModelID else { return false }
        return jobModelID != dictationModelID
    }

    /// The row one request becomes. Every per-job choice the setup screen
    /// offers is copied here: a picker whose value never reached the row
    /// would make the whole screen decorative, and `performGenerate` reads
    /// `enhancementModelID` back off the row hours later when the user asks
    /// for a document.
    nonisolated static func makeJob(request: TranscriptionRequest,
                                    durationSeconds: Double,
                                    createdAt: Date = Date()) -> TranscriptionJob {
        TranscriptionJob(
            title: TranscriptionJob.defaultTitle(sourcePath: request.sourceURL.path),
            createdAt: createdAt,
            sourcePath: request.sourceURL.path,
            durationSeconds: durationSeconds,
            transcriptionModelID: request.transcriptionModelID,
            enhancementModelID: request.enhancementModelID,
            language: request.language,
            diarizationRequested: request.diarize)
    }

    /// The body of one run: loads the Whisper model the REQUEST asked for —
    /// not whichever model dictation happens to have selected — and only then
    /// hands that transcriber to the pipeline.
    ///
    /// A model that cannot be loaded fails the row rather than transcribing
    /// with the wrong one. Silently substituting a different model would
    /// produce a transcript the user cannot account for, at a quality they
    /// did not choose.
    nonisolated static func performTranscriptionRun(
        jobID: UUID,
        request: TranscriptionRequest,
        audio: any AudioChunkProviding,
        transcriber: any ModelLoadingTranscribing,
        diarizer: (any MeetingDiarizing)?,
        store: TranscriptionJobStore,
        progress: (@Sendable (TranscriptionProgress) -> Void)?) async {
        guard let model = ModelRegistry.model(id: request.transcriptionModelID) else {
            WisprLog.log("transcription run: unknown model id "
                + "\(request.transcriptionModelID)")
            await store.update(id: jobID) {
                $0.status = .failed
                $0.failureNote = "The transcription model this job asked for is "
                    + "no longer available. Pick another one in Settings › Models."
            }
            progress?(TranscriptionProgress(stage: .done, fraction: 1))
            return
        }
        do {
            try await transcriber.load(model: model)
        } catch {
            WisprLog.log("transcription run: model load FAILED id=\(model.id) "
                + "error=\(error)")
            await store.update(id: jobID) {
                $0.status = .failed
                $0.failureNote = "The \(model.displayName) model could not be "
                    + "loaded, so this file was not transcribed."
            }
            progress?(TranscriptionProgress(stage: .done, fraction: 1))
            return
        }
        await TranscriptionPipeline.transcribe(
            jobID: jobID, audio: audio, diarize: request.diarize,
            language: request.language,
            transcriber: transcriber, diarizer: diarizer,
            store: store, progress: progress)
    }

    /// Generates one document with the model THIS job was set up with, read
    /// back off its row — `start` copied it there from the request, and a
    /// document generated hours later must still use the model the user
    /// picked for this file rather than whatever dictation's cleanup setting
    /// says today.
    nonisolated static func performGenerate(
        kind: TranscriptOutputKind,
        jobID: UUID,
        store: TranscriptionJobStore,
        backend: any CleanupBackend,
        progress: (@Sendable (Double) -> Void)?) async {
        guard let job = await store.job(id: jobID) else { return }
        await TranscriptionPipeline.generate(
            kind: kind, jobID: jobID, store: store,
            using: CleanupBackendGenerator(backend: backend,
                                           modelID: job.enhancementModelID),
            progress: progress)
    }

    /// The transcriber a run uses: the shared dictation one when the request
    /// names the model dictation already has loaded, and a DEDICATED
    /// `Transcriber` otherwise.
    ///
    /// Loading the request's model into the shared actor would silently
    /// repoint dictation at it. Nothing about a transcription run blocks the
    /// hotkey — `phase` stays `.idle` for the whole run — so the very next
    /// dictation would decode with a model the user chose for one file, not
    /// for their dictation. A second `Transcriber` costs a second resident
    /// model for the length of the run, which is the price of not lying about
    /// either choice.
    private func runTranscriber(for request: TranscriptionRequest)
        -> any ModelLoadingTranscribing {
        request.transcriptionModelID == settings.selectedModelID
            ? transcriber
            : Transcriber(modelStore: modelStore)
    }
}
