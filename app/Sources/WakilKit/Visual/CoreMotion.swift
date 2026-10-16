import Foundation

/// How the room moves in each of `design-language.md` §4's four states.
///
/// **Why this is a Swift type and not constants inside the shader.**
/// `Core.metal` — the sphere this sub-phase deletes — branched on an integer
/// state uniform and carried its periods as literals inside the fragment
/// function. Repeating that here would put five *admittedly invented*
/// numbers (see below) somewhere nothing is testable, where no test can
/// assert they match §7's table, and where the tuning pass the acceptance
/// runbook requires would edit Metal source with no safety net.
/// `VoidPalette`'s doc comment states the rule this follows: WakilKit stays
/// free of AppKit so that every question with a right answer can be tested
/// without a display, and "does idle breathe at the period §7 gives" is
/// exactly such a question.
///
/// **Expressing everything as scalars keeps the shader branchless.** Two of
/// the properties below — `bleedBPhase` and `upperCoupling` — encode what
/// would otherwise be per-state special cases, so `Void.metal` has no
/// `if (state == …)` anywhere.
///
/// **Which numbers have a source and which are invented.** `period` for idle
/// (5.4 s) and listening (1.5 s) is `design-language.md` §7's own table.
/// Speaking's 0.42 s is `Core.metal`'s shipped pulse period. Everything
/// else — thinking's 12 s and its drift magnitude, listening's spread
/// factor, and all four amplitude ranges — is this sub-phase's invention,
/// recorded as such in the spec's §13. They are starting values for the
/// tuning pass, which is why they are all in one file.
public struct CoreMotion: Sendable, Equatable {
    /// Seconds for one full cycle of the state's own cadence.
    public let period: Double
    /// The bleeds' strength at the bottom of the cycle, as a multiplier
    /// where 1.0 is the void exactly as 2b-ii ships it.
    public let amplitudeLow: Double
    /// The bleeds' strength at the top of the cycle.
    public let amplitudeHigh: Double
    /// Multiplies the bleeds' Gaussian exponent, so **larger is tighter**.
    /// Listening is the only state that is not 1.0 — §4's "rings tighten",
    /// translated from a ring to a room.
    public let spreadFactor: Double
    /// How far the bleed centres travel, in uv units. Thinking only.
    public let driftAmplitude: Double
    /// Seconds for one full circuit of that drift. Zero when there is no
    /// drift; `Void.metal` guards the division.
    public let driftPeriod: Double
    /// Bleed B's phase offset as a fraction of a cycle. 0.5 — thinking's
    /// value — puts the two bleeds in antiphase so they trade dominance,
    /// which is what reads as turnover rather than as a faster breath.
    public let bleedBPhase: Double
    /// How much of the cycle's amplitude the upper-right bleed takes.
    /// 1 everywhere except speaking, where it is 0: the 0.42 s pulse then
    /// modulates only the lower bleed, so the room speaks from the bottom
    /// edge the voice and the thought thread already occupy and no large
    /// peripheral area flickers at speech rate. This is the strobe answer,
    /// and it is geometric rather than a small constant.
    public let upperCoupling: Double
    /// What `MTKView.preferredFramesPerSecond` is set to while this state is
    /// current and the pointer is at rest.
    public let restingFrameRate: Int

    /// Frames drawn in one full cycle at the resting rate. The floor is 25;
    /// below that a cycle reads as stepping rather than as motion.
    ///
    /// **Asserts against the requested rate, not the achievable one.** A
    /// display cannot draw faster than its own refresh rate no matter what
    /// `restingFrameRate` asks for — `effectiveFramesPerCycle(atPanelHz:)`
    /// is the honest version of this number, and the one the tuning pass
    /// must be checked against, since a 120fps ask silently becomes 60fps on
    /// this machine's panels.
    public var framesPerCycle: Double { Double(restingFrameRate) * period }

    /// Frames drawn in one full cycle at whichever is lower, the state's own
    /// `restingFrameRate` or the panel's refresh rate — `MTKView` cannot
    /// exceed the display it is attached to, so a state asking for more than
    /// the panel gives is silently capped rather than delivered. Speaking is
    /// the state this matters for: it asks for 120, which this machine's 60
    /// Hz panels halve to 60, landing at 25.2 frames per pulse — "the tight
    /// one, exactly at the floor" (spec §5) — a fact the requested-rate
    /// number alone hides.
    public func effectiveFramesPerCycle(atPanelHz panelHz: Int) -> Double {
        Double(min(restingFrameRate, panelHz)) * period
    }

    public static func forState(_ state: CoreState) -> CoreMotion {
        switch state {
        case .idle:
            // Present but asleep: the lowest ceiling of the four, and the
            // slowest cadence. 15 fps is 81 frames per breath, and safe on a
            // slow luminance ramp because the per-frame delta of a 5.4 s sine
            // is far below an 8-bit quantisation step — and because
            // `Void.metal`'s grain is a hash of position only, with no time
            // term, so it cannot shimmer or alias against a low rate.
            return CoreMotion(
                period: 5.4, amplitudeLow: 0.55, amplitudeHigh: 0.67,
                spreadFactor: 1.0, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 1, restingFrameRate: 15)
        case .listening:
            // The brightest state at rest, and the only one that tightens.
            return CoreMotion(
                period: 1.5, amplitudeLow: 0.95, amplitudeHigh: 1.25,
                spreadFactor: 1.35, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 1, restingFrameRate: 30)
        case .thinking:
            // 12 s has no precedent anywhere. `Core.metal` spun at ~28.6 s
            // (`time * 0.22` rad/s), which the probe found too slow to read
            // as motion at all once translated from a rotating gradient on a
            // small object to a brightness swing across two large bleeds.
            return CoreMotion(
                period: 12.0, amplitudeLow: 0.30, amplitudeHigh: 1.00,
                spreadFactor: 1.0, driftAmplitude: 0.04, driftPeriod: 12.0,
                bleedBPhase: 0.5, upperCoupling: 1, restingFrameRate: 15)
        case .speaking:
            // 120 is asked for and 60 is what this machine's panels give, so
            // this lands at 25.2 frames per pulse here — exactly at the floor.
            // That is a real constraint on shortening the period later, and
            // it is recorded rather than left to be discovered.
            return CoreMotion(
                period: 0.42, amplitudeLow: 0.85, amplitudeHigh: 1.00,
                spreadFactor: 1.0, driftAmplitude: 0, driftPeriod: 0,
                bleedBPhase: 0, upperCoupling: 0, restingFrameRate: 120)
        }
    }
}

/// How brightly the lower bleed lifts where §9's thought thread meets the
/// bottom edge — the coupling that makes the room look like it is giving
/// birth to the thread rather than merely hosting it.
///
/// **The most invented thing in this sub-phase**, and the spec says so:
/// nothing in `design-language.md` describes a locally-modulated bleed. It
/// lives here rather than in the shader for the same reason `CoreMotion`
/// does — a decay curve buried in Metal is a decay curve nobody can test.
public enum ThreadLift {
    /// How long the glow takes to fade after the last row arrives. Matched
    /// to nothing in particular; long enough that the glow fades with the
    /// thread rather than snapping off with it.
    public static let decaySeconds: Double = 0.6

    public static func value(
        hasRows: Bool, isTurnInFlight: Bool, secondsSinceLastRow: Double
    ) -> Double {
        guard hasRows else { return 0 }
        if isTurnInFlight { return 1 }
        // `max(_:0)` because `Date` can step backwards across an NTP
        // correction, and a negative elapsed time would otherwise produce a
        // lift above 1 and blow the bleed out.
        let elapsed = max(secondsSinceLastRow, 0)
        guard elapsed < decaySeconds else { return 0 }
        return 1 - elapsed / decaySeconds
    }
}
