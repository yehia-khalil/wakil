import Foundation
import AppKit

// termspike — the instrument behind docs/wakil/phase-2c-iii-probe.md.
// Throwaway measurement code. No tests, no error handling beyond what makes it
// runnable: the point is a number, not a module.

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "all"
let repoRoot = ProcessInfo.processInfo.environment["TERMSPIKE_REPO"]
    ?? FileManager.default.currentDirectoryPath
let bigFile = ProcessInfo.processInfo.environment["TERMSPIKE_BIGFILE"] ?? "/tmp/termspike-big.txt"

func gridEntry() {
    // AppKit wants an activated application before it will lay out for real.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { runGrid() }
}

switch cmd {
case "parse":  runParse(megabytes: 32)
case "blocks": runBlocks(commands: 200, linesEach: 40)
case "gaps":   runIntegrationGaps()
case "pty":    runPty(cwd: repoRoot, bigFile: bigFile)
case "grid":   gridEntry()
case "history":
    let a2 = NSApplication.shared
    a2.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { runHistory() }
default:
    runParse(megabytes: 32)
    runBlocks(commands: 200, linesEach: 40)
    runIntegrationGaps()
    runPty(cwd: repoRoot, bigFile: bigFile)
    gridEntry()
    MainActor.assumeIsolated { runHistory() }
}
