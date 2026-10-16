import Testing
@testable import WakilKit

/// #353: a dropped pane twitched. The canvas drew `frame + drag offset` and
/// cleared the offset only after `commitDrag` returned — but the new frame is
/// published while `commitDrag` is still awaiting, so for those frames the
/// pane was drawn at its new place plus the whole drag, then jumped back.
/// The offset belongs to the frame it was measured from, and to no other.

private let start = PaneFrame(x: 100, y: 50, width: 300, height: 200)

@Test func aPaneMidDragIsDrawnAtItsFrameMovedByTheDrag() {
    let origin = paneDrawOrigin(frame: start, dragFrom: start, translation: (40, -10))
    #expect(origin.x == 140)
    #expect(origin.y == 40)
}

@Test func aPaneWithNoDragIsDrawnAtItsFrame() {
    let origin = paneDrawOrigin(frame: start, dragFrom: nil, translation: nil)
    #expect(origin.x == 100)
    #expect(origin.y == 50)
}

@Test func onceTheDropIsPublishedTheDragNoLongerMovesThePane() {
    // The model has the new frame; the view has not cleared its offset yet.
    let dropped = PaneFrame(x: 140, y: 40, width: 300, height: 200)
    let origin = paneDrawOrigin(frame: dropped, dragFrom: start, translation: (40, -10))
    #expect(origin.x == 140)
    #expect(origin.y == 40)
}

@Test func aSnapMovesThePaneOnceFromWhereItWasReleasedToWhereItSnapped() {
    let snapped = PaneFrame(x: 150, y: 40, width: 300, height: 200)
    let origin = paneDrawOrigin(frame: snapped, dragFrom: start, translation: (40, -10))
    #expect(origin.x == 150)
    #expect(origin.y == 40)
}
