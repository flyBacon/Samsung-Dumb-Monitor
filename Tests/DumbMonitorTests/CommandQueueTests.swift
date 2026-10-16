// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl
import Testing
@testable import DumbMonitor

private actor SimulatedMonitor: MonitorTransport {
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
    func fail() { failWrites = true }
    func resume() { release?.resume(); release = nil }
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
    #expect(await transport.writes == ["input:USB-C", "volume:32", "brightness:50"])
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
    controller.media.onInputShortcut(.volumeDown)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["input:HDMI3"])
    #expect(controller.input?.rawValue == "HDMI3")
    configuration.remove(id: hdmi.id)
    controller.updateInputConfiguration(configuration)
    controller.media.onInputShortcut(.volumeDown)
    controller.selectConfiguredInput(id: hdmi.id)
    await controller.waitForPendingChanges()
    #expect(await transport.writes == ["input:HDMI3"])
}
