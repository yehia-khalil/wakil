import Foundation
import Testing
@testable import WakilKit

private func tab(_ path: String, _ text: String) -> EditorTab {
    .file(path: path, root: "/p", text: text, mtime: 1, language: "go")
}
private func rendered(_ t: EditorTab) -> EditorRendered {
    EditorRendered(text: t.text, language: t.language, readOnly: t.readOnly,
                   agentSerial: t.lastAgentEdit?.serial ?? 0, cursor: t.cursor, selection: t.selection)
}

@Test func aNewTabIsShownRevealedAndScrolledToWhereItWas() {
    var a = tab("/p/a.go", "x"); a.cursor = EditorPosition(line: 4, column: 1); a.scrollTop = 80
    let s = EditorSnapshot(tabs: [a], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s) == [
        .show(key: "file:/p/a.go", text: "x", language: "go", readOnly: false),
        .reveal(key: "file:/p/a.go", cursor: EditorPosition(line: 4, column: 1), selection: nil),
        .scroll(key: "file:/p/a.go", top: 80),
    ])
}

@Test func theOperatorsOwnTypingRoundTripsToNothing() {
    var a = tab("/p/a.go", "x")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "xy"; a.edits = 1
    var seen = r; seen["file:/p/a.go"]!.text = "xy"   // the view recorded what it sent
    #expect(editorRenderSteps(rendered: seen, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0)) == [])
}

@Test func renderUpdateForAnAgentEditIsAnEditNotAReset() {
    var a = tab("/p/a.go", "if x {}")
    let r = ["file:/p/a.go": rendered(a)]
    let edit = EditorRange(start: EditorPosition(line: 1, column: 4), end: EditorPosition(line: 1, column: 5))
    a.text = "if y {}"; a.lastAgentEdit = EditorAgentEdit(serial: 1, range: edit, text: "y")
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0))
        == [.edit(key: "file:/p/a.go", range: edit, text: "y", before: "if x {}", after: "if y {}", basis: 1)])
}

@Test func anAgentEditOnTextTheRendererHasNotCaughtUpWithIsAReset() {
    var a = tab("/p/a.go", "abc")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "Xbcdef"   // operator typed "def" (not yet reported) and the agent replaced 1:1-1:2
    a.lastAgentEdit = EditorAgentEdit(serial: 1, range: EditorRange(start: EditorPosition(line: 1, column: 1), end: EditorPosition(line: 1, column: 2)), text: "X")
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0))
        == [.reset(key: "file:/p/a.go", text: "Xbcdef", basis: 1)])
}

@Test func aReloadIsAReset() {
    var a = tab("/p/a.go", "old")
    let r = ["file:/p/a.go": rendered(a)]
    a.text = "new"; a.savedText = "new"
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0))
        == [.reset(key: "file:/p/a.go", text: "new", basis: 0)])
}

@Test func anAgentGotoIsARevealAndAClosedTabIsDisposed() {
    var a = tab("/p/a.go", "x\ny")
    let b = tab("/p/b.go", "b")
    let r = ["file:/p/a.go": rendered(a), "file:/p/b.go": rendered(b)]
    a.cursor = EditorPosition(line: 2, column: 1)
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0)) == [
        .reveal(key: "file:/p/a.go", cursor: EditorPosition(line: 2, column: 1), selection: nil),
        .dispose(key: "file:/p/b.go"),
    ])
}

@Test func switchingTabsShowsTheOtherModelWithoutRevealing() {
    let a = tab("/p/a.go", "a"), b = tab("/p/b.go", "b")
    let r = ["file:/p/a.go": rendered(a), "file:/p/b.go": rendered(b)]
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a, b], active: 1))
        == [.show(key: "file:/p/b.go", text: "b", language: "go", readOnly: false)])
}

@Test func aSnapshotBehindTheOperatorsOwnTypingIsHeld() {
    var a = tab("/p/a.go", "a")
    var r = ["file:/p/a.go": rendered(a)]
    r["file:/p/a.go"]!.text = "abc"            // the page has typed on
    a.text = "ab"; a.edits = 1                 // the store has only the first post so far
    let s = EditorSnapshot(tabs: [a], active: 0)
    #expect(editorSnapshotToRender(s, rendered: r, active: "file:/p/a.go", typed: ["ab", "abc"],
                                   typingInFlight: true, viewInFlight: false) == nil)
    // Once nothing is in flight, it renders.
    #expect(editorSnapshotToRender(s, rendered: r, active: "file:/p/a.go", typed: [],
                                   typingInFlight: false, viewInFlight: false) == s)
}

@Test func anAgentEditOrAReloadIsNeverHeldBehindTyping() {
    var a = tab("/p/a.go", "a")
    var r = ["file:/p/a.go": rendered(a)]
    r["file:/p/a.go"]!.text = "abc"
    var edited = a
    edited.text = "Xa"
    edited.lastAgentEdit = EditorAgentEdit(serial: 1, range: EditorRange(start: .init(line: 1, column: 1),
                                                                          end: .init(line: 1, column: 1)), text: "X")
    let s1 = EditorSnapshot(tabs: [edited], active: 0)
    #expect(editorSnapshotToRender(s1, rendered: r, active: "file:/p/a.go", typed: ["ab", "abc", "Xa"],
                                   typingInFlight: true, viewInFlight: false) == s1)
    a.text = "from disk"; a.savedText = "from disk"; a.edits = 1
    let s2 = EditorSnapshot(tabs: [a], active: 0)
    #expect(editorSnapshotToRender(s2, rendered: r, active: "file:/p/a.go", typed: ["ab", "abc"],
                                   typingInFlight: true, viewInFlight: false) == s2)
}

@Test func aViewReportInFlightKeepsTheRenderedCursor() {
    var a = tab("/p/a.go", "abc")
    var r = ["file:/p/a.go": rendered(a)]
    r["file:/p/a.go"]!.cursor = EditorPosition(line: 1, column: 4)
    a.cursor = EditorPosition(line: 1, column: 2)            // an older report's echo
    let s = EditorSnapshot(tabs: [a], active: 0)
    let out = editorSnapshotToRender(s, rendered: r, active: "file:/p/a.go", typed: [],
                                     typingInFlight: false, viewInFlight: true)
    #expect(out?.tabs[0].cursor == EditorPosition(line: 1, column: 4))
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: out!) == [])
}

/// Final review I2: an agent edit reaching the page while a keystroke is still unposted. The step
/// carries the text the range applies to and the text it must produce, so the page can tell its
/// model is not `before` (it holds the keystroke) and replace it whole instead of applying the
/// range at shifted columns (`foo(bar)` → `Xfoobazr)`).
@Test func anAgentEditCarriesTheTextItAppliesToAndTheTextItMustProduce() {
    var a = tab("/p/a.go", "foo(bar)")
    let r = ["file:/p/a.go": rendered(a)]
    let edit = EditorRange(start: EditorPosition(line: 1, column: 5), end: EditorPosition(line: 1, column: 8))
    a.text = "foo(baz)"; a.lastAgentEdit = EditorAgentEdit(serial: 3, range: edit, text: "baz")
    let steps = editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: EditorSnapshot(tabs: [a], active: 0))
    guard case .edit(_, let range, let text, let before, let after, let basis)? = steps.first else {
        Issue.record("want an edit step, got \(steps)")
        return
    }
    #expect(before == "foo(bar)" && after == "foo(baz)" && basis == 3)
    // What the page would get by applying the range to a model holding an unposted "X" at 1:1:
    // not `after`, so the page must not keep it.
    let shifted = editorReplacing("Xfoo(bar)", range, with: text)
    #expect(shifted == "Xfoobazr)" && shifted != after && "Xfoo(bar)" != before)
}

@Test func aPostMadeBeforeAnAgentEditLandedResyncsThePageToTheStore() {
    let a = tab("/p/a.go", "abcE")
    var r = ["file:/p/a.go": rendered(a)]
    r["file:/p/a.go"]!.agentSerial = 2
    let subjects = ["file:/p/a.go": a.subject]
    #expect(editorTypingPost(key: "file:/p/a.go", basis: 1, subjects: subjects, rendered: r)
        == .resync(text: "abcE", basis: 2))
    #expect(editorTypingPost(key: "file:/p/a.go", basis: 2, subjects: subjects, rendered: r) == .send(a.subject))
}

@Test func aPostFromATabNoLongerOpenIsDroppedNotSentToAnotherTab() {
    let b = tab("/p/b.go", "b")
    let r = ["file:/p/b.go": rendered(b)]
    #expect(editorTypingPost(key: "file:/p/a.go", basis: 0, subjects: ["file:/p/b.go": b.subject], rendered: r) == .drop)
}

private func hasFind(_ steps: [EditorRenderStep]) -> Bool { steps.contains { if case .find = $0 { true } else { false } } }

/// Renders `s` the way the view does, keeping the pane's own find record beside `rendered`.
private func render(_ s: EditorSnapshot, _ rendered: inout [String: EditorRendered], _ active: inout String?,
                    _ findShown: inout Int) -> [EditorRenderStep] {
    let steps = editorRenderSteps(rendered: rendered, active: active, snapshot: s, findShown: findShown)
    rendered = editorRenderedAfter(steps, rendered: rendered, snapshot: s)
    findShown = editorFindShownAfter(steps, findShown: findShown, snapshot: s)
    active = s.active.flatMap { $0 < s.tabs.count ? editorTabKey(s.tabs[$0]) : nil }
    return steps
}

@Test func aFindRequestIsOneStepPerSerial() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a")], active: 0)
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: true, regex: false, serial: 1)
    var rendered: [String: EditorRendered] = [:], active: String? = nil, shown = 0
    let key = editorTabKey(s.tabs[0])
    #expect(render(s, &rendered, &active, &shown).contains(.find(key: key, query: "x", caseSensitive: false, wholeWord: true, regex: false)))
    #expect(shown == 1)
    #expect(!hasFind(render(s, &rendered, &active, &shown)))
    // The pane's record, not the tab's: a render from no rendered tabs never replays it.
    #expect(!hasFind(editorRenderSteps(rendered: [:], active: nil, snapshot: s, findShown: shown)))
    s.find?.serial = 2
    #expect(hasFind(render(s, &rendered, &active, &shown)) && shown == 2)
}

@Test func aFindIsNotReplayedOnATabFirstShownAfterIt() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a"), tab("/p/b.go", "b")], active: 0)
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: false, regex: false, serial: 1)
    var rendered: [String: EditorRendered] = [:], active: String? = nil, shown = 0
    #expect(hasFind(render(s, &rendered, &active, &shown)))
    s.active = 1                                              // b.go has never been rendered
    #expect(!hasFind(render(s, &rendered, &active, &shown)))
    s.active = 0
    #expect(!hasFind(render(s, &rendered, &active, &shown)))
}

// Fix round 1, I2: closing every tab drops every rendered key, never the pane's find record.
@Test func aFindIsNotReplayedAfterEveryTabClosesAndAnotherOpens() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a")], active: 0)
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: false, regex: false, serial: 1)
    var rendered: [String: EditorRendered] = [:], active: String? = nil, shown = 0
    #expect(hasFind(render(s, &rendered, &active, &shown)))
    s.tabs = []; s.active = nil
    _ = render(s, &rendered, &active, &shown)
    #expect(rendered.isEmpty)
    s.tabs = [tab("/p/b.go", "b")]; s.active = 0
    #expect(!hasFind(render(s, &rendered, &active, &shown)))
}

// Fix round 1, I2: a re-created view starts with nothing rendered. A find its bar already reported
// was shown by the view before it and is not replayed; one never reported (a pane whose view is
// new) is still opened.
@Test func aReCreatedViewDoesNotReplayAFindAlreadyShown() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a")], active: 0)
    s.find = EditorFindRequest(query: "x", caseSensitive: false, wholeWord: false, regex: false, serial: 3)
    #expect(editorFindShownSeed(s) == 0)
    #expect(hasFind(editorRenderSteps(rendered: [:], active: nil, snapshot: s, findShown: editorFindShownSeed(s))))
    s.findReport = EditorFindReport(query: "x", caseSensitive: false, wholeWord: false, regex: false, count: 1, shown: true)
    #expect(editorFindShownSeed(s) == 3)
    #expect(!hasFind(editorRenderSteps(rendered: [:], active: nil, snapshot: s, findShown: editorFindShownSeed(s))))
}

@MainActor private final class RecordingRenderer: EditorRenderer {
    var calls: [String] = []
    func showModel(key: String, text: String, language: String, readOnly: Bool) { calls.append("show \(key)") }
    func setLanguage(key: String, language: String) { calls.append("language \(key)") }
    func setReadOnly(key: String, readOnly: Bool) { calls.append("readOnly \(key)") }
    func resetText(key: String, text: String, basis: Int) { calls.append("reset \(key)") }
    func applyEdit(key: String, range: EditorRange, text: String, before: String, after: String, basis: Int) { calls.append("edit \(key)") }
    func reveal(key: String, cursor: EditorPosition, selection: EditorRange?) { calls.append("reveal \(key)") }
    func setScrollTop(key: String, top: Double) { calls.append("scroll \(key)") }
    func disposeModel(key: String) { calls.append("dispose \(key)") }
    func focus() { calls.append("focus") }
    func find(key: String, query: String, caseSensitive: Bool, wholeWord: Bool, regex: Bool) {
        calls.append("find \(key) \(query) \(caseSensitive) \(wholeWord) \(regex)")
    }
    func showDiff(key: String, original: String, modified: String, language: String, cursor: EditorPosition, scrollTop: Double) {
        calls.append("diff \(key) \(cursor.line):\(cursor.column) \(scrollTop)")
    }
    func captureKeys(_ keys: [String]) { calls.append("keys \(keys)") }
    func showPeek(key: String, _ peek: EditorPeekView?) { calls.append("peek \(key) \(peek?.title ?? "nil")") }
}

@MainActor @Test func aFindStepReachesTheRendererLast() {
    var s = EditorSnapshot(tabs: [tab("/p/a.go", "a")], active: 0)
    s.find = EditorFindRequest(query: "q", caseSensitive: true, wholeWord: false, regex: true, serial: 3)
    let r = RecordingRenderer()
    editorApply(editorRenderSteps(rendered: [:], active: nil, snapshot: s, findShown: 0), to: r)
    #expect(r.calls == ["show file:/p/a.go", "reveal file:/p/a.go", "scroll file:/p/a.go",
                        "find file:/p/a.go q true false true"])
}

// MARK: - Diff tabs (3b-iii)

private func diffTab(_ d: GitDiffState) -> EditorTab {
    var t = EditorTab.diff(root: "/p/api", path: "b.go", group: .changed)
    t.diffState = d
    return t
}
private func loaded(_ o: String, _ m: String) -> GitDiffState {
    GitDiffState(original: o, modified: m, language: "go", binary: false, bytes: 1, lines: 1, truncated: false,
                 error: nil, loading: false)
}

@Test func aDiffTabIsShownInTheDiffEditorAndNeverAsAModel() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    #expect(steps == [.diff(key: "diff:changed:/p/api/b.go", original: "a\n", modified: "b\n", language: "go",
                            cursor: EditorPosition(line: 1, column: 1), scrollTop: 0)])
}

@Test func theSameDiffReDeliveredIsNoStep() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    let after = editorRenderedAfter(steps, rendered: [:], snapshot: s)
    #expect(editorRenderSteps(rendered: after, active: "diff:changed:/p/api/b.go", snapshot: s).isEmpty)
}

// The last file's diff must not sit under the new file's name while the new one loads (3a-i).
@Test func aDiffStillLoadingWhenFirstShownShowsNothing() {
    var d = loaded("", ""); d.loading = true
    let s = EditorSnapshot(tabs: [diffTab(d)], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "", modified: "", language: "plaintext",
                  cursor: EditorPosition(line: 1, column: 1), scrollTop: 0)])
}

@Test func aRefreshLoadingTheShownDiffKeepsIt() {
    let s = EditorSnapshot(tabs: [diffTab(loaded("a\n", "b\n"))], active: 0)
    let after = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var reloading = s; reloading.tabs[0].diffState?.loading = true
    #expect(editorRenderSteps(rendered: after, active: "diff:changed:/p/api/b.go", snapshot: reloading).isEmpty)
}

@Test func anErrorOrABinaryDiffShowsAnEmptyDiffBesideItsBanner() {
    var d = loaded("x", "y"); d.binary = true
    let s = EditorSnapshot(tabs: [diffTab(d)], active: 0)
    #expect(editorRenderSteps(rendered: [:], active: nil, snapshot: s)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "", modified: "", language: "go",
                  cursor: EditorPosition(line: 1, column: 1), scrollTop: 0)])
}

@Test func leavingADiffForAFileTabShowsTheModelAgain() {
    let file = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    let s = EditorSnapshot(tabs: [diffTab(loaded("a", "b")), file], active: 0)
    let r = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var onFile = s; onFile.active = 1
    let steps = editorRenderSteps(rendered: r, active: "diff:changed:/p/api/b.go", snapshot: onFile)
    #expect(steps.first == .show(key: "file:/p/api/a.go", text: "x", language: "go", readOnly: false))
}

// Final review 1: a diff tab shown again after a switch lands where the operator left it — its
// cursor (⌘⏎ opens the file at that line) and its scroll, as the store holds them from its reports.
@Test func aDiffTabShownAgainAfterASwitchCarriesItsCursorAndScroll() {
    var d = diffTab(loaded("a\nb\nc\n", "a\nB\nc\n"))
    d.cursor = EditorPosition(line: 3, column: 2)
    d.scrollTop = 120
    let file = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    let s = EditorSnapshot(tabs: [d, file], active: 1)
    let r = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var back = s; back.active = 0
    #expect(editorRenderSteps(rendered: r, active: "file:/p/api/a.go", snapshot: back)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "a\nb\nc\n", modified: "a\nB\nc\n", language: "go",
                  cursor: EditorPosition(line: 3, column: 2), scrollTop: 120)])
}

// A diff refreshing while its tab was away is shown again with the texts it last showed, never a
// blank that would put its cursor back at 1:1 before the new texts land.
@Test func aDiffTabShownAgainWhileItRefreshesShowsItsLastDiff() {
    var d = diffTab(loaded("a\n", "b\n"))
    d.cursor = EditorPosition(line: 1, column: 2)
    d.scrollTop = 40
    let file = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: "x", mtime: 1, language: "go")
    let s = EditorSnapshot(tabs: [d, file], active: 0)
    var r = editorRenderedAfter(editorRenderSteps(rendered: [:], active: nil, snapshot: s), rendered: [:], snapshot: s)
    var away = s; away.active = 1
    r = editorRenderedAfter(editorRenderSteps(rendered: r, active: "diff:changed:/p/api/b.go", snapshot: away), rendered: r, snapshot: away)
    var back = s; back.tabs[0].diffState?.loading = true
    #expect(editorRenderSteps(rendered: r, active: "file:/p/api/a.go", snapshot: back)
        == [.diff(key: "diff:changed:/p/api/b.go", original: "a\n", modified: "b\n", language: "go",
                  cursor: EditorPosition(line: 1, column: 2), scrollTop: 40)])
}

@MainActor @Test func aDiffStepReachesTheRendererWithItsCursorAndScroll() {
    var d = diffTab(loaded("a\n", "b\n"))
    d.cursor = EditorPosition(line: 1, column: 2)
    d.scrollTop = 18
    let rec = RecordingRenderer()
    editorApply(editorRenderSteps(rendered: [:], active: nil, snapshot: EditorSnapshot(tabs: [d], active: 0)), to: rec)
    #expect(rec.calls == ["diff diff:changed:/p/api/b.go 1:2 18.0"])
}

@Test func thePageTakesOnlyTheKeysAnOpenPeekOrCompareNeeds() {
    #expect(editorCapturedKeys(comparing: false, peek: false) == [])
    #expect(editorCapturedKeys(comparing: true, peek: false) == ["escape"])
    #expect(editorCapturedKeys(comparing: false, peek: true) == ["up", "down", "escape"])
    #expect(editorCapturedKeys(comparing: true, peek: true) == ["escape"], "Compare owns the keys (R13)")
}

@Test func anOpenPeekIsAStepAndShowingAnotherTabDropsIt() {
    var t = EditorTab.file(path: "/p/a.go", root: "/p", text: "a\nB\n", mtime: 1, language: "go")
    t.baseline = "a\nb\n"
    t.peek = 0
    let s = EditorSnapshot(tabs: [t], active: 0)
    let steps = editorRenderSteps(rendered: [:], active: nil, snapshot: s)
    #expect(steps.contains(.peek(key: "file:/p/a.go", editorPeekView(t))))
    let r = editorRenderedAfter(steps, rendered: [:], snapshot: s)
    #expect(!editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: s).contains { if case .peek = $0 { true } else { false } })
    var closed = s; closed.tabs[0].peek = nil
    #expect(editorRenderSteps(rendered: r, active: "file:/p/a.go", snapshot: closed) == [.peek(key: "file:/p/a.go", nil)])
}
