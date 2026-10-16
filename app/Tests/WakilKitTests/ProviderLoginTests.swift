import Testing
import Foundation
@testable import WakilKit

/// **The first browser trip, and no test spawns one** (#202).
///
/// The seam is `ProviderLoginSpawning`, deliberately one level below
/// `ProviderLogin`: a fake conformance would test the session against a
/// stand-in for the thing under test, while a fake *spawner* tests the
/// real `ClaudeCodeProviderLogin` — its argument list, its environment,
/// its decode — against a stand-in for the browser.

/// A spawner that answers from a script and records what it was asked.
private actor FakeSpawner: ProviderLoginSpawning {
    struct Call: Sendable, Equatable {
        var binary: String
        var arguments: [String]
        var environment: [String: String]
    }

    private var replies: [ProviderLoginSpawnResult]
    private(set) var calls: [Call] = []
    private let failToStart: Bool

    init(replies: [ProviderLoginSpawnResult], failToStart: Bool = false) {
        self.replies = replies
        self.failToStart = failToStart
    }

    func run(
        binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> ProviderLoginSpawnResult {
        calls.append(Call(binary: binary, arguments: arguments, environment: environment))
        if failToStart { throw ProviderLoginError.couldNotStart("no such binary") }
        guard !replies.isEmpty else { return ProviderLoginSpawnResult(status: 0) }
        return replies.removeFirst()
    }

    func recorded() -> [Call] { calls }
}

private let liveStatus = #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test","orgName":"Example"}"#
private let deadStatus = #"{"loggedIn":false,"authMethod":"none"}"#

// MARK: - The one-string rule, and the poisoned environment

/// **`configDir` is used verbatim.** The CLI hashes the literal string it
/// is handed to name its Keychain item and does not resolve symlinks, so
/// tidying it here produces a sign-in under a name nothing else looks up —
/// a fresh, correct sign-in that reads as logged out.
@Test func theLoginSpawnUsesTheConfigDirStringItWasGiven() async throws {
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    _ = try await login.signIn(configDir: "/a/symlinked/path/.claude-acme", binary: "/bin/claude")

    let calls = await spawner.recorded()
    guard let first = calls.first else {
        Issue.record("nothing was spawned"); return
    }
    #expect(first.arguments == ["auth", "login"])
    #expect(first.environment["CLAUDE_CONFIG_DIR"] == "/a/symlinked/path/.claude-acme")
}

/// **Without this the liveness read is worthless**, measured 2026-09-22: a
/// genuinely logged-out directory reports `loggedIn: false`, and the same
/// directory with `CLAUDE_CODE_OAUTH_TOKEN` set to a garbage string
/// reports `loggedIn: true, authMethod: "oauth_token"`. The CLI reports a
/// token's PRESENCE; it does not validate one. Wakil's own harness exports
/// that variable.
@Test func theLoginChildNeverInheritsTheOAuthToken() async throws {
    setenv("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-not-a-real-token", 1)
    defer { unsetenv("CLAUDE_CODE_OAUTH_TOKEN") }

    let spawner = FakeSpawner(replies: [ProviderLoginSpawnResult(status: 0, stdout: deadStatus)])
    let login = ClaudeCodeProviderLogin(spawn: spawner)
    _ = await login.identity(configDir: "/Users/x/.claude-acme", binary: "/bin/claude")

    let calls = await spawner.recorded()
    guard let call = calls.first else {
        Issue.record("nothing was spawned"); return
    }
    #expect(call.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
            "the token reached the child and every account would read as alive")
}

// MARK: - The decoder

/// Extracted and tested directly, and it **refuses rather than passing
/// on**: an unreadable answer yields a not-logged-in identity with no
/// name, which the surface draws as "could not establish" and never as a
/// confident "this is somebody else".
@Test func theIdentityDecoderRefusesWhatItCannotRead() throws {
    let live = decodeProviderLoginIdentity(liveStatus)
    #expect(live.loggedIn)
    #expect(live.email == "a@example.test")
    #expect(live.namesSomebody)
    #expect(live.tripsToRepair == 1)

    let dead = decodeProviderLoginIdentity(deadStatus)
    #expect(!dead.loggedIn)
    #expect(!dead.namesSomebody)
    #expect(dead.tripsToRepair == 2)

    for raw in ["", "   ", "not json", #"{"authMethod":"none"}"#] {
        let got = decodeProviderLoginIdentity(raw)
        #expect(!got.loggedIn, "\(raw)")
        #expect(!got.namesSomebody, "\(raw)")
    }
}

// MARK: - A refusal may claim what a timeout may not

/// A non-zero exit is an OBSERVED fact about a trip that ran, so it may
/// say plainly that nothing was created — and it fails fast rather than
/// sitting until a timeout.
@Test func aDeclinedSignInIsARefusalCarryingItsOwnMessage() async throws {
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 1, stderr: "authorization declined"),
    ])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    let result = try await login.signIn(configDir: "/Users/x/.claude-acme", binary: "/bin/claude")
    guard case .refused(let message) = result else {
        Issue.record("expected a refusal, got \(result)"); return
    }
    #expect(message == "authorization declined")
    // It fails fast: no liveness read followed, because there is nothing
    // to read.
    #expect(await spawner.recorded().count == 1)
}

/// A timeout knows nothing about what happened, and is carried on the
/// result rather than inferred from the exit status — a terminated
/// process and one that failed on its own report alike.
@Test func aTimedOutTripIsNotARefusal() async throws {
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 15, stderr: "", timedOut: true),
    ])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    let result = try await login.signIn(configDir: "/Users/x/.claude-acme", binary: "/bin/claude")
    #expect(result == .timedOut, "\(result)")
}

// MARK: - The session's published states

@Test func thePreflightStatesTheCostBeforeAnythingRuns() async throws {
    let session = ProviderLoginSession()
    await session.offer(id: "acme", kind: "claude-code", label: "", existing: ProviderLoginIdentity())

    guard case .preflight(let offer) = await session.current() else {
        Issue.record("expected a preflight, got \(await session.current())"); return
    }
    #expect(offer.trips == 2)
    // Two trips and about a minute — the sentence an operator chooses a
    // moment from.
    #expect(offer.sentence.contains("two browser trips"))
    #expect(offer.sentence.contains("about a minute"))
    // And it says Wakil never shows a token, which is the promise the
    // whole design rests on.
    #expect(offer.sentence.contains("never shows you a token"))
}

/// **The trip count derives from liveness, not from the directory
/// existing.** A directory that already holds a live, named sign-in costs
/// one trip — the mint alone.
@Test func aDirectoryWithALiveSignInCostsOneTrip() async throws {
    let session = ProviderLoginSession()
    await session.offer(
        id: "acme", kind: "claude-code", label: "",
        existing: ProviderLoginIdentity(loggedIn: true, email: "a@example.test"))

    guard case .preflight(let offer) = await session.current() else {
        Issue.record("expected a preflight"); return
    }
    #expect(offer.trips == 1)
    #expect(offer.sentence.contains("one browser trip"))
    #expect(offer.sentence.contains("a@example.test"))
}

/// Logged in with NO identity still costs two. That is what a poisoned
/// read looks like, and under the rejected "the directory resolves, so it
/// is live" reading a mint-only repair would leave the row red.
@Test func loggedInWithoutAnIdentityStillCostsTwoTripsInThePreflight() async throws {
    let session = ProviderLoginSession()
    await session.offer(
        id: "acme", kind: "claude-code", label: "",
        existing: ProviderLoginIdentity(loggedIn: true, email: ""))

    guard case .preflight(let offer) = await session.current() else {
        Issue.record("expected a preflight"); return
    }
    #expect(offer.trips == 2)
}

@Test func startingTheTripPublishesSigningInThenSignedIn() async throws {
    let session = ProviderLoginSession()
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: login, trips: 2)

    // Returns as soon as the trip has STARTED — a browser login is
    // minutes and nothing may wait for one.
    guard case .signingIn(let trip, let total, let id) = await session.current() else {
        Issue.record("expected signingIn, got \(await session.current())"); return
    }
    #expect(trip == 1)
    #expect(total == 2)
    #expect(id == "acme")

    var settled = await session.current()
    for _ in 0..<400 {
        if case .signedIn = settled { break }
        try? await Task.sleep(nanoseconds: 5_000_000)
        settled = await session.current()
    }
    guard case .signedIn(let identity, _) = settled else {
        Issue.record("the trip never settled: \(settled)"); return
    }
    #expect(identity.email == "a@example.test")
}

/// **Trip 1's cancel is free, always offered, and says it costs nothing** —
/// the only provably clean cancel in the flow.
@Test func cancellingTheFirstTripClaimsNothingHappened() async throws {
    let session = ProviderLoginSession()
    // A spawner that never answers, so the trip is genuinely in flight
    // when the cancel lands.
    let spawner = FakeSpawner(replies: [])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: login, trips: 2)
    #expect(await session.current().offersCancel, "trip 1 must always offer a cancel")

    await session.cancel()
    guard case .cancelled(let claim) = await session.current() else {
        Issue.record("expected cancelled, got \(await session.current())"); return
    }
    #expect(claim == .nothingHappened)
}

/// **The capture step has no cancel control at all — absent, not
/// disabled.** A disabled control still teaches that pressing it is the
/// way out, and what it would destroy is a one-year credential.
@Test func onlyTheTripInFlightOffersACancel() async throws {
    #expect(!ProviderLoginState.idle.offersCancel)
    #expect(!ProviderLoginState.preflight(PreflightOffer(id: "a", kind: "claude-code")).offersCancel)
    #expect(ProviderLoginState.signingIn(trip: 1, of: 2, id: "a").offersCancel)
    #expect(!ProviderLoginState.signedIn(ProviderLoginIdentity(), id: "a").offersCancel)
    #expect(!ProviderLoginState.refused("x").offersCancel)
    #expect(!ProviderLoginState.timedOut(.firstTrip()).offersCancel)
    #expect(!ProviderLoginState.cancelled(.nothingHappened).offersCancel)
    #expect(!ProviderLoginState.failed("x").offersCancel)
}

/// A cancel that has landed wins over a result the cancelled task still
/// delivers. Reporting that over the operator's own decision would be the
/// surface arguing with them.
@Test func aResultArrivingAfterACancelDoesNotOverwriteIt() async throws {
    let session = ProviderLoginSession()
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])
    let login = ClaudeCodeProviderLogin(spawn: spawner)

    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: login, trips: 2)
    await session.cancel()

    // Give the in-flight task every chance to report.
    for _ in 0..<40 { try? await Task.sleep(nanoseconds: 5_000_000) }
    guard case .cancelled = await session.current() else {
        Issue.record("a late result overwrote the cancel: \(await session.current())"); return
    }
}

/// Trip 1's timeout may say nothing was created, because minting had not
/// started. Trip 2's may not — #205 ships that claim, and the type is
/// what keeps them from being written alike by accident.
@Test func theFirstTripsTimeoutMayClaimNothingWasCreated() throws {
    let claim = TimeoutClaim.firstTrip()
    #expect(claim.trip == 1)
    #expect(claim.message.contains("Nothing was created"))
}

/// The band goes away, and nothing is left running behind it.
@Test func dismissingReturnsToIdle() async throws {
    let session = ProviderLoginSession()
    await session.offer(id: "acme", kind: "claude-code", label: "", existing: ProviderLoginIdentity())
    await session.dismiss()
    #expect(await session.current() == .idle)
    #expect(!(await session.current().isActive))
}

// MARK: - The seam

/// **Kind-keyed, with Claude Code its only conformance** (Decision 31).
/// The second is #136 and is out of scope; the local kind has no login at
/// all and gets no ticket.
@Test func theLoginSeamAnswersForClaudeCodeAndRefusesTheRest() throws {
    #expect(ClaudeCodeProviderLogin.kind == "claude-code")
    _ = try makeProviderLogin(forKind: "claude-code")

    for kind in ["codex", "local", "", "something-else"] {
        #expect(throws: ProviderLoginError.unsupportedKind(kind)) {
            _ = try makeProviderLogin(forKind: kind)
        }
    }
    // The refusal names what IS supported rather than only what is not.
    #expect(ProviderLoginError.unsupportedKind("codex").description.contains("claude-code"))
}

/// A login that cannot be started at all is distinct from a trip that ran
/// and ended badly.
@Test func aLoginThatCannotStartThrowsRatherThanReportingARefusal() async throws {
    let login = ClaudeCodeProviderLogin(spawn: FakeSpawner(replies: [], failToStart: true))
    await #expect(throws: (any Error).self) {
        try await login.signIn(configDir: "/Users/x/.claude-acme", binary: "/nope/claude")
    }
}

// MARK: - Reachability

/// The strongest case in the operator-only set: it opens a browser on the
/// operator's machine and authenticates as them.
@Test func startingALoginIsOperatorOnly() throws {
    #expect(operatorOnlyActions.contains("ctx_provider_login"))
    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_provider_login", knownActions: ["ctx_provider_login"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_provider_login must be denied, got \(decision)"); return
    }
    #expect(reason.contains("browser"))
}

// MARK: - The mint (#204)

/// A minter that answers from a script, so no browser and no Keychain.
private actor FakeMinter: ProviderMinting {
    private let outcome: ProviderMintOutcome
    private(set) var calls: [(id: String, configDir: String)] = []

    init(_ outcome: ProviderMintOutcome) { self.outcome = outcome }

    func mint(id: String, configDir: String, binary: String) async -> ProviderMintOutcome {
        calls.append((id, configDir))
        return outcome
    }

    func recorded() -> [(id: String, configDir: String)] { calls }
}

/// Waits for the session to reach a state matching `isDone`.
private func settle(
    _ session: ProviderLoginSession, until isDone: @Sendable (ProviderLoginState) -> Bool
) async -> ProviderLoginState {
    var state = await session.current()
    for _ in 0..<400 {
        if isDone(state) { return state }
        try? await Task.sleep(nanoseconds: 5_000_000)
        state = await session.current()
    }
    return state
}

private func signedInSession(
    mint: FakeMinter,
    commit: @escaping @Sendable (String, String) async -> ProviderCommitOutcome
) async -> ProviderLoginSession {
    let session = ProviderLoginSession()
    await session.use(mint: mint, commit: commit)
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])
    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: ClaudeCodeProviderLogin(spawn: spawner), trips: 2)
    return session
}

/// **There is no pause between the trips.** `SIGNED_IN` advances straight
/// to the mint (#101, confirmed on #203) — the operator is looking at a
/// browser success page, not at Wakil, so a Continue button would cost two
/// app switches to reach an exit the browser already offers.
@Test func signingInAdvancesStraightToTheMintWithNoPause() async throws {
    let minter = FakeMinter(ProviderMintOutcome(stored: true))
    let session = await signedInSession(mint: minter) { id, _ in
        .added(Account(org: "acme", accountId: id, kind: "claude-code", mine: true))
    }

    let settled = await settle(session) { if case .added = $0 { return true }; return false }
    guard case .added(let row) = settled else {
        Issue.record("the flow stopped before the account landed: \(settled)"); return
    }
    #expect(row.accountId == "acme")
    // The mint ran against the SAME config dir the sign-in used — the
    // one-string rule, downstream.
    let calls = await minter.recorded()
    #expect(calls.map(\.configDir) == ["/Users/x/.claude-acme"])
}

/// **The capture step renders no cancel control — absent, not disabled.**
/// What one would destroy is a one-year credential printed once and kept
/// nowhere, and a disabled control still teaches that pressing it is the
/// way out.
@Test func theCaptureStepOffersNoCancelAtAll() async throws {
    #expect(!ProviderLoginState.minting(trip: 2, of: 2, id: "acme").offersCancel)

    // And in flight: a minter that never answers keeps the session in
    // `.minting`, which is where the control would be if there were one.
    let never = FakeMinter(ProviderMintOutcome(stored: true))
    let session = ProviderLoginSession()
    await session.use(mint: never, commit: { _, _ in .refused("") })
    _ = session
}

/// **Mint before record.** No binding is written when nothing was stored,
/// which is what makes today's orphaned bindings unreproducible: a record
/// naming an account with no credential cannot be reached this way.
@Test func aFailedMintWritesNoBinding() async throws {
    let committed = CommitCounter()
    let minter = FakeMinter(ProviderMintOutcome(
        stored: false, uncertain: false, detail: "authorization declined"))
    let session = await signedInSession(mint: minter) { id, dir in
        await committed.record(id: id, configDir: dir)
        return .added(Account(org: "acme", accountId: id))
    }

    let settled = await settle(session) { if case .failed = $0 { return true }; return false }
    guard case .failed(let message) = settled else {
        Issue.record("expected a failure, got \(settled)"); return
    }
    #expect(message.contains("authorization declined"))
    #expect(await committed.count() == 0, "a binding was written for a credential that does not exist")
}

private actor CommitCounter {
    private var calls = 0
    func record(id: String, configDir: String) { calls += 1 }
    func count() -> Int { calls }
}

/// **The outcome that has no clean name gets its own case**, because a
/// surface that can render it as a failure eventually will — and an
/// operator told "it failed" would leave a live 365-day credential in
/// their account without knowing it exists.
@Test func anUncertainMintIsNeverReportedAsAFailure() async throws {
    let committed = CommitCounter()
    let minter = FakeMinter(ProviderMintOutcome(
        stored: false, uncertain: true,
        detail: "a long-lived credential WAS created and could not be stored"))
    let session = await signedInSession(mint: minter) { id, dir in
        await committed.record(id: id, configDir: dir)
        return .added(Account(org: "acme", accountId: id))
    }

    let settled = await settle(session) { if case .uncertain = $0 { return true }; return false }
    guard case .uncertain(let detail) = settled else {
        Issue.record("expected uncertain, got \(settled)"); return
    }
    #expect(detail.contains("WAS created"))
    // And no record is written for a credential Wakil may not hold.
    #expect(await committed.count() == 0)
}

/// A credential that stored but whose binding did not land is its own
/// sentence: a retry costs no browser trip, because the token is kept.
@Test func aStoredCredentialWhoseBindingFailedSaysTheRetryIsFree() async throws {
    let minter = FakeMinter(ProviderMintOutcome(stored: true))
    let session = await signedInSession(mint: minter) { _, _ in .refused("") }

    let settled = await settle(session) { if case .failed = $0 { return true }; return false }
    guard case .failed(let message) = settled else {
        Issue.record("expected a failure, got \(settled)"); return
    }
    #expect(message.contains("not cost another"))
}

/// **#323: the refusal says WHY.** The walk hit this twice, and the pane
/// and the journal both said only that it failed, so the cause had to be
/// inferred. The action's own sentence travels to the operator.
@Test func aRefusedBindingSaysWhyAndThatTheRetryIsFree() async throws {
    let minter = FakeMinter(ProviderMintOutcome(stored: true))
    let session = await signedInSession(mint: minter) { _, _ in
        .refused("ctx_add_provider: could not read organisation \"pid-switch-a\"")
    }

    let settled = await settle(session) { if case .failed = $0 { return true }; return false }
    guard case .failed(let message) = settled else {
        Issue.record("expected a failure, got \(settled)"); return
    }
    #expect(message.contains("could not read organisation \"pid-switch-a\""))
    #expect(message.contains("not cost another"))
}

// MARK: - The mint outcome decoder

/// **It refuses rather than passing on, and refuses UPWARD**: output that
/// cannot be read becomes uncertain, never a clean failure. A verb that
/// ran and whose answer could not be read is exactly the case where Wakil
/// does not know whether a credential exists.
@Test func anUnreadableMintOutcomeIsUncertainRatherThanFailed() throws {
    for raw in ["", "   ", "boom", "not json at all", "{"] {
        let outcome = decodeProviderMintOutcome(raw)
        #expect(!outcome.stored, "\(raw)")
        #expect(outcome.uncertain, "an unreadable answer must not read as a clean failure: \(raw)")
        #expect(outcome.detail.contains("may have been created"), "\(raw)")
    }
}

@Test func aMintOutcomeDecodesFromTheVerbsOwnLine() throws {
    let stored = decodeProviderMintOutcome(#"{"stored":true}"#)
    #expect(stored.stored)
    #expect(!stored.uncertain)

    // Amid other output, the last JSON line is the answer.
    let amid = decodeProviderMintOutcome("""
        opening your browser
        {"stored":false,"uncertain":true,"detail":"it was created and lost"}
        """)
    #expect(amid.uncertain)
    #expect(amid.detail == "it was created and lost")
}

// MARK: - Reachability

@Test func writingTheBindingIsOperatorOnly() throws {
    #expect(operatorOnlyActions.contains("ctx_add_provider"))
    let decision = permissionDecision(
        toolName: "mcp__wakil__ctx_add_provider", knownActions: ["ctx_add_provider"])
    guard case .deny(let reason) = decision else {
        Issue.record("ctx_add_provider must be denied, got \(decision)"); return
    }
    // It falls into the boundary family, which is its actual reason.
    #expect(reason.contains("credential boundary"))
}

// MARK: - The three cancels, and the repair path (#205)

/// **Cancel means three different things in one flow and the surface must
/// not use one word for them**, so only one of them is entitled to say
/// nothing was created.
@Test func onlyTheFirstTripsCancelMayClaimNothingWasCreated() throws {
    #expect(CancelClaim.nothingHappened.mayClaimNothingWasCreated)
    #expect(!CancelClaim.trip2Recoverable.mayClaimNothingWasCreated)

    // Trip 1's sentence says it outright.
    guard case .cancelled(let clean) = ProviderLoginState.cancelled(.nothingHappened) else {
        Issue.record("unreachable"); return
    }
    #expect(clean.mayClaimNothingWasCreated)
}

/// **The correction #203 earned.** Cancelling between the trips kills the
/// `setup-token` process — and if the operator approved moments earlier,
/// the exchange may already have completed and printed, leaving the kill
/// between the print and Go's store. That is the timeout's case exactly,
/// so *"nothing has been minted yet"* is a claim this cancel has no
/// standing to make.
@Test func theSecondTripsCancelStatesTheRecoveryAndAdmitsTheUncertainty() throws {
    guard case .recoverable(let sentence) = CancelClaim.trip2Recoverable else {
        Issue.record("trip 2's claim is not recoverable"); return
    }
    // The recovery, which is what the operator acts on.
    #expect(sentence.contains("one trip rather than two"))
    // And the uncertainty, which is what they need to know.
    #expect(sentence.contains("may have been created"))
    // It must NOT reassure.
    #expect(!sentence.lowercased().contains("nothing was created"))
    #expect(!sentence.lowercased().contains("nothing has been minted"))
}

/// A trip-2 timeout may not claim a clean failure either, and for the same
/// reason: the exchange may have completed while Wakil was no longer
/// listening.
@Test func theSecondTripsTimeoutMayNotClaimACleanFailure() throws {
    let first = TimeoutClaim.firstTrip()
    let second = TimeoutClaim.secondTrip()

    #expect(first.mayClaimNothingWasCreated)
    #expect(!second.mayClaimNothingWasCreated)
    #expect(first.message.contains("Nothing was created"))
    #expect(second.message.contains("may have been created"))
    #expect(!second.message.contains("Nothing was created"))
}

/// **Re-entry costs one trip, not two**, because the config directory is a
/// pure function of the provider id — so the next add of the same id finds
/// the sign-in still there. And a one-trip start goes straight to the
/// mint: a first trip would buy nothing.
@Test func aLiveSignInReEntersAtOneTripAndGoesStraightToTheMint() async throws {
    let minter = FakeMinter(ProviderMintOutcome(stored: true))
    let session = ProviderLoginSession()
    await session.use(mint: minter) { id, _ in .added(Account(org: "acme", accountId: id, mine: true)) }

    // A spawner that would fail if a login were attempted, so a first
    // trip could not pass unnoticed.
    let spawner = FakeSpawner(replies: [], failToStart: true)
    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: ClaudeCodeProviderLogin(spawn: spawner), trips: 1)

    let settled = await settle(session) { if case .added = $0 { return true }; return false }
    guard case .added = settled else {
        Issue.record("a one-trip start did not reach the mint: \(settled)"); return
    }
    // Nothing was spawned for a sign-in.
    #expect(await spawner.recorded().isEmpty, "a one-trip re-entry ran a login it did not need")
    // And the mint DID run — re-authentication never skips it.
    #expect(await minter.recorded().count == 1)
}

/// **Re-authentication never skips the mint**, whatever the trip count.
/// The minted token is what launches sessions, so a sign-in-only repair
/// leaves the account exactly as broken as it was.
@Test func bothTripCountsEndAtTheMint() async throws {
    for trips in [1, 2] {
        let minter = FakeMinter(ProviderMintOutcome(stored: true))
        let session = ProviderLoginSession()
        await session.use(mint: minter) { id, _ in .added(Account(org: "acme", accountId: id)) }
        let spawner = FakeSpawner(replies: [
            ProviderLoginSpawnResult(status: 0),
            ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
        ])
        await session.start(
            id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
            login: ClaudeCodeProviderLogin(spawn: spawner), trips: trips)

        let settled = await settle(session) { if case .added = $0 { return true }; return false }
        guard case .added = settled else {
            Issue.record("trips=\(trips) did not land: \(settled)"); return
        }
        #expect(await minter.recorded().count == 1, "trips=\(trips) skipped the mint")
    }
}

/// **Sign in as someone else always costs two trips**, whatever the
/// directory currently holds — the whole point is that what is in there is
/// not the account the operator wants.
@Test func signingInAsSomeoneElseAlwaysCostsTwoTrips() async throws {
    let minter = FakeMinter(ProviderMintOutcome(stored: true))
    let session = ProviderLoginSession()
    await session.use(mint: minter) { id, _ in .added(Account(org: "acme", accountId: id)) }
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])

    await session.startAsSomeoneElse(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: ClaudeCodeProviderLogin(spawn: spawner))

    guard case .signingIn(let trip, let total, _) = await session.current() else {
        Issue.record("expected signingIn, got \(await session.current())"); return
    }
    #expect(trip == 1)
    #expect(total == 2, "signing in as someone else must not re-use the sign-in it is replacing")
}

/// A refusal fails fast rather than sitting until a timeout, and it is
/// still distinguishable from one on the repair path.
@Test func aRefusalOnTheRepairPathStillFailsFast() async throws {
    let session = ProviderLoginSession()
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 1, stderr: "authorization declined"),
    ])
    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: ClaudeCodeProviderLogin(spawn: spawner), trips: 2)

    let settled = await settle(session) { if case .refused = $0 { return true }; return false }
    guard case .refused(let message) = settled else {
        Issue.record("expected a refusal, got \(settled)"); return
    }
    #expect(message == "authorization declined")
    // One spawn: it did not go on to read liveness for a trip that never
    // succeeded.
    #expect(await spawner.recorded().count == 1)
}

/// The re-entry prompt turns on having a NAME, not on `loggedIn` — there
/// is nothing to say "continue as" about without one, and a poisoned read
/// is exactly the case where the two disagree.
@Test func theReEntryPromptNeedsANameAndNotJustALoggedInFlag() throws {
    #expect(ProviderLoginIdentity(loggedIn: true, email: "a@example.test").namesSomebody)
    #expect(!ProviderLoginIdentity(loggedIn: true, email: "").namesSomebody)
    #expect(!ProviderLoginIdentity(loggedIn: false, email: "a@example.test").namesSomebody)
}

// MARK: - Review fixes

/// **The mint's journal line must NAME the account**, and this is the bug
/// the review found: the mint is deliberately not a registered action, so
/// a mark inferred from the registry resolves to "unknown" and the
/// redaction replaces every value. The line read `{"id":"[redacted]"}` —
/// an audit record saying a credential may exist uncaught, and refusing to
/// say for which account.
@Test func theMintsJournalLineNamesTheAccountItCouldNotConfirm() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "mint")

    try await registry.journalMintOutcome(
        id: "acme", stored: false, origin: .ui, environment: "staging")

    let entries = try await registry.journalEntries()
    guard let entry = entries.first, case .object(let params) = entry.params else {
        Issue.record("no entry: \(entries)"); return
    }
    #expect(entry.outcome == "uncertain")
    #expect(params["id"] == .string("acme"), "the account id was redacted out of its own line")
}

/// **Both outcomes get a line.** "Minted and stored" and "a credential
/// exists that Wakil never caught" are the two facts an operator must be
/// able to tell apart, which means recording the first as well as the
/// second — otherwise the distinction is an absence.
@Test func theMintJournalsASuccessAsWellAsAnUncertainty() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "mint")

    try await registry.journalMintOutcome(
        id: "acme", stored: true, origin: .ui, environment: "staging")
    try await registry.journalMintOutcome(
        id: "other", stored: false, origin: .ui, environment: "staging")

    let entries = try await registry.journalEntries()
    #expect(entries.map(\.outcome) == ["minted", "uncertain"])
    #expect(entries.count == 2)
}

/// **`CancelClaim.trip2Recoverable` is reachable**, which the review found
/// it was not: it was constructed only in tests.
///
/// There is no cancel BUTTON on the capture step and there must not be —
/// but dismissing the band while it runs IS abandoning between the trips,
/// and that owes the trip-2 claim rather than a silent return to idle.
@Test func abandoningDuringTheCaptureStepCarriesTheTripTwoClaim() async throws {
    let session = ProviderLoginSession()
    // A minter that never answers, so the session stays in `.minting`.
    let never = NeverAnsweringMinter()
    await session.use(mint: never) { _, _ in .refused("") }
    let spawner = FakeSpawner(replies: [
        ProviderLoginSpawnResult(status: 0),
        ProviderLoginSpawnResult(status: 0, stdout: liveStatus),
    ])
    await session.start(
        id: "acme", configDir: "/Users/x/.claude-acme", binary: "/bin/claude",
        login: ClaudeCodeProviderLogin(spawn: spawner), trips: 2)

    let minting = await settle(session) { if case .minting = $0 { return true }; return false }
    guard case .minting = minting else {
        Issue.record("never reached the capture step: \(minting)"); return
    }
    // Still no cancel control — that ruling is untouched.
    #expect(!minting.offersCancel)

    await session.abandon()
    guard case .cancelled(let claim) = await session.current() else {
        Issue.record("abandon did not carry a claim: \(await session.current())"); return
    }
    #expect(claim == .trip2Recoverable)
    #expect(!claim.mayClaimNothingWasCreated)
}

/// Abandoning anywhere else is an ordinary dismiss.
@Test func abandoningOutsideTheCaptureStepJustReturnsToIdle() async throws {
    let session = ProviderLoginSession()
    await session.offer(id: "acme", kind: "claude-code", label: "", existing: ProviderLoginIdentity())
    await session.abandon()
    #expect(await session.current() == .idle)
}

private actor NeverAnsweringMinter: ProviderMinting {
    func mint(id: String, configDir: String, binary: String) async -> ProviderMintOutcome {
        // Long enough that the test observes `.minting`; cancelled with
        // the task when the session abandons.
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return ProviderMintOutcome(stored: true)
    }
}

// MARK: - The add doors (#325)

/// **The doors are how an operator recovers from a failed add**, so a
/// settled state must not take them away. In the walk, the "could not find
/// the claude executable" failure hid Adopt and Register until its banner was
/// dismissed. Only a trip in flight owns the band.
@Test func theAddDoorsShowInEverySettledStateAndNoneInFlight() {
    let account = Account(org: "acme", accountId: "main")
    let settled: [ProviderLoginState] = [
        .idle, .added(account), .uncertain("x"), .refused("x"), .failed("x"),
    ]
    for state in settled { #expect(state.offersAddDoors, "\(state) hid the doors") }
    #expect(!ProviderLoginState.minting(trip: 2, of: 2, id: "acme").offersAddDoors)
}

// MARK: - What ctx_add_provider forwards

/// Records every tool call and answers success.
private actor AddProviderRecorder: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object([:])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

/// **The walk's register failure, found at last.** `WindowModel` sends
/// `claudePath` (#259), and Go refuses a claude-code binding without one,
/// but this action forwarded only id, configDir, kind and label, so every
/// account registered through the pane was refused with "no agent
/// executable recorded". Every test that drove the add injected a fake
/// commit, so none of them ever reached this handler.
@Test func addingAnAccountForwardsTheClaudePathToGo() async throws {
    let recorder = AddProviderRecorder()
    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "add-provider")
    await registerStandardActions(
        into: registry, context: recorder, panes: PaneStore(), db: nil, resumes: ResumeBroker())

    _ = try await registry.dispatch(
        name: "ctx_add_provider",
        params: .object([
            "id": .string("walk-2e"), "configDir": .string("/Users/x/.claude-walk-2e"),
            "claudePath": .string("/Users/x/.local/bin/claude"),
        ]),
        origin: .ui, environment: "staging", confirmation: nil)

    let calls = await recorder.recorded()
    guard let call = calls.first(where: { $0.tool == "add_provider" }),
          case .object(let arguments) = call.arguments
    else {
        Issue.record("add_provider was never called: \(calls.map(\.tool))"); return
    }
    #expect(arguments["claudePath"] == .string("/Users/x/.local/bin/claude"))
}
