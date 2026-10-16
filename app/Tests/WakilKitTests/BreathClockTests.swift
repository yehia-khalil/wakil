import Testing
@testable import WakilKit

private func phase(_ frame: (time: Double, motion: CoreMotion)) -> Double {
    frame.time / frame.motion.period
}

/// The bug this fixes: the shader's phase is time/period, so changing the
/// period mid-breath jumped the room. Cycles must carry over.
@Test func phaseIsContinuousIntoListening() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.idle), reduceMotion: false)
    for _ in 0..<60 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false) }
    let before = phase(frame)
    let after = phase(clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: false))
    #expect(abs(after - before) < 0.02, "phase jumped from \(before) to \(after)")
}

@Test func phaseIsContinuousBackToIdle() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0.7, toward: .forState(.listening), reduceMotion: false)
    let before = phase(frame)
    frame = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false)
    #expect(abs(phase(frame) - before) < 0.02)
}

@Test func amplitudeEasesRatherThanSnapping() {
    var clock = BreathClock()
    for _ in 0..<120 { _ = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false) }
    let first = clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: false).motion
    let idle = CoreMotion.forState(.idle), listening = CoreMotion.forState(.listening)
    #expect(first.amplitudeHigh > idle.amplitudeHigh)
    #expect(first.amplitudeHigh < listening.amplitudeHigh, "one frame in, the ease is not finished")
    var settled = first
    for _ in 0..<120 { settled = clock.advance(by: 1.0 / 60, toward: listening, reduceMotion: false).motion }
    #expect(abs(settled.amplitudeHigh - listening.amplitudeHigh) < 0.001)
    #expect(abs(settled.spreadFactor - listening.spreadFactor) < 0.001)
}

@Test func theFirstFrameTakesTheTargetAsIs() {
    var clock = BreathClock()
    let frame = clock.advance(by: 0.15, toward: .forState(.listening), reduceMotion: false)
    let want = CoreMotion.forState(.listening), got = frame.motion
    // driftPeriod is back-solved to keep the drift angle continuous, so it is not the target's.
    #expect(got.period == want.period && got.amplitudeLow == want.amplitudeLow
        && got.amplitudeHigh == want.amplitudeHigh && got.spreadFactor == want.spreadFactor
        && got.driftAmplitude == want.driftAmplitude && got.bleedBPhase == want.bleedBPhase
        && got.upperCoupling == want.upperCoupling && got.restingFrameRate == want.restingFrameRate)
    #expect(got.driftPeriod > 0)
}

@Test func reduceMotionHoldsAmplitudeAtTheMeanAndStopsDrift() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.thinking), reduceMotion: true)
    for _ in 0..<120 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.thinking), reduceMotion: true) }
    let thinking = CoreMotion.forState(.thinking)
    let mean = (thinking.amplitudeLow + thinking.amplitudeHigh) / 2
    #expect(abs(frame.motion.amplitudeLow - mean) < 0.001)
    #expect(abs(frame.motion.amplitudeHigh - mean) < 0.001)
    #expect(frame.motion.driftAmplitude < 0.001)
}

@Test func reduceMotionStillBrightensAndTightensForListening() {
    var clock = BreathClock()
    var frame = clock.advance(by: 0, toward: .forState(.listening), reduceMotion: true)
    for _ in 0..<60 { frame = clock.advance(by: 1.0 / 60, toward: .forState(.listening), reduceMotion: true) }
    #expect(frame.motion.spreadFactor == CoreMotion.forState(.listening).spreadFactor)
    #expect(frame.motion.amplitudeHigh > CoreMotion.forState(.idle).amplitudeHigh)
}

private func driftAngle(_ f: (time: Double, motion: CoreMotion)) -> Double {
    f.time / f.motion.driftPeriod
}

@Test func breathDriftPeriodNeverZeroWhileDriftEasesOut() {
    var clock = BreathClock()
    for _ in 0..<120 { _ = clock.advance(by: 1.0 / 60, toward: .forState(.thinking), reduceMotion: false) }
    for _ in 0..<60 {
        let f = clock.advance(by: 1.0 / 60, toward: .forState(.idle), reduceMotion: false)
        if f.motion.driftAmplitude > 0 { #expect(f.motion.driftPeriod > 0) }
        #expect(f.motion.driftPeriod > 0)
    }
}

@Test func breathDriftAngleIsContinuousAcrossThinking() {
    var clock = BreathClock()
    var prev = clock.advance(by: 0, toward: .forState(.idle), reduceMotion: false)
    for target in [CoreMotion.forState(.idle), .forState(.thinking), .forState(.idle)] {
        for _ in 0..<90 {
            let f = clock.advance(by: 1.0 / 60, toward: target, reduceMotion: false)
            #expect(abs(driftAngle(f) - driftAngle(prev)) < 0.02, "drift angle jumped")
            prev = f
        }
    }
}

@Test func breathDriftAdvancesAtOneTwelfthCycleSecondWhileThinking() {
    var clock = BreathClock()
    var f = clock.advance(by: 0, toward: .forState(.thinking), reduceMotion: false)
    for _ in 0..<60 { f = clock.advance(by: 1.0 / 60, toward: .forState(.thinking), reduceMotion: false) }
    let a = driftAngle(f)
    for _ in 0..<60 { f = clock.advance(by: 1.0 / 60, toward: .forState(.thinking), reduceMotion: false) }
    #expect(abs((driftAngle(f) - a) - 1.0 / 12) < 0.001)
}
