// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl
import Testing
@testable import DumbMonitor

private actor SimulatedMonitor: MonitorTransport {
    var power: S9PowerState = .on
    var powerReads = 0
    var holdNextPower = false
    var rejectWake = false
    var failReads = false
    var volume = 20
    var muted = false
    var brightness = 50
    var input: S9Input = .usbC
    var writes: [String] = []
    var activeWrites = 0
    var maximumConcurrentWrites = 0
    var failWrites = false
    var holdNextVolume = false
    var release: CheckedContinuation<Void, Never>?

    func currentPower() throws -> S9PowerState {
        powerReads += 1
        if failReads { throw URLError(.cannotConnectToHost) }
        return power
    }
    func setPower(_ value: S9PowerState) async throws -> S9PowerState {
        try begin("power:\(value.rawValue)"); defer { activeWrites -= 1 }
        if rejectWake && value == .on { throw URLError(.cannotConnectToHost) }
        if holdNextPower {
            holdNextPower = false
            await withCheckedContinuation { release = $0 }
        }
        power = value; failReads = false
        return value
    }
    func currentInput() -> S9Input { input }
    func currentAudioState() -> MonitorAudio { MonitorAudio(volume: volume, isMuted: muted) }
    func currentBacklight() -> Int { brightness }
    func setInput(_ value: S9Input) throws -> S9Input {
        try begin("input:\(value.rawValue)"); defer { activeWrites -= 1 }
        input = value; return value
    }
    func setVolume(_ value: Int) async throws -> MonitorAudio {
        try begin("volume:\(value)"); defer { activeWrites -= 1 }
        if holdNextVolume {
            holdNextVolume = false
            await withCheckedContinuation { release = $0 }
        }
        volume = value
        return currentAudioState()
    }
    func setMuted(_ value: Bool) throws -> MonitorAudio {
        try begin("mute:\(value)"); defer { activeWrites -= 1 }
        muted = value; return currentAudioState()
    }
    func setBacklight(_ value: Int) throws -> Int {
        try begin("brightness:\(value)"); defer { activeWrites -= 1 }
        brightness = value; return value
    }
    private func begin(_ value: String) throws {
        writes.append(value)
        if failWrites { throw URLError(.cannotConnectToHost) }
        activeWrites += 1
        maximumConcurrentWrites = max(activeWrites, maximumConcurrentWrites)
    }
    func hold() { holdNextVolume = true }
    func holdWake() { holdNextPower = true }
    func rejectPowerOn() { rejectWake = true }
    func offline() { failReads = true }
    func standby() { power = .off }
    func fail() { failWrites = true }
    func resume() { release?.resume(); release = nil }
}

@Test @MainActor func wakeBeforeInputIsOneAcknowledgementThenSourceWithoutExtraPowerReads() async {
    let transport = SimulatedMonitor()
    await transport.standby()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    #expect(controller.power == .off && controller.connected && !controller.canAdjust)
    #expect(controller.wakeBeforeInput)
    controller.setInput(.displayPort)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "input:Display Port"])
    #expect(await transport.powerReads == 1)
    #expect(controller.power == .on && controller.input == .displayPort)
}

@Test @MainActor func disablingAutomaticWakeKeepsTheOriginalSingleSourceRequest() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    controller.wakeBeforeInput = false
    controller.setInput(.displayPort)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["input:Display Port"])
}

@Test @MainActor func failedWakeDoesNotSendInputOrRetryOrDrainOtherChanges() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    await transport.rejectPowerOn()
    controller.setInput(.displayPort)
    controller.setVolume(22)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn"])
    #expect(controller.error != nil && !controller.connected)
    #expect(controller.input == .usbC && controller.volume == 20)
}

@Test @MainActor func standbySupersedesQueuedInputAndSliderChanges() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    controller.setVolume(25)
    controller.setBrightness(10)
    controller.setInput(.displayPort)
    controller.setPower(.off)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOff"])
    #expect(controller.power == .off && controller.volume == 20 && controller.input == .usbC)
}

@Test @MainActor func standbyDuringAnInFlightWakePreventsTheOldSourceFromBeingSent() async throws {
    let transport = SimulatedMonitor()
    await transport.holdWake()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    controller.setInput(.displayPort)
    for _ in 0..<200 {
        if await transport.release != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await transport.release != nil)
    controller.setPower(.off)
    await transport.resume()
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "power:powerOff"])
    #expect(await transport.maximumConcurrentWrites == 1)
    #expect(controller.power == .off)
}

@Test @MainActor func wakeAndInputRemainAvailableAfterAnOfflineRead() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await transport.offline()
    await controller.refresh()
    #expect(!controller.connected && controller.canSendCommand)
    controller.execute(.powerOn)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn"])
    controller.execute(.powerOff)
    await controller.waitForPendingChanges()
    controller.execute(.input("usb-c"))
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "power:powerOff", "power:powerOn", "input:USB-C"])
}

@MainActor
private func model(_ transport: SimulatedMonitor) -> MonitorModel {
    MonitorModel(transport: transport,
        defaults: UserDefaults(suiteName: "local.dumb-monitor.tests.\(UUID().uuidString)")!, automaticServices: false)
}

@Test @MainActor func aBurstSendsOnlyFinalTargetsAndKeepsSourcePriority() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    for volume in 21...32 { controller.setVolume(volume) }
    controller.setBrightness(10)
    controller.setBrightness(25)
    controller.setBrightness(50)
    controller.setInput(.displayPort)
    controller.setInput(.usbC)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "input:USB-C", "volume:32", "brightness:50"])
    #expect(await transport.maximumConcurrentWrites == 1)
    #expect(controller.volume == 32 && controller.brightness == 50 && controller.connected)
}

@Test @MainActor func lateReadbackCannotEraseNewSliderIntent() async throws {
    let transport = SimulatedMonitor()
    await transport.hold()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    controller.setVolume(22)
    for _ in 0..<200 {
        if await transport.release != nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await transport.release != nil)
    controller.setVolume(26)
    controller.setVolume(28)
    await transport.resume()
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["volume:22", "volume:28"])
    #expect(await transport.maximumConcurrentWrites == 1)
    #expect(controller.volume == 28)
}

@Test @MainActor func aFailedCommandIsNotRetriedOrFollowedByStaleWrites() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    await transport.fail()
    controller.setVolume(22)
    controller.setBrightness(10)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["volume:22"])
    #expect(!controller.connected && controller.error != nil)
    #expect(controller.volume == 20 && controller.brightness == 50)
    controller.setVolume(24)
    await controller.waitForPendingChanges()
    #expect(await transport.writes.count == 1)
}

@Test @MainActor func cleanupShutdownDropsQueuedCommandsAndRejectsLaterControls() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    await controller.refresh()
    controller.setVolume(22)
    controller.setInput(.displayPort)
    await controller.shutdownForRemoval()
    controller.setInput(.usbC)
    controller.setBrightness(10)
    controller.toggleMute()
    await controller.refresh()
    await controller.waitForPendingChanges()
    #expect(await transport.writes.isEmpty)
    #expect(!controller.connected && !controller.mediaKeysRunning)
}

@Test @MainActor func customInputAndMediaTargetsUseExactValuesWithoutGuessing() async throws {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    await controller.refresh()
    let hdmi = ConfiguredInput(name: "Console", value: "HDMI3")
    var configuration = InputSourceConfiguration.s9
    configuration.sources.append(hdmi)
    configuration.volumeDownID = hdmi.id
    controller.updateInputConfiguration(configuration)
    var media = controller.mediaConfiguration
    media.bindings[0].command = .input(hdmi.id)
    controller.updateMediaConfiguration(media)
    controller.inputMediaKeys = true
    let command = try #require(controller.media.shortcutCommand(.volumeDown, [.command]))
    controller.media.onCommand(command)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "input:HDMI3"])
    #expect(controller.input?.rawValue == "HDMI3")
    configuration.remove(id: hdmi.id)
    controller.updateInputConfiguration(configuration)
    #expect(controller.media.shortcutCommand(.volumeDown, [.command]) == nil)
    controller.selectConfiguredInput(id: hdmi.id)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["power:powerOn", "input:HDMI3"])
}

@Test @MainActor func volumeOverrideRequiresAConnectedDisplayAndConfirmedNonUSBInput() async {
    let transport = SimulatedMonitor()
    let controller = model(transport)
    defer { controller.stop() }
    controller.volumeKeys = true
    controller.audioUID = "monitor-audio"
    controller.displayUUID = "monitor-display"
    func routes(_ output: String = "headphones", displays: Set<String> = ["monitor-display"]) -> Bool {
        controller.routesVolumeKeys(defaultOutput: output, onlineDisplays: displays)
    }
    await controller.refresh()
    #expect(routes("monitor-audio"))
    #expect(!routes())
    controller.volumeOnOtherInputs = true
    #expect(!routes())
    controller.setInput(.displayPort)
    #expect(!routes())
    await controller.waitForPendingChanges()
    #expect(routes())
    #expect(!routes(displays: ["another-display"]))
    controller.volumeOnOtherInputs = false
    #expect(!routes())
    controller.volumeOnOtherInputs = true
    controller.volumeKeys = false
    #expect(!routes())
    controller.volumeKeys = true
    controller.setInput(.usbC)
    #expect(!routes())
    await controller.waitForPendingChanges()
    #expect(!routes())
}
