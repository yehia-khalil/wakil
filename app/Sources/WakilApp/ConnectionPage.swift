import SwiftUI
import WakilKit

// MARK: - A connection's page

struct ConnectionPage: View {
    let org: String
    let connection: SettingsConnection
    let actions: ConnectionActions
    let status: ConnectionStatus?
    let checking: Bool
    let focusFirst: Bool
    var arrivalNote: String? = nil
    let check: () -> Void
    let cancelCheck: () -> Void
    let renamed: (String) -> Void
    let back: () -> Void
    @State private var signingIn: Task<Void, Never>?
    @State private var signingOut = false
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
            ConnectionPageHeader(title: c.displayTitle, identifier: id, back: back)
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
        .onAppear {
            if note == nil { note = arrivalNote }
            if status == nil && !checking { check() }
        }
        .onDisappear { signingIn?.cancel() }
    }

    // Server: read-only for a ready-made entry, editable for a custom one (Rule 9).
    @ViewBuilder private var server: some View {
        ConnectionPagePart("Server")
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
        ConnectionPagePart("Sign-in")
        let fields = c.fields
        ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
            if field.secret {
                ConnectionSecretRow(label: field.label, stored: c.secretKeys.contains(field.id), identifier: "\(id).field.\(field.id)",
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
                    Circle().fill(connectionGreen).frame(width: 7, height: 7)
                    Text(actions.account(org, c.name).map { "Signed in as \($0)" } ?? "Signed in")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                        .accessibilityIdentifier("\(id).signedIn")
                    Text("·").foregroundStyle(SettingsPalette.coolWhite.opacity(0.4))
                    FormButton(title: "Sign out", tone: SettingsPalette.coolWhite.opacity(signingOut ? 0.4 : 1),
                               identifier: "\(id).signout") { signOut() }
                        .disabled(signingOut)
                    if signingOut { ProgressView().controlSize(.small) }
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
            ConnectionSecretRow(label: "\(entry.kind) \(entry.name)", stored: true, identifier: "\(id).secret.\(entry.key)",
                      replaces: "Replaces \(entry.name)'s value stored for \(c.name) in \(org).") { value in
                await actions.setSecrets(org, c.name, [entry.key: value])
            }
        }
        NewSecretEntry(header: c.transport == "http", identifier: "\(id).secret.new") { key, value in
            await actions.setSecrets(org, c.name, [key: value])
        }
    }

    @ViewBuilder private var statusPart: some View {
        ConnectionPagePart("Status")
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                // Rule 4: a check that hangs can be stopped.
                FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "\(id).check.cancel") { cancelCheck() }
            } else if let status {
                Circle().fill(connectionTone(connectionDot(c, status: status))).frame(width: 7, height: 7)
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
        ConnectionPagePart("Tools")
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
                            .foregroundStyle(row.says == "destructive" ? connectionRed.opacity(0.9) : SettingsPalette.coolWhite.opacity(0.6))
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

    private func signOut() {
        guard !signingOut else { return }
        signingOut = true
        Task {
            note = await actions.signOut(org, c.name)
            signingOut = false
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
    @FocusState private var nameFocused: Bool
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
                        // Rule 3: opening the entry puts the keyboard on its name.
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
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
