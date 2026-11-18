// SPDX-License-Identifier: MPL-2.0
import AppKit
@preconcurrency import ApplicationServices

struct MonitorDisplay: Identifiable, Sendable {
    let id: String
    let name: String
    let cgID: CGDirectDisplayID
    let bounds: CGRect
    var isS9: Bool { name.localizedCaseInsensitiveContains("S27C900") }
}

enum DisplayInventory {
    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func isActive(uuid: String) -> Bool {
        online().contains { self.uuid($0) == uuid && CGDisplayIsActive($0) != 0 }
    }
}

private func focusedWindowChanged(_ observer: AXObserver, _ element: AXUIElement,
                                   _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let owner = Unmanaged<DisplayFocusMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { owner.invalidate() }
}

@MainActor
final class DisplayFocusMonitor: ObservableObject {
    @Published private(set) var displays: [MonitorDisplay] = []
    @Published private(set) var focusedUUID: String?
    private(set) var onlineDisplayUUIDs: Set<String> = []
    var onDisplaysChanged: (() -> Void)?
    var enabled = false
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?
    private var observedPID: pid_t = -1
    private var revision = 0

    init(start: Bool = true) {
        guard start else { return }
        reloadDisplays()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidate() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadDisplays(); self?.invalidate() }
        })
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func reloadDisplays() {
        onlineDisplayUUIDs = Set(DisplayInventory.online().map(DisplayInventory.uuid))
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return MonitorDisplay(id: DisplayInventory.uuid(id), name: screen.localizedName, cgID: id, bounds: CGDisplayBounds(id))
        }
        onDisplaysChanged?()
    }

    func isFocused(_ target: String) -> Bool {
        guard !target.isEmpty else { return false }
        if let ownWindow = NSApp?.keyWindow, ownWindow.isKeyWindow, ownWindow.isVisible, let screen = ownWindow.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return DisplayInventory.uuid(number.uint32Value) == target
        }
        return focusedUUID == target
    }

    fileprivate func invalidate() {
        revision += 1
        focusedUUID = nil
        Task { await refresh() }
    }

    private func refresh() async {
        guard enabled, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { focusedUUID = nil; return }
        attach(to: app.processIdentifier)
        let version = revision
        let pid = app.processIdentifier
        let finder = app.bundleIdentifier == "com.apple.finder"
        let window = await Task.detached(priority: .userInitiated) { FocusedWindowReader.bounds(pid: pid, finder: finder) }.value
        guard version == revision, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        focusedUUID = ControlPolicy.screenForFocus(window: window, pointer: pointer,
            screens: displays.map { ($0.id, $0.bounds) })
    }

    private func attach(to pid: pid_t) {
        if observedPID != pid {
            detach()
            observedPID = pid
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.03)
            var observer: AXObserver?
            guard AXObserverCreate(pid, focusedWindowChanged, &observer) == .success, let observer else { return }
            axObserver = observer; observedApp = app
            AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let app = observedApp, let observer = axObserver else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        if let old = observedWindow, CFEqual(old, window) { return }
        if let old = observedWindow {
            for name in [kAXMovedNotification, kAXResizedNotification] { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        observedWindow = window
        AXUIElementSetMessagingTimeout(window, 0.03)
        for name in [kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func detach() {
        if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        axObserver = nil; observedWindow = nil; observedApp = nil; observedPID = -1
    }

    func stop() {
        task?.cancel(); detach()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

private enum FocusedWindowReader {
    static func bounds(pid: pid_t, finder: Bool) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.03)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(window, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.03)
            var position: CFTypeRef?, size: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
               AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
               let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var point = CGPoint.zero, dimensions = CGSize.zero
                if AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                   AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) {
                    return CGRect(origin: point, size: dimensions)
                }
            }
        }
        // Finder can be frontmost because the user clicked a desktop, with no
        // focused window. Do not substitute a folder window on another screen.
        if finder { return nil }
        // Geometry/PID metadata only; no screen images or window-title logging.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let front = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                  && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let bounds = front[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
