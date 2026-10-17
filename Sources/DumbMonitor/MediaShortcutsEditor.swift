// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct MediaShortcutsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var configuration: MediaShortcutConfiguration
    let inputs: InputSourceConfiguration
    let save: (MediaShortcutConfiguration) -> Void
    private var commands: [MonitorCommand] {
        inputs.sources.map { .input($0.id) } + [.powerOn, .powerOff]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Media shortcuts")).font(.headline)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach($configuration.bindings) { $binding in
                        VStack(spacing: 8) {
                            HStack(spacing: 4) {
                                ForEach(MediaModifier.allCases, id: \.self) { modifier in
                                    MediaEditorButton(title: modifier.symbol, selected: binding.modifiers.contains(modifier)) { enabled in
                                        if enabled { binding.modifiers.insert(modifier) }
                                        else { binding.modifiers.remove(modifier) }
                                    }.frame(width: 30, height: 24).help(modifier.rawValue.capitalized)
                                }
                                MediaEditorPicker(titles: MediaAction.allCases.map(\.title),
                                    selection: MediaAction.allCases.firstIndex(of: binding.key) ?? -1, label: L("Key")) { index in
                                    guard MediaAction.allCases.indices.contains(index) else { return }
                                    binding.key = MediaAction.allCases[index]
                                }
                                MediaEditorButton(title: L("Remove shortcut"), symbol: "minus.circle") { _ in
                                    let id = binding.id
                                    configuration.bindings.removeAll { $0.id == id }
                                }.frame(width: 20, height: 24)
                            }
                            HStack {
                                Text(L("Action"))
                                MediaEditorPicker(titles: commands.map { $0.title(inputs: inputs.sources) },
                                    selection: commands.firstIndex(of: binding.command) ?? -1, label: L("Action")) { index in
                                    guard commands.indices.contains(index) else { return }
                                    binding.command = commands[index]
                                }
                            }
                        }
                    }
                }.padding(2)
            }
            HStack {
                MediaEditorButton(title: L("Add")) { _ in add() }
                    .fixedSize().disabled(configuration.bindings.count >= 32)
                MediaEditorButton(title: L("Reset")) { _ in configuration = .initial(inputs: inputs) }.fixedSize()
                Spacer()
            }
            Text(L("Choose at least one modifier. Unassigned combinations keep their normal behavior. Lock-screen availability depends on macOS and the keyboard."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = configuration.validationMessage(inputs: inputs.sources) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                MediaEditorButton(title: L("Cancel"), keyEquivalent: "\u{1b}") { _ in dismiss() }.fixedSize()
                MediaEditorButton(title: L("Save"), keyEquivalent: "\r") { _ in save(configuration); dismiss() }
                    .fixedSize()
                    .disabled(configuration.validationMessage(inputs: inputs.sources) != nil)
            }
        }.padding(20).frame(width: 430, height: 420).focusEffectDisabled()
    }

    private func add() {
        for mask in [8, 9, 10, 1, 2, 4, 3, 5, 6, 7, 11, 12, 13, 14, 15] {
            let modifiers = Set(MediaModifier.allCases.enumerated().compactMap { index, modifier in
                mask & (1 << index) != 0 ? modifier : nil
            })
            for key in [MediaAction.mute, .volumeDown, .volumeUp, .brightnessDown, .brightnessUp] {
                if !configuration.bindings.contains(where: { $0.key == key && $0.modifiers == modifiers }) {
                    configuration.bindings.append(MediaShortcut(key: key, modifiers: modifiers, command: .powerOn))
                    return
                }
            }
        }
    }
}
