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

enum ConnectionsPage: Equatable {
    case list, add, custom, jira
    /// `note`: a refusal to show on arrival — the secrets a just-added custom server could not keep.
    case connection(String, justAdded: Bool, note: String? = nil)
}

let connectionGreen = Color(red: 0.545, green: 0.878, blue: 0.784)   // #8be0c8 (§5)
let connectionRed = Color(red: 0.910, green: 0.361, blue: 0.361)     // #e85c5c (§5)

func connectionTone(_ dot: ConnectionDot) -> Color {
    switch dot {
    case .connected: connectionGreen
    case .needsSignIn: SettingsPalette.caution
    case .failing: connectionRed
    case .unchecked: SettingsPalette.coolWhite.opacity(0.35)
    }
}

/// The dot and its word, as the list and the status line draw them.
struct ConnectionDotLabel: View {
    let dot: ConnectionDot
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connectionTone(dot)).frame(width: 7, height: 7)
            Text(dot.word)
                .font(.system(size: SettingsScale.meta + 1))
                .foregroundStyle(connectionTone(dot).opacity(dot == .unchecked ? 1 : 0.9))
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
            case .connection(let name, let justAdded, let note):
                if let c = org.connections.first(where: { $0.name == name }) {
                    ConnectionPage(
                        org: org.id, connection: c, actions: actions, status: statuses[name],
                        checking: checks[name] != nil, focusFirst: justAdded, arrivalNote: note,
                        check: { check(name) }, cancelCheck: { cancelCheck(name) },
                        renamed: { new in
                            // The status follows the connection to its new name; a check in
                            // flight under the old one is stopped.
                            cancelCheck(name)
                            statuses[new] = statuses.removeValue(forKey: name)
                            page = .connection(new, justAdded: false)
                        },
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
struct ConnectionPageHeader: View {
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
struct ConnectionPagePart: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: SettingsScale.micro, weight: SettingsScale.headerWeight))
            .tracking(SettingsScale.microTracking)
            .foregroundStyle(SettingsPalette.coolWhite.opacity(SettingsInk.secondary))
            .padding(.top, 14)
            .padding(.bottom, SettingsScale.headerGap)
    }
}

// MARK: - Add

/// **+ Add connection**: the ready-made list, then **Custom server**. Picking one adds it at once
/// (Rule 1: adding asks nothing) and opens its page on the first sign-in field (Rule 3).
struct ConnectionCatalogList: View {
    let actions: ConnectionActions
    let org: String
    let done: (ConnectionsPage) -> Void
    @State private var kinds: [ConnectionKindEntry] = []
    @State private var adding: String?
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConnectionPageHeader(title: "Add connection", identifier: "settings.org.connections.catalog") { done(.list) }
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

// MARK: - A secret, stored once

/// A secret field: typed and stored behind **Store it**; once stored it shows
/// `•••••••• stored in Keychain` and **Replace**, which asks before it overwrites (Rule 1, the
/// `settings.apiToken.confirm` pattern, under this row's own `<identifier>.confirm` so two rows
/// open at once never share one). It is never shown again. What is typed stays while the
/// row is on screen (Rule 2).
struct ConnectionSecretRow: View {
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
                           identifier: "\(identifier).confirm") { store() }
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
