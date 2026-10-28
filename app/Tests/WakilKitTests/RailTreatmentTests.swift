import Testing
@testable import WakilKit

// `design-language.md` §3: "Far-plane content is never interactive without
// first being promoted." The rail was interactive and was never promoted
// (#138). These are that rule, and §10's "low opacity *until relevant*",
// stated as numbers — on `EnvironmentBadgeTests`' own pattern, because the
// defect is the same one: a far-plane dimming multiplier applied to
// something whose whole job is to be legible.

@Test func thePromotedRailClearsTheBodyTextFloor() {
    let ratio = RailTreatment.effectiveContrast(RailTreatment.textColour, promoted: true)
    #expect(
        ratio >= Contrast.bodyTextFloor,
        "promoted rail is \(ratio):1, floor is \(Contrast.bodyTextFloor):1")
}

/// **Every text on the row, not just the brightest one.** The row draws two:
/// the pane's title at full strength and its kind stepped down by opacity,
/// which is §5's way of quieting text. A floor measured on the title alone
/// would have passed this file while the kind — half of how `bookings` the
/// database is told from `bookings` the terminal — sat at 4.09:1, which is
/// what `Rail.dc.html` drew and what 0.46 gives.
@Test func thePromotedKindClearsTheFloorToo() {
    let ratio = RailTreatment.effectiveContrast(
        RailTreatment.textColour,
        elementOpacity: RailTreatment.kindOpacity,
        promoted: true)
    #expect(
        ratio >= Contrast.bodyTextFloor,
        "promoted kind is \(ratio):1, floor is \(Contrast.bodyTextFloor):1")
    // And the artboard's own value, so the number that failed is on the
    // record rather than in a commit message.
    let drawn = RailTreatment.effectiveContrast(
        RailTreatment.textColour, elementOpacity: 0.46, promoted: true)
    #expect(drawn < Contrast.bodyTextFloor)
}

/// The finding that made this file necessary, guarded so it cannot return.
///
/// A list of pane names read in order to pick one is text that is *being
/// read*, which is exactly what `PRODUCT.md` binds 4.5:1 for, measured
/// against the actual composite. Riding `Plane.far` whole, `#e8ecf6` at 0.30
/// over the void composites to ≈2.35:1 — the same class of failure
/// `EnvironmentBadge` was created to fix at 1.47:1, reached by the same
/// route.
///
/// Promotion is what clears it, **at the moment it is read**, which is why
/// the fix is one change and not two: the state §10 already named is also the
/// state the floor applies in.
@Test func theAmbientRailWouldFailTheBodyTextFloor() {
    let ratio = RailTreatment.effectiveContrast(RailTreatment.textColour, promoted: false)
    #expect(ratio < Contrast.bodyTextFloor)
    #expect(ratio > 2.0 && ratio < 2.6, "the recorded finding is ≈2.4:1, this reads \(ratio):1")
}

/// §3: depth is scale, opacity and blur **together — never one alone**. The
/// only opacity change the rail had before #138 was the *other* direction
/// (`deferredOpacity`), which is deference and not promotion.
@Test func promotionReleasesScaleOpacityAndBlurTogether() {
    #expect(RailTreatment.scale(promoted: true) != RailTreatment.scale(promoted: false))
    #expect(
        RailTreatment.opacity(promoted: true, isMaximized: false)
            != RailTreatment.opacity(promoted: false, isMaximized: false))
    #expect(RailTreatment.blur(promoted: true) != RailTreatment.blur(promoted: false))
}

/// Promotion lifts the rail to the mid plane whole — it does not invent a
/// fourth treatment between the two §3 already names.
@Test func theTwoStatesAreTheFarPlaneAndTheMidPlane() {
    #expect(RailTreatment.scale(promoted: false) == Plane.far.scale)
    #expect(RailTreatment.opacity(promoted: false, isMaximized: false) == Plane.far.opacity)
    #expect(RailTreatment.blur(promoted: false) == Plane.far.blur)

    #expect(RailTreatment.scale(promoted: true) == Plane.mid.scale)
    #expect(RailTreatment.opacity(promoted: true, isMaximized: false) == Plane.mid.opacity)
    #expect(RailTreatment.blur(promoted: true) == Plane.mid.blur)
}

/// §10's maximize fade is deference: *further back*, never past the rail's
/// own ambient state into invisibility.
@Test func deferenceIsQuieterThanAmbientAndIsNotZero() {
    let deferred = RailTreatment.opacity(promoted: false, isMaximized: true)
    #expect(deferred == RailTreatment.deferredOpacity)
    #expect(deferred < Plane.far.opacity)
    #expect(deferred > 0)
}

/// **Promotion outranks deference**, which is the one state the artboard does
/// not draw and the one the rail exists for: while a pane is maximized every
/// other pane is hidden behind it, so the rail is the only way back to them.
/// A deferred rail that stayed at 0.12 under the pointer would be interactive
/// far-plane content again, at 1.28:1 rather than the 2.35:1 §3 already
/// forbids.
@Test func promotionOutranksDeference() {
    #expect(RailTreatment.opacity(promoted: true, isMaximized: true) == Plane.mid.opacity)
}

/// §7's plane transition: 400–600ms, ease-out. Taken at the bottom of the
/// band for the reason `ContextLine` takes 0.40 there — this is a control the
/// operator crosses many times a day, not the room breathing.
@Test func thePromotionSitsInSection7sPlaneTransitionBand() {
    #expect(RailTreatment.planeTransition >= 0.400)
    #expect(RailTreatment.planeTransition <= 0.600)
}

/// §10: "a working pane glows green in the periphery." It was drawn as the
/// literal word `working` in cool white, behind a 1.4px blur at 0.30 — the
/// least peripherally legible treatment available. The green is §5's
/// reserved one, read from the palette rather than respelled, for the reason
/// `EnvironmentBadge.productionColour` reads `VoidPalette.red`: two copies of
/// a hue drift.
@Test func theWorkingTickCarriesSection5sReservedGreen() {
    #expect(RailTreatment.workingTickColour == TerminalPalette.green)
    #expect(RailTreatment.activeTickColour != RailTreatment.workingTickColour)
}

/// Once promoted, both ticks clear WCAG's floor for non-text graphics.
@Test func bothTicksClearTheNonTextFloorOncePromoted() {
    let working = RailTreatment.effectiveContrast(
        RailTreatment.workingTickColour, promoted: true)
    let active = RailTreatment.effectiveContrast(
        RailTreatment.activeTickColour, promoted: true)
    #expect(working >= Contrast.largeTextFloor, "working tick is \(working):1")
    #expect(active >= Contrast.largeTextFloor, "active tick is \(active):1")
}

/// **What the green tick does not claim.** At rest it composites to ≈2.05:1,
/// under the 3:1 floor for non-text graphics, and no glow changes that number.
/// The claim §10 makes for it is peripheral *hue*, not contrast: a hue shift
/// survives the far plane precisely because noticing it does not require
/// resolving anything, and the reading happens after the pointer arrives and
/// the rail promotes. Asserted rather than left in a comment so that "it is
/// green, therefore it is legible" cannot be inferred later from the code.
@Test func theAmbientTickIsAPeripheralCueAndNotAContrastClaim() {
    let working = RailTreatment.effectiveContrast(
        RailTreatment.workingTickColour, promoted: false)
    #expect(working < Contrast.largeTextFloor)
}

// Ticket noticing (piece 3): the tick's third hue, amber — §5's *pending* — for an editor row while
// something waits on the operator; `Tickets · N` when no editor pane is open; the count after the kind.
@Suite struct RailTreatmentTickTests {
    /// One mark, one hue: working (green) > needs you (amber) > active (violet).
    @Test func tickPrecedenceWorkingNeedsActive() {
        #expect(RailTreatment.tick(busy: true, needsYou: true, active: true) == .working)
        #expect(RailTreatment.tick(busy: true, needsYou: false, active: false) == .working)
        #expect(RailTreatment.tick(busy: false, needsYou: true, active: true) == .needsYou)
        #expect(RailTreatment.tick(busy: false, needsYou: true, active: false) == .needsYou)
        #expect(RailTreatment.tick(busy: false, needsYou: false, active: true) == .active)
        #expect(RailTreatment.tick(busy: false, needsYou: false, active: false) == RailTick.none)
        #expect(RailTreatment.colour(.needsYou) == RailTreatment.needsTickColour)
        #expect(RailTreatment.colour(.working) == RailTreatment.workingTickColour)
        #expect(RailTreatment.colour(.active) == RailTreatment.activeTickColour)
        #expect(RailTreatment.colour(.none) == nil)
    }

    /// Amber carries the glow a working tick carries, at rest and promoted: it is the state meant to be
    /// noticed from the corner of the eye. Active keeps its promoted-only glow.
    @Test func needsGlowMatchesWorking() {
        #expect(RailTreatment.needsGlow == 0.85)
        #expect(RailTreatment.needsGlowRadius == 5)
        for promoted in [false, true] {
            let needs = RailTreatment.glow(.needsYou, promoted: promoted)
            let working = RailTreatment.glow(.working, promoted: promoted)
            #expect(needs.opacity == working.opacity && needs.radius == working.radius)
            #expect(needs.opacity == 0.85 && needs.radius == 5)
        }
        #expect(RailTreatment.glow(.active, promoted: true) == (opacity: 0.70, radius: 4))
        #expect(RailTreatment.glow(.active, promoted: false).opacity == 0)
        #expect(RailTreatment.glow(.none, promoted: true).opacity == 0)
    }

    /// `#e8b45a`, read from the palette rather than respelled.
    @Test func amberIsTerminalAmber() {
        #expect(RailTreatment.needsTickColour == TerminalPalette.amber)
        let c = RailTreatment.needsTickColour
        #expect((c.r * 255).rounded() == 0xe8 && (c.g * 255).rounded() == 0xb4 && (c.b * 255).rounded() == 0x5a)
    }

    /// Operator decision 2 (2026-10-28): with no editor pane, one extra row; with one, none.
    @Test func ticketsRowOnlyWithoutAnEditor() {
        #expect(RailTreatment.ticketsRowShown(count: 4, hasEditorPane: false))
        #expect(!RailTreatment.ticketsRowShown(count: 4, hasEditorPane: true))
        #expect(!RailTreatment.ticketsRowShown(count: 0, hasEditorPane: false))
        #expect(!RailTreatment.ticketsRowShown(count: 0, hasEditorPane: true))
    }

    /// The count is text after the kind, `· 4`; at 0 nothing — the tick and the count go together.
    @Test func countSuffixAtZeroIsNil() {
        #expect(RailTreatment.countSuffix(0) == nil)
        #expect(RailTreatment.countSuffix(4) == " · 4")
        #expect(RailTreatment.countSuffix(12) == " · 12")
    }

    /// F8: every mark clears 4.5:1 against the rail's background where it is read — the promoted rail,
    /// mid plane, over the void. At rest the marks are hue cues (`theAmbientTickIsAPeripheralCueAndNotAContrastClaim`).
    @Test func amberTickClearsTheFarPlaneCue() {
        for (name, colour) in [("amber", RailTreatment.needsTickColour), ("green", RailTreatment.workingTickColour),
                               ("violet", RailTreatment.activeTickColour)] {
            let ratio = RailTreatment.effectiveContrast(colour, promoted: true)
            #expect(ratio >= Contrast.bodyTextFloor, "\(name) tick is \(ratio):1")
        }
    }
}
