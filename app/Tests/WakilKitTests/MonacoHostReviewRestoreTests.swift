import Foundation
import JavaScriptCore
import Testing

// Ticket noticing, final review (Task 4 #4): Restore yours never throws away the operator's live,
// not-yet-kept typing in the reply field (Rule 2). The page's decision is a pure function between
// two markers in monaco-host.html (WakilApp has no test target), evaluated here as the page runs it.

private func restoreText() throws -> JSContext {
    let page = URL(fileURLWithPath: #filePath)   // app/Tests/WakilKitTests/MonacoHostReviewRestoreTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/WakilApp/monaco-host.html")
    let html = try String(contentsOf: page, encoding: .utf8)
    let begin = try #require(html.range(of: "// BEGIN reviewRestoreText"))
    let end = try #require(html.range(of: "// END reviewRestoreText"))
    let context = try #require(JSContext())
    context.evaluateScript(String(html[begin.upperBound..<end.lowerBound]))
    return context
}

@Test func restoreYoursKeepsTheOperatorsUnkeptTyping() throws {
    let js = try restoreText()
    func call(_ args: String) -> String? {
        let v = js.evaluateScript("reviewRestoreText(\(args))")
        return v?.isNull == true || v?.isUndefined == true ? nil : v?.toString()
    }
    // Nothing typed since the agent's draft: a plain restore.
    #expect(call("'mine', 'theirs', undefined") == nil)
    #expect(call("'mine', 'theirs', 'theirs'") == nil)
    #expect(call("'mine', 'theirs', '  '") == nil)
    // Typed and not yet kept: both are kept, the restored text first.
    #expect(call("'mine', 'theirs', 'theirs, and a line I added'") == "mine\n\ntheirs, and a line I added")
    #expect(call("'mine', null, 'new words'") == "mine\n\nnew words")
}
