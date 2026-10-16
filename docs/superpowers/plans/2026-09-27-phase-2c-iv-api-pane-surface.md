# Phase 2c-iv — the API pane's surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 2c-iv's exit criterion true. *"A request built **in the window** and a request
built by the agent are the same action"* — and today nothing in the window can build one.
`ApiPane.swift` has zero Buttons, zero tap gestures and zero accessibility identifiers, so
every action the send path shipped is agent-only.

**Architecture:** The capability layer is finished and tested (#310, twelve tasks). This
plan adds no actions and changes no rulings: it gives the operator controls that dispatch
the actions that already exist, and gives those controls names.

**Tech Stack:** SwiftUI in `WakilApp` (**no test target**), rulings in `WakilKit` (tested),
`e2e/checks/seeded/` for what the controls do.

**Spec:** [#179](https://github.com/yehia-khalil/rafiq/issues/179). Stories 3, 19–32, 46–50
and 56 are this plan's; nothing here re-opens one.

## Global constraints

- **Every ruling goes in `WakilKit`, not in the view.** `WakilApp` has no test target, and
  `apiChooserIsEnabled` set the precedent: which control is enabled, what a row says, what a
  press dispatches — all testable functions, with the view calling them. A `disabled(…)`
  expression inline in a `View` is a ruling nothing can pin.
- **Every actionable control carries an `.accessibilityIdentifier`, and the identifier goes
  on an element with an accessibility ACTION behind it.** `Landing.swift:265` is the rule:
  *"a tap gesture is not an accessibility action, so VoiceOver would announce a button that
  does nothing when activated."* An identifier on a `Text` is that announcement.
- **`ApiPane.swift` joins `AuditedSources` in the task that names its controls** — the
  deliberate act `identifiers.go` asks for, never a change that merely touches the file.
- **The operator's edits are marked.** Every field that can be typed into calls
  `PaneStore.noteApiEdit`, which is what Decision 27's refusal reads — the mark has had no
  caller outside tests since #191, and that is why the one-author rule cannot fire on screen.
- **No new actions.** If a control needs something the registry cannot do, that is a finding
  for the residue, not a new registration.

---

## Phase 1 — The operator can send

### Task 1: A Send control that dispatches the right action for the method

**Files:**
- Modify: `app/Sources/WakilKit/Api/ApiActions.swift` — the ruling
- Modify: `app/Sources/WakilApp/ApiPane.swift` — the control
- Modify: `e2e/driver/identifiers.go` — `ApiPane.swift` joins `AuditedSources`
- Test: `app/Tests/WakilKitTests/ApiSurfaceTests.swift` (create)

**Interfaces:**
- Produces: `apiSendControl(method:) -> (action: String, label: String)` — which action a
  press dispatches and what the button says.

**Why a ruling and not a `if method == "GET"` in the view.** The split between
`api_request` and `api_send` is `ActionKind`'s, and getting it wrong in the view means a
`GET` priced at the gate or a `POST` that never reaches it. The query line's Run control is
the shipped precedent for a button whose action depends on state.

- [x] **Step 1: Write the failing test** — a read method presses `api_request`, a mutation
  presses `api_send`, and the label says which in the operator's words.
- [x] **Step 2: Run and watch it fail.**
- [x] **Step 3: Implement the ruling, then draw the control** with
  `.accessibilityIdentifier("api.send")` and an `.accessibilityAction(.default)`.
- [x] **Step 4: Add `ApiPane.swift` to `AuditedSources`** and run `make controls` — it will
  name every unnamed control in the file, which is the work of Task 2.
- [x] **Step 5: Run `make test && make app-test`, then commit.**

### Task 2: The entry chooser, and the regions the operator types into

**Files:**
- Modify: `app/Sources/WakilApp/ApiPane.swift`
- Test: `app/Tests/WakilKitTests/ApiSurfaceTests.swift`

**Interfaces:** none new — the fields dispatch `api_set_request` with one region each.

- [x] **Step 1: Write the failing tests** — the chooser is disabled at one entry
  (`apiChooserIsEnabled`, which already exists and nothing draws from), and a field's edit
  marks the pane (`noteApiEdit`) so Decision 27 can fire.
- [x] **Step 2: Run and watch them fail.**
- [x] **Step 3: Draw the chooser as a `Menu` over the environment's entries**, and the path,
  query, header and body regions as editable rows. Each names itself:
  `api.entry`, `api.path`, `api.query.<name>`, `api.header.<name>`, `api.contentType`,
  `api.body`.
- [x] **Step 4: `make controls` is green — every actionable control is named.**
- [x] **Step 5: Commit.**

### Phase 1 gate

- [x] The operator can build and send a request without the agent
- [x] A `GET` presses `api_request` and a `POST` presses `api_send`
- [x] `ApiPane.swift` is in `AuditedSources` and `make controls` is green
- [x] Typing in a field marks the pane, so Decision 27's refusal can fire on screen
- [x] An identifier is only ever on an element with an accessibility action

---

## Phase 2 — Cover

### Task 3: The checks the controls make possible

**Files:**
- Modify: `e2e/checks/seeded/api-send.jsonl`
- Create: `e2e/checks/seeded/api-surface.jsonl`

- [x] **Step 1:** A check that drives the pane by hand — click the entry chooser, type a
  path, press Send — and asserts the response state, which is the operator channel of
  everything #310 built.
- [x] **Step 2: The `api_send` parity check.** The coverage gate names it today: *"it
  writes, and no check drives it down both channels to prove they agree."* A Send control
  is what makes the UI channel exist, so this is the task that clears it.
- [x] **Step 3: `make e2e-new` red, `make e2e` green, and the coverage gate down to
  `api_bind`/`api_unbind`** — which stay red pending [#308](https://github.com/yehia-khalil/rafiq/issues/308).
- [x] **Step 4: Commit.**

### Phase 2 gate

- [x] `api_send` carries a parity check and the gate no longer names it
- [x] The gate's remaining items are #308's two, and nothing else
- [x] No line was added to `uncoverable.tsv`

Then: `superpowers:requesting-code-review`.

---

**Both phases landed 2026-09-27**, across [#313](https://github.com/yehia-khalil/rafiq/pull/313)
and this branch. `make e2e` exits 0 with 22 checks; `api_send` carries a parity check and
writes-with-parity went from 2 to 3.

**Five defects, every one found by the e2e and none reachable from `WakilKit`** — no test
there presses a button or types into a field. Each fix uncovered the next:

1. The Send button dispatched `api_send` without the required `statement`, so every
   mutation was silently refused while a `GET` worked.
2. `entryCount` could not exceed one, so `apiChooserIsEnabled`'s true branch was
   unreachable and the chooser was disabled everywhere — which #296's audit predicted in
   those words.
3. A pane the AGENT opened had no entry list, because the list lived on `WindowModel`,
   which only learns a result the OPERATOR's press produced.
4. The body region drew its heading but not its field at zero rows, so there was no way
   to write a first body — #158's ruling not carried far enough.
5. A region write carried the entry's own `authorization` row, which
   `api_set_request` refuses by name, so the operator's edit would have been refused
   whole over a row they never touched.

**What is still not editable, and why:** a row holding a bound value stays a chip. #112
rules a binding is unmade by `api_unbind` and never by writing over it, because a binding
pins a declared type and a generation a caller cannot author.
