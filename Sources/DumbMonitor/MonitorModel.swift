// SPDX-License-Identifier: MPL-2.0
import AppKit
import ServiceManagement
import S9InputControl
import SwiftUI

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var connected = false
    @Published private(set) var working = false
    @Published private(set) var volume = 0
    @Published private(set) var muted = false
    @Published private(set) var brightness = 50
    @Published private(set) var input: S9Input?
    @Published var error: String?
    @Published var host = ""
    @Published var pairing = false
    @Published var mediaKeysRunning = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published private var storedVolumeLimit: Int
    var volumeLimit: Int {
        get { storedVolumeLimit }
        set {
            guard !stopped else { return }
            let value = min(100, max(1, newValue))
            guard value != storedVolumeLimit else { return }
            storedVolumeLimit = value
            defaults.set(value, forKey: "volumeLimit")
        }
    }
    @Published private var storedVolumeStep: Int
    var volumeStep: Int {
        get { storedVolumeStep }
        set {
            guard !stopped else { return }
            storedVolumeStep = min(100, max(1, newValue)); defaults.set(storedVolumeStep, forKey: "volumeStep")
        }
    }
    @Published private var storedBrightnessStep: Int
    var brightnessStep: Int {
        get { storedBrightnessStep }
        set {
            guard !stopped else { return }
            storedBrightnessStep = min(50, max(1, newValue)); defaults.set(storedBrightnessStep, forKey: "brightnessStep")
        }
    }
    @Published var displayUUID: String {
        didSet { if !stopped { defaults.set(displayUUID, forKey: "displayUUID") } }
    }
    @Published var audioUID: String {
        didSet { if !stopped { defaults.set(audioUID, forKey: "audioUID") } }
    }
    @Published var volumeKeys: Bool {
        didSet { if !stopped { defaults.set(volumeKeys, forKey: "volumeKeys"); updateMediaKeys() } }
    }
    @Published var brightnessKeys: Bool {
        didSet { if !stopped { defaults.set(brightnessKeys, forKey: "brightnessKeys"); updateMediaKeys() } }
    }
    @Published var inputMediaKeys: Bool {
        didSet { if !stopped { defaults.set(inputMediaKeys, forKey: "inputMediaKeys"); updateMediaKeys() } }
    }
    @Published private(set) var inputConfiguration: InputSourceConfiguration
    let audio = AudioOutputMonitor()
    let media = MediaKeys()
    let focus: DisplayFocusMonitor
    var onBrightnessFeedback: ((Int) -> Void)?
    private let defaults: UserDefaults
    private var credentials: MonitorCredentials?
    private var controller: (any MonitorTransport)?
    private var pump: Task<Void, Never>?
    private var refreshing = false
    private var pendingVolume: Int?
    private var pendingBrightness: Int?
    private var pendingMuted: Bool?
    private var pendingInput: S9Input?
    private var keyboardVolumeSteps: [Int] = []
    private var keyboardBrightnessSteps: [(direction: Int, fine: Bool, step: Int)] = []
    private var keyboardMuteToggles = 0
    private var muteFromKeyboard = false
    private var confirmedVolume = 0
    private var confirmedBrightness = 50
    private var confirmedMuted = false
    private var confirmedInput: S9Input?
    private var lastAudioRead = Date.distantPast
    private var lastBrightnessRead = Date.distantPast
    private var polling: Task<Void, Never>?
    private var panelVisible = false
    private var stopped = false

    init(transport: (any MonitorTransport)? = nil, defaults: UserDefaults = .standard, automaticServices: Bool = true) {
        self.defaults = defaults
        inputConfiguration = InputSourceConfiguration.load(from: defaults)
        focus = DisplayFocusMonitor(start: automaticServices)
        let storedLimit = defaults.integer(forKey: "volumeLimit")
        storedVolumeLimit = storedLimit == 0 ? 32 : min(100, max(1, storedLimit))
        let savedVolumeStep = defaults.integer(forKey: "volumeStep")
        storedVolumeStep = savedVolumeStep == 0 ? 2 : min(100, max(1, savedVolumeStep))
        let savedBrightnessStep = defaults.integer(forKey: "brightnessStep")
        storedBrightnessStep = savedBrightnessStep == 0 ? 3 : min(50, max(1, savedBrightnessStep))
        displayUUID = defaults.string(forKey: "displayUUID") ?? ""
        audioUID = defaults.string(forKey: "audioUID") ?? ""
        volumeKeys = defaults.bool(forKey: "volumeKeys")
        brightnessKeys = defaults.bool(forKey: "brightnessKeys")
        inputMediaKeys = defaults.bool(forKey: "inputMediaKeys")
        focus.onDisplaysChanged = { [weak self] in self?.chooseDisplayIfNeeded() }
        audio.onChange = { [weak self] in
            guard let self else { return }
            chooseAudioIfNeeded()
            discardIneligibleKeyboardAudio()
            Task { await self.refresh() }
        }
        media.canHandle = { [weak self] action in
            guard let self, configured, connected, !pairing else { return false }
            if action.isAudio {
                return volumeKeys && !audioUID.isEmpty && audio.defaultUID == audioUID
                    && Date().timeIntervalSince(lastAudioRead) < 25
            }
            return brightnessKeys && focus.isFocused(displayUUID) && Date().timeIntervalSince(lastBrightnessRead) < 25
        }
        media.onKey = { [weak self] action, fine in self?.handleKey(action, fine: fine) }
        media.canHandleInputShortcut = { [weak self] slot in
            guard let self else { return false }
            return inputMediaKeys && configured && connected && !pairing
                && inputConfiguration.source(for: slot)?.source != nil
        }
        media.onInputShortcut = { [weak self] slot in
            guard let self, let source = inputConfiguration.source(for: slot)?.source else { return }
            setInput(source)
        }
        if let transport { controller = transport; configured = true }
        guard automaticServices else { return }
        do {
            if let saved = try CredentialStore.load() { try configure(saved) }
        } catch { self.error = error.localizedDescription }
        chooseAudioIfNeeded()
        chooseDisplayIfNeeded()
        updateMediaKeys()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                updateMediaKeys()
                try? await Task.sleep(for: .seconds(panelVisible ? 2 : 8))
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { Task { await refresh() } }
    }

    func updateInputConfiguration(_ value: InputSourceConfiguration) {
        guard !stopped, value.validationMessage == nil else { return }
        inputConfiguration = value
        defaults.set(value.storageValue, forKey: "inputSources")
        // Once migrated, keep just one source of truth for shortcuts.
        defaults.removeObject(forKey: "usbCShortcut")
        defaults.removeObject(forKey: "displayPortShortcut")
    }

    func selectConfiguredInput(id: String) {
        guard let source = inputConfiguration.sources.first(where: { $0.id == id })?.source else { return }
        setInput(source)
    }

    private func chooseAudioIfNeeded() {
        guard !stopped, audioUID.isEmpty else { return }
        // Exact S9 model name, never an arbitrary current output.
        if let match = audio.outputs.first(where: { $0.name.range(of: "S27C900", options: .caseInsensitive) != nil }) {
            audioUID = match.id
        }
    }

    private func chooseDisplayIfNeeded() {
        guard !stopped, displayUUID.isEmpty else { return }
        let candidates = focus.displays.filter(\.isS9)
        if candidates.count == 1 { displayUUID = candidates[0].id }
    }

    private func configure(_ value: MonitorCredentials) throws {
        controller = try LANMonitor(value)
        credentials = value; host = value.host; configured = true; connected = false
    }

    private func accept(_ value: MonitorCredentials, save: Bool) async {
        guard !stopped else { return }
        do {
            let candidate = try LANMonitor(value)
            _ = try await candidate.currentInput()
            guard !stopped else { return }
            if save { try CredentialStore.save(value) }
            try configure(value)
            error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func connect() {
        guard !stopped, !pairing, !working else { return }
        let requestedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedHost.isEmpty, !requestedHost.contains("/"), !requestedHost.contains(":") else {
            error = L("Enter the monitor's LAN IPv4 address or hostname."); return
        }
        pairing = true; error = nil
        Task {
            defer { pairing = false }
            do {
                let pin = try await S9Pairing.inspect(host: requestedHost)
                guard !stopped else { return }
                if var existing = credentials {
                    guard existing.certificateSHA256.lowercased() == pin else {
                        error = L("The certificate differs from the paired monitor. Check the address; no token was sent."); return
                    }
                    existing.host = requestedHost
                    await accept(existing, save: true)
                    return
                }
                let alert = NSAlert()
                alert.messageText = L("Pair this monitor?")
                alert.informativeText = LF("%@\nThis adds local control permission. Choose Allow on the monitor.\n\nThe first connection trusts this LAN device’s certificate.", requestedHost)
                alert.addButton(withTitle: L("Pair")); alert.addButton(withTitle: L("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let token = try await S9Pairing.pair(host: requestedHost, certificateSHA256: pin)
                await accept(MonitorCredentials(host: requestedHost, token: token, certificateSHA256: pin), save: true)
            } catch { self.error = error.localizedDescription }
        }
    }

    func refresh() async {
        guard !stopped, let controller, !refreshing, !working, !pairing else { return }
        refreshing = true
        defer { refreshing = false; startPump() }
        do {
            let audioState = try await controller.currentAudioState()
            guard !stopped else { return }
            confirmedVolume = audioState.volume; confirmedMuted = audioState.isMuted; lastAudioRead = Date()
            if pendingVolume == nil { volume = audioState.volume }
            if pendingMuted == nil { muted = audioState.isMuted }
            let backlight = try await controller.currentBacklight()
            guard !stopped else { return }
            confirmedBrightness = backlight; lastBrightnessRead = Date()
            if pendingBrightness == nil { brightness = backlight }
            let source = try await controller.currentInput()
            guard !stopped else { return }
            confirmedInput = source
            if pendingInput == nil { input = source }
            connected = true; error = nil
        } catch { failed(error) }
    }

    func setVolume(_ value: Int) {
        guard !stopped, configured, connected else { return }
        keyboardVolumeSteps.removeAll()
        volume = min(volumeLimit, max(0, value)); pendingVolume = volume; startPump()
    }
    func setBrightness(_ value: Int) {
        guard !stopped, configured, connected else { return }
        keyboardBrightnessSteps.removeAll()
        brightness = min(50, max(0, value)); pendingBrightness = brightness; startPump()
    }
    func toggleMute() {
        guard !stopped, configured, connected else { return }
        keyboardMuteToggles = 0; muteFromKeyboard = false
        muted.toggle(); pendingMuted = muted; startPump()
    }
    func setInput(_ value: S9Input) {
        guard !stopped, configured, connected else { return }
        input = value; pendingInput = value; startPump()
    }

    private func handleKey(_ action: MediaAction, fine: Bool) {
        guard !stopped else { return }
        switch action {
        case .volumeUp, .volumeDown:
            let delta = (action == .volumeUp ? 1 : -1) * (fine ? 1 : volumeStep)
            let next = ControlPolicy.volume(current: volume, delta: delta, limit: volumeLimit)
            // Retain relative intent until a fresh read at the start of a burst.
            keyboardVolumeSteps.append(delta)
            volume = next; pendingVolume = next
            // Match the usual keyboard experience: adjusting volume unmutes.
            if muted { muted = false; pendingMuted = false; muteFromKeyboard = true; keyboardMuteToggles = 0 }
        case .mute:
            muted.toggle(); pendingMuted = muted
            muteFromKeyboard = true; keyboardMuteToggles += 1
        case .brightnessUp, .brightnessDown:
            brightness = ControlPolicy.brightness(current: brightness, direction: action == .brightnessUp ? 1 : -1, fine: fine, step: brightnessStep)
            keyboardBrightnessSteps.append((action == .brightnessUp ? 1 : -1, fine, brightnessStep))
            pendingBrightness = brightness
            onBrightnessFeedback?(brightness)
        }
        startPump()
    }

    private func discardIneligibleKeyboardAudio() {
        guard !volumeKeys || audio.defaultUID != audioUID else { return }
        if !keyboardVolumeSteps.isEmpty {
            pendingVolume = nil; keyboardVolumeSteps.removeAll(); volume = confirmedVolume
        }
        if muteFromKeyboard {
            pendingMuted = nil; keyboardMuteToggles = 0; muteFromKeyboard = false; muted = confirmedMuted
        }
    }

    private func prepareKeyboardAudio(_ controller: any MonitorTransport) async throws {
        discardIneligibleKeyboardAudio()
        guard (!keyboardVolumeSteps.isEmpty || keyboardMuteToggles > 0), Date().timeIntervalSince(lastAudioRead) > 2 else { return }
        let state = try await controller.currentAudioState()
        try Task.checkCancellation()
        confirmedVolume = state.volume; confirmedMuted = state.isMuted; lastAudioRead = Date()
        discardIneligibleKeyboardAudio()
        if !keyboardVolumeSteps.isEmpty {
            let rebased = keyboardVolumeSteps.reduce(state.volume) { ControlPolicy.volume(current: $0, delta: $1, limit: volumeLimit) }
            pendingVolume = rebased; volume = rebased
            if state.isMuted, keyboardMuteToggles == 0 {
                pendingMuted = false; muted = false; muteFromKeyboard = true
            }
        }
        if keyboardMuteToggles > 0 {
            muted = keyboardMuteToggles.isMultiple(of: 2) ? state.isMuted : !state.isMuted
            pendingMuted = muted
        }
    }

    /// Only one network mutation at a time. New slider/key intents replace
    /// pending values; an old readback must never erase a newer user intention.
    private func startPump() {
        guard !stopped, pump == nil, !refreshing, !pairing, let controller,
              pendingInput != nil || pendingVolume != nil || pendingBrightness != nil || pendingMuted != nil else { return }
        working = true
        pump = Task {
            defer { working = false; pump = nil }
            // Coalesce the first burst without accumulating a queue of key repeats.
            try? await Task.sleep(for: .milliseconds(65))
            while !Task.isCancelled {
                do {
                    try await prepareKeyboardAudio(controller)
                    try Task.checkCancellation()
                    if let target = pendingInput {
                        pendingInput = nil
                        let result = try await controller.setInput(target)
                        confirmedInput = result
                        if pendingInput == nil { input = result }
                    } else if let target = pendingVolume {
                        pendingVolume = nil
                        keyboardVolumeSteps.removeAll()
                        let result = try await controller.setVolume(target)
                        confirmedVolume = result.volume; confirmedMuted = result.isMuted; lastAudioRead = Date()
                        if pendingVolume == nil { volume = result.volume }
                        if pendingMuted == nil { muted = result.isMuted }
                    } else if let target = pendingMuted {
                        pendingMuted = nil
                        keyboardMuteToggles = 0; muteFromKeyboard = false
                        let result = try await controller.setMuted(target)
                        confirmedVolume = result.volume; confirmedMuted = result.isMuted; lastAudioRead = Date()
                        if pendingVolume == nil { volume = result.volume }
                        if pendingMuted == nil { muted = result.isMuted }
                    } else if pendingBrightness != nil {
                        if !keyboardBrightnessSteps.isEmpty, !focus.isFocused(displayUUID) {
                            keyboardBrightnessSteps.removeAll(); pendingBrightness = nil; brightness = confirmedBrightness
                            continue
                        }
                        if !keyboardBrightnessSteps.isEmpty, Date().timeIntervalSince(lastBrightnessRead) > 2 {
                            let current = try await controller.currentBacklight()
                            try Task.checkCancellation()
                            confirmedBrightness = current; lastBrightnessRead = Date()
                            if !keyboardBrightnessSteps.isEmpty {
                                pendingBrightness = keyboardBrightnessSteps.reduce(current) {
                                    ControlPolicy.brightness(current: $0, direction: $1.direction, fine: $1.fine, step: $1.step)
                                }
                                brightness = pendingBrightness!
                            }
                        }
                        guard let target = pendingBrightness else { continue }
                        pendingBrightness = nil
                        keyboardBrightnessSteps.removeAll()
                        let result = try await controller.setBacklight(target)
                        confirmedBrightness = result; lastBrightnessRead = Date()
                        if pendingBrightness == nil { brightness = result }
                    } else { break }
                    guard !stopped else { break }
                    connected = true; error = nil
                } catch {
                    pendingInput = nil; pendingVolume = nil; pendingMuted = nil; pendingBrightness = nil
                    keyboardVolumeSteps.removeAll(); keyboardBrightnessSteps.removeAll(); keyboardMuteToggles = 0; muteFromKeyboard = false
                    volume = confirmedVolume; muted = confirmedMuted; brightness = confirmedBrightness; input = confirmedInput
                    failed(error)
                    break
                }
            }
        }
    }

    private func failed(_ failure: Error) {
        guard !stopped else { return }
        connected = false
        error = LF("Connection failed: %@", failure.localizedDescription)
    }

    func updateMediaKeys(requestPermission: Bool = false) {
        guard !stopped else { return }
        focus.enabled = brightnessKeys
        guard volumeKeys || brightnessKeys || inputMediaKeys else { media.stop(); mediaKeysRunning = false; return }
        if requestPermission { media.requestPermission() }
        mediaKeysRunning = media.start()
    }

    func updateLogin(_ enabled: Bool) {
        guard !stopped else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = LF("Login item setup failed: %@", error.localizedDescription) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        polling?.cancel(); pump?.cancel()
        audio.onChange = nil; focus.onDisplaysChanged = nil; onBrightnessFeedback = nil
        media.stop(); audio.stop(); focus.stop()
        pendingInput = nil; pendingVolume = nil; pendingMuted = nil; pendingBrightness = nil
        keyboardVolumeSteps.removeAll(); keyboardBrightnessSteps.removeAll(); keyboardMuteToggles = 0
        connected = false; mediaKeysRunning = false
        credentials = nil; controller = nil
    }

    func shutdownForRemoval() async {
        let writes = pump
        let reads = polling
        stop()
        await writes?.value
        await reads?.value
    }

    func waitForPendingChanges() async { await pump?.value }
}
