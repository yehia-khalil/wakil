import Foundation
import Testing
@testable import WakilKit

private func scratch() -> URL {
    testScratchRoot
        .appendingPathComponent("layouts-\(UUID().uuidString)", isDirectory: true)
}

/// Every test here names an org and a project, which with an environment is
/// exactly what a `LayoutScope` is. A helper rather than the constructor at
/// each of two dozen call sites, so the assertions stay the width they were
/// when the two were separate arguments. The environment is `dev` unless a
/// test is about environments.
private func scope(_ organization: String, _ project: String, _ environment: String = "dev") -> LayoutScope {
    LayoutScope(organization: organization, project: project, environment: environment)
}

@Test func aSavedLayoutLoadsBackIdentically() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    var graph = SnapGraph()
    graph.link("db-1", .right, to: "db-2")
    let snapshot = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "One",
                 frame: PaneFrame(x: 10, y: 20, width: 300, height: 200)),
            Pane(id: "db-2", kind: "db", title: "Two",
                 frame: PaneFrame(x: 310, y: 20, width: 300, height: 200)),
        ],
        focusedId: "db-2", maximizedId: nil, graph: graph)

    try store.save(snapshot, for: scope("personal", "booking"))
    #expect(store.load(for: scope("personal", "booking")).snapshot == snapshot)
}

@Test func loadingSomethingNeverSavedIsNilWithNoNote() {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = LayoutPersistence(directory: directory).load(for: scope("personal", "nope"))
    // Absence is not degradation: a project simply has no saved layout
    // yet, and a note here would put a warning in the window on every
    // first run.
    #expect(result.snapshot == nil)
    #expect(result.note == nil)
}

@Test func aCorruptLayoutDegradesToNilWithANote() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    try store.save(LayoutSnapshot(), for: scope("personal", "booking"))

    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking@dev.json")
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)

    let result = store.load(for: scope("personal", "booking"))
    #expect(result.snapshot == nil)
    let note = try #require(result.note)
    #expect(note.contains("booking"))
}

@Test func twoProjectsInOneOrgDoNotOverwriteEachOther() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let one = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "One", frame: PaneFrame(x: 1, y: 1, width: 1, height: 1))
    ])
    let two = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "Two", frame: PaneFrame(x: 2, y: 2, width: 2, height: 2))
    ])
    try store.save(one, for: scope("personal", "alpha"))
    try store.save(two, for: scope("personal", "beta"))

    #expect(store.load(for: scope("personal", "alpha")).snapshot == one)
    #expect(store.load(for: scope("personal", "beta")).snapshot == two)
}

@Test func projectNamesWithPathSeparatorsCannotEscapeTheDirectory() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    try store.save(LayoutSnapshot(), for: scope("personal", "../../escaped"))
    // Whatever it wrote, it wrote inside `directory`.
    let escaped = directory.deletingLastPathComponent().appendingPathComponent("escaped.json")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(store.load(for: scope("personal", "../../escaped")).snapshot == LayoutSnapshot())
}

@Test func orgNamesWithPathSeparatorsCannotEscapeTheDirectory() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    try store.save(LayoutSnapshot(), for: scope("../../escaped", "booking"))
    // Whatever it wrote, it wrote inside `directory` — not as a sibling
    // directory one or two levels up.
    let escaped = directory.deletingLastPathComponent()
        .appendingPathComponent("escaped").appendingPathComponent("booking@dev.json")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
    #expect(store.load(for: scope("../../escaped", "booking")).snapshot == LayoutSnapshot())

    // A literal slash in the org name must not carve out a subdirectory
    // either — "a/b" is one flattened org, not a nested "a" containing "b".
    try store.save(LayoutSnapshot(), for: scope("a/b", "booking"))
    let nested = directory.appendingPathComponent("a")
        .appendingPathComponent("b").appendingPathComponent("booking@dev.json")
    #expect(!FileManager.default.fileExists(atPath: nested.path))
    #expect(store.load(for: scope("a/b", "booking")).snapshot == LayoutSnapshot())
}

/// **The one criterion a round trip through this API cannot pin.** Every
/// other test here saves and loads through the same code, so it would
/// still pass if the path moved wholesale — and a moved path silently
/// orphans every arrangement the operator already has.
///
/// So this one writes the file the way a previous release wrote it: bytes,
/// by hand, at `<org>/<project>.json`, with no `save` involved. If keying
/// on a `LayoutScope` ever changes where the file is looked for, this
/// fails and nothing else does.
@Test func aFileWrittenAtTheLegacyOrgSlashProjectPathStillLoads() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }

    let orgDir = directory.appendingPathComponent("personal")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)
    let onDisk = LayoutSnapshot(
        panes: [
            Pane(id: "db-1", kind: "db", title: "events",
                 frame: PaneFrame(x: 12, y: 34, width: 640, height: 420))
        ],
        focusedId: "db-1")
    try JSONEncoder().encode(onDisk).write(to: orgDir.appendingPathComponent("booking.json"))

    let loaded = LayoutPersistence(directory: directory)
        .load(for: scope("personal", "booking"))
    #expect(loaded.snapshot == onDisk)
    #expect(loaded.note == nil)
}

// MARK: - The environment joins the scope (Plan 3, ruling R3)

/// R3: a project file written before the environment was in the path seeds **every**
/// environment of that project that has no file of its own. A save writes only the
/// environment's own file, and the legacy file is never rewritten — rollback is reverting the
/// branch, which finds it as it was.
@Test func aLegacyProjectFileSeedsEveryEnvironment() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let orgDir = directory.appendingPathComponent("acme")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)
    let legacy = LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "before environments",
                     frame: PaneFrame(x: 1, y: 2, width: 640, height: 420))],
        focusedId: "db-1")
    let legacyFile = orgDir.appendingPathComponent("api.json")
    try JSONEncoder().encode(legacy).write(to: legacyFile)
    let legacyBytes = try Data(contentsOf: legacyFile)
    let store = LayoutPersistence(directory: directory)

    let staging = store.load(for: scope("acme", "api", "staging"))
    #expect(staging.snapshot == legacy)
    #expect(staging.note == nil)
    let production = store.load(for: scope("acme", "api", "production"))
    #expect(production.snapshot == legacy)
    #expect(production.note == nil)

    let worked = LayoutSnapshot(
        panes: [Pane(id: "db-2", kind: "db", title: "staging's own",
                     frame: PaneFrame(x: 3, y: 4, width: 640, height: 420))],
        focusedId: "db-2")
    try store.save(worked, for: scope("acme", "api", "staging"))

    #expect(FileManager.default.fileExists(atPath: orgDir.appendingPathComponent("api@staging.json").path))
    #expect(try Data(contentsOf: legacyFile) == legacyBytes, "the legacy file was rewritten")
    #expect(store.load(for: scope("acme", "api", "staging")).snapshot == worked)
    // Production has no file of its own yet, so it still opens on the legacy seed.
    #expect(store.load(for: scope("acme", "api", "production")).snapshot == legacy)
}

/// Before this plan the window filed a project under its display NAME; the scope now carries the
/// registry key. A file under the name is read first, then one under the key.
@Test func aLegacyFileUnderTheDisplayNameIsReadBeforeOneUnderTheKey() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let orgDir = directory.appendingPathComponent("acme")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)
    let byName = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "by name", frame: PaneFrame(x: 1, y: 1, width: 1, height: 1)),
    ])
    let byKey = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "by key", frame: PaneFrame(x: 2, y: 2, width: 2, height: 2)),
    ])
    try JSONEncoder().encode(byName).write(to: orgDir.appendingPathComponent("API Service.json"))
    try JSONEncoder().encode(byKey).write(to: orgDir.appendingPathComponent("api.json"))
    let store = LayoutPersistence(directory: directory)

    #expect(store.load(for: scope("acme", "api", "staging"), legacyName: "API Service").snapshot == byName)
    #expect(store.load(for: scope("acme", "api", "staging")).snapshot == byKey)
    #expect(store.load(for: scope("acme", "api", "staging"), legacyName: "Gone").snapshot == byKey)
}

/// A conversation with no file of its own, in an environment with none either, reaches the
/// legacy project file too — and a legacy file of the conversation's own comes first.
@Test func aConversationFallsBackThroughItsOwnLegacyFileToTheProjects() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let orgDir = directory.appendingPathComponent("acme")
    let rootDir = orgDir.appendingPathComponent("conversations").appendingPathComponent("root-a")
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    let project = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "project", frame: PaneFrame(x: 1, y: 1, width: 1, height: 1)),
    ])
    let own = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "own", frame: PaneFrame(x: 2, y: 2, width: 2, height: 2)),
    ])
    try JSONEncoder().encode(project).write(to: orgDir.appendingPathComponent("api.json"))
    let store = LayoutPersistence(directory: directory)

    #expect(store.load(for: conversation("acme", "api", "root-a", "staging")).snapshot == project)

    try JSONEncoder().encode(own).write(to: rootDir.appendingPathComponent("api.json"))
    #expect(store.load(for: conversation("acme", "api", "root-a", "staging")).snapshot == own)
}

/// The environment is part of the file name, and a project with no environment declared still
/// gets one file — never the legacy name, which a save must not overwrite.
@Test func anEnvironmentIsInTheFileNameAndNoEnvironmentIsNotTheLegacyName() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    let orgDir = directory.appendingPathComponent("acme")

    try store.save(LayoutSnapshot(), for: scope("acme", "api", "staging"))
    try store.save(LayoutSnapshot(), for: scope("acme", "api", ""))
    try store.save(LayoutSnapshot(), for: conversation("acme", "api", "root-a", "staging"))

    #expect(FileManager.default.fileExists(atPath: orgDir.appendingPathComponent("api@staging.json").path))
    #expect(!FileManager.default.fileExists(atPath: orgDir.appendingPathComponent("api.json").path))
    #expect(FileManager.default.fileExists(atPath: orgDir.appendingPathComponent("conversations")
        .appendingPathComponent("root-a").appendingPathComponent("api@staging.json").path))
}

@Test func theDefaultDirectoryHangsOffTheGivenHome() {
    let url = LayoutPersistence.defaultDirectory(home: "/tmp/somewhere")
    #expect(url.path == "/tmp/somewhere/.wakil/layouts")
}

@Test func savingTwiceIsStableOnDisk() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    var graph = SnapGraph()
    graph.link("db-2", .left, to: "db-1")
    graph.link("db-1", .bottom, to: "db-3")
    let snapshot = LayoutSnapshot(panes: [], focusedId: nil, maximizedId: nil, graph: graph)

    try store.save(snapshot, for: scope("personal", "booking"))
    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking@dev.json")
    let first = try Data(contentsOf: file)
    try store.save(snapshot, for: scope("personal", "booking"))
    // Byte-identical: an unchanged arrangement must not churn the file,
    // which is what `SnapGraph.links`' sort is for.
    #expect(try Data(contentsOf: file) == first)
}

/// `busy` is runtime state: a dispatch that was in flight when the app quit
/// is not in flight when it reopens. It is excluded from `Pane`'s
/// `CodingKeys`, so it cannot reach the file at all — and once Task 14
/// draws the rail, a pane restored as busy would glow for a call nobody is
/// waiting on, with nothing to ever clear it.
@Test func aBusyPaneIsSavedAndRestoredIdle() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let snapshot = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "One",
             frame: PaneFrame(x: 1, y: 2, width: 3, height: 4), busy: true)
    ])
    try store.save(snapshot, for: scope("personal", "booking"))

    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking@dev.json")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("busy"), "\(text)")

    let loaded = try #require(store.load(for: scope("personal", "booking")).snapshot)
    #expect(loaded.panes.first?.busy == false)
    #expect(loaded.panes.first?.frame == snapshot.panes[0].frame)
}

/// `density` is a setting, not runtime state like `busy` — the mirror image
/// of `aBusyPaneIsSavedAndRestoredIdle` above: it must be in the file and
/// must come back unchanged, because a pane the operator made dense is
/// still meant to be dense after a quit.
@Test func aDensePaneIsSavedAndRestoredDense() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let snapshot = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "One",
             frame: PaneFrame(x: 1, y: 2, width: 3, height: 4), density: .dense)
    ])
    try store.save(snapshot, for: scope("personal", "booking"))

    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking@dev.json")
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("dense"), "\(text)")

    let loaded = try #require(store.load(for: scope("personal", "booking")).snapshot)
    #expect(loaded.panes.first?.density == .dense)
}

/// A file written before `preMaximizeFrames` existed must still load.
/// Rejecting the whole layout because the app that wrote it was older is
/// the silent loss the note channel exists to avoid, and the decoder
/// synthesized for a non-optional field would do exactly that.
@Test func aLayoutFileWithoutPreMaximizeFramesStillLoads() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    try store.save(LayoutSnapshot(), for: scope("personal", "booking"))

    let file = directory.appendingPathComponent("personal").appendingPathComponent("booking@dev.json")
    try #"{"panes":[],"graph":{"links":[]}}"#.write(to: file, atomically: true, encoding: .utf8)

    let result = store.load(for: scope("personal", "booking"))
    #expect(result.note == nil)
    #expect(result.snapshot == LayoutSnapshot())
}

// MARK: - Spec §4.3: a pane kind this build cannot draw is dropped with a note
//
// 2b-i's runbook recorded this as the one §4.3 clause it did not implement,
// and named the trigger: "the check must land in 2c, before 2c adds its
// second pane kind. Not 'someday' — the moment there are two kinds, a
// layout saved under a version that had a third becomes loadable, and a
// pane the app cannot draw goes on the canvas." What it waited on was a
// validity set to check against, which `Pane.kinds` now is.
//
// `"terminal"` was this test's original stand-in for a kind this build
// cannot draw. 2c-iii's `term_open` (Task 10) made it a real, drawable
// kind — `Pane.kinds` now contains it — so asserting it gets dropped would
// be asserting behaviour this build no longer has. `"widget"` replaces it:
// a kind no phase has named or plans to, unlike `"api"`/`"board"`/
// `"session"`, which `Pane.kinds`'s own comment already promises to real
// sub-phases and which would make this test wrong again the day one lands.

@Test func aSavedPaneOfAnUndrawableKindIsDroppedWithANote() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let good = Pane(
        id: "db-1", kind: "db", title: "Customers",
        frame: PaneFrame(x: 0, y: 0, width: 300, height: 200))
    let bad = Pane(
        id: "widget-2", kind: "widget", title: "Mystery",
        frame: PaneFrame(x: 10, y: 10, width: 300, height: 200))
    var graph = SnapGraph()
    graph.link(good.id, .right, to: bad.id)
    try store.save(
        LayoutSnapshot(
            panes: [good, bad], focusedId: bad.id, maximizedId: bad.id, graph: graph,
            preMaximizeFrames: [bad.id: bad.frame]),
        for: scope("personal", "booking"))

    let result = store.load(for: scope("personal", "booking"))
    let loaded = try #require(result.snapshot)

    #expect(loaded.panes.map(\.id) == ["db-1"])
    // Everything that referred to the dropped pane goes with it: a link to
    // a pane that is not there coordinates a resize against nothing, and a
    // focusedId or maximizedId naming it is a canvas pointing at a hole.
    #expect(loaded.graph.links.isEmpty)
    #expect(loaded.focusedId == "db-1")
    #expect(loaded.maximizedId == nil)
    #expect(loaded.preMaximizeFrames.isEmpty)

    let note = try #require(result.note, "a dropped pane must not be silent")
    #expect(note.contains("Mystery"))
    #expect(note.contains("widget"))
}

/// A layout holding only kinds this build draws loads unchanged and says
/// nothing — the note channel must stay quiet when nothing was lost, or it
/// trains the operator to ignore it.
@Test func aLayoutOfKnownKindsLoadsWithNoNote() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)
    let pane = Pane(
        id: "db-1", kind: "db", title: "Customers",
        frame: PaneFrame(x: 0, y: 0, width: 300, height: 200))
    try store.save(
        LayoutSnapshot(panes: [pane], focusedId: pane.id),
        for: scope("personal", "booking"))

    let result = store.load(for: scope("personal", "booking"))
    #expect(result.note == nil)
    #expect(result.snapshot?.panes.map(\.id) == ["db-1"])
}

// MARK: - A conversation's own arrangement (#147)

/// A conversation is identified by its lineage root — the oldest ancestor
/// of the session, which is what one conversation keeps across every
/// resume that forked it.
private func conversation(
    _ organization: String, _ project: String, _ root: String, _ environment: String = "dev"
) -> LayoutScope {
    LayoutScope(organization: organization, project: project, environment: environment, lineageRoot: root)
}

@Test func aConversationsArrangementRoundTripsUnderItsLineageRoot() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let snapshot = LayoutSnapshot(
        panes: [Pane(id: "db-1", kind: "db", title: "events",
                     frame: PaneFrame(x: 1, y: 2, width: 3, height: 4))],
        focusedId: "db-1")
    try store.save(snapshot, for: conversation("personal", "booking", "root-a"))

    #expect(store.load(for: conversation("personal", "booking", "root-a")).snapshot == snapshot)
}

/// Two conversations in one project stop overwriting each other — the
/// defect #142 exists to close.
@Test func twoConversationsInOneProjectKeepSeparateArrangements() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let database = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "database work",
             frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    ])
    let tickets = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "ticket work",
             frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
    ])
    try store.save(database, for: conversation("personal", "booking", "root-a"))
    try store.save(tickets, for: conversation("personal", "booking", "root-b"))

    #expect(store.load(for: conversation("personal", "booking", "root-a")).snapshot == database)
    #expect(store.load(for: conversation("personal", "booking", "root-b")).snapshot == tickets)
}

/// #142's user story 12: "the same conversation keys to the same
/// arrangement every time regardless of which project is active, so that a
/// fork chain crossing projects cannot silently rekey and lose a
/// workspace." The project is carried for the seed lookup, so it must NOT
/// reach the conversation's own path.
/// **Overturned at the walk, 2026-09-20 (#160).** This test asserted the
/// opposite until then — one conversation, one arrangement, whichever
/// project was active — which is #142's user story 12 as #147 implemented
/// it. Walking `conversation-layouts-acceptance.md` step 10 the operator
/// switched to a project with no sessions at all and the canvas did not
/// move, because the project was not part of the key. The ruling is on
/// #142, dated; the surviving half of story 12 is
/// `aConversationInOneProjectResolvesToOneArrangementWhateverIsListed`
/// below.
@Test func aConversationKeepsOneArrangementPerProjectItIsVisitedFrom() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let booking = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "the booking workspace",
             frame: PaneFrame(x: 5, y: 6, width: 7, height: 8))
    ])
    let invoicing = LayoutSnapshot(panes: [
        Pane(id: "db-2", kind: "db", title: "the invoicing workspace",
             frame: PaneFrame(x: 9, y: 9, width: 7, height: 8))
    ])
    try store.save(booking, for: conversation("personal", "booking", "root-a"))
    try store.save(invoicing, for: conversation("personal", "invoicing", "root-a"))

    // One conversation, two projects, two arrangements — and neither has
    // overwritten the other.
    #expect(store.load(for: conversation("personal", "booking", "root-a")).snapshot == booking)
    #expect(store.load(for: conversation("personal", "invoicing", "root-a")).snapshot == invoicing)
}

/// **Story 12's surviving half**, and the one the key was really
/// protecting: the same conversation in the same project resolves to the
/// same arrangement every time, whatever `list_sessions` happens to
/// return. That is bought by resolving the root against the organisation's
/// complete parent map in Go — unchanged by #160 — and not by what the
/// scope carries.
@Test func aConversationInOneProjectResolvesToOneArrangementWhateverIsListed() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let snapshot = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "one workspace",
             frame: PaneFrame(x: 5, y: 6, width: 7, height: 8))
    ])
    try store.save(snapshot, for: conversation("personal", "booking", "root-a"))

    // A later session of the same chain, resolved to the same root: one
    // arrangement, however many forks asked for it.
    #expect(store.load(for: conversation("personal", "booking", "root-a")).snapshot == snapshot)
}

/// Every file on disk today is project-keyed and cannot be mapped to a
/// lineage — the information is not in it — so those files become the seed
/// a new conversation opens on, rather than being migrated or discarded.
@Test func aConversationWithNoArrangementOfItsOwnOpensOnTheProjects() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let seed = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "the project's panes",
             frame: PaneFrame(x: 9, y: 9, width: 9, height: 9))
    ])
    try store.save(seed, for: scope("personal", "booking"))

    let loaded = store.load(for: conversation("personal", "booking", "brand-new"))
    #expect(loaded.snapshot == seed)
    // Falling back is not degradation: it is the designed first run of a
    // conversation, and a note here would train the operator to ignore notes.
    #expect(loaded.note == nil)
}

/// The other half: a brand-new conversation in a project nothing has been
/// arranged in opens an empty canvas, not a note and not a failure.
@Test func aConversationInAProjectWithNoArrangementAtAllLoadsNothing() {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }

    let loaded = LayoutPersistence(directory: directory)
        .load(for: conversation("personal", "untouched", "brand-new"))
    #expect(loaded.snapshot == nil)
    #expect(loaded.note == nil)
}

/// #142's user story 18: the project's arrangement keeps being updated
/// while work proceeds, so it stays a useful seed for the NEXT new
/// conversation. Saving under a conversation therefore writes both.
@Test func savingAConversationAlsoRefreshesTheProjectsSeed() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let snapshot = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "worked on in a conversation",
             frame: PaneFrame(x: 2, y: 2, width: 2, height: 2))
    ])
    try store.save(snapshot, for: conversation("personal", "booking", "root-a"))

    #expect(store.load(for: scope("personal", "booking")).snapshot == snapshot)
}

/// #161. The seed's job is to be a useful STARTING POINT for the next new
/// conversation in the project, and nothing never is. A conversation is
/// entitled to have nothing open — that is a state #142 names outright —
/// but it must not push that state onto the project.
///
/// Found by reading the files after the first walk: carrying a
/// conversation into a project it had never been arranged in created that
/// project's seed holding `{"panes": []}`. It cost nothing there because
/// the project had no seed yet. This is the case where it would.
@Test func aConversationWithNothingOpenDoesNotEmptyTheProjectsSeed() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let seed = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "the project's own arrangement",
             frame: PaneFrame(x: 3, y: 3, width: 3, height: 3))
    ])
    try store.save(seed, for: scope("personal", "booking"))

    // A conversation carried into this project with nothing open in it.
    try store.save(LayoutSnapshot(), for: conversation("personal", "booking", "root-a"))

    #expect(
        store.load(for: scope("personal", "booking")).snapshot == seed,
        "the seed must survive a conversation that has nothing open in the project")
    // And the conversation still records that nothing was open — "nothing"
    // is a state it may be in, and it has to survive a relaunch.
    #expect(
        store.load(for: conversation("personal", "booking", "root-a")).snapshot
            == LayoutSnapshot())
}

/// The other half, so the guard cannot be widened into "never write an
/// empty arrangement". An operator who closed every pane in a project
/// meant to close them — `activateLayout` already refuses to resurrect an
/// emptied canvas for the same reason — so a PROJECT-scoped save writes
/// whatever it is handed.
@Test func closingEveryPaneInAProjectStillEmptiesThatProjectsOwnFile() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    try store.save(
        LayoutSnapshot(panes: [
            Pane(id: "db-1", kind: "db", title: "before",
                 frame: PaneFrame(x: 3, y: 3, width: 3, height: 3))
        ]),
        for: scope("personal", "booking"))

    try store.save(LayoutSnapshot(), for: scope("personal", "booking"))

    #expect(store.load(for: scope("personal", "booking")).snapshot == LayoutSnapshot())
}

/// An unreadable arrangement opens an empty canvas **and** says so. It must
/// NOT quietly fall through to the project's seed: the conversation's file
/// exists and could not be read, which is degradation, and degradation is
/// visible or it is nothing.
@Test func anUnreadableConversationFileSaysSoRatherThanFallingBackToTheSeed() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let seed = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "the project's panes",
             frame: PaneFrame(x: 9, y: 9, width: 9, height: 9))
    ])
    try store.save(seed, for: scope("personal", "booking"))
    try store.save(LayoutSnapshot(), for: conversation("personal", "booking", "root-a"))
    // Corrupted by path, which also pins where a conversation's file
    // lives: under the org, under its root, and named for the PROJECT
    // (#160) — a conversation keeps one arrangement per project it is
    // visited from, so the project is in the path exactly as it is in the
    // key.
    let file = directory.appendingPathComponent("personal")
        .appendingPathComponent("conversations").appendingPathComponent("root-a")
        .appendingPathComponent("booking@dev.json")
    #expect(FileManager.default.fileExists(atPath: file.path))
    try "{ not json".write(to: file, atomically: true, encoding: .utf8)

    let loaded = store.load(for: conversation("personal", "booking", "root-a"))
    #expect(loaded.snapshot == nil)
    #expect(try #require(loaded.note).contains("root-a"))
}

/// A conversation's file is never written where a project's file is looked
/// for, whatever the lineage root is called — including a root that
/// happens to share a project's name.
@Test func aConversationsFileCannotCollideWithAProjectsFile() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LayoutPersistence(directory: directory)

    let projectSnapshot = LayoutSnapshot(panes: [
        Pane(id: "db-1", kind: "db", title: "the project",
             frame: PaneFrame(x: 1, y: 1, width: 1, height: 1))
    ])
    try store.save(projectSnapshot, for: scope("personal", "booking"))
    // A conversation whose lineage root is spelled exactly like a project.
    try store.save(LayoutSnapshot(), for: conversation("personal", "other", "booking"))

    #expect(store.load(for: scope("personal", "booking")).snapshot == projectSnapshot)
}

/// **Overturned at the walk, 2026-09-20 (#160).** This asserted the
/// reverse — one conversation, one key, whichever project it was visited
/// from — which #147 hand-wrote a `Hashable` conformance specifically to
/// guarantee. Its argument was that a conversation's *file path* already
/// dropped the project, so a key that kept it would let two memory entries
/// name one file. True, and the answer is that both carry it: memory and
/// disk are keyed the same way or they are not keyed at all, which is
/// `LayoutScope`'s reason to exist, and #160 moves them together.
///
/// The conformance is synthesised again, so this test is about the
/// decision rather than about a hand-written `==` that could drift from
/// its `hash`.
@Test func aConversationIsOneKeyPerProjectItIsVisitedFrom() {
    let fromOne = LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "root-a")
    let fromAnother = LayoutScope(organization: "acme", project: "gadgets", environment: "dev", lineageRoot: "root-a")
    #expect(fromOne != fromAnother)
    #expect(Set([fromOne, fromAnother]).count == 2)

    // Equal on all three fields is still one key — the property that makes
    // a scope usable as a dictionary key at all.
    #expect(fromOne == LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "root-a"))
    #expect(
        fromOne.hashValue
            == LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "root-a").hashValue)

    // The organisation still separates them: it is a credential boundary,
    // and a lineage store is per-org, so the same root in two orgs is two
    // conversations that merely share a name.
    #expect(fromOne != LayoutScope(organization: "globex", project: "widgets", environment: "dev", lineageRoot: "root-a"))
    // And two conversations are still two keys.
    #expect(fromOne != LayoutScope(organization: "acme", project: "widgets", environment: "dev", lineageRoot: "root-b"))
    // And one conversation in two environments of one project is two keys: each is a place.
    #expect(fromOne != LayoutScope(organization: "acme", project: "widgets", environment: "prod", lineageRoot: "root-a"))
    // A conversation's scope is never a project's, even spelled the same.
    #expect(scope("acme", "widgets") != scope("acme", "gadgets"))
    #expect(scope("acme", "widgets") != fromOne)
}

// 3b-iii, R1: a column view this build does not know decodes as `.files`.
@Test func anUnknownColumnViewDecodesAsFiles() throws {
    let json = #"{"shown":true,"view":"timeline","width":240,"open":[]}"#
    let c = try JSONDecoder().decode(EditorColumnState.self, from: Data(json.utf8))
    #expect(c.view == .files && c.shown)
}

@Test func aLayoutWhoseDefaultColumnIsOnAnUnknownViewStillLoads() throws {
    let empty = try JSONEncoder().encode(LayoutSnapshot(panes: [], graph: SnapGraph()))
    var object = try #require(JSONSerialization.jsonObject(with: empty) as? [String: Any])
    object["editorColumnDefault"] = ["shown": true, "view": "timeline", "width": 300, "open": [String]()] as [String: Any]
    let json = try JSONSerialization.data(withJSONObject: object)
    let s = try JSONDecoder().decode(LayoutSnapshot.self, from: json)
    #expect(s.editorColumnDefault?.view == .files && s.editorColumnDefault?.width == 300)
}

// 3b-iii: the Changes view's column state.
@Test func aColumnSavedBefore3biiiDecodesWithNoChangesState() throws {
    let json = #"{"shown":true,"view":"search","width":240,"open":["/p/api"]}"#
    let c = try JSONDecoder().decode(EditorColumnState.self, from: Data(json.utf8))
    #expect(c.changesClosed.isEmpty && c.changesHighlight == nil && c.open == ["/p/api"])
}

@Test func theChangesStateRoundTrips() throws {
    let c = EditorColumnState(shown: true, view: .changes, width: 260, open: [], changesClosed: ["/p/web"],
                              changesHighlight: EditorChangesRow(root: "/p/api", path: "a.go", group: "staged"))
    #expect(try JSONDecoder().decode(EditorColumnState.self, from: JSONEncoder().encode(c)) == c)
}

// MARK: - 3b-iii: a saved Git pane comes back as the editor on Changes

@Test func aSavedGitPaneLoadsAsAnEditorPaneOnChangesWithItsFrameAndId() throws {
    let frame = PaneFrame(x: 10, y: 20, width: 600, height: 400)
    var s = LayoutSnapshot(panes: [Pane(id: "git-1", kind: "git", title: "Git", frame: frame)], graph: SnapGraph())
    s.focusedId = "git-1"
    let out = layoutMigratingGitPanes(s)
    let p = try #require(out.panes.first)
    #expect(p.id == "git-1" && p.kind == "editor" && p.title == "Editor" && p.frame == frame)
    #expect(p.editorColumn == EditorColumnState(shown: true, view: .changes, width: 240, open: []))
    #expect(p.editorTabs == nil && out.focusedId == "git-1")
}

@Test func theMigratedColumnTakesTheLayoutsDefaultWidth() {
    var s = LayoutSnapshot(panes: [Pane(id: "g", kind: "git", title: "Git", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))],
                           graph: SnapGraph())
    s.editorColumnDefault = EditorColumnState(shown: false, view: .search, width: 310, open: [])
    #expect(layoutMigratingGitPanes(s).panes[0].editorColumn?.width == 310)
}

@Test func anyOtherUnknownKindIsStillDropped() throws {
    let s = LayoutSnapshot(panes: [Pane(id: "x", kind: "database", title: "D", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))],
                           graph: SnapGraph())
    let checked = layoutDroppingUnknownPaneKinds(layoutMigratingGitPanes(s))
    #expect(checked.snapshot.panes.isEmpty && checked.note != nil)
}

@Test func aLayoutFileWithAGitPaneComesBackAsAnEditor() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = LayoutPersistence(directory: directory)
    try persistence.save(LayoutSnapshot(panes: [Pane(id: "git-1", kind: "git", title: "Git",
                                                     frame: PaneFrame(x: 0, y: 0, width: 500, height: 300))],
                                        graph: SnapGraph()), for: scope("acme", "p"))
    let (loaded, note) = persistence.load(for: scope("acme", "p"))
    #expect(loaded?.panes.first?.kind == "editor" && note == nil)
}
