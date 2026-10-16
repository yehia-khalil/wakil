import Foundation

// MARK: - Provider credentials

/// The three values one `claude` session launches under, per spec §3.2:
/// a binary pinned by absolute path (never resolved through `PATH`), the
/// provider's config dir, and its OAuth token.
public struct ProviderCredentials: Equatable, Sendable {
    public let claudePath: String
    public let configDir: String
    public let oauthToken: String

    public init(claudePath: String, configDir: String, oauthToken: String) {
        self.claudePath = claudePath
        self.configDir = configDir
        self.oauthToken = oauthToken
    }
}

/// One provider and the credentials it resolved to, together — 2b-vi
/// Task 6's replacement for the launch-time environment read. The id
/// travels with the credentials because both are needed at the moment a
/// harness is built and they must not drift apart: the credentials go to
/// the `claude` child (`ClaudeCodeCLIHarness`'s three arguments), and the
/// id goes into every MCP server's environment (`agentMCPConfigJSON`'s
/// `provider:` argument) — a mismatch between the two would run the
/// right account's credentials with the wrong id on its own servers, and
/// nothing would throw. `harnessFactory` takes one of these, built fresh
/// from `lookup` at the moment a harness is actually needed, rather than
/// a `ProviderCredentials` captured once at window-open: that is what
/// makes a provider switch (Task 8/9) possible without relaunching the
/// window.
public struct ProviderSelection: Sendable {
    public let id: String
    public let credentials: ProviderCredentials
    public init(id: String, credentials: ProviderCredentials) {
        self.id = id
        self.credentials = credentials
    }
}

/// The default `lookup` behind `WindowModel.forTesting` when a test
/// supplies neither `lookup:` nor `lookupFactory:` — always succeeds, with
/// credentials no `forTesting`-built test reads. TEST-ONLY, in this
/// production file only because `forTesting` (also test-only) needs a
/// concrete type to hand `lookupFactory` when the caller wants the
/// zero-configuration default.
struct AlwaysSucceedsCredentialsLookupForTesting: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        ProviderCredentials(claudePath: "/usr/bin/true", configDir: "/dev/null", oauthToken: "test-only")
    }
}
