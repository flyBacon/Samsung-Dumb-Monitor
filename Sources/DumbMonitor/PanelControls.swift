// SPDX-License-Identifier: MPL-2.0
import AppKit
import S9InputControl
import SwiftUI

// The compact panel uses pointer/media-key controls. Disable keyboard focus on
// these native controls so AppKit cannot move a persistent ring between them.
private final class PanelSlider: NSSlider {
    private(set) var tracking = false
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        defer { tracking = false }
        super.mouseDown(with: event)
    }
}

struct ContinuousPanelSlider: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Int>
        init(_ value: Binding<Int>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = Int(sender.doubleValue.rounded()) }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = PanelSlider()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.focusRingType = .none
        slider.cell?.focusRingType = .none
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        if let trackingSlider = slider as? PanelSlider {
            if !trackingSlider.tracking { slider.doubleValue = Double(value) }
        }
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? 150, height: 22)
    }
}

private final class PanelSegments: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { false }
}

struct InputSelector: NSViewRepresentable {
    let sources: [ConfiguredInput]
    let selection: S9Input?
    let select: (S9Input) -> Void

    @MainActor final class Coordinator: NSObject {
        var select: (S9Input) -> Void
        var sources: [ConfiguredInput] = []
        init(_ select: @escaping (S9Input) -> Void) { self.select = select }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard sources.indices.contains(sender.selectedSegment),
                  let source = sources[sender.selectedSegment].source else { return }
            select(source)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(select) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = PanelSegments()
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.focusRingType = .none
        control.cell?.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel(L("Input source"))
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.select = select
        context.coordinator.sources = sources
        control.segmentCount = sources.count
        for (index, source) in sources.enumerated() { control.setLabel(source.name, forSegment: index) }
        control.selectedSegment = sources.firstIndex(where: { $0.source == selection }) ?? -1
        control.isEnabled = context.environment.isEnabled
    }
}

private final class PanelPopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { false }
}

struct InputMenu: NSViewRepresentable {
    let sources: [ConfiguredInput]
    let selection: S9Input?
    let select: (S9Input) -> Void

    @MainActor final class Coordinator: NSObject {
        var select: (S9Input) -> Void
        init(_ select: @escaping (S9Input) -> Void) { self.select = select }
        @objc func changed(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String,
                  let source = S9Input(rawValue: value) else { return }
            select(source)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(select) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = PanelPopUp(frame: .zero, pullsDown: false)
        control.focusRingType = .none
        control.cell?.focusRingType = .none
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel(L("Input source"))
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        let menu = NSMenu()
        menu.autoenablesItems = false
        for source in sources {
            let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
            item.representedObject = source.value
            menu.addItem(item)
        }
        if let index = sources.firstIndex(where: { $0.source == selection }) {
            control.menu = menu
            control.selectItem(at: index)
        } else {
            // Unknown current inputs remain readable, without pretending that
            // they are one of the user's configured targets.
            let item = NSMenuItem(title: selection?.rawValue ?? L("Input source"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 0)
            control.menu = menu
            control.selectItem(at: 0)
        }
        control.isEnabled = context.environment.isEnabled
    }
}

struct PanelActions: NSViewRepresentable {
    let settings: () -> Void
    let hide: () -> Void

    @MainActor final class Coordinator: NSObject {
        var settings: () -> Void
        var hide: () -> Void
        init(settings: @escaping () -> Void, hide: @escaping () -> Void) {
            self.settings = settings; self.hide = hide
        }
        @objc func showSettings() { settings() }
        @objc func hideIcon() { hide() }
        @objc func quit() { NSApp.terminate(nil) }
        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            for (title, action) in [(L("Settings…"), #selector(showSettings)), (L("Hide Menu Bar Icon"), #selector(hideIcon))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
            let quit = NSMenuItem(title: L("Quit Dumb Monitor"), action: #selector(self.quit), keyEquivalent: "q")
            quit.keyEquivalentModifierMask = .command
            quit.target = self; menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - 3), in: sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(settings: settings, hide: hide) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("More Actions"))
        button.setAccessibilityLabel(L("More Actions"))
        button.toolTip = L("Settings")
        button.target = context.coordinator
        button.action = #selector(Coordinator.open(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.settings = settings; context.coordinator.hide = hide
    }
}
