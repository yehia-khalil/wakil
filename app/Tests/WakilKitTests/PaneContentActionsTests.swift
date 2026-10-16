import Foundation
import Testing
@testable import WakilKit

private func object(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let o) = value else { return [:] }
    return o
}

/// The same construction `LayoutActionsTests.makeRegistry` uses — a real
/// ActionRegistry over a throwaway journal directory. The caller deletes
/// the directory.
private func fixture() async -> (ActionRegistry, PaneStore, LayoutStore, URL) {
    let directory = testScratchRoot
        .appendingPathComponent("pane-content-actions-\(UUID().uuidString)", isDirectory: true)
    let panes = PaneStore(kinds: PaneKinds.standard)
    let layout = LayoutStore()
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerLayoutActions(into: registry, layout: layout)
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    return (registry, panes, layout, directory)
}

/// Dispatches through the registry the way every caller does, so these
/// tests exercise the gate and the journal rather than the handler alone.
/// `environment` defaults to `"staging"` because only one test below cares
/// about `"production"`; a second dispatch helper for that one case would
/// be exactly the drift this file's other borrowed helpers are trying to
/// avoid.
private func run(
    _ registry: ActionRegistry, _ name: String, _ params: JSONValue,
    origin: ActionOrigin = .ui, environment: String = "staging"
) async throws -> JSONValue {
    try await registry.dispatch(
        name: name, params: params, origin: origin, environment: environment, confirmation: nil)
}

@Test func selectCellSetsTheAnchorAndCollapsesTheSelectionToItsRow() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.number(1), .number(2)]),
        "anchor": .number(1)]))
    _ = try await run(registry, "pane_select_cell", .object([
        "pane": .string("db"), "row": .number(9), "column": .string("name")]))
    let selection = object(object(await panes.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(9))
    #expect(selection["anchorColumn"] == .string("name"))
    // Collapsed, not extended: clicking a cell is how you START a
    // selection. Shift- and command-click go through pane_select_rows.
    #expect(selection["rows"] == .array([.number(9)]))
}

/// The three action sites that read a number through a `guard case`
/// pattern. Each asserts the number arrived, because nothing about these
/// would fail to compile if the pattern stopped matching. Inputs are
/// `.integer(…)`, not `.number(…)`: an integer arrives over the wire as
/// `.integer` now, and only a `.integer` input can catch a site reverted
/// to matching `.number` alone.
@Test func selectRowsReadsIntegerIndices() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.integer(1), .integer(3)]),
        "anchor": .integer(1)]))
    let selection = object(object(await panes.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
    #expect(selection["rows"] == .array([.number(1), .number(3)]))
}

@Test func scrollToRowReadsAnIntegerIndex() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .integer(42)]))
    #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"] == .number(42))
}

/// `LayoutStore` has no `pane(id:)` accessor — verified absent by grep
/// before writing this — so the width is read back the same way
/// `columnWidthLandsOnThePaneAndPersistsWithIt` above reads it: off
/// `layout.snapshot().panes`, which is where `setColumnWidth` actually
/// writes it. The width is passed as `.integer(180)`, not `.number(180)` —
/// `columnWidthLandsOnThePaneAndPersistsWithIt` already covers the
/// `.number` input, so this earns its name only by using the case a
/// reverted `guard case .number` would silently stop matching.
@Test func setColumnWidthReadsAnIntegerWidth() async throws {
    let (registry, _, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = await layout.open(kind: "db", title: "Results")
    _ = try await run(registry, "pane_set_column_width", .object([
        "pane": .string(pane.id), "column": .string("id"), "width": .integer(180)]))
    let stored = await layout.snapshot().panes.first { $0.id == pane.id }
    #expect(stored?.columnWidths["id"] == 180)
}

@Test func selectRowsKeepsTheAnchorInsideTheSetItNames() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_select_rows", .object([
        "pane": .string("db"), "rows": .array([.number(2), .number(3)]),
        "anchor": .number(8)]), origin: .agent)
    let selection = object(object(await panes.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
    #expect(selection["rows"] == .array([.number(2), .number(3), .number(8)]))
}

@Test func aNegativeRowIsRefused() async throws {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: LayoutActionError.self) {
        _ = try await run(
            registry, "pane_select_cell",
            .object(["pane": .string("db"), "row": .number(-1)]), origin: .agent)
    }
}

// `pane_sort`'s tests moved to `StandardActionsTests.swift` (Task 12):
// it left this file's registry entirely, moving to `StandardActions.swift`
// and changing kind from `.control` to `.read`, because sorting a result
// that is only part of what matched now reaches a database. Both tests
// that lived here are fully superseded rather than partly kept:
// `sortRecordsIntentAndClearsWhenAskedTo` asserted the old always-local
// reorder-and-clear behaviour, which `clearingASortClearsItOnThePaneToo`
// and `sortingACompleteResultOrdersItInPlaceWithNoRoundTrip` now cover
// under the new rule; `anUnknownSortDirectionIsRefusedRatherThanDefaulted`
// asserted the direction refusal, which survives unchanged and is carried
// forward as `aBadDirectionIsStillRefusedRatherThanDefaulted` — same
// assertion, new home, because the action itself now lives there.

@Test func columnWidthLandsOnThePaneAndPersistsWithIt() async throws {
    let (registry, _, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = await layout.open(kind: "db", title: "Results")
    _ = try await run(registry, "pane_set_column_width", .object([
        "pane": .string(pane.id), "column": .string("name"), "width": .number(240)]))
    let stored = await layout.snapshot().panes.first { $0.id == pane.id }
    #expect(stored?.columnWidths["name"] == 240)
}

@Test func scrollToRowIsRecordedAsATarget() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .number(4812)]), origin: .agent)
    #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"] == .number(4812))
}

@Test func scrollClearRemovesAPendingTarget() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .number(4812)]), origin: .agent)
    #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"] == .number(4812))
    _ = try await run(registry, "pane_scroll_clear", .object([
        "pane": .string("db")]), origin: .ui)
    #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"] == .null)
}

@Test func allFiveAreControlAndNameNoTargetEnvironment() async {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    // `pane_sort` moved to `StandardActions.swift` and is `.read` now
    // (Task 12), so it is deliberately not among these five.
    for name in ["pane_select_cell", "pane_select_rows",
                 "pane_set_column_width", "pane_scroll_to_row", "pane_scroll_clear"] {
        guard let action = byName[name] else {
            Issue.record("\(name) is not registered")
            continue
        }
        // .control, not .mutate: these change Wakil's own state and nothing
        // outside it, so being pointed at a production database is no
        // reason to be unable to select a row. Filed .mutate, the gate
        // would block all five in production.
        #expect(action.kind == .control, "\(name) is \(action.kind)")
    }
}

@Test func allFiveStillRunWhenPointedAtProduction() async throws {
    // Modelled on `LayoutActionsTests.noLayoutActionNamesATargetEnvironment`:
    // `.control` exists precisely so the environment never blocks these,
    // and the gate's production rule applies to `.mutate` alone. Reading
    // `action.kind` off the registry (as
    // `allFiveAreControlAndNameNoTargetEnvironment` above does) only proves
    // the declaration is right; this proves the promise the declaration
    // makes is actually kept — that being pointed at a production
    // database is no reason to be unable to select a row — by dispatching
    // each of the five with `environment: "production"` and checking the
    // effect actually landed, not merely that nothing threw. `pane_sort` no
    // longer belongs in this fixture's registry at all — it needs a
    // database, which `registerPaneContentActions` was never given — so it
    // is exercised in `StandardActionsTests.swift` instead.
    let (registry, panes, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pane = await layout.open(kind: "db", title: "Results")

    _ = try await run(
        registry, "pane_select_cell",
        .object(["pane": .string(pane.id), "row": .number(2), "column": .string("id")]),
        origin: .agent, environment: "production")
    let selection = object(object(await panes.readPane(paneId: pane.id, kind: "db"))["selection"] ?? .null)
    #expect(selection["anchorRow"] == .number(2))

    _ = try await run(
        registry, "pane_select_rows",
        .object(["pane": .string(pane.id), "rows": .array([.number(1), .number(2)])]),
        origin: .agent, environment: "production")
    let rows = object(object(await panes.readPane(paneId: pane.id, kind: "db"))["selection"] ?? .null)["rows"]
    #expect(rows == .array([.number(1), .number(2)]))

    _ = try await run(
        registry, "pane_set_column_width",
        .object(["pane": .string(pane.id), "column": .string("name"), "width": .number(180)]),
        origin: .agent, environment: "production")
    let stored = await layout.snapshot().panes.first { $0.id == pane.id }
    #expect(stored?.columnWidths["name"] == 180)

    _ = try await run(
        registry, "pane_scroll_to_row",
        .object(["pane": .string(pane.id), "row": .number(77)]),
        origin: .agent, environment: "production")
    #expect(object(await panes.readPane(paneId: pane.id, kind: "db"))["scrollTarget"] == .number(77))

    _ = try await run(
        registry, "pane_scroll_clear",
        .object(["pane": .string(pane.id)]),
        origin: .agent, environment: "production")
    #expect(object(await panes.readPane(paneId: pane.id, kind: "db"))["scrollTarget"] == .null)
}

@Test func theSameSelectionFromUiAgentAndDebugJournalsIdentically() async throws {
    // 2a's acceptance check, in its 2c form. The whole point of routing
    // every state change through the registry is that origin is the only
    // thing that distinguishes them afterwards.
    var entries: [JournalEntry] = []
    for origin in [ActionOrigin.ui, .agent, .debug] {
        let (registry, _, _, directory) = await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await run(
            registry, "pane_select_cell",
            .object(["pane": .string("db"), "row": .number(3), "column": .string("id")]),
            origin: origin)
        entries.append(try await registry.journalEntries().last!)
    }
    #expect(Set(entries.map(\.origin)) == [.ui, .agent, .debug])
    #expect(Set(entries.map(\.action)) == ["pane_select_cell"])
    // JSONValue is Equatable but not Hashable, so this compares pairwise
    // against the first entry rather than through a Set, unlike the other
    // three fields checked here.
    #expect(entries.allSatisfy { $0.params == entries[0].params })
    #expect(Set(entries.map(\.outcome)).count == 1)
}

// MARK: - Hostile row indices (final review Finding 2)
//
// These are not hypothetical inputs. `row` arrives from an agent's
// `tools/call` arguments or from a `--dispatch` script, and `Int(1e300)`
// and `Int(Double.nan)` TRAP rather than returning a wrong answer — before
// this fix `{"row": 1e300}` took the whole process down with SIGTRAP (exit
// 133). Each case below must come back as a refusal the caller can read,
// and must leave the pane untouched.

/// The values that trap on conversion, as JSON numbers. `nan` and the
/// infinities are reachable because `JSONValue.number` is a `Double` and
/// anything that built one has already done so by the time an action sees
/// it.
private let trappingNumbers: [(String, Double)] = [
    ("1e300", 1e300), ("nan", Double.nan), ("infinity", Double.infinity),
    ("-infinity", -Double.infinity),
]

/// Asserts `body` throws *something* rather than trapping, and says which
/// two shapes are legitimate.
///
/// `1e300` comes back as the handler's own `LayoutActionError.badParam`.
/// `nan` and the infinities come back as an `EncodingError` instead: the
/// handler refuses them identically, but `ActionRegistry.dispatch` journals
/// the failure before rethrowing and `JSONEncoder` cannot write a non-finite
/// `Double`, so the journal's error is what reaches the caller. Both are
/// refusals and neither is a crash, which is the property under test; the
/// journal's behaviour on non-finite numbers predates this fix and is not
/// what it is about.
private func expectRefusal(_ label: String, _ body: () async throws -> Void) async {
    await #expect(throws: (any Error).self, "\(label)") { try await body() }
}

@Test func selectCellRefusesARowIndexThatCannotBeAnIndex() async throws {
    for (label, number) in trappingNumbers {
        let (registry, panes, _, directory) = await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await expectRefusal("row: \(label)") {
            _ = try await run(registry, "pane_select_cell", .object([
                "pane": .string("db"), "row": .number(number), "column": .string("id")]))
        }
        // Nothing was written: a refused dispatch must not half-apply.
        let selection = object(object(await panes.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
        #expect(selection["anchorRow"] == .null, "row: \(label)")
    }
}

@Test func scrollToRowRefusesARowIndexThatCannotBeAnIndex() async throws {
    for (label, number) in trappingNumbers {
        let (registry, panes, _, directory) = await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await expectRefusal("row: \(label)") {
            _ = try await run(registry, "pane_scroll_to_row", .object([
                "pane": .string("db"), "row": .number(number)]))
        }
        #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"] == .null,
                "row: \(label)")
    }
}

/// The same hazard one level down, inside the array — a second conversion
/// site that had the same bare `Int(number)` in it.
@Test func selectRowsRefusesATrappingIndexInsideItsArray() async throws {
    for (label, number) in trappingNumbers {
        let (registry, panes, _, directory) = await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await expectRefusal("rows element: \(label)") {
            _ = try await run(registry, "pane_select_rows", .object([
                "pane": .string("db"),
                "rows": .array([.number(0), .number(number)])]))
        }
        let selection = object(object(await panes.readPane(paneId: "db", kind: "db"))["selection"] ?? .null)
        #expect(selection["rows"] == .array([]), "rows element: \(label)")
    }
}

/// `anchor` goes through the same guard, being a row index like any other.
@Test func selectRowsRefusesATrappingAnchor() async throws {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: LayoutActionError.self) {
        _ = try await run(registry, "pane_select_rows", .object([
            "pane": .string("db"), "rows": .array([.number(0)]),
            "anchor": .number(1e300)]))
    }
}

/// A negative index is refused by the same guard, and always was — pinned
/// here so the magnitude check cannot be "simplified" into dropping it.
@Test func aNegativeRowIndexIsStillRefused() async throws {
    let (registry, _, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: LayoutActionError.self) {
        _ = try await run(registry, "pane_select_cell", .object([
            "pane": .string("db"), "row": .number(-1)]))
    }
}

/// The largest index that IS exactly representable still works, so the
/// guard refuses what cannot be an index rather than capping what can.
@Test func aLargeButRepresentableRowIndexIsStillAccepted() async throws {
    let (registry, panes, _, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await run(registry, "pane_scroll_to_row", .object([
        "pane": .string("db"), "row": .number(999_999_999_999_998)]))
    #expect(object(await panes.readPane(paneId: "db", kind: "db"))["scrollTarget"]
        == .number(999_999_999_999_998))
}

// MARK: - An index is a position, and the schema has to say zero-based
//
// Acceptance check 4, second walk. Asked to "select rows 1,2,3", the agent
// sent `[1,2,3]` and explained itself as "indices 1, 2, 3 (0-indexed,
// meaning the 2nd, 3rd, and 4th rows shown)" — neither the ids 1,2,3 nor
// the top three rows. It was guessing, and said so, because the
// description said only "into the order currently displayed" and never
// said where that order starts counting. Three readings of one sentence,
// and nothing in the tool surface to rule any of them out.
//
// The ids-versus-positions ambiguity belongs to the operator's sentence
// and no schema can settle it; where the counting starts is the tool's own
// business, and it now says.
// MARK: - The five refuse a pane that is not a grid, by name (Task 5)

/// A terminal pane is not a grid: `row` would have no order to be a
/// position in, so all five refuse rather than silently writing a
/// selection and a scroll target nowhere anything draws.
@Test func theFiveGridActionsRefuseATerminalPaneAndNameItsKind() async throws {
    let (registry, _, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let terminal = await layout.open(kind: "terminal", title: "~/orca")

    for (action, params) in [
        ("pane_select_cell", JSONValue.object(["pane": .string(terminal.id), "row": .number(0)])),
        ("pane_select_rows", .object(["pane": .string(terminal.id), "rows": .array([.number(0)])])),
        ("pane_set_column_width", .object(["pane": .string(terminal.id),
                                           "column": .string("id"), "width": .number(80)])),
        ("pane_scroll_to_row", .object(["pane": .string(terminal.id), "row": .number(0)])),
        ("pane_scroll_clear", .object(["pane": .string(terminal.id)])),
    ] {
        await #expect(throws: PaneContentActionError.self) {
            _ = try await run(registry, action, params, origin: .agent)
        }
        // The refusal names the KIND, so the agent learns which tool to
        // reach for rather than only that this one failed.
        do {
            _ = try await run(registry, action, params, origin: .agent)
            Issue.record("\(action) did not throw for a terminal pane")
        } catch let error as PaneContentActionError {
            #expect("\(error)".contains("terminal"), "\(action): \(error)")
            #expect("\(error)".contains(action), "\(action): \(error)")
        }
    }
}

/// The second half is load-bearing: `--dispatch` and ~30 existing test
/// call sites register these actions against a `LayoutStore` holding
/// nothing, and inventing a refusal there would break every one of them.
@Test func aGridPaneIsUnaffectedAndAPaneTheLayoutDoesNotHoldStillWorks() async throws {
    let (registry, panes, layout, directory) = await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = await layout.open(kind: "db", title: "customers")

    _ = try await run(
        registry, "pane_select_cell",
        .object(["pane": .string(db.id), "row": .number(2)]), origin: .agent)
    _ = try await run(
        registry, "pane_select_cell",
        .object(["pane": .string("not-on-the-canvas"), "row": .number(2)]), origin: .agent)

    #expect(await panes.snapshot(paneId: db.id, kind: "db").contents != nil)
}

@Test func rowIndexActionsSayTheyAreZeroBasedPositions() async throws {
    let directory = testScratchRoot
        .appendingPathComponent("row-index-docs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ActionRegistry(journalDirectory: directory, sessionId: "s")
    await registerPaneContentActions(into: registry, panes: PaneStore(), layout: LayoutStore())

    for name in ["pane_select_cell", "pane_select_rows", "pane_scroll_to_row"] {
        let action = try #require(await registry.all().first { $0.name == name })
        #expect(
            action.description.contains("ZERO-BASED"),
            "\(name) does not say where its row indices start counting")
    }

    // And the two selection actions say the stronger thing: an index is a
    // position in what is on screen, never a value in the data.
    for name in ["pane_select_cell", "pane_select_rows"] {
        let action = try #require(await registry.all().first { $0.name == name })
        #expect(
            action.description.contains("never"),
            "\(name) does not rule out reading an index as an id")
    }
}
