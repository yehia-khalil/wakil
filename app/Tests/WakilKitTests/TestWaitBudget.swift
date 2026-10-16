import Foundation

/// **Why every polling wait in this suite multiplies its budget, and by
/// what.**
///
/// Three tests were red on `main` for days (#127), deterministically, and
/// the most informative fact about them was that they **passed when run
/// scoped and failed in the full run**:
///
/// | Test | Budget | Worst measured under the full run |
/// |---|---|---|
/// | `aRealBashReportsAnHonestEmptyCommand…` | 8 s | **10.50 s** |
/// | `aRealResultEventFiresTheQueuedSwitch…` | 2 s | **3.36 s** |
/// | `aResumeRequestFromTheAgentFiresAQueuedSwitch…` | 2 s | (same helper) |
///
/// Measured 2026-09-22 by instrumenting both helpers to report the elapsed
/// time on success and running the whole suite with a 120-second budget:
/// **1139 tests, zero failures.** So nothing was broken. The assertions
/// were right, the machinery worked, and what ran out was wall clock.
///
/// **Why the full run is slower, and why that is not a bug to fix.** The
/// suite runs 1139 tests in parallel; a large share of them are
/// `@MainActor` and therefore serialise on one actor, and
/// `TerminalStoreTests` spawns real PTYs running real `bash` and `zsh`.
/// The terminal round trip this budget covers costs **0.073 s** on an idle
/// machine — the helper's own doc comment has said so all along — so 8 s
/// was never a measurement of anything. It was a number large enough to
/// look generous against an idle run and, at 1139 tests, was not.
///
/// **Why a multiplier rather than bigger numbers at 37 call sites.** Each
/// call site's `seconds:` says something true and worth keeping: *this
/// round trip should take well under 8 seconds*. That is a statement about
/// the operation, and it does not change. What changes is how much of the
/// machine the operation is competing for, which is a property of the
/// suite and belongs in one place — here — where it can carry the
/// measurement that justifies it.
///
/// **Why a wall-clock deadline at all, rather than counting polls.**
/// `WindowModelTests`'s own `waitUntil` counts 400 polls instead of
/// seconds, and it is the one helper of this shape that was never in
/// #127's list: a poll count stretches under load automatically, because
/// each poll's scheduling delay is itself the contention. That is the more
/// robust shape. It is not adopted here because a deadline bounds a
/// genuinely hung condition to a stated number of seconds and can say so
/// in the failure — `condition did not hold within 64.0s` names its own
/// budget, where `400 polls` does not tell a reader how long it waited.
/// A multiplied deadline keeps the diagnostic and buys the headroom.
///
/// **What a bigger budget costs on a healthy run: nothing.** These are
/// polling waits — they return the instant the condition holds, and the
/// measurements above are what they actually take. The only run this
/// changes is one where a condition never holds, which now takes longer to
/// report a failure it was always going to report. A false red costs every
/// branch every run; a true red reported eight times slower costs once.
///
/// Eight, against a measured worst case of 1.3× the budget, is roughly six
/// times the headroom that run needed. That is deliberate: the number that
/// failed was chosen to look generous too, and the suite only grows.
let testWaitLoadMultiplier: Double = 8
