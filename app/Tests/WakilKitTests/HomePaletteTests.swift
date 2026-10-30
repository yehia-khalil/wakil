import Testing
@testable import WakilKit

/// PRODUCT.md's floor: everything the home draws to be read clears 4.5:1 against the composite of the
/// surface it sits on — the void, a slab, an expanded card's lift, a selected pill.
@Test func everyColourTheHomeReadsClearsTheFloorOnTheVoidAndOnASlab() {
    let lifted = Contrast.composite(HomePalette.ink, alpha: 0.035, over: HomePalette.slab)
    for surface in [Contrast.voidBase, HomePalette.slab, lifted] {
        for c in HomePalette.read {
            let ratio = Contrast.effectiveRatio(c.colour, alpha: c.alpha, over: surface)
            #expect(ratio >= Contrast.bodyTextFloor, "\(c.name) reads \(ratio):1")
        }
    }
    let pill = Contrast.composite(HomePalette.ink, alpha: HomePalette.pillOn.ground, over: Contrast.voidBase)
    #expect(Contrast.effectiveRatio(HomePalette.ink, alpha: HomePalette.pillOn.text, over: pill) >= Contrast.bodyTextFloor)
    let rest = Contrast.composite(HomePalette.ink, alpha: HomePalette.pillOff, over: Contrast.voidBase)
    #expect(Contrast.effectiveRatio(HomePalette.ink, alpha: HomePalette.secondary, over: rest) >= Contrast.bodyTextFloor)
    #expect(Contrast.effectiveRatio(HomePalette.amber, alpha: 1, over: pill) >= Contrast.bodyTextFloor, "a pill's ● n")
}
