import Foundation

/// What writing a just-minted account's binding came to.
///
/// **A refusal carries its sentence** (#323). It used to be `Account?`, so
/// a refused commit arrived as a bare nil and the operator was told only
/// that it failed.
public enum ProviderCommitOutcome: Sendable {
    case added(Account)
    case refused(String)
}

/// What the pane's in-flight band is showing.
///
/// **Two actions rather than one, and this type is why.** Every `ctx_*`
/// action is a thin proxy on a ten-second reply timeout, while a browser
/// login is minutes. So `ctx_provider_login` returns at once and this
/// publishes what happens afterwards — modelled on `TerminalSession`,
/// which already does exactly this for a PTY.
///
/// **The trip count is on the state**, so the band can say *1 of 2*
/// without the view computing it. A long wait reads as progress rather
/// than as a hang.
public enum ProviderLoginState: Sendable, Equatable {
    /// Nothing is running. The pane draws no band at all.
    case idle

    /// The operator has asked to add an account and has not started yet.
    ///
    /// **This state exists so the cost is stated BEFORE anything
    /// happens** — two browser trips, about a minute — so the operator can
    /// choose a moment rather than discover it halfway through.
    ///
    /// When the derived directory already holds a live sign-in, the offer
    /// carries whose it is, and the surface asks before reusing it — see
    /// `PreflightOffer.existing`.
    case preflight(PreflightOffer)

    /// The first browser trip is running.
    ///
    /// **Its cancel is free and says so.** This is the only provably clean
    /// cancel in the flow: nothing is recorded, no credential exists, and
    /// no exchange has been started that could complete behind Wakil's
    /// back.
    case signingIn(trip: Int, of: Int, id: String)

    /// The trip finished and the operator is signed in.
    ///
    /// **There is no pause here** — `SIGNED_IN` advances straight to the
    /// mint (#101, confirmed on #203). Trip 1 ends with the operator
    /// looking at a browser success page, not at Wakil, because the login
    /// completes through a localhost listener; a *Continue* button would
    /// cost two app switches to reach an exit the browser already offers.
    ///
    /// Transient: the session publishes it and advances, so the band
    /// shows it only for as long as the mint takes to start.
    case signedIn(ProviderLoginIdentity, id: String)

    /// The second trip is running: the credential is being created.
    ///
    /// **This step renders NO cancel control — absent, not disabled**
    /// (#204). What a cancel here would destroy is a one-year credential
    /// that is printed once and kept nowhere, and a disabled control
    /// still teaches that pressing it is the way out. `offersCancel` is
    /// false for this case, and that is the whole of the mechanism.
    case minting(trip: Int, of: Int, id: String)

    /// The credential was created, stored, and the binding written.
    case added(Account)

    /// **The outcome that has no clean name**: a one-year credential may
    /// exist at Anthropic that Wakil never caught.
    ///
    /// Its own case rather than a `failed` with a longer string, because
    /// a surface that can render it as a failure eventually will.
    case uncertain(String)

    /// The browser trip was declined.
    ///
    /// **A refusal may claim what a timeout may not**, and this one does:
    /// it is an observed fact, it fails fast rather than sitting until a
    /// timeout, and it may say plainly that nothing was created.
    case refused(String)

    /// The trip ran out of time, which says nothing about what happened.
    case timedOut(TimeoutClaim)

    /// The operator cancelled. The claim carried says what it cost.
    case cancelled(CancelClaim)

    /// The mechanism itself could not run.
    case failed(String)

    /// Whether a band should be on screen at all.
    public var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    /// Whether a cancel control should be drawn.
    ///
    /// **Absent, not disabled, wherever it is absent** — the capture step
    /// (#204) has none at all, so a one-year credential cannot be
    /// destroyed by pressing something that looks harmless. A disabled
    /// control still teaches that pressing it is the way out.
    /// Whether the Adopt and Register doors draw beside this state (#325).
    ///
    /// **Only a trip in flight owns the band.** A settled state, a failure
    /// above all, is exactly when the operator needs a way to try again,
    /// and hiding the doors behind a banner that must be dismissed first
    /// took it away. Every case is named, for `offersCancel`'s reason.
    public var offersAddDoors: Bool {
        switch self {
        case .preflight, .signingIn, .signedIn, .minting:
            return false
        case .idle, .added, .uncertain, .refused, .timedOut, .cancelled, .failed:
            return true
        }
    }

    public var offersCancel: Bool {
        switch self {
        case .signingIn: return true
        // **`.minting` is listed here deliberately rather than falling
        // into a default.** It is the capture step, and what a cancel
        // there would destroy is a one-year credential printed once and
        // kept nowhere. A `default: return false` would make this the
        // absence of a decision; naming it makes it one.
        case .idle, .preflight, .signedIn, .minting, .added, .uncertain,
             .refused, .timedOut, .cancelled, .failed:
            return false
        }
    }
}

/// What the operator is told before the first trip starts.
public struct PreflightOffer: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var label: String
    /// Whose sign-in the derived directory already holds, when it holds
    /// one.
    ///
    /// **Re-entry shows the identity first, and that closes a
    /// misidentification hazard**: nothing guarantees the second `acme` is
    /// the same human. When this names somebody the pane offers *Continue
    /// as <email>* or *Sign in as someone else* (#205); when it does not,
    /// the add is an ordinary first-time one.
    public var existing: ProviderLoginIdentity

    public init(
        id: String, kind: String, label: String = "",
        existing: ProviderLoginIdentity = ProviderLoginIdentity()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.existing = existing
    }

    /// How many browser trips this add will cost.
    ///
    /// **Derived from liveness, not from the directory existing**
    /// (`phase-2e-probe.md` §3.2). A directory that merely resolves is not
    /// a live sign-in: under that rejected reading, Re-authenticate on a
    /// red row succeeded and left the row red, because nothing on a
    /// mint-only path writes the sign-in.
    public var trips: Int { existing.tripsToRepair }

    /// The sentence shown before anything happens.
    ///
    /// It states the cost in trips and in time, because *about a minute*
    /// is what makes a two-step flow a choosable moment rather than a
    /// surprise.
    public var sentence: String {
        trips == 1
            ? "This takes one browser trip, a few seconds. "
                + "You are already signed in as \(existing.email); only the long-lived "
                + "credential still has to be created."
            : "This takes two browser trips and about a minute. "
                + "You will sign in, then approve a long-lived credential. "
                + "Wakil never shows you a token."
    }
}

/// What a cancel actually cost, in the operator's own terms.
///
/// **Cancel means three different things in one flow and the surface must
/// not use one word for them.** This type is what keeps them apart.
public enum CancelClaim: Sendable, Equatable {
    /// Trip 1. **The only provably clean cancel**: nothing was recorded,
    /// nothing was created, and no exchange had been started that could
    /// complete behind Wakil's back.
    case nothingHappened
    /// Trip 2. **Recoverable, and NOT clean** — and the second half is the
    /// correction #203 earned.
    ///
    /// Recoverable because abandoning between the trips leaves the sign-in
    /// in place, and that IS the recovery: the config directory is a pure
    /// function of the provider id, so the next add of the same id
    /// computes the same directory and re-enters at one trip.
    ///
    /// **Not clean, because cancelling kills the `setup-token` process** —
    /// and if the operator approved moments earlier, the exchange may
    /// already have completed and printed, leaving the kill between the
    /// print and Go's store. That is the TIMEOUT's case exactly, and
    /// equally unobservable. So *"nothing has been minted yet"* is a claim
    /// this cancel has no standing to make, and the sentence it carries
    /// must not make it.
    case recoverable(String)

    /// Whether this claim is entitled to say nothing was created.
    ///
    /// **Only trip 1's is.** A property rather than a thing each surface
    /// remembers, because the failure mode is a sentence that reads
    /// reassuringly and is false.
    public var mayClaimNothingWasCreated: Bool {
        if case .nothingHappened = self { return true }
        return false
    }
}

extension CancelClaim {
    /// Trip 2's sentence.
    ///
    /// **It states the recovery and admits the uncertainty, in that
    /// order** — the recovery is what the operator acts on, the
    /// uncertainty is what they need to know. It does not say "nothing was
    /// minted": see the case's own doc comment for why that claim has no
    /// standing here (#203).
    public static let trip2Recoverable = CancelClaim.recoverable(
        "Your sign-in is kept, so adding this account again costs one trip rather than two. "
            + "But if you had already approved the credential, one may have been created that "
            + "Wakil did not catch — check your Anthropic account before you retry.")
}

/// What a timed-out trip may say.
///
/// **A timeout may not claim what a refusal may.** It is carried as a type
/// rather than a string so that the trip-2 case — where a token may exist
/// at Anthropic that Wakil never caught — cannot be written as a clean
/// failure by accident.
public struct TimeoutClaim: Sendable, Equatable {
    public var trip: Int
    public var message: String

    public init(trip: Int, message: String) {
        self.trip = trip
        self.message = message
    }

    /// Trip 1's timeout. Nothing was minted because minting had not
    /// started, so this one may say so.
    public static func firstTrip() -> TimeoutClaim {
        TimeoutClaim(
            trip: 1,
            message: "The sign-in did not finish in time. Nothing was created — "
                + "you can start again whenever you like.")
    }

    /// Trip 2's timeout. **It may not claim a clean failure**, and this is
    /// the sentence that does not.
    ///
    /// The exchange may have completed and printed while Wakil was no
    /// longer listening, so a token may exist that Wakil never caught. An
    /// operator told "it timed out, nothing happened" would leave a live
    /// 365-day credential in their account without knowing.
    public static func secondTrip() -> TimeoutClaim {
        TimeoutClaim(
            trip: 2,
            message: "The credential step did not finish in time. Wakil did not catch a "
                + "credential — but one may have been created, and Wakil cannot tell. "
                + "Check your Anthropic account before trying again.")
    }

    /// Whether this claim is entitled to say nothing was created. **Only
    /// trip 1's is**, for the same reason only trip 1's cancel is.
    public var mayClaimNothingWasCreated: Bool { trip == 1 }
}

/// Holds one in-flight login and publishes its states.
///
/// Modelled on `TerminalSession`: the action returns at once and the
/// window observes this. An actor, so a cancel arriving from the pane and
/// a trip finishing on its own cannot race.
public actor ProviderLoginSession {
    private var state: ProviderLoginState = .idle
    private var running: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<ProviderLoginState>.Continuation] = [:]

    public init() {}

    public func current() -> ProviderLoginState { state }

    /// Whether the capture step is running.
    ///
    /// Asked by `WindowModel.invalidateForOrgChange`, which must not
    /// dismiss a mint in flight: dismissing cancels the running task, and
    /// on this step that is the cancel this phase ensured has no control,
    /// reached by another gesture.
    public func isMinting() -> Bool {
        if case .minting = state { return true }
        return false
    }

    /// Abandons the flow between the trips.
    ///
    /// **This is where `CancelClaim.trip2Recoverable` becomes
    /// reachable.** There is no cancel BUTTON on the capture step and
    /// there must not be — but an operator dismissing the band while it
    /// runs is abandoning between the trips, and that state owes the
    /// trip-2 claim rather than a silent return to idle: the sign-in is
    /// kept, so the retry costs one trip, and a credential may already
    /// have been created that Wakil did not catch.
    public func abandon() {
        guard case .minting = state else {
            dismiss()
            return
        }
        running?.cancel()
        running = nil
        publish(.cancelled(.trip2Recoverable))
    }

    /// Every state this session enters, as it enters it.
    ///
    /// `bufferingNewest(1)` for `ActionRegistry.dispatches()`' reason: a
    /// subscriber that is behind does not need to know which states it
    /// missed, only what the state is now. This is a band on a pane, not
    /// a log.
    public func states() -> AsyncStream<ProviderLoginState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            subscribers[key] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(key) }
            }
        }
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    private func publish(_ next: ProviderLoginState) {
        state = next
        for continuation in subscribers.values { continuation.yield(next) }
    }

    /// Puts the flow in front of the operator with its cost stated, and
    /// runs nothing.
    ///
    /// **Nothing happens until they say so**, which is the whole point of
    /// a pre-flight: an operator told after the fact that this takes a
    /// minute has already spent it.
    public func offer(id: String, kind: String, label: String, existing: ProviderLoginIdentity) {
        publish(.preflight(PreflightOffer(id: id, kind: kind, label: label, existing: existing)))
    }

    /// Starts the add over, discarding whatever sign-in the directory
    /// holds (#205).
    ///
    /// **`Sign in as someone else`, and it needs no confirmation.** It
    /// escalates nothing and is undone by the gesture that did it: one
    /// `claude auth login`, which REPLACES in place and upserts the same
    /// Keychain item under an unchanged name. The confirmation list has
    /// two entries and this is not one of them.
    ///
    /// It always costs two trips, whatever the directory currently holds:
    /// the whole point is that the sign-in in there is not the one the
    /// operator wants.
    public func startAsSomeoneElse(
        id: String, configDir: String, binary: String, login: any ProviderLogin
    ) {
        start(id: id, configDir: configDir, binary: binary, login: login, trips: 2)
    }

    /// Starts the first browser trip.
    ///
    /// Returns immediately; the trip runs on a task this session owns, so
    /// a cancel has something to cancel.
    ///
    /// **`trips == 1` skips straight to the mint**, and that is the whole
    /// of re-authentication's cheap path: the directory already holds a
    /// live, named sign-in, so the first trip would buy nothing. It never
    /// skips the MINT — a mint-only repair is the one-trip case, and a
    /// sign-in-only repair is not a case at all, because the minted token
    /// is what launches sessions.
    public func start(
        id: String, configDir: String, binary: String, login: any ProviderLogin, trips: Int
    ) {
        guard running == nil else { return }
        plan = Plan(configDir: configDir, binary: binary, trips: trips)
        // **One trip means the sign-in is already live and named**, so
        // there is nothing for a first trip to do. Re-authentication
        // re-enters here rather than at the top.
        guard trips > 1 else {
            advanceToMint(id: id)
            return
        }
        publish(.signingIn(trip: 1, of: trips, id: id))
        running = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await login.signIn(configDir: configDir, binary: binary)
                await self.finish(result, id: id)
            } catch {
                await self.finish(failure: "\(error)")
            }
        }
    }

    private func finish(_ result: ProviderLoginResult, id: String) {
        running = nil
        // A cancel that already landed wins: the task it cancelled may
        // still deliver a result, and reporting that over the operator's
        // own decision would be the surface arguing with them.
        if case .cancelled = state { return }
        switch result {
        case .signedIn(let identity):
            publish(.signedIn(identity, id: id))
            // **No pause. `SIGNED_IN` advances straight to the mint**
            // (#101, confirmed on #203). The operator is looking at a
            // browser success page rather than at Wakil, so a Continue
            // button would cost two app switches to reach an exit the
            // browser already offers — and declining on the authorize
            // page is a refusal, which may claim what a timeout may not.
            advanceToMint(id: id)
        case .refused(let message):
            publish(.refused(message))
        case .timedOut:
            publish(.timedOut(.firstTrip()))
        case .cancelled:
            publish(.cancelled(.nothingHappened))
        }
    }

    private func finish(failure: String) {
        running = nil
        if case .cancelled = state { return }
        publish(.failed(failure))
    }

    /// Cancels the trip that is running.
    ///
    /// **Trip 1's cancel is free, always offered, and says it costs
    /// nothing** — the only provably clean cancel in the flow. The other
    /// two meanings arrive with #204 (the capture step, which has no
    /// cancel control at all) and #205 (trip 2, which is recoverable
    /// rather than clean).
    public func cancel() {
        guard case .signingIn(let trip, _, _) = state else { return }
        running?.cancel()
        running = nil
        publish(.cancelled(trip == 1 ? .nothingHappened : .trip2Recoverable))
    }

    /// Stops waiting for the mint. **It does not cancel the mint, and it
    /// must never say that it does** (#240).
    ///
    /// The old ruling was that trip 2 has no way out at all, because what
    /// a cancel would destroy is a one-year credential printed once and
    /// kept nowhere. The reasoning is sound and this does not overturn it:
    /// nothing here destroys anything. What it overturns is the
    /// assumption underneath — that the mint either completes or hits its
    /// deadline promptly. It did neither: spawned on a pipe the CLI
    /// printed nothing and the operator sat on "Trip 2 of 2" for the full
    /// five minutes with no control at all, while a real credential had
    /// already been created at Anthropic.
    ///
    /// So the outcome is `.uncertain`, which is the truth: Wakil stopped
    /// listening, and whether a credential exists is exactly what nobody
    /// here knows. That is the same state a deadline produces, reached by
    /// the operator's choice instead of by waiting.
    public func stopWaitingForMint() {
        guard case .minting = state else { return }
        running?.cancel()
        running = nil
        publish(.uncertain(
            "You stopped waiting. Wakil did not cancel anything — it cannot: a long-lived "
                + "credential may already have been created for this account, and it is "
                + "revocable only in your Anthropic account. Check there before minting again."))
    }

    /// Runs the mint, then writes the binding.
    ///
    /// **Mint before record.** The binding is written only after the
    /// credential is stored, which makes today's orphaned bindings
    /// unreproducible by construction — and Go refuses to write one
    /// without a stored credential, so the ordering is a check rather
    /// than a convention this function could get wrong.
    private func advanceToMint(id: String) {
        guard let mint, let commit, let plan else { return }
        publish(.minting(trip: plan.trips, of: plan.trips, id: id))
        running = Task { [weak self] in
            guard let self else { return }
            let outcome = await mint.mint(
                id: id, configDir: plan.configDir, binary: plan.binary)
            await self.finishMint(outcome, id: id, commit: commit)
        }
    }

    private func finishMint(
        _ outcome: ProviderMintOutcome, id: String,
        commit: @Sendable (String, String) async -> ProviderCommitOutcome
    ) async {
        running = nil
        if case .cancelled = state { return }

        if outcome.uncertain {
            // A mint that could not be confirmed is `.uncertain` rather
            // than `.timedOut`: the distinction the surface needs is not
            // WHY Wakil stopped listening but WHETHER a credential may
            // exist, and both the timeout and the failed store answer
            // that the same way. `TimeoutClaim.secondTrip()` carries the
            // same sentence for the paths that do report a timeout.
            // **Never a clean failure.** A credential may exist that
            // Wakil never caught, and no record is written for it: a
            // binding naming an account whose token Wakil does not hold
            // is exactly the state this phase exists to make
            // unreachable.
            publish(.uncertain(outcome.detail))
            return
        }
        guard outcome.stored else {
            publish(.failed(outcome.detail.isEmpty
                ? "no credential was created, so nothing was recorded"
                : outcome.detail))
            return
        }
        switch await commit(id, plan?.configDir ?? "") {
        case .added(let row):
            publish(.added(row))
        case .refused(let reason):
            // The credential IS stored; only the record failed. Saying so
            // matters: the operator can retry the commit, and a retry
            // costs no browser trip because the token is already kept.
            // **And why it failed** (#323): without the action's own
            // sentence the cause had to be inferred from what else was
            // running at the time.
            let why = reason.isEmpty ? "" : " (\(reason))"
            publish(.failed(
                "The credential was created and stored, but the binding could not be "
                    + "written\(why). Try adding the account again — it will not cost "
                    + "another browser trip, because the credential is already kept."))
        }
    }

    /// What the in-flight add is working against, set when it starts.
    private struct Plan: Sendable {
        var configDir: String
        var binary: String
        var trips: Int
    }
    private var plan: Plan?
    private var mint: (any ProviderMinting)?
    private var commit: (@Sendable (String, String) async -> ProviderCommitOutcome)?

    /// Supplies the halves the mint needs. Separate from `start` because
    /// they are per-window wiring rather than per-trip state.
    public func use(
        mint: any ProviderMinting,
        commit: @escaping @Sendable (String, String) async -> ProviderCommitOutcome
    ) {
        self.mint = mint
        self.commit = commit
    }

    /// Returns to idle, taking the band off the pane.
    public func dismiss() {
        running?.cancel()
        running = nil
        publish(.idle)
    }
}
