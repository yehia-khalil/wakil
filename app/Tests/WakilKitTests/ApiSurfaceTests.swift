import Foundation
import Testing
@testable import WakilKit

/// The pane's surface — the operator's half of 2c-iv.
///
/// **Every ruling here is a function in `WakilKit` rather than an
/// expression in a `View`.** `WakilApp` has no test target, and
/// `apiChooserIsEnabled` set the precedent — *"a function rather than a
/// `disabled(entries.count < 2)` in the view, because `WakilApp` has no
/// test target and this is a ruling rather than a layout detail."* That
/// function is also the evidence for why this plan exists: it has been
/// shipped since #188 and nothing draws from it, because the pane has no
/// controls at all.

@Test("A read method presses api_request and a mutation presses api_send")
func theSendControlPressesTheRightAction() {
    // **The split is `ActionKind`'s and getting it wrong in the view is
    // not cosmetic**: a GET routed to `api_send` is a read priced at the
    // gate, and a POST routed to `api_request` is a write that never
    // reaches one — which is the inversion Decision 25 exists to prevent.
    for method in ["GET", "HEAD", "get"] {
        #expect(apiSendControl(method: method).action == "api_request")
    }
    for method in ["POST", "PUT", "PATCH", "DELETE", "patch"] {
        #expect(apiSendControl(method: method).action == "api_send")
    }
}

@Test("The label says what the press will do, in the operator's words")
func theSendControlSaysWhatItWillDo() {
    // A GET costs nothing anywhere, and the button says so by not
    // promising a confirmation.
    #expect(apiSendControl(method: "GET").label == "Send")
    // A mutation in production costs a typed confirmation; the label does
    // not claim otherwise, because the plane is what asks and the button
    // cannot know the environment.
    #expect(apiSendControl(method: "POST").label == "Send")
}

@Test("An unknown method is treated as a mutation, because the safe default is the gate")
func anUnknownMethodTakesTheGatedPath() {
    // A method the pane does not recognise must not be routed to the
    // ungated action. `api_send` refuses a read method by name, so the
    // worst case of this default is a refusal the operator can read —
    // where the other default's worst case is an unpriced write.
    #expect(apiSendControl(method: "TRACE").action == "api_send")
    #expect(apiSendControl(method: "").action == "api_send")
}

// MARK: - Task 2: the fields the operator types into

@Test("A typed field becomes one region of one api_set_request, and nothing else")
func aTypedFieldWritesOneRegion() {
    // **A field's edit is a whole-region write, because that is the only
    // write there is.** `api_set_request` takes every region optional and
    // absent meaning unchanged, so a path field commits `path` alone and
    // leaves query, headers, contentType and body exactly as they were.
    let params = apiFieldWrite(field: .path, text: "/bookings/41", pane: "api-1")
    guard case .object(let fields) = params else { Issue.record("not an object"); return }
    #expect(fields["pane"] == .string("api-1"))
    #expect(fields["path"] == .array([.object(["literal": .string("/bookings/41")])]))
    // Every other region is absent rather than empty — an empty array
    // CLEARS a region, which is not what typing in another one means.
    #expect(fields["query"] == nil)
    #expect(fields["headers"] == nil)
    #expect(fields["body"] == nil)
    #expect(fields["contentType"] == nil)
}

@Test("A typed path is one literal part, because typing never creates a hole")
func typingNeverCreatesAHole() {
    // #112: a binding is made by a gesture and never by writing one, and
    // there is no template syntax anywhere in Wakil. So `{{id}}` typed
    // into the path is LITERAL text, not a slot — the whole no-delimiter
    // ruling, at the one surface where somebody might expect otherwise.
    let params = apiFieldWrite(field: .path, text: "/bookings/{{id}}", pane: "api-1")
    guard case .object(let fields) = params,
        case .array(let parts)? = fields["path"]
    else { Issue.record("no path"); return }
    #expect(parts == [.object(["literal": .string("/bookings/{{id}}")])])
}

@Test("contentType is free text and admits no parts")
func contentTypeIsTheOneFieldWithoutParts() {
    let params = apiFieldWrite(field: .contentType, text: "application/merge-patch+json", pane: "p")
    guard case .object(let fields) = params else { Issue.record("not an object"); return }
    // #116: the one field on the draft that is a string rather than parts.
    #expect(fields["contentType"] == .string("application/merge-patch+json"))
}

@Test("A named row writes its whole region, carrying the rows it did not touch")
func aNamedRowCarriesItsNeighbours() {
    var draft = ApiDraft.empty
    draft.query = [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "dry", value: [.literal("false")]),
    ]
    // Editing `dry` must not drop `expand`: `query` is written ENTIRE, so
    // a write built from one row alone would clear the other.
    let params = apiRowWrite(draft: draft, field: .query("dry"), text: "true", pane: "p")
    guard case .object(let fields) = params, case .array(let rows)? = fields["query"] else {
        Issue.record("no query"); return
    }
    #expect(rows.count == 2)
    #expect(rows[0] == .object([
        "name": .string("expand"), "value": .array([.object(["literal": .string("lines")])]),
    ]))
    #expect(rows[1] == .object([
        "name": .string("dry"), "value": .array([.object(["literal": .string("true")])]),
    ]))
}

@Test("A row the draft does not hold is added rather than lost")
func anUnknownRowIsAdded() {
    let params = apiRowWrite(
        draft: ApiDraft.empty, field: .header("x-trace"), text: "abc", pane: "p")
    guard case .object(let fields) = params, case .array(let rows)? = fields["headers"] else {
        Issue.record("no headers"); return
    }
    #expect(rows == [.object([
        "name": .string("x-trace"), "value": .array([.object(["literal": .string("abc")])]),
    ])])
}

@Test("The chooser is drawn from a ruling that already existed and nothing drew from")
func theChooserUsesTheShippedRuling() {
    // `apiChooserIsEnabled` has been in WakilKit since #188 with no
    // caller, because the pane had no controls. This is the caller.
    #expect(apiChooserIsEnabled(entry: "billing", entries: ["billing"]) == false)
    #expect(apiChooserIsEnabled(entry: "billing", entries: ["billing", "catalog"]) == true)
}

@Test("Final review 2 (W1): a pane keeping an entry its one-entry environment lacks can still pick one")
func theChooserOffersTheOneEntryToAPaneThatLacksIt() {
    // `qa` declares only `catalog`; the pane kept `billing`, and reads "qa declares no entry
    // named billing — pick one". A disabled chooser there is a dead end.
    #expect(apiChooserIsEnabled(entry: "billing", entries: ["catalog"]))
    // An unpointed pane in a one-entry environment can pick it too.
    #expect(apiChooserIsEnabled(entry: "", entries: ["catalog"]))
    // Pointed at the one entry there is, there is nothing else to choose.
    #expect(!apiChooserIsEnabled(entry: "catalog", entries: ["catalog"]))
    // Nothing declared: nothing to offer.
    #expect(!apiChooserIsEnabled(entry: "billing", entries: []))
}

@Test("The Send control carries a statement for a mutation, because api_send requires one")
func theSendControlCarriesAStatement() {
    var request = ApiRequestSnapshot.empty
    request = ApiRequestSnapshot(
        method: "POST", origin: "https://billing.example.com",
        path: [.literal("/bookings/41/confirm")], query: [], headers: [], body: [])

    guard case .object(let params) = apiSendParams(
        draft: request, pane: "api-1", origin: "https://billing.example.com")
    else { Issue.record("not an object"); return }

    // **Without this the button could not send a mutation at all.** The
    // first version passed `pane` alone: `api_request` was content with
    // that so a GET worked, and every mutation was refused by
    // `sendNeedsAStatement` while the button looked live and the pane
    // never changed. The e2e parity step is what found it.
    guard case .string(let statement)? = params["statement"] else {
        Issue.record("no statement — api_send refuses without one"); return
    }
    #expect(statement.contains("POST"))
    #expect(statement.contains("billing.example.com"))
    #expect(statement.contains("no body"))
}

@Test("A read carries no statement, because api_request takes none")
func aReadCarriesNoStatement() {
    let request = ApiRequestSnapshot(
        method: "GET", origin: "https://billing.example.com",
        path: [.literal("/bookings/41")], query: [], headers: [], body: [])
    guard case .object(let params) = apiSendParams(
        draft: request, pane: "api-1", origin: "https://billing.example.com")
    else { Issue.record("not an object"); return }
    // Not merely unused — `api_request`'s schema does not declare it, and
    // sending a key an action does not take is how a caller learns
    // nothing when it is quietly ignored.
    #expect(params["statement"] == nil)
    #expect(params["pane"] == .string("api-1"))
}

@Test("The chooser's enabled branch is reachable, which it was not before")
func theChoosersTrueBranchIsReachable() {
    // #296's audit: "`apiChooserIsEnabled(entryCount:)` has a true branch
    // that nothing in the app can reach — `ApiPane.entryCount` is
    // `snapshot.entry.isEmpty ? 0 : 1`, so it is never above one."
    //
    // The ruling was always right; the pane could not count entries
    // because nothing told it the list. This pins the arithmetic the view
    // now does, so a regression to a per-pane count fails here rather
    // than in a live window.
    #expect(apiChooserIsEnabled(entry: "billing", entries: ["billing", "catalog"]))
    #expect(!apiChooserIsEnabled(entry: "billing", entries: ["billing"]))
    #expect(!apiChooserIsEnabled(entry: "billing", entries: []))
}

@Test("The pane learns the entries whoever opened it, agent or operator")
func theEntriesRideOnTheSnapshot() async {
    let panes = PaneStore()
    // Opened the way the AGENT opens one — no window `dispatch` involved,
    // which is precisely the case the first version got wrong: the model
    // only sees a result the operator's press produced, so a pane the
    // agent opened had an empty list and a chooser disabled in exactly
    // the environment it exists for.
    await panes.openApi(
        paneId: "api-1", entry: "billing", environment: "staging", origin: nil,
        credentialed: true, entries: ["billing", "catalog"])

    let snapshot = await panes.apiSnapshot(paneId: "api-1")
    #expect(snapshot.entries == ["billing", "catalog"])
    #expect(apiChooserIsEnabled(entry: snapshot.entry, entries: snapshot.entries))
}

@Test("A re-open that learned no listing keeps the entries it had")
func aReopenWithNoListingKeepsTheEntries() async {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api-1", entry: "billing", environment: "staging", origin: nil,
        credentialed: true, entries: ["billing", "catalog"])
    // `--dispatch` and this module's tests open with nothing to hand;
    // emptying the list there would disable the chooser on a re-open that
    // learned nothing new.
    await panes.openApi(
        paneId: "api-1", entry: "catalog", environment: "staging", origin: nil,
        credentialed: false)
    #expect(await panes.apiSnapshot(paneId: "api-1").entries == ["billing", "catalog"])
}

@Test("An environment switch drops the entries with the origin")
func aSwitchDropsTheEntries() async {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api-1", entry: "billing", environment: "staging", origin: "https://b.example",
        credentialed: true, entries: ["billing", "catalog"])
    await panes.clearApiResponses(to: "production")
    // The list belongs to the environment being left; a chooser offering
    // it would re-point the draft at an entry the new environment may not
    // declare.
    #expect(await panes.apiSnapshot(paneId: "api-1").entries.isEmpty)
}

// MARK: - The regions the operator types into

@Test("A row of literals is typable; one holding a binding is not")
func onlyALiteralRowIsTypable() {
    #expect(apiRowIsTypable([]))
    #expect(apiRowIsTypable([.literal("lines")]))
    // **A bound value is unmade by `api_unbind`, never by typing over
    // it** (#112). Typing over one would destroy provenance a gesture
    // recorded — the pinned declared type and generation a caller cannot
    // author — so the row is drawn as its chip instead.
    #expect(!apiRowIsTypable([.bound(ApiBoundValue(
        name: "id", binding: .live,
        source: ApiValueSource(
            pane: "db1", table: "t", keyColumns: ["id"], keyValues: ["1"],
            column: "id", declaredType: "INTEGER", generation: 1)))]))
    // A hole is not a binding: it carries nothing, and typing over it is
    // how an operator abandons it.
    #expect(apiRowIsTypable([.slot("id")]))
    // Mixed is not typable — committing text over it would silently drop
    // the binding beside the literal.
    #expect(!apiRowIsTypable([.literal("a"), .bound(ApiBoundValue(
        name: "id", binding: .live,
        source: ApiValueSource(
            pane: "db1", table: "t", keyColumns: ["id"], keyValues: ["1"],
            column: "id", declaredType: "INTEGER", generation: 1)))]))
}

@Test("The draft a row write carries its neighbours from is the snapshot's own")
func theWriteDraftIsBuiltFromTheSnapshot() {
    let request = ApiRequestSnapshot(
        method: "POST", origin: nil,
        path: [.literal("/x")],
        query: [ApiQueryRow(name: "a", value: [.literal("1")])],
        headers: [
            ApiHeaderRegionRow(
                name: "x-trace", value: [.literal("abc")], provenance: nil,
                rowClass: .authored),
            // The entry's own row carries no value and must not reach a
            // write: `api_set_request` refuses `authorization` by name.
            ApiHeaderRegionRow(
                name: "authorization", value: nil,
                provenance: "supplied by the billing entry", rowClass: .supplied),
        ],
        body: [.literal("{}")])

    let draft = apiDraftForWrite(request)
    #expect(draft.query.map(\.name) == ["a"])
    // Only the operator's own rows — a write naming the entry's would be
    // refused whole, taking the operator's edit down with it.
    #expect(draft.headers.map(\.name) == ["x-trace"])
    #expect(draft.body == [.literal("{}")])
}

// MARK: - The recent strip

private func row(
    _ method: String = "GET", path: String = "/bookings/41", status: Int? = 200,
    millis: Int? = 12
) -> ApiRecentRow {
    ApiRecentRow(
        method: method, entry: "billing", environment: "staging", path: path,
        sentUrl: "https://billing.example.com" + path, status: status, durationMs: millis,
        draft: ApiDraft.empty)
}

@Test("A row reads method, path, status and duration, in that order")
func aRecentRowReadsAsASend() {
    let label = apiRecentRowLabel(row())
    #expect(label == "GET /bookings/41 · 200 · 12 ms")
}

@Test("Re-walk #3: a row sent to the root reads `/`, never a double space")
func aRowWithAnEmptyPathReadsTheRoot() {
    #expect(apiRecentRowLabel(row("POST", path: "", status: 405)) == "POST / · 405 · 12 ms")
}

@Test("A send with no reply says so rather than drawing a zero")
func aRowWithNoStatusSaysSo() {
    // A transport failure and a fate-unknown have no status, and a `0`
    // beside a path reads as a code the server sent — the same rule the
    // response states carry, on the row.
    #expect(apiRecentRowLabel(row(status: nil, millis: nil)) == "GET /bookings/41 · no reply")
    // A failure that waited still says how long it waited: that is the
    // operator's first question about one.
    #expect(apiRecentRowLabel(row(status: nil, millis: 30)) == "GET /bookings/41 · no reply · 30 ms")
}

@Test("The strip's summary counts what is there, and says when it was trimmed")
func theStripSummaryCounts() {
    #expect(apiRecentSummary(count: 0, truncated: false) == "none yet")
    #expect(apiRecentSummary(count: 1, truncated: false) == "1 send")
    #expect(apiRecentSummary(count: 7, truncated: false) == "7 sends")
    // A short history and a trimmed one must never look alike — the rule
    // `recentTruncated` exists for.
    #expect(apiRecentSummary(count: 200, truncated: true) == "200 sends · trimmed")
}
