import Testing
@testable import WakilKit

// WCAG 2.1 relative luminance and contrast ratio, checked against values
// published with the standard rather than against this implementation's own
// output — otherwise the test certifies whatever the code happens to do.

@Test func whiteOnBlackIsTheMaximumRatio() {
    let ratio = Contrast.ratio(RGB(1, 1, 1), RGB(0, 0, 0))
    #expect(abs(ratio - 21.0) < 0.01)
}

@Test func aColourAgainstItselfHasNoContrast() {
    for colour in [RGB(1, 1, 1), RGB(0, 0, 0), VoidPalette.red, VoidPalette.violet] {
        #expect(abs(Contrast.ratio(colour, colour) - 1.0) < 1e-9)
    }
}

/// `#767676` on white is WCAG's own worked example of a colour that sits
/// just over the 4.5:1 body-text floor — the standard quotes 4.54:1.
@Test func theStandardsOwnBorderlineGreyLandsWhereTheStandardSaysItDoes() {
    let grey = RGB(0x76 / 255.0, 0x76 / 255.0, 0x76 / 255.0)
    let ratio = Contrast.ratio(grey, RGB(1, 1, 1))
    #expect(abs(ratio - 4.54) < 0.01)
}

@Test func theRatioIsTheSameWhicheverWayRoundItIsAsked() {
    let a = VoidPalette.red
    let b = RGB(0.02, 0.03, 0.05)
    #expect(abs(Contrast.ratio(a, b) - Contrast.ratio(b, a)) < 1e-12)
}

// MARK: - Compositing

/// SwiftUI's `.opacity` is alpha compositing against whatever is behind,
/// and what is behind every far-plane element is the void. A ratio computed
/// against the foreground's own colour rather than its composite is the
/// mistake that let a 1.46:1 badge ship looking like a 5.9:1 one.
@Test func fullOpacityCompositesToTheForegroundItself() {
    let composite = Contrast.composite(VoidPalette.red, alpha: 1.0, over: Contrast.voidBase)
    #expect(composite == VoidPalette.red)
}

@Test func zeroOpacityCompositesToTheBackgroundItself() {
    let composite = Contrast.composite(VoidPalette.red, alpha: 0.0, over: Contrast.voidBase)
    #expect(composite == Contrast.voidBase)
}

@Test func halfOpacityLandsHalfwayBetweenTheTwo() {
    let composite = Contrast.composite(RGB(1, 1, 1), alpha: 0.5, over: RGB(0, 0, 0))
    #expect(abs(composite.r - 0.5) < 1e-12)
    #expect(abs(composite.g - 0.5) < 1e-12)
    #expect(abs(composite.b - 0.5) < 1e-12)
}

/// The void is a gradient, not one colour (`Void.metal` mixes `#030408`
/// into `#070812`), so a single number has to stand for it. The *lightest*
/// end is the right one: light text against a lighter background is the
/// lower ratio, so measuring there is the conservative choice and cannot
/// flatter a treatment.
@Test func theVoidBaseIsTheLightestEndOfTheShadersMix() {
    #expect(abs(Contrast.voidBase.r - 0x07 / 255.0) < 1e-12)
    #expect(abs(Contrast.voidBase.g - 0x08 / 255.0) < 1e-12)
    #expect(abs(Contrast.voidBase.b - 0x12 / 255.0) < 1e-12)
}
