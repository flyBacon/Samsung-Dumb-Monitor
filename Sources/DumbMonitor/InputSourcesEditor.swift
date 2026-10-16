// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct InputSourcesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var configuration: InputSourceConfiguration
    let save: (InputSourceConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Input sources")).font(.headline)
            HStack {
                Text(L("Name")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Protocol value")).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($configuration.sources) { $source in
                        HStack {
                            TextField(L("Name"), text: $source.name)
                            TextField(L("Protocol value"), text: $source.value)
                            Button {
                                configuration.remove(id: source.id)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).frame(width: 24)
                                .help(L("Remove input source"))
                                .disabled(configuration.sources.count == 1)
                        }.textFieldStyle(.roundedBorder)
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                Button(L("Add")) {
                    configuration.sources.append(ConfiguredInput(name: "", value: ""))
                }.disabled(configuration.sources.count >= 32)
                Button(L("Reset to S9")) { configuration = .s9 }
                Spacer()
            }
            Text(L("Exact values are case-sensitive, e.g. USB-C, Display Port, HDMI1. The monitor must support local IP control; compatibility is not guaranteed."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = configuration.validationMessage {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { save(configuration); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(configuration.validationMessage != nil)
            }
        }
        .padding(20).frame(width: 430, height: 340)
    }
}
