// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@testable import DumbMonitor

@Test func onlyExactControlCommandVolumeChordSelectsAnInput() {
    #expect(MediaInputShortcut.action(for: .volumeDown, flags: [.control, .command]) == .volumeDown)
    #expect(MediaInputShortcut.action(for: .volumeUp, flags: [.control, .command, .function, .capsLock]) == .volumeUp)
    for flags: NSEvent.ModifierFlags in [[], .control, .command, [.shift, .option], [.control, .command, .shift]] {
        #expect(MediaInputShortcut.action(for: .volumeUp, flags: flags) == nil)
        #expect(MediaInputShortcut.action(for: .volumeDown, flags: flags) == nil)
    }
    for key: MediaAction in [.mute, .brightnessUp, .brightnessDown] {
        #expect(MediaInputShortcut.action(for: key, flags: [.control, .command]) == nil)
    }
}

@Test func inputChordFiresOnceAndDoesNotTurnIntoVolumeWhenModifiersAreReleasedFirst() {
    // Routing accepts a decoded target; the mapping itself is tested above.
    var routing = MediaKeyRouting()
    let down = routing.route(action: .volumeDown, down: true, isRepeat: false, eligible: false, inputAction: .volumeUp)
    #expect(down.consume && !down.invoke && down.input == .volumeUp)
    let held = routing.route(action: .volumeDown, down: true, isRepeat: true, eligible: false, inputAction: .volumeUp)
    #expect(held.consume && !held.invoke && held.input == nil)
    let modifiersReleased = routing.route(action: .volumeDown, down: true, isRepeat: true, eligible: true)
    #expect(modifiersReleased.consume && !modifiersReleased.invoke && modifiersReleased.input == nil)
    let up = routing.route(action: .volumeDown, down: false, isRepeat: false, eligible: true)
    #expect(up.consume && !up.invoke && up.input == nil)
    let normalVolume = routing.route(action: .volumeDown, down: true, isRepeat: false, eligible: true)
    #expect(normalVolume.consume && normalVolume.invoke && normalVolume.input == nil)
}

@Test func heldVolumeCannotBecomeAnInputChordAndUnownedRepeatsAreLeftAlone() {
    var routing = MediaKeyRouting()
    #expect(routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: true).invoke)
    let modifiersAdded = routing.route(action: .volumeUp, down: true, isRepeat: true, eligible: false, inputAction: .volumeDown)
    #expect(modifiersAdded.consume && !modifiersAdded.invoke && modifiersAdded.input == nil)
    #expect(routing.route(action: .volumeUp, down: false, isRepeat: false, eligible: false).consume)
    #expect(!routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false).consume)
    let lateChord = routing.route(action: .volumeUp, down: true, isRepeat: true, eligible: false, inputAction: .volumeDown)
    #expect(!lateChord.consume && !lateChord.invoke && lateChord.input == nil)
}

@Test func inputChordReleaseIsConsumedAfterOptionIsTurnedOff() {
    var routing = MediaKeyRouting()
    #expect(routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false, inputAction: .volumeDown).input == .volumeDown)
    let duplicateDown = routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false, inputAction: .volumeDown)
    #expect(duplicateDown.consume && duplicateDown.input == nil)
    let up = routing.route(action: .volumeUp, down: false, isRepeat: false, eligible: false)
    #expect(up.consume && !up.invoke && up.input == nil)
    #expect(!routing.route(action: .volumeUp, down: true, isRepeat: false, eligible: false).consume)
}
