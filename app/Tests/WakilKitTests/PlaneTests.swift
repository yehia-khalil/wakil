import Testing
@testable import WakilKit

@Test func theThreePlanesCarrySection3sConstants() {
    #expect(Plane.far.scale == 0.94)
    #expect(Plane.far.opacity == 0.30)
    #expect(Plane.far.blur == 1.4)
    // Mid is the data register: full scale, opaque, crisp. Any other value
    // here is §1's second principle broken in the type system.
    #expect(Plane.mid.scale == 1.0)
    #expect(Plane.mid.opacity == 1.0)
    #expect(Plane.mid.blur == 0.0)
    #expect(Plane.near.scale == 1.0)
    #expect(Plane.near.opacity == 1.0)
    #expect(Plane.near.blur == 0.0)
}

/// Spec §6: parallax moves the void and the far plane and never a pane.
/// Moving a data surface under the cursor while it is being read fights
/// §1's legibility register and makes table text shimmer.
@Test func theMidPlaneNeverParallaxes() {
    #expect(Plane.mid.parallaxFactor == 0)
    let offset = Plane.mid.parallaxOffset(cursor: (x: 0, y: 0), in: (width: 100, height: 100))
    #expect(offset.x == 0)
    #expect(offset.y == 0)
}

@Test func theCursorAtTheCentreMeansNoOffset() {
    let offset = Plane.far.parallaxOffset(cursor: (x: 50, y: 40), in: (width: 100, height: 80))
    #expect(abs(offset.x) < 1e-9)
    #expect(abs(offset.y) < 1e-9)
}

@Test func everyCornerIsWithinTheMaximumOffset() {
    let size = (width: 100.0, height: 80.0)
    for cursor in [(x: 0.0, y: 0.0), (x: 100.0, y: 0.0), (x: 0.0, y: 80.0), (x: 100.0, y: 80.0)] {
        let offset = Plane.far.parallaxOffset(cursor: cursor, in: size)
        #expect(abs(offset.x) <= Plane.maximumOffset + 1e-9)
        #expect(abs(offset.y) <= Plane.maximumOffset + 1e-9)
    }
}

/// A cursor dragged outside the window — which happens on every drag that
/// leaves the frame — must not send the far plane arbitrarily far.
@Test func aCursorOutsideTheWindowIsClamped() {
    let offset = Plane.far.parallaxOffset(cursor: (x: -900, y: 4000), in: (width: 100, height: 80))
    #expect(abs(offset.x) <= Plane.maximumOffset + 1e-9)
    #expect(abs(offset.y) <= Plane.maximumOffset + 1e-9)
}

/// A zero-sized window is what a view reports for one frame at launch.
/// Dividing by it must not produce NaN, which would propagate into a
/// transform and blank the view.
@Test func aZeroSizedWindowYieldsNoOffsetRatherThanNaN() {
    let offset = Plane.far.parallaxOffset(cursor: (x: 10, y: 10), in: (width: 0, height: 0))
    #expect(offset.x == 0)
    #expect(offset.y == 0)
}
