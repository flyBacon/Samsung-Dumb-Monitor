// SPDX-License-Identifier: MPL-2.0
import Carbon
import Foundation


struct GlobalShortcut: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    // Virtual key codes come from HIToolbox/Events.h. Function keys are
    // non-text keys and can be registered without a command modifier.
    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
        kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
        kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    static func functionKeyLabel(for keyCode: UInt32) -> String? {
        guard let index = functionKeys.firstIndex(where: { UInt32($0) == keyCode }) else { return nil }
        return "F\(index + 1)"
    }

    static func isAllowed(keyCode: UInt32, modifiers: UInt32) -> Bool {
        functionKeyLabel(for: keyCode) != nil || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.functionKeyLabel(for: keyCode) ?? keyLabel)
    }

    var storageValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(storageValue: String) {
        guard !storageValue.isEmpty,
              let data = storageValue.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              Self.isAllowed(keyCode: value.keyCode, modifiers: value.modifiers),
              !value.keyLabel.isEmpty else {
            return nil
        }
        self = value
    }
}


private let dumbMonitorHotKeySignature: OSType = 0x444D4F4E // DMON


private func dumbMonitorHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == dumbMonitorHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let identifier = hotKeyID.id
    Task { @MainActor in
        GlobalShortcutManager.shared?.invoke(identifier)
    }
    return noErr
}


@MainActor
final class GlobalShortcutManager: ObservableObject {
    fileprivate static weak var shared: GlobalShortcutManager?

    @Published private(set) var registrationMessage: String?

    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [EventHotKeyRef] = []
    private let actionHandler: (String) -> Void
    private var sources: [ConfiguredInput]
    private var targets: [UInt32: String] = [:]
    private var nextIdentifier: UInt32 = 1
    private var isRecording = false
    private var stopped = false

    init(sources: [ConfiguredInput], actionHandler: @escaping (String) -> Void) {
        self.sources = sources
        self.actionHandler = actionHandler
        Self.shared = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            dumbMonitorHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status == noErr {
            reload()
        } else {
            registrationMessage = LF("Cannot enable global shortcuts (error %d).", status)
        }
    }

    func setRecording(_ recording: Bool) {
        guard !stopped else { return }
        isRecording = recording
        if recording {
            unregisterAll()
            registrationMessage = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reload()
            }
        }
    }

    func reload() {
        guard !stopped, !isRecording else { return }
        unregisterAll()

        var seen: [String: String] = [:]
        var errors: [String] = []

        for source in sources {
            let stored = source.shortcut
            guard !stored.isEmpty else { continue }
            guard let shortcut = GlobalShortcut(storageValue: stored) else {
                errors.append(LF("Invalid shortcut for %@", source.name))
                continue
            }
            let identity = "\(shortcut.keyCode)-\(shortcut.modifiers)"
            if let existing = seen[identity] {
                errors.append(LF("%@ and %@ use the same shortcut", source.name, existing))
                continue
            }
            seen[identity] = source.name

            let identifier = nextIdentifier
            nextIdentifier &+= 1

            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(
                    signature: dumbMonitorHotKeySignature,
                    id: identifier
                ),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registeredHotKeys.append(reference)
                targets[identifier] = source.id
            } else {
                errors.append(LF("Cannot register %@ shortcut (error %d)", source.name, status))
            }
        }

        registrationMessage = errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    func configure(sources: [ConfiguredInput]) {
        guard !stopped, sources != self.sources else { return }
        self.sources = sources
        reload()
    }

    fileprivate func invoke(_ identifier: UInt32) {
        guard !stopped, let target = targets[identifier] else { return }
        actionHandler(target)
    }

    func stop() {
        stopped = true
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func unregisterAll() {
        for reference in registeredHotKeys { UnregisterEventHotKey(reference) }
        registeredHotKeys.removeAll()
        targets.removeAll()
    }
}
