// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@testable import DumbMonitor

@MainActor private final class RecordingEditor: NSTextView {
    var actions: [String] = []
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        actions.append(NSStringFromSelector(action))
        return true
    }
}

@MainActor private func key(_ text: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil, characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
}

@Test @MainActor func textCommandsGoToTheFocusedEditorWithoutUsingTheClipboard() {
    let editor = RecordingEditor(frame: .zero)
    for letter in ["x", "c", "v", "a", "z"] {
        #expect(PanelTextCommands.handle(key(letter, [.command, .capsLock]), firstResponder: editor))
    }
    #expect(PanelTextCommands.handle(key("Z", [.command, .shift]), firstResponder: editor))
    #expect(editor.actions == ["cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:"])
    for flags: NSEvent.ModifierFlags in [[], .control, [.command, .option], [.command, .shift]] {
        #expect(!PanelTextCommands.handle(key("v", flags), firstResponder: editor))
    }
    #expect(!PanelTextCommands.handle(key("q", .command), firstResponder: editor))
    #expect(editor.actions.count == 6)
}

@Test @MainActor func editingFallbackDoesNotStealCommandsFromShortcutRecording() {
    let recorder = RecorderButton(frame: .zero)
    for letter in ["c", "v", "a", "z"] {
        #expect(!PanelTextCommands.handle(key(letter, .command), firstResponder: recorder))
    }
    #expect(!PanelTextCommands.handle(key("v", .command), firstResponder: nil))
}

@Test @MainActor func selectAllEditsTheNativeTextSelectionWithoutActivatingAWindow() {
    let editor = NSTextView(frame: .zero)
    editor.string = "monitor.local"
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(PanelTextCommands.handle(key("a", .command), firstResponder: editor))
    #expect(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count))
}
