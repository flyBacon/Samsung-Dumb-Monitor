// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import DumbMonitor

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    func clear() { values.removeAll() }
}

@Test @MainActor func newMediaDefaultsStayStableAfterEnablingAndRelaunching() {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    let initial = model.mediaConfiguration
    #expect(initial.command(for: .mute, flags: [.command]) == .powerOff)
    model.inputMediaKeys = true
    let restored = MonitorModel(defaults: defaults, automaticServices: false)
    defer { restored.stop() }
    #expect(restored.mediaConfiguration == initial)
    #expect(restored.mediaConfiguration.command(for: .volumeDown, flags: [.command]) == .input("displayport"))
    #expect(restored.mediaConfiguration.command(for: .volumeUp, flags: [.command]) == .input("usb-c"))
}

@Test @MainActor func changingPublishedVolumeLimitDoesNotRecurseAndPersistsClampedValues() {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    for value in -2...105 {
        model.volumeLimit = value
        #expect(model.volumeLimit == min(100, max(1, value)))
    }
    #expect(defaults.integer(forKey: "volumeLimit") == 100)
    model.volumeLimit = 37
    let reloaded = MonitorModel(defaults: defaults, automaticServices: false)
    defer { reloaded.stop() }
    #expect(reloaded.volumeLimit == 37)
}

@Test @MainActor func configurableStepsRemainPositiveIntegersAndSurviveReload() {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    model.volumeStep = 7; model.brightnessStep = 11
    let reloaded = MonitorModel(defaults: defaults, automaticServices: false)
    defer { reloaded.stop() }
    #expect(reloaded.volumeStep == 7 && reloaded.brightnessStep == 11)
    model.volumeStep = 0; model.brightnessStep = 88
    #expect(model.volumeStep == 1 && model.brightnessStep == 50)
}

@Test @MainActor func stoppedModelCannotRecreateClearedPreferencesOrRestartMediaKeys() async {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    model.volumeStep = 7
    await model.shutdownForRemoval()
    defaults.clear()
    model.volumeLimit = 80; model.volumeStep = 9; model.brightnessStep = 8
    model.displayUUID = "test-display"; model.audioUID = "test-audio"
    model.volumeKeys = true; model.brightnessKeys = true; model.inputMediaKeys = true
    model.wakeBeforeInput = false; model.powerOnShortcut = "discarded"; model.powerOffShortcut = "discarded"
    model.updateMediaKeys()
    model.updateInputConfiguration(.s9)
    for key in ["volumeLimit", "volumeStep", "brightnessStep", "displayUUID", "audioUID",
                "volumeKeys", "brightnessKeys", "inputMediaKeys", "inputSources", "wakeBeforeInput",
                "powerOnShortcut", "powerOffShortcut", "mediaShortcuts"] {
        #expect(defaults.object(forKey: key) == nil)
    }
    #expect(!model.media.isRunning)
}

@Test @MainActor func automaticWakeDefaultsOnButExplicitOffAndPowerShortcutsPersist() {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    #expect(model.wakeBeforeInput)
    model.wakeBeforeInput = false
    model.powerOnShortcut = GlobalShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17").storageValue
    model.powerOffShortcut = GlobalShortcut(keyCode: 79, modifiers: 0, keyLabel: "F18").storageValue
    let restored = MonitorModel(defaults: defaults, automaticServices: false)
    defer { restored.stop() }
    #expect(!restored.wakeBeforeInput)
    #expect(restored.powerOnShortcut == model.powerOnShortcut && restored.powerOffShortcut == model.powerOffShortcut)
    #expect(restored.shortcutBindings.map(\.command).contains(.powerOn))
    #expect(restored.shortcutBindings.map(\.command).contains(.powerOff))
}

@Test @MainActor func oldMediaTargetsMigrateAndCustomMappingsSurviveReloadAndSourceRemoval() {
    let defaults = MemoryDefaults()
    var inputs = InputSourceConfiguration.s9
    inputs.volumeDownID = "usb-c"
    defaults.set(inputs.storageValue, forKey: "inputSources")
    defaults.set(true, forKey: "inputMediaKeys")
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    #expect(model.inputMediaKeys)
    #expect(model.mediaConfiguration.command(for: .volumeDown, flags: [.control, .command]) == .input("usb-c"))
    let configuration = MediaShortcutConfiguration(bindings: [
        MediaShortcut(key: .mute, modifiers: [.option, .shift], command: .powerOff),
        MediaShortcut(key: .brightnessUp, modifiers: [.command], command: .input("usb-c"))
    ])
    model.updateMediaConfiguration(configuration)
    let restored = MonitorModel(defaults: defaults, automaticServices: false)
    defer { restored.stop() }
    #expect(restored.mediaConfiguration == configuration)
    inputs.remove(id: "usb-c")
    restored.updateInputConfiguration(inputs)
    #expect(restored.mediaConfiguration.bindings.count == 1)
    #expect(restored.mediaConfiguration.bindings.first?.command == .powerOff)
    #expect(!restored.media.isRunning)
}

@Test @MainActor func volumeOnOtherInputsDefaultsOffAndPersists() {
    let defaults = MemoryDefaults()
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    #expect(!model.volumeOnOtherInputs)
    model.volumeOnOtherInputs = true
    let restored = MonitorModel(defaults: defaults, automaticServices: false)
    defer { restored.stop() }
    #expect(restored.volumeOnOtherInputs)
}
