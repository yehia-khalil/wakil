import Testing
import simd
@testable import WakilKit

/// **The layout guard.** `setFragmentBytes` is a raw memory copy with no
/// schema, so `VoidUniforms` and `Void.metal`'s struct must agree byte for
/// byte. Metal's `float3` is 16-byte aligned and 16 bytes long and Swift's
/// `SIMD3<Float>` matches, which is why the two `float3`s sit where they do.
/// A `float3` appended *after* the run of plain floats would silently repad
/// the struct on one side only and corrupt every field after it.
///
/// The rule this enforces: **every `SIMD3` comes first, and every field
/// after the last one is a plain `Float` or `SIMD2<Float>`.** If this test
/// fails, do not update the number — work out which field broke the rule.
@Test func theWireFormatsLayoutIsPinned() {
    #expect(MemoryLayout<VoidUniforms>.stride == 112)
    #expect(MemoryLayout<VoidUniforms>.alignment == 16)
    // `stride` alone does not close the hazard: the struct has 8 bytes of
    // tail padding (`size` 104 rounds up to a 112 stride), so appending one
    // or two trailing `Float`s — or reordering any two fields — leaves
    // `stride` at 112 either way. Reordering is the worse failure, since it
    // silently corrupts every field past the swap rather than merely
    // failing to grow the struct. `size` has no padding slack, so it alone
    // catches a trailing-float addition; the `offset(of:)` checks below pin
    // the ordering itself, at the front (past the two `SIMD3`s) and the
    // back (the last field before the tail padding).
    #expect(MemoryLayout<VoidUniforms>.size == 104)
    #expect(MemoryLayout<VoidUniforms>.offset(of: \.bleedA) == 16)
    #expect(MemoryLayout<VoidUniforms>.offset(of: \.time) == 56)
    #expect(MemoryLayout<VoidUniforms>.offset(of: \.ambientScale) == 100)
}

/// The environment owns the hue and the agent owns the movement (spec §2).
/// The palette's two colours must reach the shader untouched no matter what
/// state the room is in — if a state could tint them, the split has broken.
@Test func stateNeverTouchesTheBleedColours() {
    let production = VoidPalette.forEnvironment("production", production: .undeclared)
    for state in CoreState.allCases {
        let uniforms = VoidUniforms(
            resolution: SIMD2(900, 620), palette: production, parallax: .zero,
            time: 3.0, motion: CoreMotion.forState(state),
            threadAnchorX: 0.5, threadLift: 0, ambientScale: 1)
        #expect(uniforms.bleedA == SIMD3(Float(production.bleedA.r),
                                         Float(production.bleedA.g),
                                         Float(production.bleedA.b)))
        #expect(uniforms.bleedB == SIMD3(Float(production.bleedB.r),
                                         Float(production.bleedB.g),
                                         Float(production.bleedB.b)))
    }
}

/// Every motion field arrives at the shader as the `CoreMotion` gave it.
@Test func theMotionFieldsAreCarriedThroughUnchanged() {
    let motion = CoreMotion.forState(.thinking)
    let uniforms = VoidUniforms(
        resolution: SIMD2(900, 620), palette: VoidPalette.forEnvironment("staging", production: .undeclared),
        parallax: .zero, time: 1.0, motion: motion,
        threadAnchorX: 0.25, threadLift: 0.5, ambientScale: 0.4)
    #expect(uniforms.period == Float(motion.period))
    #expect(uniforms.amplitudeLow == Float(motion.amplitudeLow))
    #expect(uniforms.amplitudeHigh == Float(motion.amplitudeHigh))
    #expect(uniforms.spreadFactor == Float(motion.spreadFactor))
    #expect(uniforms.driftAmplitude == Float(motion.driftAmplitude))
    #expect(uniforms.driftPeriod == Float(motion.driftPeriod))
    #expect(uniforms.bleedBPhase == Float(motion.bleedBPhase))
    #expect(uniforms.upperCoupling == Float(motion.upperCoupling))
    #expect(uniforms.threadAnchorX == 0.25)
    #expect(uniforms.threadLift == 0.5)
    #expect(uniforms.ambientScale == 0.4)
}
