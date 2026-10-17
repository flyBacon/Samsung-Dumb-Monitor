// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import Testing
@testable import DumbMonitor

@Test func allSupportedMediaKeysAcceptEveryNonemptyModifierCombinationAndPersist() throws {
    for key in MediaAction.allCases {
        for mask in 1...15 {
            let modifiers = Set(MediaModifier.allCases.enumerated().compactMap { index, modifier in
                mask & (1 << index) != 0 ? modifier : nil
            })
            let binding = MediaShortcut(key: key, modifiers: modifiers, command: .powerOff)
            let configuration = MediaShortcutConfiguration(bindings: [binding])
            #expect(configuration.validationMessage(inputs: InputSourceConfiguration.s9.sources) == nil)
            let restored = try JSONDecoder().decode(MediaShortcutConfiguration.self, from: Data(configuration.storageValue.utf8))
            #expect(restored == configuration)
            #expect(restored.command(for: key, flags: binding.flags.union([.capsLock, .function])) == .powerOff)
            #expect(restored.command(for: key, flags: []) == nil)
        }
    }
}

@Test func mediaConfigurationRejectsDuplicateEmptyAndDanglingAssignments() {
    let inputs = InputSourceConfiguration.s9.sources
    let first = MediaShortcut(key: .mute, modifiers: [.option], command: .powerOn)
    let duplicate = MediaShortcut(key: .mute, modifiers: [.option], command: .powerOff)
    #expect(MediaShortcutConfiguration(bindings: [first, duplicate]).validationMessage(inputs: inputs) != nil)
    #expect(MediaShortcutConfiguration(bindings: [MediaShortcut(key: .mute, modifiers: [], command: .powerOff)])
        .validationMessage(inputs: inputs) != nil)
    #expect(MediaShortcutConfiguration(bindings: [MediaShortcut(key: .mute, command: .input("removed"))])
        .validationMessage(inputs: inputs) != nil)
    #expect(MediaShortcutConfiguration(bindings: []).validationMessage(inputs: inputs) == nil)
}

@Test func powerMediaChordFiresOnceAndKeepsKeyUpWhenModifiersChange() {
    for key in [MediaAction.mute, .brightnessUp, .brightnessDown] {
        var routing = MediaKeyRouting()
        let press = routing.route(action: key, down: true, isRepeat: false, eligible: true, command: .powerOff)
        #expect(press.consume && !press.invoke && press.command == .powerOff)
        let repeatPress = routing.route(action: key, down: true, isRepeat: true, eligible: true)
        #expect(repeatPress.consume && !repeatPress.invoke && repeatPress.command == nil)
        #expect(routing.route(action: key, down: false, isRepeat: false, eligible: false).consume)
    }
}

@Test func newDefaultsUseExactCommandVolumeAndMuteChords() {
    let configuration = MediaShortcutConfiguration.initial(inputs: .s9)
    #expect(configuration.bindings.count == 3)
    #expect(configuration.command(for: .volumeDown, flags: [.command]) == .input("displayport"))
    #expect(configuration.command(for: .volumeUp, flags: [.command, .function, .capsLock]) == .input("usb-c"))
    #expect(configuration.command(for: .mute, flags: [.command]) == .powerOff)
    for flags: NSEvent.ModifierFlags in [[], .control, .option, [.shift, .option], [.control, .command], [.command, .shift]] {
        #expect(configuration.command(for: .volumeUp, flags: flags) == nil)
        #expect(configuration.command(for: .volumeDown, flags: flags) == nil)
        #expect(configuration.command(for: .mute, flags: flags) == nil)
    }
    for key: MediaAction in [.brightnessUp, .brightnessDown] {
        #expect(configuration.command(for: key, flags: [.command]) == nil)
    }
}

@Test func inputChordFiresOnceAndDoesNotTurnIntoVolumeWhenModifiersAreReleasedFirst() {
    // Routing accepts a decoded target; the mapping itself is tested above.
    var routing = MediaKeyRouting()
    let down = routing.route(action: .volumeDown, down: true, isRepeat: false, eligible: false, command: .input("usb-c"))
    #expect(down.consume && !down.invoke && down.command == .input("usb-c"))
    let held = routing.route(action: .volumeDown, down: true, isRepeat: true, eligible: false, command: .input("usb-c"))
    #expect(held.consume && !held.invoke && held.command == nil)
    let modifiersReleased = routing.route(action: .volumeDown, down: true, isRepeat: true, eligible: true)
    #expect(modifiersReleased.consume && !modifiersReleased.invoke && modifiersReleased.command == nil)
    let up = routing.route(action: .volumeDown, down: false, isRepeat: false, eligible: true)
    #expect(up.consume && !up.invoke && up.command == nil)
    let normalVolume = routing.route(action: .volumeDown, down: true, isRepeat: false, eligible: true)
    #expect(normalVolume.consume && normalVolume.invoke && normalVolume.command == nil)
}

@Test func heldVolumeCannotBecomeAnInputChordAndUnownedRepeatsAreLeftAlone() {
    var routing = MediaKeyRouting()
    #expect(routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: true).invoke)
    let modifiersAdded = routing.route(action: .volumeUp, down: true, isRepeat: true, eligible: false, command: .input("displayport"))
    #expect(modifiersAdded.consume && !modifiersAdded.invoke && modifiersAdded.command == nil)
    #expect(routing.route(action: .volumeUp, down: false, isRepeat: false, eligible: false).consume)
    #expect(!routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false).consume)
    let lateChord = routing.route(action: .volumeUp, down: true, isRepeat: true, eligible: false, command: .input("displayport"))
    #expect(!lateChord.consume && !lateChord.invoke && lateChord.command == nil)
}

@Test func inputChordReleaseIsConsumedAfterOptionIsTurnedOff() {
    var routing = MediaKeyRouting()
    #expect(routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false, command: .input("displayport")).command == .input("displayport"))
    let duplicateDown = routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false, command: .input("displayport"))
    #expect(duplicateDown.consume && duplicateDown.command == nil)
    let up = routing.route(action: .volumeUp, down: false, isRepeat: false, eligible: false)
    #expect(up.consume && !up.invoke && up.command == nil)
    #expect(!routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false).consume)
}
