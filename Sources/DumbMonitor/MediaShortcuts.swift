// SPDX-License-Identifier: MPL-2.0
import AppKit

enum MonitorCommand: Codable, Hashable, Sendable {
    case input(String), powerOn, powerOff

    func title(inputs: [ConfiguredInput]) -> String {
        switch self {
        case .input(let id): inputs.first { $0.id == id }?.name ?? L("None")
        case .powerOn: L("Power On")
        case .powerOff: L("Standby")
        }
    }

    func isValid(inputs: [ConfiguredInput]) -> Bool {
        if case .input(let id) = self { return inputs.contains { $0.id == id && $0.source != nil } }
        return true
    }
}

struct ShortcutBinding: Equatable {
    let command: MonitorCommand
    let name: String
    let shortcut: String
}

enum MediaModifier: String, Codable, CaseIterable, Sendable {
    case control, option, shift, command
    var symbol: String {
        switch self { case .control: "⌃"; case .option: "⌥"; case .shift: "⇧"; case .command: "⌘" }
    }
    var flag: NSEvent.ModifierFlags {
        switch self { case .control: .control; case .option: .option; case .shift: .shift; case .command: .command }
    }
}

extension MediaAction {
    var title: String {
        switch self {
        case .volumeDown: L("Volume Down")
        case .volumeUp: L("Volume Up")
        case .mute: L("Mute")
        case .brightnessDown: L("Brightness Down")
        case .brightnessUp: L("Brightness Up")
        }
    }
}

struct MediaShortcut: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var key: MediaAction
    var modifiers: Set<MediaModifier> = [.command]
    var command: MonitorCommand

    var flags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion($1.flag) }
    }
}

struct MediaShortcutConfiguration: Codable, Equatable, Sendable {
    var bindings: [MediaShortcut]

    static func initial(inputs: InputSourceConfiguration) -> Self {
        Self(bindings: [(MediaAction.volumeDown, inputs.volumeDownID), (.volumeUp, inputs.volumeUpID)]
            .filter { !$0.1.isEmpty }
            .map { MediaShortcut(key: $0.0, command: .input($0.1)) }
            + [MediaShortcut(key: .mute, command: .powerOff)])
    }

    private static func legacy(inputs: InputSourceConfiguration) -> Self {
        Self(bindings: [(MediaAction.volumeDown, inputs.volumeDownID), (.volumeUp, inputs.volumeUpID)]
            .filter { !$0.1.isEmpty }
            .map { MediaShortcut(key: $0.0, modifiers: [.control, .command], command: .input($0.1)) })
    }

    func validationMessage(inputs: [ConfiguredInput]) -> String? {
        guard bindings.count <= 32, Set(bindings.map(\.id)).count == bindings.count else {
            return L("Use up to 32 media shortcuts.")
        }
        guard bindings.allSatisfy({ !$0.modifiers.isEmpty && $0.command.isValid(inputs: inputs) }) else {
            return L("Choose a modifier and a valid action for each shortcut.")
        }
        var seen = Set<String>()
        for binding in bindings {
            guard seen.insert("\(binding.key.rawValue)-\(binding.flags.rawValue)").inserted else {
                return L("Each media key combination must be unique.")
            }
        }
        return nil
    }

    func command(for key: MediaAction, flags: NSEvent.ModifierFlags) -> MonitorCommand? {
        let flags = flags.intersection([.control, .option, .shift, .command])
        guard !flags.isEmpty else { return nil }
        return bindings.first { $0.key == key && $0.flags == flags }?.command
    }

    static func load(from defaults: UserDefaults, inputs: InputSourceConfiguration) -> Self {
        if let stored = defaults.string(forKey: "mediaShortcuts"),
           var value = try? JSONDecoder().decode(Self.self, from: Data(stored.utf8)) {
            value.bindings.removeAll { !$0.command.isValid(inputs: inputs.sources) }
            if value.validationMessage(inputs: inputs.sources) == nil { return value }
        }
        // Existing two-slot installs keep their old chords. Persist the first
        // configuration so enabling the feature later cannot resemble a legacy
        // install and silently change a new user's defaults on the next launch.
        let fallback = defaults.string(forKey: "mediaShortcuts") == nil
            && defaults.object(forKey: "inputMediaKeys") != nil ? legacy(inputs: inputs) : initial(inputs: inputs)
        defaults.set(fallback.storageValue, forKey: "mediaShortcuts")
        return fallback
    }

    var storageValue: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}
