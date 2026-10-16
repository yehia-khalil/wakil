import Foundation

/// One row of the settings pane's flat account table (#200).
///
/// A typed mirror of Go's `wakilcore.Account`, decoded from
/// `ctx_list_accounts`.
///
/// **One flat table with `kind` as a COLUMN**, not a kind-headed layout —
/// a kind-headed one would make the pane teach the wrong word, since §9
/// defines *Provider* as the credential and does not define *Kind* at all.
///
/// **An account registered in another organisation is a row in this same
/// table**, so adopting it later is a gesture rather than a search.
public struct Account: Sendable, Equatable, Decodable, Identifiable {
    /// The organisation whose record this binding is. A binding is
    /// `(organisation, account id)`; the ACCOUNT is the config dir, and
    /// one account on this machine carries four different ids across four
    /// organisations.
    public var org: String
    public var accountId: String
    /// A column, which is the whole argument against a kind-headed layout.
    public var kind: String
    public var label: String
    public var configDir: String
    /// The organisation whose `WAKIL_ORG` is pinned inside `configDir`. It
    /// differs from `org` exactly when this binding is a shared one, and
    /// that difference is the genuinely surprising thing about a shared
    /// account: a plain `claude` session started there runs as `homeOrg`.
    public var homeOrg: String
    /// Whether this row belongs to the organisation the operator is
    /// standing in. A row that is not is **read-only here** — this pane
    /// never writes across the boundary that defines an organisation —
    /// and offers Adopt instead (#201).
    public var mine: Bool
    /// The agent executable this account's liveness was read with,
    /// resolved by Go from the full provider record (#238).
    ///
    /// **The surface needs it to spawn a sign-in**, and has no other way
    /// to name it: `Process.executableURL` does not search PATH, and a GUI
    /// launched from Finder inherits launchd's minimal one. A bare
    /// `claude` therefore resolved to `/claude` and the sign-in failed
    /// naming a path nobody configured.
    public var binary: String
    public var credential: CredentialPresence
    /// Describes the **sign-in**, not the minted token. The surface must
    /// say so, or a red row reads as a broken session when it is not one.
    public var liveness: SignInLiveness

    /// Stable across a re-read, which the pane does on open and after
    /// every dispatch — so a row does not lose its identity, and the
    /// operator's place in the table, every time anything changes.
    public var id: String { "\(org)/\(accountId)" }

    /// The condition the pane exists to NAME: this organisation holds no
    /// credential for this binding.
    ///
    /// **From a check, not from session history**, and deliberately false
    /// when the Keychain could not be read at all: *could not look* and
    /// *is missing* are different facts, and reporting the first as the
    /// second sends an operator to repair an account that is fine.
    public var credentialLess: Bool {
        credential.readable && !credential.present && !credential.ref.isEmpty
    }

    public init(
        org: String, accountId: String, kind: String = "", label: String = "",
        configDir: String = "", homeOrg: String = "", mine: Bool = false, binary: String = "",
        credential: CredentialPresence = CredentialPresence(),
        liveness: SignInLiveness = SignInLiveness()
    ) {
        self.org = org
        self.accountId = accountId
        self.kind = kind
        self.label = label
        self.configDir = configDir
        self.binary = binary
        self.homeOrg = homeOrg
        self.mine = mine
        self.credential = credential
        self.liveness = liveness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        org = try container.decode(String.self, forKey: .org)
        accountId = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        configDir = try container.decodeIfPresent(String.self, forKey: .configDir) ?? ""
        binary = try container.decodeIfPresent(String.self, forKey: .binary) ?? ""
        homeOrg = try container.decodeIfPresent(String.self, forKey: .homeOrg) ?? ""
        mine = try container.decodeIfPresent(Bool.self, forKey: .mine) ?? false
        credential = try container.decodeIfPresent(CredentialPresence.self, forKey: .credential)
            ?? CredentialPresence()
        liveness = try container.decodeIfPresent(SignInLiveness.self, forKey: .liveness)
            ?? SignInLiveness()
    }

    private enum CodingKeys: String, CodingKey {
        case org, id, kind, label, configDir, binary, homeOrg, mine, credential, liveness
    }
}

/// A stored credential's reference and whether it is present. **Never its
/// value**, and there is no field here one could travel in.
public struct CredentialPresence: Sendable, Equatable, Decodable {
    /// The Keychain ENTRY NAME, which is not a secret and is exactly what
    /// an operator's own settings pane is for.
    public var ref: String
    public var present: Bool
    /// When the item was last WRITTEN — the Keychain's own `mdat`, and
    /// `nil` when the item is absent or its date could not be read.
    ///
    /// **`mdat`, not `cdat`, and that is measured.** A minted token's
    /// 365-day clock restarts when the operator re-authenticates;
    /// `cdat` survives a re-store, so reading it would show an operator
    /// who repaired an account yesterday a credential expiring next week.
    public var modified: Date?
    /// Whether the Keychain ANSWERED — so `present == false` means "there
    /// is no such item" rather than "the lookup failed".
    ///
    /// **Decoded from the wire, per row.** It was reconstructed here from
    /// the listing's whole-table `keychainUnavailable` at first, on the
    /// reasoning that that is the only way a lookup can fail. It is not: a
    /// single row's lookup can fail on a machine where the tool works
    /// fine — a locked keychain, a denied prompt — and reconstructing
    /// made that row decode as a MISSING credential, which is exactly the
    /// "could not look" / "is missing" conflation the row exists to keep
    /// apart. Go now carries it per row.
    public var readable: Bool

    public init(ref: String = "", present: Bool = false, modified: Date? = nil, readable: Bool = true) {
        self.ref = ref
        self.present = present
        self.modified = modified
        self.readable = readable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decodeIfPresent(String.self, forKey: .ref) ?? ""
        present = try container.decodeIfPresent(Bool.self, forKey: .present) ?? false
        if let raw = try container.decodeIfPresent(String.self, forKey: .modified) {
            modified = parseAccountDate(raw)
        }
        readable = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
    }

    private enum CodingKeys: String, CodingKey { case ref, present, modified, checked }

    /// When a minted token stops working, or `nil` when the date is
    /// unknown — so the pane can draw "unknown" rather than a date in
    /// 1970, which reads as a fact rather than as an absence.
    public func expiry(after lifetime: TimeInterval = mintedTokenLifetime) -> Date? {
        modified.map { $0.addingTimeInterval(lifetime) }
    }
}

/// Parses the RFC 3339 timestamp Go marshals a `time.Time` as.
///
/// **A fresh formatter per call, not a shared one.**
/// `ISO8601DateFormatter` is not `Sendable` — it may hold mutable state —
/// and this decodes on whatever task the dispatch landed on, so a shared
/// instance is a data race the compiler correctly refuses. Caching it
/// behind a lock to save a construction per account, on a table of a
/// handful of rows read at human speed, would be buying nothing with a
/// concurrency primitive.
///
/// **Both shapes are tried**, because whether Go emits fractional seconds
/// depends on the value rather than on the encoder, and a timestamp that
/// fails to parse becomes `nil` — which the pane draws as "unknown", a
/// strictly worse answer than the one that was available.
private func parseAccountDate(_ raw: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: raw) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: raw)
}

/// How long a `claude setup-token` credential lasts. **365 days, not
/// forever.**
public let mintedTokenLifetime: TimeInterval = 365 * 24 * 60 * 60

/// What the CLI says about a config directory's sign-in.
///
/// **An identity signal, not a capability signal.** It describes the
/// operator's sign-in, never the minted token — and the minted token is
/// what launches sessions, so a directory whose sign-in has lapsed still
/// works. The surface must label it accordingly.
public struct SignInLiveness: Sendable, Equatable, Decodable {
    public var loggedIn: Bool
    public var authMethod: String
    public var email: String
    public var orgName: String
    public var subscriptionType: String
    /// Why the read did not happen. A read that could not run and a
    /// directory that is logged out are different facts.
    public var failure: String

    public init(
        loggedIn: Bool = false, authMethod: String = "", email: String = "",
        orgName: String = "", subscriptionType: String = "", failure: String = ""
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.failure = failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
        authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName) ?? ""
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType) ?? ""
        failure = try container.decodeIfPresent(String.self, forKey: .failure) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case loggedIn, authMethod, email, orgName, subscriptionType, failure
    }

    /// Whether the CLI named whose sign-in this is.
    ///
    /// Measured: a lapsed directory reports logged out with **no identity
    /// at all**, so the two arrive together or not at all — and there is
    /// nothing to offer a `Continue as <email>` for on a dead directory.
    public var hasIdentity: Bool { !email.isEmpty }

    /// How many browser trips re-authenticating costs: one when the
    /// sign-in is live and names somebody, two otherwise.
    ///
    /// **Derived from liveness, not from the directory existing.** Under
    /// the rejected reading, pressing Re-authenticate on a red row
    /// succeeded and LEFT THE ROW RED, because nothing on a mint-only path
    /// writes the sign-in. #205 ships the flow; the number lives here
    /// because it is a property of the reading.
    public var tripsToRepair: Int { loggedIn && hasIdentity ? 1 : 2 }
}

/// The whole table, plus what could not be read.
public struct AccountListing: Sendable, Equatable, Decodable {
    public var accounts: [Account]
    /// Organisations whose records could not be read. **Named rather than
    /// dropped** — an empty table beside a non-empty `skipped` means
    /// "could not look", never "there are none".
    public var skipped: [String]
    /// The Keychain tool could not be run at all, so every row's
    /// credential reports absent. Drawn as one line about the machine
    /// rather than as a broken badge per row — "every account on this
    /// machine is broken" is the single most alarming and least true thing
    /// this pane could say.
    public var keychainUnavailable: Bool

    public init(accounts: [Account] = [], skipped: [String] = [], keychainUnavailable: Bool = false) {
        self.accounts = accounts
        self.skipped = skipped
        self.keychainUnavailable = keychainUnavailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        keychainUnavailable = try container.decodeIfPresent(Bool.self, forKey: .keychainUnavailable) ?? false
        // Each row carries its own `checked`. The whole-table flag only
        // FORCES it false — a Keychain tool that could not be run at all
        // means no row was checked, whatever any row claims — and never
        // true, which is the direction that would reintroduce the
        // conflation.
        if keychainUnavailable {
            accounts = decoded.map { account in
                var row = account
                row.credential.readable = false
                return row
            }
        } else {
            accounts = decoded
        }
    }

    private enum CodingKeys: String, CodingKey { case accounts, skipped, keychainUnavailable }

    /// Every binding this organisation holds that is missing its
    /// credential — what the pane names, so the operator learns what is
    /// broken by looking rather than by a window failing to start.
    public var credentialLess: [Account] {
        accounts.filter { $0.mine && $0.credentialLess }
    }

    /// The same check, for bindings this organisation does not hold.
    ///
    /// **The table stops drawing other organisations' bindings as rows
    /// (#236), and this is what keeps that from re-opening a hole #200
    /// closed.** The organisation plane's own credential-less warning was
    /// deleted because this pane replaced it; a pane scoped to the open
    /// organisation would then warn about nothing, on a machine where
    /// four of the ten bindings have no stored credential and none of
    /// them is `personal`'s.
    ///
    /// Named rather than drawn, because naming is the part that was
    /// load-bearing: the operator needs to know the binding is broken
    /// before they switch into the organisation that holds it, and
    /// repairing it there is a different gesture in a different place.
    public var credentialLessElsewhere: [Account] {
        accounts.filter { !$0.mine && $0.credentialLess }
    }

    /// The accounts an operator could still adopt: **one entry per
    /// config dir, and none this organisation already holds.**
    ///
    /// **Per directory, because the directory is the account.** Five
    /// bindings on this machine point at `~/.claude-initech`; offering all
    /// five would ask the operator to choose between entries differing
    /// only in which other organisation happens to hold them. The adopt
    /// path copies a credential from a named source binding, so each
    /// entry keeps the binding it came from — the LIST dedupes, the
    /// adoption does not.
    ///
    /// **And never one already bound here**, which is not a tidiness
    /// rule: `personal` holds `main`, `work` and `umbrella-main`, and
    /// those three cover all three directories on this machine. A door
    /// counting bindings rather than accounts would offer "3 not in this
    /// organisation" when the true answer is none — the exact
    /// id-is-not-an-account confusion this ticket exists to remove.
    public var adoptable: [Account] {
        let held = Set(accounts.filter { $0.mine && !$0.configDir.isEmpty }.map(\.configDir))
        var chosen: [String: Account] = [:]
        var order: [String] = []
        for account in accounts where !account.mine {
            if held.contains(account.configDir) { continue }
            // A binding with no directory cannot collide with another,
            // and is its own entry.
            let key = account.configDir.isEmpty
                ? "\(account.org)/\(account.accountId)" : account.configDir
            guard let existing = chosen[key] else {
                chosen[key] = account
                order.append(key)
                continue
            }
            // **A source that HAS a credential wins** (#271). Adoption
            // copies the credential from the binding this entry names, so
            // offering the first one seen could offer the one binding of
            // that directory whose copy is guaranteed to fail — on this
            // machine `umbrella/umbrella-initech` has none and `initech/main`, the
            // same directory, does. Dedupe still answers one entry per
            // ACCOUNT; this only decides which binding speaks for it.
            if !existing.credential.present && account.credential.present {
                chosen[key] = account
            }
        }
        return order.compactMap { chosen[$0] }
    }
}

/// Decodes `ctx_list_accounts`'s reply.
///
/// **Extracted and tested directly**, the phase's standing rule for a
/// decoder, and it **refuses rather than passing a half-read table on**:
/// `nil` means the reply was not an account listing, and the pane says so.
/// An empty listing returned for a malformed reply would draw "this
/// machine has no accounts", which is a sentence about the operator's
/// machine that may be false.
public func decodeAccountListing(fromResult result: JSONValue?) -> AccountListing? {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          structured["accounts"] != nil
    else { return nil }
    guard let data = try? JSONEncoder().encode(JSONValue.object(structured)) else { return nil }
    return try? JSONDecoder().decode(AccountListing.self, from: data)
}
