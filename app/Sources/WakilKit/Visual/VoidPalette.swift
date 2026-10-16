import Foundation

/// A colour in linear-ish 0…1 components, as the shader wants it.
///
/// Not `CGColor` or `NSColor`: this type is decided in `WakilKit`, which
/// stays free of AppKit so that every question with a right answer can be
/// tested without a display (spec §2.3).
public struct RGB: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// What colour the void's two bleeds are, given the active environment.
///
/// **The whole production treatment is here** (spec §3.2): the environment
/// label turns red and the void's bleeds turn red, and nothing else on
/// screen changes. Lighting every pane edge would put a dozen bright
/// objects beside the Core and break §1's "one bright object"; and §5's
/// "reserved semantics, never decorative" cuts both ways — red that is
/// everywhere is wallpaper, and will not stop anyone on the day it needs to.
public struct VoidPalette: Sendable, Equatable {
    /// The bleed rising from below the frame.
    public let bleedA: RGB
    /// The bleed from the upper right.
    public let bleedB: RGB
    /// Whether this palette is the production one. The label reads this too,
    /// so the badge and the room cannot disagree.
    public let isProduction: Bool

    /// `#7c5cff` — §5's primary luminance.
    public static let violet = RGB(0.486, 0.361, 1.0)
    /// `#4fb9e8` — §5's cool blue.
    public static let blue = RGB(0.310, 0.725, 0.910)
    /// `#9e82ff` — `violet` lifted toward white, for a mark drawn *in front
    /// of* the room rather than by it: the context line's controls, the org
    /// plane's accents, and §10's luminous tick on the active pane. `#7c5cff`
    /// is the value the room's own bleed carries, and a foreground mark in it
    /// reads *into* that bleed rather than against it.
    ///
    /// Added 2026-09-21 with #138, which needed the tick. The hue was already
    /// spelled as a literal in two `WakilApp` files; this is its one home, on
    /// the rule `red` and the terminal's `green` already follow — two copies
    /// of a hue drift.
    public static let accent = RGB(0.620, 0.510, 1.0)

    /// `#e85c5c`. §5 names red as production's hue and gives no value; this
    /// is that value, chosen to sit at the same weight as the amber
    /// `#e8b45a` and the green `#8be0c8` beside it rather than as a pure
    /// `#ff0000`, which on a near-black field reads as a fault in the
    /// display. Recorded back into `design-language.md` §5.
    public static let red = RGB(0.910, 0.361, 0.361)

    /// The palette for an environment name.
    ///
    /// Matching is trimmed and case-insensitive because `writeGate` matches
    /// production the same way. A treatment that disagreed with the gate
    /// about what production is would paint a safe-looking room around a
    /// refusal.
    ///
    /// **That sentence used to be a promise and is now a fact.** This
    /// function had its own trim-and-lowercase and `writeGate` had its own
    /// lowercase without a trim, so the two disagreed about `" production"`
    /// — the room went red around a write the gate only asked to confirm.
    /// Both now read `isProductionEnvironment`, so there is no second copy
    /// of the rule left to drift (2026-09-14).
    /// **`production` carries the project's declarations** (Decision 26,
    /// #182), and is the same value `writeGate` is given — which is what
    /// keeps the sentence above a fact.
    ///
    /// **It has no default**, for `writeGate`'s reason: `.undeclared` is the
    /// name rule, so a defaulted parameter would let the room revert to it by
    /// omission. A caller with no project in hand — `Capture`'s fixtures, a
    /// window before its first context read — passes `.undeclared` where a
    /// reader can see the choice.
    public static func forEnvironment(
        _ environment: String,
        production: EnvironmentProduction
    ) -> VoidPalette {
        if production.isProduction(environment) {
            return VoidPalette(bleedA: red, bleedB: red, isProduction: true)
        }
        return VoidPalette(bleedA: violet, bleedB: blue, isProduction: false)
    }
}
