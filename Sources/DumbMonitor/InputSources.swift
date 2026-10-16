// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl

enum MediaInputSlot: Sendable { case volumeDown, volumeUp }

struct ConfiguredInput: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var value: String
    var shortcut = ""
    var source: S9Input? { S9Input(rawValue: value) }
}

struct InputSourceConfiguration: Codable, Equatable, Sendable {
    var sources: [ConfiguredInput]
    var volumeDownID: String
    var volumeUpID: String

    static let s9 = Self(sources: [
        ConfiguredInput(id: "usb-c", name: "USB-C", value: "USB-C"),
        ConfiguredInput(id: "displayport", name: "DisplayPort", value: "Display Port"),
    ], volumeDownID: "displayport", volumeUpID: "usb-c")

    var validationMessage: String? {
        guard (1...32).contains(sources.count) else { return L("Use 1–32 input sources.") }
        guard Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && $0.source != nil }) else {
            return L("Enter a name (up to 40 characters) and an exact protocol value for each source.")
        }
        guard Set(sources.map(\.value)).count == sources.count else { return L("Each protocol value must be unique.") }
        guard [volumeDownID, volumeUpID].allSatisfy({ id in id.isEmpty || sources.contains(where: { $0.id == id }) }) else {
            return L("Choose an existing source for each media shortcut.")
        }
        return nil
    }

    func source(for slot: MediaInputSlot) -> ConfiguredInput? {
        let id = slot == .volumeDown ? volumeDownID : volumeUpID
        return sources.first { $0.id == id }
    }

    mutating func remove(id: String) {
        sources.removeAll { $0.id == id }
        if volumeDownID == id { volumeDownID = "" }
        if volumeUpID == id { volumeUpID = "" }
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let text = defaults.string(forKey: "inputSources"),
           let saved = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
           saved.validationMessage == nil { return saved }
        // Preserve shortcuts from versions with two fixed S9 inputs.
        var initial = Self.s9
        initial.sources[0].shortcut = defaults.string(forKey: "usbCShortcut") ?? ""
        initial.sources[1].shortcut = defaults.string(forKey: "displayPortShortcut") ?? ""
        return initial
    }

    var storageValue: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}
