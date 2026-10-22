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

/// An account row in Settings: `github.com · SSH · dev-umbrella`.
public func gitAccountRowText(_ a: SettingsGitAccount) -> String {
    let method = ["ssh": "SSH", "token": "Token", "signin": "Signed in"][a.method] ?? a.method
    return [a.host, method, a.user].filter { !$0.isEmpty }.joined(separator: " · ")
}
