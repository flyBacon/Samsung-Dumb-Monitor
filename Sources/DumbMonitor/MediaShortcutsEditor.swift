// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct MediaShortcutsEditor: View {
    let configuration: MediaShortcutConfiguration
    @State private var draft: MediaShortcutConfiguration

    init(configuration: MediaShortcutConfiguration, inputs: InputSourceConfiguration,
         save: @escaping (MediaShortcutConfiguration) -> Void) {
        self.configuration = configuration
        self.inputs = inputs
        self.save = save
        _draft = State(initialValue: configuration)
    }
    let inputs: InputSourceConfiguration
    let save: (MediaShortcutConfiguration) -> Void
    private var commands: [MonitorCommand] {
        inputs.sources.map { .input($0.id) } + [.powerOn, .powerOff]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($draft.bindings) { $binding in
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
                            draft.bindings.removeAll { $0.id == id }
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
            HStack {
                MediaEditorButton(title: L("Add")) { _ in add() }
                    .fixedSize().disabled(draft.bindings.count >= 32)
                MediaEditorButton(title: L("Reset")) { _ in draft = .initial(inputs: inputs) }.fixedSize()
                Spacer()
            }
            if let message = draft.validationMessage(inputs: inputs.sources) {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button(L("Revert")) { draft = configuration }
                }
            }
        }
        .focusEffectDisabled()
        .onChange(of: draft) { _, value in
            if value != configuration, value.validationMessage(inputs: inputs.sources) == nil { save(value) }
        }
        .onChange(of: configuration) { _, value in
            if draft != value { draft = value }
        }
    }

    private func add() {
        for mask in [8, 9, 10, 1, 2, 4, 3, 5, 6, 7, 11, 12, 13, 14, 15] {
            let modifiers = Set(MediaModifier.allCases.enumerated().compactMap { index, modifier in
                mask & (1 << index) != 0 ? modifier : nil
            })
            for key in [MediaAction.mute, .volumeDown, .volumeUp, .brightnessDown, .brightnessUp] {
                if !draft.bindings.contains(where: { $0.key == key && $0.modifiers == modifiers }) {
                    draft.bindings.append(MediaShortcut(key: key, modifiers: modifiers, command: .powerOn))
                    return
                }
            }
        }
    }
}
