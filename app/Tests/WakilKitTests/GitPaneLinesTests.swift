import Testing
@testable import WakilKit

/// The git pane's text and its decisions, pure, because `WakilApp` has no test target: what
/// a root header and a diff banner read, which marks the spine draws, where the selection
/// is, and what the diff host is told when a snapshot lands.

private func r(_ files: [GitFileRow] = [], branch: String = "main", detached: String = "",
               ahead: Int = 0, behind: Int = 0, error: String? = nil) -> GitRootState {
    GitRootState(root: "/p/api", name: "api", branch: branch, detached: detached, ahead: ahead,
                 behind: behind, files: files, error: error, loading: false)
}

private func row(_ path: String, _ group: GitGroup = .changed, _ status: String = "M",
                 orig: String? = nil) -> GitFileRow {
    GitFileRow(path: path, origPath: orig, group: group, status: status)
}

private func root(_ name: String, _ files: [GitFileRow]) -> GitRootState {
    GitRootState(root: "/p/\(name)", name: name, branch: "main", detached: "", ahead: 0, behind: 0,
                 files: files, error: nil, loading: false)
}

private func diff(_ original: String = "a", _ modified: String = "b", language: String = "swift",
                  loading: Bool = false, error: String? = nil, binary: Bool = false) -> GitDiffState {
    GitDiffState(original: original, modified: modified, language: language, binary: binary,
                 bytes: 0, lines: 1, truncated: false, error: error, loading: loading)
}

// MARK: - The root header

@Test func rootLines() {
    #expect(gitRootLine(r()) == "api · main · clean")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], ahead: 2, behind: 1)) == "api · main ↑2 ↓1")
    #expect(gitRootLine(r([GitFileRow(path: "a", origPath: nil, group: .changed, status: "M")], branch: "", detached: "a1b2c3d")) == "api · a1b2c3d")
    #expect(gitRootLine(r(error: "not a git repository")) == "api · not a git repository")
}

@Test func aCleanRootAheadSaysBoth() {
    #expect(gitRootLine(r(ahead: 2)) == "api · main ↑2 · clean")
    #expect(gitRootLine(r(behind: 3)) == "api · main ↓3 · clean")
}

/// A root no read has reached yet has no branch and no SHA. It is not "clean" — nobody knows.
@Test func aRootNotYetReadIsOnlyItsName() {
    var pending = r(branch: "")
    pending.loading = true
    #expect(gitRootLine(pending) == "api")
}

/// Rule 8: the header carries an error's first line; the rest is drawn whole beneath it.
@Test func aLongErrorIsSplitBetweenTheHeaderAndTheLinesBeneath() {
    let one = r(error: "not a git repository")
    #expect(gitRootErrorDetail(one) == nil)
    let many = r(error: "fatal: bad object HEAD\nhint: run git fsck\nhint: or re-clone")
    #expect(gitRootLine(many) == "api · fatal: bad object HEAD")
    #expect(gitRootErrorDetail(many) == "hint: run git fsck\nhint: or re-clone")
    #expect(gitRootErrorDetail(r()) == nil)
}

// MARK: - The list

@Test func groupsAreLabelledAndAnEmptyGroupIsNotDrawn() {
    #expect(gitGroupLabel(.staged) == "STAGED")
    #expect(gitGroupLabel(.changed) == "CHANGES")
    #expect(gitGroupLabel(.untracked) == "UNTRACKED")
    let state = r([row("b.txt", .untracked, "?"), row("a.txt", .staged, "A"), row("c.txt", .untracked, "?")])
    let sections = gitListSections(state)
    #expect(sections.map(\.group) == [.staged, .untracked])
    #expect(sections[1].rows.map(\.path) == ["b.txt", "c.txt"])
}

/// The list's rows run in the same order the spine and ↑↓ do.
@Test func theListsOrderIsTheStepOrder() {
    let state = r([row("z.txt"), row("a.txt", .untracked, "?"), row("m.txt", .staged, "A"), row("b.txt")])
    let listed = gitListSections(state).flatMap(\.rows).map { GitSelection(root: state.root, path: $0.path, group: $0.group) }
    #expect(listed == gitRows([state]))
}

@Test func aRenameReadsOldToNew() {
    #expect(gitRowLabel(row("new.swift", .staged, "R", orig: "old.swift")) == "old.swift → new.swift")
    #expect(gitRowLabel(row("same.swift")) == "same.swift")
}

/// §5: amber for a change, green for an addition, and a deletion muted — red is production's.
@Test func statusTones() {
    #expect(gitStatusTone("M") == .modified)
    #expect(gitStatusTone("R") == .modified)
    #expect(gitStatusTone("T") == .modified)
    #expect(gitStatusTone("A") == .added)
    #expect(gitStatusTone("?") == .added)
    #expect(gitStatusTone("D") == .muted)
    #expect(gitStatusTone("U") == .modified)
}

// MARK: - The spine

@Test func theSpineIsOneColumnPerRootInStepOrder() {
    let api = root("api", [row("b.php"), row("a.php", .staged, "A")])
    let empty = root("docs", [])
    let portal = root("portal", [row("x.vue")])
    let marks = gitSpineMarks([api, empty, portal])
    #expect(marks.count == 3, "one array per root, an empty root included")
    #expect(marks[1].isEmpty)
    #expect(marks.flatMap { $0 } == gitRows([api, empty, portal]))
    #expect(marks[0].map(\.path) == ["a.php", "b.php"])
}

/// A mark draws its file's status letter; a partly staged file is two marks with two letters.
@Test func aMarkFindsItsRow() {
    let api = root("api", [row("a.php", .staged, "A"), row("a.php", .changed, "M")])
    let staged = GitSelection(root: "/p/api", path: "a.php", group: .staged)
    let changed = GitSelection(root: "/p/api", path: "a.php", group: .changed)
    #expect(gitFileRow(staged, in: [api])?.status == "A")
    #expect(gitFileRow(changed, in: [api])?.status == "M")
    #expect(gitFileRow(GitSelection(root: "/p/api", path: "gone", group: .changed), in: [api]) == nil)
}

// MARK: - Above the diff

@Test func theDiffHeaderNamesRootPathAndPosition() {
    let api = root("api", [row("BookingController.php"), row("ConfirmRequest.php", .untracked, "?")])
    let portal = root("portal", [row("booking.vue")])
    var s = GitSnapshot(roots: [api, portal], selection: nil, folded: true, diff: nil)
    #expect(gitDiffHeader(s) == nil)
    s.selection = GitSelection(root: "/p/api", path: "BookingController.php", group: .changed)
    #expect(gitPosition(s) == GitPosition(index: 0, count: 3))
    #expect(gitDiffHeader(s) == "api / BookingController.php · 1 of 3 · ↑↓")
    s.selection = GitSelection(root: "/p/portal", path: "booking.vue", group: .changed)
    #expect(gitDiffHeader(s) == "portal / booking.vue · 3 of 3 · ↑↓")
}

/// A selection whose row a refresh took away (before Rule 6 moved it) still names its file,
/// with no position it does not have.
@Test func aSelectionNotInTheListHasNoPosition() {
    let api = root("api", [row("a.php")])
    let s = GitSnapshot(roots: [api], selection: GitSelection(root: "/p/api", path: "gone.php", group: .changed),
                        folded: true, diff: nil)
    #expect(gitPosition(s) == nil)
    #expect(gitDiffHeader(s) == "api / gone.php")
}

@Test func banners() {
    var d = GitDiffState(original: "", modified: "", language: "plaintext", binary: true, bytes: 2_202_009,
                         lines: 0, truncated: false, error: nil, loading: false)
    #expect(gitDiffBanner(d) == "binary · 2.1 MB")
    // R9: `git_show` cuts each side at 2 MB of bytes, and `bytes` is the larger side's true size.
    d.binary = false; d.bytes = 3_145_728; d.truncated = true
    #expect(gitDiffBanner(d) == "file is 3.0 MB · first 2 MB shown")
    d.truncated = false
    #expect(gitDiffBanner(d) == nil)
}

@Test func smallBinarySizes() {
    var d = diff(binary: true)
    d.bytes = 512
    #expect(gitDiffBanner(d) == "binary · 512 bytes")
    d.bytes = 20_480
    #expect(gitDiffBanner(d) == "binary · 20 KB")
}

// MARK: - What the diff host is told

private let sel = GitSelection(root: "/p/api", path: "a.swift", group: .changed)
private let other = GitSelection(root: "/p/api", path: "b.swift", group: .changed)

private func snap(_ selection: GitSelection?, _ d: GitDiffState?) -> GitSnapshot {
    GitSnapshot(roots: [], selection: selection, folded: true, diff: d)
}

@Test func aFirstDiffIsShownFromTheTop() {
    #expect(gitDiffUpdate(shown: nil, snapshot: snap(sel, diff())) ==
            .show(GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift"), keepScroll: false))
}

/// Rule 6: a refresh that re-delivers the same file with new text keeps the scroll.
@Test func aRefreshOfTheSameFileKeepsTheScroll() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(sel, diff("a", "bb"))) ==
            .show(GitDiffShown(selection: sel, original: "a", modified: "bb", language: "swift"), keepScroll: true))
}

/// The same text again — a refresh where nothing in the file changed — is not re-shown.
@Test func theSameDiffAgainIsLeftAlone() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(sel, diff())) == .keep)
}

/// A refresh's re-read keeps the old texts while it loads: nothing to do until it lands.
@Test func aReloadOfTheSameFileKeepsWhatIsShown() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(sel, diff(loading: true))) == .keep)
}

/// A new file loading must not leave the last file's diff under the new file's name.
@Test func anotherFileLoadingClearsTheOldDiff() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(other, diff("", "", loading: true))) == .clear)
    #expect(gitDiffUpdate(shown: nil, snapshot: snap(other, diff("", "", loading: true))) == .keep)
}

@Test func anotherFileIsShownFromTheTop() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(other, diff())) ==
            .show(GitDiffShown(selection: other, original: "a", modified: "b", language: "swift"), keepScroll: false))
}

/// An error, a binary file, and no selection at all each leave the host empty.
@Test func nothingToShowClears() {
    let shown = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(sel, diff(error: "boom"))) == .clear)
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(sel, diff(binary: true))) == .clear)
    #expect(gitDiffUpdate(shown: shown, snapshot: snap(nil, nil)) == .clear)
    #expect(gitDiffUpdate(shown: nil, snapshot: snap(nil, nil)) == .keep)
}

@MainActor
private final class RecordingRenderer: DiffRenderer {
    var calls: [String] = []
    var top: Double = 0
    func show(original: String, modified: String, language: String) {
        calls.append("show \(modified) \(language)")
        top = 0   // a new model pair starts at the top, as Monaco's does
    }
    func clear() { calls.append("clear"); top = 0 }
    var scrollTop: Double {
        get { top }
        set { calls.append("scrollTop \(Int(newValue))"); top = newValue }
    }
}

@MainActor @Test func applyingAKeptScrollRestoresItAfterTheShow() {
    let renderer = RecordingRenderer()
    renderer.top = 340
    let next = GitDiffShown(selection: sel, original: "a", modified: "bb", language: "swift")
    let shown = gitApply(.show(next, keepScroll: true), to: renderer, shown: nil)
    #expect(renderer.calls == ["show bb swift", "scrollTop 340"])
    #expect(renderer.top == 340)
    #expect(shown == next)
}

@MainActor @Test func applyingANewFileStartsAtTheTop() {
    let renderer = RecordingRenderer()
    renderer.top = 340
    let next = GitDiffShown(selection: other, original: "a", modified: "b", language: "swift")
    _ = gitApply(.show(next, keepScroll: false), to: renderer, shown: nil)
    #expect(renderer.calls == ["show b swift"])
}

@MainActor @Test func applyingClearAndKeep() {
    let renderer = RecordingRenderer()
    let was = GitDiffShown(selection: sel, original: "a", modified: "b", language: "swift")
    #expect(gitApply(.keep, to: renderer, shown: was) == was)
    #expect(renderer.calls.isEmpty)
    #expect(gitApply(.clear, to: renderer, shown: was) == nil)
    #expect(renderer.calls == ["clear"])
}

// MARK: - Keys

/// Who acts on a key: the pane only while it owns the keyboard, and each key by fold state.
@Test func keysByFoldAndOwnership() {
    #expect(gitPaneKeyAction(.up, folded: true, owner: true) == .step(-1))
    #expect(gitPaneKeyAction(.down, folded: true, owner: true) == .step(1))
    #expect(gitPaneKeyAction(.escape, folded: true, owner: true) == .unfold)
    #expect(gitPaneKeyAction(.return, folded: true, owner: true) == nil)
    #expect(gitPaneKeyAction(.up, folded: false, owner: true) == .moveHighlight(-1))
    #expect(gitPaneKeyAction(.down, folded: false, owner: true) == .moveHighlight(1))
    #expect(gitPaneKeyAction(.return, folded: false, owner: true) == .selectHighlight)
    #expect(gitPaneKeyAction(.escape, folded: false, owner: true) == nil)
    for key in [GitPaneKey.up, .down, .escape, .return] {
        #expect(gitPaneKeyAction(key, folded: true, owner: false) == nil, "an overlay owns the keyboard")
        #expect(gitPaneKeyAction(key, folded: false, owner: false) == nil)
    }
}

/// D1: AppKit marks every arrow key with `numericPad` and `function`, so a pane that treated
/// any modifier as a chord ignored ↑↓ outright while Esc and Return worked. Only the four
/// the operator holds make a chord.
@Test func arrowKeysCarryNumericPadAndFunctionAndAreStillBare() {
    #expect(!gitPaneKeyIsChord([]))
    #expect(!gitPaneKeyIsChord([.numericPad, .function]), "a bare ↑ or ↓")
    #expect(!gitPaneKeyIsChord([.capsLock]))
    #expect(!gitPaneKeyIsChord([.capsLock, .numericPad, .function]))
    for held: GitKeyModifiers in [.shift, .control, .option, .command] {
        #expect(gitPaneKeyIsChord(held))
        #expect(gitPaneKeyIsChord(held.union([.numericPad, .function])), "⇧↓ and the like stay chords")
    }
}

/// The diff host's page takes ↑↓/Esc from Monaco only while the pane owns the keyboard and is folded.
@Test func theDiffCapturesKeysOnlyWhileItCanActOnThem() {
    #expect(gitDiffCapturesKeys(folded: true, owner: true))
    #expect(!gitDiffCapturesKeys(folded: true, owner: false))
    #expect(!gitDiffCapturesKeys(folded: false, owner: true))
}

// MARK: - The unfolded list's loading mark (Rule 5, final review item 11)

@Test func theClickedRowCarriesTheLoadingMarkUntilItsDiffArrives() {
    let a = GitSelection(root: "/p/api", path: "a", group: .changed)
    let b = GitSelection(root: "/p/api", path: "b", group: .changed)
    let roots = [root("api", [row("a"), row("b")])]
    let idle = GitSnapshot(roots: roots, selection: a, folded: false, diff: diff())
    // The operator's own click: the snapshot does not change until the select returns, so
    // the row the click named is the one marked.
    #expect(gitListLoadingRow(idle, opening: b) == b)
    // Nothing opening and the diff whole: no mark.
    #expect(gitListLoadingRow(idle, opening: nil) == nil)
    // The selection's diff loading (an agent's select, a refresh's re-read) marks that row.
    let loading = GitSnapshot(roots: roots, selection: a, folded: false, diff: diff(loading: true))
    #expect(gitListLoadingRow(loading, opening: nil) == a)
    // A click outranks it: the operator is waiting on the row they clicked.
    #expect(gitListLoadingRow(loading, opening: b) == b)
}

// MARK: - The folded column: spine or names (wide pane)

@Test func aNarrowFoldedPaneKeepsTheSpine() {
    #expect(gitFoldedListStyle(width: 0) == .spine)
    #expect(gitFoldedListStyle(width: 640) == .spine)
    #expect(gitFoldedListStyle(width: gitNamesColumnMinPaneWidth - 0.5) == .spine)
    #expect(GitFoldedListStyle.spine.width == 26)
}

@Test func aWideFoldedPaneDrawsTheNamesColumn() {
    #expect(gitNamesColumnMinPaneWidth == 900)
    #expect(gitFoldedListStyle(width: gitNamesColumnMinPaneWidth) == .names)
    #expect(gitFoldedListStyle(width: 1440) == .names)
    #expect(GitFoldedListStyle.names.width == 240)
}
