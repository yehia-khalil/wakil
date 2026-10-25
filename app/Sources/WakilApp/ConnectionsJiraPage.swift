import SwiftUI
import WakilKit

// MARK: - Jira

/// The Jira entry is `wakil-pm`: its site (the field that was on the organisation's page), its
/// sign-in — email and API token, kept as `jira:<org>` — and its tools, which have no switches.
struct JiraConnectionPage: View {
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
            ConnectionPageHeader(title: "Jira", identifier: id, back: back)
            ConnectionPagePart("Server")
            site
            ConnectionPagePart("Sign-in")
            if org.jiraTokenStored && !replacing {
                SettingsRow("API token") {
                    HStack(spacing: 10) {
                        Text("•••••••• stored in Keychain")
                            .font(.system(size: SettingsScale.identifier, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                            .accessibilityIdentifier("\(id).token.stored")
                        FormButton(title: "Replace", tone: SettingsPalette.coolWhite, identifier: "\(id).token.replace") {
                            replacing = true
                        }
                    }
                }
            } else {
                form
            }
            ConnectionPagePart("Status")
            HStack(spacing: 8) {
                ConnectionDotLabel(dot: jiraDot(org))
                Text(org.jiraBase.isEmpty ? "No site yet." : (org.jiraTokenStored ? org.jiraBase : "No API token stored."))
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.75))
                    .accessibilityIdentifier("\(id).status")
            }
            .padding(.vertical, 6)
            ConnectionPagePart("Tools")
            ForEach(wakilPMToolNames, id: \.self) { tool in
                Text(tool)
                    .font(.system(size: SettingsScale.identifier, design: .monospaced))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                    .padding(.vertical, 2)
            }
            FormHint("Permissions for these are Wakil's own.").padding(.top, 6)
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelledField(label: "EMAIL", prompt: "you@initech.test", text: $email, width: 280,
                          identifier: "\(id).email", focus: $focus, focusKey: "email")
                // Rule 3: the form appears when there is a sign-in to give (none stored, or
                // Replace), and its first field takes the keyboard then.
                .onAppear { focus = "email" }
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
                           filled: true, identifier: org.jiraTokenStored ? "\(id).token.confirm" : "\(id).store") { store() }
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
