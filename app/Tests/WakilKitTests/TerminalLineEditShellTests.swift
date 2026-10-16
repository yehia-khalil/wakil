import Foundation
import Testing
@testable import WakilKit

/// Real shells on real ptys, through the store — the shipped path.

/// Opens `shell`, waits for an editable prompt, types `text`, waits for it.
private func typed(_ store: TerminalStore, shell: String, _ text: String) async throws {
    _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: shell,
                             environment: ["HOME": scratchHome()])
    try await waitUntil(seconds: 10) { await store.inputLine("t") != nil }
    // Foundation's `contains("")` is false, so an empty `text` has nothing to wait for.
    guard !text.isEmpty else { return }
    await store.write(paneId: "t", bytes: Array(text.utf8))
    try await waitUntil(seconds: 5) { await store.screenContains("t", text) }
}

/// The selection over `word` on the current input line.
private func selection(of word: String, in line: TerminalInputLine) throws -> TerminalGridRange {
    let characters = line.cells.map(\.character)
    let target = Array(word)
    let start = try #require((0...(characters.count - target.count)).last {
        Array(characters[$0..<($0 + target.count)]) == target })
    return TerminalGridRange(anchor: line.cells[start].point, head: line.cells[start + target.count - 1].point)
}

private func runAndWaitForOutput(_ store: TerminalStore, _ output: String) async throws {
    await store.write(paneId: "t", bytes: Array("\r".utf8))
    try await waitUntil(seconds: 5) { await store.screenLines("t").contains(output) }
}

@Test func zshReplacesTheSelectedWord() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let edit = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "switch"))
        try await waitUntil(seconds: 5) { await store.screenContains("t", "echo git switch main") }
        try await runAndWaitForOutput(store, "git switch main")
    }
}

@Test func zshDeletesASelectionThatStartsInThePrompt() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo abc")
        let line = try #require(await store.inputLine("t"))
        // From the first cell on the row (prompt text) through "echo ".
        let echoEnd = try selection(of: "echo ", in: line).head
        let edit = try #require(terminalLineEdit(
            selection: TerminalGridRange(anchor: line.cells[0].point, head: echoEnd), line: line))
        #expect(edit.startDelta < -8, "the selection reaches back into the prompt")
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "print "))
        try await runAndWaitForOutput(store, "abc")
    }
}

@Test func zshIgnoresAnEditWhoseExpectedTextDoesNotMatch() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let real = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        let stale = TerminalLineEdit(startDelta: real.startDelta, endDelta: real.endDelta, expected: "chekcout")
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: stale, replacement: "switch"))
        try await runAndWaitForOutput(store, "git checkout main")
    }
}

@Test func zshBracketedPasteOfTwoLinesDoesNotRunBeforeEnter() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "")
        try await waitUntil(seconds: 5) { await store.bracketedPaste("t") }
        await store.write(paneId: "t", bytes: terminalPasteBytes("echo one\necho two", bracketed: true))
        try await waitUntil(seconds: 5) { await store.screenContains("t", "echo two") }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!(await store.screenLines("t").contains("one")), "nothing ran before Enter")
        try await runAndWaitForOutput(store, "two")
        #expect(await store.screenLines("t").contains("one"))
    }
}

@Test func zshStopsReportingSupportOnceTheBindingIsGone() async throws {
    // Review finding: with the binding removed (a plugin rebuilding keymaps,
    // `bindkey -d`), a request's BEL is send-break in emacs mode and throws
    // the whole typed line away. The signal must follow the binding.
    try await withTerminalStore { store in
        try await typed(store, shell: "/bin/zsh", "")
        await store.write(paneId: "t", bytes: Array("bindkey -M main -r '\\e[999~'\r".utf8))
        await store.write(paneId: "t", bytes: Array("echo wakil-unbound\r".utf8))
        try await waitUntil(seconds: 5) { await store.screenLines("t").contains("wakil-unbound") }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await store.inputLine("t") == nil)
    }
}

@Test func macOSBash32NeverReportsLineEditSupport() async throws {
    try await withTerminalStore { store in
        _ = try await store.open(paneId: "t", path: NSTemporaryDirectory(), shell: "/bin/bash",
                                 environment: ["HOME": scratchHome()])
        await store.write(paneId: "t", bytes: Array("echo wakil-ready\n".utf8))
        try await waitUntil(seconds: 10) {
            await store.marks("t").filter { $0 == .promptEnd }.count >= 2
        }
        #expect(!(await store.lineEditSupported("t")))
        #expect(await store.inputLine("t") == nil)
    }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/bash"),
               "needs Homebrew bash 4+"))
func homebrewBashReplacesTheSelectedWord() async throws {
    try await withTerminalStore { store in
        try await typed(store, shell: "/opt/homebrew/bin/bash", "echo git checkout main")
        let line = try #require(await store.inputLine("t"))
        let edit = try #require(terminalLineEdit(selection: try selection(of: "checkout", in: line), line: line))
        await store.write(paneId: "t", bytes: terminalReplaceBytes(edit: edit, replacement: "switch"))
        try await runAndWaitForOutput(store, "git switch main")
    }
}

// The same two helpers `TerminalStoreTests` keeps private (several test
// files each keep their own `waitUntil`, so these stay file-private too).

private func waitUntil(seconds: Double, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds * testWaitLoadMultiplier)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("condition did not hold within \(seconds)s")
}

/// A fresh `HOME` with no dotfiles, so the operator's own rc never runs here.
private func scratchHome() -> String {
    let dir = testScratchRoot.appendingPathComponent("wakil-scratch-home-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
