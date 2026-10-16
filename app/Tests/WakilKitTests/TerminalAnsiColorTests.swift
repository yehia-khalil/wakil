import Foundation
import Testing
@testable import WakilKit

/// `TerminalAnsiColor.swift`'s three jobs, each asserted independently:
/// parsing a captured block's raw SGR bytes into styled runs, coalescing
/// same-styled cells into runs, and mapping ANSI colour onto
/// design-language.md §5's own anchors. All three are pure — no
/// SwiftTerm, no display — which is what lets a dozen defects in this
/// pane reach a test instead of a human, the standing reason
/// `TerminalPaneSupport.swift` exists at all.

// MARK: - Test helpers

/// `"#e85c5c"` → `RGB`, so a test can write the hex the design doc uses
/// rather than the pre-divided doubles the production code compares.
private func hex(_ string: String) -> RGB {
    var value: UInt64 = 0
    Scanner(string: String(string.dropFirst())).scanHexInt64(&value)
    let r = Double((value >> 16) & 0xFF) / 255.0
    let g = Double((value >> 8) & 0xFF) / 255.0
    let b = Double(value & 0xFF) / 255.0
    return RGB(r, g, b)
}

private func approximatelyEqual(_ a: RGB, _ b: RGB, tolerance: Double = 0.01) -> Bool {
    abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance && abs(a.b - b.b) < tolerance
}

private func csi(_ params: String) -> [UInt8] { Array("\u{1B}[\(params)".utf8) }

// MARK: - The mapping

@Test func standardAnchorsLandOnDesignLanguagesStatedHex() {
    #expect(approximatelyEqual(terminalPaletteColor(for: .standard(1))!, hex("#e85c5c")))  // red
    #expect(approximatelyEqual(terminalPaletteColor(for: .standard(2))!, hex("#8be0c8")))  // green
    #expect(approximatelyEqual(terminalPaletteColor(for: .standard(3))!, hex("#e8b45a")))  // amber
    #expect(approximatelyEqual(terminalPaletteColor(for: .standard(4))!, hex("#4fb9e8")))  // blue
    #expect(approximatelyEqual(terminalPaletteColor(for: .standard(5))!, hex("#7c5cff")))  // violet
}

@Test func brightVariantsShareTheirNormalHueAtHigherLuminance() {
    for code: UInt8 in [1, 2, 3, 4, 5] {
        let normal = terminalPaletteColor(for: .standard(code))!
        let bright = terminalPaletteColor(for: .standard(code + 8))!
        let (normalHue, normalSaturation, normalLightness) = rgbToHSL(normal)
        let (brightHue, brightSaturation, _) = rgbToHSL(bright)
        _ = normalSaturation
        _ = brightSaturation
        #expect(abs(normalHue - brightHue) < 0.5, "hue drifted for code \(code)")
        let (_, _, brightLightness) = rgbToHSL(bright)
        #expect(brightLightness > normalLightness, "bright \(code) is not lighter than normal")
    }
}

@Test func ansiBlackAndBrightBlackAreNeverAHue() {
    #expect(terminalPaletteColor(for: .standard(0)) == nil)
    #expect(terminalPaletteColor(for: .standard(8)) == nil)
    #expect(terminalIsAnsiBlack(.standard(0)))
    #expect(terminalIsAnsiBlack(.standard(8)))
    #expect(!terminalIsAnsiBlack(.standard(7)))
}

@Test func whiteAndDefaultInheritThePanesOwnTextColour() {
    #expect(terminalPaletteColor(for: .standard(7)) == nil)
    #expect(terminalPaletteColor(for: .standard(15)) == nil)
    #expect(terminalPaletteColor(for: .defaultColor) == nil)
}

@Test func cyanIsStatedAsABlendRatherThanAGuess() {
    let cyan = TerminalPalette.cyan
    // Closer to blue than to green — the 2:1 lean the doc comment states.
    let distanceToBlue = abs(cyan.r - TerminalPalette.blue.r) + abs(cyan.g - TerminalPalette.blue.g)
        + abs(cyan.b - TerminalPalette.blue.b)
    let distanceToGreen = abs(cyan.r - TerminalPalette.green.r) + abs(cyan.g - TerminalPalette.green.g)
        + abs(cyan.b - TerminalPalette.green.b)
    #expect(distanceToBlue < distanceToGreen)
}

@Test func trueColourIsPulledTowardThePaletteRatherThanPassedRaw() {
    // A saturated neon green: HSL(120°, 100%, 50%).
    let neon = RGB(0, 1, 0)
    let pulled = terminalPaletteColor(for: .trueColor(0, 255, 0))!
    #expect(pulled != neon)
    let (_, saturation, lightness) = rgbToHSL(pulled)
    #expect(saturation <= 0.72 + 0.001)
    #expect(lightness >= 0.45 - 0.001)
}

@Test func aNearBlackTrueColourIsLiftedRatherThanLeftInvisible() {
    let almostBlack = terminalPaletteColor(for: .trueColor(4, 4, 4))!
    let (_, _, lightness) = rgbToHSL(almostBlack)
    #expect(lightness >= 0.45 - 0.001)
}

@Test func the256PaletteBelowSixteenDelegatesToStandard() {
    #expect(terminalPaletteColor(for: .extended(1)) == terminalPaletteColor(for: .standard(1)))
}

@Test func the256PaletteAboveSixteenIsAlsoPulled() {
    // Colour cube index for a saturated pure green (16 + 0*36 + 5*6 + 0 = 46).
    let color = terminalPaletteColor(for: .extended(46))!
    let (_, saturation, _) = rgbToHSL(color)
    #expect(saturation <= 0.72 + 0.001)
}

@Test func reverseSwapsForegroundAndBackgroundOnlyAtResolution() {
    let style = TerminalCellStyle(
        foreground: TerminalPalette.red, background: TerminalPalette.green, reverse: true)
    let (fg, bg) = style.resolvedColors
    #expect(fg == TerminalPalette.green)
    #expect(bg == TerminalPalette.red)
    // The stored fields are untouched — only the read is swapped.
    #expect(style.foreground == TerminalPalette.red)
}

// MARK: - Coalescing

@Test func consecutiveSameStyledCellsCoalesceIntoOneRun() {
    let red = TerminalCellStyle(foreground: TerminalPalette.red)
    let cells: [(character: Character, style: TerminalCellStyle)] = [
        ("a", red), ("b", red), ("c", red),
    ]
    let runs = terminalCoalesceStyleRuns(cells)
    #expect(runs.count == 1)
    #expect(runs[0].text == "abc")
    #expect(runs[0].style == red)
}

@Test func aRowOfOneStyleIsOneRun() {
    let cells: [(character: Character, style: TerminalCellStyle)] =
        "plain text row".map { ($0, .plain) }
    let runs = terminalCoalesceStyleRuns(cells)
    #expect(runs.count == 1)
    #expect(runs[0].text == "plain text row")
    #expect(runs[0].style == .plain)
}

@Test func aStyleChangeStartsANewRun() {
    let red = TerminalCellStyle(foreground: TerminalPalette.red)
    let cells: [(character: Character, style: TerminalCellStyle)] = [
        ("a", .plain), ("b", .plain), ("c", red), ("d", red), ("e", .plain),
    ]
    let runs = terminalCoalesceStyleRuns(cells)
    #expect(runs.count == 3)
    #expect(runs[0].text == "ab")
    #expect(runs[1].text == "cd")
    #expect(runs[1].style == red)
    #expect(runs[2].text == "e")
}

// MARK: - SGR parsing (a captured block's own bytes)

@Test func aColourSetAndResetProducesTwoRuns() {
    var bytes: [UInt8] = []
    bytes += csi("31m")
    bytes += Array("red".utf8)
    bytes += csi("0m")
    bytes += Array("plain".utf8)
    let lines = terminalStyledOutputLines(bytes)
    #expect(lines.count == 1)
    #expect(lines[0].map(\.text) == ["red", "plain"])
    #expect(lines[0][0].style.foreground != nil)
    #expect(lines[0][1].style == .plain)
}

@Test func severalColourRunsInOneRow() {
    var bytes: [UInt8] = []
    bytes += csi("31m") + Array("R".utf8)
    bytes += csi("32m") + Array("G".utf8)
    bytes += csi("33m") + Array("Y".utf8)
    let lines = terminalStyledOutputLines(bytes)
    #expect(lines.count == 1)
    #expect(lines[0].map(\.text) == ["R", "G", "Y"])
    #expect(approximatelyEqual(lines[0][0].style.foreground!, hex("#e85c5c")))
    #expect(approximatelyEqual(lines[0][1].style.foreground!, hex("#8be0c8")))
    #expect(approximatelyEqual(lines[0][2].style.foreground!, hex("#e8b45a")))
}

@Test func boldDimUnderlineAndReverseAreModelled() {
    var bytes: [UInt8] = []
    bytes += csi("1m") + Array("bold".utf8)
    bytes += csi("0;2m") + Array("dim".utf8)
    bytes += csi("0;4m") + Array("under".utf8)
    bytes += csi("0;7m") + Array("rev".utf8)
    let lines = terminalStyledOutputLines(bytes)
    let runs = lines[0]
    #expect(runs[0].style.bold)
    #expect(runs[1].style.dim)
    #expect(runs[2].style.underline)
    #expect(runs[3].style.reverse)
}

@Test func bareResetAndZeroResetBothClearStyle() {
    var bareBytes: [UInt8] = []
    bareBytes += csi("1m") + Array("bold".utf8)
    bareBytes += csi("m") + Array("plain".utf8)
    let bareLines = terminalStyledOutputLines(bareBytes)
    #expect(bareLines[0][1].style == .plain)

    var zeroBytes: [UInt8] = []
    zeroBytes += csi("31m") + Array("red".utf8)
    zeroBytes += csi("0m") + Array("plain".utf8)
    let zeroLines = terminalStyledOutputLines(zeroBytes)
    #expect(zeroLines[0][1].style == .plain)
}

@Test func anUnterminatedSequenceAtTheEndIsPreservedAsText() {
    var bytes = Array("before".utf8)
    bytes += [0x1B, 0x5B, 0x33, 0x31]  // "\u{1B}[31" — never closed with 'm'
    let lines = terminalStyledOutputLines(bytes)
    let joined = lines[0].map(\.text).joined()
    #expect(joined.contains("before"))
    // The truncated escape's own bytes are handed back as text, not eaten.
    #expect(joined.utf8.count == bytes.count)
}

@Test func aSequenceThisBuildDoesNotModelIsIgnoredNotRenderedAsText() {
    var bytes: [UInt8] = []
    bytes += Array("before".utf8)
    bytes += csi("2J")  // erase-display — a real CSI final byte, not SGR
    bytes += Array("after".utf8)
    let lines = terminalStyledOutputLines(bytes)
    #expect(lines[0].map(\.text).joined() == "beforeafter")
}

@Test func plainTextDerivedFromRunsIsUnaffectedByColour() {
    var bytes: [UInt8] = []
    bytes += csi("31m") + Array("line one".utf8)
    bytes += Array("\n".utf8)
    bytes += Array("line two, no colour".utf8)
    let lines = terminalStyledOutputLines(bytes)
    #expect(lines.count == 2)
    #expect(lines[0].map(\.text).joined() == "line one")
    #expect(lines[1].map(\.text).joined() == "line two, no colour")
}

// MARK: - `TerminalBlock.outputRuns` is additive, never a second source of truth

@Test func aBlocksPlainOutputIsUnchangedRegardlessOfOutputRuns() {
    let withRuns = TerminalBlock.capped(
        id: "1", command: "printf '\\033[31mred\\033[0m'", origin: .operatorTyped, exitCode: 0,
        durationMs: 1, output: ["red"], heldTheGrid: false, startedAt: Date(),
        outputRuns: [[TerminalStyleRun(text: "red", style: TerminalCellStyle(foreground: TerminalPalette.red))]])
    let withoutRuns = TerminalBlock.capped(
        id: "1", command: "printf '\\033[31mred\\033[0m'", origin: .operatorTyped, exitCode: 0,
        durationMs: 1, output: ["red"], heldTheGrid: false, startedAt: Date())
    #expect(withRuns.output == withoutRuns.output)
    #expect(withoutRuns.outputRuns == nil)
}

@Test func cappingTrimsOutputRunsInStepWithOutput() {
    let lines = (0..<(TerminalBlock.outputLineCap + 10)).map { "line \($0)" }
    let runs = lines.map { [TerminalStyleRun(text: $0, style: .plain)] }
    let block = TerminalBlock.capped(
        id: "1", command: "x", origin: .operatorTyped, exitCode: 0, durationMs: 1,
        output: lines, heldTheGrid: false, startedAt: Date(), outputRuns: runs)
    #expect(block.output.count == TerminalBlock.outputLineCap)
    #expect(block.outputRuns?.count == TerminalBlock.outputLineCap)
    #expect(block.output.last == block.outputRuns?.last?.first?.text)
}
