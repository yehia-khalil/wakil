import Testing
import Foundation
@testable import WakilKit

/// **The account table's Swift half** (#200): the decoder, and the three
/// facts a row has to carry without lying.
///
/// The Go half — the Keychain presence lookup that reads no value, the
/// `mdat`-not-`cdat` rule, the liveness read with the OAuth token absent —
/// is pinned in `internal/wakilcore/accounts_test.go` against fake
/// binaries. What is pinned here is what survives the wire.

private func listing(_ structured: [String: JSONValue]) -> JSONValue {
    .object(["structuredContent": .object(structured)])
}

private let oneAccount: [String: JSONValue] = [
    "accounts": .array([
        .object([
            "org": .string("acme"), "id": .string("main"),
            "kind": .string("claude-code"), "label": .string("Main"),
            "configDir": .string("/Users/x/.claude-main"),
            "mine": .bool(true),
            "credential": .object([
                "ref": .string("provider:main"), "present": .bool(true),
                "modified": .string("2026-09-22T13:02:57Z"),
            ]),
            "liveness": .object([
                "loggedIn": .bool(true), "authMethod": .string("claude.ai"),
                "email": .string("someone@example.test"),
                "orgName": .string("example.test"),
                "subscriptionType": .string("enterprise"),
            ]),
        ]),
    ]),
]

// MARK: - The decoder

@Test func decodingAnAccountKeepsItsCredentialAndItsLiveness() throws {
    guard let table = decodeAccountListing(fromResult: listing(oneAccount)) else {
        Issue.record("the listing did not decode"); return
    }
    guard let row = table.accounts.first else {
        Issue.record("no rows"); return
    }
    #expect(row.accountId == "main")
    #expect(row.kind == "claude-code")
    #expect(row.mine)
    // The reference travels; a value has nowhere to travel in.
    #expect(row.credential.ref == "provider:main")
    #expect(row.credential.present)
    #expect(row.liveness.loggedIn)
    #expect(row.liveness.hasIdentity)
}

/// The minted token's age is a **date**, so a 365-day clock is visible
/// rather than guessed at — and it runs from the Keychain item's own
/// modification date.
@Test func aMintedTokensExpiryIsAYearAfterTheKeychainItemWasWritten() throws {
    guard let table = decodeAccountListing(fromResult: listing(oneAccount)),
          let row = table.accounts.first, let modified = row.credential.modified
    else {
        Issue.record("the modification date did not decode"); return
    }
    guard let expiry = row.credential.expiry() else {
        Issue.record("no expiry"); return
    }
    #expect(abs(expiry.timeIntervalSince(modified) - mintedTokenLifetime) < 1)
}

/// **A wrong date is worse than no date**, because it is the one fact on
/// the row an operator plans against. An absent or unparseable timestamp
/// yields `nil`, which the pane draws as "expiry unknown" rather than as a
/// credential minted in 1970.
@Test func anUnreadableModificationDateGivesNoExpiryRatherThanTheEpoch() throws {
    for raw in [JSONValue.string("not a date"), .string(""), .null] {
        let reply = listing([
            "accounts": .array([
                .object([
                    "org": .string("acme"), "id": .string("main"),
                    "credential": .object([
                        "ref": .string("provider:main"), "present": .bool(true),
                        "modified": raw,
                    ]),
                ]),
            ]),
        ])
        guard let row = decodeAccountListing(fromResult: reply)?.accounts.first else {
            Issue.record("did not decode \(raw)"); return
        }
        #expect(row.credential.modified == nil, "\(raw)")
        #expect(row.credential.expiry() == nil, "\(raw)")
    }
}

/// It refuses rather than passing a half-read table on. An empty listing
/// returned for a malformed reply would draw "this machine has no
/// accounts" — a sentence about the operator's machine that may be false.
@Test func aReplyThatIsNotAnAccountListingDecodesToNil() throws {
    #expect(decodeAccountListing(fromResult: nil) == nil)
    #expect(decodeAccountListing(fromResult: .object([:])) == nil)
    #expect(decodeAccountListing(fromResult: .object(["structuredContent": .object([:])])) == nil,
            "a structuredContent with no accounts key is not an account listing")
    #expect(decodeAccountListing(fromResult: .string("nope")) == nil)
}

/// An organisation with no accounts is a real, ordinary answer and must
/// decode — distinct from a reply that is not a listing at all.
@Test func anEmptyButWellFormedListingDecodes() throws {
    guard let table = decodeAccountListing(fromResult: listing(["accounts": .array([])])) else {
        Issue.record("an empty listing must decode"); return
    }
    #expect(table.accounts.isEmpty)
    #expect(table.credentialLess.isEmpty)
}

// MARK: - Missing versus could-not-look

/// **The condition the pane exists to NAME**, and it comes from a check.
@Test func abindingWithNoStoredCredentialIsNamed() throws {
    let reply = listing([
        "accounts": .array([
            .object([
                "org": .string("acme"), "id": .string("main"), "mine": .bool(true),
                // `checked: true` is the Keychain ANSWERING and finding
                // nothing — which is what makes this a missing credential
                // rather than a lookup that failed. An absent `checked`
                // now means "not checked", which is the safe default.
                "credential": .object([
                    "ref": .string("provider:main"), "present": .bool(false),
                    "checked": .bool(true),
                ]),
            ]),
        ]),
    ])
    guard let table = decodeAccountListing(fromResult: reply) else {
        Issue.record("did not decode"); return
    }
    #expect(table.accounts[0].credentialLess)
    #expect(table.credentialLess.map(\.accountId) == ["main"])
}

/// **"Could not look" is not "is missing."** When the Keychain tool could
/// not be run at all, every row reports absent — and drawing that as a
/// missing credential per row would tell the operator every account on
/// their machine is broken, which is the single most alarming and least
/// true thing this pane could say.
@Test func aTableThatCouldNotCheckTheKeychainNamesNothingAsMissing() throws {
    let reply = listing([
        "keychainUnavailable": .bool(true),
        "accounts": .array([
            .object([
                "org": .string("acme"), "id": .string("main"), "mine": .bool(true),
                // Even a row CLAIMING it was checked is forced to
                // unchecked by the table-level flag: the whole-table flag
                // only ever forces it false, never true.
                "credential": .object([
                    "ref": .string("provider:main"), "present": .bool(false),
                    "checked": .bool(true),
                ]),
            ]),
        ]),
    ])
    guard let table = decodeAccountListing(fromResult: reply) else {
        Issue.record("did not decode"); return
    }
    #expect(table.keychainUnavailable)
    #expect(!table.accounts[0].credential.readable)
    #expect(!table.accounts[0].credentialLess,
            "a credential that could not be CHECKED must not report as missing")
    #expect(table.credentialLess.isEmpty)
}

/// A binding in another organisation is a row here — so adopting it is a
/// gesture rather than a search — but it is not THIS organisation's
/// problem to repair, so it never appears in the credential-less list the
/// pane warns about.
@Test func aRowHomedElsewhereIsListedButIsNotThisOrganisationsToRepair() throws {
    let reply = listing([
        "accounts": .array([
            .object([
                "org": .string("other"), "id": .string("elsewhere"), "mine": .bool(false),
                "credential": .object([
                    "ref": .string("provider:elsewhere"), "present": .bool(false),
                    "checked": .bool(true),
                ]),
            ]),
        ]),
    ])
    guard let table = decodeAccountListing(fromResult: reply) else {
        Issue.record("did not decode"); return
    }
    #expect(table.accounts.count == 1)
    #expect(!table.accounts[0].mine)
    #expect(table.credentialLess.isEmpty)
}

// MARK: - Liveness is an identity signal

/// A lapsed directory reports logged out with **no identity at all** —
/// measured twice, four days and one CLI version apart. So there is
/// nothing to offer a `Continue as <email>` for, and the repair costs two
/// trips, the FIRST of which is the one that clears the red.
@Test func aLapsedSignInHasNoIdentityAndCostsTwoTrips() throws {
    let lapsed = SignInLiveness(loggedIn: false, authMethod: "none")
    #expect(!lapsed.hasIdentity)
    #expect(lapsed.tripsToRepair == 2)

    let live = SignInLiveness(loggedIn: true, authMethod: "claude.ai", email: "x@example.test")
    #expect(live.hasIdentity)
    #expect(live.tripsToRepair == 1)
}

/// **The trip count derives from liveness, not from the directory
/// existing.** Under the rejected reading, pressing Re-authenticate on a
/// red row succeeded and LEFT THE ROW RED, because nothing on a mint-only
/// path writes the sign-in. A directory that reports logged in without an
/// identity — which is what a poisoned read looks like — still costs two.
@Test func loggedInWithoutAnIdentityStillCostsTwoTrips() throws {
    let poisoned = SignInLiveness(loggedIn: true, authMethod: "oauth_token")
    #expect(!poisoned.hasIdentity)
    #expect(poisoned.tripsToRepair == 2)
}

/// A read that could not run says nothing about the account. Drawing it as
/// "logged out" would tell the operator their account had lapsed when
/// nothing of the kind was established.
@Test func aLivenessFailureIsNotALoggedOutAccount() throws {
    let reply = listing([
        "accounts": .array([
            .object([
                "org": .string("acme"), "id": .string("main"),
                "liveness": .object(["loggedIn": .bool(false), "failure": .string("boom")]),
            ]),
        ]),
    ])
    guard let row = decodeAccountListing(fromResult: reply)?.accounts.first else {
        Issue.record("did not decode"); return
    }
    #expect(row.liveness.failure == "boom")
    #expect(!row.liveness.loggedIn)
}

// MARK: - Reachability

/// Operator-only on `ctx_list_machine_providers`' own reasoning — a
/// session scoped to ONE organisation has no business enumerating every
/// account and config dir on the machine, and a Keychain presence check
/// per row makes that objection no weaker.
///
/// The agent is not thereby blind to settings: `ctx_config_tree` answers
/// the ACTIVE organisation's own accounts and stays agent-reachable.
@Test func theAccountTableIsOperatorOnlyAndTheConfigTreeIsNot() throws {
    #expect(operatorOnlyActions.contains("ctx_list_accounts"))
    #expect(!operatorOnlyActions.contains("ctx_config_tree"))

    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_list_accounts",
        knownActions: ["ctx_list_accounts", "ctx_config_tree"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_list_accounts must be denied, got \(decision)"); return
    }
    // The session-scope family's sentence, not the boundary family's — a
    // true sentence about the wrong family answers a question the agent
    // never asked.
    #expect(reason.contains("scoped to one organisation"))
}

// MARK: - Adoption names its source (#201)

/// A `ToolCaller` that records what it was asked, so a test can assert on
/// the arguments that reached Go.
private actor AdoptRecorder: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object(["credentialCopied": .bool(true)])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func adoptRegistry() async throws -> (ActionRegistry, AdoptRecorder) {
    let caller = AdoptRecorder()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "adopt")
    await registerStandardActions(
        into: registry, context: caller, panes: PaneStore(), db: nil,
        resumes: ResumeBroker(), providerSwitches: ProviderSwitchBroker())
    return (registry, caller)
}

/// **Naming the source is what makes an adoption instant.** The credential
/// is copied Keychain-to-Keychain in Go from the binding named here, so no
/// browser opens — possible only because the minted token is kept.
@Test func adoptForwardsTheSourceBindingSoTheCredentialCanBeCopied() async throws {
    let (registry, caller) = try await adoptRegistry()

    _ = try await registry.dispatch(
        name: "ctx_adopt_provider",
        params: .object([
            "org": .string("personal"), "id": .string("work"),
            "configDir": .string("/Users/x/.claude-initech"), "kind": .string("claude-code"),
            "fromOrg": .string("initech"), "fromId": .string("main"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one adopt_provider call, got \(calls)"); return
    }
    #expect(arguments["fromOrg"] == .string("initech"))
    #expect(arguments["fromId"] == .string("main"))
}

/// **Absent means copy nothing**, which is the honest shape for a caller
/// with no source — rather than a silent default to some other
/// organisation's Keychain item. The organisation plane's own Adopt still
/// sends none, and must keep working.
@Test func adoptWithoutASourceForwardsNoneAndStillSucceeds() async throws {
    let (registry, caller) = try await adoptRegistry()

    _ = try await registry.dispatch(
        name: "ctx_adopt_provider",
        params: .object([
            "org": .string("personal"), "id": .string("work"),
            "configDir": .string("/Users/x/.claude-initech"), "kind": .string("claude-code"),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one adopt_provider call, got \(calls)"); return
    }
    #expect(arguments["fromOrg"] == nil)
    #expect(arguments["fromId"] == nil)
    #expect(Set(arguments.keys) == ["org", "id", "configDir", "kind"])
}

/// An empty string is not a source. Forwarding one would have Go read
/// `wakil::provider:main` — a service name with no organisation in it,
/// which is the shape Invariant 4's scoping exists to make impossible.
@Test func anEmptySourceIsNotForwarded() async throws {
    let (registry, caller) = try await adoptRegistry()

    _ = try await registry.dispatch(
        name: "ctx_adopt_provider",
        params: .object([
            "org": .string("personal"), "id": .string("work"),
            "configDir": .string("/Users/x/.claude-initech"), "kind": .string("claude-code"),
            "fromOrg": .string(""), "fromId": .string(""),
        ]),
        origin: .ui, caller: .test("staging"), confirmation: nil)

    let calls = await caller.recorded()
    guard calls.count == 1, case .object(let arguments) = calls[0].arguments else {
        Issue.record("expected one adopt_provider call, got \(calls)"); return
    }
    #expect(arguments["fromOrg"] == nil)
    #expect(arguments["fromId"] == nil)
}

/// Still operator-only, and for the unchanged reason: adopting an account
/// into an organisation moves the credential boundary an organisation IS.
/// Copying a credential as part of it makes that objection no weaker.
@Test func adoptRemainsOperatorOnlyNowThatItCopiesACredential() async throws {
    #expect(operatorOnlyActions.contains("ctx_adopt_provider"))
    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_adopt_provider", knownActions: ["ctx_adopt_provider"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_adopt_provider must be denied, got \(decision)"); return
    }
    #expect(reason.contains("credential boundary"))
}

// MARK: - Unlink (#206)

/// The report decodes, and the permanent sentence survives the wire.
@Test func anUnlinkReportCarriesWhatItCouldNotDestroy() throws {
    let reply = JSONValue.object(["structuredContent": .object([
        "recordRemoved": .bool(true),
        "credentialRemoved": .bool(true),
        "wasLastBinding": .bool(true),
        "configDir": .string("/Users/x/.claude-main"),
        "pointersCleared": .array([.string("org.json defaultProvider")]),
        "backfilled": .array([.string("personal/work")]),
        "notes": .array([.string("Wakil removed this organisation's stored credential…")]),
    ])])
    guard let report = decodeUnlinkReport(fromResult: reply) else {
        Issue.record("the report did not decode"); return
    }
    #expect(report.recordRemoved)
    #expect(report.credentialRemoved)
    #expect(report.wasLastBinding)
    #expect(report.pointersCleared == ["org.json defaultProvider"])
    #expect(report.backfilled == ["personal/work"])
    #expect(report.configDir == "/Users/x/.claude-main")
    #expect(!report.notes.isEmpty)
}

/// It refuses rather than reporting a row of zeroes — which would read as
/// "nothing was removed" for an unlink whose result is simply unknown.
@Test func aReplyThatIsNotAnUnlinkReportDecodesToNil() throws {
    #expect(decodeUnlinkReport(fromResult: nil) == nil)
    #expect(decodeUnlinkReport(fromResult: .object(["structuredContent": .object([:])])) == nil)
    #expect(decodeUnlinkReport(fromResult: .string("nope")) == nil)
}

/// **The confirmation states what will NOT be destroyed**, because that is
/// the part an operator otherwise assumes — and it renders the account id
/// and nothing that could be a secret.
@Test func theUnlinkConfirmationSaysWhatSurvives() throws {
    let account = Account(org: "acme", accountId: "main", kind: "claude-code")
    let sentence = UnlinkWording.confirmation(for: account)

    #expect(sentence.contains("main"))
    #expect(sentence.contains("acme"))
    // What survives: the directory, and the credential Wakil cannot
    // destroy.
    #expect(sentence.contains("config"))
    #expect(sentence.contains("cannot destroy"))
    #expect(sentence.contains("Anthropic"))
}

/// **The revocation offer warns that the CLI lies.** `claude auth logout`
/// prints success when it revoked nothing, so anything shelling out to it
/// reports a revocation it did not perform.
@Test func theRevocationOfferWarnsThatSuccessMayBeFalse() throws {
    let offer = UnlinkWording.revocationOffer
    #expect(offer.contains("not reliable"))
    #expect(offer.contains("revoked nothing"))
    // And it is an offer — it never says Wakil did it.
    #expect(!offer.lowercased().contains("wakil revoked"))
}

/// Operator-only, on the boundary family's reason: removing a binding
/// moves what an organisation can reach.
@Test func unlinkingIsOperatorOnly() throws {
    #expect(operatorOnlyActions.contains("ctx_unlink_provider"))
    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_unlink_provider", knownActions: ["ctx_unlink_provider"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_unlink_provider must be denied, got \(decision)"); return
    }
    #expect(reason.contains("credential boundary"))
}


/// **A row whose OWN lookup failed is not reported missing** — the review
/// finding, from the decoding side.
///
/// `readable` was reconstructed from the whole-table `keychainUnavailable`
/// at first, on the reasoning that that is the only way a lookup can fail.
/// It is not: a single row can fail on a machine where the tool works
/// fine. Go now carries `checked` per row, and an ABSENT one means "not
/// checked" rather than "checked and empty".
@Test func aRowThatWasNeverCheckedIsNotReportedMissing() throws {
    let reply = listing([
        "accounts": .array([
            .object([
                "org": .string("acme"), "id": .string("main"), "mine": .bool(true),
                // The table is fine; this ROW's lookup failed.
                "credential": .object([
                    "ref": .string("provider:main"), "present": .bool(false),
                    "checked": .bool(false),
                ]),
            ]),
        ]),
    ])
    guard let table = decodeAccountListing(fromResult: reply) else {
        Issue.record("did not decode"); return
    }
    #expect(!table.keychainUnavailable, "the table is fine; only this row failed")
    #expect(!table.accounts[0].credential.readable)
    #expect(!table.accounts[0].credentialLess,
            "a row whose own lookup failed was reported as missing its credential")
    #expect(table.credentialLess.isEmpty)
}

// ---------------------------------------------------------------------
// #236 — this organisation's bindings, and what the Adopt door offers
// ---------------------------------------------------------------------

/// This machine's actual shape, which is the whole reason for #236:
/// **ten bindings over three accounts**, five of them called `main`.
private func thisMachine() -> AccountListing {
    func row(_ org: String, _ id: String, _ dir: String, mine: Bool, present: Bool) -> Account {
        Account(
            org: org, accountId: id, kind: "claude-code", configDir: dir, mine: mine,
            credential: CredentialPresence(
                ref: "provider:\(id)", present: present, readable: true))
    }
    return AccountListing(accounts: [
        // personal's own three — one per directory, as it happens.
        row("personal", "main", "/h/.claude-personal", mine: true, present: true),
        row("personal", "work", "/h/.claude-initech", mine: true, present: true),
        row("personal", "umbrella-main", "/h/.claude-umbrella", mine: true, present: true),
        // Everyone else's seven.
        row("initech", "main", "/h/.claude-initech", mine: false, present: true),
        row("umbrella", "umbrella-initech", "/h/.claude-initech", mine: false, present: false),
        row("new-org", "initech-main", "/h/.claude-initech", mine: false, present: false),
        row("wakil-2civ-demo", "work", "/h/.claude-initech", mine: false, present: false),
        row("umbrella", "main", "/h/.claude-umbrella", mine: false, present: true),
        row("acceptance-b", "main", "/h/.claude-personal", mine: false, present: true),
        row("test-org", "main", "/h/.claude-personal", mine: false, present: false),
    ])
}

/// **The door counts ACCOUNTS, not bindings, and subtracts the ones
/// already held.** Seven bindings are not this organisation's, over three
/// directories — and `personal` already holds all three. So there is
/// nothing to adopt, and a door advertising "7" or even "3" would be
/// repeating the id-is-not-an-account confusion this ticket removes.
@Test func anOrganisationHoldingEveryDirectoryHasNothingLeftToAdopt() {
    #expect(thisMachine().adoptable.isEmpty)
}

/// One directory short: drop `personal`'s binding to `~/.claude-initech` and
/// exactly one entry appears, though FOUR other bindings point there.
@Test func theAdoptDoorOffersOneEntryPerDirectoryRatherThanPerBinding() {
    var machine = thisMachine()
    machine.accounts.removeAll { $0.mine && $0.configDir == "/h/.claude-initech" }

    let offered = machine.adoptable
    #expect(offered.count == 1, "four bindings share that directory; it is ONE account")
    #expect(offered.first?.configDir == "/h/.claude-initech")
}

/// **Scoping the table must not stop the pane naming what is broken.**
/// #200 deleted the organisation plane's session-based warning because
/// this pane replaced it. All four credential-less bindings on this
/// machine belong to other organisations, so a pane that only looked at
/// its own would warn about nothing at all.
@Test func credentialLessBindingsElsewhereAreStillNamed() {
    let machine = thisMachine()
    #expect(machine.credentialLess.isEmpty, "personal's own three are all present")

    let elsewhere = machine.credentialLessElsewhere.map { "\($0.org)/\($0.accountId)" }
    #expect(elsewhere == [
        "umbrella/umbrella-initech", "new-org/initech-main", "wakil-2civ-demo/work", "test-org/main",
    ])
}

/// A row whose own lookup failed is not "missing elsewhere" either — the
/// same distinction `credentialLess` draws, on the other side of `mine`.
@Test func anUncheckedRowElsewhereIsNotReportedMissing() {
    let unchecked = Account(
        org: "other", accountId: "main", mine: false,
        credential: CredentialPresence(ref: "provider:main", present: false, readable: false))
    #expect(AccountListing(accounts: [unchecked]).credentialLessElsewhere.isEmpty)
}

/// **The Adopt door must not offer a source whose credential copy is
/// guaranteed to fail** (#271, found by review).
///
/// Adoption copies the credential from the binding the entry names, and
/// the dedupe took the first binding seen for a directory. On this machine
/// `umbrella/umbrella-initech` has no credential and `initech/main` — the same
/// directory — does, so first-seen could offer the one that cannot work.
@Test func theAdoptDoorPrefersASourceThatHasACredential() {
    func row(_ org: String, _ id: String, present: Bool) -> Account {
        Account(
            org: org, accountId: id, configDir: "/h/.claude-initech", mine: false,
            credential: CredentialPresence(
                ref: "provider:\(id)", present: present, readable: true))
    }
    // The credential-less one is FIRST, so first-seen would pick it.
    let machine = AccountListing(accounts: [
        row("umbrella", "umbrella-initech", present: false),
        row("initech", "main", present: true),
    ])

    let offered = machine.adoptable
    #expect(offered.count == 1, "one directory is one account")
    #expect(offered.first?.accountId == "main",
            "offered a source with no credential to copy")
}

/// And it still answers one entry per directory when every binding is
/// equally usable — the dedupe is not weakened by the preference.
@Test func theAdoptDoorStillAnswersOnePerDirectory() {
    func row(_ org: String, _ id: String) -> Account {
        Account(
            org: org, accountId: id, configDir: "/h/.claude-initech", mine: false,
            credential: CredentialPresence(ref: "provider:\(id)", present: true, readable: true))
    }
    let machine = AccountListing(accounts: [row("a", "one"), row("b", "two"), row("c", "three")])
    #expect(machine.adoptable.count == 1)
}
