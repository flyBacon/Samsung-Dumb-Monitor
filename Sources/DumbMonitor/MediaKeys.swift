// SPDX-License-Identifier: MPL-2.0
import AppKit
@preconcurrency import ApplicationServices

private func mediaKeyCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                              _ event: CGEvent, _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue()
    let key = DecodedMediaKey(event: event)
    // The tap source is attached exclusively to CFRunLoopGetMain(). Return a
    // Sendable decision across assumeIsolated, never a CGEvent reference.
    let consume = MainActor.assumeIsolated {
        owner.handle(type: type, key: key)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}

private struct DecodedMediaKey: Sendable {
    let action: MediaAction
    let down: Bool
    let repeated: Bool
    let fine: Bool
    let allowedModifiers: Bool
    let inputAction: MediaInputSlot?

    init?(event: CGEvent) {
        guard let native = NSEvent(cgEvent: event), native.type == .systemDefined,
              native.subtype.rawValue == 8,
              let action = MediaAction(rawValue: (native.data1 >> 16) & 0xFFFF) else { return nil }
        let flags = native.modifierFlags.intersection([.shift, .option, .command, .control])
        self.action = action
        down = ((native.data1 >> 8) & 0xFF) == 0xA
        repeated = native.data1 & 1 != 0
        fine = flags == [.shift, .option]
        allowedModifiers = flags.isEmpty || fine
        inputAction = MediaInputShortcut.action(for: action, flags: flags)
    }
}

enum MediaInputShortcut {
    static func action(for action: MediaAction, flags: NSEvent.ModifierFlags) -> MediaInputSlot? {
        let modifiers = flags.intersection([.shift, .option, .command, .control])
        guard modifiers == [.control, .command] else { return nil }
        switch action {
        case .volumeDown: return .volumeDown
        case .volumeUp: return .volumeUp
        default: return nil
        }
    }
}

@MainActor
final class MediaKeys {
    var canHandle: (MediaAction) -> Bool = { _ in false }
    var onKey: (MediaAction, Bool) -> Void = { _, _ in }
    var canHandleInputShortcut: (MediaInputSlot) -> Bool = { _ in false }
    var onInputShortcut: (MediaInputSlot) -> Void = { _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var routing = MediaKeyRouting()

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if isRunning { return true }
        stop()
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; routing = MediaKeyRouting()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    fileprivate func handle(type: CGEventType, key: DecodedMediaKey?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let key else { return false }
        let decision = routing.route(action: key.action, down: key.down, isRepeat: key.repeated,
            eligible: key.allowedModifiers && canHandle(key.action),
            inputAction: key.inputAction.flatMap { canHandleInputShortcut($0) ? $0 : nil })
        if let input = decision.input { onInputShortcut(input) }
        if decision.invoke { onKey(key.action, key.fine) }
        return decision.consume
    }
}
