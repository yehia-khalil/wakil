import Foundation

/// The login mechanism, behind one protocol (Decision 31).
///
/// **The contract is: scoped home environment variable, spawn a login,
/// read liveness. It is NOT minting**, which is Claude-shaped — a
/// `setup-token` verb with a one-shot capture and an atomic store, and
/// nothing about it generalises. Putting the mint behind this protocol
/// would put a Claude-specific step in a seam whose whole purpose is that
/// a second kind can conform without touching the flow.
///
/// **Kind-keyed, with Claude Code its only conformance.** Codex differs at
/// every mechanism, which is what earns the seam rather than what makes it
/// speculative: the second conformance is [#136] and is out of scope here,
/// and `ProviderKindLocal` stays out with no ticket at all because it has
/// no login.
///
/// **The seam splits at the human, not at the language.** Swift spawns the
/// interactive login because a browser trip is a thing an operator watches;
/// Go owns durable capture because a credential must not travel through an
/// action's parameters. Invariant 1 survives because *neither side
/// interprets* the credential — Swift never sees the token, and Go never
/// decides what a login means.
///
/// It is `ProviderCredentialsLookup` one object over, and it is injected
/// the same way: `WindowModel` already takes an injected lookup factory, so
/// the fake used by every test here has a working precedent rather than a
/// new pattern. **No test spawns a browser.**
public protocol ProviderLogin: Sendable {
    /// The provider kind this conformance answers for.
    static var kind: String { get }

    /// Spawns an interactive login scoped to `configDir` and returns when
    /// it has finished, one way or another.
    ///
    /// **`configDir` is used verbatim.** It arrives already resolved from
    /// `DeriveConfigDir`, and the CLI hashes the literal string it is
    /// handed to name its Keychain item — so resolving it again here, or
    /// tidying it in any way, produces a sign-in under a name nothing else
    /// will look up.
    func signIn(configDir: String, binary: String) async throws -> ProviderLoginResult

    /// Reads whose sign-in is in `configDir`, or that there is none.
    ///
    /// Separate from `signIn` because re-entry has to ask before it
    /// offers: the operator is shown *whose* sign-in was found before it
    /// is reused, which closes a misidentification hazard — nothing
    /// guarantees the second `acme` is the same human.
    func identity(configDir: String, binary: String) async -> ProviderLoginIdentity
}

/// How a browser trip ended.
///
/// **A refusal and a timeout are different**, and the difference is the
/// one thing this type exists to carry: *a refusal may claim what a
/// timeout may not*. A declined sign-in is an observed fact and fails
/// fast; a timeout knows nothing about what did or did not happen.
public enum ProviderLoginResult: Sendable, Equatable {
    /// The operator signed in. The identity is what the CLI reported
    /// afterwards.
    case signedIn(ProviderLoginIdentity)
    /// The operator declined in the browser. **Fails fast** rather than
    /// sitting until a timeout, and may state plainly that nothing
    /// happened — a refusal is observed.
    case refused(String)
    /// The trip ran out of time. It says nothing about what happened,
    /// which is exactly what makes it different from a refusal.
    case timedOut
    /// The operator cancelled.
    case cancelled
}

/// Whose sign-in a config directory holds.
///
/// **Measured, 2026-09-22:** a lapsed directory reports logged out with no
/// identity at all — no email, no org. So `email` non-empty and
/// `loggedIn` true arrive together or not at all, and there is nothing to
/// offer a `Continue as <email>` for on a dead directory.
public struct ProviderLoginIdentity: Sendable, Equatable {
    public var loggedIn: Bool
    public var email: String
    public var orgName: String

    public init(loggedIn: Bool = false, email: String = "", orgName: String = "") {
        self.loggedIn = loggedIn
        self.email = email
        self.orgName = orgName
    }

    /// Whether this names somebody. The re-entry prompt turns on THIS
    /// rather than on `loggedIn`, because there is nothing to say
    /// "continue as" about without a name.
    public var namesSomebody: Bool { loggedIn && !email.isEmpty }

    /// How many browser trips a repair costs: **one** when the sign-in is
    /// live and names somebody — the mint alone — and **two** otherwise,
    /// the first of which is the one that clears the red.
    ///
    /// Derived from liveness, not from the directory existing. Under the
    /// rejected reading, pressing Re-authenticate on a red row succeeded
    /// and left the row red, because nothing on a mint-only path writes
    /// the sign-in.
    public var tripsToRepair: Int { namesSomebody ? 1 : 2 }
}

/// Errors the login mechanism itself can raise — as distinct from a trip
/// that ran and ended badly, which is a `ProviderLoginResult`.
public enum ProviderLoginError: Error, Equatable, CustomStringConvertible {
    /// No conformance is registered for this provider kind.
    case unsupportedKind(String)
    /// The login binary could not be started at all.
    case couldNotStart(String)

    public var description: String {
        switch self {
        case .unsupportedKind(let kind):
            return "Wakil cannot sign in to a \(kind) account from here yet — "
                + "only \(ClaudeCodeProviderLogin.kind) has a login mechanism."
        case .couldNotStart(let message):
            return message
        }
    }
}

/// Picks the conformance for a provider kind.
///
/// A function rather than a registry actor, because there is exactly one
/// conformance and the alternative would be machinery standing in for a
/// decision. When #136 adds the second, this grows an arm — which is the
/// whole of what "kind-keyed" has to mean.
public func makeProviderLogin(
    forKind kind: String, spawn: ProviderLoginSpawning = SubprocessProviderLoginSpawner()
) throws -> any ProviderLogin {
    switch kind {
    case ClaudeCodeProviderLogin.kind:
        return ClaudeCodeProviderLogin(spawn: spawn)
    default:
        throw ProviderLoginError.unsupportedKind(kind)
    }
}
