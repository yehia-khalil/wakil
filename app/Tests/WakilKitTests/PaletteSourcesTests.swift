import Testing
import Foundation
@testable import WakilKit

// MARK: - Fakes

/// A `list_databases` / `list_tables` answer in the shape `wakil-db` publishes.
private func databasesResult(_ names: [String]) -> JSONValue {
    .object(["structuredContent": .object([
        "databases": .array(names.map { .object(["name": .string($0), "driver": .string("postgres")]) }),
    ])])
}

private func tablesResult(_ names: [String]) -> JSONValue {
    .object(["structuredContent": .object([
        "containers": .array(names.map { .object(["name": .string($0), "kind": .string("table")]) }),
    ])])
}

private func errorResult(_ text: String) -> JSONValue {
    .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
}

/// A `wakil-db` that answers `list_databases` with `databases` and `list_tables` from `tables`.
private func fakeDB(
    _ databases: [String], tables: @escaping @Sendable (String) -> JSONValue
) -> RecordingToolCaller {
    RecordingToolCaller { name, args in
        if name == "list_databases" { return databasesResult(databases) }
        guard name == "list_tables", case .object(let a) = args, case .string(let db)? = a["database"] else {
            throw SourceTestFailure("unexpected tool \(name) \(args)")
        }
        return tables(db)
    }
}

private struct SourceTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private func listTablesCalls(_ caller: RecordingToolCaller) async -> Int {
    await caller.calls.filter { $0.name == "list_tables" }.count
}

/// A source that answers `rows` once `gate` opens, or after five seconds.
private struct SlowPaletteSource: PaletteSource {
    let id = "tables"
    let group = PaletteGroup.resources
    let gate: SourceGate
    let rows: [PaletteEntry]
    func entries() async -> [PaletteEntry] {
        await gate.wait(upTo: .seconds(5))
        return rows
    }
}

private actor SourceGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
    func wait(upTo limit: Duration) async {
        if open { return }
        let timer = Task { try? await Task.sleep(for: limit); self.release() }
        await withCheckedContinuation { waiters.append($0) }
        timer.cancel()
    }
}

/// A source with fixed rows.
private struct StubPaletteSource: PaletteSource {
    let id: String
    let group: PaletteGroup
    let rows: [PaletteEntry]
    func entries() async -> [PaletteEntry] { rows }
}

private func row(_ id: String, _ group: PaletteGroup) -> PaletteEntry {
    PaletteEntry(id: id, group: group, title: id, subtitle: "", kindLabel: "x", verb: "open",
                 action: .focusPane(id: id))
}

private func gitRoot(_ name: String, _ files: [GitFileRow]) -> GitRootState {
    GitRootState(root: "/w/\(name)", name: name, branch: "main", detached: "", ahead: 0, behind: 0,
                 files: files, error: nil, loading: false)
}

// MARK: - Tests

@Suite struct PaletteSourcesTests {
    // 1
    @Test func newPaneRowsComeFromPaneKinds() async {
        let rows = newPaneEntries(kinds: Pane.kinds)
        #expect(Set(rows.map(\.id)) == Set(Pane.kinds.subtracting([Pane.settingsKind]).map { "newpane:\($0)" }))
        #expect(rows.map(\.title) == ["New Database pane", "New Terminal", "New API client", "New Editor pane", "New Browser pane"])
        let db = rows.first { $0.id == "newpane:db" }
        #expect(db?.kindLabel == "db")
        #expect(db?.group == .newPane)
        #expect(db?.action == .dispatch(action: "pane_open", params: .object(["kind": .string("db")])))

        let more = newPaneEntries(kinds: Pane.kinds.union(["notes"]))
        #expect(more.count == rows.count + 1)
        #expect(more.contains { $0.id == "newpane:notes" && $0.title == "New notes pane" })
    }

    // 2
    @Test func tablesListedPerDatabaseWithSubtitles() async {
        let db = fakeDB(["core", "events"]) { name in
            tablesResult(name == "core" ? ["bookings", "users"] : ["clicks"])
        }
        let source = TablesSource(db: db, environment: { "staging" }, cache: TableCache())
        let rows = await source.entries()

        let bookings = rows.first { $0.title == "bookings" }
        #expect(bookings?.subtitle == "core · staging")
        #expect(bookings?.kindLabel == "table")
        #expect(bookings?.group == .resources)
        #expect(bookings?.action == .dispatch(action: "db_read_table", params: .object([
            "database": .string("core"), "table": .string("bookings"),
        ])))
        #expect(rows.first { $0.title == "clicks" }?.subtitle == "events · staging")

        let core = rows.first { $0.id == "db:core" }
        #expect(core?.kindLabel == "database")
        #expect(core?.action == .drill(sourceId: "tables", value: "core"))
        #expect(rows.filter { $0.kindLabel == "database" }.count == 2)

        // The drill step's choices are that database's table rows only.
        let drilled = await source.drillEntries(commandId: "drill:tables:core")
        #expect(drilled?.map(\.title) == ["bookings", "users"])
        #expect(await source.drillEntries(commandId: "drill:other:core") == nil)
    }

    // 3
    @Test func aFailingDatabaseIsOneWholeErrorRowAndOthersStillList() async {
        let whole = "connect: dial tcp 10.0.0.4:5432: connection refused (core is unreachable)"
        let db = fakeDB(["core", "events"]) { name in
            name == "core" ? errorResult(whole) : tablesResult(["clicks"])
        }
        let rows = await TablesSource(db: db, environment: { "staging" }, cache: TableCache()).entries()
        let errors = rows.filter(\.isError)
        #expect(errors.count == 1)
        #expect(errors.first?.title == "core")
        #expect(errors.first?.subtitle.contains(whole) == true)
        #expect(rows.contains { $0.title == "clicks" && !$0.isError })
    }

    // 4
    @Test func sameTableNameInTwoDatabasesGivesTwoRowsDistinguishedBySubtitle() async {
        let db = fakeDB(["core", "archive"]) { _ in tablesResult(["bookings"]) }
        let rows = await TablesSource(db: db, environment: { "staging" }, cache: TableCache()).entries()
        let bookings = rows.filter { $0.title == "bookings" }
        #expect(bookings.count == 2)
        #expect(Set(bookings.map(\.subtitle)) == ["core · staging", "archive · staging"])
        #expect(Set(bookings.map(\.id)).count == 2)
    }

    // 5
    @Test func tableCacheHitOnReopenAndRefreshReplacesRows() async {
        let generation = ReplyGeneration()
        let db = fakeDB(["core"]) { _ in
            tablesResult(generation.value == 0 ? ["bookings"] : ["bookings", "invoices"])
        }
        let cache = TableCache()
        let source = TablesSource(db: db, environment: { "staging" }, cache: cache)
        _ = await source.entries()
        #expect(await listTablesCalls(db) == 1)
        #expect(await cache.tables(env: "staging", database: "core") == ["bookings"])

        // Reopen: the cache answers, nothing is asked.
        let again = await TablesSource(db: db, environment: { "staging" }, cache: cache).entries()
        #expect(await listTablesCalls(db) == 1)
        #expect(again.filter { $0.kindLabel == "table" }.map(\.title) == ["bookings"])

        // Refresh asks again and its answer replaces the rows.
        generation.value = 1
        let refreshed = await source.refresh()
        #expect(await listTablesCalls(db) == 2)
        #expect(refreshed.filter { $0.kindLabel == "table" }.map(\.title) == ["bookings", "invoices"])
        #expect(await cache.tables(env: "staging", database: "core") == ["bookings", "invoices"])

        // Another environment is its own cache entry.
        _ = await TablesSource(db: db, environment: { "qa" }, cache: cache).entries()
        #expect(await listTablesCalls(db) == 3)
    }

    // 6
    @Test func apiEntriesFromListApis() async {
        let http = RecordingToolCaller { name, _ in
            guard name == "list_apis" else { throw SourceTestFailure(name) }
            return .object(["structuredContent": .object(["apis": .array([
                .object(["name": .string("catalog"), "baseUrl": .string("https://c"), "authenticated": .bool(true)]),
                .object(["name": .string("payments"), "baseUrl": .string("https://p"), "authenticated": .bool(false)]),
            ])])])
        }
        let rows = await ApiEntriesSource(http: http, environment: { "staging" }).entries()
        #expect(rows.map(\.title) == ["catalog", "payments"])
        let catalog = rows[0]
        #expect(catalog.subtitle == "staging")
        #expect(catalog.kindLabel == "api")
        #expect(catalog.group == .resources)
        #expect(catalog.id == "api:catalog")
        #expect(catalog.action == .dispatch(action: "api_open", params: .object(["entry": .string("catalog")])))
    }

    @Test func noApiEntriesHidesTheGroup() async {
        let http = RecordingToolCaller(always: .object(["structuredContent": .object(["apis": .array([])])]))
        #expect(await ApiEntriesSource(http: http, environment: { "staging" }).entries().isEmpty)
    }

    // Open tabs and bookmarks (3c-iii, ruling 11)
    @Test func openTabsRowSwitchesToTheTabAndFocusesItsPane() async {
        let tab = PaletteBrowserTab(pane: "p1", tab: "t2", title: "Docs", subtitle: "example.com/docs")
        let rows = await BrowserTabsSource(tabs: { [tab] }).entries()
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.id == "browsertab:p1/t2")
        #expect(row.group == .resources)
        #expect(row.title == "Docs")
        #expect(row.subtitle == "example.com/docs")
        #expect(row.kindLabel == "tab")
        #expect(row.verb == "switch to")
        #expect(row.action == .dispatch(action: "browser_select_tab", params: .object([
            "pane": .string("p1"), "tab": .string("t2"), "focus": .bool(true),
        ])))
    }

    @Test func bookmarkRowOpensInANewTab() async {
        let mark = PaletteBookmark(url: "https://www.example.com/a", title: "Example A", subtitle: "example.com/a")
        let rows = await BookmarksSource(bookmarks: { [mark] }).entries()
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.id == "bookmark:https://www.example.com/a")
        #expect(row.group == .resources)
        #expect(row.title == "Example A")
        #expect(row.subtitle == "example.com/a")
        #expect(row.kindLabel == "bookmark")
        #expect(row.verb == "open")
        #expect(row.action == .dispatch(action: "browser_open", params: .object([
            "url": .string("https://www.example.com/a"), "newTab": .bool(true),
        ])))
    }

    @Test func noBrowserPaneGivesNoTabRows() async {
        #expect(await BrowserTabsSource(tabs: { [] }).entries().isEmpty)
        #expect(await BookmarksSource(bookmarks: { [] }).entries().isEmpty)
    }

    // 7
    @Test func changedFilesFromTheWindowsStatus() async {
        let roots = [gitRoot("walk-a", [
            GitFileRow(path: "src/booking-controller.ts", origPath: nil, group: .changed, status: "M"),
            GitFileRow(path: "notes.md", origPath: nil, group: .untracked, status: "?"),
        ])]
        let rows = await ChangedFilesSource(status: { roots }).entries()
        #expect(rows.count == 2)
        let controller = rows.first { $0.title == "booking-controller.ts" }
        #expect(controller?.subtitle == "Changes · walk-a")
        #expect(controller?.kindLabel == "git")
        #expect(controller?.group == .resources)
        // No `pane`: `editor_changes_select` picks the focused or first editor pane, or opens one.
        #expect(controller?.action == .dispatch(action: "editor_changes_select", params: .object([
            "root": .string("/w/walk-a"), "path": .string("src/booking-controller.ts"), "group": .string("changed"),
        ])))
        #expect(rows.first { $0.title == "notes.md" }?.subtitle == "Untracked · walk-a")
    }

    @Test func partlyStagedFileIsTwoRows() async {
        let roots = [gitRoot("walk-a", [
            GitFileRow(path: "a.ts", origPath: nil, group: .staged, status: "M"),
            GitFileRow(path: "a.ts", origPath: nil, group: .changed, status: "M"),
        ])]
        let rows = await ChangedFilesSource(status: { roots }).entries()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.subtitle)) == ["Staged · walk-a", "Changes · walk-a"])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test func aRootLoadingOrFailedListsNothing() async {
        var loading = gitRoot("walk-a", [GitFileRow(path: "a.ts", origPath: nil, group: .changed, status: "M")])
        loading.loading = true
        var failed = gitRoot("walk-b", [GitFileRow(path: "b.ts", origPath: nil, group: .changed, status: "M")])
        failed.error = "not a git repository"
        let roots = [loading, failed]
        #expect(await ChangedFilesSource(status: { roots }).entries().isEmpty)
    }

    // 8
    @Test func projectsAreCurrentOrganisationOnly() async {
        let source = ItemsSource.projects(organisation: { "acme" }, read: { org in
            org == "acme"
                ? ([PaletteItem(id: "project:wakil", kind: .project, title: "wakil", subtitle: "", payload: "wakil")], nil)
                : ([PaletteItem(id: "project:walk-a", kind: .project, title: "walk-a", subtitle: "", payload: "walk-a")], nil)
        })
        let rows = await source.entries()
        #expect(rows.map(\.title) == ["wakil"])
        #expect(PaletteSearch.rank(rows, query: "walk-a").isEmpty)
        #expect(rows.first?.action == .setProject("wakil"))
        #expect(rows.first?.id == "project:wakil")
        #expect(rows.first?.group == .projects)
    }

    // 9
    @Test func productionEnvironmentChoiceIsFlagged() async {
        let readers = ChoiceReaders(environments: {
            ([EnvironmentListing(name: "production", isReadOnly: false, isProduction: true),
              EnvironmentListing(name: "staging", isReadOnly: false, isProduction: false)], nil)
        })
        let rows = await choiceEntries(.environments, readers: readers)
        #expect(rows.map(\.id) == ["production", "staging"])
        #expect(rows.first { $0.id == "production" }?.isProduction == true)
        #expect(rows.first { $0.id == "staging" }?.isProduction == false)
        #expect(rows.allSatisfy { $0.group == .choices && $0.verb == "choose" })

        let kinds = await choiceEntries(.paneKinds, readers: readers)
        #expect(!kinds.contains { $0.id == Pane.settingsKind })
        #expect(kinds.first { $0.id == "db" }?.title == "Database")
    }

    // 10
    @Test func slowSourceDoesNotDelayOthers() async throws {
        let gate = SourceGate()
        let tableRow = row("table:core/bookings", .resources)
        let sources: [any PaletteSource] = [
            StubPaletteSource(id: "panes", group: .openPanes, rows: [row("pane:p1", .openPanes)]),
            SlowPaletteSource(gate: gate, rows: [tableRow]),
            StubPaletteSource(id: "projects", group: .projects, rows: [row("project:wakil", .projects)]),
        ]
        let (late, lateContinuation) = AsyncStream.makeStream(of: [PaletteEntry].self)

        // No wall-clock bound: a loaded full run took over the 2 s once kept here. The
        // rows are the proof — the gate is still shut, so a list that waited on the slow source
        // would hold its table row (after the gate's own five seconds), not "loading…".
        let rows = await openModeEntries(sources, timeout: .milliseconds(100)) { lateContinuation.yield($0) }
        #expect(rows.contains { $0.id == "pane:p1" })
        #expect(rows.contains { $0.id == "project:wakil" })
        let loading = rows.first { $0.title == "loading…" }
        #expect(loading?.group == .resources)
        #expect(loading?.isError == true)
        #expect(!rows.contains { $0.id == tableRow.id })

        await gate.release()
        // Bounded, so a source that never reports late fails here instead of hanging the suite.
        let delivered = await firstValue(of: late, within: .seconds(10))
        #expect(delivered?.contains { $0.id == tableRow.id } == true)
        #expect(delivered?.contains { $0.id == "pane:p1" } == true)
        #expect(delivered?.contains { $0.title == "loading…" } == false)
    }

    // 11
    @Test func groupsAreOrdered() async {
        let sources: [any PaletteSource] = [
            StubPaletteSource(id: "providers", group: .providers, rows: [row("provider:a", .providers)]),
            StubPaletteSource(id: "sessions", group: .sessions, rows: [row("session:a", .sessions)]),
            StubPaletteSource(id: "projects", group: .projects, rows: [row("project:a", .projects)]),
            StubPaletteSource(id: "tables", group: .resources, rows: [row("table:a", .resources)]),
            StubPaletteSource(id: "newPane", group: .newPane, rows: [row("newpane:a", .newPane)]),
            StubPaletteSource(id: "panes", group: .openPanes, rows: [row("pane:a", .openPanes)]),
        ]
        let rows = await openModeEntries(sources, timeout: .seconds(5))
        #expect(rows.map(\.group) == [.openPanes, .newPane, .resources, .projects, .sessions, .providers])
    }

    // 12
    @Test func emptyEverythingLeavesOnlyNewPaneRows() async {
        let db = fakeDB([]) { _ in tablesResult([]) }
        let http = RecordingToolCaller(always: .object(["structuredContent": .object(["apis": .array([])])]))
        let none: @Sendable () async -> (items: [PaletteItem], note: String?) = { ([], nil) }
        let sources: [any PaletteSource] = [
            OpenPanesSource(panes: { [] }),
            NewPaneSource(),
            TablesSource(db: db, environment: { "staging" }, cache: TableCache()),
            ApiEntriesSource(http: http, environment: { "staging" }),
            ChangedFilesSource(status: { [] }),
            ItemsSource.projects(organisation: { "acme" }, read: { _ in ([], nil) }),
            ItemsSource.sessions(read: none),
            ItemsSource.providers(read: none),
        ]
        let rows = await openModeEntries(sources, timeout: .seconds(5))
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.group == .newPane })
    }

    // Open panes say what they hold.
    @Test func openPanesSayWhatTheyHold() async {
        let db = Pane(id: "p1", kind: "db", title: "core", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1),
                      fetch: PaneFetch(query: .table(database: "core", name: "bookings")))
        let term = Pane(id: "p2", kind: "terminal", title: "shell",
                        frame: PaneFrame(x: 0, y: 0, width: 1, height: 1), terminalPath: "/w/walk-a")
        let editor = Pane(id: "p3", kind: "editor", title: "Editor", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
        let api = Pane(id: "p4", kind: "api", title: "api", frame: PaneFrame(x: 0, y: 0, width: 1, height: 1))
        let rows = await OpenPanesSource(panes: {
            [PaneSummary(pane: db), PaneSummary(pane: term), PaneSummary(pane: editor),
             PaneSummary(pane: api, apiEntry: "catalog")]
        }).entries()
        #expect(rows.map(\.subtitle) == ["bookings", "/w/walk-a", "", "catalog"])
        #expect(rows.first?.action == .focusPane(id: "p1"))
        #expect(rows.first?.id == "pane:p1")
        #expect(rows.first?.kindLabel == "db")
        #expect(rows.first?.verb == "open")
    }

    // A source that reports a note is not silently short.
    @Test func aReaderNoteIsAnErrorRowBesideItsItems() async {
        let rows = await ItemsSource.sessions(read: {
            ([PaletteItem(id: "session:s1", kind: .session, title: "fix", subtitle: "", payload: "s1")],
             "session_list: 1 of 2 sessions had no id")
        }).entries()
        #expect(rows.count == 2)
        #expect(rows.first?.action == .resumeSession("s1"))
        #expect(rows.last?.isError == true)
        #expect(rows.last?.subtitle == "session_list: 1 of 2 sessions had no id")
    }

    // Provider capacity: a low reading's caution reaches the row ⌘P draws, in both the
    // Providers group and the "Switch provider…" choice step.
    @Test func aProviderItemsCautionReachesItsEntry() async {
        let read: PaletteItemsReader = {
            ([PaletteItem(id: "provider:main", kind: .provider, title: "main",
                          subtitle: "account \u{00b7} 5h 12% \u{00b7} week 59%", payload: "main", caution: true),
              PaletteItem(id: "provider:alt", kind: .provider, title: "alt",
                          subtitle: "account \u{00b7} not read yet", payload: "alt")], nil)
        }
        let rows = await ItemsSource.providers(read: read).entries()
        #expect(rows.map(\.isCaution) == [true, false])
        #expect(rows.first?.subtitle == "account \u{00b7} 5h 12% \u{00b7} week 59%")
        let choices = await choiceEntries(.providers, readers: ChoiceReaders(providers: read))
        #expect(choices.map(\.isCaution) == [true, false])
    }
}

/// The stream's first value, or nil once `limit` passes.
private func firstValue<T: Sendable>(of stream: AsyncStream<T>, within limit: Duration) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A mutable flag the fake's reply closure reads.
private final class ReplyGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private func sessionRow(_ id: String, parent: String? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["id": .string(id), "firstPrompt": .string(id)]
    if let parent { fields["parent"] = .string(parent) }
    return .object(fields)
}

@Test func continueLeavesOutEveryChainALiveConversationHolds() {
    let rows = PaletteItems.sessionItems(from: [
        sessionRow("c", parent: "p"), sessionRow("p"), sessionRow("other"),
    ])
    #expect(PaletteItems.continueItems(rows, excluding: ["c"]).map(\.payload) == ["other"])
    #expect(PaletteItems.continueItems(rows, excluding: ["p"]).map(\.payload) == ["other"],
            "the child's transcript not listed yet: its parent is the chain's row")
    let lone = PaletteItems.sessionItems(from: [sessionRow("c", parent: "gone"), sessionRow("other")])
    #expect(PaletteItems.continueItems(lone, excluding: ["gone"]).map(\.payload) == ["other"])
}

// MARK: - Running (conversations 2 of 3, Task 3)

@Test func runningRowsSwitchToTheirConversationAndCarryTheirState() async {
    let staging = Place(organization: "initech", project: "api", environment: "staging")
    let prod = Place(organization: "initech", project: "api", environment: "production")
    let source = RunningConversationsSource(conversations: {
        [
            LiveConversation(id: "c-1", session: "s-1", place: staging, title: "fix the login test",
                             state: .waiting, onScreen: false, lastActivity: Date()),
            LiveConversation(id: "c-2", session: nil, place: prod, title: "New conversation",
                             state: .idle, onScreen: true, lastActivity: Date(), isProduction: true),
        ]
    })
    #expect(source.id == "running" && source.group == .running)

    let rows = await source.entries()

    #expect(rows.map(\.id) == ["running:c-1", "running:c-2"])
    #expect(rows.map(\.title) == ["fix the login test", "New conversation"])
    #expect(rows.map(\.subtitle) == ["initech · api · staging · waiting", "initech · api · production · idle"])
    #expect(rows.allSatisfy { $0.kindLabel == "conversation" && $0.verb == "switch to" && $0.group == .running })
    #expect(rows.map(\.state) == [.waiting, .idle])
    #expect(rows.map(\.isProduction) == [false, true], "production stays red (Invariant 8)")
    #expect(rows[0].action == .dispatch(action: "session_switch", params: .object(["conversation": .string("c-1")])))
}

@Test func theRunningGroupSitsAboveOpenPanes() async {
    #expect(PaletteGroup.running.rawValue == -1 && PaletteGroup.running.label == "Running")
    #expect(PaletteGroup.allCases.sorted().first == .running)
    let live = LiveConversation(id: "c", session: nil, place: Place(organization: "o", project: "p", environment: "e"),
                                title: "t", state: .working, onScreen: false, lastActivity: Date())
    let rows = await openModeEntries([
        OpenPanesSource(panes: { [PaneSummary(id: "p1", kind: "db", title: "db", holds: "")] }),
        RunningConversationsSource(conversations: { [live] }),
    ])
    #expect(rows.map(\.group) == [.running, .openPanes])
    #expect(rows.last?.state == nil, "a row that is not a conversation carries no dot")
}

// Names, Calls made 11: each Running row offers ⌘R, the name step for its conversation.
@Test func runningRowsCarryTheirRename() async {
    let place = Place(organization: "initech", project: "api", environment: "staging")
    let source = RunningConversationsSource(conversations: {
        [LiveConversation(id: "c-1", session: "s-1", place: place, title: "Mine", titleSource: .operator_,
                          fallbackTitle: "Model", state: .idle, onScreen: false, lastActivity: Date())]
    })
    let rows = await source.entries()
    #expect(rows.first?.rename == PaletteRename(
        action: "conversation_rename", params: .object(["conversation": .string("c-1")]),
        current: "Mine", fallback: "Model", placeholder: "Conversation name"))
}
