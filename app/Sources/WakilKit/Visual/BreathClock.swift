import Foundation

/// The room's breath across state changes (2d-ii).
///
/// `Void.metal` computes `phase = 2π · time / period`. Passing wall time
/// made every period change — idle's 5.4 s to listening's 1.5 s the moment
/// ⌥ arms — jump the breath mid-cycle. This counts **cycles** instead and
/// hands the shader `cycles × period`, so the phase continues from where
/// it was. Strength, spread, drift and coupling ease toward the new state
/// over `easeSeconds`; the period itself switches at once, which is exactly
/// what phase continuity makes safe.
///
/// Drift needs the same care: the shader reads `time / driftPeriod`, and
/// leaving thinking switches the state's `driftPeriod` to 0 while the drift
/// amplitude is still easing down. So drift keeps its own cycle count and
/// held period on the CPU, and the emitted `driftPeriod` is back-solved
/// (`time / driftCycles`) so the shader's drift angle equals `driftCycles`
/// on every transition and the period is never 0.
public struct BreathClock: Sendable {
    public static let easeSeconds: Double = 0.25

    private var cycles: Double = 0
    private var shown: CoreMotion?
    private var driftCycles: Double = 0
    private var driftPeriodHeld: Double = 12

    public init() {}

    public mutating func advance(
        by dt: Double, toward target: CoreMotion, reduceMotion: Bool
    ) -> (time: Double, motion: CoreMotion) {
        let goal = reduceMotion ? Self.still(target) : target
        let eased: CoreMotion
        if let shown {
            let k = min(max(dt / Self.easeSeconds, 0), 1)
            func ease(_ from: Double, _ to: Double) -> Double { from + (to - from) * k }
            eased = CoreMotion(
                period: goal.period,
                amplitudeLow: ease(shown.amplitudeLow, goal.amplitudeLow),
                amplitudeHigh: ease(shown.amplitudeHigh, goal.amplitudeHigh),
                spreadFactor: ease(shown.spreadFactor, goal.spreadFactor),
                driftAmplitude: ease(shown.driftAmplitude, goal.driftAmplitude),
                driftPeriod: goal.driftPeriod,
                bleedBPhase: ease(shown.bleedBPhase, goal.bleedBPhase),
                upperCoupling: ease(shown.upperCoupling, goal.upperCoupling),
                restingFrameRate: goal.restingFrameRate)
        } else {
            eased = goal
        }
        shown = eased
        cycles += max(dt, 0) / max(goal.period, 1e-4)
        let time = cycles * goal.period
        if goal.driftPeriod > 0 { driftPeriodHeld = goal.driftPeriod }
        driftCycles += max(dt, 0) / driftPeriodHeld
        let driftPeriod = driftCycles > 0 ? time / driftCycles : driftPeriodHeld
        return (time, eased.withDriftPeriod(driftPeriod))
    }

    /// Reduce Motion: the state's brightness and tightness stay, its
    /// movement goes — amplitude pinned at the mean, no drift.
    private static func still(_ m: CoreMotion) -> CoreMotion {
        let mean = (m.amplitudeLow + m.amplitudeHigh) / 2
        return CoreMotion(
            period: m.period, amplitudeLow: mean, amplitudeHigh: mean,
            spreadFactor: m.spreadFactor, driftAmplitude: 0, driftPeriod: m.driftPeriod,
            bleedBPhase: m.bleedBPhase, upperCoupling: m.upperCoupling,
            restingFrameRate: m.restingFrameRate)
    }
}

private extension CoreMotion {
    func withDriftPeriod(_ p: Double) -> CoreMotion {
        CoreMotion(
            period: period, amplitudeLow: amplitudeLow, amplitudeHigh: amplitudeHigh,
            spreadFactor: spreadFactor, driftAmplitude: driftAmplitude, driftPeriod: p,
            bleedBPhase: bleedBPhase, upperCoupling: upperCoupling,
            restingFrameRate: restingFrameRate)
    }
}
