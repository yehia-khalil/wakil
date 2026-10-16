import Foundation

/// WCAG 2.1 contrast arithmetic, so a legibility claim can be asserted
/// rather than eyeballed.
///
/// **Why this exists at all.** `design-language.md` uses the word "contrast"
/// three times and never as a number, and §6 asks for micro-labels at "low
/// opacity" without saying what low is. The result was that the environment
/// badge — Invariant 8's entire implementation, the thing that is supposed to
/// make production unmissable — shipped at 1.46:1, the lowest-contrast text
/// in the application, and *less* legible in production than out of it,
/// because red carries less luminance than white. 2b-ii's visual review
/// recorded the symptom ("warm rather than alarming") and nothing connected
/// it to a cause, because there was no instrument that could.
///
/// This is that instrument. It is deliberately in `WakilKit` rather than in a
/// test file: the numbers it produces are about the design language, several
/// surfaces owe it an assertion, and a helper that lives in one test cannot
/// be reached by the next one.
///
/// It measures colour only. Blur, font size and tracking also decide whether
/// something can be read, and this says nothing about them — a treatment that
/// passes here can still be illegible at 8pt behind a 1.4pt blur.
public enum Contrast {
    /// The void's base colour, as one number standing for a gradient.
    ///
    /// `Void.metal` mixes `#030408` into `#070812`; this is the lighter end.
    /// Light text against a lighter background yields the *lower* ratio, so
    /// measuring here is the conservative choice — a treatment that passes
    /// against this passes against the whole field.
    public static let voidBase = RGB(0x07 / 255.0, 0x08 / 255.0, 0x12 / 255.0)

    /// WCAG's floor for body text.
    public static let bodyTextFloor: Double = 4.5

    /// WCAG's floor for large text and for non-text graphics.
    public static let largeTextFloor: Double = 3.0

    /// One sRGB component, linearised — WCAG 2.1's transfer function.
    private static func linearise(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance, 0 for black and 1 for white.
    public static func relativeLuminance(_ colour: RGB) -> Double {
        0.2126 * linearise(colour.r)
            + 0.7152 * linearise(colour.g)
            + 0.0722 * linearise(colour.b)
    }

    /// The contrast ratio between two colours, from 1:1 to 21:1.
    ///
    /// Symmetric: which argument is the text and which the background does
    /// not change the answer.
    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `foreground` drawn at `alpha` over `background`.
    ///
    /// SwiftUI's `.opacity` is alpha compositing, so the colour a reader
    /// actually sees is this, not the foreground's own value. Measuring the
    /// foreground instead is what let a 1.46:1 badge be described in a code
    /// comment as though the plane treatment were "orthogonal" to its
    /// legibility.
    public static func composite(_ foreground: RGB, alpha: Double, over background: RGB) -> RGB {
        RGB(
            alpha * foreground.r + (1 - alpha) * background.r,
            alpha * foreground.g + (1 - alpha) * background.g,
            alpha * foreground.b + (1 - alpha) * background.b)
    }

    /// The ratio `foreground` actually achieves when drawn at `alpha` over
    /// `background` — the composite against the background it sits on.
    public static func effectiveRatio(
        _ foreground: RGB, alpha: Double, over background: RGB
    ) -> Double {
        ratio(composite(foreground, alpha: alpha, over: background), background)
    }
}
