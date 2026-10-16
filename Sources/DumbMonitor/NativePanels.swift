// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class RoundedPanel: FloatingPanel {
    static let shadowPadding: CGFloat = 24
    var surfaceFrame: NSRect {
        contentView?.layoutSubtreeIfNeeded()
        guard let surface = contentView as? RoundedSurfaceView else { return frame }
        return convertToScreen(surface.surfaceRectInWindow)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Placement constrains the visible surface. The invisible shadow margin
        // may extend into the menu bar; constraining it adds an unwanted gap.
        frameRect
    }
    func setSurfaceSize(_ size: NSSize) {
        setContentSize(NSSize(width: size.width + Self.shadowPadding * 2, height: size.height + Self.shadowPadding * 2))
        contentView?.layoutSubtreeIfNeeded()
    }
}

private final class RoundedSurfaceView: NSView {
    private let materialView = NSVisualEffectView()
    private let surfaceShadow = CALayer()
    private let surfaceMask = CAShapeLayer()
    private let cornerRadius: CGFloat = 12
    var surfaceRectInWindow: NSRect { materialView.convert(materialView.bounds, to: nil) }

    init(content: NSView, size: NSSize, material: NSVisualEffectView.Material) {
        let padding = RoundedPanel.shadowPadding
        super.init(frame: NSRect(x: 0, y: 0, width: size.width + padding * 2, height: size.height + padding * 2))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(surfaceShadow)
        surfaceShadow.shadowColor = NSColor.black.cgColor
        surfaceShadow.shadowOpacity = 0.24
        surfaceShadow.shadowRadius = 9
        surfaceShadow.shadowOffset = CGSize(width: 0, height: -3)
        materialView.material = material
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.mask = surfaceMask
        addSubview(materialView)
        materialView.addSubview(content)
        content.autoresizingMask = [.width, .height]
        layout()
        content.frame = materialView.bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding = RoundedPanel.shadowPadding
        let surface = bounds.insetBy(dx: padding, dy: padding)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        materialView.frame = surface
        surfaceShadow.frame = surface
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: surface.size),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        // Use exactly the same outline for clipping and shadow. WindowServer's
        // system shadow (including global user overrides) is disabled entirely.
        surfaceMask.frame = materialView.bounds
        surfaceMask.path = path
        surfaceShadow.shadowPath = path
        CATransaction.commit()
    }
}

@MainActor
func roundedPanel<Content: View>(root: Content, size: NSSize, material: NSVisualEffectView.Material = .popover) -> RoundedPanel {
    let padding = RoundedPanel.shadowPadding
    let paddedSize = NSSize(width: size.width + padding * 2, height: size.height + padding * 2)
    let panel = RoundedPanel(contentRect: NSRect(origin: .zero, size: paddedSize),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    let host = NSHostingView(rootView: root)
    host.sizingOptions = [.intrinsicContentSize]
    panel.contentView = RoundedSurfaceView(content: host, size: size, material: material)
    return panel
}

struct MuteButton: NSViewRepresentable {
    let muted: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func click() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.click)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let label = muted ? L("Unmute") : L("Mute")
        button.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: label)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.isEnabled = context.environment.isEnabled
    }
}

@MainActor
final class BrightnessHUD {
    private var panel: RoundedPanel?
    private var dismiss: Task<Void, Never>?

    func show(_ value: Int, displayUUID: String) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return DisplayInventory.uuid(number.uint32Value) == displayUUID
        }) else { return }
        dismiss?.cancel()
        panel?.orderOut(nil)
        let content = HStack(spacing: 12) {
            Image(systemName: "sun.max.fill").font(.system(size: 21))
            ProgressView(value: Double(value), total: 50).progressViewStyle(.linear).frame(width: 112)
            Text("\(value)/50").monospacedDigit().font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary).frame(width: 50, alignment: .trailing)
        }.padding(16)
        let next = roundedPanel(root: content, size: NSSize(width: 248, height: 56), material: .hudWindow)
        next.ignoresMouseEvents = true
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        next.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - next.frame.width / 2,
            y: screen.visibleFrame.minY + 72 - RoundedPanel.shadowPadding))
        next.orderFrontRegardless()
        panel = next
        dismiss = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1100)) }
            catch { return }
            self?.panel?.orderOut(nil)
        }
    }
    func stop() { dismiss?.cancel(); panel?.orderOut(nil); panel = nil }
}
