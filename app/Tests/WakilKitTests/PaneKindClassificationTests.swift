import Foundation
import Testing
@testable import WakilKit

// Two readers in the app answered for a pane kind they were never told
// about, and both were live traps rather than untidiness (#181):
//
//   * `PaneStore.snapshot(paneId:kind:)` chose between terminal and
//     EVERYTHING ELSE with a ternary, so an unwritten pane of any future
//     kind answered as an empty db grid — `columns: []`, `rows: []`, which
//     a reader takes for a successful read of an empty table.
//   * `WindowModel.restorePaneContents`' `kind == "db"` filter was a
//     negative test that silently skipped anything else. A later reader
//     who "fixes" it into a catch-all causes an unattended send on
//     relaunch, which is exactly what 2c-iv's api pane would make of it.
//
// Both now classify explicitly, through `PaneKinds`. These tests
// are the half of the guarantee the compiler cannot give: the totality
// test below makes `PaneKinds.standard` cover every `Pane.kinds` entry.
//
// **Neither half claims the mapping is right** — a kind pointed at the
// wrong case passes both, and deliberately so, because two kinds may hold
// the same shape. What is bought is that the mapping is a decision somebody
// wrote down. `theOnlyKindWhoseSubjectIsRerun` is the pin that makes one
// particular wrong mapping — a new kind swept into the launch refetch —
// fail rather than ship.

/// A kind this build will never register, so the unregistered-kind test
/// keeps testing that and does not start failing on the sub-phase that
/// registers whatever literal it happened to name. `"api"` was that literal
/// until 2c-iv was about to add it.
private let unregisteredKind = "kind-no-build-registers"

@Test func everyLayoutKindHasAPaneKind() {
    // Add a kind to `Pane.kinds` without a `PaneKind` in `PaneKinds.standard` and this fails.
    for kind in Pane.kinds { #expect(PaneKinds.kind(named: kind) != nil, "\(kind) has no PaneKind") }
}

@Test func anUnwrittenDbPaneStillAnswersAsAnEmptyDataSurface() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let snap = await store.snapshot(paneId: "p1", kind: "db")
    #expect(snap.kind == "db")
    #expect(snap.failure == nil)
    guard let surface = snap.dataSurface else {
        Issue.record("a db pane must answer as a data surface"); return
    }
    #expect(surface.columns.isEmpty)
    #expect(surface.rows.isEmpty)
}

@Test func anUnwrittenTerminalPaneStillAnswersAsAnEmptyTerminal() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let snap = await store.snapshot(paneId: "p1", kind: "terminal")
    #expect(snap.kind == "terminal")
    #expect(snap.failure == nil)
    guard snap.terminal != nil else {
        Issue.record("a terminal pane must answer as a terminal"); return
    }
}

@Test func anUnwrittenPaneOfAnUnregisteredKindIsNotAnEmptyDataSurface() async {
    // The trap, stated as the assertion it always deserved. A reader must
    // not be handed `columns: [], rows: []` for a kind this build cannot
    // describe and read it as a table that came back empty. It answers
    // `.none` with a failure naming the kind, which is the one
    // kind-independent key `PaneSnapshot` has for exactly this.
    let store = PaneStore()
    let snap = await store.snapshot(paneId: "p1", kind: unregisteredKind)
    #expect(snap.kind == unregisteredKind)
    if snap.dataSurface != nil {
        Issue.record("an unregistered kind must not answer as an empty grid")
    }
    if snap.terminal != nil {
        Issue.record("an unregistered kind must not answer as an empty terminal")
    }
    #expect(snap.failure != nil, "the refusal must say something")
    #expect(snap.failure?.contains(unregisteredKind) == true, "and must name the kind")
}

@Test func anIdTheLayoutDoesNotHoldStillAnswersKindNull() async {
    // Unchanged, and asserted here because the new classification sits on
    // the same path: a `nil` kind is not an unregistered kind. A pane can
    // close between the `read_layout` that named it and the `read_pane`
    // that asks, and that is not a failure.
    let store = PaneStore()
    let snap = await store.snapshot(paneId: "gone", kind: nil)
    #expect(snap.kind == nil)
    #expect(snap.failure == nil)
    guard snap.contents == nil else {
        Issue.record("an unknown pane id answers .none"); return
    }
}

@Test func theOnlyKindsWhoseSubjectIsRerunAtLaunchAreReads() {
    // `restorePaneContents` re-runs a pane's subject when a layout is loaded
    // from disk. Which kinds that is true of is now a property of the
    // classification rather than a string compare at the call site — so it
    // is checkable without standing up a window, and it is PINNED here
    // rather than merely derived.
    //
    // **The pin is the safety claim.** Totality only forces a new kind to
    // have a row; it does not stop that row being `.dataSurface`, which
    // would silently enrol the new kind in the launch refetch. For an api
    // pane, whose stored subject is a request, that is an unattended send
    // on relaunch — Invariant 6, lost at startup. Any kind joining this set
    // must edit this line and say why.
    //
    // **`git` joined in 3a-i, and why that is safe:** its subject is
    // `git status` per root, a read with no side effect, so re-running it
    // at launch is how a reopened pane is current. It is not a write.
    #expect(PaneKinds.kind(named: "db")?.rerunsSubjectOnRestore == true)
    #expect(PaneKinds.kind(named: "terminal")?.rerunsSubjectOnRestore == false)
    let rerun = Pane.kinds.sorted().filter { PaneKinds.kind(named: $0)?.rerunsSubjectOnRestore == true }
    #expect(rerun == ["db", "git"],
            "only db and git (both reads) have their subject re-run at launch; a new kind here is a deliberate, reviewed change, not a consequence of being classified")
}

@Test func onlyReadsRerunOnRestore() {
    #expect(PaneKinds.kind(named: "db")?.rerunsSubjectOnRestore == true)
    #expect(PaneKinds.kind(named: "git")?.rerunsSubjectOnRestore == true)
    #expect(PaneKinds.kind(named: "api")?.rerunsSubjectOnRestore == false)
    #expect(PaneKinds.kind(named: "terminal")?.rerunsSubjectOnRestore == false)
    #expect(PaneKinds.kind(named: Pane.settingsKind)?.rerunsSubjectOnRestore == false)
}
