import Testing
@testable import WakilKit

// 3a-ii walk: the Changes view's + − ↺ showed no hover or press.

@Test func anIconButtonAtRestDrawsNoFill() {
    #expect(IconButtonTreatment.fill(hovered: false, pressed: false, enabled: true) == 0)
    #expect(IconButtonTreatment.glyph(hovered: false, pressed: false, enabled: true) == IconButtonTreatment.restGlyph)
}

@Test func hoverLiftsAndAPressLiftsFurther() {
    let hover = IconButtonTreatment.fill(hovered: true, pressed: false, enabled: true)
    let press = IconButtonTreatment.fill(hovered: true, pressed: true, enabled: true)
    #expect(hover > 0)
    #expect(press > hover)
    #expect(IconButtonTreatment.glyph(hovered: true, pressed: false, enabled: true) > IconButtonTreatment.restGlyph)
}

@Test func aDisabledIconButtonAnswersNothing() {
    #expect(IconButtonTreatment.fill(hovered: true, pressed: true, enabled: false) == 0)
    #expect(IconButtonTreatment.glyph(hovered: true, pressed: false, enabled: false) == IconButtonTreatment.restGlyph)
}

@Test func reduceMotionDrawsTheHoverAtOnce() {
    #expect(IconButtonTreatment.hoverDuration(reduceMotion: true) == 0)
    #expect(IconButtonTreatment.hoverDuration(reduceMotion: false) == RailTreatment.rowHoverDuration)
}
