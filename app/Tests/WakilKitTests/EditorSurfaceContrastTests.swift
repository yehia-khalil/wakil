import Testing
@testable import WakilKit

/// 3a-ii review I4: the Changes view's dimmed read text — a branch, a folder, a count, the
/// commit box's placeholder — clears the 4.5:1 floor on both surfaces it sits on, at §3's 0.55.

@Test func dimmedReadTextClearsTheFloorOnTheSlabAndTheLiftedBox() {
    for surface in [EditorSurface.slab, EditorSurface.lifted] {
        let ratio = Contrast.effectiveRatio(RailTreatment.textColour, alpha: RailTreatment.kindOpacity, over: surface)
        #expect(ratio >= Contrast.bodyTextFloor, "dimmed read text is \(ratio):1")
    }
}

@Test func theRedesignsZeroPointFourSixFailsTheFloorOnBoth() {
    for surface in [EditorSurface.slab, EditorSurface.lifted] {
        #expect(Contrast.effectiveRatio(RailTreatment.textColour, alpha: 0.46, over: surface) < Contrast.bodyTextFloor)
    }
}
