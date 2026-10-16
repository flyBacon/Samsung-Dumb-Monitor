// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl
import Testing
@testable import DumbMonitor

private final class InputDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: String] = [:]
    override func string(forKey key: String) -> String? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value as? String }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@Test func customProtocolValuesRoundTripWithoutChangingExistingJSON() throws {
    for raw in ["USB-C", "Display Port", "HDMI1", "HDMI2", "HDMI3", "Other Input"] {
        let source = try #require(S9Input(rawValue: raw))
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(String.self, from: data) == raw)
        #expect(try JSONDecoder().decode(S9Input.self, from: data) == source)
    }
    for invalid in ["", " HDMI1", "HDMI1 ", "HDMI\n1", String(repeating: "x", count: 129)] {
        #expect(S9Input(rawValue: invalid) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(S9Input.self, from: JSONEncoder().encode(invalid))
        }
    }
    #expect(S9Input.usbC.rawValue == "USB-C" && S9Input.displayPort.rawValue == "Display Port")
}

@Test @MainActor func existingShortcutsMigrateAndCustomSourcesSurviveReload() throws {
    let defaults = InputDefaults()
    let shortcut = GlobalShortcut(keyCode: 64, modifiers: 0, keyLabel: "F17").storageValue
    defaults.values["usbCShortcut"] = shortcut
    var configuration = InputSourceConfiguration.load(from: defaults)
    #expect(configuration.sources[0].shortcut == shortcut)
    #expect(configuration.source(for: .volumeDown)?.source == .displayPort)
    #expect(configuration.source(for: .volumeUp)?.source == .usbC)
    let hdmi = ConfiguredInput(name: "Console", value: "HDMI2")
    configuration.sources.append(hdmi)
    configuration.volumeDownID = hdmi.id
    let model = MonitorModel(defaults: defaults, automaticServices: false)
    defer { model.stop() }
    model.updateInputConfiguration(configuration)
    #expect(defaults.values["usbCShortcut"] == nil)
    #expect(InputSourceConfiguration.load(from: defaults) == configuration)
    configuration.sources.reverse()
    #expect(configuration.source(for: .volumeDown)?.id == hdmi.id)
    configuration.remove(id: hdmi.id)
    #expect(configuration.source(for: .volumeDown) == nil)
    #expect(configuration.validationMessage == nil)
}

@Test func invalidSourceListsCannotReplaceAWorkingConfiguration() {
    var configuration = InputSourceConfiguration.s9
    #expect(configuration.validationMessage == nil)
    configuration.sources.append(ConfiguredInput(name: "Duplicate", value: "USB-C"))
    #expect(configuration.validationMessage != nil)
    configuration = .s9
    configuration.sources[0].value = ""
    #expect(configuration.validationMessage != nil)
    configuration = .s9
    configuration.volumeUpID = "missing-source"
    #expect(configuration.validationMessage != nil)
    configuration = .s9
    configuration.sources.removeAll()
    #expect(configuration.validationMessage != nil)
    configuration = .s9
    configuration.sources[0].name = String(repeating: "x", count: 41)
    #expect(configuration.validationMessage != nil)
}

@Test func corruptSavedSourcesFallBackToS9InsteadOfBreakingStartup() {
    let defaults = InputDefaults()
    defaults.values["inputSources"] = "invalid JSON"
    #expect(InputSourceConfiguration.load(from: defaults) == .s9)
    var invalid = InputSourceConfiguration.s9
    invalid.volumeDownID = "missing"
    defaults.values["inputSources"] = invalid.storageValue
    #expect(InputSourceConfiguration.load(from: defaults) == .s9)
}
