import Testing
import Foundation
@testable import WakilKit

/// Three ⌘P rows: an open pane, a new-pane row and a project.
private let openRows: [PaletteEntry] = [
    PaletteEntry(id: "pane:git-1", group: .openPanes, title: "Git", subtitle: "walk-a", kindLabel: "pane",
                 verb: "open", action: .focusPane(id: "git-1")),
    PaletteEntry(id: "new:db", group: .newPane, title: "Database", subtitle: "", kindLabel: "pane",
                 verb: "open", action: .dispatch(action: "pane_open", params: .object(["kind": .string("db")]))),
    PaletteEntry(id: "project:wakil", group: .projects, title: "wakil", subtitle: "", kindLabel: "project",
                 verb: "switch to", action: .setProject("wakil")),
]

private let dbContext = PaletteContext(
    focusedPane: FocusedPane(id: "db-1", kind: "db"), dbPageHasNext: true, hasEnvironments: true,
    projectCount: 2, providerCount: 2)

/// The catalog's ⌘K rows over a focused Database pane with a next page.
private let commandRows = CommandCatalog.entries(for: dbContext)

private func choice(_ value: String) -> PaletteEntry {
    PaletteEntry(id: value, group: .choices, title: value, subtitle: "", kindLabel: "environment",
                 verb: "choose", action: .setProject(value), isProduction: value == "production")
}

private func cmdP() -> PaletteModel {
    var m = PaletteModel(mode: .open)
    m.rootEntries = openRows
    return m
}

private func cmdK(_ rows: [PaletteEntry] = commandRows) -> PaletteModel {
    var m = PaletteModel(mode: .commands)
    m.rootEntries = rows
    return m
}

/// Moves the selection onto the row titled `title`.
private func select(_ m: inout PaletteModel, _ title: String) {
    let i = try! #require(m.results.firstIndex { $0.title == title })
    m.move(i - m.selection)
}

/// ⌘K at "Switch environment…" with its three choices filled.
private func environmentStep() -> PaletteModel {
    var m = cmdK()
    m.type("environment")
    _ = m.confirm()
    m.provideChoices(["local", "staging", "production"].map(choice), for: "global.env")
    return m
}

/// ⌘K over an API pane, inside "Fill from cURL…".
private func curlStep() -> PaletteModel {
    var ctx = dbContext
    ctx.focusedPane = FocusedPane(id: "api-1", kind: "api")
    var m = cmdK(CommandCatalog.entries(for: ctx))
    m.type("curl")
    _ = m.confirm()
    return m
}

// 1
@Test func cmdPOpensInOpenMode() {
    let m = cmdP()
    #expect(m.mode == .open)
    #expect(m.query == "")
    #expect(m.results == openRows)
    #expect(m.placeholder == "open or switch to…")
}

@Test func cmdKOpensInCommandsMode() {
    let m = cmdK()
    #expect(m.mode == .commands)
    #expect(m.results.map(\.id).prefix(3) == ["db.refetch", "db.next", "db.close"])
    #expect(m.placeholder == "run an action…")
}

// 2
@Test func modeKeyWhileOpenSwitchesModeAndKeepsQueryMinusChevron() {
    var m = cmdP()
    m.type(">ref")
    #expect(m.mode == .commands)
    #expect(m.query == "ref")
    m.modeKey(.open)
    #expect(m.mode == .open)
    #expect(m.query == "ref")
    #expect(m.line == "ref")
    m.modeKey(.commands)
    #expect(m.mode == .commands)
    #expect(m.query == "ref")
}

// 3
@Test func leadingChevronSwitchesToCommands() {
    var m = cmdP()
    m.type(">")
    #expect(m.mode == .commands)
    #expect(m.query == "")
    #expect(m.line == ">")
}

@Test func deletingTheChevronSwitchesBack() {
    var m = cmdP()
    m.type(">")
    m.type("")
    #expect(m.mode == .open)
    #expect(m.query == "")
    // Deleting only the `>` (caret at the start) keeps the rest as an open-mode query.
    m.type(">git")
    m.type("git")
    #expect(m.mode == .open)
    #expect(m.query == "git")
}

@Test func chevronMidQueryIsLiteral() {
    var m = cmdP()
    m.type("ab>c")
    #expect(m.mode == .open)
    #expect(m.query == "ab>c")
}

@Test func pastedChevronQuerySwitchesAndSearches() {
    var m = cmdP()
    m.rootEntries = openRows
    m.type(">run query")
    #expect(m.mode == .commands)
    m.rootEntries = commandRows  // the caller swaps lists on a mode change
    #expect(m.results.first?.title == "Run query again")
}

@Test func chevronInCmdKIsLiteral() {
    var m = cmdK()
    m.type(">ref")
    #expect(m.mode == .commands)
    #expect(m.query == ">ref")
    m.type("")
    #expect(m.mode == .commands)
}

// 4
@Test func moveWrapsBothWays() {
    var m = cmdP()
    #expect(m.selection == 0)
    m.move(-1)
    #expect(m.selection == openRows.count - 1)
    m.move(1)
    #expect(m.selection == 0)
}

// 5
@Test func selectionResetsOnQueryChange() {
    var m = cmdK()
    m.move(2)
    #expect(m.selection == 2)
    m.type("s")
    #expect(m.selection == 0)
}

@Test func selectionFollowsSameIdAcrossContextChange() {
    var m = cmdK()
    select(&m, "Open settings")
    var ctx = dbContext
    ctx.hasEnvironments = false  // a row above the selection goes
    m.contextChanged(rootEntries: CommandCatalog.entries(for: ctx))
    #expect(m.selected?.title == "Open settings")
}

// 6
@Test func focusedPaneClosingWhileOpenDropsItsCommands() {
    var m = cmdK()
    m.move(1)  // Next page
    var ctx = dbContext
    ctx.focusedPane = nil
    let globals = CommandCatalog.entries(for: ctx)
    m.contextChanged(rootEntries: globals)
    #expect(m.selection == 1)
    #expect(m.selected?.id == globals[1].id)
    for i in 0..<m.results.count {
        var n = m
        n.move(i - n.selection)
        if case .run(.dispatch(let action, _), _) = n.confirm() {
            #expect(!action.hasPrefix("db_"))
        }
    }
    #expect(!m.results.contains { $0.id.hasPrefix("db.") })
}

@Test func paneClosingUnderItsStepDropsTheStep() {
    var m = curlStep()
    m.type("curl x")
    m.contextChanged(rootEntries: CommandCatalog.entries(for: PaletteContext()))
    #expect(m.steps.isEmpty)
    #expect(m.confirm().map { if case .runCommand = $0 { true } else { false } } != true)
}

// 7
@Test func confirmOnPlainCommandRunsOnce() {
    var m = cmdK()
    let effect = m.confirm()
    #expect(effect == .run(.dispatch(action: "db_refetch", params: .object(["pane": .string("db-1")]))))
    #expect(m.inFlight == ["db.refetch"])
}

@Test func doubleConfirmRunsOnce() {
    var m = cmdK()
    #expect(m.confirm() != nil)
    #expect(m.confirm() == nil)
    m.runFinished(entryId: "db.refetch", error: nil)
    #expect(m.inFlight.isEmpty)
    #expect(m.confirm() != nil)
}

// 8
@Test func confirmOnInputCommandPushesStep() {
    var m = cmdK()
    m.type("environment")
    #expect(m.confirm() == .needChoices(commandId: "global.env"))
    #expect(m.steps.count == 1)
    #expect(m.placeholder == "Environment")
    #expect(m.query == "")
    #expect(m.steps[0].isText == false)
}

// 9
@Test func choiceStepFiltersAndConfirms() {
    var m = environmentStep()
    #expect(m.results.map(\.title) == ["local", "staging", "production"])
    m.type("sta")
    #expect(m.results.map(\.title) == ["staging"])
    #expect(m.confirm() == .runCommand(commandId: "global.env", value: "staging"))
    #expect(m.inFlight.contains("global.env"))
    #expect(m.confirm() == nil)
}

// 10
@Test func choiceStepNoMatchShowsNoResultsAndConfirmDoesNothing() {
    var m = environmentStep()
    m.type("qa")
    #expect(m.results.count == 1)
    #expect(m.results[0].title == "No results for 'qa'")
    #expect(m.results[0].isError)
    #expect(m.confirm() == nil)
    #expect(m.inFlight.isEmpty)
}

// 11
@Test func textStepConfirmsTypedText() {
    var m = curlStep()
    #expect(m.steps[0].isText)
    #expect(m.placeholder == "cURL command")
    m.type("curl https://x")
    #expect(m.confirm() == .runCommand(commandId: "api.curl", value: "curl https://x"))
    #expect(m.recents["api.curl"] == ["curl https://x"])
}

@Test func emptyTextStepConfirmDoesNothing() {
    var m = curlStep()
    #expect(m.results.isEmpty)
    #expect(m.confirm() == nil)
    m.type("   ")
    #expect(m.confirm() == nil)
    #expect(m.inFlight.isEmpty)
}

@Test func recentsAppearAboveAndFilter() {
    var m = curlStep()
    m.recents["api.curl"] = ["curl https://b", "curl https://a"]
    #expect(m.results.map(\.title) == ["curl https://b", "curl https://a"])
    m.type("curl https://a")
    // The recent equal to the line is the line itself; the line row sits last and is selected.
    #expect(m.results.map(\.title) == ["curl https://a"])
    m.type("curl")
    #expect(m.results.map(\.title) == ["curl https://b", "curl https://a", "curl"])
    #expect(m.selected?.title == "curl")
    #expect(m.footerVerb == "run")
    m.type("https://b")
    #expect(m.results.map(\.title) == ["curl https://b", "https://b"])
}

@Test func choosingARecentFillsTheLineThenConfirmRuns() {
    var m = curlStep()
    m.recents["api.curl"] = ["curl https://b", "curl https://a"]
    m.move(1)
    #expect(m.footerVerb == "choose")
    #expect(m.confirm() == nil)
    #expect(m.query == "curl https://a")
    #expect(m.confirm() == .runCommand(commandId: "api.curl", value: "curl https://a"))
    #expect(m.recents["api.curl"] == ["curl https://a", "curl https://b"])
}

@Test func recentsAreCappedAtTen() {
    var m = curlStep()
    for i in 0..<12 {
        m.type("c\(i)")
        _ = m.confirm()
        m.runFinished(entryId: "api.curl", error: "x")
    }
    #expect(m.recents["api.curl"]?.count == 10)
    #expect(m.recents["api.curl"]?.first == "c11")
}

// 12
@Test func escapePopsOneStepAndRestoresParentQueryAndSelection() {
    var m = cmdK()
    m.type("switch")
    select(&m, "Switch provider…")
    let sel = m.selection
    _ = m.confirm()
    m.type("open")
    #expect(m.escape() == nil)
    #expect(m.steps.isEmpty)
    #expect(m.query == "switch")
    #expect(m.selection == sel)
}

@Test func escapeAtRootCloses() {
    var m = cmdP()
    #expect(m.escape() == .close)
}

@Test func escapeFromTwoLevelsNeedsTwoPopsBeforeClose() {
    var m = environmentStep()
    m.provideChoices([PaletteEntry(id: "core", group: .choices, title: "core db", subtitle: "", kindLabel: "database",
                                   verb: "choose", action: .pushStep(commandId: "global.newpane"))],
                     for: "global.env")
    #expect(m.confirm() == .needChoices(commandId: "global.newpane"))
    #expect(m.steps.count == 2)
    #expect(m.escape() == nil)
    #expect(m.escape() == nil)
    #expect(m.escape() == .close)
}

// 13
@Test func failedRunKeepsPaletteOpenWithWholeErrorAndInput() {
    var m = environmentStep()
    m.type("sta")
    _ = m.confirm()
    let whole = "pane_open: kind must be one of db, terminal, api, editor"
    m.runFinished(entryId: "global.env", error: whole)
    #expect(m.error == whole)
    #expect(m.steps.count == 1)
    #expect(m.query == "sta")
    #expect(m.inFlight.isEmpty)
    m.type("stag")
    #expect(m.error == nil)
}

// 14
@Test func noResultsRowWhenQueryMatchesNothing() {
    var m = cmdP()
    m.type("zzz")
    #expect(m.results.count == 1)
    #expect(m.results[0].title == "No results for 'zzz'")
    #expect(m.results[0].isError)
    #expect(m.confirm() == nil)
}

@Test func errorRowIsNeverRunnable() {
    var m = cmdP()
    m.rootEntries = [PaletteEntry(id: "err", group: .resources, title: "core db: connection refused",
                                  subtitle: "", kindLabel: "database", verb: "open",
                                  action: .focusPane(id: "x"), isError: true)]
    #expect(m.confirm() == nil)
}

// 15
@Test func emptyRootShowsNothingButNoResultsOnlyWhenQueryNonEmpty() {
    var m = PaletteModel(mode: .open)
    #expect(m.results.isEmpty)
    #expect(m.confirm() == nil)
    m.move(1)
    #expect(m.selection == 0)
    m.type("x")
    #expect(m.results.map(\.title) == ["No results for 'x'"])
}

// 16
@Test func footerVerbFollowsSelection() {
    var m = cmdP()
    #expect(m.footerVerb == "open")
    select(&m, "wakil")
    #expect(m.footerVerb == "switch to")
    var k = cmdK()
    #expect(k.footerVerb == "run")
    select(&k, "Switch environment…")
    #expect(k.footerVerb == "choose")
}

// 17
@Test func freshModelAlwaysStartsAtRoot() {
    var m = environmentStep()
    m.type("sta")
    m = PaletteModel(mode: .commands)
    #expect(m.steps.isEmpty)
    #expect(m.query == "")
    #expect(m.selection == 0)
    #expect(m.error == nil)
    #expect(m.inFlight.isEmpty)
}

// 18
@Test func allSpaceQueryIsEmpty() {
    var m = cmdP()
    m.type("   ")
    #expect(m.results == openRows)
}

// Fix round 1

private let dbRow = PaletteEntry(id: "database:core:staging", group: .resources, title: "core db",
                                 subtitle: "staging", kindLabel: "database", verb: "open",
                                 action: .drill(sourceId: "tables", value: "core"))

private func table(_ name: String) -> PaletteEntry {
    PaletteEntry(id: "table:core:\(name)", group: .resources, title: name, subtitle: "table · core db",
                 kindLabel: "table", verb: "open",
                 action: .dispatch(action: "db_read_table", params: .object(["table": .string(name)])))
}

/// ⌘P inside the core database's tables.
private func drillStep() -> PaletteModel {
    var m = cmdP()
    m.rootEntries = openRows + [dbRow]
    m.type("core")
    #expect(m.confirm() == .needChoices(commandId: "drill:tables:core"))
    m.provideChoices(["bookings", "users", "payments"].map(table), for: "drill:tables:core")
    return m
}

@Test func drillPushesAStep() {
    let m = drillStep()
    #expect(m.steps.count == 1)
    #expect(m.steps[0].isDrill)
    #expect(m.placeholder == "core")
    #expect(m.query == "")
    #expect(m.results.map(\.title) == ["bookings", "users", "payments"])
}

@Test func drillStepFilters() {
    var m = drillStep()
    m.type("pay")
    #expect(m.results.map(\.title) == ["payments"])
}

@Test func confirmInDrillRunsTheRowsOwnAction() {
    var m = drillStep()
    m.type("users")
    // The run names its step, so the window can check it against the context the step's rows
    // were read in.
    #expect(m.confirm() == .run(.dispatch(action: "db_read_table", params: .object(["table": .string("users")])),
                                step: "drill:tables:core"))
    #expect(m.inFlight == ["table:core:users"])
    #expect(m.confirm() == nil)
}

@Test func refreshKeepsTheDrillStep() {
    var m = drillStep()
    m.type("pay")
    m.contextChanged(rootEntries: openRows + [dbRow])
    #expect(m.steps.count == 1)
    #expect(m.query == "pay")
}

@Test func escapePopsTheDrillStep() {
    var m = drillStep()
    #expect(m.escape() == nil)
    #expect(m.steps.isEmpty)
    #expect(m.query == "core")
    #expect(m.selected?.id == dbRow.id)
}

@Test func popResolvesTheParentRowAgainstCurrentResults() {
    var m = drillStep()
    // A row above the database arrives while in the step; Esc lands on the database, not the old index.
    let newRow = PaletteEntry(id: "pane:core-2", group: .openPanes, title: "core db", subtitle: "",
                              kindLabel: "pane", verb: "open", action: .focusPane(id: "core-2"))
    m.contextChanged(rootEntries: [newRow] + openRows + [dbRow])
    _ = m.escape()
    #expect(m.selected?.id == dbRow.id)
}

@Test func modeKeyInsideAStepIsIgnored() {
    var m = environmentStep()
    m.type("sta")
    m.modeKey(.open)
    #expect(m.mode == .commands)
    #expect(m.steps.count == 1)
    #expect(m.query == "sta")
}

@Test func aSuccessfulRunDoesNotClearAnotherRunsError() {
    var m = cmdK()
    _ = m.confirm()  // db.refetch
    m.move(1)
    _ = m.confirm()  // db.next
    m.runFinished(entryId: "db.refetch", error: "db: no such table")
    m.runFinished(entryId: "db.next", error: nil)
    #expect(m.error == "db: no such table")
}

@Test func choosingARecentWorksWhileARunIsInFlight() {
    var m = curlStep()
    m.type("curl https://a")
    _ = m.confirm()  // in flight
    m.type("")
    #expect(m.results.map(\.title) == ["curl https://a"])
    #expect(m.confirm() == nil)
    #expect(m.query == "curl https://a")  // filled despite the run in flight
    #expect(m.confirm() == nil)           // but it does not run twice
}

@Test func prefixedSourceIdsNeverShareInFlightWithCatalogIds() {
    var m = cmdK(commandRows + [PaletteEntry(id: "pane:db.refetch", group: .openPanes, title: "Database pane",
                                             subtitle: "", kindLabel: "pane", verb: "open",
                                             action: .focusPane(id: "db-1"))])
    #expect(m.confirm() == .run(.dispatch(action: "db_refetch", params: .object(["pane": .string("db-1")]))))
    select(&m, "Database pane")
    #expect(m.confirm() == .run(.focusPane(id: "db-1")))
    #expect(m.inFlight == ["db.refetch", "pane:db.refetch"])
}

// MARK: - Rule 5: the row that is running shows it

@Test func aRootRowRunningIsMarkedUntilItFinishes() {
    var m = cmdK()
    let first = m.results[0]
    #expect(!m.isRunning(first))
    _ = m.confirm()
    #expect(m.isRunning(first))
    #expect(m.results.dropFirst().allSatisfy { !m.isRunning($0) })
    m.runFinished(entryId: first.id, error: nil)
    #expect(!m.isRunning(first))
}

@Test func aChoiceStepMarksTheChosenRowAndTheCommandAtTheRoot() {
    var m = environmentStep()
    select(&m, "staging")
    #expect(m.confirm() == .runCommand(commandId: "global.env", value: "staging"))
    #expect(m.isRunning(m.selected!))
    #expect(m.results.filter { m.isRunning($0) }.map(\.id) == ["staging"])
    _ = m.escape()
    #expect(m.results.filter { m.isRunning($0) }.map(\.id) == ["global.env"])
}

@Test func aTextStepMarksItsLineRow() {
    var m = curlStep()
    m.type("curl https://x")
    _ = m.confirm()
    let line = m.results.last!
    #expect(m.isRunning(line))
    m.recents["api.curl"] = ["curl https://y"]
    #expect(m.results.filter { m.isRunning($0) }.map(\.id) == [line.id])
}

@Test func aDrillRowRunningIsMarkedByItsOwnId() {
    var m = cmdP()
    m.rootEntries = [PaletteEntry(id: "database:core", group: .resources, title: "core", subtitle: "", kindLabel: "database",
                                  verb: "open", action: .drill(sourceId: "tables", value: "core"))]
    _ = m.confirm()
    let table = PaletteEntry(id: "table:core/bookings", group: .choices, title: "bookings", subtitle: "",
                             kindLabel: "table", verb: "open", action: .focusPane(id: "x"))
    m.provideChoices([table], for: "drill:tables:core")
    _ = m.confirm()
    #expect(m.isRunning(table))
    #expect(!m.isRunning(m.rootEntries[0]))
}

// MARK: - A mode switch: the old mode's rows never run while the new list loads

@Test func aModeKeyLeavesTheOldRowsStaleUntilTheNewListLands() {
    var m = cmdP()
    #expect(!m.rootStale)
    m.modeKey(.commands)
    #expect(m.rootStale)
    #expect(m.selected != nil)                 // still drawn, so nothing flashes
    #expect(m.confirm() == nil)                // but Return runs none of them
    #expect(m.inFlight.isEmpty)
    #expect(m.footerVerb == "")
    m.contextChanged(rootEntries: commandRows)
    #expect(!m.rootStale)
    #expect(m.confirm() != nil)
}

@Test func theChevronSwitchIsStaleBothWays() {
    var m = cmdP()
    m.type(">")
    #expect(m.rootStale)
    m.rootEntries = commandRows
    #expect(!m.rootStale)
    m.type("")
    #expect(m.rootStale)
    #expect(m.confirm() == nil)
}

@Test func aSameModeKeyIsNotStale() {
    var m = cmdP()
    m.modeKey(.open)
    #expect(!m.rootStale)
    #expect(m.confirm() != nil)
}

// Final fix wave, item 2 (rule 2): typed input is never thrown away. A text step's line that was
// not run becomes a recent when the step is popped, when the palette closes, and when the step
// is dropped because its command left the list.
@Test func anAbandonedTextLineBecomesARecent() {
    var popped = curlStep()
    popped.type("  curl https://popped  ")
    #expect(popped.escape() == nil)
    #expect(popped.recents["api.curl"] == ["curl https://popped"])

    var closed = curlStep()
    closed.recents["api.curl"] = ["curl https://older"]
    closed.type("curl https://closed")
    closed.closing()
    #expect(closed.recents["api.curl"] == ["curl https://closed", "curl https://older"])

    var dropped = curlStep()
    dropped.type("curl https://dropped")
    dropped.contextChanged(rootEntries: commandRows)   // the API pane closed: Fill from cURL… left
    #expect(dropped.steps.isEmpty)
    #expect(dropped.recents["api.curl"] == ["curl https://dropped"])
}

@Test func anEmptyOrChoiceStepLeavesNoRecent() {
    var empty = curlStep()
    empty.type("   ")
    empty.closing()
    #expect(empty.recents.isEmpty)

    var choice = environmentStep()
    choice.type("stag")
    _ = choice.escape()
    choice.closing()
    #expect(choice.recents.isEmpty)
}

// MARK: - The name step (names, Calls made 10 and 11)

private let conversationRename = PaletteRename(
    action: "conversation_rename", params: .object(["conversation": .string("c1")]),
    current: "Old", fallback: "Model", placeholder: "Conversation name")

private let runningRow = PaletteEntry(
    id: "conversation:c1", group: .running, title: "Old", subtitle: "wakil", kindLabel: "conversation",
    verb: "switch to", action: .focusPane(id: "agent-1"), state: .idle, rename: conversationRename)

/// ⌘P with a Running row (which offers a rename) above the open-pane rows.
private func withRunning() -> PaletteModel {
    var m = PaletteModel(mode: .open)
    m.rootEntries = [runningRow] + openRows
    return m
}

/// The name step for `conversationRename`, pushed by Return on a row whose action is `.pushName`.
private func nameStep() -> PaletteModel {
    var m = cmdK([PaletteEntry(id: "global.renameConversation", group: .commands, title: "Rename Conversation…",
                               subtitle: "", kindLabel: "command", verb: "choose",
                               action: .pushName(conversationRename))])
    #expect(m.confirm() == nil)
    return m
}

private let runMine = PaletteEffect.runName(
    action: "conversation_rename", params: .object(["conversation": .string("c1")]), name: "Mine")

@Test func aNameStepArrivesFilledAndSelected() {
    let m = nameStep()
    let step = try! #require(m.steps.last)
    #expect(step.isName)
    #expect(step.rename == conversationRename)
    #expect(step.selectAllOnShow)
    #expect(m.query == "Old")
    #expect(m.placeholder == "Conversation name")
    #expect(!m.steps.contains { $0.isText })
}

@Test func itsOneRowSaysWhatReturnDoes() {
    var m = nameStep()
    m.type("Mine")
    #expect(m.results.map(\.title) == ["Rename to “Mine”"])
    #expect(m.results.first?.id == "name")
    #expect(m.footerVerb == "run")
    m.type("")
    #expect(m.results.map(\.title) == ["Clear name — back to “Model”"])
    #expect(m.footerVerb == "run")
    m.type("Old")
    #expect(m.results.map(\.title) == ["Keep “Old”"])
    #expect(m.footerVerb == "keep")
}

@Test func returnRunsAChangedName() {
    var m = nameStep()
    m.type("  Mine ")
    #expect(m.confirm() == runMine)
    #expect(m.isRunning(m.results[0]))
    // Rule 5: a second Return while it runs fires nothing.
    #expect(m.confirm() == nil)
}

@Test func anEmptyLineRunsAClear() {
    var m = nameStep()
    m.type("   ")
    #expect(m.confirm() == .runName(action: "conversation_rename",
                                    params: .object(["conversation": .string("c1")]), name: ""))
}

@Test func returnOnKeepClosesAndRunsNothing() {
    var m = nameStep()
    #expect(m.confirm() == .close)
    #expect(m.inFlight.isEmpty)
    #expect(m.closing() == nil)
}

@Test func escapeCancels() {
    var m = nameStep()
    m.type("Mine")
    #expect(m.escape() == nil)
    #expect(m.steps.isEmpty)
    #expect(m.closing() == nil)
}

@Test func closingKeepsAChangedName() {
    var m = nameStep()
    m.type("Mine")
    #expect(m.closing() == runMine)
    // A second close never runs it again.
    #expect(m.closing() == nil)
}

@Test func closingAfterTheRunDoesNotRunAgain() {
    // Review focus 3: confirm ran it; the palette closes on its success — one dispatch, not two.
    var m = nameStep()
    m.type("Mine")
    #expect(m.confirm() == runMine)
    #expect(m.closing() == nil)   // in flight

    var done = nameStep()
    done.type("Mine")
    #expect(done.confirm() == runMine)
    done.runFinished(entryId: done.steps.last!.commandId, error: nil)
    #expect(done.closing() == nil)   // ran and finished

    // A failed run stays; a line typed after it is a new name, and closing keeps that one.
    var failed = nameStep()
    failed.type("Mine")
    #expect(failed.confirm() == runMine)
    failed.runFinished(entryId: failed.steps.last!.commandId, error: "conversation_rename: no live conversation c1")
    #expect(failed.closing() == nil)
    failed.type("Yours")
    #expect(failed.closing() == .runName(action: "conversation_rename",
                                         params: .object(["conversation": .string("c1")]), name: "Yours"))
}

@Test func cmdROnARunningRowPushesItsRename() {
    var m = withRunning()
    #expect(m.selected?.id == "conversation:c1")
    #expect(m.footerHints == ["⌘R rename"])
    #expect(m.renameSelected() == nil)
    #expect(m.steps.last?.rename == conversationRename)
    #expect(m.query == "Old")
    #expect(m.footerHints.isEmpty)
    _ = m.escape()
    #expect(m.selected?.id == "conversation:c1")   // back where the operator was (rule 6)

    m.move(1)   // an open pane: no rename
    #expect(m.footerHints.isEmpty)
    #expect(m.renameSelected() == nil)
    #expect(m.steps.isEmpty)
}

@Test func aNameStepSurvivesAContextChange() {
    var m = withRunning()
    _ = m.renameSelected()
    m.type("Mine")
    m.contextChanged(rootEntries: openRows)
    #expect(m.steps.last?.isName == true)
    #expect(m.query == "Mine")
}

@Test func aNameStepKeepsNoRecents() {
    var m = nameStep()
    m.type("Mine")
    _ = m.escape()
    var n = nameStep()
    n.type("Mine")
    _ = n.closing()
    #expect(m.recents.isEmpty)
    #expect(n.recents.isEmpty)
    #expect(n.results.count == 1)
}

@Test func returnRunsAFailedNameAgain() {
    var m = nameStep()
    m.type("Mine")
    #expect(m.confirm() == runMine)
    m.runFinished(entryId: m.steps.last!.commandId, error: "refused")
    #expect(m.confirm() == runMine)
}

// MARK: - Opened on the name step (names, Calls made 12)

/// A chip's Rename… opens ⌘P on the name step: Esc closes the palette straight back (Rule 6), with
/// nothing run on the close — Esc cancels, not keeps.
@Test func aPaletteOpenedOnTheNameStepClosesOnEsc() {
    var m = PaletteModel(mode: .open)
    m.openOnName(conversationRename)
    let step = try! #require(m.steps.last)
    #expect(step.isName && step.selectAllOnShow)
    #expect(m.query == "Old")
    m.type("Mine")
    #expect(m.escape() == .close)
    #expect(m.steps.isEmpty)
    #expect(m.closing() == nil)
}

/// Opened on the step, the close still keeps a changed name (Rule 2), and Return runs it once.
@Test func aPaletteOpenedOnTheNameStepKeepsOnCloseAndRunsOnce() {
    var m = PaletteModel(mode: .open)
    m.openOnName(conversationRename)
    m.type("Mine")
    #expect(m.closing() == runMine)

    var n = PaletteModel(mode: .open)
    n.openOnName(conversationRename)
    n.type("Mine")
    #expect(n.confirm() == runMine)
    n.runFinished(entryId: n.steps.last!.commandId, error: nil)
    #expect(n.closing() == nil)
}

/// A name step pushed from a row (⌘K's Rename Conversation…, ⌘R) still drops back to the list.
@Test func aPushedNameStepEscapesToTheList() {
    var m = nameStep()
    #expect(m.escape() == nil)
    #expect(m.steps.isEmpty)
}
