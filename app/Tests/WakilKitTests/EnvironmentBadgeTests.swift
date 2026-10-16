import Testing
@testable import WakilKit

// Invariant 8: "The active environment is on screen at all times. Production
// looks alarming." These are that invariant stated as numbers, because it had
// never been stated as numbers and was not in fact met.

@Test func theProductionBadgeClearsTheBodyTextFloor() {
    let ratio = EnvironmentBadge.effectiveContrast(isProduction: true)
    #expect(
        ratio >= Contrast.bodyTextFloor,
        "production badge is \(ratio):1, floor is \(Contrast.bodyTextFloor):1")
}

@Test func theOrdinaryBadgeClearsTheBodyTextFloor() {
    let ratio = EnvironmentBadge.effectiveContrast(isProduction: false)
    #expect(
        ratio >= Contrast.bodyTextFloor,
        "badge is \(ratio):1, floor is \(Contrast.bodyTextFloor):1")
}

/// The finding that made this file necessary, guarded so it cannot return.
///
/// Red carries less luminance than white, so applying one opacity multiplier
/// to both does not treat them alike: at `Plane.far`'s 0.30 the ordinary
/// badge reached 2.33:1 and the production badge 1.46:1. Invariant 8 asks
/// production to be *unmissable*, and it was the least legible state in the
/// application — the one place a dimming rule inverts the meaning it is
/// drawn over.
/// **What this does and does not claim.** Production is still the lower-contrast
/// of the two — 5.82:1 against 16.86:1 — because red simply carries less
/// luminance than white, and no exemption changes that. Production is alarming
/// through *hue*, not through luminance. What the exemption bought is that both
/// states now clear the readability floor, which is the property that was
/// missing and the only one this can honestly assert.
///
/// *(Renamed 2026-09-14: this was
/// `productionIsNeverLessLegibleThanTheStateItIsWarningAbout`, which named an
/// ordering the body never checked and the numbers do not support.)*
@Test func bothBadgeStatesClearTheBodyTextFloor() {
    let production = EnvironmentBadge.effectiveContrast(isProduction: true)
    let ordinary = EnvironmentBadge.effectiveContrast(isProduction: false)
    #expect(
        production >= Contrast.bodyTextFloor && ordinary >= Contrast.bodyTextFloor,
        "both states must be readable before their ranking means anything")
}

/// Why the badge is exempt from the plane it sits on, kept as an assertion
/// rather than a comment so the exemption cannot quietly be undone.
///
/// The far plane is right for the rail — ambient context, nothing on it is
/// being read. It is wrong for the one label that exists to be read at the
/// moment it matters most. If someone reinstates `Plane.far`'s treatment on
/// the badge, this is the test that says what it costs.
@Test func theFarPlanesOwnTreatmentWouldFailBothBadgeStates() {
    let production = Contrast.effectiveRatio(
        EnvironmentBadge.productionColour, alpha: Plane.far.opacity, over: Contrast.voidBase)
    let ordinary = Contrast.effectiveRatio(
        EnvironmentBadge.ordinaryColour, alpha: Plane.far.opacity, over: Contrast.voidBase)
    #expect(production < Contrast.bodyTextFloor)
    #expect(ordinary < Contrast.bodyTextFloor)
    // And the inversion itself: dimmed, production reads fainter than staging.
    #expect(production < ordinary)
}

@Test func theBadgeIsNeitherDimmedNorBlurred() {
    #expect(EnvironmentBadge.opacity == 1.0)
    #expect(EnvironmentBadge.blur == 0.0)
}

/// The badge stays *spatially* on the far plane — it is ambient furniture and
/// moves with the rail — and is exempted only from the two properties that
/// decide legibility. Depth through scale and parallax costs nothing a reader
/// needs; depth through opacity and blur costs exactly that.
@Test func theBadgeKeepsTheFarPlanesScaleAndParallax() {
    #expect(EnvironmentBadge.scale == Plane.far.scale)
    #expect(EnvironmentBadge.parallaxFactor == Plane.far.parallaxFactor)
}

@Test func theBadgeTakesItsProductionColourFromTheSamePaletteAsTheRoom() {
    #expect(EnvironmentBadge.productionColour == VoidPalette.red)
}
