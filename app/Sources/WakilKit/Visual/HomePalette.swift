import Foundation

/// The home's colours (workspaces piece 3, the comp of 2026-10-30), held here so the 4.5:1 floor
/// (PRODUCT.md, Accessibility) is asserted on what is drawn — each read colour composited over the
/// surface it sits on, the void and a slab — rather than described in a comment (`HomePaletteTests`).
/// `WakilApp/Home.swift` draws with these and nothing else.
public enum HomePalette {
    /// §5's text luminance, `#e8ecf6`, stepped by opacity.
    public static let ink = EnvironmentBadge.ordinaryColour
    /// §2's slab, `#0e1019`: NEEDS YOU, each project, Tickets.
    public static let slab = RGB(0.055, 0.063, 0.098)
    /// Titles and lines.
    public static let title = 0.92
    /// Ticket keys in a title, a teammate proposal's sentence.
    public static let strong = 0.86
    /// The expanded card's repo names, the PR line, a pill's words.
    public static let secondary = 0.72
    /// State words, a repo's branch, the project id in NEEDS YOU, Dismiss.
    public static let quiet = 0.62
    /// Micro-labels (NEEDS YOU, a project's count, EARLIER) and separators read as words: the floor.
    public static let micro = 0.58
    /// A selected pill's ground and words.
    public static let pillOn = (ground: 0.16, text: 0.95)
    /// A pill's ground at rest.
    public static let pillOff = 0.05

    /// Actions: violet raised to read (`#9e82ff`), not §5's `#7c5cff`, which is the working dot's.
    public static let action = VoidPalette.accent
    public static let amber = TerminalPalette.amber
    public static let green = TerminalPalette.green
    public static let red = VoidPalette.red
    /// Web links only (a PR's checks ↗).
    public static let link = VoidPalette.blue

    /// Every read colour at its alpha, by name: what the floor is asserted over.
    public static var read: [(name: String, colour: RGB, alpha: Double)] {
        [("title", ink, title), ("strong", ink, strong), ("secondary", ink, secondary), ("quiet", ink, quiet),
         ("micro", ink, micro), ("action", action, 1), ("amber", amber, 1), ("green", green, 1), ("red", red, 1),
         ("link", link, 1)]
    }
}
