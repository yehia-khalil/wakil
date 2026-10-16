import Testing
@testable import WakilKit

private func armed(at t: Double = 0) -> ListeningMachine {
    var m = ListeningMachine()
    _ = m.optionDown(at: t)
    _ = m.tick(at: t + ListeningMachine.armDelay)
    return m
}

@Test func holdingOptionAloneArmsAfter180ms() {
    var m = ListeningMachine()
    #expect(m.optionDown(at: 0) == [])
    #expect(m.tick(at: 0.17) == [])
    #expect(m.tick(at: 0.18) == [.startEngine])
    #expect(m.isCapturing)
}

@Test func releasingBefore180msDoesNothing() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0)
    #expect(m.optionUp(at: 0.1) == [])
    #expect(m.tick(at: 1) == [])
    #expect(m.phase == .idle)
}

/// ⌥ chorded with a key or a click is an ordinary modifier (rule 7).
@Test func anotherKeyOrClickWhileArmingCancels() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0)
    _ = m.otherInput()
    #expect(m.tick(at: 0.5) == [])
    #expect(m.phase == .idle)
}

@Test func releaseStopsTheEngineAndTheFinalLands() {
    var m = armed()
    _ = m.receive(.partial(settled: "open the", volatile: "book"))
    #expect(m.optionUp(at: 1) == [.stopEngine])
    #expect(m.receive(.final("open the booking")) == [.land("open the booking")])
    #expect(m.phase == .idle)
}

@Test func anEmptyFinalLandsNothing() {
    var m = armed()
    _ = m.optionUp(at: 1)
    #expect(m.receive(.final("")) == [])
}

@Test func escapeWhileHoldingDiscards() {
    var m = armed()
    _ = m.receive(.partial(settled: "drop the table", volatile: ""))
    #expect(m.escape() == [.cancelEngine])
    #expect(m.phase == .idle)
    #expect(m.heard == "")
}

@Test func escapeWhenIdleIsNotConsumed() {
    var m = ListeningMachine()
    #expect(m.escape() == [])
}

/// Losing focus while holding is a release (rule 2: input is never lost).
@Test func resigningActiveIsARelease() {
    var m = armed()
    #expect(m.resigned(at: 1) == [.stopEngine])
}

@Test func noAudioFor1_5sNamesTheDevice() {
    var m = armed(at: 0)
    _ = m.receive(.started(device: "MacBook Pro Microphone"))
    _ = m.tick(at: 1.6)
    #expect(m.notice == nil, "1.42 s since listening began is under the threshold")
    _ = m.tick(at: 0.18 + 1.5)
    #expect(m.notice == .heardNothing(device: "MacBook Pro Microphone"))
}

@Test func soundClearsTheSilenceNotice() {
    var m = armed(at: 0)
    _ = m.tick(at: 5)
    #expect(m.notice != nil)
    _ = m.receive(.audio)
    #expect(m.notice == nil)
}

/// A pause mid-sentence is not a dead microphone.
@Test func aPauseAfterSoundNeverRaisesTheNotice() {
    var m = armed(at: 0)
    _ = m.receive(.audio)
    _ = m.tick(at: 10)
    #expect(m.notice == nil)
}

@Test func deniedAndDownloadingAreNotices() {
    var m = armed()
    _ = m.receive(.downloading(fraction: 0.4, totalBytes: 120_000_000))
    #expect(m.notice == .downloading(fraction: 0.4, totalBytes: 120_000_000))
    _ = m.receive(.denied)
    #expect(m.notice == .denied)
}

/// Review focus 3: a provider that never sends `.final`.
@Test func finishingTimesOutAndLandsWhatWasHeard() {
    var m = armed()
    _ = m.receive(.partial(settled: "show tables", volatile: ""))
    _ = m.optionUp(at: 1)
    #expect(m.tick(at: 2.9) == [])
    #expect(m.tick(at: 3.0) == [.cancelEngine, .land("show tables")])
    #expect(m.phase == .idle)
}

/// Review focus 2: released before any engine started.
@Test func finishingWithNothingHeardTimesOutToIdle() {
    var m = armed()
    _ = m.optionUp(at: 1)
    #expect(m.tick(at: 3.0) == [.cancelEngine])
    #expect(m.phase == .idle)
}

/// Spec: engine fails mid-utterance — words so far land, the error is reported.
@Test func aFailureLandsWhatWasHeardAndReportsIt() {
    var m = armed()
    _ = m.receive(.partial(settled: "open", volatile: "the"))
    #expect(m.receive(.failed("engine stopped")) == [.land("open the"), .failed("engine stopped")])
    #expect(m.phase == .idle)
}

@Test func eventsWhileIdleAreIgnored() {
    var m = ListeningMachine()
    #expect(m.receive(.partial(settled: "stale", volatile: "")) == [])
    #expect(m.heard == "")
}

@Test func heardJoinsSettledAndVolatile() {
    var m = armed()
    _ = m.receive(.partial(settled: " open the ", volatile: "book "))
    #expect(m.heard == "open the book")
}

/// A chord after the arm delay, before anything was heard, is a modifier
/// use that slipped past the 180 ms: the mic closes, as with Esc.
@Test func otherInputWhileListeningWithNothingHeardCancels() {
    var m = armed()
    #expect(!m.swallowsOtherInput)
    #expect(m.otherInput() == [.cancelEngine])
    #expect(m.phase == .idle)
}

@Test func otherInputWhileListeningWithWordsHeardChangesNothingAndIsSwallowed() {
    var m = armed()
    _ = m.receive(.partial(settled: "open", volatile: ""))
    #expect(m.swallowsOtherInput)
    #expect(m.otherInput() == [])
    #expect(m.isCapturing)
    #expect(m.heard == "open")
}

@Test func startedClearsTheDownloadingNoticeAndRestartsTheSilenceClock() {
    var m = armed(at: 0)
    _ = m.receive(.downloading(fraction: 0.5, totalBytes: 100))
    _ = m.tick(at: 20)
    _ = m.receive(.started(device: "Mic"), at: 20)
    #expect(m.notice == nil)
    _ = m.tick(at: 21.4)
    #expect(m.notice == nil, "1.4 s after listening really began")
    _ = m.tick(at: 21.5)
    #expect(m.notice == .heardNothing(device: "Mic"))
}

@Test func audioClearsTheDownloadingNotice() {
    var m = armed()
    _ = m.receive(.downloading(fraction: 0.5, totalBytes: 100))
    _ = m.receive(.audio)
    #expect(m.notice == nil)
}

@Test func anEmptyFinalLandsWhatWasAlreadyHeard() {
    var m = armed()
    _ = m.receive(.partial(settled: "open the book", volatile: ""))
    _ = m.optionUp(at: 1)
    #expect(m.receive(.final("  ")) == [.land("open the book")])
    #expect(m.phase == .idle)
}

// MARK: - Permission notices outlive the hold (2d-ii walk)

/// The first hold on a fresh build raises the macOS prompt, which takes the
/// key window and so ends the hold at once. The sentence must still be on
/// screen afterwards, or the bar looks dead.
@Test func aPermissionPendingNoticeOutlivesTheHold() {
    var m = armed()
    _ = m.receive(.permissionPending)
    _ = m.resigned(at: 0.3)
    _ = m.tick(at: 3)                       // the finish timeout ends the hold
    #expect(m.phase == .idle)
    #expect(m.standingNotice == .permissionPending)
}

/// The same for a refusal: the operator must be able to read where to go.
@Test func aDeniedNoticeOutlivesTheHold() {
    var m = armed()
    _ = m.receive(.denied)
    _ = m.optionUp(at: 1)
    _ = m.tick(at: 4)
    #expect(m.standingNotice == .denied)
}

@Test func theNextHoldClearsAStandingNotice() {
    var m = armed()
    _ = m.receive(.permissionPending)
    _ = m.optionUp(at: 1); _ = m.tick(at: 4)
    _ = m.optionDown(at: 10)
    #expect(m.standingNotice == nil)
}
