import Foundation

/// ANSI SGR colour and style, mapped onto Wakil's own design-language
/// palette rather than drawn as raw web colour.
///
/// **Why a program's colour is not passed through as-is.**
/// `docs/wakil/design-language.md` §5 reserves `#8be0c8` (green),
/// `#e8b45a` (amber) and `#e85c5c` (red) as semantics — staging/healthy,
/// pending/caution, production/destructive/failed — "never decorative,
/// anywhere". A program's stdout is quoted material, not Wakil's own
/// chrome, so §5's carve-out (recorded there alongside this file) lets it
/// carry colour — but rendered in THIS app's values, so a program's red
/// and Wakil's red read as the same red instead of two unrelated signals
/// sharing a hue by coincidence. Suppressing colour instead would make
/// the pane misreport what the program printed, which is exactly what
/// `structuredOutput`'s own doc comment (`TerminalPaneSupport.swift`)
/// refuses: "guessing at output this build has never seen is how a
/// terminal starts telling the operator a program printed something it
/// did not" — and rendering everything in one flat white is guessing too,
/// just in the opposite direction.
///
/// This file is pure — no SwiftTerm, no AppKit, no SwiftUI — so every
/// anchor and every transform below is asserted in
/// `TerminalAnsiColorTests.swift` without a display, the same reason
/// `VoidPalette.swift` stays free of AppKit.

// MARK: - Style

/// One cell's (or run's) style: colour plus the SGR attributes this build
/// models. `nil` colour means "inherit the pane's own text colour" —
/// the default foreground, or a background with no fill at all.
public struct TerminalCellStyle: Sendable, Equatable {
    public var foreground: RGB?
    public var background: RGB?
    public var bold: Bool
    /// SGR 2 (faint), **and** forced on by `terminalIsAnsiBlack` — see
    /// that function's own doc comment for why ANSI black rides this flag
    /// rather than a colour value of its own.
    public var dim: Bool
    public var underline: Bool
    /// SGR 7. Applied at read time by `resolvedColors`, never by mutating
    /// `foreground`/`background` in place — the params that set colour
    /// and the param that reverses it can arrive in either order in the
    /// same sequence, and swapping once at the end is the only order that
    /// is not order-dependent.
    public var reverse: Bool

    public init(
        foreground: RGB? = nil, background: RGB? = nil, bold: Bool = false, dim: Bool = false,
        underline: Bool = false, reverse: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.underline = underline
        self.reverse = reverse
    }

    public static let plain = TerminalCellStyle()

    /// `(foreground, background)` after `reverse` swaps them — the same
    /// "reverse means swap, not compose" rule every ANSI terminal applies
    /// for SGR 7, kept as a pure computed property so the view never has
    /// to remember to apply it.
    public var resolvedColors: (foreground: RGB?, background: RGB?) {
        reverse ? (background, foreground) : (foreground, background)
    }
}

/// One run of same-styled text — the unit `terminalCoalesceStyleRuns`
/// produces and `TerminalPane`'s drawing concatenates with `+`, one `Text`
/// per run, never one view per cell.
public struct TerminalStyleRun: Sendable, Equatable {
    public let text: String
    public let style: TerminalCellStyle

    public init(text: String, style: TerminalCellStyle) {
        self.text = text
        self.style = style
    }
}

// MARK: - Coalescing

/// Consecutive cells sharing an identical style, merged into one run.
///
/// **Decoupled from SwiftTerm's `CharData` on purpose.** `CharData` has
/// no public initialiser — it can only be produced by feeding the
/// headless engine — so a function that took `[CharData]` could not be
/// asserted with a hand-built row; this takes the plain
/// `(character, style)` pairs any caller can construct, and
/// `TerminalSession` is the one adapter that reads real cells into this
/// shape.
///
/// A row of one style — the overwhelmingly common case, plain text with
/// no SGR at all — coalesces to exactly one run, so a row with one colour
/// draws exactly what it draws today: one `Text`, no per-run overrides.
public func terminalCoalesceStyleRuns(
    _ cells: [(character: Character, style: TerminalCellStyle)]
) -> [TerminalStyleRun] {
    var runs: [TerminalStyleRun] = []
    var currentStyle: TerminalCellStyle?
    var currentText = ""
    for cell in cells {
        if let style = currentStyle, style == cell.style {
            currentText.append(cell.character)
        } else {
            if let style = currentStyle {
                runs.append(TerminalStyleRun(text: currentText, style: style))
            }
            currentStyle = cell.style
            currentText = String(cell.character)
        }
    }
    if let style = currentStyle {
        runs.append(TerminalStyleRun(text: currentText, style: style))
    }
    return runs
}

// MARK: - Colour anchors

/// Where an ANSI colour parameter came from — the one shape both the live
/// grid (already parsed by SwiftTerm into `Attribute.Color`) and a
/// captured block's own SGR parser (below) can each produce, so
/// `terminalPaletteColor` is the single mapping both paths share.
public enum TerminalAnsiColorSource: Sendable, Equatable {
    /// The 16 standard ANSI colours, 0–15 — codes 0–7 normal, 8–15
    /// bright, the layout every terminal agrees on.
    case standard(UInt8)
    /// The 256-colour palette, 16–255 (the cube at 16–231, greyscale at
    /// 232–255). A value under 16 is treated as `standard` — SGR
    /// `38;5;<n>` is defined over the full 0–255 range, and 0–15 there
    /// name the same 16 colours `standard` does.
    case extended(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
    /// No colour was ever set, or it was reset — "use the pane's own
    /// text/background", never a value of this file's own.
    case defaultColor
}

/// The reserved anchors themselves, `RGB` (0…1), the same units
/// `VoidPalette` already uses so a future "compare against the void's own
/// colours" question has one currency instead of two.
public enum TerminalPalette {
    /// `#e85c5c` — design-language.md §5's red. Reuses `VoidPalette.red`'s
    /// own value rather than restating it, so the two can never drift.
    public static let red = VoidPalette.red
    /// `#8be0c8` — §5's green.
    public static let green = RGB(0.545, 0.878, 0.784)
    /// `#e8b45a` — §5's amber.
    public static let amber = RGB(0.910, 0.706, 0.353)
    /// `#4fb9e8` — §5's void-blue bleed. Reuses `VoidPalette.blue`.
    public static let blue = VoidPalette.blue
    /// `#7c5cff` — §5's primary luminance violet. Reuses
    /// `VoidPalette.violet`.
    public static let violet = VoidPalette.violet
    /// ANSI cyan has no anchor of its own in §5's table — the task
    /// handed to this file is "your pick between the blue and the green,
    /// stated in a comment". Blended 2:1 toward blue rather than split
    /// evenly: §5 reserves green as a status hue ("healthy/completed"),
    /// and a cyan that reads as close to green as it does to blue would
    /// be read as a fourth status colour the operator has to learn is
    /// not one. Leaning on blue keeps cyan legible as "informational",
    /// the same register `VoidPalette.blue` already carries for the
    /// void's own cool bleed.
    public static let cyan = RGB(
        (blue.r * 2 + green.r) / 3, (blue.g * 2 + green.g) / 3, (blue.b * 2 + green.b) / 3)
}

extension RGB {
    /// The same hue, lifted toward white by `factor` — used for the
    /// bright ANSI variants (9–14), which the task requires to be "the
    /// same hue at higher luminance, never a different hue".
    ///
    /// **Hue-exact by construction, not by luck.** `newC = c + (1-c)*f`
    /// is an affine map with the SAME slope `(1-f)` and the same
    /// intercept `f` applied to every channel. Hue in HSL is a function
    /// of the ratios between the three channel differences
    /// (`g-b`, `b-r`, `r-g`); under an identical affine map on all three
    /// channels those differences all scale by the same `(1-f)`, so their
    /// ratios — and therefore the hue angle — are unchanged. Only
    /// luminance (and, as a side effect, saturation) moves.
    func lightened(by factor: Double = 0.22) -> RGB {
        RGB(r + (1 - r) * factor, g + (1 - g) * factor, b + (1 - b) * factor)
    }
}

/// Whether `source` names ANSI black (0) or bright black (8) — the one
/// standard colour this file never renders as a hue at all.
///
/// **Why black is not simply "the anchor for index 0".** §2's void is a
/// near-black field; a program that sets literal black text on it would
/// be asking for text that reads as a hole in the pane, which is worse
/// than the "fault in the display" reasoning §5 already gives for why
/// red is `#e85c5c` and not `#ff0000`. §5's own rule for dimming text is
/// "stepped down by opacity, never by a different hue" — so ANSI black
/// rides that exact rule instead of inventing a colour: `terminalPaletteColor`
/// answers `nil` for it (inherit the text colour) and the caller ORs this
/// flag into `dim`, which is what actually dims it.
public func terminalIsAnsiBlack(_ source: TerminalAnsiColorSource) -> Bool {
    if case .standard(let code) = source { return code == 0 || code == 8 }
    return false
}

/// ANSI colour, mapped onto `TerminalPalette`'s anchors.
///
/// `nil` means "inherit the pane's own colour for this role" — `standard`
/// 7 (white) and 15 (bright white), which already sit at the pane's text
/// colour, `standard` 0 and 8 (black — see `terminalIsAnsiBlack`), and
/// `defaultColor` itself.
public func terminalPaletteColor(for source: TerminalAnsiColorSource) -> RGB? {
    switch source {
    case .defaultColor:
        return nil
    case .standard(let code):
        return standardPaletteColor(code)
    case .extended(let code):
        if code < 16 { return standardPaletteColor(code) }
        return pulledTerminalColor(extendedPaletteRawColor(code))
    case .trueColor(let r, let g, let b):
        return pulledTerminalColor(
            RGB(Double(r) / 255, Double(g) / 255, Double(b) / 255))
    }
}

private func standardPaletteColor(_ code: UInt8) -> RGB? {
    switch code {
    case 0, 7, 8, 15: return nil
    case 1: return TerminalPalette.red
    case 2: return TerminalPalette.green
    case 3: return TerminalPalette.amber
    case 4: return TerminalPalette.blue
    case 5: return TerminalPalette.violet
    case 6: return TerminalPalette.cyan
    case 9: return TerminalPalette.red.lightened()
    case 10: return TerminalPalette.green.lightened()
    case 11: return TerminalPalette.amber.lightened()
    case 12: return TerminalPalette.blue.lightened()
    case 13: return TerminalPalette.violet.lightened()
    case 14: return TerminalPalette.cyan.lightened()
    default: return nil
    }
}

/// The 256-colour palette's own raw RGB for `code` (16–255), by the
/// standard xterm formula — the 6×6×6 cube at 16–231, an 8..238 grey ramp
/// at 232–255. Not yet pulled toward this app's palette; that is
/// `pulledTerminalColor`'s job, applied uniformly to this AND to
/// truecolour, so a 256-colour green and a truecolour green land the
/// same way.
private func extendedPaletteRawColor(_ code: UInt8) -> RGB {
    if code >= 232 {
        let level = Double(8 + (Int(code) - 232) * 10) / 255.0
        return RGB(level, level, level)
    }
    let index = Int(code) - 16
    let r = index / 36
    let g = (index / 6) % 6
    let b = index % 6
    func component(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v * 40) / 255.0 }
    return RGB(component(r), component(g), component(b))
}

/// Pulls an arbitrary colour toward this app's own palette weight rather
/// than rendering it raw — required for 256-colour and truecolour alike,
/// because neither is one of §5's reserved anchors and both can name any
/// web colour a program likes, including a saturated `#00ff00` that would
/// read as a display fault on the void's near-black field, the identical
/// reasoning §5 already gives for why red is `#e85c5c` and not `#ff0000`.
///
/// **A saturation ceiling and a luminance floor, sized off the anchors
/// themselves, not guessed.** The five reserved anchors' own HSL:
///
///     red    S 0.75  L 0.64
///     green  S 0.58  L 0.71
///     amber  S 0.76  L 0.63
///     blue   S 0.77  L 0.61
///     violet S 1.00  L 0.68
///
/// so every anchor already sits at S ≥ 0.58, L ≈ 0.61–0.71. The ceiling
/// (0.72 saturation) and floor (0.45 luminance) below keep an arbitrary
/// colour inside roughly that band without collapsing it to one exact
/// point: `#00ff00` (S 1.0, L 0.5) comes out at (S 0.72, L 0.5) — still
/// unmistakably green, no longer neon. A near-black truecolour (L ≈ 0.05)
/// that would all but vanish against the void is lifted to L 0.45 instead
/// of staying invisible, which is the direct analogue of "a pure black on
/// a near-black field reads as a fault", the same failure the anchors
/// exist to avoid on the standard 16.
func pulledTerminalColor(_ color: RGB) -> RGB {
    let (h, s, l) = rgbToHSL(color)
    let cappedSaturation = min(s, 0.72)
    let flooredLuminance = max(l, 0.45)
    return hslToRGB(hue: h, saturation: cappedSaturation, lightness: flooredLuminance)
}

// MARK: - HSL, the one intermediate this file needs

func rgbToHSL(_ color: RGB) -> (hue: Double, saturation: Double, lightness: Double) {
    let maxc = max(color.r, color.g, color.b)
    let minc = min(color.r, color.g, color.b)
    let lightness = (maxc + minc) / 2
    let delta = maxc - minc
    guard delta > 0.0001 else { return (0, 0, lightness) }
    let saturation = delta / (1 - abs(2 * lightness - 1))
    var hue: Double
    if maxc == color.r {
        hue = ((color.g - color.b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maxc == color.g {
        hue = (color.b - color.r) / delta + 2
    } else {
        hue = (color.r - color.g) / delta + 4
    }
    hue *= 60
    if hue < 0 { hue += 360 }
    return (hue, saturation, lightness)
}

func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> RGB {
    guard saturation > 0.0001 else { return RGB(lightness, lightness, lightness) }
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let hPrime = hue / 60
    let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
    let m = lightness - c / 2
    var r = 0.0, g = 0.0, b = 0.0
    switch hPrime {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return RGB(r + m, g + m, b + m)
}

// MARK: - A captured block's own SGR parser

/// Every SGR-styled line a captured block's raw output actually printed —
/// the second of the two places colour has to come from, described in
/// this sub-phase's own brief: `TerminalSession.stripEscapeSequences`
/// removes SGR at capture, so keeping it means parsing the SAME bytes a
/// second time, independently of SwiftTerm's live engine.
///
/// **Why not read it back from `Terminal`'s own `CharData` instead**
/// (which is what the live grid does, and is parsed exactly once). By the
/// time a block SEALS, the rows its output was drawn to have very likely
/// already scrolled past the engine's own limited scrollback, or been
/// overwritten by the next command entirely — `TerminalBlock`'s own doc
/// comment measured 207 of 400 marked commands already unrecoverable
/// from the buffer for the identical reason, which is why a block's
/// PLAIN text is captured from the raw stream rather than read back from
/// the emulator at all. Colour for a block has to follow the same rule:
/// parsed from the bytes captured alongside it, not from a screen that
/// may no longer hold them.
///
/// **What this models, and what it does not.** SGR ("m") parameters only
/// — colour, bold, dim, underline, reverse, and the resets (`ESC[0m`, the
/// bare `ESC[m`). Every other CSI (cursor movement, erase) and every OSC
/// is recognised only long enough to be dropped, unrendered as text —
/// the same "ignored, not guessed at" rule
/// `TerminalSession.stripEscapeSequences` already applies for the plain
/// path, which is also why the two produce character-for-character the
/// same residual text (asserted in `TerminalAnsiColorTests.swift`): both
/// strip exactly the same categories of byte, this one dispatches on the
/// final byte an extra time before doing so.
///
/// **An unterminated sequence at the very end is preserved as text, not
/// eaten** — mirroring `stripEscapeSequences`'s own documented rule, for
/// its own stated reason: there is no next chunk here in which the
/// terminator might still arrive (this runs once, over a whole sealed
/// block), so treating a truncated sequence as "not actually a sequence"
/// and handing the bytes back is the only choice that cannot silently
/// swallow real text.
///
/// Line splitting mirrors `TerminalSession.outputLines` exactly —
/// `\r\n`/`\r` as `\n`, a trailing terminator dropping the empty final
/// line it would otherwise produce — so this function's line COUNT always
/// matches `outputLines`' own for the same bytes; `TerminalSession` still
/// verifies that at the one call site before storing the result, rather
/// than trusting it by construction.
public func terminalStyledOutputLines(_ bytes: [UInt8]) -> [[TerminalStyleRun]] {
    var lines: [[TerminalStyleRun]] = []
    var currentRuns: [TerminalStyleRun] = []
    var pending: [UInt8] = []
    var style = TerminalCellStyle.plain

    func flushPending() {
        guard !pending.isEmpty else { return }
        currentRuns.append(TerminalStyleRun(text: String(decoding: pending, as: UTF8.self), style: style))
        pending.removeAll(keepingCapacity: true)
    }
    func endLine() {
        flushPending()
        lines.append(currentRuns)
        currentRuns = []
    }

    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x0D {  // \r — possibly the first half of \r\n
            endLine()
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            } else {
                index += 1
            }
            continue
        }
        if byte == 0x0A {  // \n
            endLine()
            index += 1
            continue
        }
        guard byte == 0x1B else {
            pending.append(byte)
            index += 1
            continue
        }
        guard index + 1 < bytes.count else {
            // A lone trailing ESC; nothing legitimate follows it — dropped,
            // the same call `stripEscapeSequences` makes.
            index += 1
            continue
        }
        switch bytes[index + 1] {
        case 0x5B:  // CSI: "ESC [" … up to a final byte in 0x40...0x7E.
            var cursor = index + 2
            while cursor < bytes.count, !(0x40...0x7E).contains(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count else {
                pending.append(contentsOf: bytes[index...])
                index = bytes.count
                continue
            }
            if bytes[cursor] == 0x6D {  // 'm' — SGR
                flushPending()
                style = applySGR(sgrParams(bytes[(index + 2)..<cursor]), to: style)
            }
            // Any other final byte: cursor movement, erase, and the rest
            // — recognised only to be dropped, never rendered as text.
            index = cursor + 1
        case 0x5D:  // OSC: "ESC ]" … up to BEL or "ESC \".
            var cursor = index + 2
            var terminated = false
            while cursor < bytes.count {
                if bytes[cursor] == 0x07 { cursor += 1; terminated = true; break }
                if bytes[cursor] == 0x1B, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x5C {
                    cursor += 2
                    terminated = true
                    break
                }
                cursor += 1
            }
            guard terminated else {
                pending.append(contentsOf: bytes[index...])
                index = bytes.count
                continue
            }
            index = cursor
        default:
            // A two-byte escape (`ESC c`, `ESC =`, …): drop only the ESC,
            // exactly as `stripEscapeSequences` does.
            index += 1
        }
    }
    endLine()
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

/// The numeric parameters of one SGR sequence's argument bytes (between
/// `ESC[` and the final `m`, exclusive of both). A missing digit between
/// separators reads as `0`, the ANSI convention (`ESC[1;;31m` is
/// `1;0;31`); a wholly empty argument (the bare `ESC[m`) is `[0]` — reset
/// — because that IS what a bare `m` means, not an empty parameter list
/// that happens to do nothing.
func sgrParams(_ slice: ArraySlice<UInt8>) -> [Int] {
    if slice.isEmpty { return [0] }
    var params: [Int] = []
    var current = 0
    for byte in slice {
        if byte >= 0x30, byte <= 0x39 {
            current = current * 10 + Int(byte - 0x30)
        } else if byte == 0x3B || byte == 0x3A {
            params.append(current)
            current = 0
        }
    }
    params.append(current)
    return params
}

/// Applies one SGR sequence's parameters to `style`, left to right —
/// `38`/`48` (extended/truecolour foreground/background) each consume the
/// one or four parameters after them, exactly as a real terminal's own
/// SGR state machine does. A code this file does not model (italic,
/// blink, strikethrough, and every code above 107) is skipped, never
/// guessed at.
func applySGR(_ params: [Int], to initial: TerminalCellStyle) -> TerminalCellStyle {
    var style = initial
    var i = 0
    while i < params.count {
        let code = params[i]
        switch code {
        case 0:
            style = .plain
        case 1:
            style.bold = true
        case 2:
            style.dim = true
        case 4:
            style.underline = true
        case 7:
            style.reverse = true
        case 22:
            style.bold = false
            style.dim = false
        case 24:
            style.underline = false
        case 27:
            style.reverse = false
        case 30...37:
            let source = TerminalAnsiColorSource.standard(UInt8(code - 30))
            style.foreground = terminalPaletteColor(for: source)
            if terminalIsAnsiBlack(source) { style.dim = true }
        case 39:
            style.foreground = nil
        case 40...47:
            style.background = terminalPaletteColor(for: .standard(UInt8(code - 40)))
        case 49:
            style.background = nil
        case 90...97:
            let source = TerminalAnsiColorSource.standard(UInt8(code - 90 + 8))
            style.foreground = terminalPaletteColor(for: source)
            if terminalIsAnsiBlack(source) { style.dim = true }
        case 100...107:
            style.background = terminalPaletteColor(for: .standard(UInt8(code - 100 + 8)))
        case 38, 48:
            guard i + 1 < params.count else { break }
            let isForeground = code == 38
            let mode = params[i + 1]
            if mode == 5, i + 2 < params.count {
                let colorCode = UInt8(clamping: params[i + 2])
                let color = terminalPaletteColor(for: .extended(colorCode))
                if isForeground {
                    style.foreground = color
                    if terminalIsAnsiBlack(.extended(colorCode)) { style.dim = true }
                } else {
                    style.background = color
                }
                i += 2
            } else if mode == 2, i + 4 < params.count {
                let r = UInt8(clamping: params[i + 2])
                let g = UInt8(clamping: params[i + 3])
                let b = UInt8(clamping: params[i + 4])
                let color = terminalPaletteColor(for: .trueColor(r, g, b))
                if isForeground { style.foreground = color } else { style.background = color }
                i += 4
            }
        default:
            break
        }
        i += 1
    }
    return style
}
