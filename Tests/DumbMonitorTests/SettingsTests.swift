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
    model.updateMediaKeys()
    model.updateInputConfiguration(.s9)
    for key in ["volumeLimit", "volumeStep", "brightnessStep", "displayUUID", "audioUID",
                "volumeKeys", "brightnessKeys", "inputMediaKeys", "inputSources"] {
        #expect(defaults.object(forKey: key) == nil)
    }
    #expect(!model.media.isRunning)
}
