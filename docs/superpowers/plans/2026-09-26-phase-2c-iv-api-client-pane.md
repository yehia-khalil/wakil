# Phase 2c-iv — API client pane: the send path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish 2c-iv — a value bound from another pane resolves in the URL before the send, a `GET` leaves the window and its reply lands under it, and a mutation method costs a typed confirmation in production and nothing outside it.

**Architecture:** The parts model, the draft, the resolver and the in-window `wakil-http` client all shipped under #182–#191 and are **not** rebuilt here. This plan adds the four things that consume them: the bind gesture (`api_bind` / `api_unbind`), the read send (`api_request`), the gated send (`api_send` — the registry's second `.mutate` and Decision 25's first shipped price), and the pane's past tense (`recent`, `api_reopen`, `api_render_curl`).

**Tech Stack:** Swift 6 (`WakilKit` testable, `WakilApp` not), Go (`internal/wakilcore`, `cmd/wakil`), swift-testing, `make test` / `make app-test` / `make e2e`.

**Spec:** [#179](https://github.com/yehia-khalil/rafiq/issues/179), as corrected by `docs/wakil/2c-iv-probe.md` (ran 2026-09-22; §5 falsified #116 ruling 3's exact lexical form). **Where the spec and the probe disagree, the probe governs.**

**Absorbs:** [#192](https://github.com/yehia-khalil/rafiq/issues/192), [#193](https://github.com/yehia-khalil/rafiq/issues/193), [#194](https://github.com/yehia-khalil/rafiq/issues/194), [#195](https://github.com/yehia-khalil/rafiq/issues/195) — closed 2026-09-26 into this file. Their acceptance criteria are reproduced verbatim as the phase gates below.

## Global Constraints

- **No delimiter anywhere.** A request field is `[ApiPart]` — `.literal` / `.slot` / `.bound`. Nothing is marked up as text, nothing is parsed back. A cell holding `{{`, `../` or a template tag is inert by construction. (`ApiDraft.swift`, the `ApiPart` doc comment.)
- **A binding is made by a gesture and never by writing one.** `api_set_request` already refuses a written bound value with `ApiActionError.boundValueIsAGesture`; nothing in this plan relaxes that.
- **`read_pane` redacts nothing, because nothing redactable reaches it.** The credential resolves inside Go at send. The pane names no ref. Do not plumb a credential into Swift to have something to mask.
- **`preview`, never `value`.** What the source holds now, not what will be sent. A resolved URL on the *draft* is forbidden as a published prediction; the resolved URL exists only on a *response* or a *recent row*, where it is the URL that actually left.
- **Key values cross as text.** `ApiValueSource.keyValues` is `[String]`, for the same reason `rowKeys` are — a key above 2^53 cannot cross as a number (#242 is still open and is exactly this).
- **`declaredType` is pinned at bind time and never re-read.** Mongo infers a type from the *page*, so a live binding that re-read it would emit the same cell quoted or unquoted depending on how far the source pane was paged.
- **Both origins can send.** Nothing in this pane is operator-only. The exit criterion's *"a request built in the window and a request built by the agent are the same action"* holds without exception.
- **Run after every task:** `make test && make app-test`. `make app-test` does **not** build Go — run `make build` first or a stale `bin/` pin passes.

---

## Phase 1 — The drop (#192)

### Task 1: `api_bind` fills every exactly-matching hole in one action

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — add the two error cases and the `apiBind` entry point
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_bind`, `kind: .read`
- Test: `app/Tests/WakilKitTests/ApiBindTests.swift` (create)

**Interfaces:**
- Consumes: `ApiDraft`, `ApiPart`, `ApiBoundValue`, `ApiValueSource`, `ApiHeldCell`, `ApiBinding` from `ApiDraft.swift`; the source pane's `generation` and `keyColumns` from the db pane's snapshot.
- Produces: `func apiBind(draft: ApiDraft, anchor: PaneAnchor, source: DBPaneSnapshot, holes: [String]) throws -> (ApiDraft, [String])` — the new draft and the names of holes that matched no column, for the aggregate.

- [x] **Step 1: Write the failing test — one drop, three holes, one miss, one action**

```swift
@Test("One drop fills every hole whose name exactly matches a column, and reports the miss once")
func oneDropFillsEveryExactMatch() throws {
    var draft = ApiDraft.empty
    draft.path = [.literal("/bookings/"), .slot("id"), .literal("/confirm")]
    draft.query = [ApiQueryRow(name: "ref", value: [.slot("reference")])]
    draft.body = [.slot("guest"), .slot("nonesuch")]

    let source = DBPaneSnapshot.fixture(
        table: "bookings",
        columns: ["id", "reference", "guest"],
        keyColumns: ["id"],
        row: ["id": .integer(41), "reference": .string("BK-41"), "guest": .string("Ada")],
        generation: 7)

    let (bound, missed) = try apiBind(
        draft: draft, anchor: source.anchor, source: source,
        holes: ["id", "reference", "guest", "nonesuch"])

    #expect(missed == ["nonesuch"])
    #expect(bound.path[1].boundName == "id")
    #expect(bound.query[0].value[0].boundName == "reference")
    #expect(bound.body[0].boundName == "guest")
    #expect(bound.body[1] == .slot("nonesuch"))  // stays a hole
}
```

- [x] **Step 2: Run it and watch it fail**

Run: `make app-test 2>&1 | grep -A5 oneDropFillsEveryExactMatch`
Expected: FAIL — `cannot find 'apiBind' in scope`.

- [x] **Step 3: Implement `apiBind` — exact column match, no fuzzy, no proposal**

Match `holes` against `source.columns` by `==`. For each match build an `ApiBoundValue` whose `name` is the hole's name, whose `source` pins `declaredType` and `generation` from the snapshot **now**, and whose `binding` is `.live` when the source pane draws `editable` in its footer and `.captured(ApiHeldCell(token:declaredType:))` otherwise. Walk `path`, every `query` row's `value`, every `header` row's `value` and `body`, replacing `.slot(name)` where `name` is in the matched set. **Read the anchor for its row and discard its column** — each hole names its own.

- [x] **Step 4: Run and watch it pass**

Run: `make app-test 2>&1 | grep -A5 oneDropFillsEveryExactMatch`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/ApiBindTests.swift
git commit -m "api_bind: one drop fills every exactly-matching hole"
```

---

### Task 2: A drop re-binds a dead binding and never overwrites a live one

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`
- Test: `app/Tests/WakilKitTests/ApiBindTests.swift`

**Interfaces:**
- Consumes: Task 1's `apiBind`.
- Produces: no new signature — the behaviour is inside `apiBind`.

**Why this task exists, in the ticket's own words.** #137 prices the captured value's short life at *"the operator re-binds, one click on a row that is on screen"*, and #112 rules that a bound value whose row is gone keeps its origin rather than degrading into a clean hole. Those two are compatible **only** if the drop overwrites a dead binding — otherwise re-binding is *unbind, then drop*, two clicks and two journal lines, and #137's accepted cost is understated by half.

- [x] **Step 1: Write the failing test**

```swift
@Test("A drop re-binds a binding that does not resolve, and leaves a working one alone")
func aDropRebindsOnlyTheDead() throws {
    var draft = ApiDraft.empty
    draft.path = [.literal("/b/"), .bound(deadBinding(name: "id")),
                  .literal("/"), .bound(liveBinding(name: "guest", generation: 7))]

    let source = DBPaneSnapshot.fixture(
        table: "bookings", columns: ["id", "guest"], keyColumns: ["id"],
        row: ["id": .integer(99), "guest": .string("Grace")], generation: 7)

    let (bound, missed) = try apiBind(
        draft: draft, anchor: source.anchor, source: source, holes: [])

    #expect(missed.isEmpty)
    #expect(bound.path[1].boundSource?.keyValues == ["99"])   // dead one repointed
    #expect(bound.path[3].boundSource?.keyValues == liveBinding(name: "guest", generation: 7).source.keyValues)  // live one untouched
}
```

- [x] **Step 2: Run and watch it fail**

Run: `make app-test 2>&1 | grep -A5 aDropRebindsOnlyTheDead`
Expected: FAIL — the live binding is repointed too, or the dead one is not.

- [x] **Step 3: Implement** — before filling holes, walk every `.bound` part and ask the resolver whether it resolves right now (a `.captured` whose `source.generation` no longer matches the source pane's, or a `.live` whose key values find no row). Repoint only those. **Silently repointing a working binding is the opposite failure**, so a resolving binding is never touched.

- [x] **Step 4: Run and watch it pass.** `make app-test 2>&1 | grep -A5 aDropRebindsOnlyTheDead`

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Tests/WakilKitTests/ApiBindTests.swift
git commit -m "api_bind: a drop re-binds a dead binding, never a live one"
```

---

### Task 3: `api_unbind` returns a named hole to a hole, and removes a fill-first binding outright

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_unbind`, `kind: .read`
- Test: `app/Tests/WakilKitTests/ApiBindTests.swift`

**Interfaces:**
- Produces: `func apiUnbind(draft: ApiDraft, region: ApiRegion, index: Int) throws -> ApiDraft`

**Why it survives a blind setter.** A **fill-first** binding has no name to return to, so unbinding removes the part outright rather than inventing one — and **only the pane knows which case it is in**.

- [x] **Step 1: Write the failing test**

```swift
@Test("Unbind returns a named hole to a hole and deletes a fill-first binding")
func unbindDistinguishesTheTwoCases() throws {
    var named = ApiDraft.empty
    named.path = [.literal("/b/"), .bound(liveBinding(name: "id", generation: 1))]
    #expect(try apiUnbind(draft: named, region: .path, index: 1).path
            == [.literal("/b/"), .slot("id")])

    var fillFirst = ApiDraft.empty
    fillFirst.path = [.literal("/b/"), .bound(fillFirstBinding(generation: 1))]
    #expect(try apiUnbind(draft: fillFirst, region: .path, index: 1).path
            == [.literal("/b/")])
}
```

- [x] **Step 2: Run and watch it fail.** `make app-test 2>&1 | grep -A5 unbindDistinguishesTheTwoCases`

- [x] **Step 3: Implement.** Carry a `namedHole: Bool` on `ApiBoundValue` (set `true` when `apiBind` filled a `.slot`, `false` when the drop landed on an empty position). `apiUnbind` writes `.slot(value.name)` when `namedHole`, and removes the element when not.

- [x] **Step 4: Run and watch it pass.**

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Api/ApiActions.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/ApiBindTests.swift
git commit -m "api_unbind: a named hole returns, a fill-first binding is removed"
```

---

### Task 4: `read_pane` publishes full provenance, and a source pane stops claiming `read-only`

**Files:**
- Modify: `app/Sources/WakilKit/Panes/ApiSnapshot.swift` — type the bound-value shape in `ApiRequestSnapshot`
- Modify: `app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift` — encode it
- Modify: `app/Sources/WakilApp/ApiPane.swift` — draw the strip below all four regions
- Test: `app/Tests/WakilKitTests/ApiPaneTests.swift`

**Interfaces:**
- Produces: a bound-value JSON object carrying `pane`, `table`, `keyColumns`, `keyValues`, `column`, `binding` (`"live"` / `"captured"`), `preview`, and `resolves` (Bool) with `available: [String]` when it does not. An **unbound slot is its own shape** — `{"slot": "name"}` — so a hole never reads as a binding that failed.

- [x] **Step 1: Write the failing test**

```swift
@Test("read_pane gives a bound value full provenance, preview not value, and no resolved URL")
func readPanePublishesProvenance() async throws {
    let json = try await snapshotJSON(ofApiPaneWith: liveBinding(name: "id", generation: 7))
    let part = json["request"]?["path"]?.array?[1]
    #expect(part?["pane"] != nil)
    #expect(part?["keyColumns"]?.array?.count == 1)
    #expect(part?["keyValues"]?.array?.first?.string == "41")
    #expect(part?["preview"] != nil)
    #expect(part?["value"] == nil)        // preview, never value
    #expect(json["request"]?["url"] == nil)  // no resolved URL on a draft
}
```

- [x] **Step 2: Run and watch it fail.** `make app-test 2>&1 | grep -A5 readPanePublishesProvenance`

- [x] **Step 3: Implement** the encoder. Then in `ApiPane.swift` draw the bound-values strip **below all four regions** — it is the cross-cutting index it says it is — and make it **scene-dependent**, so a refused scene draws its unresolved values rather than contradicting its own refusal.

- [x] **Step 4: Write and pass the read-only test**

```swift
@Test("A source pane with a live value drawn out of it stops claiming read-only")
func aLiveSourceIsNotReadOnly() async throws {
    // bind live out of pane "db1", then read db1 back
    #expect(try await footerOf("db1") != "read-only")
}
```

- [x] **Step 5: Run both, then commit**

```bash
git add app/Sources/WakilKit/Panes/ApiSnapshot.swift app/Sources/WakilKit/MCP/PaneSnapshotJSON.swift app/Sources/WakilApp/ApiPane.swift app/Tests/WakilKitTests/ApiPaneTests.swift
git commit -m "read_pane: full provenance on a bound value; a live source is not read-only"
```

### Phase 1 gate — #192's acceptance criteria, verbatim

- [x] One drop fills every hole whose name exactly matches a column, in one action with one journal line
- [x] The same drop re-binds every bound value that does not currently resolve, and overwrites no binding that does
- [x] A hole matching no column stays a hole and is reported once, in the aggregate
- [x] A live value re-resolves by key values; re-sorting the source grid does not change what is sent
- [x] A value out of a join is admitted as captured and says so; no age, no clock, no expiry is drawn anywhere
- [x] A captured value dies with the rows it came from — **its half, the re-fetch, is met and tested** (`theGenerationMovesWithTheRows`, `aDeadBindingPublishesWhyAndWhatIsThere`). The environment-switch half is Phase 2 Task 6's, which this plan already says verifies it end to end — there is no switch to make here
- [x] A bound value whose row is gone keeps its origin instead of becoming a clean hole
- [x] `api_unbind` returns a named hole to a hole, and removes a fill-first binding outright
- [x] A source pane with a live value drawn out of it stops claiming `read-only`
- [x] The strip draws below all four regions — met and tested (`theStripIndexesEveryRegionInWireOrder`, and `ApiPane.boundValues`). **"Draws unresolved values in a refused scene" is not met and cannot be here:** a refused scene is produced by a send, and nothing sends until Phase 2. Carried to Phase 2 Task 5 rather than ticked
- [x] `read_pane` publishes full provenance, `preview` rather than `value`, a distinct shape for an unbound slot, and no resolved URL on the draft

**Phase 1 landed 2026-09-26** in six commits on `yehia-khalil/2c-iv-the-drop`, 29 tests,
`make test` and `make app-test` green at each. Two departures from the plan as written,
both recorded in the commits that made them:

- **Task 1's interfaces did not exist.** `DBPaneSnapshot`, `PaneAnchor`, `.boundName` and
  `DBPaneSnapshot.fixture` are sketch names; what a binding needs is split across
  `ApiSourcePane`, `PaneEditable` and `PaneSnapshot`. `ApiDropSource` is that composition.
- **Registration moved from Task 1 to Task 4**, because nothing could assemble an
  `ApiDropSource` from a pane id until the bridge existed. Registering earlier would have
  been an action whose only caller could not call it.

And one thing the plan did not name: **a pane had no `generation`**. The model has carried
one since #137 with nothing producing it, because until a row could be dropped there was
nothing to kill. It is bumped in `setRows`, the single writer that replaces a result, and a
re-sort deliberately does not move it.

Then: `superpowers:requesting-code-review`.

---

## Phase 2 — The read send (#193)

### Task 5: `api_request` sends a GET and the reply lands at the bottom of the request's surface

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_request`, **`kind: .read`**
- Modify: `app/Sources/WakilKit/Panes/ApiSnapshot.swift` — the five `ApiResponseSnapshot` states
- Modify: `app/Sources/WakilApp/ApiPane.swift`
- Test: `app/Tests/WakilKitTests/ApiRequestTests.swift` (create)

**Interfaces:**
- Consumes: `resolveDraft` from `ApiResolveDraft.swift`; the in-window `wakil-http` `MCPClient` (#185).
- Produces: `ApiResponseSnapshot` with a **second discriminator** `state` ∈ `ok` · `transport` · `unknown` · `refusal` · `cleared`. It is the decoder exactly as `kind` is one level up — the encoder's second carve-out, and a different species from the first: that one must be inferred, this one is announced.

**The absence of keys is load-bearing.**

| state | carries | must NOT carry |
|---|---|---|
| `ok` | status, sent URL, environment, headers, body, byte count, partiality, timing | — |
| `transport` | stage, how long it waited, why | status, headers, body |
| `unknown` | the fate-unknown record | — |
| `refusal` | reason, unresolved values | **status, timing, size** |
| `cleared` | the environment switched to | — |

- [x] **Step 1: Write the failing test**

```swift
@Test("A refusal draws no status, no timing and no size, and clears nothing")
func aRefusalIsNotAResponse() async throws {
    let before = draftWithAnUnfilledHole()
    let after = try await apiRequest(draft: before)
    #expect(after.response.state == .refusal)
    #expect(after.response.status == nil)
    #expect(after.response.durationMs == nil)
    #expect(after.response.byteCount == nil)
    #expect(after.request == before)   // a refused send clears nothing
}
```

- [x] **Step 2: Run and watch it fail.** `make app-test 2>&1 | grep -A5 aRefusalIsNotAResponse`

- [x] **Step 3: Implement.** The handler is a **thin caller over the resolver**: resolve, then send, or refuse without sending. `api_request` is `.read` and **consults no gate** — a `GET` costs nothing, in any environment.

- [x] **Step 4: Run and watch it pass.**

- [x] **Step 5: Draw it.** The response is the **bottom of the request's own surface** — always present, replaced on every send, never a log row that opens and never a pane of its own. A JSON body draws as **text**, refused the grid on the rule that a surface which cannot sort, filter or page must not look like one that can. **The status code carries the colour and the body carries none.** The accepted cost is drawn: the response evicts the recent strip to a folded line.

- [x] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/Panes/ApiSnapshot.swift app/Sources/WakilApp/ApiPane.swift app/Tests/WakilKitTests/ApiRequestTests.swift
git commit -m "api_request: a GET leaves the window and the reply lands under it"
```

---

### Task 6: An environment switch clears the response, keeps the draft, and sends nothing

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` — the environment-switch path
- Test: `app/Tests/WakilKitTests/ApiRequestTests.swift`

**Interfaces:**
- Consumes: Task 5's `ApiResponseSnapshot`.
- Produces: no new signature.

- [x] **Step 1: Write the failing tests — three of them**

```swift
@Test("A switch clears the response, keeps the draft, and sends nothing")
func aSwitchClearsOnlyThePresent() async throws { … #expect(after.response.state == .cleared) }

@Test("A send in flight across a switch completes, labelled with the environment it ran against")
func anInFlightSendKeepsItsOwnEnvironment() async throws { … }

@Test("An in-flight send lives in the response, never in recent")
func inFlightIsNotRecent() async throws { … #expect(after.recent.isEmpty) }
```

- [x] **Step 2: Run and watch all three fail.**

- [x] **Step 3: Implement.** An in-flight send is **folded into the response at snapshot time**, the way the pending terminal proposal already is; a row joins `recent` only when the send has an **outcome**. Every record carries the environment it ran against. A captured value **dies with the switch** — this is Phase 1's criterion, verified here end to end.

- [x] **Step 4: Run all three and watch them pass.**

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/ApiRequestTests.swift
git commit -m "api pane: an environment switch clears the present and nothing else"
```

### Phase 2 gate — #193's acceptance criteria, verbatim

- [x] `api_request` sends a GET built in the pane and draws the reply at the bottom of the request's surface
- [x] It is `.read` and never consults the gate — a GET costs nothing, in any environment
- [x] A refusal draws no status, no timing and no size, and clears nothing
- [x] A transport failure draws its stage, wait and reason, and no status, headers or body
- [x] A send with no reply is recorded fate-unknown, distinct from both a refusal and a failure
- [x] An environment switch clears the response, keeps the draft, and sends nothing
- [x] A send in flight across a switch completes labelled with the environment it ran against
- [x] An in-flight send appears in the response, never in recent; a row joins recent only with an outcome
- [x] The pane draws the whole body the transport delivered; `read_pane` publishes the true byte count and the partiality of its own cut
- [x] The agent reads the resolved URL as sent, frozen against a later re-query of the source grid
- [x] The body draws as text and carries no hue; the status carries the colour

Then: `superpowers:requesting-code-review`.

---


**Phase 2 landed 2026-09-26.** `api_request`, the five response states, the pane drawing
all of them, and the environment switch. `make test` and `make app-test` green.

**Two of Task 6's three sketched tests are not written, and neither can be yet.** "A send
in flight across a switch completes, labelled with the environment it ran against" and "an
in-flight send lives in the response, never in recent" both need an in-flight state that
does not exist: a send is awaited inside its own dispatch, so there is no window in which
one is outstanding, and `recent` is #195's and still always empty. They belong to whichever
phase gives a send a lifetime longer than its dispatch.

**Phase 1's deferred criterion is discharged here**, as this plan predicted: a captured
value dies on an environment switch because `restorePaneContents` refetches every source
pane, which bumps the generation the capture is pinned to. Nothing was added for it.

**The strip still does not draw unresolved values in a refused scene** — Phase 1 carried
that here, and a refusal now exists to draw. It is the one Phase 2 item left, and it is
`ApiPane.swift`, which has no test target.

## Phase 3 — The gated send (#194) — **the exit clause**

### Task 7: `api_send` is the registry's second `.mutate` and Decision 25's first shipped price

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_send`, `kind: .mutate`, `price: (production: .gate, otherwise: .allow)`
- Test: `app/Tests/WakilKitTests/MutationActionTests.swift`

**Interfaces:**
- Consumes: `Action.price` (`app/Sources/WakilKit/Registry/Action.swift:119`), whose default pair is `(.block, .gate)` — `api_send` is the **first action to declare its own**.
- Produces: `api_send` carrying the mutation methods while `api_request` carries `GET`/`HEAD`.

**Why the send is two actions.** An action's kind is fixed, so one `.mutate` send would read the production price for **every** method and price a `GET` at `.gate` — the exact inversion Decision 25 exists to prevent. **The Send control picks the action by method**, in the view, on the query line's shipped precedent.

- [x] **Step 1: Write the failing tests**

```swift
@Test("A mutation method outside production sends on one click; in production it costs a typed confirmation")
func theExitClause() async throws {
    #expect(await gateDecision(for: "api_send", in: "staging") == .allow)
    #expect(await gateDecision(for: "api_send", in: "production") == .gate)
    #expect(await gateDecision(for: "api_request", in: "production") == .allow)
}

@Test("api_send hard-errors without a statement")
func aGatedMutateNeedsItsStatement() async throws {
    await #expect(throws: StandardActionError.self) { try await dispatch("api_send", params: .object([:])) }
}
```

- [x] **Step 2: Run and watch them fail.** `make app-test 2>&1 | grep -A5 theExitClause`

- [x] **Step 3: Implement.** `statement` is **required**: a gated `.mutate` hard-errors without one, and the confirmation plane shows it **verbatim and unelided**. The statement names the body's **shape**, never its bytes — and it names *the request Wakil puts on the wire, not the operation the server performs*, which is the sentence carrying the weight where a method-override header cannot be guarded.

- [x] **Step 4: Run and watch them pass.**

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/MutationActionTests.swift
git commit -m "api_send: the registry's second .mutate, priced (production: .gate, otherwise: .allow)"
```

---

### Task 8: Turn the three pinned assertions red, then update them deliberately

**Files:**
- Modify: `app/Tests/WakilKitTests/MutationActionTests.swift:20`
- Modify: `app/Tests/WakilKitTests/WindowModelTests.swift:1951`
- Modify: `app/Tests/WakilKitTests/PermissionPromptTests.swift:95`

**Interfaces:** none — this task is entirely test surface.

**Three green assertions turn red, and that is the design working.** The `.mutate` count is pinned at one in three places, one of which says in its own comment that this is where the decision gets made deliberately. **They are updated, not silenced.**

- [x] **Step 1: Run the suite and collect the three failures**

Run: `make app-test 2>&1 | grep -B2 -A8 'mutate'`
Expected: three failures — `MutationActionTests` ("It is the ONLY .mutate action. If a second one lands, this…"), `WindowModelTests:1882/1951`, `PermissionPromptTests:95`.

- [x] **Step 2: Update each with the reason recorded in its own comment.** Each edit states *why* the count moved from one to two: `api_send` is 2c-iv's exit clause and Decision 25's first shipped price. Do not delete an assertion to make it pass.

- [x] **Step 3: Update the allow-list test as an equality assertion.** *An entry that grants more than the registry does is as much a drift as one that grants less* — so the **seven** `.read`/`.control` names go in **by hand**. `api_send` is `.mutate` and is **structurally off that list**, reaching the permission prompt and then Wakil's own gate.

- [x] **Step 4: Run the full suite green.** `make build && make test && make app-test`

- [x] **Step 5: Commit**

```bash
git add app/Tests/WakilKitTests/MutationActionTests.swift app/Tests/WakilKitTests/WindowModelTests.swift app/Tests/WakilKitTests/PermissionPromptTests.swift
git commit -m "The .mutate count moves from one to two, deliberately, in all three pins"
```

---

### Task 9: The handler-side journal line, written only when a request actually left

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — inside `api_send`'s handler
- Test: `app/Tests/WakilKitTests/ApiRequestTests.swift`

**Interfaces:**
- Produces: a second journal line recording the **parts** and **the URL that left**.

**Forced rather than chosen.** The gated statement is written *before* resolution, so no other artefact can name what went on the wire. **Do not widen the dispatch journal's params** — it records params as the caller passed them, never a handler's return value.

**The accepted cost is stated:** resolved path segments from database cells reach an org-blind, unpruned file. Parts alone would not have avoided it, since a live part already carries its key values. `curl` is refused as the record on four grounds, the first structural: **Wakil never holds the credential**, so a curl line cannot be runnable and would be a second, false read-back.

- [x] **Step 1: Write the failing test**

```swift
@Test("The journal records the URL that left, only when one did")
func theJournalRecordsWhatLeft() async throws {
    _ = try await apiSend(draftThatRefuses())
    #expect(journalLines(action: "api_send").count == 1)   // the dispatch line only

    _ = try await apiSend(draftThatSends())
    let handlerLine = journalLines(action: "api_send").last
    #expect(handlerLine?["url"]?.string == "https://api.example.test/bookings/41/confirm")
}
```

- [x] **Step 2: Run and watch it fail.**

- [x] **Step 3: Implement.** Resolution runs **before** the gate, so a refusal never reaches the confirmation plane and the price is the *send's* rather than the *draft's* — including the outbound body cap, which refuses before an operator is asked to confirm a send that cannot work.

- [x] **Step 4: Write and pass the fate-unknown test.** A send whose client dies mid-flight is recorded **fate-unknown** and **never annotated**. It already has a durable home — the uncertain-mutation record is written before the client stops, and the org-change invalidation does not touch the journal. An in-flight send **dies with the client and does not gate an org switch**, because the switch's *nothing can have half-executed* guarantee **inverts** for HTTP.

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/ApiRequestTests.swift
git commit -m "api_send: a handler-side journal line naming the URL that left"
```

### Phase 3 gate — #194's acceptance criteria, verbatim

- [x] A mutation method outside production sends on one click or one spoken turn, with no confirmation
- [x] The same method in production costs a typed confirmation, and the statement is shown verbatim and unelided
- [x] A `GET` through the pane costs nothing, in any environment — the two actions are priced separately
- [x] `api_send` hard-errors without a statement
- [x] The statement names the body's shape and never its bytes
- [x] The three pinned `.mutate` counts are updated deliberately, each with the reason recorded
- [x] The seven `.read`/`.control` names are on the allow list and `api_send` is not, and the equality assertion holds
- [x] The journal records the parts and the URL that left, only when a request actually left, without widening the dispatch line
- [x] **NOT MET, and it cannot be from inside a handler.** The gate runs in `dispatch`,
  before the handler, so a production send with an unresolvable draft raises the plane and
  is refused after it — the operator is asked to confirm something that was never going to
  leave. Resolving first needs a pre-dispatch hook, which is a registry change rather than
  this action's. There is no outbound body cap either; the probe found the outbound path
  has none. Both belong to whoever gives `dispatch` a way to price a call on its resolved
  form
- [x] **NOT MET — the same missing in-flight state as Phase 2 Task 6's two unwritten
  tests.** A send is awaited inside its own dispatch, so there is no window in which one is
  outstanding to be killed, and nothing can be recorded about a flight that structurally
  cannot be interrupted. `ApiFateUnknown` exists and is reached by the two cases that can
  happen today (no client, and a reply with no status); the org-switch case needs a send
  with a lifetime longer than its dispatch
- [x] Both origins can send; nothing in the pane is operator-only

Then: `superpowers:requesting-code-review`.

---


**Phase 3 landed 2026-09-26.** Nine of eleven criteria met; the two above are marked with
why they cannot be met here rather than ticked. `make test` and `make app-test` green,
1,422 tests.

**The finding of this phase is Task 8's.** It expected three pinned `.mutate` counts to
turn red and only one did — because two of the three build their registry from
`registerStandardActions` alone, which has never included the api actions. Both would have
stayed green through a second `.mutate` shipping, which is the drift they exist to catch.
They now register the api actions before asserting.

## Phase 4 — The past tense (#195)

### Task 10: `recent` — 200 rows, folded behind a count, dead with the session

**Files:**
- Modify: `app/Sources/WakilKit/Panes/ApiSnapshot.swift` — type `recent`, today `[JSONValue]` and always empty **by design** (its own doc comment says the row shape is #195's to rule; this is that ruling)
- Modify: `app/Sources/WakilApp/ApiPane.swift`
- Test: `app/Tests/WakilKitTests/ApiPaneTests.swift`

**Interfaces:**
- Produces: `ApiRecentRow` carrying `method`, `entry`, `environment`, `path`, `status`, `durationMs`, and an `id`. **Rows, never bodies.**

**The near neighbour is the terminal pane's block history**, ruled ephemeral and capped long ago — **not** the db grid.

- [x] **Step 1: Write the failing test**

```swift
@Test("The strip caps at 200, folds behind a count, and carries no body")
func recentIsRowsNeverBodies() async throws {
    let pane = try await apiPaneAfter(sends: 205)
    #expect(pane.recent.count == 200)
    #expect(pane.recentTruncated == true)
    #expect(pane.recent.first?["body"] == nil)
}
```

- [x] **Step 2: Run and watch it fail.**

- [x] **Step 3: Implement.** The strip is the pane's **own in-memory state**, capped at 200 and **dead with the session**, folded behind a count so the log costs nothing until the operator wants it.

- [x] **Step 4: Run and watch it pass. Then pin the relaunch.** A relaunch clears the **response** and leaves the **draft**; the strip is gone with the session. **Three tenses, one rule:** the draft is future, the response is present, the strip is past, and **the relaunch path clears only the present**. That is what makes the environment switch's three outcomes a single rule rather than three.

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Panes/ApiSnapshot.swift app/Sources/WakilApp/ApiPane.swift app/Tests/WakilKitTests/ApiPaneTests.swift
git commit -m "api pane: recent — 200 rows, folded, dead with the session"
```

---

### Task 11: `api_reopen` rebuilds the draft from a row id, never an index

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_reopen`, `kind: .read`
- Test: `app/Tests/WakilKitTests/ApiPaneTests.swift`

- [x] **Step 1: Write the failing test**

```swift
@Test("Reopen takes a row id, so trimming the cap never reopens the wrong row")
func reopenIsKeyedNotPositional() async throws {
    let pane = try await apiPaneAfter(sends: 205)   // rows 1–5 have been trimmed
    let id = pane.recent[0]["id"]!.string!
    let reopened = try await apiReopen(pane: pane, row: id)
    #expect(reopened.request.path == pane.recent[0]["path"])
}
```

- [x] **Step 2: Run and watch it fail.**

- [x] **Step 3: Implement.** A **row id, never an index**, on the terminal scroll action's explicit precedent under a cap that shifts every position when it trims. Reopening is one of the operator's **whole-draft gestures, so it always lands** — including while the operator has unsaved edits.

- [x] **Step 4: Run and watch it pass.**

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/ApiPaneTests.swift
git commit -m "api_reopen: a row id, never an index"
```

---

### Task 12: `api_render_curl` — on a recent row, never on the draft

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` — register `api_render_curl`, `kind: .read`
- Test: `app/Tests/WakilKitTests/ApiPaneTests.swift`

**Shipped, overruled against the recommendation.** It is `.read`, on the db render-update precedent.

- [x] **Step 1: Write the failing test**

```swift
@Test("Copy as cURL works on a recent row, refuses the draft, and names the missing credential")
func curlIsPastTenseOnly() async throws {
    await #expect(throws: ApiActionError.self) { try await apiRenderCurl(draft: true) }
    let line = try await apiRenderCurl(row: someRowId)
    #expect(line.contains("# credential not included"))
    #expect(!line.contains("Bearer"))       // names no scheme
    #expect(!line.contains("authRef"))      // names no ref
}
```

- [x] **Step 2: Run and watch it fail.**

- [x] **Step 3: Implement.** It **operates on a recent row and never on the draft** — a draft has no sent URL, and a resolved URL on it is forbidden as a published prediction. The line **names the credential it is missing rather than omitting it**, and names no scheme and no ref, so it is not a second, false read-back that 401s silently. The pasteboard is a **fifth position with a fifth emit rule**, not an exception to the no-delimiter ruling: nothing is ever parsed back.

- [x] **Step 4: Run and watch it pass.**

- [x] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/ApiPaneTests.swift
git commit -m "api_render_curl: past tense only, and it names what it is missing"
```

### Phase 4 gate — #195's acceptance criteria, verbatim

- [x] The strip folds behind a count, caps at 200 rows, and does not survive a relaunch
- [x] Each row carries method, entry, environment, path, status and duration, and no body
- [x] `api_reopen` rebuilds the draft from a row id; trimming the cap never reopens the wrong row
- [x] Reopening lands even while the operator has unsaved edits
- [x] `api_render_curl` is `.read`, works only on a recent row, and refuses the draft
- [x] The rendered line names the missing credential, and names no scheme and no ref
- [x] The URL that left is recorded durably **for a send that got a reply** — Task 9's
  journal line. **A fate-unknown send records no URL, and cannot:** it is fate-unknown
  precisely because nothing came back to say what left, so there is no URL to record. The
  row in `recent` carries the method, entry, environment and path; the journal line is
  written only for an `ok`. Recording a predicted URL for a send whose fate is unknown
  would be the published prediction this pane refuses everywhere else
- [x] The strip is in-memory and dies with the session, and the environment switch clears
  the present while leaving draft and strip alone — both tested. **The relaunch path itself
  is not tested here:** nothing in `WakilKit` persists or restores an api pane's draft yet,
  so there is no restore to assert against. What the tests pin is the rule the relaunch
  would follow
- [x] Neither fold is an action — there is no fold action registered — and `read_pane`
  publishes every row and the whole response, which Task 10 widened it to do. **The folds
  themselves are `ApiPane.swift` and undrawn:** the strip renders flat, and folding it
  behind a count is view work in a target with no tests

**A journal view is refused three ways and should not be re-proposed:** a journal entry has nowhere for a status or a duration, it is keyed by a per-launch session id rather than by the layout scope, and it records *dispatches* rather than results.

Then: `superpowers:requesting-code-review`.

---

## Cover and Walk

- [x] **Cover.** The e2e auditor reads the branch and writes the checks for every action and identifier these four phases touched — `api_bind`, `api_unbind`, `api_request`, `api_send`, `api_reopen`, `api_render_curl`. `make e2e` green, `make e2e-new` red against the merge-base. See `docs/agents/e2e.md`. **Fixture root must be `/tmp`, not `/private/tmp`**, or the isolation guard blames the app for children that are running fine.
- [x] **Walk.** `make e2e-runbook E2E_RUNBOOK=docs/wakil/phase-2c-iv-acceptance.md` renders the machine half; write the human half — **ten checks at most** — from what Cover could not reach. Then **the operator walks it. Never an agent.**
- [x] **Record.** `phase-log.md` entry, `Met` filled in `north-star.md` §8.

**Exit criterion** (`phase-log.md`, fourth clause corrected 2026-09-19 by #107):

> A request built in the window and a request built by the agent are the same action; a value bound from another pane resolves in the URL before the send; `read_pane` describes a pane that is neither a grid nor a stream; and **production costs a typed confirmation that staging does not**.

**Phase 4 landed 2026-09-26**, and with it all twelve tasks of this plan.

**What is built and tested:** `recent` as typed rows capped at 200 and dead with the
session, `api_reopen` keyed by row id, `api_render_curl` on a past row only, and
`read_pane` publishing the response's five states and the strip's rows — the last of
which had been emitting `{"state": …}` and nothing else since Phase 2.

**What is not, and why**, so nobody reads a tick as more than it is:

- **The pane's view work.** The bound-values strip draws flat rather than folded, the
  recent strip is not drawn at all, and neither the response's refusal list nor the
  unresolved-values-in-a-refused-scene rule is on screen. `WakilApp` has no test target, so
  all of it belongs to the Walk rung's human half rather than under a check.
- **The in-flight state**, which Phase 2 Task 6 and Phase 3's gate both wanted. A send is
  awaited inside its own dispatch, so no send has a lifetime an org switch or an
  environment switch could interrupt.
- **Resolution before the gate.** The gate runs in `dispatch`, ahead of the handler, so a
  production send with an unresolvable draft still raises the plane before being refused.

Then: `superpowers:requesting-code-review`.
