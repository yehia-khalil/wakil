import Foundation

/// The treatment of the environment badge — Invariant 8's implementation.
///
/// **Why the badge is not simply `Plane.far`.** It used to be. The badge is
/// ambient furniture, it sits beside the rail, and it inherited the far
/// plane's whole treatment: scale 0.94, opacity 0.30, blur 1.4. The code
/// comment that did it reasoned that the badge's *colour* is what makes
/// production unmissable and that "the plane treatment is orthogonal to it."
///
/// It is not orthogonal. Opacity and blur are the mechanism of legibility,
/// and composited against the void the result was **1.47:1 in production and
/// 2.35:1 out of it** — the lowest-contrast text in the application, against
/// a 4.5:1 floor. Worse, it inverted: red carries less luminance than white,
/// so one dimming multiplier applied to both made the *production* badge the
/// fainter of the two. Invariant 8 asks for "unmissable" and the
/// implementation delivered the least visible thing on screen, which is why
/// 2b-ii's visual review could only record that production read "warm rather
/// than alarming" without being able to say why.
///
/// **What is exempted, and what is not.** Depth has four channels here and
/// only two of them cost legibility. The badge keeps `Plane.far`'s scale and
/// parallax, so it still reads as the same distance as the rail and moves
/// with it — the room's spatial language is intact. It is exempted from
/// opacity and blur alone, which are the two that decide whether a reader can
/// resolve it. `Plane.far` itself is unchanged and still correct for the
/// rail: nothing on the rail is being read at the moment it matters.
///
/// Full opacity is chosen for margin, not because it is the only value that
/// works. Against the void `#e85c5c` crosses the 4.5:1 body-text floor at
/// **α ≈ 0.86** — 0.75 gives 3.65:1 and 0.90 gives 4.86:1 — so the usable
/// band is narrow and its lower edge sits close to the floor. 1.0 is taken so
/// that no later dimming, whether a fade, a deference rule or a plane change,
/// lands near that edge without someone noticing. `EnvironmentBadgeTests`
/// holds the arithmetic.
///
/// *(Corrected 2026-09-14: this read "clears the floor at 1.0 and nowhere
/// below it", which overstated the case — the crossover is ≈0.86. The choice
/// of 1.0 is unaffected; only the reason for it is.)*
public enum EnvironmentBadge {
    /// `#e85c5c` — the same value the room's bleeds use, read from the same
    /// palette rather than repeated as a literal, so the badge and the room
    /// cannot drift apart on hue any more than they can on meaning.
    public static let productionColour = VoidPalette.red

    /// `#e8ecf6`, §5's ordinary text luminance.
    public static let ordinaryColour = RGB(0.910, 0.925, 0.965)

    /// **Not `Plane.far.opacity`.** See the type comment: 0.30 puts this
    /// label at 1.47:1 in the state it exists to warn about.
    public static let opacity: Double = 1.0

    /// **Not `Plane.far.blur`.** A 1.4pt blur on 9pt tracked caps removes
    /// what little the opacity left.
    public static let blur: Double = 0.0

    /// The **chip** form's foreground, for the one place the badge is drawn
    /// as a filled token rather than as a line of text: the context line
    /// (`ContextLine.swift`), where every artboard in `docs/wakil/screens/`
    /// draws it as a chip.
    ///
    /// **Green, not `ordinaryColour`, and the difference is the element.**
    /// `ordinaryColour` is §5's ordinary *text* luminance, correct for a
    /// label rendered as a sentence. A chip is a token with a background, and
    /// §5's reserved table assigns green to "Local / staging · healthy" — so
    /// a chip painted cool white would be the one place in the app where an
    /// environment is shown without its own semantic hue.
    ///
    /// **A chip is also a shape, which is why it is worth having.** Colour
    /// alone has to be resolved; a filled token is legible peripherally as a
    /// silhouette, which is the same argument §10's green rail tick makes.
    ///
    /// Read from `TerminalPalette.green` rather than respelled as a literal,
    /// for the reason `productionColour` reads `VoidPalette.red`: two copies
    /// of a hue drift. That type exists to give §5's reserved hues one home —
    /// its own comment says the "what colour" question should have "one
    /// currency instead of two" — and it holds `#8be0c8` because the terminal
    /// carve-out needed it first. The name is historical; the value is §5's.
    public static func chipColour(isProduction: Bool) -> RGB {
        isProduction ? productionColour : TerminalPalette.green
    }

    /// How strongly the chip's own hue tints its background. Production is
    /// carried a shade stronger, matching the artboards: the one chip that
    /// must be unmissable gets the most present fill.
    public static func chipTintOpacity(isProduction: Bool) -> Double {
        isProduction ? 0.13 : 0.12
    }

    /// Spatially the badge is still far-plane furniture, so these two are
    /// deliberately inherited rather than restated.
    public static let scale = Plane.far.scale
    public static let parallaxFactor = Plane.far.parallaxFactor

    public static func colour(isProduction: Bool) -> RGB {
        isProduction ? productionColour : ordinaryColour
    }

    /// The badge's contrast against the void once its opacity has been
    /// composited — what a reader actually gets, not what the foreground
    /// colour would give on its own.
    public static func effectiveContrast(isProduction: Bool) -> Double {
        Contrast.effectiveRatio(
            colour(isProduction: isProduction), alpha: opacity, over: Contrast.voidBase)
    }
}
