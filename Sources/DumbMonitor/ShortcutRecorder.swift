// SPDX-License-Identifier: MPL-2.0
import AppKit
import Carbon
import SwiftUI


struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var value: String
    let onRecordingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onRecordingChanged: onRecordingChanged)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onValueChanged = { context.coordinator.value.wrappedValue = $0 }
        button.onRecordingChanged = context.coordinator.onRecordingChanged
        button.update(storageValue: value)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onRecordingChanged = onRecordingChanged
        button.onValueChanged = { context.coordinator.value.wrappedValue = $0 }
        button.onRecordingChanged = context.coordinator.onRecordingChanged
        button.update(storageValue: value)
    }

    final class Coordinator {
        var value: Binding<String>
        var onRecordingChanged: (Bool) -> Void

        init(value: Binding<String>, onRecordingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onRecordingChanged = onRecordingChanged
        }
    }
}


final class RecorderButton: NSButton {
    var onValueChanged: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var storageValue = ""
    private var isRecordingShortcut = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        font = .systemFont(ofSize: NSFont.systemFontSize)
        target = self
        action = #selector(beginRecording)
        toolTip = L("Use F1–F20 alone, or another key with ⌘, ⌥ or ⌃. Esc cancels; Delete clears.")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func update(storageValue: String) {
        self.storageValue = storageValue
        if !isRecordingShortcut { updateTitle() }
    }

    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecordingShortcut = true
        title = L("Press a shortcut…")
        onRecordingChanged?(true)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else { super.keyDown(with: event); return }
        if event.keyCode == 53 { // Escape cancels recording.
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete clears it.
            storageValue = ""
            onValueChanged?("")
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard GlobalShortcut.isAllowed(keyCode: UInt32(event.keyCode), modifiers: modifiers),
              let label = keyLabel(for: event) else {
            NSSound.beep()
            title = L("F key or ⌘/⌥/⌃ combination")
            return
        }

        let shortcut = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: label
        )
        storageValue = shortcut.storageValue
        onValueChanged?(storageValue)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isRecordingShortcut {
            isRecordingShortcut = false
            updateTitle()
            onRecordingChanged?(false)
        }
        return didResign
    }

    private func updateTitle() {
        title = GlobalShortcut(storageValue: storageValue)?.displayName ?? L("Not set")
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func keyLabel(for event: NSEvent) -> String? {
        if let functionKey = GlobalShortcut.functionKeyLabel(for: UInt32(event.keyCode)) { return functionKey }
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            return characters.uppercased()
        }
    }
}
