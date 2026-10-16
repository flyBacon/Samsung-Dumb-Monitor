// SPDX-License-Identifier: MPL-2.0
import AppKit

enum PanelTextCommands {
    // Nonactivating panels keep the foreground app's menu bar. Dispatch editing
    // to our own field editor, without activating the app or changing Spaces.
    @MainActor static func handle(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard let editor = firstResponder as? NSTextView else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("x", .command): action = #selector(NSText.cut(_:))
        case ("c", .command): action = #selector(NSText.copy(_:))
        case ("v", .command): action = #selector(NSText.paste(_:))
        case ("a", .command): action = #selector(NSText.selectAll(_:))
        case ("z", .command): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: return false
        }
        return editor.tryToPerform(action, with: nil)
    }
}
