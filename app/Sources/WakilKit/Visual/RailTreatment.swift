import Foundation

/// The treatment of the rail — `design-language.md` §10's list of open panes,
/// and §3's promotion rule applied to it.
///
/// **Why this is not simply `Plane.far`.** It was, permanently, and the rail
/// held no hover or promotion code at all — yet a click on a row dispatched
/// `pane_focus`. §3 says *"far-plane content is never interactive without
/// first being promoted"*, and nothing promoted it (#138). The same paragraph
/// of §10 that puts the rail on the far plane already named the missing
/// state in its own words: the rail is "low opacity **until relevant**".
/// Nothing ever made it relevant. The only opacity change the rail had was
/// the *other* direction — `deferredOpacity`, which is deference.
///
/// **Two defects, one state.** Riding the far plane whole, `#e8ecf6` at 0.30
/// composites to ≈2.35:1 over the void, against the 4.5:1 floor `PRODUCT.md`
/// binds for anything being *read* — and a list of pane names read in order
/// to pick one is being read. That is the failure `EnvironmentBadge` was
/// created to fix at 1.47:1, reached by the same route: a far-plane dimming
/// multiplier applied to something whose whole job is to be legible.
/// Promotion clears it at the moment it is read, which is why the fix is one
/// change and not two.
///
/// **Not the badge's exemption, and the difference matters.** The badge (and
/// since 2026-09-20 the whole context line) is exempt from opacity and blur
/// *permanently*, because Invariant 8 puts the environment on screen at all
/// times and there is no moment at which it is allowed to be unreadable. The
/// rail has such a moment — most of them, in fact. It answers "what is open"
/// when asked, and at rest it is ambient furniture that genuinely is not
/// being read. So the rail takes §3's other remedy: it stays on the far plane
/// and is **promoted to the mid plane whole** when the pointer arrives, which
/// is the operator saying they are about to read it.
///
/// This type exists in `WakilKit` rather than in `WakilApp` for the reason
/// `EnvironmentBadge` does: `WakilApp` has no test target, and the contrast
/// claim above is arithmetic that must be assertable. `RailTreatmentTests`
/// holds it — both that the promoted state clears the floor and that the
/// ambient state would fail it, so the treatment cannot be quietly undone.
public enum RailTreatment {
    /// §5's ordinary text luminance, `#e8ecf6` — the pane names and kinds.
    /// Read from `EnvironmentBadge` rather than respelled as a literal: two
    /// copies of a value drift, and this is the same cool white by
    /// definition rather than by coincidence.
    public static let textColour = EnvironmentBadge.ordinaryColour

    /// §10's "luminous left tick" on the active pane — `#9e82ff`, read from
    /// `VoidPalette.accent`, which this change gave the hue its one home in.
    /// It was a literal in `ContextLine` and `OrgPlane` and would have become
    /// a third copy here, inside the layer that exists to end them.
    public static let activeTickColour = VoidPalette.accent

    /// §10's "a working pane glows green in the periphery" — §5's reserved
    /// green, read from `TerminalPalette` for the reason
    /// `EnvironmentBadge.productionColour` reads `VoidPalette.red`.
    ///
    /// **This replaces the word "working".** The rail drew
    /// `Text(pane.busy ? "working" : "")` — a glyph, in cool white, at 0.30
    /// behind a 1.4px blur, which is the least peripherally legible
    /// treatment available. A hue shift on the tick survives the far plane
    /// precisely because noticing it does not require resolving anything,
    /// and a luminous tick is the one such mark §8 already permits.
    public static let workingTickColour = TerminalPalette.green

    /// §10's maximize fade: "the rail and Core fade back" — not to zero,
    /// which would read as a bug rather than as deference. The room defers
    /// too while maximized, by a different mechanism and to a different
    /// degree (0.4 in `VoidView.Coordinator`); the two were never the same
    /// fade, only the same rule.
    public static let deferredOpacity: Double = 0.12

    /// §7's plane transition, 400–600ms ease-out, near the bottom of the
    /// band: the rail is chrome the operator crosses many times a day, not
    /// the room breathing. `ContextLine.promote` takes 0.40 for the same
    /// reason; this is 0.45 because that is what the rail's maximize fade
    /// has always used, and two speeds on one surface would read as two
    /// surfaces.
    ///
    /// **One constant for both of the rail's plane moves** — promotion and
    /// the maximize fade — on `ContextLine.promote`'s own reasoning: two
    /// constants holding the same value are an invitation to drift apart by
    /// accident rather than by decision.
    public static let planeTransition: Double = 0.45

    /// §7 again, and the artboards' own `transition: background 240ms
    /// ease-out` on a row. A row highlight is not a plane move and should not
    /// borrow a plane move's duration.
    public static let rowHoverDuration: Double = 0.24

    /// How far the pane *kind* is stepped down from the name beside it —
    /// §5's way of quieting text, "by opacity rather than by hue".
    ///
    /// **Not the artboard's 0.46, and the difference is the floor.** A kind
    /// is read: it is half of how the operator tells `bookings` the database
    /// from `bookings` the terminal. At 0.46 the promoted row composites it
    /// to **4.09:1**, under the 4.5:1 `PRODUCT.md` binds against the actual
    /// composite — the artboard drew the hierarchy without measuring it, and
    /// where the two disagree the binding requirement wins. Cool white
    /// crosses the floor at **α ≈ 0.489**; 0.55 is taken for the margin
    /// `EnvironmentBadge` takes 1.0 for, and still reads a clear step below
    /// the name.
    public static let kindOpacity: Double = 0.55

    /// How strongly the row under the pointer lifts, once promoted.
    /// `Rail.dc.html` state 3: `rgba(232,236,246,0.05)`.
    public static let rowHoverTint: Double = 0.05

    // MARK: - The spine (the collapsed rail)

    /// A spine mark's opacity, by what it says. The quiet marks are on the far plane, as the rail
    /// is at rest; the active and working marks are not dimmed with them, because a 2 pt mark at 0.30
    /// is a smudge and the hue is the whole message — "what is open" and "what is working" stay
    /// readable collapsed. Scale and blur are not applied to a mark at all: 1.4 px of blur on a 2 pt
    /// line is its whole width.
    ///
    /// **While a pane is maximized the whole spine defers**, as the rail does (`deferredOpacity`):
    /// the same fade, one rule. Promotion outranks it the same way — the pointer on the spine brings
    /// the rail out, and the rail is promoted.
    ///
    /// Takes the two facts rather than the mark, so `Visual/` stays below `Layout/`.
    public static func spineOpacity(working: Bool, active: Bool, isMaximized: Bool) -> Double {
        if isMaximized { return deferredOpacity }
        if working { return 1.0 }
        return active ? 0.95 : 0.6
    }

    /// What the peeked rail sits on. Out over the canvas the pane names would be read against
    /// whatever pane is under them, and the 4.5:1 floor is measured against the void; so the rail
    /// brings the void with it, `Contrast.voidBase`, nearly opaque — the one place on this surface
    /// that a backing is earned rather than decorative.
    public static let peekSlabColour = Contrast.voidBase
    public static let peekSlabOpacity: Double = 0.9

    public static func scale(promoted: Bool) -> Double {
        promoted ? Plane.mid.scale : Plane.far.scale
    }

    public static func blur(promoted: Bool) -> Double {
        promoted ? Plane.mid.blur : Plane.far.blur
    }

    /// **Promotion outranks deference.** While a pane is maximized every
    /// other pane is hidden behind it, so the rail is the only way back to
    /// them — which is the reason §10 gives for the rail existing at all. A
    /// deferred rail that stayed at 0.12 under the pointer would be
    /// interactive far-plane content again, at 1.28:1 rather than the 2.35:1
    /// that §3 already forbids.
    ///
    /// `Rail.dc.html` draws the deferred state without a pointer on it and so
    /// does not rule on this; it is settled here rather than left to the
    /// order two modifiers happen to be applied in.
    public static func opacity(promoted: Bool, isMaximized: Bool) -> Double {
        if promoted { return Plane.mid.opacity }
        return isMaximized ? deferredOpacity : Plane.far.opacity
    }

    /// What a reader actually gets, composited over the void — not what the
    /// foreground colour would give on its own. Measuring the foreground
    /// instead is the mistake that let a 1.46:1 badge ship.
    ///
    /// `elementOpacity` is the row's own step-down, which multiplies with the
    /// plane's: a kind at `kindOpacity` on an ambient rail is drawn at
    /// 0.55 × 0.30, and a floor measured on either factor alone would miss
    /// the one a reader is actually looking at.
    ///
    /// Only the two states the rail is *read* in are reachable here. The
    /// maximize fade is deference — nobody reads a rail they have just
    /// pushed behind a maximized pane, and the moment they point at it, it is
    /// promoted.
    public static func effectiveContrast(
        _ colour: RGB, elementOpacity: Double = 1, promoted: Bool
    ) -> Double {
        Contrast.effectiveRatio(
            colour,
            alpha: elementOpacity * opacity(promoted: promoted, isMaximized: false),
            over: Contrast.voidBase)
    }
}
