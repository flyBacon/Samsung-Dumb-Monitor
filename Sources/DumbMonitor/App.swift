// SPDX-License-Identifier: MPL-2.0
import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@main
struct DumbMonitorMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: MonitorModel!
    private var shortcuts: GlobalShortcutManager!
    private var item: NSStatusItem?
    private var controls: RoundedPanel!
    private var settingsWindow: NSPanel?
    private let brightnessHUD = BrightnessHUD()
    private var observers: [NSObjectProtocol] = []
    private var localClickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var windowKeyMonitor: Any?
    private var updates: AnyCancellable?
    private var cleanupInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = MonitorModel()
        shortcuts = GlobalShortcutManager(bindings: model.shortcutBindings) { [weak self] command in
            self?.model.execute(command)
        }
        model.onBrightnessFeedback = { [weak self] value in
            guard let self else { return }
            brightnessHUD.show(value, displayUUID: model.displayUUID)
        }
        controls = roundedPanel(root: ControlsView(model: model,
            settings: { [weak self] in self?.showSettings() }, hide: { [weak self] in self?.hideIcon() }),
            size: NSSize(width: ControlPanelLayout.width, height: 120))
        controls.delegate = self
        installWindowCommands()
        updates = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resizeControls()
                self.shortcuts.configure(bindings: self.model.shortcutBindings)
            }
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !loginLaunch { showIcon() }
        if !model.configured && !loginLaunch { showSettings() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.model.refresh() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.closeControls() } })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !cleanupInProgress else { return false }
        showIcon()
        showControls()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !cleanupInProgress else { return }
        model?.audio.reload()
        model?.updateMediaKeys()
        if let model { model.loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    private func showIcon() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: 28)
        let configuration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        let image = NSImage(systemSymbolName: "ev.plug.dc.nacs", accessibilityDescription: "Dumb Monitor")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        status.button?.image = image
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        status.button?.sendAction(on: [.leftMouseDown])
        status.button?.toolTip = "Dumb Monitor"
        item = status
    }

    private func hideIcon() {
        closeControls()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func togglePanel() {
        if controls.isVisible { closeControls() } else { showControls() }
    }

    private func resizeControls() {
        let height: CGFloat = model.configured ? (model.error == nil ? 120 : 148) : 60
        guard controls.surfaceFrame.height != height else { return }
        let top = controls.frame.maxY
        controls.setSurfaceSize(NSSize(width: ControlPanelLayout.width, height: height))
        controls.setFrameOrigin(NSPoint(x: controls.frame.minX, y: top - controls.frame.height))
    }

    private func showControls() {
        guard !cleanupInProgress else { return }
        guard let button = item?.button, let window = button.window else { return }
        resizeControls()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        let frame = screen?.visibleFrame ?? anchor
        controls.setFrameOrigin(ControlPanelLayout.windowOrigin(window: controls.frame,
            surface: controls.surfaceFrame, anchor: anchor,
            menuBarBottom: window.frame.minY, visibleFrame: frame))
        // A nonactivating panel stays in the current Space and leaves the
        // front application's menu bar intact, including full-screen Spaces.
        controls.makeKeyAndOrderFront(nil)
        controls.makeFirstResponder(nil)
        model.setPanelVisible(true)
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.dismissControlsIfOutside(at: NSEvent.mouseLocation)
                }
                return event
            }
        }
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in self?.dismissControlsIfOutside(at: point) }
            }
        }
    }

    private func dismissControlsIfOutside(at point: NSPoint) {
        // The status item can arrive through the global monitor. Closing on
        // mouse-down and then toggling on mouse-up used to reopen the panel.
        if let button = item?.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        if !controls.surfaceFrame.contains(point) { closeControls() }
    }

    private func installWindowCommands() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Dumb Monitor")
        let quit = NSMenuItem(title: L("Quit Dumb Monitor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        for (title, action, key, modifiers): (String, Selector, String, NSEvent.ModifierFlags) in [
            (L("Undo"), Selector(("undo:")), "z", .command),
            (L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            (L("Cut"), #selector(NSText.cut(_:)), "x", .command),
            (L("Copy"), #selector(NSText.copy(_:)), "c", .command),
            (L("Paste"), #selector(NSText.paste(_:)), "v", .command),
            (L("Select All"), #selector(NSText.selectAll(_:)), "a", .command),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        // Nonactivating panels leave the front application's menus in place.
        // Handle these standard commands locally, only while our UI has focus.
        windowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleWindowCommand(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleWindowCommand(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow, window.isKeyWindow else { return false }
        var owner = window
        while let parent = owner.sheetParent { owner = parent }
        guard owner === controls || owner === settingsWindow else { return false }
        if PanelTextCommands.handle(event, firstResponder: window.firstResponder) { return true }
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q": NSApp.terminate(nil)
        case "w" where window === settingsWindow:
            if !cleanupInProgress { window.performClose(nil) }
        default: return false
        }
        return true
    }

    private func closeControls() {
        controls?.orderOut(nil)
        model?.setPanelVisible(false)
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        localClickMonitor = nil; outsideClickMonitor = nil
    }

    private func showSettings() {
        guard !cleanupInProgress else { return }
        closeControls()
        if settingsWindow == nil {
            let window = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 610),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Dumb Monitor"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model,
                shortcuts: shortcuts, audio: model.audio, focus: model.focus,
                clearLocalData: { [weak self] in self?.confirmLocalDataCleanup() }))
            settingsWindow = window
        }
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main, let window = settingsWindow {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.audio.reload()
        model.focus.reloadDisplays()
        model.updateMediaKeys()
    }

    private func confirmLocalDataCleanup() {
        guard !cleanupInProgress, !model.pairing, let window = settingsWindow else { return }
        cleanupInProgress = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Clear local data and quit?")
        alert.informativeText = L("This turns off launch at login and deletes app settings, caches and the local pairing credentials shared with the CLI. You will need to pair again.\n\nMonitor-side authorization, macOS permissions, firewall rules and separate backups are not removed.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Clear and Quit"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                Task { @MainActor in await self.clearLocalDataAndQuit() }
            } else {
                self.cleanupInProgress = false
            }
        }
    }

    private func clearLocalDataAndQuit() async {
        guard let window = settingsWindow else { cleanupInProgress = false; return }
        NSApp.disableRelaunchOnLogin()
        for existing in NSApp.windows { existing.isRestorable = false }
        // Detach AppStorage bindings before removing their domain, so an old
        // settings view cannot save its values again during the final alert.
        window.contentViewController = NSHostingController(rootView:
            ProgressView(L("Clearing local data…")).frame(maxWidth: .infinity, maxHeight: .infinity))
        let cleanup = LocalDataCleanup.production { [weak self] in
            guard let self else { return }
            self.closeControls()
            self.updates?.cancel()
            self.brightnessHUD.stop()
            self.shortcuts.stop()
            await self.model.shutdownForRemoval()
        }
        let alert = NSAlert()
        do {
            try await cleanup.run()
            alert.messageText = L("Local Data Cleared")
            alert.informativeText = L("You can now drag Dumb Monitor.app to the Trash.\n\nRemove its Accessibility and firewall entries manually if present. Delete any separate CLI copies or credential backups you no longer need.")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = L("Cleanup Incomplete")
            alert.informativeText = LF("Some data may remain. Quit and reopen the app to try again.\n\n%@", error.localizedDescription)
        }
        alert.addButton(withTitle: L("Quit"))
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.cleanupInProgress = false
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanupInProgress ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeControls(); brightnessHUD.stop(); model.stop(); shortcuts.stop()
        if let windowKeyMonitor { NSEvent.removeMonitor(windowKeyMonitor) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
