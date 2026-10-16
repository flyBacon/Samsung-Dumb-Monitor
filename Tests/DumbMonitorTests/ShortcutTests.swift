// SPDX-License-Identifier: MPL-2.0
import Carbon
import Testing
@testable import DumbMonitor

@Test func standaloneFunctionKeysSurvivePersistenceAndHaveReadableLabels() {
    let keys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
        kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
        kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    for (index, code) in keys.enumerated() {
        let keyCode = UInt32(code)
        #expect(GlobalShortcut.isAllowed(keyCode: keyCode, modifiers: 0))
        let shortcut = GlobalShortcut(keyCode: keyCode, modifiers: 0, keyLabel: "F\(index + 1)")
        let restored = GlobalShortcut(storageValue: shortcut.storageValue)
        #expect(restored == shortcut)
        #expect(restored?.displayName == "F\(index + 1)")
    }
    let modified = GlobalShortcut(keyCode: UInt32(kVK_F17), modifiers: UInt32(shiftKey), keyLabel: "F17")
    #expect(GlobalShortcut(storageValue: modified.storageValue)?.displayName == "⇧F17")
}

@Test func ordinaryTypingStillRequiresACommandModifier() {
    for modifiers: UInt32 in [0, UInt32(shiftKey)] {
        let plainLetter = GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers, keyLabel: "A")
        #expect(!GlobalShortcut.isAllowed(keyCode: plainLetter.keyCode, modifiers: modifiers))
        #expect(GlobalShortcut(storageValue: plainLetter.storageValue) == nil)
    }
    for modifiers in [cmdKey, optionKey, controlKey, cmdKey | shiftKey] {
        let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(modifiers), keyLabel: "A")
        #expect(GlobalShortcut.isAllowed(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
        #expect(GlobalShortcut(storageValue: shortcut.storageValue) == shortcut)
    }
}
