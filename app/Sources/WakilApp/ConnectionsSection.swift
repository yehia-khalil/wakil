import AppKit
import SwiftUI
import WakilKit

/// Settings → Organisation → Connections, handed in from the window as closures, as the pane's
/// other writes are. Every one names the organisation the page was drawn for.
struct ConnectionActions {
    var catalog: () async -> [ConnectionKindEntry] = { [] }
    var add: (_ org: String, _ kind: String, _ name: String, _ transport: String, _ url: String,
              _ command: String, _ args: [String]) async -> (name: String?, error: String?) = { _, _, _, _, _, _, _ in (nil, nil) }
    var update: (_ org: String, _ name: String, _ newName: String?, _ url: String?, _ command: String?,
                 _ args: [String]?, _ values: [String: String]) async -> String? = { _, _, _, _, _, _, _ in nil }
    var remove: (_ org: String, _ name: String) async -> String? = { _, _ in nil }
    var setSecrets: (_ org: String, _ name: String, _ values: [String: String]) async -> String? = { _, _, _ in nil }
    var setAllow: (_ org: String, _ name: String, _ tool: String, _ allow: Bool) async -> String? = { _, _, _, _ in nil }
    var allowReadOnly: (_ org: String, _ name: String) async -> String? = { _, _ in nil }
    var check: (_ org: String, _ name: String) async -> ConnectionStatus = { _, _ in .failing("not wired") }
    var signIn: (_ org: String, _ name: String) async -> String? = { _, _ in nil }
    var signOut: (_ org: String, _ name: String) async -> String? = { _, _ in nil }
    var account: (_ org: String, _ name: String) -> String? = { _, _ in nil }
    var setJiraToken: (_ org: String, _ email: String, _ token: String) async -> String? = { _, _, _ in nil }
}

private enum ConnectionsPage: Equatable {
    case list, add, custom, jira
    case connection(String, justAdded: Bool)
}

private let green = Color(red: 0.545, green: 0.878, blue: 0.784)   // #8be0c8 (§5)
private let red = Color(red: 0.910, green: 0.361, blue: 0.361)     // #e85c5c (§5)

private func tone(_ dot: ConnectionDot) -> Color {
    switch dot {
    case .connected: green
    case .needsSignIn: SettingsPalette.caution
    case .failing: red
    case .unchecked: SettingsPalette.coolWhite.opacity(0.35)
    }
}

/// The dot and its word, as the list and the status line draw them.
private struct ConnectionDotLabel: View {
    let dot: ConnectionDot
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone(dot)).frame(width: 7, height: 7)
            Text(dot.word)
                .font(.system(size: SettingsScale.meta + 1))
                .foregroundStyle(tone(dot).opacity(dot == .unchecked ? 1 : 0.9))
        }
    }
}

/// The list — Jira first, then each connection with its dot and word — and **+ Add connection**;
/// a row opens its page in place. Each connection is checked when the list opens (no timer).
struct ConnectionsBlock: View {
    let org: SettingsOrg
    let actions: ConnectionActions
    /// The Jira site's row: the organisation page's own editor for it (`settings.org.jiraBase`),
    /// moved onto the Jira entry's page — the same field, saved the same way.
    var jiraSite: AnyView = AnyView(EmptyView())
    @State private var page: ConnectionsPage = .list
    @State private var statuses: [String: ConnectionStatus] = [:]
    @State private var checks: [String: Task<Void, Never>] = [:]

    var body: some View {
        Group {
            switch page {
            case .list: list
            case .add: ConnectionCatalogList(actions: actions, org: org.id) { result in page = result }
            case .custom: CustomServerForm(org: org.id, actions: actions) { result in page = result }
            case .jira: JiraConnectionPage(org: org, actions: actions, site: jiraSite) { page = .list }
            case .connection(let name, let justAdded):
                if let c = org.connections.first(where: { $0.name == name }) {
                    ConnectionPage(
                        org: org.id, connection: c, actions: actions, status: statuses[name],
                        checking: checks[name] != nil, focusFirst: justAdded,
                        check: { check(name) }, cancelCheck: { cancelCheck(name) },
                        renamed: { page = .connection($0, justAdded: false) },
                        back: { page = .list })
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .onDisappear { for name in checks.keys { cancelCheck(name) } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: "Jira", dot: jiraDot(org), identifier: "settings.org.connections.jira") { page = .jira }
            ForEach(org.connections, id: \.name) { c in
                row(title: c.displayTitle, detail: c.displayTitle == c.name ? "" : c.name,
                    dot: connectionDot(c, status: statuses[c.name]), checking: checks[c.name] != nil,
                    identifier: "settings.org.connections.\(c.name)") {
                    page = .connection(c.name, justAdded: false)
                }
            }
            FormButton(title: "+ Add connection", tone: SettingsPalette.accent,
                       identifier: "settings.org.connections.add") { page = .add }
                .padding(.top, 10)
        }
        .onAppear {
            for c in org.connections where statuses[c.name] == nil && checks[c.name] == nil { check(c.name) }
        }
    }

    private func row(title: String, detail: String = "", dot: ConnectionDot, checking: Bool = false,
                     identifier: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: SettingsScale.identifier, weight: .medium))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.9))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: SettingsScale.meta + 1, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.45))
                }
                Spacer(minLength: 0)
                if checking { ProgressView().controlSize(.small) }
                ConnectionDotLabel(dot: dot)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.35))
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SettingsPalette.coolWhite.opacity(0.06)).frame(height: 0.5)
        }
        .accessibilityIdentifier(identifier)
    }

    private func check(_ name: String) {
        checks[name]?.cancel()
        checks[name] = Task {
            let status = await actions.check(org.id, name)
            guard !Task.isCancelled else { return }
            statuses[name] = status
            checks[name] = nil
        }
    }

    private func cancelCheck(_ name: String) {
        checks[name]?.cancel()
        checks[name] = nil
    }
}

/// A page's own header: its title, and the way back to the list.
private struct PageHeader: View {
    let title: String
    let identifier: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Text("‹ Connections")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(identifier).back")
            Text(title)
                .font(.system(size: SettingsScale.door, weight: .semibold))
                .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                .accessibilityIdentifier(identifier)
        }
        .padding(.bottom, 6)
    }
}

/// A micro header inside a connection's page: Server, Sign-in, Status, Tools.
private struct PagePart: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: SettingsScale.micro, weight: .medium))
            .tracking(SettingsScale.microTracking)
            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.42))
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

// MARK: - Add

/// **+ Add connection**: the ready-made list, then **Custom server**. Picking one adds it at once
/// (Rule 1: adding asks nothing) and opens its page on the first sign-in field (Rule 3).
private struct ConnectionCatalogList: View {
    let actions: ConnectionActions
    let org: String
    let done: (ConnectionsPage) -> Void
    @State private var kinds: [ConnectionKindEntry] = []
    @State private var adding: String?
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PageHeader(title: "Add connection", identifier: "settings.org.connections.catalog") { done(.list) }
            ForEach(kinds) { kind in
                HStack(spacing: 10) {
                    FormButton(title: kind.title, tone: SettingsPalette.coolWhite,
                               identifier: "settings.org.connections.catalog.\(kind.id)") { add(kind) }
                        .disabled(adding != nil)
                    if adding == kind.id { ProgressView().controlSize(.small) }
                }
            }
            FormButton(title: "Custom server", tone: SettingsPalette.accent,
                       identifier: "settings.org.connections.catalog.custom") { done(.custom) }
                .disabled(adding != nil)
            if let refusal { SheetMessage(text: refusal, identifier: "settings.org.connections.catalog.error") }
        }
        .task { kinds = await actions.catalog() }
    }

    private func add(_ kind: ConnectionKindEntry) {
        guard adding == nil else { return }
        adding = kind.id
        refusal = nil
        Task {
            let r = await actions.add(org, kind.id, "", "", "", "", [])
            adding = nil
            if let name = r.name, r.error == nil { done(.connection(name, justAdded: true)) } else { refusal = r.error }
        }
    }
}

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
private struct CustomServerForm: View {
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
            PageHeader(title: "Custom server", identifier: "settings.org.connections.custom") { done(.add) }
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
            if !secrets.isEmpty, let error = await actions.setSecrets(org, added, secrets) {
                saving = false
                refusal = error
                return
            }
            saving = false
            done(.connection(added, justAdded: false))
        }
    }
}

// MARK: - A secret, stored once

/// A secret field: typed and stored behind **Store it**; once stored it shows
/// `•••••••• stored in Keychain` and **Replace**, which asks before it overwrites (Rule 1, the
/// `settings.apiToken.confirm` pattern). It is never shown again. What is typed stays while the
/// row is on screen (Rule 2).
private struct SecretRow: View {
    let label: String
    let stored: Bool
    let identifier: String
    /// What a replacement overwrites, said before **Store it**.
    let replaces: String
    var wantsFocus = false
    let save: (String) async -> String?
    @State private var replacing = false
    @State private var value = ""
    @State private var saving = false
    @State private var refusal: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(label, wraps: true) {
                if stored && !replacing {
                    HStack(spacing: 10) {
                        Text("•••••••• stored in Keychain")
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                            .accessibilityIdentifier("\(identifier).stored")
                        FormButton(title: "Replace", tone: SettingsPalette.coolWhite,
                                   identifier: "\(identifier).replace") { replacing = true }
                    }
                } else {
                    HStack(spacing: 10) {
                        SecureField(stored ? "new value" : "", text: $value)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.9))
                            .focused($focused)
                            .fieldBox(maxWidth: 280)
                            .accessibilityIdentifier(identifier)
                            .accessibilityLabel(label.lowercased())
                            .onAppear { if wantsFocus || replacing { focused = true } }
                        if !value.isEmpty && !stored {
                            FormButton(title: "Store it", tone: SettingsPalette.coolWhite.opacity(saving ? 0.4 : 0.9), filled: true,
                                       identifier: "\(identifier).store") { store() }
                                .disabled(saving)
                        }
                        if stored {
                            FormButton(title: "Cancel", tone: SettingsPalette.coolWhite.opacity(0.62),
                                       identifier: "\(identifier).cancel") {
                                value = ""
                                replacing = false
                            }
                        }
                        if saving { ProgressView().controlSize(.small) }
                    }
                }
            }
            if stored && replacing && !value.isEmpty {
                Text(replaces)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .underRowValue()
                FormButton(title: "Store it", tone: SettingsPalette.caution.opacity(saving ? 0.45 : 1), filled: true,
                           identifier: "settings.apiToken.confirm") { store() }
                    .disabled(saving)
                    .underRowValue()
            }
            if let refusal {
                SheetMessage(text: refusal, identifier: "\(identifier).error").underRowValue()
            }
        }
    }

    private func store() {
        guard !saving, !value.isEmpty else { return }
        saving = true
        refusal = nil
        let typed = value
        Task {
            let error = await save(typed)
            saving = false
            if let error { refusal = error } else {
                value = ""
                replacing = false
            }
        }
    }
}

// MARK: - A connection's page

private struct ConnectionPage: View {
    let org: String
    let connection: SettingsConnection
    let actions: ConnectionActions
    let status: ConnectionStatus?
    let checking: Bool
    let focusFirst: Bool
    let check: () -> Void
    let cancelCheck: () -> Void
    let renamed: (String) -> Void
    let back: () -> Void
    @State private var signingIn: Task<Void, Never>?
    @State private var busyTools: Set<String> = []
    @State private var allowingAll = false
    @State private var removing = false
    @State private var note: String?
    @State private var focusSet = false

    private var c: SettingsConnection { connection }
    private var id: String { "settings.org.connections.\(c.name)" }
    private var custom: Bool { c.kind == "custom" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: c.displayTitle, identifier: id, back: back)
            server
            signIn
            statusPart
            tools
            HStack(spacing: 10) {
                FormButton(title: "Remove connection", tone: SettingsPalette.caution,
                           identifier: "\(id).remove") { remove() }
                    .disabled(removing)
                if removing { ProgressView().controlSize(.small) }
            }
            .padding(.top, 18)
            .help("Removes \(c.name) from this organisation. Its token in the Keychain goes with it.")
            FormHint("Removes it from this organisation; its token in the Keychain goes with it.")
                .padding(.top, 4)
            if let note { SheetMessage(text: note, identifier: "\(id).note").padding(.top, 6) }
        }
        .onAppear { if status == nil && !checking { check() } }
        .onDisappear { signingIn?.cancel() }
    }

    // Server: read-only for a ready-made entry, editable for a custom one (Rule 9).
    @ViewBuilder private var server: some View {
        PagePart("Server")
        if custom {
            LeaveSavedTextField(label: "Name", stored: c.name, identifier: "\(id).name") { new in
                let error = await actions.update(org, c.name, new, nil, nil, nil, [:])
                if error == nil { renamed(new) }
                return error
            }
            if c.transport == "http" {
                LeaveSavedTextField(label: "Address", stored: c.url, identifier: "\(id).url", maxWidth: 400) { new in
                    await actions.update(org, c.name, nil, new, nil, nil, [:])
                }
            } else {
                LeaveSavedTextField(label: "Command", stored: c.command, identifier: "\(id).command", maxWidth: 400) { new in
                    await actions.update(org, c.name, nil, nil, new, nil, [:])
                }
                LeaveSavedTextField(label: "Arguments", stored: c.args.joined(separator: " "), identifier: "\(id).args",
                                    prompt: "none", maxWidth: 400) { new in
                    await actions.update(org, c.name, nil, nil, nil, new.split(whereSeparator: \.isWhitespace).map(String.init), [:])
                }
            }
        } else {
            SettingsRow("Server") { SettingsValue(text: c.transport == "http" ? c.url : ([c.command] + c.args).joined(separator: " ")) }
        }
    }

    // Sign-in, by kind: token or fields (labelled, secret ones masked), browser, or none.
    @ViewBuilder private var signIn: some View {
        PagePart("Sign-in")
        let fields = c.fields
        ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
            if field.secret {
                SecretRow(label: field.label, stored: c.secretKeys.contains(field.id), identifier: "\(id).field.\(field.id)",
                          replaces: "Replaces the \(field.label.lowercased()) stored for \(c.name) in \(org).",
                          wantsFocus: focusFirst && i == 0) { value in
                    await actions.setSecrets(org, c.name, [field.id: value])
                }
            } else {
                LeaveSavedTextField(label: field.label, stored: c.values[field.id] ?? "", identifier: "\(id).field.\(field.id)",
                                    maxWidth: 280, wantsFocus: .constant(focusFirst && i == 0)) { value in
                    await actions.update(org, c.name, nil, nil, nil, nil, [field.id: value])
                }
            }
        }
        if c.signIn == "browser" { browser }
        if custom { customSecrets }
        if c.signIn == "none" && !custom {
            FormHint("This server signs in on its own, or needs no sign-in.").underRowValue()
        }
    }

    @ViewBuilder private var browser: some View {
        SettingsRow("Browser", wraps: true) {
            if signingIn != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                    // Rule 4: a sign-in waits on the operator in another app, so it can be stopped.
                    FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "\(id).signin.cancel") {
                        signingIn?.cancel()
                        signingIn = nil
                    }
                }
            } else if c.signedIn {
                HStack(spacing: 8) {
                    Circle().fill(green).frame(width: 7, height: 7)
                    Text(actions.account(org, c.name).map { "Signed in as \($0)" } ?? "Signed in")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                        .accessibilityIdentifier("\(id).signedIn")
                    Text("·").foregroundStyle(SettingsPalette.coolWhite.opacity(0.4))
                    FormButton(title: "Sign out", tone: SettingsPalette.coolWhite, identifier: "\(id).signout") {
                        Task { note = await actions.signOut(org, c.name) }
                    }
                }
            } else {
                FormButton(title: "Sign in with \(c.displayTitle)…", tone: SettingsPalette.accent, filled: true,
                           identifier: "\(id).signin") { startSignIn() }
            }
        }
    }

    // A custom server's environment variables or headers, each stored once with Replace.
    @ViewBuilder private var customSecrets: some View {
        ForEach(connectionSecretEntries(c), id: \.key) { entry in
            SecretRow(label: "\(entry.kind) \(entry.name)", stored: true, identifier: "\(id).secret.\(entry.key)",
                      replaces: "Replaces \(entry.name)'s value stored for \(c.name) in \(org).") { value in
                await actions.setSecrets(org, c.name, [entry.key: value])
            }
        }
        NewSecretEntry(header: c.transport == "http", identifier: "\(id).secret.new") { key, value in
            await actions.setSecrets(org, c.name, [key: value])
        }
    }

    @ViewBuilder private var statusPart: some View {
        PagePart("Status")
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                // Rule 4: a check that hangs can be stopped.
                FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "\(id).check.cancel") { cancelCheck() }
            } else if let status {
                Circle().fill(tone(connectionDot(c, status: status))).frame(width: 7, height: 7)
                Text(connectionStatusLine(status))
                    .font(.system(size: SettingsScale.body, design: status.isFailing ? .monospaced : .default))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(id).status")
                FormButton(title: "Check again", tone: SettingsPalette.coolWhite, identifier: "\(id).check") { check() }
            } else {
                FormButton(title: "Check", tone: SettingsPalette.coolWhite, identifier: "\(id).check") { check() }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var tools: some View {
        PagePart("Tools")
        let live: [ConnectionTool]? = { if case .connected(let t, _)? = status { return t }; return nil }()
        let rows = connectionToolRows(c, live: live)
        if rows.isEmpty {
            FormHint("No tools yet: they are listed once the server answers a check.")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Tool", "Server says", "Allow agent"], id: \.self) { h in
                        Text(h)
                            .font(.system(size: SettingsScale.meta, weight: .medium))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.45))
                    }
                }
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name)
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.88))
                        Text(row.says)
                            .font(.system(size: SettingsScale.body))
                            .foregroundStyle(row.says == "destructive" ? red.opacity(0.9) : SettingsPalette.coolWhite.opacity(0.6))
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { row.allowed }, set: { on in flip(row.name, on) }))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(row.locked || busyTools.contains(row.name))
                                .accessibilityLabel("Allow agent: \(row.name)")
                                .accessibilityIdentifier("\(id).tool.\(row.name)")
                            if row.locked {
                                Text("(locked)")
                                    .font(.system(size: SettingsScale.meta + 1))
                                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.45))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            FormHint("Unticked = asks you before each call. Ticked = runs without asking.")
                .padding(.top, 6)
            HStack(spacing: 10) {
                FormButton(title: "Allow every tool the server marks read-only", tone: SettingsPalette.coolWhite,
                           identifier: "\(id).allowReadOnly") { allowAll() }
                    .disabled(allowingAll || !rows.contains { $0.says == "read-only" && !$0.allowed })
                if allowingAll { ProgressView().controlSize(.small) }
            }
            .padding(.top, 6)
        }
    }

    private func flip(_ tool: String, _ on: Bool) {
        guard !busyTools.contains(tool) else { return }
        busyTools.insert(tool)
        Task {
            note = await actions.setAllow(org, c.name, tool, on)
            busyTools.remove(tool)
        }
    }

    private func allowAll() {
        guard !allowingAll else { return }
        allowingAll = true
        Task {
            note = await actions.allowReadOnly(org, c.name)
            allowingAll = false
        }
    }

    private func startSignIn() {
        guard signingIn == nil else { return }
        note = nil
        signingIn = Task {
            let error = await actions.signIn(org, c.name)
            guard !Task.isCancelled else { return }
            signingIn = nil
            note = error
            if error == nil { check() }
        }
    }

    // Rule 1: removing configuration is not destroying work, so it asks nothing.
    private func remove() {
        guard !removing else { return }
        removing = true
        Task {
            let error = await actions.remove(org, c.name)
            removing = false
            if let error { note = error } else { back() }
        }
    }
}

private extension ConnectionStatus {
    var isFailing: Bool { if case .failing = self { return true }; return false }
}

/// **+ environment variable** / **+ header** on a custom server's page: a name and a value,
/// stored behind **Store it**.
private struct NewSecretEntry: View {
    let header: Bool
    let identifier: String
    let save: (String, String) async -> String?
    @State private var open = false
    @State private var name = ""
    @State private var value = ""
    @State private var saving = false
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if open {
                HStack(spacing: 8) {
                    TextField(header ? "X-Api-Key" : "API_TOKEN", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .fieldBox(width: 150)
                        .accessibilityIdentifier("\(identifier).name")
                    SecureField("value", text: $value)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsScale.identifier, design: .monospaced))
                        .fieldBox(maxWidth: 200)
                        .accessibilityIdentifier("\(identifier).value")
                    FormButton(title: "Store it", tone: SettingsPalette.coolWhite.opacity(ready ? 0.9 : 0.35), filled: true,
                               identifier: "\(identifier).store") { store() }
                        .disabled(!ready)
                    if saving { ProgressView().controlSize(.small) }
                }
            } else {
                FormButton(title: header ? "+ header" : "+ environment variable", tone: SettingsPalette.accent,
                           identifier: "\(identifier).open") { open = true }
            }
            if let refusal { SheetMessage(text: refusal, identifier: "\(identifier).error") }
        }
        .underRowValue()
        .padding(.vertical, 6)
    }

    private var ready: Bool { !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty && !value.isEmpty }

    private func store() {
        guard ready else { return }
        saving = true
        refusal = nil
        let key = (header ? "header:" : "env:") + name.trimmingCharacters(in: .whitespaces)
        let typed = value
        Task {
            let error = await save(key, typed)
            saving = false
            if let error { refusal = error } else {
                name = ""
                value = ""
                open = false
            }
        }
    }
}

// MARK: - Jira

/// The Jira entry is `wakil-pm`: its site (the field that was on the organisation's page), its
/// sign-in — email and API token, kept as `jira:<org>` — and its tools, which have no switches.
private struct JiraConnectionPage: View {
    let org: SettingsOrg
    let actions: ConnectionActions
    let site: AnyView
    let back: () -> Void
    @State private var replacing = false
    @State private var email = ""
    @State private var token = ""
    @State private var saving = false
    @State private var refusal: String?
    @FocusState private var focus: String?

    private let id = "settings.org.connections.jira"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Jira", identifier: id, back: back)
            PagePart("Server")
            site
            PagePart("Sign-in")
            if org.jiraTokenStored && !replacing {
                SettingsRow("API token") {
                    HStack(spacing: 10) {
                        Text("•••••••• stored in Keychain")
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                            .accessibilityIdentifier("\(id).token.stored")
                        FormButton(title: "Replace", tone: SettingsPalette.coolWhite, identifier: "\(id).token.replace") {
                            replacing = true
                            focus = "email"
                        }
                    }
                }
            } else {
                form
            }
            PagePart("Status")
            HStack(spacing: 8) {
                ConnectionDotLabel(dot: jiraDot(org))
                Text(org.jiraBase.isEmpty ? "No site yet." : (org.jiraTokenStored ? org.jiraBase : "No API token stored."))
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.75))
                    .accessibilityIdentifier("\(id).status")
            }
            .padding(.vertical, 6)
            PagePart("Tools")
            ForEach(wakilPMToolNames, id: \.self) { tool in
                Text(tool)
                    .font(.system(size: SettingsScale.identifier, design: .monospaced))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                    .padding(.vertical, 2)
            }
            FormHint("Permissions for these are Wakil's own.").padding(.top, 6)
        }
        // Rule 3: the first sign-in field, when there is a sign-in to give.
        .onAppear { if !org.jiraTokenStored { focus = "email" } }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelledField(label: "EMAIL", prompt: "you@initech.test", text: $email, width: 280,
                          identifier: "\(id).email", focus: $focus, focusKey: "email")
            LabelledField(label: "API TOKEN", text: $token, width: 280, identifier: "\(id).token", secure: true,
                          focus: $focus, focusKey: "token")
            if org.jiraTokenStored && ready {
                Text("Replaces the Jira sign-in stored for \(org.id).")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.caution)
            }
            HStack(spacing: 10) {
                FormButton(title: "Store it",
                           tone: (org.jiraTokenStored ? SettingsPalette.caution : SettingsPalette.coolWhite).opacity(ready ? 1 : 0.4),
                           filled: true, identifier: org.jiraTokenStored ? "settings.apiToken.confirm" : "\(id).store") { store() }
                    .disabled(!ready)
                if org.jiraTokenStored {
                    FormButton(title: "Cancel", tone: SettingsPalette.coolWhite.opacity(0.62), identifier: "\(id).cancel") {
                        email = ""
                        token = ""
                        replacing = false
                    }
                }
                if saving { ProgressView().controlSize(.small) }
            }
            if let refusal { SheetMessage(text: refusal, identifier: "\(id).error") }
        }
        .padding(.vertical, 6)
    }

    private var ready: Bool {
        !saving && !email.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty
    }

    private func store() {
        guard ready else { return }
        saving = true
        refusal = nil
        let (e, t) = (email.trimmingCharacters(in: .whitespaces), token)
        Task {
            let error = await actions.setJiraToken(org.id, e, t)
            saving = false
            if let error { refusal = error } else {
                email = ""
                token = ""
                replacing = false
            }
        }
    }
}
