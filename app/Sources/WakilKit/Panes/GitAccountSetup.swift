import Foundation

/// The git providers Settings → Organisation → Git knows by name (3a-iii); any other host is `other`.
public enum GitProvider: String, Sendable, CaseIterable {
    case github, gitlab, bitbucket, other

    public init(host: String) {
        switch host.lowercased() {
        case "github.com": self = .github
        case "gitlab.com": self = .gitlab
        case "bitbucket.org": self = .bitbucket
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .other: "Other…"
        }
    }

    /// The host a provider's account is for; `other` asks for one.
    public var host: String? {
        switch self {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .bitbucket: "bitbucket.org"
        case .other: nil
        }
    }

    /// Where the operator adds a public key, and where they make a token (the scopes named).
    public var sshKeyPage: URL? {
        switch self {
        case .github: URL(string: "https://github.com/settings/ssh/new")
        case .gitlab: URL(string: "https://gitlab.com/-/user_settings/ssh_keys")
        case .bitbucket: URL(string: "https://bitbucket.org/account/settings/ssh-keys/")
        case .other: nil
        }
    }

    public var tokenPage: URL? {
        switch self {
        case .github: URL(string: "https://github.com/settings/tokens/new?scopes=repo")
        case .gitlab: URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")
        case .bitbucket: URL(string: "https://bitbucket.org/account/settings/api-tokens/")
        case .other: nil
        }
    }

    /// What a token must be allowed to do, in the host's own words.
    public var tokenScopes: String {
        switch self {
        case .github: "repo"
        case .gitlab: "read_repository, write_repository"
        case .bitbucket: "repository read and write"
        case .other: "read and write the repository"
        }
    }
}

/// How an account reaches its host.
public enum GitAccountMethod: String, Sendable, CaseIterable {
    case signin, ssh, token

    public var title: String {
        switch self {
        case .signin: "Sign in"
        case .ssh: "SSH key"
        case .token: "Paste a token"
        }
    }
}

/// The methods a provider offers (spec: Sign in only for GitHub and GitLab.com, and only when Wakil
/// has the provider's OAuth client id — `signInAvailable`).
public func gitAccountMethods(provider: GitProvider, signInAvailable: Bool) -> [GitAccountMethod] {
    let signIn = signInAvailable && (provider == .github || provider == .gitlab)
    return (signIn ? [.signin] : []) + [.ssh, .token]
}

/// The account already connected for a named provider's host, if any: one account per host, so the
/// sheet shows that provider as taken. `other` is never taken — it asks for its own host.
public func gitAccountTaken(provider: GitProvider, accounts: [SettingsGitAccount]) -> SettingsGitAccount? {
    guard let host = provider.host else { return nil }
    return accounts.first { $0.host == host }
}

extension GitAccountMethod {
    /// One line under the method's name in the sheet, saying what choosing it means.
    public func summary(provider: GitProvider) -> String {
        switch self {
        case .signin: return "Approve Wakil in your browser; nothing to copy"
        case .ssh:
            return "Wakil makes a key for this organisation only; you add it to \(provider == .other ? "the host" : provider.title) once"
        case .token: return "Paste a personal access token that can \(provider.tokenScopes)"
        }
    }
}

/// The tip under an SSH account's setup: SSH reads nothing from the host's API, so the Ticket
/// view's pull requests, threads and checks need a token beside the key (walk, 2026-10-27). Only
/// GitHub's API is read today; other hosts get no tip.
public func gitSSHAPIAccessTip(provider: GitProvider) -> String? {
    guard provider == .github else { return nil }
    return "Tip: SSH pushes and pulls but reads nothing from GitHub's API. For pull requests, review threads and checks in the Ticket view, also give this account an access token: its API access row, once it is added."
}

/// What an account's card in Settings shows.
public struct GitAccountCard: Sendable, Equatable {
    public var title: String
    /// The host beneath a provider's name; empty when the title is the host already.
    public var host: String
    public var user: String
    public var method: String

    public init(title: String, host: String, user: String, method: String) {
        self.title = title
        self.host = host
        self.user = user
        self.method = method
    }
}

public func gitAccountCard(_ a: SettingsGitAccount) -> GitAccountCard {
    let provider = GitProvider(host: a.host)
    let method = ["ssh": "SSH key", "token": "Token", "signin": "Signed in"][a.method] ?? a.method
    return GitAccountCard(
        title: provider == .other ? a.host : provider.title, host: provider == .other ? "" : a.host,
        user: a.user.isEmpty ? "Not tested yet" : a.user, method: method)
}

/// An SSH GitHub account's API access row: git keeps pushing over SSH, and this is what Wakil
/// reads pull requests with.
public struct GitAPIAccessRow: Sendable, Equatable {
    public var title: String
    public var detail: String
    /// Whether any access is set (Test and Remove apply).
    public var isSet: Bool
}

/// The row under an account's card: only an SSH GitHub account has one.
public func gitAPIAccessRow(_ a: SettingsGitAccount) -> GitAPIAccessRow? {
    guard a.provider == "github", a.method == "ssh" else { return nil }
    let detail: String
    switch a.apiAccess {
    case "signin": detail = "Signed in"
    case "token": detail = "Access token"
    default: detail = "Not set — pull requests are not read"
    }
    return GitAPIAccessRow(title: "API access", detail: detail, isSet: !a.apiAccess.isEmpty)
}

/// A failed Test, said plainly when it is the usual case — the key not added on the host yet —
/// and whole otherwise.
public func gitTestFailureText(_ error: String, provider: GitProvider) -> String {
    guard error.contains("Permission denied (publickey)") else { return error }
    let name = provider == .other ? "The host" : provider.title
    return "\(name) didn't accept the key yet. Add it on \(provider == .other ? "the host" : provider.title), then test again"
}
