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
    var devicePoll: (GitProvider, String, String, Bool) async -> (pending: Bool, error: String?) = { _, _, _, _ in (false, nil) }
    var setAPIToken: (String, String) async -> String? = { _, _ in nil }
    var removeAPIAccess: (String) async -> String? = { _ in nil }
    var testAPIAccess: (String) async -> (user: String?, error: String?) = { _ in (nil, nil) }
    var ghLogins: () async -> [(host: String, user: String)] = { [] }
    var ghImport: (String, String) async -> String? = { _, _ in nil }
}

/// One card per connected host — the provider, who the account is, how it connects — with Test, and
/// Remove behind ⋯ (it ends access, so it asks, in the card: Rule 1). **+ Connect another host**
/// opens the sheet.
struct GitAccountsBlock: View {
    let org: SettingsOrg
    let git: GitAccountActions
    @State private var adding = false
    @State private var confirmingRemove: String?
    @State private var notes: [String: String] = [:]
    @State private var testing: [String: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(org.gitAccounts, id: \.host) { account in
                card(account)
            }
            FormButton(title: org.gitAccounts.isEmpty ? "+ Connect a git account" : "+ Connect another host",
                       tone: SettingsPalette.accent, identifier: "settings.org.git.account.add") {
                adding = true
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .sheet(isPresented: $adding) {
            GitAccountSheet(org: org, git: git) { adding = false }
        }
    }

    @ViewBuilder
    private func card(_ account: SettingsGitAccount) -> some View {
        let id = "settings.org.git.account.\(account.host)"
        let card = gitAccountCard(account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(card.title)
                            .font(.system(size: SettingsScale.identifier, weight: .semibold))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                            .accessibilityIdentifier(id)
                        Text(card.method)
                            .font(.system(size: SettingsScale.meta))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(SettingsPalette.coolWhite.opacity(0.07)))
                    }
                    Text([card.host, card.user].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: SettingsScale.meta + 1, design: .monospaced))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.55))
                }
                Spacer(minLength: 0)
                if testing[account.host] != nil {
                    ProgressView().controlSize(.small)
                    // Rule 4: a Test waits on the network, so it can be stopped.
                    FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.\(account.host).test.cancel") {
                        testing[account.host]?.cancel()
                        testing[account.host] = nil
                    }
                } else {
                    FormButton(title: "Test", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.\(account.host).test") { test(account) }
                }
                Menu {
                    Button("Remove…", role: .destructive) { confirmingRemove = account.host }
                        .accessibilityIdentifier("settings.org.git.account.\(account.host).remove")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.7))
                        .frame(width: 26, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
                .accessibilityIdentifier("settings.org.git.account.\(account.host).more")
            }
            if let row = gitAPIAccessRow(account) {
                GitAPIAccessRowView(account: account, row: row, git: git, signInAvailable: org.gitSignIn.contains("github"))
            }
            if confirmingRemove == account.host {
                HStack(spacing: 8) {
                    Text("Remove \(card.title)? Pushes and pulls from \(account.host) stop until you connect it again.")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    FormButton(title: "Keep it", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.\(account.host).remove.keep") {
                        confirmingRemove = nil
                    }
                    FormButton(title: "Remove", tone: SettingsPalette.caution, filled: true, identifier: "settings.org.git.account.\(account.host).remove.confirm") {
                        Task {
                            notes[account.host] = await git.remove(account.host)
                            confirmingRemove = nil
                        }
                    }
                }
            }
            if let note = notes[account.host] {
                SheetMessage(text: note, identifier: "settings.org.git.account.\(account.host).note")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.coolWhite.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsPalette.coolWhite.opacity(0.08), lineWidth: 0.5)))
    }

    private func test(_ account: SettingsGitAccount) {
        notes[account.host] = nil
        testing[account.host] = Task {
            let r = await git.test(account.host)
            guard !Task.isCancelled else { return }
            testing[account.host] = nil
            notes[account.host] = r.error.map { gitTestFailureText($0, provider: GitProvider(host: account.host)) }
                ?? "✓ \(account.host) knows this account\(r.user.map { $0.isEmpty ? "" : " as \($0)" } ?? "")"
        }
    }
}

/// **Connect a git account**, in three steps and an ending: where the code is (a provider, or any
/// host), how Wakil signs in there (each way says what it means), connecting that way — which ends
/// with a Test where one can run — and Connected. Back steps back; Cancel stops work in flight, else
/// closes (Rule 4); the main action is Return.
struct GitAccountSheet: View {
    let org: SettingsOrg
    let git: GitAccountActions
    let done: () -> Void

    private enum Step { case provider, method, connect, connected }
    /// How the operator chose to connect: the provider's methods, plus a GitHub CLI login by user.
    private enum Way: Hashable { case signin, gh(String), ssh, token }
    private enum KeySource { case generate, existing }

    @State private var step = Step.provider
    @State private var suggestions: [(host: String, repositories: Int)] = []
    @State private var ghLogins: [(host: String, user: String)] = []
    @State private var provider: GitProvider?
    @State private var otherHost = ""
    @State private var way: Way?
    @State private var keySource = KeySource.generate
    @State private var keys: [GitSSHKey] = []
    @State private var pickedKey: GitSSHKey?
    @State private var passphrase = ""
    @State private var publicKey: String?
    @State private var copied = false
    @State private var token = ""
    @State private var username = ""
    @State private var deviceUserCode: String?
    @State private var devicePage: String?
    @State private var message: String?
    @State private var connectedAs = ""
    @State private var work: Task<Void, Never>?
    @FocusState private var field: Field?
    private enum Field { case host, token, username, passphrase }

    private var host: String { provider?.host ?? otherHost.trimmingCharacters(in: .whitespaces).lowercased() }
    private var providerName: String { provider == .other || provider == nil ? host : provider!.title }
    private var working: Bool { work != nil }

    var body: some View {
        SettingsSheet(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                switch step {
                case .provider: providerStep
                case .method: methodStep
                case .connect: connectStep
                case .connected: connectedStep
                }
                if let message { SheetMessage(text: message, identifier: "settings.org.git.account.add.message") }
            }
        } footer: {
            if step == .method || step == .connect {
                FormButton(title: "Back", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.back") {
                    back()
                }
                .disabled(working)
            }
            Spacer()
            if step != .connected {
                FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "settings.org.git.account.add.close") {
                    if let work { work.cancel(); self.work = nil } else { done() }
                }
                .keyboardShortcut(.cancelAction)
            }
            primary
        }
        .task {
            suggestions = await git.suggestions()
            ghLogins = await git.ghLogins()
        }
        .onDisappear { work?.cancel() }
    }

    private var title: String {
        switch step {
        case .provider: "Connect a git account"
        case .method: "Connect \(providerName)"
        case .connect: way.map(wayTitle) ?? "Connect \(providerName)"
        case .connected: "Connected"
        }
    }

    private var subtitle: String {
        switch step {
        case .provider: "Pushes, pulls and clones in \(org.id) use this account. One account per host."
        case .method: "How should Wakil sign in to \(host)?"
        case .connect: connectSubtitle
        case .connected: "Pushes, pulls and clones in \(org.id) now use this account on \(host)."
        }
    }

    // MARK: Step 1 — where the code is

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GitProvider.allCases, id: \.self) { p in
                let taken = gitAccountTaken(provider: p, accounts: org.gitAccounts)
                let count = p.host.flatMap { h in suggestions.first { $0.host == h }?.repositories }
                SheetChoice(
                    title: p == .other ? "Another host" : p.title,
                    detail: p.host ?? "Self-hosted GitLab, Gitea, Bitbucket Server, or any git host",
                    note: taken.map { $0.user.isEmpty ? "Connected" : "Connected as \($0.user)" }
                        ?? count.map { "\($0) repositor\($0 == 1 ? "y" : "ies") here" },
                    selected: provider == p, enabled: taken == nil,
                    identifier: "settings.org.git.account.add.provider.\(p.rawValue)"
                ) {
                    provider = p
                    message = nil
                    if p == .other {
                        if otherHost.isEmpty, let s = suggestions.first(where: { GitProvider(host: $0.host) == .other }) {
                            otherHost = s.host
                        }
                        field = .host
                    }
                }
            }
            if provider == .other {
                TextField("git.example.com", text: $otherHost)
                    .textFieldStyle(.roundedBorder)
                    .focused($field, equals: .host)
                    .onSubmit { if providerReady { step = .method } }
                    .accessibilityIdentifier("settings.org.git.account.add.host")
                if org.gitAccounts.contains(where: { $0.host == host }) {
                    SheetMessage(text: "\(host) is connected already. Remove it on the Git page to connect it again.",
                                 identifier: "settings.org.git.account.add.hostTaken")
                }
            }
        }
    }

    private var providerReady: Bool {
        guard let provider, !host.isEmpty else { return false }
        return gitAccountTaken(provider: provider, accounts: org.gitAccounts) == nil
            && !org.gitAccounts.contains { $0.host == host }
    }

    // MARK: Step 2 — how Wakil signs in

    private var ways: [Way] {
        guard let provider else { return [] }
        let gh = provider == .github ? ghLogins.filter { $0.host == host }.map { Way.gh($0.user) } : []
        let methods = gitAccountMethods(provider: provider, signInAvailable: org.gitSignIn.contains(provider.rawValue))
        return methods.flatMap { m -> [Way] in
            switch m {
            case .signin: [.signin]
            case .ssh: gh + [.ssh]   // a gh login is offered first when there is one
            case .token: [.token]
            }
        }
    }

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ways, id: \.self) { w in
                let key = wayKey(w)
                SheetChoice(title: wayTitle(w), detail: wayDetail(w), note: w == ways.first ? "Recommended" : nil,
                            selected: way == w, identifier: "settings.org.git.account.add.method.\(key)") {
                    way = w
                    message = nil
                }
            }
        }
    }

    private func wayTitle(_ w: Way) -> String {
        switch w {
        case .signin: "Sign in with \(providerName)"
        case .gh(let user): "Use your GitHub CLI login (\(user))"
        case .ssh: "SSH key"
        case .token: "Personal access token"
        }
    }

    private func wayDetail(_ w: Way) -> String {
        let p = provider ?? .other
        switch w {
        case .signin: return GitAccountMethod.signin.summary(provider: p)
        case .gh: return "Reuse the login `gh` already has on this Mac; nothing to copy"
        case .ssh: return GitAccountMethod.ssh.summary(provider: p)
        case .token: return GitAccountMethod.token.summary(provider: p)
        }
    }

    private func wayKey(_ w: Way) -> String {
        switch w {
        case .signin: "signin"
        case .gh(let user): "gh.\(user)"
        case .ssh: "ssh"
        case .token: "token"
        }
    }

    // MARK: Step 3 — connecting

    private var connectSubtitle: String {
        switch way {
        case .ssh: publicKey == nil ? "Wakil keeps the key in \(org.id)'s folder and its passphrase in the Keychain; ~/.ssh is left alone."
            : "Add this key on \(providerName), then test the connection."
        case .token: "The token is kept in the Keychain, never in a file."
        case .signin: "Approve Wakil on \(host); this sheet finishes by itself."
        case .gh(let user): "Wakil copies \(user)'s token from gh into the Keychain."
        case nil: ""
        }
    }

    @ViewBuilder
    private var connectStep: some View {
        switch way {
        case .ssh: sshStep
        case .token: tokenStep
        case .signin: signInStep
        case .gh(let user):
            SheetChoice(title: user, detail: "GitHub CLI login on \(host)", selected: true,
                        identifier: "settings.org.git.account.add.gh.\(user)") {}
        case nil: EmptyView()
        }
    }

    private var sshStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let publicKey {
                numbered(1, "Copy the public key") {
                    HStack(alignment: .top, spacing: 8) {
                        Text(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("settings.org.git.account.add.publicKey")
                        FormButton(title: copied ? "Copied" : "Copy", tone: SettingsPalette.coolWhite,
                                   identifier: "settings.org.git.account.add.copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                            copied = true
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(SettingsPalette.coolWhite.opacity(0.05)))
                }
                numbered(2, "Add it on \(providerName)") {
                    if let page = provider?.sshKeyPage {
                        FormButton(title: "Open \(providerName)'s SSH keys page", tone: SettingsPalette.coolWhite,
                                   identifier: "settings.org.git.account.add.openKeys") { NSWorkspace.shared.open(page) }
                    } else {
                        Text("In \(host)'s settings, under SSH keys.")
                            .font(.system(size: SettingsScale.body))
                            .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                    }
                }
                numbered(3, "Test the connection", content: { EmptyView() })
            } else {
                HStack(spacing: 6) {
                    segment("A new key", .generate, id: "generate")
                    segment("A key from ~/.ssh", .existing, id: "existing")
                }
                if keySource == .generate {
                    Text("Recommended: a key just for \(org.id), so this organisation never pushes as another.")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                } else if keys.isEmpty {
                    Text("No key pairs in ~/.ssh.")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                } else {
                    ForEach(keys) { key in
                        let name = (key.path as NSString).lastPathComponent
                        SheetChoice(title: key.comment.isEmpty ? name : key.comment,
                                    detail: "~/.ssh/\(name)", note: key.encrypted ? "Passphrase" : nil,
                                    selected: pickedKey == key, identifier: "settings.org.git.account.add.key.\(name)") {
                            pickedKey = key
                            if key.encrypted { Task { try? await Task.sleep(for: .milliseconds(150)); field = .passphrase } }
                        }
                    }
                    if pickedKey?.encrypted == true {
                        SecureField("Its passphrase, kept in the Keychain", text: $passphrase)
                            .textFieldStyle(.roundedBorder)
                            .focused($field, equals: .passphrase)
                            .accessibilityIdentifier("settings.org.git.account.add.passphrase")
                    }
                }
            }
        }
    }

    private func segment(_ title: String, _ source: KeySource, id: String) -> some View {
        FormButton(title: title, tone: keySource == source ? SettingsPalette.accent : SettingsPalette.coolWhite,
                   filled: keySource == source, identifier: "settings.org.git.account.add.keySource.\(id)") {
            keySource = source
            message = nil
            if source == .existing, keys.isEmpty { Task { keys = await git.sshKeys() } }
        }
    }

    private func numbered<C: View>(_ n: Int, _ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: SettingsScale.meta, weight: .semibold))
                .foregroundStyle(SettingsPalette.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SettingsPalette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.system(size: SettingsScale.body, weight: .medium))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.88))
                content()
            }
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let page = provider?.tokenPage {
                FormButton(title: "Create a token on \(providerName) (\(provider?.tokenScopes ?? ""))", tone: SettingsPalette.coolWhite,
                           identifier: "settings.org.git.account.add.openTokens") { NSWorkspace.shared.open(page) }
            }
            if provider == .bitbucket {
                TextField("Bitbucket username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .focused($field, equals: .username)
                    .accessibilityIdentifier("settings.org.git.account.add.username")
            }
            SecureField("Paste the token", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($field, equals: .token)
                .accessibilityIdentifier("settings.org.git.account.add.token")
        }
        // Rule 3. A beat after appearing: in a sheet, focus set as the field appears is dropped.
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            field = provider == .bitbucket ? .username : .token
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = deviceUserCode {
                numbered(1, "Enter this code on \(host)") {
                    Text(code)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.org.git.account.add.deviceCode")
                    if let page = devicePage, let url = URL(string: page) {
                        FormButton(title: "Open \(url.host ?? page)", tone: SettingsPalette.coolWhite,
                                   identifier: "settings.org.git.account.add.openDevice") { NSWorkspace.shared.open(url) }
                    }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve…")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                }
            } else {
                Text("Your browser opens \(host) to approve Wakil.")
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
            }
        }
    }

    // MARK: Connected

    private var connectedStep: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(SettingsPalette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(connectedAs.isEmpty ? providerName : "\(providerName) · \(connectedAs)")
                    .font(.system(size: SettingsScale.identifier, weight: .semibold))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.92))
                    .accessibilityIdentifier("settings.org.git.account.add.connected")
                Text(host)
                    .font(.system(size: SettingsScale.meta + 1, design: .monospaced))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.55))
            }
        }
    }

    // MARK: The footer's main action

    @ViewBuilder
    private var primary: some View {
        let id = "settings.org.git.account.add.primary"
        switch step {
        case .provider:
            SheetPrimaryButton(title: "Continue", enabled: providerReady, identifier: id) {
                way = ways.first
                step = .method
            }
        case .method:
            SheetPrimaryButton(title: "Continue", enabled: way != nil, identifier: id) {
                message = nil
                step = .connect
                if way == .signin { run { await signIn() } }
            }
        case .connect:
            switch way {
            case .ssh where publicKey != nil:
                SheetPrimaryButton(title: "Test connection", working: working, identifier: id) { run { await testAndFinish() } }
            case .ssh where keySource == .generate:
                SheetPrimaryButton(title: "Generate key", working: working, identifier: id) { run { await generate() } }
            case .ssh:
                SheetPrimaryButton(title: "Use this key", enabled: pickedKey != nil && (pickedKey?.encrypted != true || !passphrase.isEmpty),
                                   working: working, identifier: id) { run { await useKey() } }
            case .token:
                SheetPrimaryButton(title: "Connect", enabled: !token.trimmingCharacters(in: .whitespaces).isEmpty
                                   && (provider != .bitbucket || !username.isEmpty), working: working, identifier: id) {
                    run { await saveToken() }
                }
            case .gh(let user):
                SheetPrimaryButton(title: "Connect", working: working, identifier: id) { run { await importGh(user) } }
            case .signin:
                if !working {
                    SheetPrimaryButton(title: "Sign in again", identifier: id) { run { await signIn() } }
                }
            case nil: EmptyView()
            }
        case .connected:
            SheetPrimaryButton(title: "Done", identifier: id) { done() }
        }
    }

    private func back() {
        message = nil
        switch step {
        case .method: step = .provider
        case .connect: step = .method
        default: break
        }
    }

    /// Runs one piece of the flow as the sheet's work in flight: one at a time (Rule 5), stopped by
    /// Cancel (Rule 4).
    private func run(_ body: @escaping @MainActor () async -> Void) {
        guard work == nil else { return }
        message = nil
        work = Task {
            await body()
            work = nil
        }
    }

    private func generate() async {
        let r = await git.generateKey(host, "\(org.gitEmail.isEmpty ? org.id : org.gitEmail) (Wakil · \(org.id))")
        if let e = r.error { message = e; return }
        // No account without the key it is for: an answer missing either records nothing.
        guard let path = r.path, !path.isEmpty, let key = r.publicKey else {
            message = "Generating the key gave no key back; nothing was saved"
            return
        }
        if let e = await git.add(host, provider ?? .other, .ssh, path, "") { message = e; return }
        publicKey = key
    }

    private func useKey() async {
        guard let key = pickedKey else { return }
        if key.encrypted, let e = await git.setPassphrase(host, passphrase) { message = e; return }
        if let e = await git.add(host, provider ?? .other, .ssh, key.path, "") { message = e; return }
        await testAndFinish()
    }

    private func saveToken() async {
        if let e = await git.setToken(host, token) { message = e; return }
        token = ""
        if let e = await git.add(host, provider ?? .other, .token, "", username) { message = e; return }
        await testAndFinish(untestable: true)
    }

    private func importGh(_ user: String) async {
        if let e = await git.ghImport(host, user) { message = e; return }
        connectedAs = user
        step = .connected
    }

    /// Tests the account just saved; Connected on an answer. A token host Wakil cannot test is
    /// Connected too, saying so — the next fetch is its test.
    private func testAndFinish(untestable: Bool = false) async {
        let r = await git.test(host)
        if Task.isCancelled { return }
        if let e = r.error {
            if untestable, e.contains("cannot test a token") {
                step = .connected
                message = "Wakil cannot test a token on \(host); the next fetch will."
                return
            }
            message = gitTestFailureText(e, provider: provider ?? .other)
            return
        }
        connectedAs = r.user ?? ""
        message = nil
        step = .connected
    }

    private func signIn() async {
        guard let provider else { return }
        let start = await git.deviceStart(provider)
        guard let deviceCode = start.deviceCode, start.error == nil else {
            message = start.error
            return
        }
        deviceUserCode = start.userCode
        devicePage = start.page
        if let page = start.page, let url = URL(string: page) { NSWorkspace.shared.open(url) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(start.interval))
            if Task.isCancelled { break }
            let r = await git.devicePoll(provider, host, deviceCode, false)
            if let e = r.error {
                message = e
                deviceUserCode = nil
                return
            }
            if !r.pending {
                deviceUserCode = nil
                await testAndFinish()
                return
            }
        }
        deviceUserCode = nil
    }
}

/// An SSH GitHub account's **API access**: what Wakil reads pull requests with while git keeps
/// pushing over SSH. Sign in (a code to approve; Cancel ends the wait, Rule 4) or an access token
/// (a secure field, focused when it opens, kept when focus leaves, Rules 2 and 3); once set, Test and
/// Remove. One action runs at a time per row, its buttons off until its call returns (Rule 5): Store,
/// Test and Remove offer no Cancel, since one would only stop watching a call already sent.
struct GitAPIAccessRowView: View {
    let account: SettingsGitAccount
    let row: GitAPIAccessRow
    let git: GitAccountActions
    let signInAvailable: Bool

    @State private var enteringToken = false
    @State private var token = ""
    @State private var userCode: String?
    @State private var page: String?
    @State private var work: Task<Void, Never>?
    /// The running work is Sign in's: the only one Cancel is offered for.
    @State private var signingIn = false
    @State private var confirmingRemove = false
    @State private var note: String?
    @FocusState private var tokenFocused: Bool

    private var id: String { "settings.org.git.account.\(account.host).api" }
    private var host: String { account.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(.system(size: SettingsScale.body, weight: .semibold))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.85))
                Text(row.detail)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                    .accessibilityIdentifier("\(id).detail")
                Spacer(minLength: 0)
                if work != nil {
                    ProgressView().controlSize(.small)
                    if signingIn {
                        // Ends the wait; the row stays busy until the sign-in's call returns.
                        FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "\(id).cancel") {
                            work?.cancel()
                            userCode = nil
                        }
                    }
                } else {
                    if signInAvailable {
                        FormButton(title: "Sign in", tone: SettingsPalette.accent, identifier: "\(id).signin") { signIn() }
                    }
                    FormButton(title: "Use a token", tone: SettingsPalette.coolWhite, identifier: "\(id).token") {
                        enteringToken = true
                    }
                    if row.isSet {
                        FormButton(title: "Test", tone: SettingsPalette.coolWhite, identifier: "\(id).test") { test() }
                        FormButton(title: "Remove", tone: SettingsPalette.caution, identifier: "\(id).remove") {
                            confirmingRemove = true
                        }
                    }
                }
            }
            if let code = userCode {
                HStack(spacing: 8) {
                    Text("Enter this code on \(host)")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.coolWhite.opacity(0.6))
                    Text(code)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(id).deviceCode")
                    if let page, let url = URL(string: page) {
                        FormButton(title: "Open \(url.host ?? page)", tone: SettingsPalette.coolWhite, identifier: "\(id).openDevice") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if enteringToken && work == nil {
                HStack(spacing: 8) {
                    SecureField("Paste an access token that can \(GitProvider.github.tokenScopes)", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .focused($tokenFocused)
                        .accessibilityIdentifier("\(id).token.field")
                        .onSubmit { storeToken() }
                        // Rule 3. A beat after appearing, as the sheet's fields do.
                        .task {
                            try? await Task.sleep(for: .milliseconds(150))
                            tokenFocused = true
                        }
                    FormButton(title: "Store", tone: SettingsPalette.accent, filled: true, identifier: "\(id).token.store") { storeToken() }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    FormButton(title: "Cancel", tone: SettingsPalette.coolWhite, identifier: "\(id).token.cancel") {
                        token = ""
                        enteringToken = false
                    }
                }
            }
            if confirmingRemove {
                HStack(spacing: 8) {
                    Text("Remove API access? Pull requests are not read until you add it again. Pushes stay on SSH.")
                        .font(.system(size: SettingsScale.body))
                        .foregroundStyle(SettingsPalette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    FormButton(title: "Keep it", tone: SettingsPalette.coolWhite, identifier: "\(id).remove.keep") { confirmingRemove = false }
                    FormButton(title: "Remove", tone: SettingsPalette.caution, filled: true, identifier: "\(id).remove.confirm") {
                        confirmingRemove = false
                        run { note = await git.removeAPIAccess(host) }
                    }
                }
            }
            if let note { SheetMessage(text: note, identifier: "\(id).note") }
        }
    }

    /// Starts one piece of work and clears the row's busy state when it ends, cancelled or not.
    private func run(_ body: @escaping () async -> Void) {
        guard work == nil else { return }
        note = nil
        work = Task {
            await body()
            work = nil
        }
    }

    private func storeToken() {
        let value = token.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        run {
            let refusal = await git.setAPIToken(host, value)
            note = refusal
            // The typed token stays when it was refused (Rule 2); a stored one is not kept in the view.
            if refusal == nil {
                token = ""
                enteringToken = false
            }
        }
    }

    private func test() {
        run {
            let r = await git.testAPIAccess(host)
            guard !Task.isCancelled else { return }
            note = r.error ?? "✓ GitHub knows this access\(r.user.map { $0.isEmpty ? "" : " as \($0)" } ?? "")"
        }
    }

    private func signIn() {
        run {
            signingIn = true
            defer { signingIn = false }
            let start = await git.deviceStart(.github)
            guard !Task.isCancelled else { return }
            guard let deviceCode = start.deviceCode, start.error == nil else {
                note = start.error
                return
            }
            userCode = start.userCode
            page = start.page
            if let p = start.page, let url = URL(string: p) { NSWorkspace.shared.open(url) }
            defer { userCode = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(start.interval))
                if Task.isCancelled { break }
                let r = await git.devicePoll(.github, host, deviceCode, true)
                // A wait cancelled meanwhile shows no late note (Rule 5).
                if let e = r.error, !Task.isCancelled {
                    note = e
                    return
                }
                if !r.pending { return }
            }
        }
    }
}
