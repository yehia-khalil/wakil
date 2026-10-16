import simd

/// The Swift half of `Void.metal`'s `VoidUniforms`. Field order and types
/// must match it exactly, because `setFragmentBytes` is a raw memory copy
/// with no schema.
///
/// **It lives in `WakilKit`, not beside the view that sends it**, so it can
/// be tested: a test target cannot import an executable target, and the wire
/// format's layout is precisely the kind of thing worth a test. `VoidView`
/// and `Capture.swift` both use this one declaration; there is no second
/// hand-copy of a memory layout anywhere.
///
/// **Layout rule, enforced by `VoidUniformsTests`:** every `SIMD3<Float>`
/// comes first, and every field after the last one is a plain `Float` or a
/// `SIMD2<Float>`. `SIMD3<Float>` is 16-byte aligned on both sides; appending
/// one after the run of floats below would repad the struct on one side only.
public struct VoidUniforms: Sendable, Equatable {
    public var resolution: SIMD2<Float>
    /// The bleed rising from below. **Environment, never state** (spec §2).
    public var bleedA: SIMD3<Float>
    /// The bleed from the upper right. **Environment, never state.**
    public var bleedB: SIMD3<Float>
    public var parallax: SIMD2<Float>
    /// Seconds since the view appeared.
    public var time: Float
    public var period: Float
    public var amplitudeLow: Float
    public var amplitudeHigh: Float
    public var spreadFactor: Float
    public var driftAmplitude: Float
    public var driftPeriod: Float
    public var bleedBPhase: Float
    public var upperCoupling: Float
    /// Where §9's thread meets the bottom edge, in uv. Measured from the
    /// thread's own laid-out frame, never assumed.
    public var threadAnchorX: Float
    public var threadLift: Float
    /// 1 normally; lower while a pane is maximized. Multiplies the **bleeds
    /// only** — never the field, the vignette or the grain — so a maximized
    /// window reads as the same room with the lights down rather than as a
    /// different, flatter surface.
    public var ambientScale: Float

    /// **`palette` is optional — Task 14, spec §8.5.** Before an
    /// organisation is open there is no environment, so there is nothing
    /// that owns a hue: `nil` draws the bare field, the vignette and the
    /// grain, with both bleeds at `(0, 0, 0)` so their gaussians (still
    /// computed below, in `Void.metal`) contribute no colour at all. This
    /// is deliberately not a third `VoidPalette` case and not
    /// `VoidPalette.forEnvironment("")` — the latter would return the
    /// ordinary violet/blue pair, asserting a non-production environment to
    /// a window that has none. `VoidPalette` itself is untouched; the
    /// absence is handled at this one boundary instead.
    public init(
        resolution: SIMD2<Float>,
        palette: VoidPalette?,
        parallax: SIMD2<Float>,
        time: Float,
        motion: CoreMotion,
        threadAnchorX: Float,
        threadLift: Float,
        ambientScale: Float
    ) {
        self.resolution = resolution
        self.bleedA = palette.map { SIMD3(Float($0.bleedA.r), Float($0.bleedA.g), Float($0.bleedA.b)) }
            ?? SIMD3(0, 0, 0)
        self.bleedB = palette.map { SIMD3(Float($0.bleedB.r), Float($0.bleedB.g), Float($0.bleedB.b)) }
            ?? SIMD3(0, 0, 0)
        self.parallax = parallax
        self.time = time
        self.period = Float(motion.period)
        self.amplitudeLow = Float(motion.amplitudeLow)
        self.amplitudeHigh = Float(motion.amplitudeHigh)
        self.spreadFactor = Float(motion.spreadFactor)
        self.driftAmplitude = Float(motion.driftAmplitude)
        self.driftPeriod = Float(motion.driftPeriod)
        self.bleedBPhase = Float(motion.bleedBPhase)
        self.upperCoupling = Float(motion.upperCoupling)
        self.threadAnchorX = threadAnchorX
        self.threadLift = threadLift
        self.ambientScale = ambientScale
    }
}
