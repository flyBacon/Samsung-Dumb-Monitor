// SPDX-License-Identifier: MPL-2.0
import AppKit
import S9InputControl
import SwiftUI

struct ControlsView: View {
    @ObservedObject var model: MonitorModel
    let settings: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if model.configured {
                HStack(spacing: 6) {
                    MuteButton(muted: model.muted, action: model.toggleMute).frame(width: 20, height: 20)
                    ContinuousPanelSlider(value: Binding(get: { model.volume }, set: model.setVolume),
                        range: 0...max(model.volumeLimit, model.volume), label: L("Volume"))
                        .help("\(model.volume) / \(model.volumeLimit)")
                    controlValue(model.volume, maximum: model.volumeLimit)
                }
                .disabled(!model.canAdjust)
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.fill").frame(width: 20).foregroundStyle(.secondary)
                    ContinuousPanelSlider(value: Binding(get: { model.brightness }, set: model.setBrightness),
                        range: 0...50, label: L("Brightness"))
                        .help("\(model.brightness) / 50")
                    controlValue(model.brightness, maximum: 50)
                }
                .disabled(!model.canAdjust)
                HStack(spacing: 6) {
                    Group {
                        if model.inputConfiguration.sources.count <= 2,
                           model.inputConfiguration.sources.map(\.name).joined().count <= 20 {
                            InputSelector(sources: model.inputConfiguration.sources, selection: model.input, select: model.setInput)
                        } else {
                            InputMenu(sources: model.inputConfiguration.sources, selection: model.input, select: model.setInput)
                                .frame(maxWidth: .infinity)
                        }
                    }.disabled(!model.canSendCommand)
                    Spacer(minLength: 2)
                    PowerButton(isOn: model.connected && model.power == .on) {
                        model.setPower(model.connected && model.power == .on ? .off : .on)
                    }.frame(width: 20, height: 22).disabled(!model.canSendCommand)
                    actions
                }
                if let error = model.error {
                    Button { Task { await model.refresh() } } label: {
                        Label(L("Reconnect"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(error)
                }
            } else {
                HStack {
                    Button(L("Connect Monitor…"), action: settings)
                    Spacer()
                    actions
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(width: ControlPanelLayout.width)
        .focusEffectDisabled()
    }

    private func controlValue(_ value: Int, maximum: Int) -> some View {
        // Reserve only the required digits, keeping the slider still as its
        // value changes. Leading alignment keeps the number close to the bar.
        Text("\(max(value, maximum))/\(maximum)").hidden()
            .overlay(alignment: .leading) { Text("\(value)/\(maximum)") }
            .font(.system(size: 14, weight: .medium)).monospacedDigit()
            .foregroundStyle(.primary).fixedSize().accessibilityHidden(true)
    }

    private var actions: some View {
        PanelActions(settings: settings, hide: hide).frame(width: 20, height: 22)
    }
}

struct SettingsView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var shortcuts: GlobalShortcutManager
    @ObservedObject var audio: AudioOutputMonitor
    @ObservedObject var focus: DisplayFocusMonitor
    let clearLocalData: () -> Void
    @State private var editingInputs = false

    var body: some View {
        Form {
            if !model.accessibilityGranted {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(L("Media keys need Accessibility access.")).font(.headline)
                        Spacer()
                        Button(L("Allow Accessibility…")) {
                            model.media.requestPermission()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                HStack {
                    TextField(L("Monitor address"), text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(model.connect)
                    Button(model.configured ? L("Update") : L("Connect"), action: model.connect)
                        .disabled(model.pairing || model.working)
                }
                if model.pairing {
                    HStack { ProgressView().controlSize(.small); Text(L("Connecting. Check the monitor for an approval prompt…")).font(.caption) }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section {
                Toggle(L("Launch at login (hidden icon)"), isOn: Binding(get: { model.loginEnabled }, set: model.updateLogin))
                integerRow(L("Volume limit"), value: $model.volumeLimit, range: 1...100)
            }
            Section(L("Keyboard")) {
                Toggle(L("Volume keys"), isOn: $model.volumeKeys)
                integerRow(L("Volume step"), value: $model.volumeStep, range: 1...100)
                Picker(L("Monitor audio output"), selection: $model.audioUID) {
                    Text(L("Choose…")).tag("")
                    ForEach(audio.outputs) { Text($0.name).tag($0.id) }
                    if !model.audioUID.isEmpty, !audio.outputs.contains(where: { $0.id == model.audioUID }) {
                        Text(L("Monitor (disconnected)")).tag(model.audioUID)
                    }
                }
                .disabled(!model.volumeKeys)
                Toggle(L("Control monitor volume on non-USB-C inputs"), isOn: $model.volumeOnOtherInputs)
                    .disabled(!model.volumeKeys)
                Toggle(L("Brightness keys"), isOn: $model.brightnessKeys)
                integerRow(L("Brightness step"), value: $model.brightnessStep, range: 1...50)
                Picker(L("Monitor display"), selection: $model.displayUUID) {
                    Text(L("Choose…")).tag("")
                    ForEach(focus.displays) { Text($0.name).tag($0.id) }
                    if !model.displayUUID.isEmpty, !focus.displays.contains(where: { $0.id == model.displayUUID }) {
                        Text(L("Monitor (disconnected)")).tag(model.displayUUID)
                    }
                }
                Text(L("⇧⌥ adjusts by 1. Brightness follows the active display."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Input sources")) {
                Toggle(L("Power on before switching input"), isOn: $model.wakeBeforeInput)
                ForEach(model.inputConfiguration.sources) { source in
                    shortcutRow(source.name, value: Binding(get: {
                        model.inputConfiguration.sources.first(where: { $0.id == source.id })?.shortcut ?? ""
                    }, set: { shortcut in
                        var configuration = model.inputConfiguration
                        guard let index = configuration.sources.firstIndex(where: { $0.id == source.id }) else { return }
                        configuration.sources[index].shortcut = shortcut
                        model.updateInputConfiguration(configuration)
                    }))
                }
                Button(L("Edit Input Sources…")) { editingInputs = true }
            }
            Section(L("Power")) {
                shortcutRow(L("Power On"), value: $model.powerOnShortcut)
                shortcutRow(L("Standby"), value: $model.powerOffShortcut)
            }
            Section(L("Media shortcuts")) {
                Toggle(L("Enable media shortcuts"), isOn: $model.inputMediaKeys)
                MediaShortcutsEditor(configuration: model.mediaConfiguration, inputs: model.inputConfiguration,
                                     save: model.updateMediaConfiguration)
                    .id(model.inputConfiguration.sources.map(\.id))
                if let message = shortcuts.registrationMessage { Text(message).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Button(L("Clear Local Data and Quit…"), role: .destructive, action: clearLocalData)
                    .disabled(model.pairing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 610)
        .sheet(isPresented: $editingInputs) {
            InputSourcesEditor(configuration: model.inputConfiguration) {
                model.updateInputConfiguration($0)
            }
        }
        .onAppear { model.updateMediaKeys() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.updateMediaKeys()
        }
    }

    private func integerRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 50)
            Stepper("", value: value, in: range).labelsHidden().fixedSize()
        }
    }

    private func shortcutRow(_ title: String, value: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorderField(value: value, onRecordingChanged: { recording in
                model.recordingShortcut = recording
                shortcuts.setRecording(recording)
            })
                .frame(width: 155, height: 25)
        }
    }

}
