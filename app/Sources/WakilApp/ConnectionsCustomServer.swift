import SwiftUI
import WakilKit

/// One secret entry a custom server is given: an environment variable (stdio) or a header (http).
private struct SecretEntryDraft: Identifiable {
    let id = UUID()
    var header = false
    var name = ""
    var value = ""
    var key: String { (header ? "header:" : "env:") + name.trimmingCharacters(in: .whitespaces) }
}

/// **Custom server**: a name, the transport, the command and its arguments or the address, and the
/// secrets it is given. Values are stored in the Keychain as `env:`/`header:` keys.
struct CustomServerForm: View {
    let org: String
    let actions: ConnectionActions
    let done: (ConnectionsPage) -> Void
    @State private var name = ""
    @State private var http = false
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var entries: [SecretEntryDraft] = []
    @State private var saving = false
    @State private var refusal: String?
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConnectionPageHeader(title: "Custom server", identifier: "settings.org.connections.custom") { done(.add) }
            LabelledField(label: "NAME", prompt: "wiki", text: $name, width: 200,
                          identifier: "settings.org.connections.custom.name", focus: $focus, focusKey: "name")
            HStack(spacing: 6) {
                FormButton(title: "Local command (stdio)", tone: http ? SettingsPalette.coolWhite.opacity(0.6) : SettingsPalette.accent,
                           filled: !http, identifier: "settings.org.connections.custom.stdio") { http = false }
                FormButton(title: "Address (http)", tone: http ? SettingsPalette.accent : SettingsPalette.coolWhite.opacity(0.6),
                           filled: http, identifier: "settings.org.connections.custom.http") { http = true }
            }
            if http {
                LabelledField(label: "ADDRESS", prompt: "https://mcp.initech.test/mcp", text: $url, width: 456,
                              identifier: "settings.org.connections.custom.url", narrows: true)
            } else {
                LabelledField(label: "COMMAND", prompt: "npx", text: $command, width: 456,
                              identifier: "settings.org.connections.custom.command", narrows: true)
                LabelledField(label: "ARGUMENTS", prompt: "-y @initech/wiki-mcp", text: $args, width: 456,
                              identifier: "settings.org.connections.custom.args", narrows: true)
            }
            ForEach($entries) { $entry in
                HStack(spacing: 8) {
                    FormButton(title: entry.header ? "Header" : "Environment variable", tone: SettingsPalette.coolWhite,
                               identifier: "settings.org.connections.custom.entry.kind") { entry.header.toggle() }
                    TextField(entry.header ? "X-Api-Key" : "API_TOKEN", text: $entry.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .fieldBox(width: 150)
                        .accessibilityIdentifier("settings.org.connections.custom.entry.name")
                        // Rule 3: an entry just appended takes the keyboard on its name.
                        .focused($focus, equals: entry.id.uuidString)
                        .onAppear { focus = entry.id.uuidString }
                    SecureField("value", text: $entry.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .fieldBox(maxWidth: 200)
                        .accessibilityIdentifier("settings.org.connections.custom.entry.value")
                    Button { entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.5))
                        .accessibilityLabel("Remove entry")
                }
            }
            FormButton(title: http ? "+ header" : "+ environment variable", tone: SettingsPalette.accent,
                       identifier: "settings.org.connections.custom.entry.add") {
                entries.append(SecretEntryDraft(header: http))
            }
            HStack(spacing: 10) {
                FormButton(title: "Add", tone: SettingsPalette.coolWhite.opacity(ready ? 0.9 : 0.35), filled: true,
                           identifier: "settings.org.connections.custom.save") { save() }
                    .disabled(!ready)
                if saving { ProgressView().controlSize(.small) }
            }
            if let refusal { SheetMessage(text: refusal, identifier: "settings.org.connections.custom.error") }
        }
        .onAppear { focus = "name" }
    }

    private var ready: Bool { !saving && !(http ? url : command).trimmingCharacters(in: .whitespaces).isEmpty }

    private func save() {
        guard ready else { return }
        saving = true
        refusal = nil
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        Task {
            let r = await actions.add(org, "custom", name.trimmingCharacters(in: .whitespaces),
                                      http ? "http" : "stdio", http ? url : "", http ? "" : command, http ? [] : words)
            guard let added = r.name, r.error == nil else {
                saving = false
                refusal = r.error
                return
            }
            let secrets = Dictionary(entries.filter { !$0.name.isEmpty && !$0.value.isEmpty }.map { ($0.key, $0.value) },
                                     uniquingKeysWith: { _, b in b })
            // The server is added either way: a refusal here is shown on its page, so a retry
            // there replaces the secret instead of adding the server a second time.
            let error = secrets.isEmpty ? nil : await actions.setSecrets(org, added, secrets)
            saving = false
            done(.connection(added, justAdded: false, note: error))
        }
    }
}
