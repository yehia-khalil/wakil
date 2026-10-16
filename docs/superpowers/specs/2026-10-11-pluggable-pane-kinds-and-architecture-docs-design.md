# Pluggable pane kinds, and the architecture reference

**Date:** 2026-10-11
**Status:** design approved by the operator 2026-10-11, section by section
**Scope:** whole-app architecture docs and a contribution guide; a structural refactor that makes a
pane kind a folder. Landed before the editor (3b). No behaviour change.
**Origin:** the WindowModel split's remeasure (PR #375): one folder cycle of 11 is left, and `Panes`
is in 5 of its 10 mutual pairs. The operator also asked for an architecture overview and a
contribution guide "that is clear that we should follow", covering all of the Swift and Go code.

---

## Problem

**There is no map of the code.** Architecture lives in ~40 phase specs, the charter, and the code
itself. The operator does not know the code structure, and every session re-derives it. Nothing says
where new code goes, and nothing stops the structure drifting except the two layering tests.

**`PaneStore` is the hub every pane kind edits.** Adding a pane kind today touches seven places:

1. `Layout/Pane.swift` — `Pane.kinds`, `Pane.contentsByKind`, a `Pane.Contents` case
2. `Panes/PaneSnapshot.swift` — a `PaneSnapshotContents` case
3. `Panes/PaneStore.swift` — its private storage enum and the `snapshot(paneId:kind:)` switch
4. `MCP/PaneSnapshotJSON.swift` — what `read_pane` returns
5. `Identifiers/IdentifierSources.swift` — the names a kind offers
6. `App/WindowModel.swift` — a per-kind snapshot dictionary, `refreshPanes()`, its org-switch reset
   and its tripwire entry
7. `WakilApp/Canvas.swift` — the `switch pane.kind` that picks the view

Because `PaneStore` and `PaneSnapshotContents` name each kind's types, and each kind writes into
`PaneStore`, `Panes` is mutually dependent with `Api`, `Git` and `Terminal`. `PaneContentActions.swift`
(an action registration file living in `Panes/`) adds `Panes -> Layout` and `Panes -> Registry`.
About 800 of `PaneStore`'s 1,653 lines are Api's. Phase 3 adds at least three kinds (editor, chat,
inbox), each of which would edit all seven places.

## Decisions

Agreed with the operator 2026-10-11.

1. **Pluggable, not just untangled.** A pane kind becomes a protocol conformance in its own folder;
   `Panes/` names no kind. Rejected: moving each kind's value types beneath `Panes` (fixes the arrows,
   leaves `PaneStore` the hub every kind edits).
2. **One actor, kinds as extensions** (approach A). Rejected: a runtime kind registry threaded
   everywhere (B — only needed for one case, solved below); a store actor per kind (C — Api reads
   data-surface rows for drops, so cross-actor hops would change ordering, a behaviour change).
3. **Docs first.** PR 1 writes the architecture reference and the contribution guide, with pane kinds
   described as the target; the last PR updates them to what was built.
4. **The whole app is documented**, Swift and Go, as the reference for future work — not only pane
   kinds.
5. **Every structural rule is either tested or labelled convention.** A new docs check fails when a
   WakilKit folder or a `cmd/` binary is not documented.
6. **Stacked PRs**, one per step, merged together at the end.
7. **A view only redraws for its own pane.** Nothing here may widen what a terminal tick (or any
   single pane's update) invalidates.

## Part 1 — the architecture reference and contribution guide

### Files

| File | Covers |
|---|---|
| `docs/architecture/README.md` | The system on one page: Go capability layer, Swift app, how they talk (MCP over stdio, the shim over a unix socket), a diagram, and a reading order |
| `docs/architecture/go.md` | Every `cmd/` binary — what it serves, its tools, who launches it (window or harness); `internal/wakilcore` by area (config and paths, Keychain, database drivers, HTTP, git, Jira, recall, sessions, providers); `internal/mcpx`; the Go layering rules and their test |
| `docs/architecture/wakilkit.md` | Every WakilKit folder: its job, key types, what it may use, the tests that own it; `Core/` and `App/` rules; the allow-list and how it ratchets |
| `docs/architecture/wakilapp.md` | `main.swift` and its headless modes (`--mcp-shim`, `--dispatch`, `--capture`, …); `AppScene` → `WakilWindow` → `WindowSession`; the canvas and each view; how views read `WindowModel` and dispatch through it |
| `docs/architecture/runtime.md` | Who creates and owns what: `WakilWiring.build`, `WindowSession.start`, `WindowModel`, the stores, `ActionRegistry`, the write gate and brokers, the harness, `MCPSocketServer` and the shim; how binaries are located (`WAKIL_BIN_DIR`, the bundle, `bin/`) and their child environment; lifetimes and shutdown order |
| `docs/architecture/flows.md` | Three flows, function by function: an operator click → registry → gate → binary → `PaneStore` → view; an agent tool call → shim → permission prompt → registry → confirmation; an org switch (`setOrganization` → `invalidateForOrgChange` → `WakilWiring.switchOrg`) |
| `docs/architecture/state.md` | Everything on disk (`~/.wakil/orgs/<org>/…`, layouts, journal, vocabulary, project `.wakil/project.json`), the Keychain services, what lives only in memory, and what an org switch resets |
| `docs/architecture/testing.md` | Swift unit tests, the layering tests, the org-switch tripwire, Go tests, e2e (checks, the auditor, `uncoverable.tsv`), acceptance runbooks and walks, and the make targets |
| `CONTRIBUTING.md` | "Where does my code go?" table; recipes for a new pane kind, action, MCP binary, provider and WakilKit folder; the tests each change needs; the workflow (linking `docs/agents/workflow.md`, never copying it) |

`CLAUDE.md` and `AGENTS.md` link to `docs/architecture/README.md` and `CONTRIBUTING.md`. The charter
is not touched (3,998 of 4,000 words).

### Rules for the docs

- **Facts from the code, with paths.** Every claim names the file or type it comes from, so it can be
  checked. The 2026-10-11 survey of the repo is the starting point; each fact is re-read in the code
  before it is written.
- **Link, never copy,** for anything with a home already: the charter's invariants, `PRODUCT.md`'s
  interaction rules, `docs/agents/*`, decision records, phase specs.
- **Each rule says how it is enforced:** a test name, or the word *convention*.
- **No line numbers** (they go stale); name the type or function.

### Structure rules, and what enforces them

| Rule | Enforced by |
|---|---|
| Nothing in WakilKit uses `App/` | `LayeringTests.wakilKitKeepsItsLayering` (exists) |
| `Core/` uses no other folder; any folder may use `Core/` | `LayeringTests` (exists) |
| Every other folder link is on `layering-allowed.txt`, which only shrinks | `LayeringTests` (exists) |
| `Panes/` names no pane kind | the allow-list, once PR 8 removes the reverse links |
| Every pane kind is registered once, serves unique names, and answers `read_pane` when empty | new `PaneKindsTests` (PR 8) |
| Every `WindowModel` stored property is classified for the org switch | `InvalidationContractTests` (exists) |
| Every window-owned MCP client joins the org switch | `everyWakilOwnedClientJoinsTheOrgSwitch` (exists) |
| Every action declares its audience | `ActionClassificationTests` (exists) |
| Go: `internal/wakilcore` imports no other package of the module | `internal/wakilcore/layering_test.go` (exists) |
| Every WakilKit folder and every `cmd/` binary is documented in `docs/architecture/` | **new docs check** in `make test` (PR 1) |

The docs check: a Go test in `scripts/` (run by `make test`'s `go test ./...`, beside the Makefile's
`docs-check` charter word limit), listing the folders under
`app/Sources/WakilKit/` and `cmd/`, and failing for any name that does not appear as a heading in
`wakilkit.md` or `go.md` respectively. It is tested on a fake tree with an undocumented folder.

## Part 2 — pluggable pane kinds

### The protocol (`Panes/PaneKind.swift`)

```swift
public protocol PaneKind {
    associatedtype Contents: Sendable              // one pane's state
    associatedtype Shared: Sendable = Void         // store-wide state for this kind (Api: recent sends, flights)
    associatedtype Snapshot: PaneKindSnapshot      // what readers get
    static var names: [String] { get }             // the pane.kind strings it serves
    static var emptyContents: Contents { get }
    static var emptyShared: Shared { get }         // default for Void
    static func snapshot(of: Contents, in store: isolated PaneStore) -> Snapshot
    static func failure(of: Contents) -> String?   // default nil
    static var rerunsSubjectOnRestore: Bool { get } // default false; today a Pane.Contents property
}

public protocol PaneKindSnapshot: Sendable, Equatable {}
```

`snapshot(of:in:)` takes the store isolated because Api's snapshot reads store-wide state (its recent
sends) and data-surface rows (bound values). `read_pane` is a further requirement added in PR 7:
`static func readPane(_ snapshot: Snapshot, in store: isolated PaneStore) -> [String: JSONValue]`
— on the kind, not the snapshot, and store-isolated, because Api's answer reads data-surface rows
for bound-value previews (#192), which a snapshot value alone does not carry. *(Amended while
planning: the first draft put `readPane` on the snapshot.)*

**Store-wide state and scope changes.** `clearAllScopes()` and `switchScope(to:)` must keep doing
exactly what they do for Api today (clear recent sends and bump the resolution counter; bump the
counter), without naming Api. Two hooks with defaults carry it:
`sharedAfterClearingAllScopes(_:)` (default: `emptyShared`) and `sharedAfterSwitchingScope(_:)`
(default: unchanged). A kind's shared state is created on first touch, read or write, so a counter
read before any write is still bumped by a later scope change — today's behaviour.

### Storage and access (`PaneStore`)

- Each pane is a slot: the kind's type and its contents, held opaquely.
- `contents(K.self, paneId)` returns the kind's contents, or `K.emptyContents`.
- `update(K.self, paneId) { inout contents in … }` changes them, and refuses (returns `nil`) when the
  pane holds another kind — today's rule in `setGit`, `setApi`, `setTerminal`, `setDataSurface`.
- `shared(K.self)` / `updateShared(K.self) { … }` do the same for store-wide state.
- `snapshot(paneId:kind:)` names no kind: a written slot snapshots itself; a never-written pane gets
  its kind's empty snapshot from the kinds list.
- `PaneSnapshot.contents` becomes `(any PaneKindSnapshot)?`, with `Equatable` written by hand.
- `PaneStore(kinds:)` receives the kinds list; `PaneStore()` keeps working with none (a never-written
  pane then says "no contents for kind …", as an unknown kind does today).

### Where a kind's code lives

Git as the example; Terminal and Api follow the same shape.

- `Git/GitPaneKind.swift` — the conformance.
- `Git/PaneStore+Git.swift` — today's methods, **same names** (`setGit`, `updateGit`,
  `gitSnapshot`), as an `extension PaneStore`: same actor, same ordering. Callers and tests do not
  change.
- `Git/GitSnapshot+ReadPane.swift` — its `read_pane` JSON, moved from `MCP/PaneSnapshotJSON.swift`.

The data surface (the db pane) conforms too but stays in `Panes/` this round, since `PaneTable` and
`PaneFetch` live there. Moving it to its own folder is a possible follow-up, out of scope here.

### The kinds list (`App/PaneKinds.swift`)

`PaneKinds.standard: [any PaneKind.Type]` — the one place every kind is named (`App/` may use
everything). Passed to `PaneStore(kinds:)` by `WakilWiring.build`. It replaces Layout's
`Pane.contentsByKind` and `Pane.Contents`; `WindowModel`'s uses of them (`== .git`, `== .apiClient`,
`rerunsSubjectOnRestore`) read the kinds list instead. Tests that rely on empty snapshots of
never-written panes construct `PaneStore(kinds: PaneKinds.standard)`; the plan counts them.

### The consumers

- **`read_pane`.** `PaneStore.readPane(paneId:kind:) -> JSONValue` builds the shared envelope
  (`kind`, `failure`) and asks the pane's kind for the rest; each kind's JSON code moves from
  `MCP/PaneSnapshotJSON.swift` into its folder. `MCPServer.readPane` and `GitActions` call it, and
  `paneSnapshotJSON` goes. Output is byte-identical; existing MCP tests pin it.
- **Identifiers.** `Identifiers/` defines `protocol OffersIdentifiers`, carrying what `PaneSource`
  extracts per kind today. Terminal, Api and the data surface conform in their own folders; Git offers
  none today (`GitSource` is separate) and still offers none. `PaneSource` asks
  `as? any OffersIdentifiers` instead of switching. `Identifiers -> Api` (via `apiRenderedPath`)
  disappears.
- **`WindowModel`.** `terminalSnapshots`, `apiSnapshots` and `gitSnapshots` become
  `paneCells: [String: PaneSnapshotCell]`, where `PaneSnapshotCell` is a small `@Observable` class
  holding one pane's `PaneSnapshot`. **Not one plain dictionary**, which the first draft proposed:
  `refreshTerminal` writes only `terminalSnapshots` on every terminal tick precisely so that a tick
  does not redraw every other pane (the 240.5 ms/frame regression its doc comment records), and one
  shared dictionary would bring that back. With a cell per pane, a tick redraws only that pane's view,
  and the dictionary itself changes only when a pane opens or closes. `refreshPanes()` updates cells
  in place and fills them without a switch. Views and `WindowModel` read per pane — `terminal(_:)`,
  `api(_:)`, `git(_:)` — and the canvas's three dictionary reads become those (the one `WakilApp`
  edit outside a new kind's case). Tests that read the dictionaries move to the per-pane reads. The db
  pane's derived `tables` and `editables` stay. The tripwire gets one entry (`paneCells`) instead of
  three; the reset is unchanged. *(Amended while planning.)*
- **The canvas** (`WakilApp/Canvas.swift`) **keeps its `switch pane.kind`.** A view registry would
  need `AnyView`, risking lost view state (the terminal, the coming editor) in a target with no tests;
  the switch is one compiler-checked case per kind. The docs name it as the single view-side place a
  new kind touches.
- **`PaneContentActions.swift`** moves from `Panes/` to `Registry/` (it registers actions, which is
  Registry's job), removing `Panes -> Registry` and most of `Panes -> Layout`. `PaneStore`'s one use of Layout's `Pane` (`Pane.contentsByKind`) goes in PR 3, so
  `Panes -> Layout` disappears without moving `Pane`.

### Adding a pane kind, after this

| Where | What |
|---|---|
| its own folder | the conformance, `PaneStore+<Kind>.swift`, its `readPane`, its identifiers, its actions, its tests |
| `WakilApp` | its view file, one `case` in the canvas switch |
| `App/PaneKinds.swift` | one line |

`Layout/`, `Panes/`, `MCP/`, `Identifiers/` and `WindowModel` are not touched.

## The stack

*(Reordered while planning so that the one behaviour-critical change — the storage swap — lands in
one PR, and every kind's move after it is a pure move.)*

| PR | Change | Kind |
|---|---|---|
| 1 | `docs/architecture/*`, `CONTRIBUTING.md`, the docs check, links from `CLAUDE.md`/`AGENTS.md`; pane kinds described as the target. Spec and plan ride here | docs + test |
| 2 | `PaneKind`, slot storage, store-wide state with its hooks, `PaneStore(kinds:)`, `App/PaneKinds.swift`; all five kinds conform (still beside `PaneStore` in `Panes/`); `PaneSnapshot.contents` becomes `(any PaneKindSnapshot)?` with typed reads; `PaneSnapshotContents` goes | the storage swap |
| 3 | `Pane.contentsByKind` and `Pane.Contents` go; their readers use `PaneKinds` | extraction |
| 4 | Git's kind and store methods move to `Git/` | pure move |
| 5 | Terminal's kind, contents, snapshot and store methods move to `Terminal/` | pure move |
| 6 | Api's kind, contents, shared state, `ApiSnapshot.swift` and store methods move to `Api/` | pure move |
| 7 | `read_pane` and identifiers through the kinds; `paneCells` on `WindowModel` | extraction |
| 8 | `PaneContentActions` → `Registry/`; reverse links off the allow-list; `PaneKindsTests` | move + tests |
| 9 | Docs updated to what was built; the remeasure (cycle groups, mutual pairs) | docs |

If a kind's move turns out to need a behaviour change (an ordering or a visible difference), it stops
and the PR says so: the refactor is no-behaviour-change or it does not land.

## Verification

- **Every PR:** its own tests, plus the existing tests unchanged (same-name forwarders). A test that
  needs more than a constructor change (`PaneStore(kinds:)`) is a sign behaviour moved: stop and report.
- **PR 1:** the docs check fails on a fake tree with an undocumented folder, and passes on the real
  tree. Every fact in the docs is checked against the code by the final reviewer.
- **PR 7:** `read_pane` output byte-identical (existing MCP tests); a terminal tick invalidates
  only its own pane's cell (new test).
- **Top of the stack, before merge:** `make app-test`, `make test`, `make e2e` (operator's OK for the
  screen), a launch check, one fresh whole-stack review. No walk: nothing user-visible changes.

## Out of scope

- Moving the data surface out of `Panes/`.
- A view registry in `WakilApp`.
- Breaking the cycle's other pairs (`Api <-> MCP`, `Layout <-> Registry`, `Layout <-> Terminal`,
  `MCP <-> Registry`, `Terminal <-> Visual`) and separate Swift modules (level 3).
- Any behaviour change.
