# Splitting WindowModel, and a layering test for WakilKit

**Date:** 2026-10-10
**Status:** design approved by the operator 2026-10-10, section by section
**Scope:** a structural refactor, landed before the editor (3b). No behaviour change.
**Origin:** the Wakil-vs-Jarvis comparison (2026-10-09): `WindowModel.swift` is Wakil's weak spot,
and Jarvis enforces its layering with import-direction tests while Wakil enforces nothing.

---

## Problem

`app/Sources/WakilKit/App/WindowModel.swift` is 8,098 lines: one `@MainActor @Observable`
class (lines 864–8083, ~90 stored properties, ~258 members) plus ~860 lines of free-standing
code that does not touch the class at all.

It costs development, not users:

- Every window-touching change has an agent read slices of it; missed wiring lives here
  (memory: the never-wired `WindowModel` injectables).
- Parallel worktrees all edit it, so it is where branches collide.
- Swift recompiles the whole file on any change.
- Nothing in it can be tested without building the whole window (`WindowModel.forTesting`,
  59 test uses).

`WakilKit` is one Swift module, so folder layering is unenforced. Measured 2026-10-10 (type
references, comments and strings stripped): 66 folder-to-folder links; **14 of 16 folders form
one dependency cycle** (only `Query` and `Speech` stand apart), with 15 mutually dependent
pairs. Almost nothing reaches into `App/`: the one real case is `PaneRow`, which is part of the
free-standing code.

The Go side is small: `cmd/wakil*` import `internal/wakilcore` and `internal/mcpx`; neither
internal package imports a command, and `wakilcore` imports no other package of the module
(`mcpx` builds on it). *(Corrected while building PR 8: the first measurement had the
`mcpx`/`wakilcore` direction backwards.)*

## Decisions

Agreed with the operator 2026-10-10.

1. **The realistic split, not a full break-up.** Move the free-standing code out, extract the
   self-contained pieces as real types, and leave the tangled core in the class. Moving the
   core into `extension WindowModel` files was rejected: it shortens the file without
   simplifying the class, and needs ~100 `private` members relaxed to `internal`.
2. **Layering at level 2.** A hard rule (nothing uses `App/`), a ratchet over today's links,
   and one untangling pass (shared vocabulary types to a base folder). Then remeasure and
   decide on level 3 (full layering, likely separate Swift modules) as its own piece of work.
3. **Stacked PRs**, one per step, merged together at the end.

## The stack

| PR | Change | Kind |
|---|---|---|
| 1 | Move the free-standing code out of `WindowModel.swift` | pure move |
| 2 | Org/project listing parsers and palette helpers become their own types | extraction |
| 3 | The git watcher becomes its own type | extraction |
| 4 | The terminal mirror becomes its own type | extraction |
| 5 | The surface ordering chain becomes its own type | extraction |
| 6 | The Claude locator and provider-login sub-state become their own type | extraction |
| 7 | Shared vocabulary types move to `WakilKit/Core/` | pure move |
| 8 | The layering tests (Swift and Go), and the remeasured cycle report | new tests |

The spec and plan ride in PR 1.

### PR 1 — the free-standing code

Out of `WindowModel.swift`, into files beside it in `App/` unless noted, unchanged:

- lines 1–503: `PaneRow`, `PaneTable` and the pure `pane*` layout functions → `Panes/PaneTable.swift` (not `App/`: `Api/` uses `PaneRow`)
- lines 504–550: `ThoughtRow`, `thoughtRow(id:for:)` → `ThoughtRow.swift`
- lines 551–601: `ProviderCredentials`, `ProviderSelection` → `ProviderCredentials.swift`;
  the private `AlwaysSucceedsCredentialsLookupForTesting` goes with them and becomes `internal`
  (it is only the default `lookup` of `forTesting`)
- lines 602–841: `agentMCPConfigJSON`, `agentAllowedTools` → `AgentMCPConfig.swift`
- lines 8084–8098: `confirmationDescription`, `apiSurfaceCallDetaches` → `WindowModelSupport.swift`

None reference `WindowModel` except in doc comments. Expected: ~860 lines out.

### PR 2–6 — extractions

Each new type:

- holds the state and methods of its cluster (cluster map below), behind a narrow interface;
- is owned by `WindowModel` as a stored property, so the window still has one source of truth;
- **keeps every name tests use on `WindowModel`**, as forwarding methods or computed
  properties, so the 34 test files that reference `WindowModel` change only where a test is
  better moved to the new type;
- gets its own unit tests for the behaviour it now owns;
- is `@Observable` itself if a view reads its state, so views keep updating.

| PR | New type | Takes from `WindowModel` | Interface (in / out) |
|---|---|---|---|
| 2 | `OrgListings` (enum, static) and `PaletteItems` (enum, static) | the `nonisolated static` parsers `orgListings`, `machineProviderListings`, `projectListings`, `environmentListings`, `adoptionCandidates`, `slugForOrgIdentifier`; the static `sessionItems`, `age`, `providerItems` | pure functions; `WindowModel` keeps static forwarders with the same names |
| 3 | `GitRootWatcher` | `rootWatcher`, `watchedGitRoots`, `gitWatcherChain`; `syncGitWatcher`, `gitRootChanged`, `refreshUnreadGitPanes`, `refreshGitPanes` | roots in; a "these roots changed" callback out |
| 4 | `TerminalMirrorFeed` (in `Terminal/TerminalMirror.swift`) | `mirrorEvents`; `mirrorEventId`, `isMirrorRelevant`, `retainMirrorEvent`, `pumpMirror`, `backfillMirror` | harness events in; mirror blocks written to `PaneStore` |
| 5 | `SurfaceChain` | `surfaceChain`, the static `focusGenerations`; the ordering part of `dispatchFromSurfaceInOrder` / `enqueue*` | an async closure in, run strictly in order; `surfaceChainSettled` for tests |
| 6 | `ClaudeLocator` (and the login sub-state it guards) | `claudeLocator`, `locatedClaude`, `claudePathOverride`; `resolvedClaudePath`, `locateClaudeIfNeeded`, `loginBinary` | a resolved path out; an override in |

If an extraction turns out to need more than its cluster's state (a write to the shared core
beyond a callback), it stays in the class and the PR says so: the split is opportunistic, not
forced.

**The org-switch tripwire.** `InvalidationContractTests` lists every stored property of
`WindowModel` by `Mirror` and requires each to be classified. A moved property disappears from
that list and the new owner's label appears instead. Each new owner is classified, and if it
holds org-derived state, `invalidateForOrgChange` resets it through one method on the new type
and a test of the new type asserts that reset covers all of its stored state, so the tripwire
still sees everything.

### PR 7 — shared vocabulary to `Core/`

A type moves to `WakilKit/Core/` only if it is a value type or protocol **and depends on nothing
outside `Core/` and Foundation**. Candidates by cross-folder use (measured): `JSONValue` (used by
11 folders, now in `MCP/`), `ToolCaller`, `Action` / `ActionDescriptor`, `EnvironmentProduction`,
`Pane`, `LayoutScope`, `LayoutActionError`, `PaneCell`. The stores (`PaneStore`, `LayoutStore`,
`ActionRegistry`, `MCPClient`) are services, not vocabulary, and stay. The plan verifies each
candidate's dependencies before moving it; one that fails the rule stays.

### PR 8 — the layering tests

**Swift**, in `WakilKitTests`, reading `app/Sources/WakilKit` directly:

1. Strip comments and string literals; record the folder that declares each top-level type;
   record which folders reference which declared types. A name declared in two folders, or a
   generic name (`CodingKeys`, `Source`, `Contents`, `Kind`, `State`), is skipped and listed in
   the test's output, never guessed at.
2. **Hard rule:** any link into `App/` fails, naming the file, the type and the folder.
3. **Ratchet:** the allowed links live in `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`,
   one per line, `Panes -> Layout`. A link not listed fails. **A listed link that no longer
   exists also fails**, so the list only shrinks (the rule `uncoverable.tsv` follows). `Core/`
   may be used by any folder and uses none.
4. The analyser is tested on a small fake source tree with a forbidden link, an unlisted link
   and a stale entry, each of which must fail.

**Go**, one test using the standard library's `go/build`: `internal/...` never imports
`cmd/...`; `internal/wakilcore`, the base, imports no other package of this module.

Both run in existing gates (`make app-test`, `make test`). No new dependencies.

**The remeasurement.** PR 8's description reports the cycle groups and mutual pairs after PR 7,
in the same form as above. That is the input to the level-3 decision.

## Cluster map (reference)

From the decomposition survey, 2026-10-10. Line ranges are at 35c73fc1 and will drift.

| Cluster | Lines | Stays or moves |
|---|---|---|
| State declarations | 864–1593 | stays (shrinks as owners move) |
| Init, `forTesting`, test seams | 1594–2325 | stays |
| Labels and derived views | 2326–2405 | stays |
| Context, org reset, layout activation (`invalidateForOrgChange`) | 2406–2999 | stays — the hub |
| Environment, queries, databases | 3000–3163 | stays |
| Settings, accounts, provider login | 3164–3787 | locator part moves (PR 6) |
| Query line, mutations, cell edits, `refreshPanes` | 3788–4268 | stays |
| Surface dispatch | 4269–4505 | ordering moves (PR 5) |
| Layout refresh | 4506–4596 | stays |
| Git watcher | 4597–4715 | moves (PR 3) |
| Pane operations | 4716–4917 | stays |
| Palettes, layout persistence | 4918–5434 | static helpers move (PR 2) |
| Dispatch core | 5435–5644 | stays |
| Agent turn | 5645–5970 | stays |
| Resume | 5971–6252 | stays |
| Provider and org switching | 6253–6699 | stays |
| Org plane, listings | 6700–7317 | static parsers move (PR 2) |
| Thread, events, test queue | 7318–7671 | stays |
| Terminal mirror | 7672–7806 | moves (PR 4) |
| Terminal | 7807–8083 | stays |

Expected end state: `WindowModel.swift` at roughly 5,000–6,000 lines.

## Verification

- **PR 1, 2, 7 (pure moves):** full Swift suite green, nothing else changed. A test that needs
  more than an import or name change is a sign behaviour moved: stop and report.
- **PR 3–6:** the new type's own tests; the existing `WindowModel`-level tests pass unchanged;
  moved state classified in the tripwire, with its reset covered.
- **PR 8:** the analyser's own tests fail on each bad tree; the real tree is green.
- **Top of the stack, before merge:** `make app-test`, `make test`, `make e2e` (operator's OK for
  the screen), the app builds and launches; one fresh whole-stack review. No walk: nothing
  user-visible changes.

## Out of scope

- Moving the tangled core into extension files, or relaxing its `private` members.
- Breaking the remaining folder cycles, and separate Swift modules (level 3) — decided after
  PR 8's remeasurement.
- `WakilApp` (the views) — no test target, and not part of the tangle measured here.
- Any behaviour change.
