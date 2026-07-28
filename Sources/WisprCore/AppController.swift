import AppKit
import AVFoundation

@MainActor
public final class AppController: NSObject {
    private let settings = SettingsStore()
    private let modelStore = ModelStore.defaultStore()
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let pill = OverlayPill()
    private let statusItem = StatusItemController()
    private lazy var transcriber = Transcriber(modelStore: modelStore)
    private lazy var cleanupEngine = CleanupEngine(
        backend: MLXCleanupBackend(cacheDirectory: modelStore.cleanupCacheDirectory))

    private enum Phase { case idle, recording, transcribing }
    private var phase: Phase = .idle
    private var modelReady = false
    private var recordingStart: Date?
    private var settingsWindow: SettingsWindowController?
    private var loadEpoch = 0

    public override init() {
        super.init()
    }

    public func start() {
        buildMenu()
        hotkey.keyCode = settings.hotkeyKeyCode
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }

        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        WisprLog.log("bootstrap: begin (hotkey keyCode=\(settings.hotkeyKeyCode))")
        let micOK = await Permissions.microphoneGranted()
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

        await loadSelectedModel()
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
        pill.showRecording()
        recorder.onLevel = { [weak self] level in self?.pill.pushLevel(level) }
    }

    private func endRecording() {
        WisprLog.log("hotkey RELEASE: phase=\(phase)")
        guard phase == .recording else { return }
        let samples = recorder.stop()
        WisprLog.log("recorded \(samples.count) samples (\(String(format: "%.2f", Recorder.duration(of: samples)))s)")
        let heldSeconds = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        guard DictationGate.shouldTranscribe(samples: samples) else {
            phase = .idle
            statusItem.setIcon(.idle)
            if samples.isEmpty && heldSeconds >= 1.0 {
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
        pill.showTranscribing()

        Task {
            do {
                var text = try await transcriber.transcribe(samples: samples)
                WisprLog.log("transcribed \(text.count) chars")
                if !text.isEmpty && settings.cleanupEnabled {
                    text = await cleanupEngine.clean(text, modelID: settings.cleanupModelID)
                    WisprLog.log("cleanup returned \(text.count) chars")
                }
                if !text.isEmpty {
                    let pasted = Paster.deliver(text)
                    WisprLog.log("delivered: pasted=\(pasted)")
                }
                self.pill.hide()
            } catch {
                self.pill.showError("Transcription failed")
                WisprLog.log("transcribe FAILED: \(error)")
            }
            self.phase = .idle
            self.statusItem.setIcon(.idle)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = statusItem.menu
        menu.removeAllItems()

        let header = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for model in ModelRegistry.models {
            let installed = modelStore.isInstalled(model)
            let suffix = installed ? "" : "  (↓ \(model.approxSizeMB) MB)"
            let item = NSMenuItem(title: model.displayName + suffix,
                                  action: #selector(selectModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = model.id
            item.state = model.id == settings.selectedModelID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let cleanupToggle = NSMenuItem(title: "AI Cleanup",
                                       action: #selector(toggleCleanup),
                                       keyEquivalent: "")
        cleanupToggle.target = self
        cleanupToggle.state = settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanupToggle)

        let cleanupHeader = NSMenuItem(title: "Cleanup Model", action: nil, keyEquivalent: "")
        cleanupHeader.isEnabled = false
        menu.addItem(cleanupHeader)

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
            menu.addItem(item)
        }

        menu.addItem(.separator())
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings,
                modelStore: modelStore,
                onHotkeyChange: { [weak self] keyCode in
                    guard let self else { return }
                    self.hotkey.keyCode = keyCode
                    if !self.hotkey.start() {
                        self.pill.showError("Grant Input Monitoring, then relaunch Wispr Free")
                        Permissions.openSystemSettings(pane: .inputMonitoring)
                    }
                },
                onModelChange: { [weak self] _ in
                    guard let self else { return }
                    self.buildMenu()
                    Task { await self.loadSelectedModel() }
                })
        }
        settingsWindow?.show()
    }
}
