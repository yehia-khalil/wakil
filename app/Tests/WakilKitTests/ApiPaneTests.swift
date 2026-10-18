import Foundation
import Testing
@testable import WakilKit

/// `api_open` and `read_pane`'s third arm (#188) — the first tracer
/// bullet through the window for the API client pane: a pane opens, draws,
/// and reads back honestly, with no request built, nothing bound and
/// nothing sent.

private func scratch() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `list_apis`' reply, in the shape `wakil-http` actually answers with —
/// `structuredContent` wrapping an `apis` array, each entry carrying the
/// three keys that tool publishes.
private func listApisReply(_ entries: [(String, String, Bool)]) -> JSONValue {
    .object([
        "structuredContent": .object([
            "apis": .array(entries.map { name, baseURL, authenticated in
                .object([
                    "name": .string(name),
                    "baseUrl": .string(baseURL),
                    "authenticated": .bool(authenticated),
                ])
            }),
        ]),
    ])
}

private func apiFixture(
    entries: [(String, String, Bool)] = [("billing", "https://billing-staging.example.com", true)],
    environment: String = "staging"
) async throws -> (registry: ActionRegistry, panes: PaneStore, layout: LayoutStore) {
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    let http = RecordingToolCaller(always: listApisReply(entries))
    await registerApiActions(
        into: registry, panes: panes, layout: layout, http: http,
        activeContext: { ("initech", "proj", environment, "/tmp") })
    return (registry, panes, layout)
}

private struct NoPaneIdReturned: Error {}

/// The entry a pane's draft targets, read through the snapshot — the one
/// way anything reads it, tests included.
private func entryOf(_ panes: PaneStore, _ paneId: String) async -> String? {
    guard let api = await panes.snapshot(paneId: paneId, kind: "api").api else {
        return nil
    }
    return api.entry
}

private func openApi(
    _ registry: ActionRegistry, entry: String? = nil, pane: String? = nil
) async throws -> String {
    var params: [String: JSONValue] = [:]
    if let entry { params["entry"] = .string(entry) }
    if let pane { params["pane"] = .string(pane) }
    let result = try await registry.dispatch(
        name: "api_open", params: .object(params),
        origin: .agent, caller: .test("staging"), confirmation: nil)
    guard case .object(let fields) = result, case .string(let paneId)? = fields["pane"] else {
        throw NoPaneIdReturned()
    }
    return paneId
}

// MARK: - the pane opens, and it is an api pane

@Test func apiOpenOpensAnApiPaneAndNotADbOne() async throws {
    // The trap this ticket's own body names: inheriting `resolvePane`
    // literally opens a `db` pane, because that helper hardcodes the kind
    // `db_run_query` needs. A pane drawing a grid for an HTTP request
    // would be a surface lying about what it is.
    let (registry, _, layout) = try await apiFixture()
    let paneId = try await openApi(registry)

    let panes = await layout.snapshot().panes
    #expect(panes.count == 1)
    #expect(panes.first?.kind == "api")
    #expect(panes.first?.id == paneId)
}

@Test func theEntryIsRecordedOnTheDraftRatherThanOnThePane() async throws {
    // The entry lives on the draft so one pane can send to `billing` and
    // then to `auth` without a second pane being opened. `Pane` carries
    // nothing about it.
    let (registry, panes, layout) = try await apiFixture(entries: [
        ("billing", "https://billing.example.com", true),
        ("auth", "https://auth.example.com", false),
    ])
    let paneId = try await openApi(registry, entry: "billing")
    // Read back the way every other reader reads it — through the
    // snapshot. An accessor for the entry alone would be an internals
    // hatch that exists only for this assertion.
    #expect(await entryOf(panes, paneId) == "billing")

    // Re-pointing the SAME pane at another entry — what the URL line's
    // chooser does — keeps one pane and changes the draft.
    let again = try await openApi(registry, entry: "auth", pane: paneId)
    #expect(again == paneId)
    #expect(await entryOf(panes, paneId) == "auth")
    #expect(await layout.snapshot().panes.count == 1)
}

@Test func theTitleIsDerivedAndNotStored() async throws {
    // The entry alone (W8): the title moves only with the entry, so a path
    // segment in it would go stale the first time the path was typed.
    #expect(apiPaneTitle(entry: "billing") == "billing")
    // No entry resolved yet — the pane still has a name to draw.
    #expect(apiPaneTitle(entry: "") == "api")

    let (registry, _, layout) = try await apiFixture()
    let paneId = try await openApi(registry, entry: "billing")
    #expect(await layout.snapshot().panes.first(where: { $0.id == paneId })?.title == "billing")
}

// MARK: - what it reads back

@Test func anEmptyApiPaneReadsBackWithEveryKeyOfItsArm() async throws {
    let (registry, panes, _) = try await apiFixture()
    let paneId = try await openApi(registry, entry: "billing")

    guard case .object(let json) = await panes.readPane(paneId: paneId, kind: "api") else {
        Issue.record("the api arm did not serialise to an object"); return
    }

    #expect(json["kind"] == .string("api"))
    // Always null for this kind, structurally: a refusal is the pane
    // working correctly, and `ApiContents` has no field to hold one.
    #expect(json["failure"] == .null)
    #expect(json["entry"] == .string("billing"))
    #expect(json["environment"] == .string("staging"))
    // A boolean, meaning only that a credential is CONFIGURED.
    #expect(json["credentialed"] == .bool(true))
    #expect(json["recent"] == .array([]))
    #expect(json["recentTruncated"] == .bool(false))
    // W14: always present — false until a send is in flight.
    #expect(json["sending"] == .bool(false))
    // The second discriminator, and `none` has no other keys at all — a
    // null status beside an empty body would be lies about a request
    // nobody has sent.
    #expect(json["response"] == .object(["state": .string("none")]))

    guard case .object(let request)? = json["request"] else {
        Issue.record("request is not an object"); return
    }
    #expect(request["method"] == .string("GET"))
    #expect(request["origin"] == .string("https://billing-staging.example.com"))
    // The four regions, in wire order, all present and all empty.
    #expect(Array(request.keys).sorted() == ["body", "headers", "method", "origin", "path", "query"])
    for region in ["path", "query", "headers", "body"] {
        #expect(request[region] == .array([]), "\(region) must be present and empty")
    }
}

@Test func originIsNullWhenTheEntryDoesNotResolve() async throws {
    // An entry with no baseUrl configured. The pane still opens: the
    // failure showing on the surface BEFORE any send is the whole reason
    // the entry is resolved at open time.
    let (registry, panes, _) = try await apiFixture(entries: [("billing", "", false)])
    let paneId = try await openApi(registry, entry: "billing")

    guard case .object(let json) = await panes.readPane(paneId: paneId, kind: "api"),
          case .object(let request)? = json["request"] else {
        Issue.record("no request region"); return
    }
    #expect(request["origin"] == .null)
    #expect(json["credentialed"] == .bool(false))
    #expect(json["entry"] == .string("billing"))
    // And `failure` stays null even here: the pane produced exactly what
    // it was asked for, and what it produced says the entry has no origin.
    #expect(json["failure"] == .null)
}

@Test func anUnwrittenApiPaneAnswersAsAnEmptyApiPaneNotAnEmptyGrid() async {
    // The #181 trap, now reachable for a third kind: a pane that exists
    // and has never been written to answers with its OWN empty payload.
    let store = PaneStore(kinds: PaneKinds.standard)
    let snapshot = await store.snapshot(paneId: "p1", kind: "api")
    #expect(snapshot.kind == "api")
    #expect(snapshot.failure == nil)
    guard let api = snapshot.api else {
        Issue.record("an api pane must answer as an api pane"); return
    }
    #expect(api == .empty)
    #expect(!ApiPaneKind.rerunsSubjectOnRestore,
            "an api pane's subject is a request; re-running it at launch is an unattended send")
}

// MARK: - the refusals

@Test func anOmittedEntryOpensUnpointedRatherThanGuessedWhenSeveralExist() async throws {
    // 9b W1 (#183 amended): the refusal moved to Send. The pane opens pointed at nothing, so
    // nothing is guessed; `ApiEnvironmentTests` pins the result's keys and Send's refusal.
    let (registry, panes, layout) = try await apiFixture(entries: [
        ("billing", "https://billing.example.com", true),
        ("auth", "https://auth.example.com", true),
    ])
    let paneId = try await openApi(registry)
    #expect(await layout.snapshot().panes.map(\.id) == [paneId])
    #expect(await entryOf(panes, paneId) == "")
    #expect(await panes.apiSnapshot(paneId: paneId).request.origin == nil)
}

@Test func anUnknownEntryFailsLoudlyAndNamesWhatExists() async throws {
    let (registry, _, _) = try await apiFixture(entries: [
        ("billing", "https://billing.example.com", true),
    ])
    do {
        _ = try await openApi(registry, entry: "billinng")
        Issue.record("a typo'd entry opened a pane")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("billinng"))
        #expect("\(error)".contains("billing"), "the refusal names what the environment does declare")
    }
}

@Test func anEnvironmentWithNoEntriesIsRefusedWithItsOwnSentence() async throws {
    let (registry, _, _) = try await apiFixture(entries: [])
    do {
        _ = try await openApi(registry)
        Issue.record("a pane opened against an environment with no api entries")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("no api configured"))
    }
}

@Test func withNoHttpClientThePaneStillOpensWithNoOrigin() async throws {
    // `--dispatch` and this module's own tests: nothing to ask, so
    // nothing to refuse — the pane opens with the entry it was given and
    // no origin, which is the same answer an unreadable environment gives
    // and, for the caller, the same situation.
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerApiActions(into: registry, panes: panes, layout: layout, http: nil)

    let paneId = try await openApi(registry, entry: "billing")
    #expect(await layout.snapshot().panes.first?.kind == "api")
    guard case .object(let json) = await panes.readPane(paneId: paneId, kind: "api"),
          case .object(let request)? = json["request"] else {
        Issue.record("no request region"); return
    }
    #expect(json["entry"] == .string("billing"))
    #expect(request["origin"] == .null)
}

@Test func theFiveGridActionsRefuseAnApiPaneByName() async throws {
    // Free, and that is the point: `requireDataSurfacePane` refuses every
    // pane whose kind is not `db`, so registering `api` in `Pane.kinds`
    // is the whole of what this cost.
    let registry = ActionRegistry(journalDirectory: try scratch(), sessionId: "t")
    let panes = PaneStore()
    let layout = LayoutStore()
    await registerPaneContentActions(into: registry, panes: panes, layout: layout)
    let paneId = await layout.open(kind: "api", title: "billing").id

    let calls: [(String, JSONValue)] = [
        ("pane_select_cell", .object(["pane": .string(paneId), "row": .number(0)])),
        ("pane_select_rows", .object(["pane": .string(paneId), "rows": .array([.number(0)])])),
        ("pane_set_column_width",
         .object(["pane": .string(paneId), "column": .string("id"), "width": .number(100)])),
        ("pane_scroll_to_row", .object(["pane": .string(paneId), "row": .number(0)])),
        ("pane_scroll_clear", .object(["pane": .string(paneId)])),
    ]
    for (name, params) in calls {
        do {
            _ = try await registry.dispatch(
                name: name, params: params, origin: .agent, caller: .test("staging"),
                confirmation: nil)
            Issue.record("\(name) drove an api pane")
        } catch let error as PaneContentActionError {
            #expect("\(error)".contains("api"), "\(name) must refuse the pane BY KIND")
            #expect("\(error)".contains(paneId), "\(name) must name the pane it refused")
        }
    }
}

// MARK: - the URL line

@Test func theChooserIsDisabledRatherThanHiddenForASingleEntryEnvironment() {
    // Hidden would make a one-entry environment look like a pane that
    // cannot be re-pointed at all, and the operator would have no way to
    // learn that naming a second entry in the project is what changes it.
    // Disabled says: this exists, and there is nothing else to choose.
    #expect(!apiChooserIsEnabled(entry: "a", entries: []))
    #expect(!apiChooserIsEnabled(entry: "a", entries: ["a"]))
    #expect(apiChooserIsEnabled(entry: "a", entries: ["a", "b"]))
}
