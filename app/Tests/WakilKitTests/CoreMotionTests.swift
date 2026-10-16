import Testing
@testable import WakilKit

/// `design-language.md` §7's table, verbatim. The room inherits the sphere's
/// cadences rather than inventing new ones, and these two are the only
/// periods the design language actually states.
@Test func idleAndListeningKeepTheDesignLanguagesPeriods() {
    #expect(CoreMotion.forState(.idle).period == 5.4)
    #expect(CoreMotion.forState(.listening).period == 1.5)
}

/// Spec §3: idle is "present but asleep" and listening is "attending", so
/// idle has the lowest ceiling of the four and listening the highest.
///
/// Stated as ceilings rather than as "dimmest"/"brightest" on purpose:
/// thinking's *floor* (0.30) is below idle's (0.55), because thinking's two
/// bleeds trade dominance and each one dips further than idle ever does.
/// A test asserting idle is lowest on both ends would be asserting something
/// false.
@Test func idleHasTheLowestCeilingAndListeningTheHighest() {
    let idle = CoreMotion.forState(.idle)
    let listening = CoreMotion.forState(.listening)
    for state in CoreState.allCases where state != .idle {
        #expect(idle.amplitudeHigh < CoreMotion.forState(state).amplitudeHigh)
    }
    for state in CoreState.allCases where state != .listening {
        #expect(listening.amplitudeHigh > CoreMotion.forState(state).amplitudeHigh)
    }
}

@Test func everyStatesAmplitudeRangeIsOrdered() {
    for state in CoreState.allCases {
        let motion = CoreMotion.forState(state)
        #expect(motion.amplitudeLow < motion.amplitudeHigh)
    }
}

/// §4's word for listening is "tighten", and spread is the only channel that
/// can express it for a room. No other state touches it.
@Test func listeningIsTheOnlyStateThatChangesSpread() {
    for state in CoreState.allCases {
        let spread = CoreMotion.forState(state).spreadFactor
        #expect(state == .listening ? spread > 1.0 : spread == 1.0)
    }
}

/// Thinking is "internal turbulence": the only state whose bleeds move, and
/// the only one whose two bleeds are out of phase so they trade dominance
/// rather than brightening together.
@Test func thinkingIsTheOnlyStateWithDriftOrAntiphase() {
    for state in CoreState.allCases {
        let motion = CoreMotion.forState(state)
        if state == .thinking {
            #expect(motion.driftAmplitude > 0)
            #expect(motion.driftPeriod > 0)
            #expect(motion.bleedBPhase == 0.5)
        } else {
            #expect(motion.driftAmplitude == 0)
            #expect(motion.bleedBPhase == 0)
        }
    }
}

/// Spec §3: speaking's 0.42s pulse is contained by geometry, not by a small
/// constant. Upper coupling 0 means the upper-right bleed holds still while
/// only the lower bleed pulses, so no large peripheral area ever flickers at
/// speech rate. Every other state modulates both bleeds together.
@Test func speakingIsTheOnlyStateWhosePulseIsLocalToTheLowerBleed() {
    for state in CoreState.allCases {
        let coupling = CoreMotion.forState(state).upperCoupling
        #expect(state == .speaking ? coupling == 0 : coupling == 1)
    }
}

/// Spec §5's rule: each state buys the smoothness its own period needs and
/// no more. Below 25 frames a cycle, motion reads as stepping.
///
/// **Against the requested rate.** This alone is not the floor that matters
/// — see the 60 Hz test below — but it stays because a state that fails
/// even at its own requested rate is a plainer bug than one that only fails
/// once a panel refresh rate caps it.
@Test func everyStateGetsAtLeastTwentyFiveFramesPerCycle() {
    for state in CoreState.allCases {
        #expect(CoreMotion.forState(state).framesPerCycle >= 25)
    }
}

/// Ruling R15 (final whole-branch review, Important 5): asserting the floor
/// against `framesPerCycle` alone passes with 2× margin for speaking
/// (120 × 0.42 = 50.4) while the number the spec calls "the tight one,
/// exactly at the floor" is 60 × 0.42 = 25.2, on the 60 Hz panels this
/// machine actually has. A tuning pass that shortened speaking's period to,
/// say, 0.30 s would still pass the requested-rate test (36 frames) while
/// the real, panel-capped number (18) falls well under the floor. Asserting
/// `effectiveFramesPerCycle(atPanelHz: 60)` closes that gap.
@Test func everyStateGetsAtLeastTwentyFiveFramesPerCycleOnASixtyHertzPanel() {
    for state in CoreState.allCases {
        #expect(CoreMotion.forState(state).effectiveFramesPerCycle(atPanelHz: 60) >= 25)
    }
}

/// north-star.md's frame-rate section: 120 is the ceiling, as a statement of
/// intent and a guard on future hardware. Nothing may ask for more.
@Test func noStateAsksForMoreThanOneHundredAndTwentyFramesPerSecond() {
    for state in CoreState.allCases {
        let rate = CoreMotion.forState(state).restingFrameRate
        #expect(rate > 0)
        #expect(rate <= 120)
    }
}

@Test func threadLiftIsZeroWithNoRows() {
    #expect(ThreadLift.value(hasRows: false, isTurnInFlight: true, secondsSinceLastRow: 0) == 0)
}

@Test func threadLiftIsFullWhileATurnIsInFlight() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: true, secondsSinceLastRow: 99) == 1)
}

/// Decays to zero over `decaySeconds` after the last row, so the glow fades
/// with the thread rather than snapping off with it.
@Test func threadLiftDecaysToZeroAfterTheLastRow() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: 0) == 1)
    #expect(abs(ThreadLift.value(hasRows: true, isTurnInFlight: false,
                                 secondsSinceLastRow: ThreadLift.decaySeconds / 2) - 0.5) < 1e-9)
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false,
                             secondsSinceLastRow: ThreadLift.decaySeconds) == 0)
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: 10) == 0)
}

/// A clock that goes backwards — which `Date` can, across an NTP step — must
/// not produce a lift above 1 and blow the bleed out.
@Test func threadLiftClampsANegativeElapsedTime() {
    #expect(ThreadLift.value(hasRows: true, isTurnInFlight: false, secondsSinceLastRow: -5) == 1)
}
