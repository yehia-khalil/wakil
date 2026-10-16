# Phase 2c-iv — the split pane, and editing around a chip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** The api pane splits into a request that scrolls and a response that scrolls, with
the response's head pinned and its headers shown on request. A chip can be removed from the
keyboard, a body hole lands at the cursor, and a bound value locks only itself. Recent is one
list per project and environment that shows the values that were sent. The small things the
walk found are fixed too: the name box takes focus, refusal lines span the full width,
`BODY · JSON` / `BODY · TEXT`, the pane title follows its entry, and the content-type
placeholder reads `application/json`.

**Architecture:** As in every 2c-iv plan, rulings live in WakilKit and the view only calls
them. First, a commit that changes no behaviour splits `ApiPane.swift` (about 2,000 lines once
plan A lands) into one `extension ApiPane` file per region. W16 reverses Amendment 2.
`api_set_request` admits a bound part that the region already holds, so every write the pane
builds can carry its bindings (`ApiHeldBindings`). Backspace and Delete on a chip go through
the chip's own `×` gesture (`apiChipBeside`, `apiChipUnbindParams`). The `×` path is caught at
the AppKit level, because SwiftUI does not expose a single-line field's caret on macOS 14.
Recent moves out of each pane into a `PaneStore` list keyed by
(organisation, project, environment). The split is `apiPaneSplit`, one GeometryReader and two
ScrollViews.

**Tech Stack:** SwiftUI (`WakilApp`, no test target, macOS 14.4), AppKit (`NSEvent` local
monitor, `NSTextView`), `WakilKit` (swift-testing, `make app-test`), JSONL checks under
`e2e/checks/seeded/`, the e2e driver (`go test ./e2e/...`).

**Spec:** `docs/superpowers/specs/2026-09-29-phase-2c-iv-the-hand-bind-design.md`, **Amendment
9**, section **9c**, plus the parts of 9d that belong to it: W16's per-part-lock check, the
Backspace-on-a-chip check, and the re-walk's look at the split layout. Read Amendment 8 and all
of Amendment 9 first.

**Runs after plan A:** `docs/superpowers/plans/2026-10-03-phase-2c-iv-saved-as-typed-and-sending.md`
(9a, 9b) must be implemented and merged into this branch first. Every "after plan A" below
names code that plan A writes:

- `ApiSaveAsTyped.swift`: `apiPendingWrite`, `apiRequestApplying`, `apiFlush`,
  `apiFlushedSequence`, `apiBoxesAfterLanding`, `ApiFocusedField`, `apiRestoreWrite`.
- The pane's doors: `operate`, `operateInOrder`, `operateFlushed`, `flush()`, `keystroke()`,
  `applied`, `send()`, `restore(_:)`, `focusChanged(_:_:)`.
- `WindowModel.enqueueFromSurface`.
- `ApiSnapshot.sending`, `ApiResponseSnapshot.cancelled`, `ApiRequestOutcome.cancelled`,
  `PaneStore.finishApiSend`.
- `ApiPaneResolver`, `PaneStore.reresolveApis`.
- `apiFailureLine` and the `.wraps()` modifier.
- The harness's `refuses` dispatch field.

**Nothing from 9a or 9b is planned here.** Where this plan edits plan A's code, it says so.

## Global Constraints

- **Every ruling goes in `WakilKit`, not in the view.** A string, an `if` that chooses an
  action, a parse or a comparison written inline in `ApiPane*.swift`, `ApiBodyTextView.swift`
  or `ApiChipKeys.swift` is a ruling that nothing can pin. Layout numbers (a row height in
  points) are drawing, not rulings.
- **Every dispatch in the pane goes through `operate(_:_:)`, `operateInOrder(_:)` or
  `operateFlushed(_:)`.** These are plan A's doors, and all three reach
  `WindowModel.enqueueFromSurface`. `dispatch` and `dispatchInOrder` stay `private` in
  `ApiPane.swift`, so that no extension file can reach them.
- **Identifiers go only on an element with an accessibility action**, such as `Button`,
  `TextField`, the body's `NSTextView` or `Menu`, and never on a `Text`. **At the AppKit
  level, an identifier is set only when it changes.** `ApiBodyTextView.updateNSView` guards
  this, because 10 of 10 `api.recent` presses answered AXError -25200 without the guard.
  `ChipKeyCatcher` sets no identifier, and its view is not an accessibility element.
- **No shipped identifier changes.** The chip's `×` moves inside the chip and keeps
  `api.<key>.part.<i>.remove` / `.unbind`.
- **Exactly two identifiers are added: `api.response.body` and `api.response.headers`.** They
  are the `SegmentedChoice` from `app/Sources/WakilApp/SettingsForm.swift`, and they harvest
  as the family `api.response.<…>`.
- **A hover or quiet control changes its opacity, never whether it exists.**
- **No new action. No new `read_pane` key.** `recent` keeps its shape, but **its meaning
  widens** (W15): every api pane of the project and environment publishes the same list.
  `ApiSnapshot.bound` and `ApiRecentRow.shownPath` are screen-only and are not published.
  `read_pane` already carries both facts: `preview` on every bound part, and `sentUrl` on a
  row.
- **Design language** (`docs/wakil/design-language.md` §1, §5, §6, §8, and the restyle
  rules):
  - violet `#7c5cff` (`SettingsPalette.accent`) marks only what is active or chosen;
  - green, amber and red carry only their meanings, and the response's status chip is the
    only hue in the response;
  - micro-labels are uppercase and tracked (`micro(_:)`);
  - every value is monospace;
  - rows are separated by hairlines, never by boxes.
- **Spec values, verbatim:**
  - the request half takes **55%**;
  - Recent is at most **4** rows tall when unfolded, and capped at **200** rows in memory;
  - a value over **24** characters is shortened with **`…`**;
  - `BODY · JSON` / `BODY · TEXT`;
  - the placeholder is `application/json`;
  - a Recent row reads `GET /customers/<id:3>/confirm`;
  - a Bound row reads `id = 3 · live · events.customers`;
  - the choice reads `Body · Headers`, defaulting to Body.
- **Tests:** `make app-test` (swift-testing, `app/Tests/WakilKitTests`), `go test ./...`.
  `make app-bundle` and `make controls` are headless.
- **GUI runs need the operator's OK every time.** That covers `make e2e`, `make e2e-new` and
  launching the app. Quit the live Wakil first. Ask the peer sessions before a run and tell
  them after (the shared-GUI memory). No task runs a GUI target unless its step says so.
- **New e2e checks must be seen red against `ed1af70`:**
  `make e2e-new E2E_NEW_ARGS="--base ed1af70"`. Read each failure's reason, not the count.
- **The runbook** `docs/wakil/phase-2c-iv-acceptance.md` is re-rendered with
  `make e2e-runbook` while the hand edits are still uncommitted. Then commit both together.

## Review Focus

1. **A path-box edit that would carry a bound chip from the Query region into the path.**
   Example: the operator deletes the `?` in front of `id=<chip>`. Expected: the edit is refused
   on screen in amber (*"a bound value stays in the region it was dropped in — unbind it to
   move it"*), nothing is written, and the binding is kept. The server would refuse the write
   anyway, but as a dispatch error the operator never sees. *Task 2,
   `aBindingCannotMoveBetweenPathAndQuery`.*
2. **An agent's write that names one held binding twice.** The agent copies the chip it read
   from `read_pane` into two places. Expected: the whole write is refused, because the second
   copy would be a binding that no gesture made. *Task 2,
   `aHeldBindingCannotBeWrittenTwice`.*
3. **Backspace (or `×`) on a filled chip right after the box before it was emptied.** The
   flush drops the empty literal, so every index after it moves down by one. Expected: the
   unbind lands on the same chip, never on the part beside it. Plan A's `×` sends the drawn
   index after the flush, which has this defect latent. *Task 3,
   `anUnbindAfterAnEmptiedBoxTargetsTheSameChip`.*
4. **Body `+ HOLE` with a remembered caret in a box that no longer exists.** An agent
   rewrote the body, or a write merged the boxes. Expected: the hole is appended at the end.
   It is never put at a guessed position, and never refused as *"a hole needs a name"*. *Task
   4, `aStaleCaretFallsBackToTheEnd`.*
5. **A bound value whose source pane is closed when Recent or the Bound list is drawn.**
   Expected: Recent shows `<id>` with no value, and the Bound row reads
   `id · live · bookings · no value now`. It never shows a stale or invented value. *Task 5,
   `aValueWithNoSourceShowsNone`.*

---

## Phase 1 — the file split and the per-part lock

### Task 1: Split `ApiPane.swift` by region (no behaviour change)

**Why, and why first.** After plan A, `ApiPane.swift` is about 2,000 lines. Tasks 2–8 touch
four of its regions: the fields, the tables, the response and the body. A reviewer of the
split-pane work should see the split itself in its own commit, as pure moves, and every later
diff should land in a file that holds one region. Swift extensions in other files cannot read
`private` members. So this commit removes `private` from every member that another file
needs, and from nothing else. Stored state stays in `ApiPane.swift`, because extensions cannot
declare it. `dispatch` and `dispatchInOrder` **stay private** in `ApiPane.swift`, where
`operate` and `operateInOrder` are the only callers. That is the "one door" rule, now enforced
by the compiler.

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift`. Keep the type's doc comment, the stored
  properties, every `@State`/`@FocusState`, `init`, the colour constants, `methods`, `body`,
  `// MARK: - The operator's dispatches` (`operate`, `operateInOrder`, and plan A's
  `pendingWrite` / `applied` / `keystroke` / `flush` / `operateFlushed`) and
  `// MARK: - The drop` (`drop`, `resultLine`).
- Create: `app/Sources/WakilApp/ApiPane+Request.swift`. Move the MARKs *The method line and
  the URL box*, *The three regions below it*, *The two tables*, *Adding and removing rows
  (8b)*, and `bodyRegion` and `formatControl`.
- Create: `app/Sources/WakilApp/ApiPane+Fields.swift`. Move the MARKs *Parts* and *The fields
  the operator types into*. That is everything from `parts(_:)` through `takeOwedFocus`,
  including plan A's `focusChanged`, `restore` and `write` / `holeWrite` / `pathWrite`.
- Create: `app/Sources/WakilApp/ApiPane+Sending.swift`. Move the MARKs *Send* (`sendControl`,
  plan A's `send()`, `unfilledLine`), *The bound-values strip*, *The past tense* and *The
  response* (`response`, `responseHeading`, `toneColor`).
- Create: `app/Sources/WakilApp/ApiPaneLayout.swift`. Move the file-scope `// MARK: - Layout`
  (`Verb`, `ApiFlowGrows`, `ApiFlow`, `ApiRowColumns`) and plan A's
  `private extension View { func wraps() }`.
- Modify: `e2e/driver/identifiers.go`. Add the three files that hold controls to
  `AuditedSources`.

**Interfaces:**
- Consumes: plan A's `ApiPane` as merged.
- Produces: the file map above. Later tasks name a file and a function, never a line.
  `FieldView`, `RowSlot`, `Verb`, `ApiFlowGrows` and `wraps()` become internal.

- [ ] **Step 1: Record the control harvest before the split.**

```bash
go run ./e2e/cmd/wakil-controls > "$SCRATCH/controls-before.txt" 2>&1
sed -E 's/[A-Za-z+]+\.swift:[0-9]+//g' "$SCRATCH/controls-before.txt" | sort > "$SCRATCH/names-before.txt"
```

  (`$SCRATCH` is the session's scratchpad directory.)
- [ ] **Step 2: Move the code.** Each MARK section moves **verbatim**, doc comments included,
  into `extension ApiPane { … }` in its file. Each new file starts with `import AppKit`,
  `import WakilKit` and `import SwiftUI`. Then fix access, and change nothing else:
  - `@State private var` becomes `@State var`, and `@FocusState private var` becomes
    `@FocusState var`.
  - `private let ink` / `amber` / `green` / `red` / `methods` become `let`.
  - Every `private func`, `private var … : some View` and `@ViewBuilder private` loses
    `private`.
  - `private struct FieldView` and `private struct RowSlot` lose `private`.
  - `private struct Verb` and `private struct ApiFlowGrows` (now in `ApiPaneLayout.swift`)
    lose `private`.
  - `private extension View { func wraps() … }` becomes `extension View { func wraps() … }`
    in `ApiPaneLayout.swift`.
  - **`private let dispatch` and `private let dispatchInOrder` keep `private`.**
- [ ] **Step 3: Put the new files under the gate.** In `e2e/driver/identifiers.go`, replace
  the line `"ApiPane.swift",` in `AuditedSources` with:

```go
	"ApiPane.swift",
	// The split (2c-iv 9c, Task 1) moved the pane's controls into one file per region;
	// each is under the gate, or the denominator goes blind on everything moved.
	"ApiPane+Fields.swift",
	"ApiPane+Request.swift",
	"ApiPane+Sending.swift",
```

- [ ] **Step 4: Prove nothing moved but code.**
  - `make app-bundle` must build. If a moved member is still `private` and read from another
    file, the build names it. Remove that `private` and nothing more.
  - `go test ./e2e/driver/` must be green.
  - Run `go run ./e2e/cmd/wakil-controls > "$SCRATCH/controls-after.txt" 2>&1`, put it through
    the same `sed | sort` into `names-after.txt`, and run
    `diff "$SCRATCH/names-before.txt" "$SCRATCH/names-after.txt"`. Expected: **no
    difference.** Only file names and line numbers may change.
  - `grep -n "dispatch(\|dispatchInOrder(" app/Sources/WakilApp/ApiPane*.swift`. The only
    hits are inside `operate` and `operateInOrder` in `ApiPane.swift`.
  - `make app-test` must be green, and unchanged.
  - `git diff --stat -M` shows four new files. `git diff --color-moved=dimmed-zebra` shows
    nothing but moved blocks and deleted `private` keywords.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilApp/ApiPane.swift app/Sources/WakilApp/ApiPane+Request.swift \
  app/Sources/WakilApp/ApiPane+Fields.swift app/Sources/WakilApp/ApiPane+Sending.swift \
  app/Sources/WakilApp/ApiPaneLayout.swift e2e/driver/identifiers.go
git commit -m "Split ApiPane.swift by region, no behaviour change; the three files with controls join the gate"
```

### Task 2: A bound value locks only itself (W16)

Amendment 2 locked a whole region over one binding, because a region's write carried its
neighbours and `api_set_request` refused every bound part. W16 reverses that.
**`api_set_request` admits a bound part identical to one the same region already holds**:
same name, binding kind and source. The bound part may sit anywhere in that region. A bound
part the region does not hold is still refused, so a write can keep a binding but can never
make one. Each held binding can be carried **once**. Every write the pane builds now carries
the binding as `apiPartJSON` publishes it, instead of degrading it to its slot.

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiParts.swift`. Add `ApiBoundIdentity` and
  `ApiHeldBindings`. `apiPart`, `apiParts` and `apiNamedRows` take
  `held: inout ApiHeldBindings`. The existing three-argument forms keep refusing every
  binding.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`:
  - the `api_set_request` handler's region decoding;
  - its description sentence *"A bound value CANNOT be written here …"*;
  - `boundValueIsAGesture`'s text;
  - `apiFieldIsTypable` and its doc;
  - `apiPartsWrite`'s `written`, which carries the binding.
- Modify: `app/Sources/WakilKit/Api/ApiRows.swift`. `apiRowDrawsRemove` draws `×` on every
  operator row that holds no binding of its own. Update `apiRowAddIsEnabled`'s doc.
- Modify: `app/Sources/WakilKit/Api/ApiPathQuery.swift`. Change `apiPathBoxIsTypable` and
  `apiPathBoxNote`, add `ApiPathQueryRefusal.boundMoved` and `apiPathBoxKeepsItsBindings`,
  and add the guard in `apiPathBoxWrite`. Update `apiPathQueryWrite`'s doc.
- Modify: `app/Sources/WakilKit/Api/ApiBodyFormat.swift`. `apiFormatBodyWrite` carries a
  binding. Update `apiFormatIsEnabled`'s doc.
- Modify: `app/Sources/WakilKit/Api/ApiSaveAsTyped.swift` (plan A's). `apiRequestApplying`'s
  `.path` case also requires `apiPathBoxKeepsItsBindings`.
- Modify: `app/Sources/WakilApp/ApiPane+Request.swift` and `ApiPane+Fields.swift`. Comments
  only: delete every *"Locked whole … (Amendment 2)"* sentence and write the W16 rule in its
  place. The drawing already follows the rulings.
- Test:
  - `app/Tests/WakilKitTests/ApiSetRequestTests.swift`;
  - `app/Tests/WakilKitTests/ApiHandBindTests.swift` (rewrite `aBoundFieldIsNotTypable`,
    `aRegionHoldingABoundRowLocksWhole`, `aBoundHeaderLocksTheHeaderRegion` and
    `formatIsLiveOverABody`);
  - `app/Tests/WakilKitTests/ApiRowsTests.swift` (rewrite
    `addingIsLiveUnlessTheRegionIsBound` and `theRemoveIsDrawnOnTheOperatorsRows`);
  - `app/Tests/WakilKitTests/ApiPathQueryTests.swift` (rewrite `thePathBoxLocks`,
    `theAmpersandNote`, and the `bound, .literal("?x")` line of the Ruling 23 test);
  - `app/Tests/WakilKitTests/ApiSaveAsTypedTests.swift` (rewrite plan A's
    `aLockedBodyIsNeverWritten`).

**Interfaces:**
- Consumes: `apiPartJSON(_:sources:)`, `apiPathQueryParse`, plan A's `apiRequestApplying`.
- Produces:
  ```swift
  struct ApiBoundIdentity: Equatable { init(_ bound: ApiBoundValue); init?(json: [String: JSONValue]) }
  struct ApiHeldBindings { init(_ parts: [ApiPart]); static var none: ApiHeldBindings; mutating func take(_ identity: ApiBoundIdentity) -> ApiBoundValue? }
  func apiParts(_ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings) throws -> [ApiPart]
  func apiNamedRows(_ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings) throws -> [(name: String, value: [ApiPart])]
  public func apiPathBoxKeepsItsBindings(_ request: ApiRequestSnapshot, path: [ApiPart], query: [ApiQueryRow]) -> Bool
  case ApiPathQueryRefusal.boundMoved   // "a bound value stays in the region it was dropped in — unbind it to move it"
  ```
  After this task, `apiFieldIsTypable` is `true` for every field. `apiPathBoxIsTypable` is
  false only for a query value that holds `&`.

- [ ] **Step 1: Write the failing tests.**

  In `ApiSetRequestTests.swift`, after `aBoundValueCannotBeWrittenAsText`, which stays and
  must still pass because an empty region holds nothing to carry:

```swift
// MARK: - W16: a bound value locks only itself

/// Puts a binding into the pane's draft the way a drop would, without a grid.
private func holding(
    _ f: ApiFixture, _ paneId: String, path: [ApiPart] = [], body: [ApiPart] = []
) async {
    var draft = await f.panes.apiDraft(paneId: paneId)
    draft.path = path
    draft.body = body
    await f.panes.setApiDraft(paneId: paneId, draft: draft)
}

private func boundJSON(_ bound: ApiBoundValue) -> JSONValue {
    apiPartJSON(.bound(bound), sources: [:])
}

@Test func aWriteMayCarryABindingTheRegionHoldsWhereverItMoved() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id", generation: 3)
    await holding(f, paneId, path: [.literal("/v1/"), .bound(bound)])
    // The agent's write moves the text around the chip and carries the chip, as published.
    try await setRequest(f, pane: paneId, [
        "path": .array([literal("/v2/bookings/"), boundJSON(bound), literal("/confirm")]),
    ])
    // The binding that lands is the one the region held, with its pinned provenance
    // (generation 3, declared type), not a reconstruction from the JSON.
    #expect(await f.panes.apiDraft(paneId: paneId).path
        == [.literal("/v2/bookings/"), .bound(bound), .literal("/confirm")])
}

@Test func aBindingTheRegionDoesNotHoldIsStillRefused() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let held = liveBinding(name: "id")
    await holding(f, paneId, path: [.literal("/v1/"), .bound(held)])
    let other = ApiBoundValue(
        name: "id", binding: .live,
        source: valueSource(name: "id", keyValues: ["100"], generation: 3))
    do {
        try await setRequest(f, pane: paneId, ["path": .array([boundJSON(other)])])
        Issue.record("a binding the region does not hold was written")
    } catch let error as ApiActionError {
        #expect("\(error)".contains("api_bind"))
    }
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.literal("/v1/"), .bound(held)])
}

@Test func aBindingCannotMoveToAnotherRegion() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id")
    await holding(f, paneId, path: [.bound(bound)])
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["body": .array([boundJSON(bound)])])
    }
}

@Test func aHeldBindingCannotBeWrittenTwice() async throws {
    // Review Focus 2: the second copy would be a binding no gesture made.
    let f = try await fixture()
    let paneId = try await open(f)
    let bound = liveBinding(name: "id")
    await holding(f, paneId, path: [.bound(bound)])
    await #expect(throws: ApiActionError.self) {
        try await setRequest(f, pane: paneId, ["path": .array([boundJSON(bound), boundJSON(bound)])])
    }
    #expect(await f.panes.apiDraft(paneId: paneId).path == [.bound(bound)])
}
```

  In `ApiHandBindTests.swift`, replace `aBoundFieldIsNotTypable` and
  `aRegionHoldingABoundRowLocksWhole` with:

```swift
@Test("W16: a bound value locks only itself — the field and its region stay typable")
func aBoundValueLocksOnlyItself() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiFieldIsTypable(request(path: [.literal("/b/"), bound]), .path))
    #expect(apiFieldIsTypable(request(path: [], body: [bound]), .body))
    let draft = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [bound]),
    ])
    #expect(apiFieldIsTypable(draft, .query("expand")))
}

@Test("W16: a gesture beside a binding writes the field and carries the binding unchanged")
func aGestureBesideABindingCarriesIt() {
    let bound = liveBinding(name: "id")
    // The walk's case: an unfilled hole removed while the value beside it is bound.
    let draft = request(path: [.literal("/b/"), .bound(bound), .slot("v")])
    #expect(pathParts(apiPartsWrite(draft: draft, field: .path, edit: .remove(index: 2), pane: "p"))
        == [.object(["literal": .string("/b/")]), apiPartJSON(.bound(bound), sources: [:])])
    let rows = request(path: [], query: [
        ApiQueryRow(name: "expand", value: [.literal("lines")]),
        ApiQueryRow(name: "id", value: [.bound(bound)]),
    ])
    guard case .object(let fields)? = apiPartsWrite(
        draft: rows, field: .query("expand"), edit: .text(index: 0, "guest"), pane: "p"),
        case .array(let written)? = fields["query"]
    else { Issue.record("no query region written"); return }
    #expect(written[1] == .object([
        "name": .string("id"), "value": .array([apiPartJSON(.bound(bound), sources: [:])]),
    ]))
}
```

  Replace `aBoundHeaderLocksTheHeaderRegion` with:

```swift
@Test("W16: a bound header row locks only its own value")
func aBoundHeaderLocksOnlyItself() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/x")], query: [],
        headers: [authored("accept", [.literal("a")]), authored("x-id", [bound])]
            + ApiRequestSnapshot.empty.headers,
        body: [])
    #expect(apiFieldIsTypable(request, .header("accept")))
    #expect(apiFieldIsTypable(request, .header("x-id")))
}
```

  In `formatIsLiveOverABody`, replace the last two lines with:

```swift
    // W16: a binding is one opaque value token, and Format carries it.
    let bound = liveBinding(name: "id")
    let body = request(path: [], body: [.literal("{\"a\": "), .bound(bound), .literal("}")])
    #expect(apiFormatIsEnabled(draft: body, typed: [:]))
    guard case .object(let fields)? = apiFormatBodyWrite(draft: body, pane: "p", typed: [:]),
          case .array(let written)? = fields["body"]
    else { Issue.record("Format wrote nothing"); return }
    #expect(written.contains(apiPartJSON(.bound(bound), sources: [:])))
```

  In `ApiRowsTests.swift`, replace the two rulings tests:

```swift
@Test("W16: + query and + header stay live over a bound row")
func addingStaysLiveOverABinding() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiRowAddIsEnabled(draft(query: [ApiQueryRow(name: "a", value: [bound])]), .query))
    #expect(apiRowAddIsEnabled(draft(headers: [("x-a", [bound])]), .header))
    guard case .write(.object(let f)) = apiRowAdd(
        draft: draft(query: [ApiQueryRow(name: "a", value: [bound])]),
        region: .query, name: "b", pane: "p"),
        case .array(let rows)? = f["query"]
    else { Issue.record("no write"); return }
    #expect(rows.first == .object([
        "name": .string("a"), "value": .array([apiPartJSON(bound, sources: [:])]),
    ]))
}

@Test("× is drawn on the operator's rows, and not on a row holding a binding of its own")
func theRemoveIsDrawnOnTheOperatorsRows() {
    let d = draft(query: [ApiQueryRow(name: "a", value: [.literal("1")])],
                  headers: [("x-a", [.literal("v")])], contentType: "application/json")
    #expect(apiRowDrawsRemove(d, .query, at: 0))
    let index = d.headers.firstIndex { $0.name == "x-a" }!
    #expect(apiRowDrawsRemove(d, .header, at: index))
    let ct = d.headers.firstIndex { $0.name == "content-type" }!
    #expect(!apiRowDrawsRemove(d, .header, at: ct))
    #expect(!apiRowDrawsRemove(d, .query, at: 5))
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let mixed = draft(query: [ApiQueryRow(name: "a", value: [.literal("1")]),
                              ApiQueryRow(name: "b", value: [bound])])
    // The neighbour of a bound row is removable now; the bound row unbinds first (8b).
    #expect(apiRowDrawsRemove(mixed, .query, at: 0))
    #expect(!apiRowDrawsRemove(mixed, .query, at: 1))
}
```

  In `ApiPathQueryTests.swift`, replace `thePathBoxLocks` and `theAmpersandNote`, and add the
  Review Focus test:

```swift
@Test("W16: the path box locks only over an &, never over a binding")
func thePathBoxLocks() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o/"), bound], query: [])))
    #expect(apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("id", [bound])])))
    #expect(!apiPathBoxIsTypable(req(path: [.literal("/o")], query: [q("q", [.literal("a&b")])])))
}

@Test("The & note is drawn whenever an & locks the box, a binding or not")
func theAmpersandNote() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    #expect(apiPathBoxNote(req(path: [.literal("/o")], query: [q("q", [.literal("a&b")])]))
        == apiPathQueryAmpersandNote)
    #expect(apiPathBoxNote(req(path: [.literal("/o")], query: [q("q", [.literal("ab")])])) == nil)
    #expect(apiPathBoxNote(req(path: [bound], query: [q("q", [.literal("a&b")])]))
        == apiPathQueryAmpersandNote)
}

@Test("Review Focus 1: a bound chip cannot move between the Query region and the path")
func aBindingCannotMoveBetweenPathAndQuery() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let r = req(path: [.literal("/o")], query: [q("id", [bound])])
    #expect(apiPathQueryView(path: r.path, query: r.query) == [.literal("/o?id="), bound])
    // Deleting the `?` would parse the chip into the path.
    #expect(apiPathBoxWrite(r, edit: .text(index: 0, "/oid="), typed: [:], pane: "p")
        == .refused(ApiPathQueryRefusal.boundMoved.line))
    #expect(ApiPathQueryRefusal.boundMoved.line
        == "a bound value stays in the region it was dropped in — unbind it to move it")
    // Text beside it writes, the chip carried in its own region.
    guard case .write = apiPathBoxWrite(r, edit: .text(index: 0, "/orders?id="), typed: [:], pane: "p")
    else { Issue.record("text beside a binding was refused"); return }
}
```

  In the Ruling 23 test (the one ending `apiPathBoxNote(both) == apiPathQueryAmpersandNote`),
  replace `#expect(apiPathBoxNote(req(path: [bound, .literal("?x")], query: [])) == nil)` with
  `#expect(apiPathBoxNote(req(path: [bound, .literal("?x")], query: [])) == apiPathQuestionNote)`.

  In plan A's `ApiSaveAsTypedTests.swift`, replace `aLockedBodyIsNeverWritten` with:

```swift
@Test("W16: a body beside a binding is written, and the binding rides along unchanged")
func aBodyBesideABindingIsWritten() {
    let bound = liveBinding(name: "id")
    let r = req(body: [.bound(bound)])
    #expect(apiPendingWrite(r, box: ApiFieldRow(.body), typed: [1: "x"], pane: "p")
        == .write(.object(["pane": .string("p"), "body": .array([
            apiPartJSON(.bound(bound), sources: [:]), .object(["literal": .string("x")]),
        ])])))
}

@Test("Review Focus 1, on screen: a path box that would move a binding applies nothing")
func aBindingMoveIsNotApplied() {
    let bound = ApiPart.bound(liveBinding(name: "id"))
    let r = req(path: [.literal("/o")], query: [q("id", [bound])])
    let applied = apiRequestApplying(r, boxes: [ApiFieldRow(.path): [0: "/oid="]])
    #expect(applied.path == r.path)
    #expect(applied.query == r.query)
}
```

- [ ] **Step 2: Run them and watch them fail.**
  `make app-test 2>&1 | grep -E "error:|✘" | head -30`. Expect `boundMoved` to be undefined,
  and the W16 expectations to fail against today's locks.
- [ ] **Step 3: Implement.**
  - `ApiParts.swift`, before `apiPart`:

```swift
/// A bound value as `read_pane` publishes it, and so as a write may carry it back (W16): its
/// name, its binding's kind and its source's published fields. **Not** the pinned declared
/// type or generation, which are never published and therefore never compared. The binding
/// that lands is the one the region already held, so those two survive untouched.
struct ApiBoundIdentity: Equatable {
    let name: String
    let binding: String
    let pane: String
    let table: String
    let keyColumns: [String]
    let keyValues: [String]
    let column: String

    init(_ bound: ApiBoundValue) {
        name = bound.name
        binding = bound.binding.wireName
        pane = bound.source.pane
        table = bound.source.table
        keyColumns = bound.source.keyColumns
        keyValues = bound.source.keyValues
        column = bound.source.column
    }

    /// The identity a written part claims, or `nil` when it is not shaped like one.
    init?(json object: [String: JSONValue]) {
        guard case .string(let name)? = object["name"],
              case .string(let binding)? = object["binding"],
              case .object(let source)? = object["source"],
              case .string(let pane)? = source["pane"],
              case .string(let table)? = source["table"],
              case .string(let column)? = source["column"],
              let keyColumns = Self.strings(source["keyColumns"]),
              let keyValues = Self.strings(source["keyValues"])
        else { return nil }
        self.name = name
        self.binding = binding
        self.pane = pane
        self.table = table
        self.keyColumns = keyColumns
        self.keyValues = keyValues
        self.column = column
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let text) = item else { return nil }
            out.append(text)
        }
        return out
    }
}

/// The bindings one region already holds: what a write to that region may carry back (W16).
///
/// **Each one once.** A write that names a held binding twice is MAKING the second one, which
/// only a drop may do (Review Focus 2). **Per region**, so a binding cannot move between the
/// path and the body by being written out of one and into the other.
struct ApiHeldBindings {
    private var remaining: [ApiBoundValue]

    init(_ parts: [ApiPart]) {
        remaining = parts.compactMap { part in
            if case .bound(let bound) = part { return bound }
            return nil
        }
    }

    static var none: ApiHeldBindings { ApiHeldBindings([]) }

    /// The held binding this identity names, removed from the pool, or `nil`.
    mutating func take(_ identity: ApiBoundIdentity) -> ApiBoundValue? {
        guard let index = remaining.firstIndex(where: { ApiBoundIdentity($0) == identity })
        else { return nil }
        return remaining.remove(at: index)
    }
}
```

    Change `apiPart` to take `held: inout ApiHeldBindings`, and replace its binding branch:

```swift
    if object["binding"] != nil || object["source"] != nil {
        // W16: a write may CARRY a binding this region already holds — the same name, kind
        // and source, wherever the text around it moved it — and never MAKE one.
        if let identity = ApiBoundIdentity(json: object), let kept = held.take(identity) {
            return .bound(kept)
        }
        throw ApiActionError.boundValueIsAGesture(
            action: action, region: region, index: index)
    }
```

    Replace `apiParts` and `apiNamedRows` with an overload pair each. A loop replaces `map`,
    because an `inout` cannot be captured:

```swift
func apiParts(_ json: JSONValue, action: String, region: String) throws -> [ApiPart] {
    var none = ApiHeldBindings.none
    return try apiParts(json, action: action, region: region, held: &none)
}

func apiParts(
    _ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings
) throws -> [ApiPart] {
    guard case .array(let items) = json else {
        throw ApiActionError.notAPartList(action: action, region: region)
    }
    var parts: [ApiPart] = []
    for (index, item) in items.enumerated() {
        parts.append(try apiPart(item, action: action, region: region, index: index, held: &held))
    }
    return parts
}

func apiNamedRows(
    _ json: JSONValue, action: String, region: String
) throws -> [(name: String, value: [ApiPart])] {
    var none = ApiHeldBindings.none
    return try apiNamedRows(json, action: action, region: region, held: &none)
}

func apiNamedRows(
    _ json: JSONValue, action: String, region: String, held: inout ApiHeldBindings
) throws -> [(name: String, value: [ApiPart])] {
    guard case .array(let items) = json else {
        throw ApiActionError.notARowList(action: action, region: region)
    }
    var rows: [(name: String, value: [ApiPart])] = []
    for (index, item) in items.enumerated() {
        guard case .object(let row) = item, case .string(let name)? = row["name"] else {
            throw ApiActionError.notARow(action: action, region: region, index: index)
        }
        rows.append((name, try apiParts(
            row["value"] ?? .array([]), action: action, region: region, held: &held)))
    }
    return rows
}
```

    Keep the existing doc comments above each. Above `apiPart`, append to its doc: *"(W16)
    A binding the region already holds may be carried back — see `ApiHeldBindings`."*
  - `ApiActions.swift`, the `api_set_request` handler's decoding (`draft.path = …` through
    `draft.body = …`):

```swift
            if let path = fields["path"] {
                var held = ApiHeldBindings(draft.path)
                draft.path = try apiParts(path, action: action, region: "path", held: &held)
            }
            if let query = fields["query"] {
                var held = ApiHeldBindings(draft.query.flatMap(\.value))
                draft.query = try apiNamedRows(query, action: action, region: "query", held: &held)
                    .map { ApiQueryRow(name: $0.name, value: $0.value) }
            }
            if let headers = fields["headers"] {
                var held = ApiHeldBindings(draft.headers.flatMap(\.value))
                draft.headers = try apiNamedRows(
                    headers, action: action, region: "headers", held: &held)
                    .map { ApiHeaderRow(name: $0.name, value: $0.value) }
            }
```

    The same applies to `body`, with `ApiHeldBindings(draft.body)`. In the description, replace
    *"A bound value CANNOT be written here: it pins provenance recorded at the moment a row was
    dropped, so writing one back from read_pane would invent it."* with *"A bound value cannot
    be MADE here: it pins provenance recorded at the moment a row was dropped. A write may
    CARRY one the same region already holds — name, binding and source exactly as read_pane
    published them — anywhere in that region, so the text around a chip can be rewritten; each
    held binding once, and any other bound part is refused (api_bind is the gesture)."*
    Replace `boundValueIsAGesture`'s text with:

```swift
        case .boundValueIsAGesture(let action, let region, let index):
            return "\(action): \(region) part \(index) is a bound value this region does not "
                + "hold. A binding is made by dropping a row on a hole — never by writing one: "
                + "it pins the source column's declared type and the source pane's generation "
                + "at the moment of the drop, and read_pane publishes neither. A write may "
                + "carry back a binding the same region already holds, exactly as read_pane "
                + "published it and once; to make a new one, write a slot here and fill it "
                + "with api_bind."
```

    Replace `apiFieldIsTypable`'s body and doc:

```swift
/// Whether a field can be typed into. **Always, since W16** (Amendment 9c): a bound value
/// locks only itself. It is drawn as a chip, which is not a box, and every write carries it
/// back (`ApiHeldBindings` admits it). Amendment 2's region lock is superseded. Kept as the
/// one place the rule is stated, because the view and `ApiSaveAsTyped` ask it.
public func apiFieldIsTypable(_ request: ApiRequestSnapshot, _ field: ApiDraftField) -> Bool {
    true
}
```

    In `apiPartsWrite`, replace the `let written: [JSONValue] = parts.map { … }` block with
    `let written = parts.map { apiPartJSON($0, sources: [:]) }`. In its doc, replace the
    paragraph *"A bound part is never carried …"* with *"**A bound part is carried as
    published** (W16): `api_set_request` admits a binding its region already holds."*
  - `ApiRows.swift`, `apiRowDrawsRemove`:

```swift
public func apiRowDrawsRemove(
    _ request: ApiRequestSnapshot, _ region: ApiRowRegion, at index: Int
) -> Bool {
    switch region {
    case .query:
        guard request.query.indices.contains(index) else { return false }
        // W16: a neighbour of a binding is removable; the bound row itself unbinds first (8b).
        return apiRowIsTypable(request.query[index].value)
    case .header:
        guard request.headers.indices.contains(index),
              request.headers[index].rowClass == .authored
        else { return false }
        return apiRowIsTypable(request.headers[index].value ?? [])
    }
}
```

    Rewrite the doc: *"The operator's own rows only … and **not a row that holds a binding of
    its own** (8b): that row's chip unbinds first. Since W16 a binding no longer locks its
    neighbours."* In `apiRowAddIsEnabled`'s doc, replace the Amendment 2 paragraph with *"Live
    over a bound row too, since W16: the add carries the binding back."*
  - `ApiPathQuery.swift`:

```swift
public func apiPathBoxIsTypable(_ request: ApiRequestSnapshot) -> Bool {
    // W16: a binding no longer locks the box. Only an `&` in a query value does (8d).
    apiPathQueryRoundTrips(request.query)
}
```

    In `apiPathBoxNote`, delete the `let unbound = …` and `guard unbound else { return nil }`
    lines, and the doc sentence *"Neither over a bound value …"*. Add to
    `ApiPathQueryRefusal`:

```swift
    case holeInName, namelessRow, forbiddenInName(Character), boundMoved
    // in `line`:
        case .boundMoved:
            return "a bound value stays in the region it was dropped in — unbind it to move it"
```

    Add next to `apiPathBoxWrite`:

```swift
/// Whether a path-box parse keeps every binding in the region it came from (W16): the path's
/// in the path, the query's in the query. `api_set_request` refuses a binding its region does
/// not hold, so a parse that moved one is refused here, on screen, rather than as a dispatch
/// error the operator never sees (Review Focus 1).
public func apiPathBoxKeepsItsBindings(
    _ request: ApiRequestSnapshot, path: [ApiPart], query: [ApiQueryRow]
) -> Bool {
    func stay(_ written: [ApiPart], within held: [ApiPart]) -> Bool {
        var pool = ApiHeldBindings(held)
        return written.allSatisfy { part in
            guard case .bound(let bound) = part else { return true }
            return pool.take(ApiBoundIdentity(bound)) != nil
        }
    }
    return stay(path, within: request.path)
        && stay(query.flatMap(\.value), within: request.query.flatMap(\.value))
}
```

    In `apiPathBoxWrite`'s `.success(var parsed)` branch, right after the `if let hole` line:

```swift
        guard apiPathBoxKeepsItsBindings(request, path: parsed.path, query: parsed.query) else {
            return .refused(ApiPathQueryRefusal.boundMoved.line)
        }
```

    In `apiPathQueryWrite`'s doc, replace the paragraph *"A bound part never reaches this …"*
    with *"A bound part is carried as published (W16); `apiPathBoxKeepsItsBindings` has
    already kept it in its own region."*
  - `ApiBodyFormat.swift`, in `apiFormatBodyWrite`:

```swift
    let written: [JSONValue] = formatted.compactMap { part in
        if case .literal(let text) = part, text.isEmpty { return nil }
        // W16: a binding is carried as published; `api_set_request` admits it.
        return apiPartJSON(part, sources: [:])
    }
```

    In `apiFormatIsEnabled`'s doc, replace the bound-value sentence with *"Since W16 a binding
    does not stop it: the binding is one value token, carried."*
  - Plan A's `ApiSaveAsTyped.swift`, in `apiRequestApplying`'s `case .path:` guard, add one
    clause:

```swift
            guard apiPathBoxIsTypable(request),
                  case .success(let parsed) = apiPathQueryParse(
                      apiTyped(apiPathQueryView(path: request.path, query: request.query), typed)),
                  apiPathBoxKeepsItsBindings(request, path: parsed.path, query: parsed.query)
            else { continue }
```

  - The view (`ApiPane+Request.swift` / `ApiPane+Fields.swift`). Comments only, no code
    change:
    - In `queryRegion`, replace the comment *"Locked whole when any row of the region is bound
      (Amendment 2) …"* with *"W16: a bound value locks only itself — the row's other boxes
      and its neighbours stay typable, and every write carries the chip back."*
    - In `bodyRegion`, replace the comment *"Locked while it holds a bound value …"* with the
      same sentence.
    - In `fieldFlow`'s doc, replace *"Locked whole or not at all (`apiFieldIsTypable`) …"*
      with *"A chip is not a box, so a bound value locks only itself (W16). Only the path box
      can still be read-only, over an `&` (8d)."*
- [ ] **Step 4: Run and watch it pass.** Run `make app-test` and `make app-bundle`. Then run
  `grep -rn "Amendment 2" app/Sources`: every remaining hit must say *superseded*.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit/Api app/Sources/WakilApp app/Tests/WakilKitTests
git commit -m "A bound value locks only itself: api_set_request carries a binding its region holds, once, and never makes one (W16)"
```

---

## Phase 2 — editing around a chip

### Task 3: Backspace and Delete on a chip, and the `×` inside it (W4)

Backspace just after a chip, or Delete just before one, does what the chip's `×` does. An
unfilled hole is removed. A bound value is unbound back to its hole, and a second press removes
that hole. The ruling is `apiChipBeside` plus `apiChipKeyApplies` (the caret must be at the
box's edge with nothing selected).

The keys are caught at the AppKit level:
- **Single-line boxes:** an `NSEvent` local monitor that is live only while that box has focus
  (`ChipKeyCatcher`). SwiftUI does not expose a `TextField`'s selection on macOS 14, and the
  field editor handles Delete before `.onKeyPress` would see it.
- **The body:** `BodyNSTextView` overrides `deleteBackward(_:)` and `deleteForward(_:)`.

The unbind is sent as `apiChipUnbindParams`, which finds **the same chip by its ordinal among
chips** in the request the flush will leave behind. This fixes Review Focus 3 for the `×` as
well.

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiChipKeys.swift`
- Create: `app/Sources/WakilApp/ApiChipKeys.swift` (`ChipKeyCatcher`)
- Modify: `app/Sources/WakilApp/ApiBodyTextView.swift`. Add `chipBackspace`, `chipDelete`,
  `import WakilKit`, and the `BodyNSTextView` overrides.
- Modify: `app/Sources/WakilApp/ApiPane+Fields.swift`. Add `chipGesture`, put the `×` inside
  `chip`, and plumb the keys through `literalBox` / `field` / `lineBox` / `editorBox`.
- Modify: `app/Sources/WakilApp/ApiPane+Sending.swift`. `boundValues` calls
  `chip(_:filled:)`, which stays as the read-only form.
- Test: `app/Tests/WakilKitTests/ApiChipKeysTests.swift` (create)

**Interfaces:**
- Consumes: plan A's `apiRequestApplying`, `operateFlushed`, `write`, `pathWrite`;
  `apiPathQueryOrigin`, `apiUnbindParams`, `apiFieldParts`, `apiPathQueryView`.
- Produces:
  ```swift
  public enum ApiChipKey: Sendable { case backspace, delete }
  public enum ApiChipAct: Equatable, Sendable { case remove, unbind }
  public struct ApiChipTarget: Equatable, Sendable { public let index: Int; public let act: ApiChipAct }
  public func apiChipAct(_ part: ApiPart) -> ApiChipAct?
  public func apiChipBeside(_ parts: [ApiPart], box: Int, key: ApiChipKey) -> ApiChipTarget?
  public func apiChipKeyApplies(_ key: ApiChipKey, selectionLocation: Int, selectionLength: Int, textLength: Int) -> Bool
  public func apiChipUnbindParams(_ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]], field: ApiDraftField, row: Int, index: Int, pane: String) -> JSONValue?
  // view (ApiPane+Fields.swift)
  func chipGesture(_ box: ApiFieldRow, index: Int, act: ApiChipAct)
  ```

- [ ] **Step 1: Write the failing tests** in `ApiChipKeysTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// W4: Backspace just after a chip, or Delete just before one, acts as its `×`.

private let bound = ApiPart.bound(liveBinding(name: "v"))

@Test("Backspace acts on the chip before its box; Delete on the chip after it")
func theChipBesideTheCaret() {
    let parts: [ApiPart] = [.literal("/a/"), .slot("id"), .literal("/b"), bound]
    #expect(apiChipBeside(parts, box: 2, key: .backspace) == ApiChipTarget(index: 1, act: .remove))
    // The trailing box after the last part is box `parts.count`.
    #expect(apiChipBeside(parts, box: 4, key: .backspace) == ApiChipTarget(index: 3, act: .unbind))
    #expect(apiChipBeside(parts, box: 0, key: .delete) == ApiChipTarget(index: 1, act: .remove))
    #expect(apiChipBeside(parts, box: 2, key: .delete) == ApiChipTarget(index: 3, act: .unbind))
    #expect(apiChipBeside(parts, box: 0, key: .backspace) == nil)
    #expect(apiChipBeside(parts, box: 4, key: .delete) == nil)
}

@Test("A literal beside the box is text, not a chip: the key does what it always did")
func aLiteralIsNotAChip() {
    #expect(apiChipBeside([.literal("a"), .literal("b")], box: 1, key: .backspace) == nil)
    #expect(apiChipAct(.literal("a")) == nil)
    #expect(apiChipAct(.slot("id")) == .remove)
    #expect(apiChipAct(bound) == .unbind)
}

@Test("Only a caret at the box's edge with nothing selected reaches the chip")
func onlyACaretAtTheEdge() {
    #expect(apiChipKeyApplies(.backspace, selectionLocation: 0, selectionLength: 0, textLength: 4))
    #expect(!apiChipKeyApplies(.backspace, selectionLocation: 1, selectionLength: 0, textLength: 4))
    // A selection is deleted as text, never the chip beside it.
    #expect(!apiChipKeyApplies(.backspace, selectionLocation: 0, selectionLength: 4, textLength: 4))
    #expect(apiChipKeyApplies(.delete, selectionLocation: 4, selectionLength: 0, textLength: 4))
    #expect(!apiChipKeyApplies(.delete, selectionLocation: 3, selectionLength: 0, textLength: 4))
    // An empty box is at both edges.
    #expect(apiChipKeyApplies(.backspace, selectionLocation: 0, selectionLength: 0, textLength: 0))
    #expect(apiChipKeyApplies(.delete, selectionLocation: 0, selectionLength: 0, textLength: 0))
}

private func snap(path: [ApiPart], query: [ApiQueryRow] = [], body: [ApiPart] = []) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "POST", origin: nil, path: path, query: query,
                       headers: ApiRequestSnapshot.empty.headers, body: body)
}

@Test("Review Focus 3: an unbind after an emptied box targets the same chip")
func anUnbindAfterAnEmptiedBoxTargetsTheSameChip() {
    let r = snap(path: [.literal("/a/"), bound, .literal("/x")])
    // The operator emptied the first box. The flush drops that literal, so the chip is at 0.
    let params = apiChipUnbindParams(
        r, boxes: [ApiFieldRow(.path): [0: ""]], field: .path, row: 0, index: 1, pane: "p")
    #expect(params == apiUnbindParams(field: .path, index: 0, pane: "p"))
    // Nothing typed: the drawn index, mapped through the view.
    #expect(apiChipUnbindParams(r, boxes: [:], field: .path, row: 0, index: 1, pane: "p")
        == apiUnbindParams(field: .path, index: 1, pane: "p"))
}

@Test("A chip the path box draws from a query value unbinds in its row")
func aQueryChipInThePathBoxUnbindsInItsRow() {
    let r = snap(path: [.literal("/o")], query: [ApiQueryRow(name: "id", value: [bound])])
    #expect(apiChipUnbindParams(r, boxes: [:], field: .path, row: 0, index: 1, pane: "p")
        == apiUnbindParams(field: .query("id"), index: 0, pane: "p", row: 0))
}

@Test("A body chip unbinds by its index in the body; a slot is not unbound")
func aBodyChipUnbinds() {
    let r = snap(path: [], body: [.literal("{\"a\": "), bound, .literal("}")])
    #expect(apiChipUnbindParams(r, boxes: [:], field: .body, row: 0, index: 1, pane: "p")
        == apiUnbindParams(field: .body, index: 1, pane: "p"))
    #expect(apiChipUnbindParams(
        snap(path: [.slot("x")]), boxes: [:], field: .path, row: 0, index: 0, pane: "p") == nil)
}
```

- [ ] **Step 2: Run and watch them fail** (`cannot find 'apiChipBeside' in scope`).
- [ ] **Step 3: Implement the WakilKit half** in `ApiChipKeys.swift`:

```swift
import Foundation

/// W4 (Amendment 9c): **Backspace just after a chip, or Delete just before one, acts as its
/// `×`.** An unfilled hole is removed. A bound value is unbound back to its hole, and a second
/// press removes that. The keys are the `×` gesture under another name, so they are built from
/// the same rulings and travel through the same flush (9a).

public enum ApiChipKey: Sendable { case backspace, delete }

/// What a chip's `×` does, and so what its key does.
public enum ApiChipAct: Equatable, Sendable { case remove, unbind }

/// The chip a key reaches: its index among the drawn parts, and what it does there.
public struct ApiChipTarget: Equatable, Sendable {
    public let index: Int
    public let act: ApiChipAct

    public init(index: Int, act: ApiChipAct) {
        self.index = index
        self.act = act
    }
}

/// `remove` for a hole, `unbind` for a bound value, `nil` for text.
public func apiChipAct(_ part: ApiPart) -> ApiChipAct? {
    switch part {
    case .literal: return nil
    case .slot: return .remove
    case .bound: return .unbind
    }
}

/// The chip beside box `box`. Box indices are the drawn parts' indices, and the trailing box
/// after a last chip is `parts.count`. Backspace reaches the part before the box, Delete the
/// part after it. `nil` when that part is text, or there is none, and the key then does what
/// it always did.
public func apiChipBeside(_ parts: [ApiPart], box: Int, key: ApiChipKey) -> ApiChipTarget? {
    let index = key == .backspace ? box - 1 : box + 1
    guard parts.indices.contains(index), let act = apiChipAct(parts[index]) else { return nil }
    return ApiChipTarget(index: index, act: act)
}

/// Whether the key reaches past the box's text to the chip: **a caret at the box's edge with
/// nothing selected**. Backspace at the start, Delete at the end. A selection is deleted as
/// text, as everywhere. An empty box is at both edges. Lengths are UTF-16, as AppKit counts
/// them.
public func apiChipKeyApplies(
    _ key: ApiChipKey, selectionLocation: Int, selectionLength: Int, textLength: Int
) -> Bool {
    guard selectionLength == 0 else { return false }
    return key == .backspace ? selectionLocation == 0 : selectionLocation == textLength
}

/// The `api_unbind` a chip's `×` or key sends: **the same chip, found by its ordinal among
/// the chips**, in the request the flush in front of it will leave behind (Review Focus 3).
///
/// The flush drops a box the operator emptied, which moves every later part down by one, so
/// the drawn index would unbind the wrong part. Typing never adds, removes or reorders a chip,
/// so the n-th chip drawn is the n-th chip after the flush. For the path box, the view's index
/// is mapped back to its field and row by `apiPathQueryOrigin`. `nil` when the part is not a
/// binding, and nothing is sent.
public func apiChipUnbindParams(
    _ request: ApiRequestSnapshot, boxes: [ApiFieldRow: [Int: String]],
    field: ApiDraftField, row: Int, index: Int, pane: String
) -> JSONValue? {
    func drawn(_ r: ApiRequestSnapshot) -> [ApiPart] {
        field == .path
            ? apiPathQueryView(path: r.path, query: r.query)
            : apiFieldParts(r, field, row: row)
    }
    func chipIndices(_ parts: [ApiPart]) -> [Int] {
        parts.indices.filter { apiChipAct(parts[$0]) != nil }
    }
    let before = drawn(request)
    guard before.indices.contains(index), apiChipAct(before[index]) == .unbind,
          let ordinal = chipIndices(before).firstIndex(of: index)
    else { return nil }
    let applied = apiRequestApplying(request, boxes: boxes)
    let after = chipIndices(drawn(applied))
    guard after.indices.contains(ordinal) else { return nil }
    let at = after[ordinal]
    if field == .path {
        guard let origin = apiPathQueryOrigin(
            path: applied.path, query: applied.query, viewIndex: at)
        else { return nil }
        return apiUnbindParams(field: origin.field, index: origin.index, pane: pane, row: origin.row)
    }
    return apiUnbindParams(field: field, index: at, pane: pane, row: row)
}
```

- [ ] **Step 4: Run the WakilKit tests.** `make app-test 2>&1 | grep -E "ApiChipKeys|error:"`.
  They must pass.
- [ ] **Step 5: The key catcher** (`app/Sources/WakilApp/ApiChipKeys.swift`):

```swift
import AppKit
import WakilKit
import SwiftUI

/// W4: Backspace and Delete on a chip, from a single-line box.
///
/// **An `NSEvent` local monitor, live only while its box has focus.** SwiftUI does not expose
/// a `TextField`'s selection on macOS 14, and the field editor turns Delete into
/// `deleteBackward:` before `.onKeyPress` sees it. The monitor runs before the field editor,
/// reads the editor's own selection, and swallows the key only when `apiChipKeyApplies` says
/// it reaches the chip. Otherwise the key is untouched.
///
/// **No identifier, and not an accessibility element.** It is a zero-size background, and it
/// must not add a node to the tree the checks read.
struct ChipKeyCatcher: NSViewRepresentable {
    let active: Bool
    let backspace: (() -> Void)?
    let delete: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setActive(active && (backspace != nil || delete != nil))
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator {
        var parent: ChipKeyCatcher
        private var monitor: Any?

        init(_ parent: ChipKeyCatcher) { self.parent = parent }

        func setActive(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
            } else if !on, let installed = monitor {
                NSEvent.removeMonitor(installed)
                monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // 51 is Delete (backspace), 117 Forward Delete (fn-Delete).
            let key: ApiChipKey
            switch event.keyCode {
            case 51: key = .backspace
            case 117: key = .delete
            default: return event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad])
            guard modifiers.isEmpty,
                  let editor = event.window?.firstResponder as? NSTextView
            else { return event }
            let selection = editor.selectedRange()
            guard apiChipKeyApplies(
                key, selectionLocation: selection.location, selectionLength: selection.length,
                textLength: (editor.string as NSString).length),
                let act = key == .backspace ? parent.backspace : parent.delete
            else { return event }
            act()
            return nil
        }
    }
}
```

- [ ] **Step 6: The body's keys.** In `ApiBodyTextView.swift`, add `import WakilKit`. After
  `focusChanged` (plan A), add:

```swift
    /// W4: Backspace at the box's start, Delete at its end, when a chip sits there. `nil` when
    /// none does.
    var chipBackspace: (() -> Void)? = nil
    var chipDelete: (() -> Void)? = nil
```

  In `BodyNSTextView`, add:

```swift
    /// W4: past the box's edge is a chip, and the key is the chip's `×`. Anywhere else the
    /// text system deletes as it always has.
    override func deleteBackward(_ sender: Any?) {
        if let act = chipKey(.backspace) { act(); return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if let act = chipKey(.delete) { act(); return }
        super.deleteForward(sender)
    }

    private func chipKey(_ key: ApiChipKey) -> (() -> Void)? {
        let selection = selectedRange()
        guard apiChipKeyApplies(
            key, selectionLocation: selection.location, selectionLength: selection.length,
            textLength: (string as NSString).length)
        else { return nil }
        return key == .backspace ? coordinator?.parent.chipBackspace : coordinator?.parent.chipDelete
    }
```

- [ ] **Step 7: Wire the view** (`ApiPane+Fields.swift`).
  - One gesture for the `×` and both keys:

```swift
    /// A chip's one act — its `×`, Backspace after it, Delete before it (W4). Removal goes
    /// through `write` / `pathWrite`, which carry the boxes against the drawn indices. The
    /// unbind is `apiChipUnbindParams`, so it finds the same chip after the flush.
    func chipGesture(_ box: ApiFieldRow, index: Int, act: ApiChipAct) {
        switch act {
        case .remove:
            if box.field == .path { pathWrite(.remove(index: index)) } else {
                write(box, .remove(index: index))
            }
        case .unbind:
            guard let params = apiChipUnbindParams(
                snapshot.request, boxes: boxes, field: box.field, row: box.row, index: index,
                pane: pane.id)
            else { return }
            operateFlushed([("api_unbind", params)])
        }
    }
```

  - **The `×` moves inside the chip.** Replace `chip(_:filled:)` with two overloads, and give
    `chipButton` a tone:

```swift
    /// A hole or a bound value, as a chip under its own name: an unfilled hole in amber on an
    /// amber tint, a filled one in the pane's ink on a cool-white tint. **Its `×` sits inside
    /// it, at its right edge** (W4), so the chip and its control are one shape.
    func chip<Close: View>(
        _ name: String, filled: Bool, @ViewBuilder close: () -> Close
    ) -> some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            close()
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(filled ? SettingsPalette.coolWhite.opacity(0.10) : amber.opacity(0.10)))
        .foregroundStyle(filled ? ink.opacity(0.85) : amber)
        .fixedSize()
    }

    /// The read-only chip: Wakil's rows, the Bound list.
    func chip(_ name: String, filled: Bool) -> some View {
        chip(name, filled: filled) { EmptyView() }
            .padding(.trailing, 2)
    }

    /// A chip's `×`. **A `Button`, so the identifier is on something `AXPress` reaches.** It
    /// is drawn in the chip's own tone, quieter.
    func chipButton(
        _ identifier: String, tone: Color, action: @escaping () -> Void
    ) -> some View {
        Button("×", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tone.opacity(0.55))
            .accessibilityIdentifier(identifier)
    }
```

  - In `fieldFlow`, the `.slot` and `.bound` cases become one chip each, with the `×` inside.
    The identifier literals stay at the call site, so the harvester still reads them:

```swift
                case .slot(let name):
                    chip(name, filled: false) {
                        if field.typable {
                            chipButton("api.\(field.key).part.\(index).remove", tone: amber) {
                                chipGesture(field.box, index: index, act: .remove)
                            }
                        }
                    }
                case .bound(let value):
                    // **The unbind `×`, drawn always** (spec §3): this is how it unbinds.
                    chip(value.name, filled: true) {
                        chipButton("api.\(field.key).part.\(index).unbind", tone: ink) {
                            chipGesture(field.box, index: index, act: .unbind)
                        }
                    }
```

  - `literalBox` computes the two keys and hands them down:

```swift
        let backspace = apiChipBeside(parts, box: index, key: .backspace).map { target in
            { chipGesture(box, index: target.index, act: target.act) }
        }
        let delete = apiChipBeside(parts, box: index, key: .delete).map { target in
            { chipGesture(box, index: target.index, act: target.act) }
        }
```

    It passes `backspace: backspace, delete: delete` to `field(…)`. `field`, `lineBox` and
    `editorBox` each gain `backspace: (() -> Void)?` and `delete: (() -> Void)?`.
    - `lineBox` adds `.background(ChipKeyCatcher(active: focusedBox == identifier,
      backspace: backspace, delete: delete))` after `.focused($focusedBox, equals: identifier)`.
    - `editorBox` passes `chipBackspace: backspace, chipDelete: delete` to `ApiBodyTextView`.
    - The content-type field passes `nil` for both.
  - In `ApiPane+Request.swift`, `removeControl`'s row `×` passes `tone: ink`:
    `chipButton(identifier, tone: ink) { … }`. Its identifier literals are unchanged.
  - In `ApiPane+Sending.swift`, `boundValues` still calls `chip(row.element.name,
    filled: true)`. That resolves to the read-only overload. Task 5 replaces the row anyway.
- [ ] **Step 8: Run.** `make app-test`, `make app-bundle` and `make controls`. The harvest
  must still list `api.<…>.part.<…>.remove` and `.unbind`. Then
  `grep -n "\"api_unbind\"" app/Sources/WakilApp` must hit only `chipGesture`, because every
  unbind (the `×` and both keys) now goes through it.
- [ ] **Step 9: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiChipKeys.swift app/Sources/WakilApp \
  app/Tests/WakilKitTests/ApiChipKeysTests.swift
git commit -m "Backspace after a chip and Delete before one act as its ×, which now sits inside the chip; an unbind finds the same chip after the flush (W4)"
```

### Task 4: Body `+ HOLE` lands at the cursor (W7)

The walk's hole landed after the closing `}`, which made the body not JSON. The body remembers
its caret: the box (a literal's index, or the trailing box) and the UTF-16 offset in it,
reported by the text view while it is first responder. `+ HOLE` splits that literal there. It
appends at the end only when the body has never had focus, or when the remembered box no
longer exists (Review Focus 4).

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiBodyCaret.swift`
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Add `ApiPartsEdit.insertHole`, and its
  arm in `apiPartsWrite`.
- Modify: `app/Sources/WakilKit/Api/ApiPathQuery.swift`. `apiPathBoxWrite`'s `switch edit`
  answers `.insertHole` with `.nothing`, because the path box has no caret ruling.
- Modify: `app/Sources/WakilApp/ApiBodyTextView.swift`. Add `caretMoved`, and
  `textViewDidChangeSelection`.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. Add `@State var bodyCaret: ApiBodyCaret?`.
- Modify: `app/Sources/WakilApp/ApiPane+Fields.swift`. Body boxes report their caret, and
  `holeWrite` uses `apiBodyHoleEdit`.
- Test: `app/Tests/WakilKitTests/ApiBodyHoleTests.swift` (create)

**Interfaces:**
- Consumes: `apiPartsWrite`, `apiTyped`, plan A's `holeWrite` (built on
  `apiRequestApplying(…, except: box)` and dispatched through `operateFlushed`).
- Produces:
  ```swift
  case ApiPartsEdit.insertHole(String, index: Int, utf16Offset: Int)
  public struct ApiBodyCaret: Equatable, Sendable { public let box: Int; public let utf16Offset: Int }
  func apiSplit(_ text: String, utf16Offset: Int) -> (before: String, after: String)
  public func apiBodyHoleEdit(_ name: String, caret: ApiBodyCaret?, body: [ApiPart], typed: [Int: String]) -> ApiPartsEdit
  public func apiCaretAfterHole(_ caret: ApiBodyCaret, body: [ApiPart], typed: [Int: String]) -> ApiBodyCaret
  ```

- [ ] **Step 1: Write the failing tests** in `ApiBodyHoleTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// W7: body `+ HOLE` inserts at the cursor, and at the end only if the body never had focus.

private func body(_ parts: [ApiPart]) -> ApiRequestSnapshot {
    ApiRequestSnapshot(method: "POST", origin: nil, path: [], query: [],
                       headers: ApiRequestSnapshot.empty.headers, body: parts)
}

private func bodyParts(_ json: JSONValue?) -> [JSONValue]? {
    guard case .object(let f)? = json, case .array(let parts)? = f["body"] else { return nil }
    return parts
}

private func lit(_ text: String) -> JSONValue { .object(["literal": .string(text)]) }
private func slot(_ name: String) -> JSONValue { .object(["slot": .string(name)]) }

@Test("The hole splits the literal at the caret")
func theHoleLandsAtTheCaret() {
    let parts: [ApiPart] = [.literal("{\"a\":1}")]
    let edit = apiBodyHoleEdit("id", caret: ApiBodyCaret(box: 0, utf16Offset: 6), body: parts, typed: [:])
    #expect(edit == .insertHole("id", index: 0, utf16Offset: 6))
    #expect(bodyParts(apiPartsWrite(draft: body(parts), field: .body, edit: edit, pane: "p"))
        == [lit("{\"a\":1"), slot("id"), lit("}")])
}

@Test("Never focused: the hole is appended, as before")
func neverFocusedAppends() {
    #expect(apiBodyHoleEdit("id", caret: nil, body: [.literal("{}")], typed: [:]) == .appendHole("id"))
}

@Test("Review Focus 4: a stale caret falls back to the end, never to a guess")
func aStaleCaretFallsBackToTheEnd() {
    // An agent rewrote the body; box 2 is now a chip, and box 7 is nowhere.
    let parts: [ApiPart] = [.literal("{"), .slot("x"), .slot("y")]
    #expect(apiBodyHoleEdit("id", caret: ApiBodyCaret(box: 2, utf16Offset: 0), body: parts, typed: [:])
        == .appendHole("id"))
    #expect(apiBodyHoleEdit("id", caret: ApiBodyCaret(box: 7, utf16Offset: 0), body: parts, typed: [:])
        == .appendHole("id"))
    // And a blank name is still the blank-name refusal, whichever edit it is.
    #expect(apiPartsWrite(draft: body(parts), field: .body,
                          edit: .insertHole(" ", index: 0, utf16Offset: 1), pane: "p") == nil)
}

@Test("The caret counts typed text, and the trailing box is a place to insert")
func theCaretCountsTypedText() {
    // Nothing committed yet: the trailing box holds "xy" and the caret sits between.
    let edit = apiBodyHoleEdit("id", caret: ApiBodyCaret(box: 0, utf16Offset: 1), body: [], typed: [0: "xy"])
    #expect(bodyParts(apiPartsWrite(draft: body([]), field: .body, edit: edit, pane: "p", typed: [0: "xy"]))
        == [lit("x"), slot("id"), lit("y")])
}

@Test("An offset inside a surrogate pair splits before the character, never through it")
func aSurrogatePairIsNeverSplit() {
    func split(_ text: String, _ offset: Int) -> [String] {
        let parts = apiSplit(text, utf16Offset: offset)
        return [parts.before, parts.after]
    }
    #expect(split("a😀b", 3) == ["a😀", "b"])
    #expect(split("a😀b", 2) == ["a", "😀b"])
    #expect(split("ab", 9) == ["ab", ""])
    #expect(split("ab", -1) == ["", "ab"])
}

@Test("After the insert the caret sits just after the new hole")
func theCaretMovesPastTheHole() {
    #expect(apiCaretAfterHole(ApiBodyCaret(box: 0, utf16Offset: 6), body: [.literal("{\"a\":1}")], typed: [:])
        == ApiBodyCaret(box: 2, utf16Offset: 0))
    // At offset 0 the empty `before` is dropped, so the slot is part 0 and the caret box 1.
    #expect(apiCaretAfterHole(ApiBodyCaret(box: 0, utf16Offset: 0), body: [.literal("{}")], typed: [:])
        == ApiBodyCaret(box: 1, utf16Offset: 0))
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
  - In `ApiActions.swift`, add a case to `ApiPartsEdit`:

```swift
    /// Body `+ HOLE` at the caret (W7): the literal at `index` split at `utf16Offset`, the
    /// slot between. Past the last part, it appends.
    case insertHole(String, index: Int, utf16Offset: Int)
```

    In `apiPartsWrite`'s `switch edit`:

```swift
    case .insertHole(let name, let index, let offset):
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if index >= parts.count {
            parts.append(.slot(name))
        } else if case .literal(let text) = parts[index] {
            let split = apiSplit(text, utf16Offset: offset)
            parts.replaceSubrange(index...index, with: [
                .literal(split.before), .slot(name), .literal(split.after),
            ])
        } else {
            // A chip is not a box; `apiBodyHoleEdit` never sends this.
            return nil
        }
```

    Then `grep -rn "case .remove" app/Sources/WakilKit/Api` and add an `.insertHole` arm to
    every other exhaustive `switch` over `ApiPartsEdit`. That is `apiPathBoxWrite`, with
    `case .insertHole: return .nothing`.
  - `ApiBodyCaret.swift`:

```swift
import Foundation

/// W7 (Amendment 9c): **body `+ HOLE` inserts at the cursor**, and at the end only if the body
/// has never had focus. The walk's hole landed after the closing `}` and made the body not
/// JSON.

/// Where the body's caret last was: the box (a literal's index among the body's parts, or
/// `parts.count` for the trailing box) and the UTF-16 offset in it, as `NSTextView` counts.
public struct ApiBodyCaret: Equatable, Sendable {
    public let box: Int
    public let utf16Offset: Int

    public init(box: Int, utf16Offset: Int) {
        self.box = box
        self.utf16Offset = utf16Offset
    }
}

/// `text` split at a UTF-16 offset, clamped to the text and rounded down to a character
/// boundary, so a surrogate pair is never cut.
func apiSplit(_ text: String, utf16Offset: Int) -> (before: String, after: String) {
    var consumed = 0
    var cut = text.startIndex
    for index in text.indices {
        let width = text[index].utf16.count
        guard consumed + width <= utf16Offset else { break }
        consumed += width
        cut = text.index(after: index)
    }
    return (String(text[..<cut]), String(text[cut...]))
}

/// What body `+ HOLE` writes: at the caret when there is one and its box still exists, and
/// appended otherwise. **A stale caret falls back to the end** (Review Focus 4). An agent's
/// rewrite or a merged write can leave the remembered box on a chip or past the end, and a
/// guess there would put the hole somewhere the operator never pointed.
public func apiBodyHoleEdit(
    _ name: String, caret: ApiBodyCaret?, body: [ApiPart], typed: [Int: String]
) -> ApiPartsEdit {
    let parts = apiTyped(body, typed)
    guard let caret else { return .appendHole(name) }
    if caret.box == parts.count { return .insertHole(name, index: caret.box, utf16Offset: 0) }
    guard parts.indices.contains(caret.box), case .literal = parts[caret.box] else {
        return .appendHole(name)
    }
    return .insertHole(name, index: caret.box, utf16Offset: caret.utf16Offset)
}

/// Where the caret is once the hole is written: at the start of the box right after it.
/// `apiPartsWrite` drops empty literals, so an empty `before` does not count.
public func apiCaretAfterHole(
    _ caret: ApiBodyCaret, body: [ApiPart], typed: [Int: String]
) -> ApiBodyCaret {
    let parts = apiTyped(body, typed)
    let kept = parts.prefix(caret.box).filter { part in
        if case .literal(let text) = part { return !text.isEmpty }
        return true
    }.count
    var beforeIsEmpty = true
    if parts.indices.contains(caret.box), case .literal(let text) = parts[caret.box] {
        beforeIsEmpty = apiSplit(text, utf16Offset: caret.utf16Offset).before.isEmpty
    }
    return ApiBodyCaret(box: kept + (beforeIsEmpty ? 0 : 1) + 1, utf16Offset: 0)
}
```

- [ ] **Step 4: Run the WakilKit tests.** They must pass.
- [ ] **Step 5: Wire the view.**
  - In `ApiBodyTextView.swift`, after `chipDelete`, add
    `var caretMoved: ((Int) -> Void)? = nil`. In the `Coordinator`, add:

```swift
        /// W7: the caret's UTF-16 offset, reported **only while this box is first responder**.
        /// Setting `string` in `updateNSView` moves the selection too, and that is not the
        /// operator's caret. Deferred one turn, for plan A's focus reason: a selection change
        /// can arrive during a SwiftUI update.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView.window?.firstResponder === textView,
                  let caretMoved = parent.caretMoved
            else { return }
            let location = textView.selectedRange().location
            DispatchQueue.main.async { caretMoved(location) }
        }
```

  - In `ApiPane.swift`, add:

```swift
    /// W7: where the body's caret last was, or `nil` while the body has never had focus.
    @State var bodyCaret: ApiBodyCaret?
```

  - In `ApiPane+Fields.swift`, `editorBox` gains `caretMoved: ((Int) -> Void)?` and passes
    it to `ApiBodyTextView`. `literalBox` passes
    `caretMoved: box.field == .body ? { bodyCaret = ApiBodyCaret(box: index, utf16Offset: $0) } : nil`
    through `field(…)`. The single-line path ignores it.
  - `holeWrite` (plan A's version) chooses the edit by field:

```swift
    func holeWrite(_ box: ApiFieldRow, _ name: String) -> String? {
        let typed = boxes[box] ?? [:]
        let edit: ApiPartsEdit = box.field == .body
            ? apiBodyHoleEdit(name, caret: bodyCaret, body: snapshot.request.body, typed: typed)
            : .appendHole(name)
        guard let params = apiPartsWrite(
            draft: apiRequestApplying(snapshot.request, boxes: boxes, except: box),
            field: box.field, edit: edit, pane: pane.id, row: box.row, typed: typed)
        else { return apiHoleNameRefusal }
        if box.field == .body, let caret = bodyCaret, case .insertHole = edit {
            bodyCaret = apiCaretAfterHole(caret, body: snapshot.request.body, typed: typed)
        }
        operateFlushed([("api_set_request", params)])
        return nil
    }
```

- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls`.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilKit/Api app/Sources/WakilApp app/Tests/WakilKitTests/ApiBodyHoleTests.swift
git commit -m "Body + HOLE inserts at the caret, and at the end only when the body never had focus (W7)"
```

Then: `superpowers:requesting-code-review` for Phases 1–2 (Tasks 1–4).

---

## Phase 3 — Recent, the split, the headers

### Task 5: Recent is one list per project and environment, and shows what was sent (W15, W18)

**W15:** Recent leaves `ApiContents` and becomes a `PaneStore` list keyed by
(organisation, project, environment). Every api pane in that key reads and writes the same
list. A send is filed under the environment it ran against, which is plan A's rule.
`api_reopen` and the `Reopen` button load into the pane they were pressed in. The list stays in
memory, capped at 200.

**W18:**
- A Recent row shows the values sent, for example `GET /customers/<id:3>/confirm`. The values
  are taken when the send resolves (`apiShownPath`), and any value over 24 characters is
  shortened with `…`.
- The Bound list shows each hole's current value, for example
  `id = 3 · live · events.customers`. These rows are computed in `PaneStore` from the panes on
  screen at every snapshot.
- A credential is never in the draft, so it is in neither.

**Files:**
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. Move `recent` / `recentTruncated` out
  of `ApiContents` into `apiRecent`. Change `snapshot()`, `recordApiSend` (which gains
  `shownPath:`), `reopenApiRow`, `clearAllScopes` and plan A's `finishApiSend`. Rewrite the doc
  comments that say *"the pane's past tense"*.
- Modify: `app/Sources/WakilKit/Panes/ApiSnapshot.swift`. Add `ApiSnapshot.bound` and
  `ApiRecentRow.shownPath`. Update the `recent` doc.
- Modify: `app/Sources/WakilKit/Api/ApiParts.swift`. `ApiStripRow` gains `value` and `table`.
  Add `apiBoundValues(in:sources:)` and `apiBoundLine`. `apiRecentRowLabel` reads `shownPath`.
- Modify: `app/Sources/WakilKit/Api/ApiResolveDraft.swift`. `ApiRequestOutcome.shownPath`.
  Add `apiShownPath` and `apiShortened`. `apiRequest` passes the shown path on every outcome
  it returns, plan A's cancelled one included.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`. Rewrite `api_reopen`'s description
  sentence *"by ROW ID from the pane's recent strip"*.
- Modify: `app/Sources/WakilKit/MCP/MCPServer.swift`. In `read_pane`'s description, the
  `recent` sentence.
- Modify: `app/Sources/WakilApp/ApiPane+Sending.swift`. `boundValues` draws
  `apiBoundLine(row)`.
- Test:
  - `app/Tests/WakilKitTests/ApiRecentTests.swift`: rewrite `eachRowKeepsItsOwnEnvironment`
    and `aSwitchLeavesThePastAlone`, and add the W15 tests;
  - `app/Tests/WakilKitTests/ApiCancelTests.swift`: rewrite plan A's
    `aSendThatOutlivesItsEnvironmentLandsInRecentOnly`;
  - `app/Tests/WakilKitTests/ApiValuesShownTests.swift` (create).

**Interfaces:**
- Consumes: plan A's `finishApiSend(paneId:outcome:)`, `ApiRequestOutcome(draft:response:cancelled:)`,
  `recordApiSend(paneId:draft:response:cancelled:)`; `resolvePart`, `ApiCellText`,
  `PaneStore.apiSources()`.
- Produces:
  ```swift
  // ApiRequestOutcome: public let shownPath: String?   — init(draft:response:cancelled: = false, shownPath: String? = nil)
  // ApiRecentRow: public let shownPath: String          — init(…, shownPath: String? = nil) defaults to path
  // ApiSnapshot: public let bound: [ApiStripRow]        — init(…, bound: [ApiStripRow] = [])
  // ApiStripRow: public let value: String?; public let table: String — init(…, value: String? = nil, table: String = "")
  public func apiShortened(_ text: String) -> String               // > 24 characters: 23 + "…"
  public func apiShownPath(_ path: [ApiPart], sources: [String: ApiSourcePane]) -> String
  public func apiBoundValues(in request: ApiRequestSnapshot, sources: [String: ApiSourcePane] = [:]) -> [ApiStripRow]
  public func apiBoundLine(_ row: ApiStripRow) -> String
  // PaneStore.recordApiSend(paneId:draft:response:cancelled:shownPath:)  — shownPath: String? = nil
  ```

- [ ] **Step 1: Write the failing tests.**

  `ApiValuesShownTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// W18: Recent shows the values sent; the Bound list shows each hole's current value.

private let bound = liveBinding(name: "reference")   // p3, key id 99, column reference
private func sources(_ value: String) -> [String: ApiSourcePane] {
    ["p3": ApiSourcePane(columns: ["id", "reference"], rows: [[.integer(99), .string(value)]],
                         generation: 1)]
}

@Test("A sent path shows each bound value beside its name")
func theShownPathCarriesTheValues() {
    #expect(apiShownPath([.literal("/customers/"), .bound(bound), .literal("/confirm")],
                         sources: sources("3"))
        == "/customers/<reference:3>/confirm")
    #expect(apiShownPath([.literal("/c/"), .slot("id")], sources: [:]) == "/c/<id>")
}

@Test("A value over 24 characters is shortened with …")
func aLongValueIsShortened() {
    #expect(apiShortened("abcdefghijklmnopqrstuvwx") == "abcdefghijklmnopqrstuvwx")   // 24
    #expect(apiShortened("abcdefghijklmnopqrstuvwxy") == "abcdefghijklmnopqrstuvw…")  // 25
    #expect(apiShownPath([.bound(bound)], sources: sources(String(repeating: "z", count: 40)))
        == "<reference:\(String(repeating: "z", count: 23))…>")
}

@Test("The Bound list shows each hole's current value")
func theBoundLineShowsTheValue() {
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.bound(bound)], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    let rows = apiBoundValues(in: request, sources: sources("BK-2026-8842"))
    #expect(rows.map(apiBoundLine) == ["reference = BK-2026-8842 · live · bookings"])
}

@Test("Review Focus 5: a value with no source shows none, never a stale one")
func aValueWithNoSourceShowsNone() {
    let request = ApiRequestSnapshot(
        method: "GET", origin: nil, path: [.literal("/c/"), .bound(bound)], query: [],
        headers: ApiRequestSnapshot.empty.headers, body: [])
    #expect(apiBoundValues(in: request).map(apiBoundLine)
        == ["reference · live · bookings · no value now"])
    #expect(apiShownPath(request.path, sources: [:]) == "/c/<reference>")
}

@Test("A recent row's label shows the path as sent")
func theRowLabelShowsTheSentPath() {
    let row = ApiRecentRow(
        method: "GET", entry: "e", environment: "staging", path: "/c/<id>",
        status: 200, durationMs: 12, draft: .empty, shownPath: "/c/<id:3>")
    #expect(apiRecentRowLabel(row).hasPrefix("GET /c/<id:3> · 200 · 12 ms"))
    // read_pane's `path` is unchanged: the draft as written, `<name>` for a bound value.
    #expect(row.path == "/c/<id>")
}
```

  In `ApiRecentTests.swift`, replace `eachRowKeepsItsOwnEnvironment` and
  `aSwitchLeavesThePastAlone`, and add the W15 tests:

```swift
@Test("W15: each environment keeps its own Recent, and a row is filed where it ran")
func eachEnvironmentKeepsItsOwnRecent() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(), response: okResponse(1, environment: "staging"))
    await panes.clearApiResponses(to: "production")
    await panes.recordApiSend(
        paneId: "api1", draft: aDraft(), response: okResponse(2, environment: "production"))
    #expect(await panes.apiSnapshot(paneId: "api1").recent.map(\.environment) == ["production"])
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.map(\.environment) == ["staging"])
}

@Test("An environment switch clears the present and leaves the past where it ran")
func aSwitchLeavesThePastAlone() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    let draft = aDraft()
    await panes.setApiDraft(paneId: "api1", draft: draft)
    let sent = okResponse(1)
    await panes.setApiResponse(paneId: "api1", response: sent)
    await panes.recordApiSend(paneId: "api1", draft: draft, response: sent)

    await panes.clearApiResponses(to: "production")
    let away = await panes.apiSnapshot(paneId: "api1")
    #expect(away.response.state == "cleared")
    #expect(away.request.method == "GET")
    #expect(away.recent.isEmpty)
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.count == 1)
}

@Test("W15: every api pane of one project and environment shares one Recent")
func recentIsSharedAcrossPanes() async throws {
    let panes = PaneStore()
    for id in ["api1", "api2"] {
        await panes.openApi(
            paneId: id, entry: "billing", environment: "staging", origin: nil, credentialed: true)
    }
    await panes.recordApiSend(paneId: "api1", draft: aDraft(path: "/bookings/41"), response: okResponse(41))
    #expect(await panes.apiSnapshot(paneId: "api2").recent.map(\.path) == ["/bookings/41"])
}

@Test("W15: another project has its own Recent")
func anotherProjectHasItsOwn() async throws {
    let panes = PaneStore()
    await panes.switchScope(to: LayoutScope(organization: "initech", project: "a"))
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(paneId: "api1", draft: aDraft(), response: okResponse(1))
    await panes.switchScope(to: LayoutScope(organization: "initech", project: "b"))
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    #expect(await panes.apiSnapshot(paneId: "api1").recent.isEmpty)
}

@Test("W15: Reopen loads into the pane it is pressed in, and the cap is shared")
func reopenLoadsIntoThePanePressed() async throws {
    let panes = PaneStore()
    for id in ["api1", "api2"] {
        await panes.openApi(
            paneId: id, entry: "billing", environment: "staging", origin: nil, credentialed: true)
    }
    await panes.recordApiSend(paneId: "api1", draft: aDraft(path: "/bookings/7"), response: okResponse(7))
    let row = try #require(await panes.apiSnapshot(paneId: "api2").recent.first)
    #expect(await panes.reopenApiRow(paneId: "api2", rowId: row.id) != nil)
    #expect(await panes.apiDraft(paneId: "api2").path == [.literal("/bookings/7")])
    #expect(await panes.apiDraft(paneId: "api1").path == [])
    for n in 1...PaneStore.recentCap {
        await panes.recordApiSend(paneId: n.isMultiple(of: 2) ? "api1" : "api2",
                                  draft: aDraft(path: "/b/\(n)"), response: okResponse(n))
    }
    let shared = await panes.apiSnapshot(paneId: "api1")
    #expect(shared.recent.count == PaneStore.recentCap)
    #expect(shared.recentTruncated)
}

@Test("A recorded send keeps the path as it was shown")
func aRowKeepsItsShownPath() async throws {
    let panes = PaneStore()
    await panes.openApi(
        paneId: "api1", entry: "billing", environment: "staging", origin: nil, credentialed: true)
    await panes.recordApiSend(paneId: "api1", draft: aDraft(), response: okResponse(1),
                              shownPath: "/bookings/<id:1>")
    #expect(await panes.apiSnapshot(paneId: "api1").recent.first?.shownPath == "/bookings/<id:1>")
}
```

  In plan A's `ApiCancelTests.swift`, replace the last three `#expect`s of
  `aSendThatOutlivesItsEnvironmentLandsInRecentOnly` with:

```swift
    let snapshot = await panes.apiSnapshot(paneId: "api-1")
    #expect(snapshot.response == .cleared(environment: "production"))
    #expect(snapshot.sending == nil)
    // W15: production's Recent is production's. The send is filed under staging, where it went.
    #expect(snapshot.recent.isEmpty)
    await panes.clearApiResponses(to: "staging")
    #expect(await panes.apiSnapshot(paneId: "api-1").recent.first?.environment == "staging")
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
  - `ApiResolveDraft.swift`. `ApiRequestOutcome` gains
    `public let shownPath: String?`, with an init parameter `shownPath: String? = nil` after
    plan A's `cancelled`. Add:

```swift
/// A value in a shown path or a Bound row, shortened past 24 characters (W18): 23 and `…`, so
/// a JSON blob or a token-length key keeps a row on one line.
public func apiShortened(_ text: String) -> String {
    text.count > 24 ? String(text.prefix(23)) + "…" : text
}

/// The path as it was sent, for Recent (W18): literals as typed, each bound value as
/// `<name:value>` with the value it resolved to at send, and `<name>` for a hole or a value
/// that did not resolve. **Screen-only.** `read_pane`'s `path` stays the draft as written, and
/// `sentUrl` already carries the URL that left.
public func apiShownPath(_ path: [ApiPart], sources: [String: ApiSourcePane]) -> String {
    path.map { part -> String in
        switch part {
        case .literal(let text): return text
        case .slot(let name): return "<\(name)>"
        case .bound(let bound):
            guard case .value(_, let cell) = resolvePart(part, sources: sources) else {
                return "<\(bound.name)>"
            }
            return "<\(bound.name):\(apiShortened(ApiCellText.of(cell)))>"
        }
    }.joined()
}
```

    In `apiRequest`, add `let shown = apiShownPath(draft.path, sources: sources)` as its first
    line. Pass `shownPath: shown` to **every** `ApiRequestOutcome(…)` it builds. That is the
    refusal, the no-client fate-unknown, the reply, the transport failure, and plan A's
    cancelled one. Run `grep -n "ApiRequestOutcome(" app/Sources/WakilKit/Api/ApiResolveDraft.swift`
    and check that each hit has it.
  - `ApiSnapshot.swift`. `ApiRecentRow` gains `public let shownPath: String`, with an init
    parameter `shownPath: String? = nil` (last), stored as `shownPath ?? path`. Its doc:
    *"The path as shown when it was sent — `<name:value>` (W18). Screen-only:
    `apiRecentRowJSON` does not publish it."* `ApiSnapshot` gains `public let bound: [ApiStripRow]`
    with init parameter `bound: [ApiStripRow] = []`, documented *"The Bound list's rows with
    their current values (W18), computed at snapshot from the panes on screen. Screen-only."*
    Rewrite the `recent` doc: *"What has been sent from every api pane of this project in this
    environment — one list they share (W15), newest first, capped, dead with the session."*
  - `ApiParts.swift`. `ApiStripRow` gains `public let value: String?` and
    `public let table: String`, with init parameters `value: String? = nil, table: String = ""`
    after `region`. Change `apiBoundValues` to `apiBoundValues(in:sources: [String: ApiSourcePane] = [:])`,
    and in its `collect`:

```swift
            let value: String?
            if case .value(_, let cell) = resolvePart(part, sources: sources) {
                value = apiShortened(ApiCellText.of(cell))
            } else {
                value = nil
            }
            rows.append(ApiStripRow(
                name: bound.name, kind: bound.binding.wireName,
                origin: apiOriginText(bound.source), region: region,
                value: value, table: bound.source.table.isEmpty ? "a result" : bound.source.table))
```

    Add:

```swift
/// One Bound row as drawn (W18): `id = 3 · live · events.customers` — the hole's name, its
/// value now, the binding's kind, and the table. A value that does not resolve now reads
/// `no value now`, never a remembered one (Review Focus 5).
public func apiBoundLine(_ row: ApiStripRow) -> String {
    guard let value = row.value else {
        return "\(row.name) · \(row.kind) · \(row.table) · no value now"
    }
    return "\(row.name) = \(value) · \(row.kind) · \(row.table)"
}
```

    In `apiRecentRowLabel`, change `"\(row.method) \(row.path)"` to
    `"\(row.method) \(row.shownPath)"`. Plan A's `cancelled` suffix is unchanged.
  - `PaneStore.swift`. Delete `recent` and `recentTruncated` from `ApiContents`, and the
    `recent:` / `recentTruncated:` arguments in its `snapshot()`. `snapshot()` becomes:

```swift
        func snapshot(recent: [ApiRecentRow], recentTruncated: Bool, bound: (ApiRequestSnapshot) -> [ApiStripRow]) -> ApiSnapshot {
            let request = ApiRequestSnapshot(
                method: draft.method, origin: origin,
                path: draft.path, query: draft.query,
                headers: apiHeaderRegion(draft: draft, credentialed: credentialed),
                body: draft.body)
            return ApiSnapshot(
                entry: draft.entry, environment: environment, credentialed: credentialed,
                request: request, response: response, entries: entries, recent: recent,
                recentTruncated: recentTruncated, sending: flight.map { ApiSending(since: $0.since, method: $0.method) },
                bound: bound(request))
        }
```

    The `sending:` argument is plan A's, kept as plan A wrote it. Add, beside `recentCap`:

```swift
    /// Recent's key (W15): **one list per organisation, project and environment**, shared by
    /// every api pane in it. Not the conversation (`LayoutScope.lineageRoot`): a project's
    /// sends are the project's, whichever conversation made them.
    private struct ApiRecentKey: Hashable {
        let organization: String
        let project: String
        let environment: String
    }

    private struct ApiRecentList {
        var rows: [ApiRecentRow] = []
        var truncated = false
    }

    /// In memory, capped at `recentCap` per list, dead with the session. Persisting it is a
    /// decision of its own (Amendment 9c).
    private var apiRecent: [ApiRecentKey: ApiRecentList] = [:]

    private func recentKey(_ environment: String) -> ApiRecentKey {
        ApiRecentKey(
            organization: scope.organization, project: scope.project, environment: environment)
    }

    /// One api pane's snapshot: its own contents, the shared Recent for its environment, and
    /// its bound values resolved against the panes on screen now (W18).
    private func apiSnapshot(of contents: ApiContents) -> ApiSnapshot {
        let list = apiRecent[recentKey(contents.environment)] ?? ApiRecentList()
        let sources = apiSources()
        return contents.snapshot(
            recent: list.rows, recentTruncated: list.truncated,
            bound: { apiBoundValues(in: $0, sources: sources) })
    }
```

    `apiSnapshot(paneId:)` becomes `apiSnapshot(of: api(paneId))`. In `snapshot(paneId:kind:)`,
    the `.api(contents)` arm uses `apiSnapshot(of: contents)`. `recordApiSend` gains
    `shownPath: String? = nil` (after plan A's `cancelled`), and its tail becomes:

```swift
        let key = recentKey(environment)
        var list = apiRecent[key] ?? ApiRecentList()
        list.rows.insert(
            ApiRecentRow(
                method: draft.method, entry: draft.entry, environment: environment,
                path: apiRenderedPath(draft.path),
                sentUrl: { if case .ok(let reply) = response { return reply.url } else { return nil } }(),
                status: status, durationMs: millis, draft: draft, cancelled: cancelled,
                shownPath: shownPath),
            at: 0)
        if list.rows.count > Self.recentCap {
            list.rows.removeLast(list.rows.count - Self.recentCap)
            list.truncated = true
        }
        apiRecent[key] = list
```

    `recordApiSend` no longer reads or writes `contents`. Delete its `var contents = api(paneId)`
    and `setApi` lines, and keep `paneId` in the signature for the call sites. In
    `reopenApiRow`, replace `contents.recent.first(where:)` with
    `apiRecent[recentKey(contents.environment)]?.rows.first(where: { $0.id == rowId })`. In
    `clearAllScopes`, add `apiRecent = [:]`. In plan A's `finishApiSend`, pass
    `shownPath: outcome.shownPath` to `recordApiSend`. Rewrite `recordApiSend`'s and
    `recentCap`'s docs from *"the pane's past tense"* to *"the project and environment's past
    tense (W15)"*.
  - `ApiActions.swift`, in `api_reopen`'s description: *"by ROW ID from Recent — one list per
    project and environment, shared by every api pane in it, read from any of them with
    read_pane — into THIS pane's draft."*
  - `MCPServer.swift`, in `read_pane`'s description: replace *"recent is what this pane has
    ALREADY sent, one row per send with an outcome"* with *"recent is what has ALREADY been
    sent from every api pane of this project in this environment — one list they share — one
    row per send with an outcome"*.
  - `ApiPane+Sending.swift`, `boundValues`:

```swift
    @ViewBuilder var boundValues: some View {
        let rows = snapshot.bound
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                micro("BOUND")
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    // W18: `id = 3 · live · events.customers`, monospace, the pane's ink.
                    Text(apiBoundLine(row.element))
                        .foregroundStyle(ink.opacity(row.element.value == nil ? 0.45 : 0.70))
                        .wraps()
                }
            }
        }
    }
```

    The Recent strip's label is already `apiRecentRowLabel`, so it picks up `shownPath` with
    no view change.
- [ ] **Step 4: Run.** `make app-test`, `make app-bundle` and `make controls`. Then
  `grep -rn "\.recent\b\|recentTruncated" app/Sources/WakilKit/Panes/PaneStore.swift` must
  show no use of `contents.recent`.
- [ ] **Step 5: Commit.**

```bash
git add app/Sources/WakilKit app/Sources/WakilApp app/Tests/WakilKitTests
git commit -m "Recent is one list per project and environment and shows the values sent; the Bound list shows each value now (W15, W18)"
```

### Task 6: The pane splits (W10, W11)

The request (method, URL, tables, body, Bound, Send) sits on top and the response below. Each
half scrolls on its own, and the request half takes 55%. The response's head stays pinned
while its body scrolls. Recent sits at the foot of the response half: at most four rows tall
when unfolded, scrolling within. When the response says only one line (`none`, `cleared`,
`cancelled`), the response half shrinks to that line plus Recent, and the request takes the
rest. Nothing draws outside the pane, which closes the walk's case: a 200 KB reply pushed the
request under `Open…` / `Actions…`.

**Files:**
- Create: `app/Sources/WakilKit/Api/ApiPaneLayout.swift`
- Modify: `app/Sources/WakilApp/ApiPane.swift` (`body`)
- Modify: `app/Sources/WakilApp/ApiPane+Sending.swift`. Split `response` into `responseHead`
  and `responseBody`, add `responseHalf`, and make `recentStrip` hold four rows and scroll.
- Test: `app/Tests/WakilKitTests/ApiPaneLayoutTests.swift` (create)

**Interfaces:**
- Consumes: `ApiResponseSnapshot` (plan A's `.cancelled` included).
- Produces:
  ```swift
  public let apiRequestShare: Double                      // 0.55
  public enum ApiPaneSplit: Equatable, Sendable { case shared(request: Double, response: Double), responseLine }
  public func apiResponseIsOneLine(_ response: ApiResponseSnapshot) -> Bool
  public func apiPaneSplit(total: Double, response: ApiResponseSnapshot) -> ApiPaneSplit
  public let apiRecentStripMaxRows: Int                   // 4
  public func apiRecentStripRows(count: Int) -> Int
  // view
  var requestHalf: some View; func responseHalf(scrolls: Bool) -> some View
  var responseHead: some View; var responseBody: some View
  ```

- [ ] **Step 1: Write the failing tests** in `ApiPaneLayoutTests.swift`:

```swift
import Foundation
import Testing
@testable import WakilKit

/// W10, W11: the pane splits, the request above at 55%, the response below.

private let reply = ApiResponseSnapshot.ok(ApiResponseOK(
    status: 200, url: "https://h/x", environment: "staging", headers: [:], body: "",
    durationMs: 5, byteCount: 0, truncated: false))

@Test("Once something came back, the request takes 55% and the response the rest")
func theSplitIsShared() {
    #expect(apiPaneSplit(total: 1000, response: reply) == .shared(request: 550, response: 450))
    #expect(apiPaneSplit(total: 381, response: reply) == .shared(request: 209, response: 172))
    #expect(apiRequestShare == 0.55)
}

@Test("A response that says one line shrinks to it", arguments: [
    ApiResponseSnapshot.none,
    .cleared(environment: "production"),
    .cancelled(ApiCancelled(waitedMs: 4200, environment: "staging")),
])
func aOneLineResponseShrinks(response: ApiResponseSnapshot) {
    #expect(apiResponseIsOneLine(response))
    #expect(apiPaneSplit(total: 1000, response: response) == .responseLine)
}

@Test("A refusal, a failure and a fate-unknown take their half: they say more than one line")
func theOtherStatesShare() {
    let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: [
        ApiSendFailure(region: .path, message: "m"),
    ]))
    let transport = ApiResponseSnapshot.transport(ApiTransportFailure(
        stage: "send", waitedMs: 3, reason: "r", environment: "staging"))
    let unknown = ApiResponseSnapshot.unknown(ApiFateUnknown(reason: "r", environment: "staging"))
    for response in [refusal, transport, unknown, reply] {
        #expect(!apiResponseIsOneLine(response))
    }
}

@Test("A pane with no height splits nothing")
func noHeight() {
    #expect(apiPaneSplit(total: 0, response: reply) == .shared(request: 0, response: 0))
    #expect(apiPaneSplit(total: -5, response: reply) == .shared(request: 0, response: 0))
}

@Test("Recent is at most four rows tall, scrolling past that")
func recentIsAtMostFourRows() {
    #expect(apiRecentStripMaxRows == 4)
    #expect(apiRecentStripRows(count: 0) == 0)
    #expect(apiRecentStripRows(count: 3) == 3)
    #expect(apiRecentStripRows(count: 9) == 4)
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement** `ApiPaneLayout.swift`:

```swift
import Foundation

/// W10, W11 (Amendment 9c): **the pane splits.** The request sits above and the response
/// below, each scrolling on its own, and nothing draws outside the pane. The walk saw a 200 KB
/// reply push the request under the window's toolbar.

/// The request half's share of the pane, once something has come back.
public let apiRequestShare = 0.55

public enum ApiPaneSplit: Equatable, Sendable {
    /// Request and response, each this tall, in points.
    case shared(request: Double, response: Double)
    /// The response is one line, drawn at its own height. The request takes the rest.
    case responseLine
}

/// Whether the response says one line: nothing sent, cleared by a switch, or cancelled. That
/// half then shrinks to the line and Recent below it.
public func apiResponseIsOneLine(_ response: ApiResponseSnapshot) -> Bool {
    switch response {
    case .none, .cleared, .cancelled: return true
    case .ok, .transport, .unknown, .refusal: return false
    }
}

/// How a pane `total` points tall splits for this response.
public func apiPaneSplit(total: Double, response: ApiResponseSnapshot) -> ApiPaneSplit {
    if apiResponseIsOneLine(response) { return .responseLine }
    let height = max(total, 0)
    let request = (height * apiRequestShare).rounded(.down)
    return .shared(request: request, response: height - request)
}

/// Recent's height cap, in rows (W11): unfolded, it scrolls past this.
public let apiRecentStripMaxRows = 4

/// How many rows tall Recent is drawn, for `count` rows: all of them up to the cap.
public func apiRecentStripRows(count: Int) -> Int { min(max(count, 0), apiRecentStripMaxRows) }
```

  If plan A's `.cancelled` case has a different associated type, follow plan A's.
- [ ] **Step 4: Run the tests.** They must pass.
- [ ] **Step 5: The view.**
  - `ApiPane.swift`. `body` becomes the split. Every modifier after the old `VStack`'s
    `.frame(maxWidth: .infinity, alignment: .leading)` stays as it is, in the same order:
    `.contentShape`, `.accessibilityElement(children: .contain)`,
    `.accessibilityIdentifier("api.pane")`, `.dropDestination`, the drop `.overlay`, and plan
    A's `.onChange(of: snapshot.request)`.

```swift
    var body: some View {
        GeometryReader { geometry in
            let split = apiPaneSplit(total: Double(geometry.size.height), response: snapshot.response)
            VStack(alignment: .leading, spacing: 0) {
                switch split {
                case .shared(let request, let response):
                    requestHalf.frame(height: CGFloat(request), alignment: .top)
                    hairline(0.08)
                    responseHalf(scrolls: true).frame(height: CGFloat(response), alignment: .top)
                case .responseLine:
                    requestHalf.frame(maxHeight: .infinity, alignment: .top)
                    hairline(0.08)
                    responseHalf(scrolls: false)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(ink.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // W10: nothing draws outside the pane — not under the toolbar, not over a neighbour.
        .clipped()
        // … `.contentShape(Rectangle())` and every modifier after it, unchanged …
    }

    /// The request half (W10): everything that composes and sends, scrolling on its own.
    var requestHalf: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    methodLine
                    urlBox
                    if let refusal = pathRefusal {
                        // No identifier: a line is read, not pressed.
                        Text(refusal).foregroundStyle(amber).wraps()
                    }
                }
                queryRegion
                headerRegion
                bodyRegion
                boundValues
                VStack(alignment: .leading, spacing: 6) {
                    resultLine
                    sendControl
                    unfilledLine
                }
            }
            // Room for the overlay scroller, so it never sits on a value.
            .padding(.trailing, 10)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

  - `ApiPane+Sending.swift`. Replace `response` with three views. Every case keeps its
    current text, colours and plan A's `.wraps()` / `apiFailureLine` / `.cancelled` arm.
    Only where each line sits changes:

```swift
    /// The response half (W10, W11): the head pinned, the body scrolling below it when the
    /// half has a height to scroll in, and Recent at its foot.
    func responseHalf(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            responseHead
            if scrolls {
                ScrollView(.vertical) {
                    responseBody
                        .padding(.trailing, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                responseBody
            }
            recentStrip
        }
        .padding(.top, 8)
    }

    /// What stays pinned: the status chip, timing and size, the URL, and the one-line states
    /// whole.
    @ViewBuilder var responseHead: some View {
        switch snapshot.response {
        case .none:
            HStack(spacing: 10) {
                micro("RESPONSE")
                Text("nothing sent yet").foregroundStyle(ink.opacity(0.35))
            }
        case .cleared(let environment):
            HStack(spacing: 10) {
                micro("RESPONSE")
                Text("cleared — the environment is now \(environment)")
                    .foregroundStyle(ink.opacity(0.35)).wraps()
            }
        case .cancelled(let c):
            HStack(spacing: 10) {
                micro("RESPONSE")
                Text(apiCancelledLine(waitedMs: c.waitedMs)).foregroundStyle(ink.opacity(0.45))
            }
        case .ok(let reply):
            responseHeading(chip: "\(reply.status)", tone: snapshot.response) {
                Text("\(reply.durationMs) ms · \(reply.byteCount) bytes")
            }
            Text(reply.url).foregroundStyle(ink.opacity(0.45)).wraps()
            if reply.truncated {
                Text("truncated").foregroundStyle(amber)
            }
        case .transport(let failure):
            responseHeading(chip: "\(failure.stage) failed", tone: snapshot.response) {
                Text("after \(failure.waitedMs) ms")
            }
        case .unknown:
            responseHeading(chip: "fate unknown", tone: snapshot.response) { EmptyView() }
        case .refusal:
            HStack(spacing: 10) {
                micro("RESPONSE")
                Text("not sent").foregroundStyle(amber)
            }
        }
    }

    /// What scrolls: the reply's body, a failure's reason, a refusal's lines.
    @ViewBuilder var responseBody: some View {
        switch snapshot.response {
        case .ok(let reply):
            if !reply.body.isEmpty {
                // **Text, refused the grid** — a surface that cannot sort, filter or page must
                // not look like one that can.
                Text(reply.body)
                    .foregroundStyle(ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .transport(let failure):
            Text(failure.reason).foregroundStyle(ink.opacity(0.50)).wraps()
        case .unknown(let record):
            Text(record.reason).foregroundStyle(ink.opacity(0.50)).wraps()
        case .refusal(let refusal):
            ForEach(Array(refusal.failures.enumerated()), id: \.offset) { failure in
                Text(apiFailureLine(failure.element)).foregroundStyle(ink.opacity(0.50)).wraps()
            }
        case .none, .cleared, .cancelled:
            EmptyView()
        }
    }
```

    Move the doc comments of the old `response` to `responseHalf` and `responseHead`, and
    delete the old `response` and its leading `hairline(0.08)` (the split draws the hairline
    now). If plan A's arm uses a different spelling for the transport or fate-unknown amber
    line, keep plan A's.
  - `recentStrip`. The heading line is unchanged. The unfolded rows sit in a scroll view
    exactly as tall as `apiRecentStripRows`, and each row is one line:

```swift
            if recentUnfolded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                            HStack(spacing: 12) {
                                Text(apiRecentRowLabel(entry.element))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(ink.opacity(0.70))
                                Spacer(minLength: 8)
                                // the existing `Reopen` and `Copy as cURL` buttons, unchanged,
                                // identifiers `api.recent.\(entry.offset).reopen` / `.curl`
                            }
                            .frame(height: recentRowHeight)
                        }
                    }
                    .padding(.trailing, 10)
                }
                .frame(height: CGFloat(apiRecentStripRows(count: rows.count)) * recentRowHeight)
            }
```

    and add `private var recentRowHeight: CGFloat { 22 }` beside it. That is drawing, not a
    ruling: the cap in rows is `apiRecentStripMaxRows`.
- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls`. The harvest must
  be unchanged.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiPaneLayout.swift app/Sources/WakilApp \
  app/Tests/WakilKitTests/ApiPaneLayoutTests.swift
git commit -m "The api pane splits: request above at 55%, response below with its head pinned, Recent four rows at its foot, nothing outside the pane (W10, W11)"
```

### Task 7: The response's headers, behind Body · Headers (W20)

`ApiResponseSnapshot` already holds the headers, and `read_pane` already publishes them. The
pane never drew them. The pinned head gains `Body · Headers` (`api.response.body`,
`api.response.headers`, `SegmentedChoice`), defaulting to Body. Headers draws a
`HEADER | VALUE` table in the request tables' style. Names come in the order received, values
wrap, and nothing is coloured. A refusal or a transport failure has no headers and draws no
choice. Neither do fate-unknown, cancelled, cleared or none.

**Order received.** `wakil-http` returns `map[string]string`, and Go's JSON encoder writes map
keys in byte order. `ApiResponseOK.headers` is a Swift dictionary. Sorting the names by their
UTF-8 bytes therefore reproduces exactly the order the reply arrived in.

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiPaneLayout.swift`. Add `ApiResponseShows`,
  `apiResponseOffersHeaders`, `ApiResponseHeaderRow` and `apiResponseHeaderRows`.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. Add
  `@State var responseShows: ApiResponseShows = .body`.
- Modify: `app/Sources/WakilApp/ApiPane+Sending.swift`. The choice in `responseHead`'s `.ok`
  arm, and the table in `responseBody`'s `.ok` arm.
- Test: `app/Tests/WakilKitTests/ApiPaneLayoutTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ApiResponseShows: String, CaseIterable, Sendable { case body = "Body", headers = "Headers"; public var key: String }
  public func apiResponseOffersHeaders(_ response: ApiResponseSnapshot) -> Bool
  public struct ApiResponseHeaderRow: Equatable, Sendable { public let name: String; public let value: String }
  public func apiResponseHeaderRows(_ reply: ApiResponseOK) -> [ApiResponseHeaderRow]
  ```

- [ ] **Step 1: Write the failing tests** (append to `ApiPaneLayoutTests.swift`):

```swift
@Test("W20: only a reply offers its headers")
func onlyAReplyOffersHeaders() {
    #expect(apiResponseOffersHeaders(reply))
    let refusal = ApiResponseSnapshot.refusal(ApiSendRefusal(failures: []))
    let transport = ApiResponseSnapshot.transport(ApiTransportFailure(
        stage: "send", waitedMs: 3, reason: "r", environment: "staging"))
    for response in [ApiResponseSnapshot.none, refusal, transport,
                     .unknown(ApiFateUnknown(reason: "r", environment: "s")),
                     .cleared(environment: "s"),
                     .cancelled(ApiCancelled(waitedMs: 1, environment: "s"))] {
        #expect(!apiResponseOffersHeaders(response))
    }
}

@Test("W20: headers in the order received — wakil-http's JSON writes them in byte order")
func headersInTheOrderReceived() {
    let ok = ApiResponseOK(
        status: 200, url: "u", environment: "s",
        headers: ["x-b": "2", "date": "Fri", "Content-Type": "application/json"],
        body: "", durationMs: 1, byteCount: 0, truncated: false)
    #expect(apiResponseHeaderRows(ok) == [
        ApiResponseHeaderRow(name: "Content-Type", value: "application/json"),
        ApiResponseHeaderRow(name: "date", value: "Fri"),
        ApiResponseHeaderRow(name: "x-b", value: "2"),
    ])
}

@Test("W20: the choice reads Body · Headers, Body first, and keys its identifiers in lower case")
func theChoice() {
    #expect(ApiResponseShows.allCases.map(\.rawValue) == ["Body", "Headers"])
    #expect(ApiResponseShows.allCases.map(\.key) == ["body", "headers"])
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement** (append to `ApiPaneLayout.swift`):

```swift
/// W20: what the response half shows under its pinned head. Body by default.
public enum ApiResponseShows: String, CaseIterable, Sendable {
    case body = "Body"
    case headers = "Headers"

    /// The identifier's last segment: `api.response.body`, `api.response.headers`.
    public var key: String { rawValue.lowercased() }
}

/// Whether the response has headers to show. **Only a reply.** A refusal, a transport failure,
/// a fate-unknown and a cancelled send had no reply to take them from, so they draw no choice.
public func apiResponseOffersHeaders(_ response: ApiResponseSnapshot) -> Bool {
    if case .ok = response { return true }
    return false
}

public struct ApiResponseHeaderRow: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The reply's headers **in the order received.** `wakil-http` returns them as a JSON object,
/// and Go's encoder writes map keys in byte order, so UTF-8 byte order is the wire's own.
/// Uncoloured: §5's hues are spent on the status chip alone.
public func apiResponseHeaderRows(_ reply: ApiResponseOK) -> [ApiResponseHeaderRow] {
    reply.headers
        .map { ApiResponseHeaderRow(name: $0.key, value: $0.value) }
        .sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
}
```

- [ ] **Step 4: Run the tests.** They must pass.
- [ ] **Step 5: The view.**
  - `ApiPane.swift`:

```swift
    /// W20: Body or Headers under the response's pinned head. The operator's choice, kept across
    /// replies. Not published: `read_pane` already carries both.
    @State var responseShows: ApiResponseShows = .body
```

  - `ApiPane+Sending.swift`, `responseHead`'s `.ok` arm. The choice sits on the heading line,
    before the measurements:

```swift
        case .ok(let reply):
            responseHeading(chip: "\(reply.status)", tone: snapshot.response) {
                HStack(spacing: 12) {
                    if apiResponseOffersHeaders(snapshot.response) {
                        SegmentedChoice(
                            options: ApiResponseShows.allCases.map(\.rawValue),
                            selection: Binding(
                                get: { responseShows.rawValue },
                                set: { responseShows = ApiResponseShows(rawValue: $0) ?? .body }),
                            identifier: { label in
                                let key = ApiResponseShows(rawValue: label)?.key ?? label
                                return "api.response.\(key)"
                            })
                    }
                    Text("\(reply.durationMs) ms · \(reply.byteCount) bytes")
                }
            }
```

    (`responseHeading` applies `ink.opacity(0.45)` to its trailing content.
    `SegmentedChoice` sets its own segment colours, and the chosen one is violet, so the
    opacity does not wash it out. If it does, move the `.foregroundStyle` onto the `Text`
    alone.)
  - `responseBody`'s `.ok` arm:

```swift
        case .ok(let reply):
            switch responseShows {
            case .body:
                if !reply.body.isEmpty {
                    Text(reply.body)
                        .foregroundStyle(ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .headers:
                responseHeaders(reply)
            }
```

    and add:

```swift
    /// W20: `HEADER | VALUE`, in the request tables' style. Names in the order received,
    /// values wrapping, no hue.
    func responseHeaders(_ reply: ApiResponseOK) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ApiRowColumns {
                micro("HEADER")
                micro("VALUE")
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.vertical, 5)
            hairline(0.08)
            ForEach(Array(apiResponseHeaderRows(reply).enumerated()), id: \.offset) { row in
                ApiRowColumns {
                    Text(row.element.name).foregroundStyle(ink.opacity(0.55)).wraps()
                    Text(row.element.value).foregroundStyle(ink.opacity(0.85)).wraps()
                    Color.clear.frame(width: 0, height: 0)
                }
                .padding(.vertical, 6)
                hairline(0.05)
            }
        }
    }
```

- [ ] **Step 6: Run.** `make app-test` and `make app-bundle`. Then `make controls`: the harvest
  gains exactly one family, `api.response.<…>`.
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilKit/Api/ApiPaneLayout.swift app/Sources/WakilApp \
  app/Tests/WakilKitTests/ApiPaneLayoutTests.swift
git commit -m "The response's headers, behind Body · Headers on the pinned head (W20)"
```

### Task 8: The rest (W5, W6, W2, W8, W19)

- **W5:** `+ query` and `+ header` focus their name box. The pane had two `@FocusState`s. The
  name box's `holeNameFocused` was set in `onAppear` while `focusedBox` still claimed the box
  the operator was in. The name box now uses `focusedBox` too, with the identifier as its
  value, and the focus is owed through `pendingFocus` and taken one turn after the box is
  drawn.
- **W6:** a refusal under a table spans the pane's width. Today an add's name-box refusal is
  drawn in the heading row's last cell (`ApiRowColumns` caps that cell at 45%).
- **W2:** `BODY · JSON` / `BODY · TEXT`, from the content type the screen shows. Empty counts as
  JSON, because `wakil-http`'s `send` defaults to `application/json`.
- **W8:** the pane's title follows its entry. It is retitled on `api_set_request`'s `entry`, on
  `api_reopen`, and on a re-resolve that changes the entry.
- **W19:** the content-type placeholder reads `application/json`.

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiPaneLines.swift`. Add `apiContentTypeIsJSON`,
  `apiBodyHeading` and `apiContentTypePlaceholder`.
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`:
  - `api_set_request` and `api_reopen` retitle;
  - `apiPaneTitle`'s doc;
  - plan A's `ApiPaneResolver` gains `var layout: LayoutStore? = nil`, and `reresolve`
    retitles;
  - `registerApiActions` returns `ApiPaneResolver(panes: panes, http: http, layout: layout)`.
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift`. Plan A's `reresolveApis` returns the
  panes whose entry changed.
- Modify: `app/Sources/WakilApp/ApiPane.swift`. Delete `@FocusState var holeNameFocused`.
- Modify: `app/Sources/WakilApp/ApiPane+Fields.swift`:
  - `nameControl` takes `refusalBelow:` and focuses through `focusedBox`;
  - `takeOwedFocus` defers;
  - add `nameRefusal(_:)`.
- Modify: `app/Sources/WakilApp/ApiPane+Request.swift`:
  - `table` draws the add refusal at full width, and `tableRow` draws a row's `+ hole`
    refusal at full width;
  - `bodyRegion` uses `apiBodyHeading`;
  - the content-type field uses `apiContentTypePlaceholder`.
- Test: `app/Tests/WakilKitTests/ApiPaneLinesTests.swift`,
  `app/Tests/WakilKitTests/ApiSetRequestTests.swift`, plan A's
  `app/Tests/WakilKitTests/ApiEnvironmentTests.swift`.

**Interfaces:**
- Consumes: plan A's `ApiPaneResolver`, `PaneStore.reresolveApis(environment:listing:)`,
  `applied`; `LayoutStore.retitle(id:to:)`, `apiPaneTitle(entry:path:)`.
- Produces:
  ```swift
  public func apiContentTypeIsJSON(_ contentType: String) -> Bool
  public func apiBodyHeading(_ request: ApiRequestSnapshot) -> String     // "BODY · JSON" / "BODY · TEXT"
  public let apiContentTypePlaceholder: String                            // "application/json"
  // PaneStore: @discardableResult func reresolveApis(environment:listing:) -> [String: String]   // paneId → new entry
  // ApiPaneResolver: var layout: LayoutStore? = nil
  ```

- [ ] **Step 1: Write the failing tests.**

  `ApiPaneLinesTests.swift`:

```swift
@Test("W2: the body heading says JSON from the content type, and TEXT otherwise", arguments: [
    ("", "BODY · JSON"),
    ("application/json", "BODY · JSON"),
    ("Application/JSON; charset=utf-8", "BODY · JSON"),
    ("application/merge-patch+json", "BODY · JSON"),
    ("text/plain", "BODY · TEXT"),
    ("application/x-www-form-urlencoded", "BODY · TEXT"),
])
func theBodyHeading(contentType: String, expected: String) {
    let rows = apiWakilHeaderRows(entry: "", contentType: contentType, credentialed: false)
    let request = ApiRequestSnapshot(method: "POST", origin: nil, path: [], query: [],
                                     headers: rows, body: [])
    #expect(apiBodyHeading(request) == expected)
}

@Test("W19: the content type's placeholder is the default it stands for")
func theContentTypePlaceholder() {
    #expect(apiContentTypePlaceholder == "application/json")
}
```

  `ApiSetRequestTests.swift`:

```swift
@Test func w8TheTitleFollowsTheEntry() async throws {
    let f = try await fixture(entries: [
        ("billing", "https://billing.example.com", true), ("catalog", "https://c.example", false),
    ])
    let paneId = try await open(f)
    try await setRequest(f, pane: paneId, ["entry": .string("catalog")])
    #expect(await f.layout.snapshot().panes.first { $0.id == paneId }?.title == "catalog")
}

@Test func w8AReopenedRowRetitlesThePane() async throws {
    let f = try await fixture()
    let paneId = try await open(f)
    var sent = ApiDraft.empty
    sent.entry = "catalog"
    await f.panes.recordApiSend(paneId: paneId, draft: sent, response: .ok(ApiResponseOK(
        status: 200, url: "u", environment: "staging", headers: [:], body: "",
        durationMs: 1, byteCount: 0, truncated: false)))
    let row = try #require(await f.panes.apiSnapshot(paneId: paneId).recent.first)
    _ = try await f.registry.dispatch(
        name: "api_reopen", params: .object(["pane": .string(paneId), "row": .string(row.id)]),
        origin: .ui, environment: "staging", confirmation: nil)
    #expect(await f.layout.snapshot().panes.first { $0.id == paneId }?.title == "catalog")
}
```

  In plan A's `ApiEnvironmentTests.swift`:

```swift
@Test("W8: a re-resolve that points an unpointed pane retitles it")
func aReresolveRetitles() async {
    let panes = PaneStore()
    let layout = LayoutStore()
    let id = await layout.open(kind: "api", title: "api").id
    await panes.openApi(paneId: id, entry: "", environment: "staging", origin: nil,
                        credentialed: false, entries: ["a", "b"])
    let http = RecordingToolCaller(always: listApisReply([("catalog", "https://c.example")]))
    await ApiPaneResolver(panes: panes, http: http, layout: layout).reresolve(environment: "qa")
    #expect(await layout.snapshot().panes.first { $0.id == id }?.title == "catalog")
}
```

- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement the WakilKit half.**
  - `ApiPaneLines.swift`:

```swift
// MARK: - The body heading and the content type's placeholder (W2, W19)

/// Whether a content type names JSON: empty (the send's own default is `application/json`),
/// `application/json`, or any `+json` suffix. Parameters are ignored, and case does not count.
public func apiContentTypeIsJSON(_ contentType: String) -> Bool {
    let media = contentType.split(separator: ";", maxSplits: 1).first
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    return media.isEmpty || media == "application/json" || media.hasSuffix("+json")
}

/// The Body heading (W2): `BODY · JSON` from the content type, `BODY · TEXT` otherwise.
public func apiBodyHeading(_ request: ApiRequestSnapshot) -> String {
    apiContentTypeIsJSON(apiContentTypeText(request)) ? "BODY · JSON" : "BODY · TEXT"
}

/// The content-type box's placeholder (W19): the default an empty box stands for.
public let apiContentTypePlaceholder = "application/json"
```

  - `ApiActions.swift`. In `api_set_request`, right after `await panes.setApiDraft(…)`:

```swift
            // W8: the title follows the entry.
            if entry != nil {
                await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry, path: ""))
            }
```

    In `api_reopen`, after the `guard let draft = …`:
    `await layout?.retitle(id: paneId, to: apiPaneTitle(entry: draft.entry, path: ""))`.
    Rewrite `apiPaneTitle`'s first doc paragraph: *"**Derived from the entry, and re-derived
    whenever the entry changes** (W8): `api_open`, `api_set_request`'s `entry`, `api_reopen`
    and a re-resolve. Never stored and never edited."* Plan A's `ApiPaneResolver`:

```swift
public struct ApiPaneResolver: Sendable {
    let panes: PaneStore
    let http: (any ToolCaller)?
    /// W8: a pane the re-resolve points at an entry is retitled. `nil` in tests that only
    /// read the store.
    var layout: LayoutStore? = nil

    public func reresolve(environment: String) async {
        guard let listing = await apiListing(http: http) else { return }
        let changed = await panes.reresolveApis(environment: environment, listing: listing)
        for (paneId, entry) in changed {
            await layout?.retitle(id: paneId, to: apiPaneTitle(entry: entry, path: ""))
        }
    }
}
```

    `registerApiActions` ends with `return ApiPaneResolver(panes: panes, http: http, layout: layout)`.
  - `PaneStore.swift`. Plan A's `reresolveApis` gains `@discardableResult`, returns
    `[String: String]`, and records `changed[paneId] = resolved.entry` whenever
    `resolved.entry != contents.draft.entry`. The comparison must happen before the
    assignment.
- [ ] **Step 4: Run the WakilKit tests.** They must pass.
- [ ] **Step 5: Wire the view.**
  - W2: in `bodyRegion`, `micro("BODY")` becomes `micro(apiBodyHeading(applied))`. Plan A's
    `applied` is used so that the heading follows a content type typed and not yet saved.
  - W19: in the content-type field (`headerValue`'s `.derived` branch), the second argument
    of `field("api.contentType", …)` becomes `apiContentTypePlaceholder`.
  - W5: in `ApiPane.swift`, delete `@FocusState var holeNameFocused`. In `nameControl`:

```swift
            TextField("name", text: $holeName)
                // … the existing modifiers through `.accessibilityIdentifier(nameId)` …
                // W5: the one focus state the pane has, so the box the operator was in lets go.
                .focused($focusedBox, equals: nameId)
                .onAppear { takeOwedFocus(nameId) }
```

    and in its `Button(button) { … }` action, add `pendingFocus = nameId` after
    `holeNaming = slot`. Do the same in `table`'s mouse-only *"+ add a parameter"* button.
    `takeOwedFocus` defers the hand-off one turn, because a field appearing in this update is
    not yet in the window's responder chain:

```swift
    func takeOwedFocus(_ identifier: String) {
        guard pendingFocus == identifier else { return }
        pendingFocus = nil
        DispatchQueue.main.async { focusedBox = identifier }
    }
```

    Then `grep -n "holeNameFocused" app/Sources/WakilApp` must be empty.
  - W6: `nameControl` gains `refusalBelow: Bool = false` and draws `holeRefusal` beside its
    box only when `!refusalBelow`. Add:

```swift
    /// W6: an open name box's refusal, drawn the pane's full width under a table's row rather
    /// than squeezed into its last cell.
    @ViewBuilder func nameRefusal(_ slots: [String]) -> some View {
        if let open = holeNaming, slots.contains(open), let line = holeRefusal {
            Text(line).foregroundStyle(amber).wraps()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
        }
    }
```

    `addControl` passes `refusalBelow: true`. `table` draws `nameRefusal([region == .query ?
    "+query" : "+header"])` right after its heading row's `.padding(.vertical, 5)`, before
    the hairline. In both regions, the row's `fieldHole(field, row: occurrence)` passes
    `refusalBelow: true` through `fieldHole` → `holeControl` → `nameControl`. `tableRow` gains
    a `holeKey: String?` parameter and draws `nameRefusal([holeKey].compactMap { $0 })` after
    its `ApiRowColumns`. The two call sites pass `apiFieldKey(field, row: occurrence)`, or
    `nil` for Wakil's rows.
- [ ] **Step 6: Run.** `make app-test`, `make app-bundle` and `make controls` (harvest
  unchanged).
- [ ] **Step 7: Commit.**

```bash
git add app/Sources/WakilKit app/Sources/WakilApp app/Tests/WakilKitTests
git commit -m "The name box takes focus, refusals span the pane, BODY · JSON / TEXT, the title follows the entry, and the content type's placeholder (W5, W6, W2, W8, W19)"
```

Then: `superpowers:requesting-code-review` for Phase 3 (Tasks 5–8).

---

## Phase 4 — Cover and the runbook

### Task 9: The checks, and the GUI session

**Read first:**
- `docs/agents/e2e.md`;
- `e2e/driver/check.go` (four step kinds: `do`, `dispatch`, `expect`, `parity`);
- plan A's `refuses` dispatch field.

Facts the shipped checks establish:
- `type` into a single-line `TextField` **replaces** its text;
- `type` into the body's `NSTextView` **appends**, with the caret at the end;
- `focus` sets `AXFocused` and costs no foreground;
- the harness refuses a duplicate identifier, so a check clicks `api.*` controls only while
  **one** api pane is open;
- `{"expect":{"tree":"contains","text":"Placeholder: path"}}` is how an empty box's
  placeholder reads.

**Files:**
- Modify: `e2e/checks/seeded/api-bound-locks.jsonl`. Rewrite it for W16, because its old
  assertions are the region lock.
- Create:
  - `e2e/checks/seeded/api-chip-keys.jsonl` (W4);
  - `api-body-hole-cursor.jsonl` (W7);
  - `api-recent-shared.jsonl` (W15, W18);
  - `api-the-rest.jsonl` (W2, W8, W19, W5).
- Modify: `e2e/checks/uncoverable.tsv`. Add a section for the reply-only controls.

- [ ] **Step 1: Find Orca's name for Backspace.** `orca computer press-key` validates only
  that it was given one key, and the native helper maps the name. Read
  `orca computer press-key --help` from a working Orca install (the symlinked `orca` in this
  worktree cannot resolve its bundle), or the key map it documents. Use `Backspace` if it is
  listed. Otherwise use `Delete`, macOS's name for the same key. Write the name you used into
  `api-chip-keys.jsonl` and the commit message.
- [ ] **Step 2: Rewrite `api-bound-locks.jsonl`** for W16, a bound value locking only itself:

```
{"dispatch":{"action":"db_set_dsn","params":{"projectPath":"{fixtureRoot}/e2e-project/.wakil/project.json","environment":"staging","name":"bookings","driver":"sqlite","dsn":"{fixtureRoot}/bookings.db","grantWrite":true,"writeDsn":"{fixtureRoot}/bookings.db"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}
{"dispatch":{"action":"db_run_query","params":{"pane":"db-1","database":"bookings","query":"SELECT * FROM bookings ORDER BY id"}}}
{"expect":{"pane":"db-1","field":"rowCount","equals":"2"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"pane_move","params":{"id":"api-2","x":740,"y":60}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"literal":"/v1/bookings/"},{"slot":"id"},{"literal":"/"},{"slot":"nope"}]}}}
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"expect":{"tree":"contains","text":"Filled 1 · no column for nope"}}
{"expect":{"tree":"contains","text":"Placeholder: path"}}
{"do":{"click":"api.path.part.3.remove"}}
{"expect":{"pane":"api-2","field":"request.path[3]","present":false}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"do":{"type":{"into":"api.path","text":"/cancel"}}}
{"expect":{"pane":"api-2","field":"request.path[2].literal","equals":"/cancel"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"expect":{"pane":"api-2","field":"request.path[1].source.keyValues[0]","equals":"8842"}}
{"do":{"focus":"api.body"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"literal":"/v2/"},{"name":"id","binding":"live","source":{"pane":"db-1","table":"bookings","keyColumns":["id"],"keyValues":["8842"],"column":"id"}}]}}}
{"expect":{"pane":"api-2","field":"request.path[0].literal","equals":"/v2/"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"name":"id","binding":"live","source":{"pane":"db-1","table":"bookings","keyColumns":["id"],"keyValues":["8843"],"column":"id"}}]},"refuses":"api_bind"}}
{"do":{"click":"api.path.part.1.unbind"}}
{"expect":{"pane":"api-2","field":"request.path[1].slot","equals":"id"}}
```

  The `focus api.body` line moves the cursor out of the path, so Decision 27 by focus (plan
  A) lets the agent's path write land. If the `source` expect fails, the fixture's binding has
  a different table or key. Copy the values its failure prints into both dispatches.
- [ ] **Step 3: Write the new checks.**
  - `api-chip-keys.jsonl` (W4). Backspace removes a hole, unbinds a bound value, and then
    removes it:

```
{"dispatch":{"action":"db_set_dsn","params":{"projectPath":"{fixtureRoot}/e2e-project/.wakil/project.json","environment":"staging","name":"bookings","driver":"sqlite","dsn":"{fixtureRoot}/bookings.db","grantWrite":true,"writeDsn":"{fixtureRoot}/bookings.db"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}
{"dispatch":{"action":"db_run_query","params":{"pane":"db-1","database":"bookings","query":"SELECT * FROM bookings ORDER BY id"}}}
{"expect":{"pane":"db-1","field":"rowCount","equals":"2"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"pane_move","params":{"id":"api-2","x":740,"y":60}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"literal":"/v1/bookings/"},{"slot":"id"},{"slot":"nope"}]}}}
{"do":{"focus":"api.path"}}
{"do":{"press":"Backspace"}}
{"expect":{"pane":"api-2","field":"request.path[2]","present":false}}
{"expect":{"pane":"api-2","field":"request.path[1].slot","equals":"id"}}
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"do":{"focus":"api.path"}}
{"do":{"press":"Backspace"}}
{"expect":{"pane":"api-2","field":"request.path[1].slot","equals":"id"}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","present":false}}
{"do":{"focus":"api.path"}}
{"do":{"press":"Backspace"}}
{"expect":{"pane":"api-2","field":"request.path[1]","present":false}}
{"expect":{"pane":"api-2","field":"request.path[0].literal","equals":"/v1/bookings/"}}
```

  - `api-body-hole-cursor.jsonl` (W7):

```
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","method":"post","body":[{"literal":"{\"a\":1}"}]}}}
{"do":{"focus":"api.body"}}
{"do":{"press":"Left"}}
{"do":{"click":"api.body.hole"}}
{"do":{"type":{"into":"api.body.hole.name","text":"id"}}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.body[0].literal","equals":"{\"a\":1"}}
{"expect":{"pane":"api-1","field":"request.body[1].slot","equals":"id"}}
{"expect":{"pane":"api-1","field":"request.body[2].literal","equals":"}"}}
```

  - `api-recent-shared.jsonl` (W15, W18). The send is a dispatch, and so is the second open,
    so `api.recent` is clicked only after the first pane is closed:

```
{"dispatch":{"action":"db_set_dsn","params":{"projectPath":"{fixtureRoot}/e2e-project/.wakil/project.json","environment":"staging","name":"bookings","driver":"sqlite","dsn":"{fixtureRoot}/bookings.db","grantWrite":true,"writeDsn":"{fixtureRoot}/bookings.db"}}}
{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}
{"dispatch":{"action":"db_run_query","params":{"pane":"db-1","database":"bookings","query":"SELECT * FROM bookings ORDER BY id"}}}
{"expect":{"pane":"db-1","field":"rowCount","equals":"2"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"pane_move","params":{"id":"api-2","x":740,"y":60}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-2","path":[{"literal":"/v1/bookings/"},{"slot":"id"},{"literal":"/confirm"}]}}}
{"do":{"drag":{"from":"db.row.0.grip","to":"api.pane"}}}
{"expect":{"pane":"api-2","field":"request.path[1].binding","equals":"live"}}
{"expect":{"tree":"contains","text":"id = 8842 · live · bookings"}}
{"dispatch":{"action":"api_request","params":{"pane":"api-2"}}}
{"expect":{"pane":"api-2","field":"recent[0].path","equals":"/v1/bookings/<id>/confirm"}}
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"expect":{"pane":"api-3","field":"recent[0].path","equals":"/v1/bookings/<id>/confirm"}}
{"dispatch":{"action":"pane_close","params":{"id":"api-2"}}}
{"do":{"click":"api.recent"}}
{"expect":{"tree":"contains","text":"GET /v1/bookings/<id:8842>/confirm"}}
{"do":{"click":"api.recent.0.reopen"}}
{"expect":{"pane":"api-3","field":"request.path[1].binding","equals":"live"}}
```

  - `api-the-rest.jsonl` (W2, W19, W8, W5):

```
{"dispatch":{"action":"api_open","params":{"entry":"billing"}}}
{"expect":{"tree":"contains","text":"BILLING"}}
{"expect":{"tree":"contains","text":"BODY · JSON"}}
{"expect":{"tree":"contains","text":"Placeholder: application/json"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","contentType":"text/plain"}}}
{"expect":{"tree":"contains","text":"BODY · TEXT"}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","entry":"catalog"}}}
{"expect":{"tree":"contains","text":"CATALOG"}}
{"do":{"focus":"api.path"}}
{"do":{"click":"api.query.add"}}
{"do":{"keys":"page"}}
{"do":{"press":"Return"}}
{"expect":{"pane":"api-1","field":"request.query[0].name","equals":"page"}}
```

- [ ] **Step 4: The reply-only controls.** No check can draw a reply. Every fixture entry
  points at an `.invalid` host or at plan A's stalling listener, and `wakil-http` refuses a
  cleartext origin, so a local server cannot answer either. `api.response.<…>` exists only
  over a reply. In `e2e/checks/uncoverable.tsv`, after section 2, add:

```
# ---- 3. Drawn only over a reply ----------------------------------------------
#
# The fixture's entries resolve to `.invalid` hosts on purpose, and the one live
# listener (`slow`) never answers; wakil-http refuses a cleartext origin, so no
# fixture server can answer either. A control drawn only over a reply cannot be
# reached by any check. The runbook's check 5 walks it against a real API.
api.response.<…>	the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
```

- [ ] **Step 5: GUI. Ask the operator first, quit the live Wakil, and tell the peers.** Run
  `make e2e-new E2E_NEW_ARGS="--base ed1af70" > "$SCRATCH/new.log" 2>&1; rc=$?`, then
  `grep -E "red|green|FAIL" "$SCRATCH/new.log"` and `echo $rc`. Use `rc`: in zsh, `status` is
  read-only and will abort the capture. **Read each reason, not the count.** Each file must be
  red against `ed1af70`, for these reasons:
  - `api-bound-locks`: *the tree does not contain "Placeholder: path"*. The region lock drew
    no box.
  - `api-chip-keys`: `request.path[2]` is still present after the Backspace.
  - `api-body-hole-cursor`: `request.body[0].literal` is `{"a":1}`, because the hole was
    appended.
  - `api-recent-shared`: *the tree does not contain "id = 8842 · live · bookings"*.
  - `api-the-rest`: *the tree does not contain "BODY · JSON"*.

  A file that is red because the window could not be reached proves nothing: fix it and
  rerun. If `api-the-rest`'s W5 steps pass against the base, the defect needs the
  precondition the walk had. The `focus api.path` line is that precondition, and it must be
  present.
- [ ] **Step 6: GUI (same OK). `make e2e`.** Every file must be green and the coverage gate
  clean. The gate prints the new `api.response.<…>` redirect. **The split is new here.** A
  shipped `tree` assertion that now fails only because its text sits in a half that is
  scrolled out of view is a finding about what Orca reads, not about the pane. Confirm it from
  `tree.txt` in that run's evidence. Then give that check room with
  `{"dispatch":{"action":"pane_resize","params":{"id":"api-1","width":640,"height":820}}}`
  right after its `api_open`, and record the line in the commit message. Do not loosen an
  assertion.
- [ ] **Step 7: Commit the checks.**

```bash
git add e2e/checks
git commit -m "The checks for the per-part lock, Backspace on a chip, a hole at the cursor, the shared Recent, and the rest of 9c"
```

### Task 10: The runbook

**Files:** Modify `docs/wakil/phase-2c-iv-acceptance.md`. This task starts from plan A's
Task 10 text.

- [ ] **Step 1: Check 4.** In plan A's rewritten check 4, add after *"— the amber chip
  appears — then type `/confirm` after it."*:

```markdown
      Click just after the chip and press **Backspace** — **the hole goes**. Put it back,
      and later, once the drop has filled it, Backspace after the filled chip **unbinds it
      back to its hole, and a second Backspace removes that**. Each chip's `×` now sits
      **inside** the chip, at its right edge. **Does the `×` still read as part of the chip
      rather than a stray character?**
```

  After the drag sentence (*"— the chip fills, and a drop is never refused for what you are
  typing."*), add:

```markdown
      **Type into the text beside the filled chip — it stays editable; only the chip
      itself is locked** — and a second hole beside it can still be removed.
```

  After *"Type a multi-line JSON body (Return is a newline),"* add *"put the cursor between
  two keys and press `+ HOLE` — **the hole lands at the cursor**, not after the closing `}`,"*.
- [ ] **Step 2: Check 5.** Replace its text with:

```markdown
- [ ] **5. A reply draws legibly, in its own half.** From 4: **the pane splits** — the
      request above, about 55% of the pane, the response below, each scrolling on its own;
      before anything is sent the response is one line and the request takes the rest. The
      status chip, timing, size and URL **stay pinned while a long body scrolls**, and a large
      reply never pushes the request under the window's toolbar. The status carries the only
      colour and the body carries none. **Is a 500's JSON visually identical to a 200's, apart
      from the status?** Press **Headers** on the response's head — the reply's headers as a
      `HEADER | VALUE` table, names in the order received, uncoloured; **Body** goes back.
      Recent sits at the foot of the response half, at most four rows tall, and a row shows
      the values sent (`GET /customers/<id:3>/confirm`); the Bound list reads
      `id = 3 · live · …`. Open a second api pane: **Recent is the same list there**, and
      Reopen loads into the pane you pressed it in. **Does the split read as one request and
      its reply, and is the pinned status findable without hunting?**
```

- [ ] **Step 3: §0 and the counts.** Plan A added *"Amendment 9 re-walk: checks 4, 6 and 10."*
  Change it to *"Amendment 9 re-walk: checks 4, 5, 6 and 10 — 5 is the look at the split
  layout and the response's headers."* Replace the check-file count with what
  `ls e2e/checks/*/*.jsonl | wc -l` prints. Under *What this walk CANNOT establish*, add one
  sentence: *"The Body · Headers choice and its table are drawn only over a reply, so check 5
  is their only evidence (`uncoverable.tsv` §3)."*
- [ ] **Step 4: Render with the edits uncommitted.**
  `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md`. It is headless and reads
  Task 9's run records. Never edit between the `machine-walk` markers. It must render green
  against Task 9's build.
- [ ] **Step 5: Commit the hand edits and the render together.**

```bash
git add docs/wakil/phase-2c-iv-acceptance.md
git commit -m "2c-iv's runbook: Backspace on a chip, a hole at the cursor, the per-part lock, and the split pane with its headers walked in check 5"
```

Then: `superpowers:requesting-code-review` for the whole branch, followed by the **Walk** rung,
where the operator re-walks checks 4, 5, 6 and 10.

---

## Gate — done when

- [ ] `make app-test` is green. `make app-bundle` and `make controls` are clean, and the only
      family the harvest gained is `api.response.<…>`.
- [ ] `go test ./...` is green, including `e2e/driver` with the three new `AuditedSources`.
- [ ] `make e2e-new E2E_NEW_ARGS="--base ed1af70"` saw the five checks red, for the reasons
      Task 9 names. `make e2e` is green and the gate is clean.
- [ ] No shipped identifier changed. `api.<…>.part.<…>.remove` / `.unbind` now sit inside
      the chip.
- [ ] `uncoverable.tsv` gained exactly one line: `api.response.<…>`, in a new §3.
- [ ] `grep -rn "holeNameFocused" app/Sources/WakilApp` is empty, and
      `grep -rn "\"api_unbind\"" app/Sources/WakilApp` hits only `chipGesture`.
- [ ] The runbook is re-rendered green, and the re-walk is checks 4, 5, 6 and 10.
