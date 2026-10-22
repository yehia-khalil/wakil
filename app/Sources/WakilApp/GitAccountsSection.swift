import AppKit
import SwiftUI
import WakilKit

/// Settings → Organisation → Git's accounts (3a-iii, Decision 44), handed in from the window as
/// closures, as the pane's other writes are.
struct GitAccountActions {
    var suggestions: () async -> [(host: String, repositories: Int)] = { [] }
    var sshKeys: () async -> [GitSSHKey] = { [] }
    var add: (String, GitProvider, GitAccountMethod, String, String) async -> String? = { _, _, _, _, _ in nil }
    var remove: (String) async -> String? = { _ in nil }
    var generateKey: (String, String) async -> (publicKey: String?, path: String?, error: String?) = { _, _ in (nil, nil, nil) }
    var setToken: (String, String) async -> String? = { _, _ in nil }
    var setPassphrase: (String, String) async -> String? = { _, _ in nil }
    var test: (String) async -> (user: String?, error: String?) = { _ in (nil, nil) }
    var deviceStart: (GitProvider) async -> (userCode: String?, page: String?, deviceCode: String?, interval: Int, error: String?) = { _ in (nil, nil, nil, 5, nil) }
    var devicePoll: (GitProvider, String, String) async -> (pending: Bool, error: String?) = { _, _, _ in (false, nil) }
    var ghLogins: () async -> [(host: String, user: String)] = { [] }
    var ghImport: (String, String) async -> String? = { _, _ in nil }
}

/// The account rows, each with Test and Remove (Remove asks, in the pane: it ends access — Rule 1),
/// and **+ Add a git account**, which opens the sheet.
struct GitAccountsBlock: View {
    let org: SettingsOrg
    let git: GitAccountActions
    @State private var adding = false
    @State private var confirmingRemove: String?
    @State private var notes: [String: String] = [:]
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(org.gitAccounts, id: \.host) { account in
                row(account)
            }
            FormButton(title: "+ Add a git account", tone: SettingsPalette.accent, identifier: "settings.org.git.account.add") {
                adding = true
            }
        }
        .sheet(isPresented: $adding) {
            GitAccountSheet(org: org, git: git) { adding = false }
        }
    }

    @ViewBuilder
    private func row(_ account: SettingsGitAccount) -> some View {
        let id = "settings.org.git.account.\(account.host)"
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(gitAccountRowText(account))
                    .font(.system(size: SettingsScale.identifier, design: .monospaced))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.9))
                    .accessibilityIdentifier(id)
                Spacer(minLength: 0)
                if busy.contains(account.host) { ProgressView().controlSize(.mini) }
                FormButton(title: "Test", tone: SettingsPalette.coolWhite, identifier: id + ".test") {
                    Task {
                        busy.insert(account.host)
                        let r = await git.test(account.host)
                        busy.remove(account.host)
                        notes[account.host] = r.error ?? (r.user.map { $0.isEmpty ? "✓ \(account.host) knows this account" : "✓ \(account.host) knows this account as \($0)" })
                    }
                }
                if confirmingRemove == account.host {
                    FormButton(title: "Remove", tone: SettingsPalette.caution, filled: true, identifier: id + ".remove.confirm") {
                        Task {
                            notes[account.host] = await git.remove(account.host)
                            confirmingRemove = nil
                        }
                    }
                    FormButton(title: "Keep it", tone: SettingsPalette.coolWhite, identifier: id + ".remove.keep") {
                        confirmingRemove = nil
                    }
                } else {
                    FormButton(title: "Remove", tone: SettingsPalette.caution, identifier: id + ".remove") {
                        confirmingRemove = account.host
                    }
                }
            }
            if let note = notes[account.host] {
                Text(note)
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(note.hasPrefix("✓") ? SettingsPalette.coolWhite.opacity(0.6) : SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// + Add a git account: the provider (suggested from the projects' remotes), the method it offers,
/// then that method's steps, ending in Test (spec item 1).
struct GitAccountSheet: View {
    let org: SettingsOrg
    let git: GitAccountActions
    let done: () -> Void

    @State private var suggestions: [(host: String, repositories: Int)] = []
    @State private var provider: GitProvider?
    @State private var otherHost = ""
    @State private var method: GitAccountMethod?
    @State private var keys: [GitSSHKey] = []
    @State private var pickedKey: GitSSHKey?
    @State private var passphrase = ""
    @State private var publicKey: String?
    @State private var token = ""
    @State private var username = ""
    @State private var message: String?
    @State private var working = false
    @State private var ghLogins: [(host: String, user: String)] = []
    @State private var deviceUserCode: String?
    @State private var devicePage: String?
    @State private var signingIn: Task<Void, Never>?
    @FocusState private var focus: Bool

    private var host: String { provider?.host ?? otherHost.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a git account").font(.system(size: 14, weight: .semibold))
            providerStep
            if provider != nil, !host.isEmpty { methodStep }
            if let method, !host.isEmpty { steps(method) }
            if let message {
                Text(message)
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(message.hasPrefix("✓") ? SettingsPalette.coolWhite.opacity(0.7) : SettingsPalette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.org.git.account.add.message")
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                FormButton(title: "Close", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.close") { done() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            suggestions = await git.suggestions()
            ghLogins = await git.ghLogins()
        }
        .onDisappear { signingIn?.cancel() }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider").font(.system(size: SettingsScale.meta)).foregroundStyle(SettingsPalette.coolWhite.opacity(0.5))
            if !suggestions.isEmpty {
                Text(suggestions.map { "\($0.host) — \($0.repositories) repositor\($0.repositories == 1 ? "y" : "ies")" }.joined(separator: " · "))
                    .font(.system(size: SettingsScale.meta))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
            }
            HStack(spacing: 6) {
                ForEach(GitProvider.allCases, id: \.self) { p in
                    FormButton(title: p.title, tone: provider == p ? SettingsPalette.accent : SettingsPalette.coolWhite,
                               filled: provider == p, identifier: "settings.org.git.account.add.provider.\(p.rawValue)") {
                        provider = p
                        method = nil
                        message = nil
                        if p == .other, let s = suggestions.first(where: { GitProvider(host: $0.host) == .other }) { otherHost = s.host }
                    }
                }
            }
            .focused($focus)
            .onAppear { focus = true }   // Rule 3
            if provider == .other {
                TextField("git.example.com", text: $otherHost)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.org.git.account.add.host")
            }
        }
    }

    private var methodStep: some View {
        HStack(spacing: 6) {
            ForEach(gitAccountMethods(provider: provider ?? .other, signInAvailable: signInOffered), id: \.self) { m in
                FormButton(title: m.title, tone: method == m ? SettingsPalette.accent : SettingsPalette.coolWhite,
                           filled: method == m, identifier: "settings.org.git.account.add.method.\(m.rawValue)") {
                    method = m
                    message = nil
                    if m == .ssh { Task { keys = await git.sshKeys() } }
                }
            }
        }
    }

    @ViewBuilder
    private func steps(_ method: GitAccountMethod) -> some View {
        switch method {
        case .ssh: sshSteps
        case .token: tokenSteps
        case .signin: signInSteps
        }
    }

    private var sshSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let publicKey {
                Text("Add this public key to \(host):").font(.system(size: SettingsScale.meta))
                Text(publicKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(SettingsPalette.coolWhite.opacity(0.05)))
                    .accessibilityIdentifier("settings.org.git.account.add.publicKey")
                HStack(spacing: 6) {
                    FormButton(title: "Copy", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(publicKey, forType: .string)
                    }
                    if let page = provider?.sshKeyPage {
                        FormButton(title: "Open \(host)'s SSH keys page", tone: SettingsPalette.coolWhite,
                                   identifier: "settings.org.git.account.add.openKeys") { NSWorkspace.shared.open(page) }
                    }
                    testButton
                }
            } else {
                ForEach(keys) { key in
                    FormButton(title: "\(key.comment.isEmpty ? (key.path as NSString).lastPathComponent : key.comment) · \((key.path as NSString).lastPathComponent)\(key.encrypted ? " · passphrase" : "")",
                               tone: pickedKey == key ? SettingsPalette.accent : SettingsPalette.coolWhite, filled: pickedKey == key,
                               identifier: "settings.org.git.account.add.key.\((key.path as NSString).lastPathComponent)") {
                        pickedKey = key
                    }
                }
                if let pickedKey {
                    if pickedKey.encrypted {
                        SecureField("Its passphrase, kept in the Keychain", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("settings.org.git.account.add.passphrase")
                    }
                    HStack(spacing: 6) {
                        FormButton(title: "Use this key", tone: SettingsPalette.accent, filled: true,
                                   identifier: "settings.org.git.account.add.useKey") {
                            Task { await useKey(pickedKey) }
                        }
                        testButton
                    }
                }
                FormButton(title: "Generate a new key", tone: SettingsPalette.accent, identifier: "settings.org.git.account.add.generate") {
                    Task { await generate() }
                }
            }
        }
    }

    /// Sign in is offered when Wakil has the provider's client id, or, for GitHub, when gh holds a login.
    private var signInOffered: Bool {
        guard let provider else { return false }
        return org.gitSignIn.contains(provider.rawValue) || (provider == .github && ghLogins.contains { $0.host == host })
    }

    private var signInSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider == .github, ghLogins.contains(where: { $0.host == host }) {
                Text("Use a gh login").font(.system(size: SettingsScale.meta)).foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                HStack(spacing: 6) {
                    ForEach(ghLogins.filter { $0.host == host }, id: \.user) { login in
                        FormButton(title: login.user, tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.gh.\(login.user)") {
                            Task {
                                working = true
                                message = await git.ghImport(host, login.user) ?? "✓ Signed in as \(login.user) (from gh)"
                                working = false
                            }
                        }
                    }
                }
            }
            if let provider, org.gitSignIn.contains(provider.rawValue) {
                if let code = deviceUserCode {
                    Text(code)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.org.git.account.add.deviceCode")
                    HStack(spacing: 6) {
                        if let page = devicePage, let url = URL(string: page) {
                            FormButton(title: "Open \(url.host ?? page)", tone: SettingsPalette.accent, filled: true,
                                       identifier: "settings.org.git.account.add.openDevice") { NSWorkspace.shared.open(url) }
                        }
                        if signingIn != nil {
                            ProgressView().controlSize(.small)
                            FormButton(title: "Cancel", tone: SettingsPalette.caution, identifier: "settings.org.git.account.add.cancelSignIn") {
                                signingIn?.cancel()
                                signingIn = nil
                            }
                        }
                    }
                } else {
                    FormButton(title: "Sign in with \(provider.title)", tone: SettingsPalette.accent, filled: true,
                               identifier: "settings.org.git.account.add.signin") { startSignIn(provider) }
                }
            }
        }
    }

    private func startSignIn(_ provider: GitProvider) {
        message = nil
        signingIn = Task {
            let start = await git.deviceStart(provider)
            guard let deviceCode = start.deviceCode, start.error == nil else {
                message = start.error
                signingIn = nil
                return
            }
            deviceUserCode = start.userCode
            devicePage = start.page
            if let page = start.page, let url = URL(string: page) { NSWorkspace.shared.open(url) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(start.interval))
                if Task.isCancelled { break }
                let r = await git.devicePoll(provider, host, deviceCode)
                if let e = r.error {
                    message = e
                    deviceUserCode = nil
                    break
                }
                if !r.pending {
                    message = "✓ Signed in to \(host)"
                    break
                }
            }
            signingIn = nil
        }
    }

    private var tokenSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page = provider?.tokenPage {
                FormButton(title: "Open \(host)'s token page (\(provider?.tokenScopes ?? ""))", tone: SettingsPalette.coolWhite,
                           identifier: "settings.org.git.account.add.openTokens") { NSWorkspace.shared.open(page) }
            }
            if provider == .bitbucket {
                TextField("Bitbucket username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.org.git.account.add.username")
            }
            SecureField("Token, kept in the Keychain", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.org.git.account.add.token")
            HStack(spacing: 6) {
                FormButton(title: "Save", tone: SettingsPalette.accent, filled: true, identifier: "settings.org.git.account.add.saveToken") {
                    Task { await saveToken() }
                }
                testButton
            }
        }
    }

    private var testButton: some View {
        FormButton(title: "Test connection", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.test") {
            Task {
                working = true
                let r = await git.test(host)
                working = false
                message = r.error ?? "✓ \(host) knows this account\(r.user.map { $0.isEmpty ? "" : " as \($0)" } ?? "")"
            }
        }
    }

    private func useKey(_ key: GitSSHKey) async {
        working = true
        defer { working = false }
        if key.encrypted {
            if let e = await git.setPassphrase(host, passphrase) { message = e; return }
        }
        message = await git.add(host, provider ?? .other, .ssh, key.path, "") ?? "Saved. Test it, or add the key on \(host) first."
    }

    private func generate() async {
        working = true
        defer { working = false }
        let r = await git.generateKey(host, "\(org.gitEmail.isEmpty ? org.id : org.gitEmail) (Wakil · \(org.id))")
        if let e = r.error { message = e; return }
        if let e = await git.add(host, provider ?? .other, .ssh, r.path ?? "", "") { message = e; return }
        publicKey = r.publicKey
        message = nil
    }

    private func saveToken() async {
        working = true
        defer { working = false }
        if let e = await git.setToken(host, token) { message = e; return }
        token = ""
        message = await git.add(host, provider ?? .other, .token, "", username) ?? "Saved. Test it."
    }
}
