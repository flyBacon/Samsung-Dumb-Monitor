// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

// SwiftUI's focusEffectDisabled does not remove every AppKit focus ring.
// These compact editor controls use the same explicit policy as the panel.
struct MediaEditorButton: NSViewRepresentable {
    let title: String
    var selected: Bool? = nil
    var symbol: String? = nil
    var keyEquivalent = ""
    let action: (Bool) -> Void

    @MainActor final class Coordinator: NSObject {
        var action: (Bool) -> Void
        init(_ action: @escaping (Bool) -> Void) { self.action = action }
        @objc func click(_ sender: NSButton) { action(sender.state == .on) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.setButtonType(selected == nil ? .momentaryPushIn : .pushOnPushOff)
        button.focusRingType = .none
        button.cell?.focusRingType = .none
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.state = selected == true ? .on : .off
        button.isBordered = symbol == nil
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = symbol == nil ? .noImage : .imageOnly
        button.keyEquivalent = keyEquivalent
        button.keyEquivalentModifierMask = []
        button.setAccessibilityLabel(title)
        button.toolTip = title
        button.isEnabled = context.environment.isEnabled
    }
}

struct MediaEditorPicker: NSViewRepresentable {
    let titles: [String]
    let selection: Int
    let label: String
    let select: (Int) -> Void

    @MainActor final class Coordinator: NSObject {
        var select: (Int) -> Void
        init(_ select: @escaping (Int) -> Void) { self.select = select }
        @objc func changed(_ sender: NSPopUpButton) { select(sender.indexOfSelectedItem) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(select) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.focusRingType = .none
        button.cell?.focusRingType = .none
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        if button.itemTitles != titles {
            button.removeAllItems()
            // addItems(withTitles:) can collapse duplicate display names. Exact
            // per-item insertion keeps indices aligned with the source IDs.
            for title in titles { button.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        }
        button.selectItem(at: selection)
        button.setAccessibilityLabel(label)
        button.isEnabled = context.environment.isEnabled
    }
}
