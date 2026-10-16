# Pluggable pane kinds, and the architecture reference — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write the whole-app architecture reference and contribution guide, then make a pane kind a
protocol conformance in its own folder so `Panes/` names no kind — with no behaviour change.

**Architecture:** `PaneStore` stays one actor; its storage becomes a slot per pane (the kind's type +
opaque contents) plus opaque store-wide state per kind. Each kind's conformance and store methods
(`extension PaneStore`) live in its folder; `App/PaneKinds.swift` is the one list naming them all.
`WindowModel` holds one `@Observable` cell per pane so a pane's update redraws only that pane.

**Tech Stack:** Swift 6.4 (language mode 6, `swift-tools-version: 6.0`), Swift Testing, Observation;
Go 1.x (`scripts/` package tests); Markdown docs.

**Spec:** `docs/superpowers/specs/2026-10-11-pluggable-pane-kinds-and-architecture-docs-design.md`

## Global Constraints

- No behaviour change. A test that needs more than a constructor change (`PaneStore(kinds:)`) or the
  mechanical rewrites named in a task is a sign behaviour moved: stop and report.
- Every public `PaneStore` and `WindowModel` method keeps its name and signature unless a task says
  otherwise; callers and tests do not change.
- "A view only redraws for its own pane": nothing may widen what one pane's update invalidates.
- `PaneKind` refines `SendableMetatype` (probe 2026-10-11: without it `[any PaneKind.Type]` is not
  Sendable under Swift 6).
- Docs: facts from the code with paths; no line numbers; link, never copy (charter invariants,
  `PRODUCT.md` interaction rules, `docs/agents/*`); every rule names its test or says *convention*.
  The charter (`docs/wakil/north-star.md`) is not touched.
- Commits: no `Co-Authored-By` or "Generated with Claude Code" lines (operator rule).
- Stacked PRs with gh-stack; one task = one layer. Branch names: `yehia-khalil/pane-kinds-<n>-<slug>`.
- Test commands. Swift, filtered: `cd app && ../scripts/swift-test.sh --filter '<regex>'`.
  Swift, full: `make app-test` (controller only, never a subagent). Go: `go test ./scripts/ -run <Name>`.
  `make app-test` does not build Go; run `make build` first when the Go side changed.

## Review Focus

1. **One pane's update redrawing other panes** — a terminal tick must invalidate only that terminal's
   view (the 240.5 ms/frame regression `refreshTerminal`'s doc comment records). Pinned in Task 7:
   `aTerminalTickInvalidatesOnlyItsOwnPane`.
2. **Scope changes and store-wide Api state** — `switchScope(to:)` bumps the resolution mark even if
   nothing was written yet; `clearAllScopes()` forgets recent sends, bumps the mark, keeps flight
   subscribers. Pinned in Task 2: `switchingScopeBumpsTheResolutionMarkBeforeAnyWrite`,
   `clearingAllScopesBumpsTheMarkAndKeepsFlightSubscribers`.
3. **A pane holding one kind written by another kind's setter** — refused, as every `set*` does today.
   Pinned in Task 2: `aPaneHoldingOneKindRefusesAnother`.
4. **A never-written pane** — a known kind answers its empty snapshot; settings answers no contents;
   an unknown kind answers the "no contents" failure. Pinned in Task 2:
   `aNeverWrittenPaneAnswersItsKindsEmptySnapshot`.
5. **A doc that drifts from the code** — a WakilKit folder or `cmd/` binary with no heading fails
   `make test`. Pinned in Task 1: `TestArchitectureDocsCoverEveryFolderAndBinary`.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `scripts/architecture_docs_test.go` | 1 | docs check: every WakilKit folder / `cmd/` binary / `internal/` package has a heading |
| `docs/architecture/{README,go,wakilkit,wakilapp,runtime,flows,state,testing}.md` | 1, 9 | the reference |
| `CONTRIBUTING.md` | 1, 9 | where code goes, recipes, tests per change |
| `CLAUDE.md`, `AGENTS.md` | 1 | link the two |
| `app/Sources/WakilKit/Panes/PaneKind.swift` | 2 | `PaneKind`, `PaneKindSnapshot`, `PaneSlot` |
| `app/Sources/WakilKit/Panes/PaneStore.swift` | 2, 4–6 | slot storage, generic access, snapshot/failure/scope; kind methods leave in 4–6 |
| `app/Sources/WakilKit/Panes/PaneSnapshot.swift` | 2, 5 | `PaneSnapshot` with existential contents and typed reads; `TerminalSnapshot` leaves in 5 |
| `app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift` | 2 | data-surface kind + `DataSurfaceContents` (stays in Panes) |
| `app/Sources/WakilKit/Panes/SettingsPaneKind.swift` | 2 | settings kind (no stored contents; stays in Panes) |
| `app/Sources/WakilKit/Panes/{Git,Terminal,Api}PaneKind.swift` | 2 | the three kinds, temporarily beside `PaneStore` |
| `app/Sources/WakilKit/App/PaneKinds.swift` | 2, 3 | the one list of kinds |
| `app/Sources/WakilKit/Git/{GitPaneKind,PaneStore+Git}.swift` | 4 | Git's kind and store methods |
| `app/Sources/WakilKit/Terminal/{TerminalPaneKind,PaneStore+Terminal,TerminalSnapshot}.swift` | 5 | Terminal's |
| `app/Sources/WakilKit/Api/{ApiPaneKind,PaneStore+Api,ApiSnapshot}.swift` | 6 | Api's |
| `app/Sources/WakilKit/App/PaneSnapshotCell.swift` | 7 | one pane's observable snapshot |
| `app/Sources/WakilKit/Registry/PaneContentActions.swift` | 8 | moved from `Panes/` |
| `app/Tests/WakilKitTests/PaneKindStorageTests.swift` | 2 | storage behaviour pins |
| `app/Tests/WakilKitTests/PaneKindsTests.swift` | 8 | the kinds list's rules |

---

### Task 1: The architecture reference, the contribution guide, and the docs check (PR 1)

Branch: `yehia-khalil/pane-kinds-1-docs` (exists; spec and this plan are on it).

**Files:**
- Create: `scripts/architecture_docs_test.go`
- Create: `docs/architecture/README.md`, `go.md`, `wakilkit.md`, `wakilapp.md`, `runtime.md`, `flows.md`, `state.md`, `testing.md`
- Create: `CONTRIBUTING.md`
- Modify: `CLAUDE.md`, `AGENTS.md`

**Interfaces:**
- Produces: heading convention later tasks keep — `wakilkit.md` has one `### <Folder>/` heading per
  WakilKit folder; `go.md` has one `### <binary>` heading per `cmd/` directory and one
  `### internal/<pkg>` per `internal/` package.

- [ ] **Step 1: Write the docs check (failing on the fake tree's undocumented folder, and on the real repo)**

```go
package scripts

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The architecture docs are the map of the code (docs/architecture/), so a folder
// or binary missing from them is a hole in the map. Each WakilKit folder needs a
// "### <Folder>/" heading in wakilkit.md; each cmd/ binary a "### <name>" and each
// internal/ package a "### internal/<name>" heading in go.md.

// headingWords returns the first word of every "### " heading in doc.
func headingWords(doc string) map[string]bool {
	words := map[string]bool{}
	for _, line := range strings.Split(doc, "\n") {
		if rest, ok := strings.CutPrefix(line, "### "); ok {
			if fields := strings.Fields(rest); len(fields) > 0 {
				words[fields[0]] = true
			}
		}
	}
	return words
}

// subdirs returns the names of the directories directly under dir.
func subdirs(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("reading %s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// undocumentedIn returns the "want" headings that doc does not have.
func undocumentedIn(doc string, want []string) []string {
	have := headingWords(doc)
	var missing []string
	for _, w := range want {
		if !have[w] {
			missing = append(missing, w)
		}
	}
	return missing
}

// architectureGaps lists every folder, binary and package under root that the
// docs under root/docs/architecture do not give a heading.
func architectureGaps(t *testing.T, root string) []string {
	t.Helper()
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(root, "docs", "architecture", name))
		if err != nil {
			t.Fatalf("the architecture reference is missing %s: %v", name, err)
		}
		return string(b)
	}
	var folders, goWant []string
	for _, f := range subdirs(t, filepath.Join(root, "app", "Sources", "WakilKit")) {
		folders = append(folders, f+"/")
	}
	goWant = append(goWant, subdirs(t, filepath.Join(root, "cmd"))...)
	for _, p := range subdirs(t, filepath.Join(root, "internal")) {
		goWant = append(goWant, "internal/"+p)
	}
	gaps := undocumentedIn(read("wakilkit.md"), folders)
	for _, g := range undocumentedIn(read("go.md"), goWant) {
		gaps = append(gaps, g)
	}
	return gaps
}

func TestArchitectureDocsCatchAnUndocumentedFolder(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{
		"app/Sources/WakilKit/Core", "app/Sources/WakilKit/Panes",
		"cmd/wakil-a", "internal/base", "docs/architecture",
	} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(root, "docs", "architecture", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("wakilkit.md", "# WakilKit\n\n### Core/ — shared vocabulary\n")
	write("go.md", "# Go\n\n### wakil-a\n\n### internal/base\n")
	got := architectureGaps(t, root)
	if len(got) != 1 || got[0] != "Panes/" {
		t.Fatalf("gaps = %v, want [Panes/]", got)
	}
}

func TestArchitectureDocsCoverEveryFolderAndBinary(t *testing.T) {
	if gaps := architectureGaps(t, repoRoot(t)); len(gaps) > 0 {
		t.Fatalf("docs/architecture has no heading for: %s\n"+
			"Add a \"### <name>\" section (wakilkit.md for a WakilKit folder, go.md for a binary or "+
			"internal package) saying what it is for, its key types, and what it may use.",
			strings.Join(gaps, ", "))
	}
}
```

- [ ] **Step 2: Run it**

Run: `go test ./scripts/ -run 'TestArchitectureDocs' -v`
Expected: `TestArchitectureDocsCatchAnUndocumentedFolder` PASS; `TestArchitectureDocsCoverEveryFolderAndBinary`
FAIL with "the architecture reference is missing wakilkit.md".

- [ ] **Step 3: Write `docs/architecture/wakilkit.md` and `go.md`**

Read each folder and package in the code before writing its section; the 2026-10-11 survey (in the
session that wrote this plan; its findings are summarised below) is the starting point, not the
source. Every section names files and types.

`wakilkit.md` — sections in this order:
1. `# WakilKit` — one paragraph: the testable library under `WakilApp`; one Swift module; folders are
   its layers.
2. `## The rules` — the table from the spec's "Structure rules" (nothing uses `App/`; `Core/` uses
   nothing; the shrink-only allow-list `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`; how
   `LayeringTests` scans: types and top-level non-private func/let/var, interpolations kept, generic
   names skipped). Name `LayeringTests.wakilKitKeepsItsLayering`. How to change the allow-list.
3. `## Folders` — one `### <Folder>/` heading per folder under `app/Sources/WakilKit/` (today: `Api/`,
   `App/`, `Command/`, `Context/`, `Core/`, `Gate/`, `Git/`, `Harness/`, `Identifiers/`, `Layout/`,
   `MCP/`, `Panes/`, `Query/`, `Registry/`, `Speech/`, `Terminal/`, `Visual/`). Each: what it is for
   (one paragraph), key types (bullets with file names), what it uses (from the allow-list), the tests
   that own it (test file names).
4. `## The cycle` — the current cycle group and mutual pairs (61 links; one cycle of 11: Api, Context,
   Git, Harness, Identifiers, Layout, MCP, Panes, Registry, Terminal, Visual; 10 mutual pairs), and
   that Task 8 of this plan removes Panes' five reverse links. Recompute with the snippet in Task 9
   Step 2 before writing.
5. `## Pane kinds` — the target design from the spec's Part 2 (protocol, slots, kinds list, where a
   kind's code lives, the canvas switch), marked "**Being built** (pluggable pane kinds stack)".

`go.md` — sections in this order:
1. `# The Go capability layer` — what it is (headless capabilities behind MCP), `CGO_ENABLED=0`.
2. `## The rules` — `internal/...` never imports `cmd/...`; `internal/wakilcore` imports no other
   package of the module (`internal/wakilcore/layering_test.go`); `internal/mcpx` exists so wakilcore
   never imports the MCP SDK.
3. `## Binaries` — one `### <name>` per `cmd/` directory (`wakil`, `wakil-ctx`, `wakil-db`,
   `wakil-git`, `wakil-http`, `wakil-pm`, `wakil-recall`): what it serves, its tool names, who launches
   it (window via `WakilWiring.build`, or harness via `agentMCPConfigJSON`; `wakil-git` by both), its
   transport (MCP stdio; `wakil` is an operator CLI, not MCP), notable env (`WAKIL_IN_WINDOW=1` gates
   `wakil-http send`).
4. `## Packages` — `### internal/wakilcore` by area (config and paths, Keychain service
   `wakil:<org>:<ref>`, database drivers sqlite/mysql/mongo with read-only and classification, HTTP,
   git, Jira, recall, sessions and lineage, providers), each with its files; `### internal/mcpx`
   (`ToolErr`, `mcpxtest`, `shippedbinary_test.go`).
5. `## Adding a binary` — link to `CONTRIBUTING.md`'s recipe.

- [ ] **Step 4: Run the check**

Run: `go test ./scripts/ -run 'TestArchitectureDocs' -v`
Expected: PASS (both).

- [ ] **Step 5: Write the other six files and `CONTRIBUTING.md`**

`docs/architecture/README.md`:
- `# Wakil architecture` — reading order of the other files; what each answers.
- `## The pieces` — a Mermaid diagram (`flowchart LR`): `WakilApp` views → `WindowModel` →
  `ActionRegistry` → `writeGate` → `MCPClient` → Go binaries (ctx, db, http, git); the harness
  (`claude` CLI) → shim (`--mcp-shim`) → unix socket → `MCPSocketServer` → registry; agent-facing
  servers (pm, recall, git) launched by `claude` directly.
- `## How they talk` — MCP over stdio for every Go binary; the shim copies bytes between stdio and the
  window's socket (`MCP/Shim.swift`, `MCPSocketServer`); `read_pane` / `read_layout` answered in-window.
- `## Where to go next` — links: charter §4 Invariants and §9 Glossary (`docs/wakil/north-star.md`),
  `PRODUCT.md` §Interaction Rules, `docs/wakil/decisions.md`, `docs/agents/workflow.md`, `CONTRIBUTING.md`.

`docs/architecture/wakilapp.md`: `main.swift` headless modes (`--mcp-shim`, `--dispatch <file>`
`--environment`, `--capture`, `--capture-motion`, `--bench-surface`, `--probe-monaco`); `AppScene` →
`WakilWindow` → `WindowSession.start()`; `Canvas.swift`'s `switch pane.kind` (db → `DBPane`, terminal
→ `TerminalPane`, api → `ApiPane`, git → `GitPane`, settings → `SettingsPane`) — "the one view-side
place a new pane kind touches"; the other views (Rail, ContextLine, ComposerBar, ThoughtThread,
ConfirmationPlane, OrgPlane, Landing, Palettes, VoidView, DataSurface); the rule: views read
`WindowModel` and dispatch through it; nothing worth asserting is decided in `WakilApp` (no test
target).

`docs/architecture/runtime.md`: `WakilWiring.build` (what it creates: the four `MCPClient`s, stores,
registry, brokers, vocabulary, speech, root watcher; the `register*Actions` calls; `wakilOwnedClients`);
`WindowSession.start` (socket path, harness factory, `WindowModel`, `ComposerModel`,
`MCPSocketServer`, `useActiveContext`); `WindowModel` (owns references, never writes `PaneStore`
directly, reads back via `refreshPanes()`); binary location order (`WAKIL_BIN_DIR` exclusive, bundle
`Contents/Resources`, checkout `bin/`) and the child environment; lifetimes and shutdown order
(`model.shutdown` → `socketServer.stop` → `wiring.shutdown`).

`docs/architecture/flows.md`: the three flows from the spec, each as a numbered list of hops naming
the function at each hop (click → `dispatchFromSurface` → `WindowModel.dispatch` →
`ActionRegistry.dispatch` → `writeGate` → handler → `callChecked`/`MCPClient.callTool` → binary →
`layout.setFetch`/`panes.setRows` → journal → `refreshPanes()` → view; agent call → `--allowedTools` /
`approve_tool_use` → `permissionDecision` → shim → `MCPSocketServer` → `handleToolsCall` →
`registry.dispatch(origin: .agent)` → `parkForConfirmation` on `needsConfirmation`; org switch →
`requestOrganizationSwitch` → `setOrganization` → `harness.stop()` → `invalidateForOrgChange()` →
`WakilWiring.switchOrg` → `refreshContext()`).

`docs/architecture/state.md`: a table — `~/.wakil/orgs/<org>/{org.json,projects.json,active.json,
providers/,sessions.json}`, project `.wakil/project.json`, Keychain services (`wakil:<org>:<ref>`,
`wakil:<org>:provider:<id>`; read via `/usr/bin/security` in Go, `wakil provider credentials` from the
app), layouts `~/.wakil/layouts/<org>/<project>.json` and conversation layouts, journal
`~/.wakil/journal/<sessionId>.jsonl`, vocabulary cache, in-memory only (recent api sends, capped 200),
transcripts under the provider config dir; what `invalidateForOrgChange()` resets and the tripwire
(`InvalidationContractTests`) that keeps it honest.

`docs/architecture/testing.md`: Swift unit tests (`app/Tests/WakilKitTests`, Swift Testing,
`scripts/swift-test.sh`), `LayeringTests`, `InvalidationContractTests`, `ActionClassificationTests`,
`AppWiringTests`; Go tests (`go test ./...`, `layering_test.go`, `mcpx/shippedbinary_test.go`,
`scripts/*_test.go` including the new docs check, `make test-live`); e2e (`e2e/cmd/wakil-e2e`,
`e2e/checks/{unseeded,seeded,agent}/*.jsonl`, step kinds, `uncoverable.tsv`, the auditor —
link `docs/agents/e2e.md`); acceptance runbooks (`docs/wakil/*-acceptance.md`, `make e2e-runbook`);
a table of make targets with one line each; "`make app-test` does not build Go".

`CONTRIBUTING.md`:
- `# Contributing to Wakil` — read `docs/architecture/README.md` first; the workflow is
  `docs/agents/workflow.md` (Design → Plan → Build → Cover → Walk), link don't repeat.
- `## Where does my code go?` — a table: a new capability that touches a system → a Go binary tool
  (`internal/wakilcore` logic + `cmd/<binary>`); an operator or agent action → `register*Actions` in
  the owning folder; state a pane shows → its pane kind's folder; pure decisions a view needs →
  WakilKit beside the kind (never `WakilApp`); drawing → `WakilApp`; shared value types with no
  dependencies → `Core/`; window orchestration → `App/` (last resort; nothing may use it).
- `## Recipes` — `### A new action` (Action fields, audience, `operatorOnlyActions`,
  `ActionClassificationTests`); `### A new MCP binary` (the full list: `cmd/<name>/main.go`, `BINS`,
  `scripts/make-app-bundle.sh`, `.gitignore`, `scripts/app_bundle_test.go`,
  `scripts/register-provider.sh` and its test, then window-owned via `WakilWiring.build` +
  `wakilOwnedClients` + `register*Actions`, or agent-facing via `agentFacingServers`; a `### <name>`
  in `docs/architecture/go.md`); `### A new pane kind` (today's seven places, marked "until the
  pluggable pane kinds stack lands", plus the target three-place recipe); `### A new WakilKit folder`
  (a `### <Folder>/` section in `wakilkit.md`, allow-list entries, why it isn't in an existing folder);
  `### A new provider` (link `docs/wakil/org-and-provider-model.md`).
- `## Tests every change needs` — a table by kind of change (Swift logic → Swift Testing in
  `WakilKitTests`; a `WindowModel` stored property → classify it in `InvalidationContractTests`; a new
  folder link → allow-list line; UI control → e2e check or an `uncoverable.tsv` line with its reason;
  Go → `go test`).
- `## Before a PR` — `make build`, `make test`, `make app-test`, and `make e2e` for UI changes (ask the
  operator for the screen); no `Co-Authored-By` lines.

`CLAUDE.md`: under the first paragraph add:
```markdown
**Code map:** `docs/architecture/README.md` (the whole app, Swift and Go) and `CONTRIBUTING.md`
(where code goes, recipes, the tests each change needs). Read them before changing structure.
```
`AGENTS.md`: add `docs/architecture/README.md` and `CONTRIBUTING.md` to its pointer line.

- [ ] **Step 6: Run the gates for this task**

Run: `go test ./scripts/ -v -run 'TestArchitectureDocs' && make test`
Expected: PASS; `make test` prints the charter word count unchanged (3998/4000) and Go `ok`.

- [ ] **Step 7: Commit**

```bash
git add scripts/architecture_docs_test.go docs/architecture CONTRIBUTING.md CLAUDE.md AGENTS.md
git commit -m "Architecture reference and contribution guide, with a check that every folder and binary is documented (PR 1 of 9)"
```

---

### Task 2: `PaneKind` and slot storage — the storage swap (PR 2)

`gh stack add yehia-khalil/pane-kinds-2-storage`

**Files:**
- Create: `app/Sources/WakilKit/Panes/PaneKind.swift`
- Create: `app/Sources/WakilKit/Panes/DataSurfacePaneKind.swift`, `SettingsPaneKind.swift`,
  `GitPaneKind.swift`, `TerminalPaneKind.swift`, `ApiPaneKind.swift`
- Create: `app/Sources/WakilKit/App/PaneKinds.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (storage core, accessors, the matches listed below)
- Modify: `app/Sources/WakilKit/Panes/PaneSnapshot.swift` (`PaneSnapshot`, delete `PaneSnapshotContents`)
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (delete `Contents.emptySnapshot`; `settingsKind` reads `SettingsPaneKind`)
- Modify: `App/AppWiring.swift`, `App/WindowModel.swift` (two `PaneStore()` → `PaneStore(kinds: PaneKinds.standard)`; rewrite matches)
- Modify: `MCP/PaneSnapshotJSON.swift`, `Identifiers/IdentifierSources.swift` (rewrite matches)
- Test: `app/Tests/WakilKitTests/PaneKindStorageTests.swift`; mechanical rewrites in the 7 test files that match `PaneSnapshotContents` cases

**Interfaces:**
- Produces (used by Tasks 3–8):
  - `public protocol PaneKind: SendableMetatype` with `Contents`, `Shared`, `Snapshot`, `names`,
    `emptyContents`, `emptyShared`, `emptySnapshot: Snapshot?`, `rerunsSubjectOnRestore`,
    `snapshot(of:in:)`, `failure(of:)`, `sharedAfterClearingAllScopes(_:)`, `sharedAfterSwitchingScope(_:)`
  - `public protocol PaneKindSnapshot: Sendable, Equatable`
  - `PaneStore`: `init(kinds: [any PaneKind.Type] = [])`, internal `contents(_:_:)`,
    `setContents(_:_:_:)`, `holds(_:_:)`, `kindState(_:)`, `setKindState(_:_:)`,
    `scope(holding:paneId:where:)`, `inScope(_:_:)`
  - kinds: `DataSurfacePaneKind`, `SettingsPaneKind`, `GitPaneKind`, `TerminalPaneKind`, `ApiPaneKind`
  - `PaneSnapshot.contents: (any PaneKindSnapshot)?`; typed reads `.dataSurface`, `.terminal`, `.api`, `.git`
  - `enum PaneKinds { static let standard; static func kind(named:); static func is(_:_:) }`

- [ ] **Step 1: Write the storage pins** (characterization: they must pass on today's code once the
  kinds API exists; until then they fail to compile — that is the RED)

```swift
import Foundation
import Testing
@testable import WakilKit

/// What the slot storage must keep doing exactly as the per-kind enum did (pluggable pane kinds, PR 2).

@Test func aPaneHoldingOneKindRefusesAnother() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    await store.setGit(paneId: "p", .empty)
    await store.setTerminalProposal(paneId: "p", nil)
    await store.setRows(
        paneId: "p", columns: ["a"], columnTypes: ["text"], columnTypesInferred: false,
        rows: [[.string("x")]], millis: 1, truncated: false, pageable: false, offset: 0,
        sort: [], listsTables: false, editable: nil)
    #expect(await store.snapshot(paneId: "p", kind: "git").git == .empty)
    #expect(await store.snapshot(paneId: "p", kind: "git").dataSurface == nil)
}

@Test func aNeverWrittenPaneAnswersItsKindsEmptySnapshot() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let git = await store.snapshot(paneId: "g", kind: "git")
    #expect(git.git == .empty && git.failure == nil)
    let settings = await store.snapshot(paneId: "s", kind: Pane.settingsKind)
    #expect(settings.contents == nil && settings.failure == nil)
    let unknown = await store.snapshot(paneId: "u", kind: "nope")
    #expect(unknown.contents == nil)
    #expect(unknown.failure == "this build has no contents for a pane of kind \"nope\"")
    let none = await store.snapshot(paneId: "n", kind: nil)
    #expect(none.kind == nil && none.contents == nil && none.failure == nil)
}

@Test func switchingScopeBumpsTheResolutionMarkBeforeAnyWrite() async {
    let store = PaneStore()
    let before = await store.apiResolutionMark()
    await store.switchScope(to: LayoutScope(organization: "acme", project: "widgets"))
    #expect(await store.apiResolutionMark() != before)
}

@Test func clearingAllScopesBumpsTheMarkAndKeepsFlightSubscribers() async {
    let store = PaneStore()
    let flights = await store.apiFlights()
    _ = flights
    let before = await store.apiResolutionMark()
    await store.clearAllScopes()
    #expect(await store.apiResolutionMark() != before)
    #expect(await store.apiFlightSubscriberCount == 1)
}

@Test func adoptingAScopeCarriesItsPanesWithoutBumpingTheMark() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    let seed = LayoutScope(organization: "acme", project: "widgets")
    let conversation = LayoutScope(organization: "acme", project: "widgets", lineageRoot: "r")
    await store.switchScope(to: seed)
    await store.setGit(paneId: "g", .empty)
    let mark = await store.apiResolutionMark()
    await store.switchScope(to: conversation, adoptingFrom: seed)
    #expect(await store.holdsContents(paneId: "g"))
    #expect(await store.apiResolutionMark() == mark)
}
```

- [ ] **Step 2: Run them**

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindStorage|aPaneHolding|aNeverWritten|switchingScope|clearingAllScopes|adoptingAScope'`
Expected: build FAIL — `PaneKinds`, `PaneStore(kinds:)`, `.git`, `.dataSurface` do not exist.

- [ ] **Step 3: Write `Panes/PaneKind.swift`**

```swift
import Foundation

/// One kind of pane: what `PaneStore` holds for each pane of it, what it holds for the whole store,
/// and what readers get back (pluggable pane kinds). A kind's conformance and its store methods live
/// in its own folder, as `extension PaneStore`; `App/PaneKinds.swift` is the one list naming every
/// kind. `Panes/` names none.
public protocol PaneKind: SendableMetatype {
    /// One pane's state.
    associatedtype Contents: Sendable
    /// State this kind keeps for the whole store (Api: recent sends, flight subscribers, the
    /// resolution mark). `Void` for most kinds.
    associatedtype Shared: Sendable = Void
    /// What a reader gets for one pane.
    associatedtype Snapshot: PaneKindSnapshot

    /// The `Pane.kind` strings this kind serves.
    static var names: [String] { get }
    static var emptyContents: Contents { get }
    static var emptyShared: Shared { get }
    /// What a pane of this kind that was never written answers; `nil` answers no contents at all
    /// (settings, whose `read_pane` is built from the config tree instead).
    static var emptySnapshot: Snapshot? { get }
    /// Whether a restored pane of this kind re-runs its subject (a read). Never true for a kind whose
    /// subject can be a write: an api pane's last request may have been a `POST`.
    static var rerunsSubjectOnRestore: Bool { get }

    static func snapshot(of contents: Contents, in store: isolated PaneStore) -> Snapshot
    static func failure(of contents: Contents) -> String?
    /// `clearAllScopes()` (an org switch) calls this on the kind's store-wide state.
    static func sharedAfterClearingAllScopes(_ shared: Shared) -> Shared
    /// `switchScope(to:)` calls this on the kind's store-wide state.
    static func sharedAfterSwitchingScope(_ shared: Shared) -> Shared
}

extension PaneKind {
    public static var rerunsSubjectOnRestore: Bool { false }
    public static func failure(of contents: Contents) -> String? { nil }
    public static func sharedAfterClearingAllScopes(_ shared: Shared) -> Shared { emptyShared }
    public static func sharedAfterSwitchingScope(_ shared: Shared) -> Shared { shared }
}

extension PaneKind where Shared == Void {
    public static var emptyShared: Void { () }
}

/// A pane kind's snapshot. Equality across kinds is false.
public protocol PaneKindSnapshot: Sendable, Equatable {}

extension PaneKindSnapshot {
    func isEqual(to other: any PaneKindSnapshot) -> Bool { (other as? Self) == self }
}

/// One pane in `PaneStore`: which kind holds it, and that kind's contents, held opaquely.
struct PaneSlot {
    let kind: any PaneKind.Type
    var contents: any Sendable
    var kindID: ObjectIdentifier { ObjectIdentifier(kind) }
}
```

- [ ] **Step 4: Change `PaneSnapshot` (`Panes/PaneSnapshot.swift`)**

Replace the `PaneSnapshot` struct and delete `public enum PaneSnapshotContents` (and its doc comment):

```swift
public struct PaneSnapshot: Sendable, Equatable {
    public let kind: String?
    public let failure: String?
    /// The pane kind's own snapshot; `nil` for no contents (no kind, settings, an unknown kind).
    public let contents: (any PaneKindSnapshot)?

    public init(kind: String?, failure: String?, contents: (any PaneKindSnapshot)?) {
        self.kind = kind
        self.failure = failure
        self.contents = contents
    }

    public static func == (a: PaneSnapshot, b: PaneSnapshot) -> Bool {
        guard a.kind == b.kind, a.failure == b.failure else { return false }
        switch (a.contents, b.contents) {
        case (nil, nil): return true
        case let (x?, y?): return x.isEqual(to: y)
        default: return false
        }
    }
}

extension PaneSnapshot {
    public var dataSurface: DataSurfaceSnapshot? { contents as? DataSurfaceSnapshot }
    public var terminal: TerminalSnapshot? { contents as? TerminalSnapshot }
    public var api: ApiSnapshot? { contents as? ApiSnapshot }
    public var git: GitSnapshot? { contents as? GitSnapshot }
}

extension DataSurfaceSnapshot: PaneKindSnapshot {}
extension TerminalSnapshot: PaneKindSnapshot {}
extension ApiSnapshot: PaneKindSnapshot {}
extension GitSnapshot: PaneKindSnapshot {}
```

Keep `PaneSnapshot`'s existing doc comment, replacing any sentence about `PaneSnapshotContents` with
"`contents` is the pane kind's own snapshot (`PaneKind.Snapshot`)".

- [ ] **Step 5: Write the five kinds**

`Panes/DataSurfacePaneKind.swift` — move `private struct DataSurfaceContents { … }` out of
`PaneStore` verbatim (with its doc comment and its `snapshot()`), as file-level `struct
DataSurfaceContents`, then:

```swift
/// The data surface: a grid read from a database (the `db` pane).
enum DataSurfacePaneKind: PaneKind {
    static let names = ["db"]
    static var emptyContents: DataSurfaceContents { DataSurfaceContents() }
    static var emptySnapshot: DataSurfaceSnapshot? { .empty }
    /// Its subject is a read; re-running it is how a reopened pane is current.
    static let rerunsSubjectOnRestore = true
    static func snapshot(of contents: DataSurfaceContents, in store: isolated PaneStore) -> DataSurfaceSnapshot {
        contents.snapshot()
    }
    static func failure(of contents: DataSurfaceContents) -> String? { contents.failure }
}
```

`Panes/SettingsPaneKind.swift`:

```swift
/// The settings pane. `PaneStore` never holds contents for it: everything it draws is re-read from
/// disk on open (Decision 30), and `read_pane` answers for it from the config tree
/// (`MCPServer.readPane`). It is a kind so that its name is known and it never re-runs on restore.
enum SettingsPaneKind: PaneKind {
    struct Snapshot: PaneKindSnapshot {}
    static let names = ["settings"]
    static var emptyContents: Void { () }
    static var emptySnapshot: Snapshot? { nil }
    static func snapshot(of contents: Void, in store: isolated PaneStore) -> Snapshot { Snapshot() }
}
```

In `Layout/Pane.swift`, change `public static let settingsKind = "settings"` to
`public static let settingsKind = SettingsPaneKind.names[0]` (keep its doc comment).

`Panes/GitPaneKind.swift`:

```swift
/// The git pane: per-root status, selection and diff (3a-i). Its contents are its snapshot.
enum GitPaneKind: PaneKind {
    static let names = ["git"]
    static var emptyContents: GitSnapshot { .empty }
    static var emptySnapshot: GitSnapshot? { .empty }
    /// Its subject is a read — `git status` per root.
    static let rerunsSubjectOnRestore = true
    static func snapshot(of contents: GitSnapshot, in store: isolated PaneStore) -> GitSnapshot { contents }
}
```

`Panes/TerminalPaneKind.swift` — move `private struct TerminalContents { … }` out of `PaneStore`
verbatim as file-level `struct TerminalContents`, then:

```swift
/// The terminal pane: a live shell's blocks, screen and input line (2c-iii).
enum TerminalPaneKind: PaneKind {
    static let names = ["terminal"]
    static var emptyContents: TerminalContents { TerminalContents() }
    static var emptySnapshot: TerminalSnapshot? { .empty }
    static func snapshot(of contents: TerminalContents, in store: isolated PaneStore) -> TerminalSnapshot {
        contents.snapshot()
    }
    static func failure(of contents: TerminalContents) -> String? { contents.failure }
}
```

`Panes/ApiPaneKind.swift` — move `private struct ApiContents`, `private struct ApiFlight`,
`private struct ApiRecentKey`, `private struct ApiRecentList` out of `PaneStore` verbatim as
file-level `struct`s (internal), then:

```swift
/// What the api kind keeps for the whole store.
struct ApiShared: Sendable {
    /// Bumped by every scope change and environment switch, so a listing read begun before one
    /// cannot land after it (`reresolveApis(generation:)`).
    var resolutionGeneration = 0
    var flightSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    /// Recent sends per organisation, project and environment (W15); memory only.
    var recent: [ApiRecentKey: ApiRecentList] = [:]
}

/// The api pane: a request draft, its response and its recent sends (9a).
enum ApiPaneKind: PaneKind {
    static let names = ["api"]
    static var emptyContents: ApiContents { ApiContents() }
    static var emptyShared: ApiShared { ApiShared() }
    static var emptySnapshot: ApiSnapshot? { .empty }
    // `rerunsSubjectOnRestore` stays false: an api pane's subject is a REQUEST, and the one it last
    // held may have been a `POST`; re-running it would put an unattended write on the wire at launch.
    // `failure` stays nil: a refusal is this pane working correctly — see `ApiSnapshot`.
    static func snapshot(of contents: ApiContents, in store: isolated PaneStore) -> ApiSnapshot {
        store.apiSnapshot(of: contents)
    }
    /// An org switch: recent sends belong to the outgoing org; any listing read in flight is stale.
    /// Flight subscribers are the window's, not the org's, and stay.
    static func sharedAfterClearingAllScopes(_ shared: ApiShared) -> ApiShared {
        var next = shared
        next.recent = [:]
        next.resolutionGeneration += 1
        return next
    }
    /// A listing read for the scope left behind must not land on this one's panes.
    static func sharedAfterSwitchingScope(_ shared: ApiShared) -> ApiShared {
        var next = shared
        next.resolutionGeneration += 1
        return next
    }
}
```

In `PaneStore`, change `private func apiSnapshot(of contents: ApiContents)` to internal (drop
`private`) so the kind can call it.

- [ ] **Step 6: Swap `PaneStore`'s storage**

In `Panes/PaneStore.swift`:

1. Delete `private enum Contents { … }`.
2. Replace the stored state and `init` with:

```swift
    private var byScope: [LayoutScope: [String: PaneSlot]] = [:]
    private var scope = LayoutScope.initial
    /// Each kind's store-wide state, created on first touch (read or write) so that a scope change
    /// reaches state that has only been read so far.
    private var sharedByKind: [ObjectIdentifier: (kind: any PaneKind.Type, value: any Sendable)] = [:]
    /// The kinds this store knows, for a never-written pane's empty snapshot (`App/PaneKinds.swift`).
    private let kinds: [any PaneKind.Type]

    public init(kinds: [any PaneKind.Type] = []) {
        self.kinds = kinds
    }

    private var panes: [String: PaneSlot] {
        get { byScope[scope] ?? [:] }
        set { byScope[scope] = newValue }
    }

    // MARK: - Generic access, for each kind's store methods

    /// The pane's contents if it holds `kind`, else the kind's empty contents.
    func contents<K: PaneKind>(_ kind: K.Type, _ paneId: String) -> K.Contents {
        guard let slot = panes[paneId], slot.kindID == ObjectIdentifier(kind) else { return K.emptyContents }
        return slot.contents as! K.Contents
    }

    /// Writes `contents` unless the pane already holds another kind — the rule each kind's setter had.
    func setContents<K: PaneKind>(_ kind: K.Type, _ paneId: String, _ contents: K.Contents) {
        if let slot = panes[paneId], slot.kindID != ObjectIdentifier(kind) { return }
        panes[paneId] = PaneSlot(kind: kind, contents: contents)
    }

    func holds<K: PaneKind>(_ kind: K.Type, _ paneId: String) -> Bool {
        panes[paneId]?.kindID == ObjectIdentifier(kind)
    }

    func kindState<K: PaneKind>(_ kind: K.Type) -> K.Shared {
        if let entry = sharedByKind[ObjectIdentifier(kind)] { return entry.value as! K.Shared }
        sharedByKind[ObjectIdentifier(kind)] = (kind, K.emptyShared)
        return K.emptyShared
    }

    func setKindState<K: PaneKind>(_ kind: K.Type, _ value: K.Shared) {
        sharedByKind[ObjectIdentifier(kind)] = (kind, value)
    }

    /// The scope whose pane `paneId` holds `kind` and matches — the active scope first.
    func scope<K: PaneKind>(
        holding kind: K.Type, paneId: String, where match: (K.Contents) -> Bool
    ) -> LayoutScope? {
        func holds(_ panes: [String: PaneSlot]) -> Bool {
            guard let slot = panes[paneId], slot.kindID == ObjectIdentifier(kind) else { return false }
            return match(slot.contents as! K.Contents)
        }
        if holds(panes) { return scope }
        return byScope.first { holds($0.value) }?.key
    }

    private func clearing<K: PaneKind>(_ kind: K.Type, _ value: any Sendable) -> any Sendable {
        K.sharedAfterClearingAllScopes(value as! K.Shared)
    }

    private func switching<K: PaneKind>(_ kind: K.Type, _ value: any Sendable) -> any Sendable {
        K.sharedAfterSwitchingScope(value as! K.Shared)
    }

    private func slotSnapshot<K: PaneKind>(_ kind: K.Type, _ contents: any Sendable, label: String) -> PaneSnapshot {
        let typed = contents as! K.Contents
        return PaneSnapshot(kind: label, failure: K.failure(of: typed), contents: K.snapshot(of: typed, in: self))
    }

    private func slotFailure<K: PaneKind>(_ kind: K.Type, _ contents: any Sendable) -> String? {
        K.failure(of: contents as! K.Contents)
    }

    private func emptySnapshot<K: PaneKind>(_ kind: K.Type, label: String) -> PaneSnapshot {
        PaneSnapshot(kind: label, failure: nil, contents: K.emptySnapshot)
    }
```

3. Replace the Api store-wide stored properties (`private var apiResolutionGeneration = 0`,
   `private var flightSubscribers: …`, `private var apiRecent: …`) with computed properties of the
   same names, so every method that uses them stays verbatim:

```swift
    private var apiResolutionGeneration: Int {
        get { kindState(ApiPaneKind.self).resolutionGeneration }
        set { var s = kindState(ApiPaneKind.self); s.resolutionGeneration = newValue; setKindState(ApiPaneKind.self, s) }
    }

    private var flightSubscribers: [UUID: AsyncStream<String>.Continuation] {
        get { kindState(ApiPaneKind.self).flightSubscribers }
        set { var s = kindState(ApiPaneKind.self); s.flightSubscribers = newValue; setKindState(ApiPaneKind.self, s) }
    }

    private var apiRecent: [ApiRecentKey: ApiRecentList] {
        get { kindState(ApiPaneKind.self).recent }
        set { var s = kindState(ApiPaneKind.self); s.recent = newValue; setKindState(ApiPaneKind.self, s) }
    }
```

4. Replace the per-kind accessors (bodies only; names and signatures unchanged):

```swift
    private func dataSurface(_ paneId: String) -> DataSurfaceContents { contents(DataSurfacePaneKind.self, paneId) }
    private func setDataSurface(_ paneId: String, _ contents: DataSurfaceContents) {
        setContents(DataSurfacePaneKind.self, paneId, contents)
    }
    private func terminal(_ paneId: String) -> TerminalContents { contents(TerminalPaneKind.self, paneId) }
    private func setTerminal(_ paneId: String, _ contents: TerminalContents) {
        setContents(TerminalPaneKind.self, paneId, contents)
    }
    private func api(_ paneId: String) -> ApiContents { contents(ApiPaneKind.self, paneId) }
    private func setApi(_ paneId: String, _ contents: ApiContents) { setContents(ApiPaneKind.self, paneId, contents) }
    public func gitSnapshot(paneId: String) -> GitSnapshot { contents(GitPaneKind.self, paneId) }
    public func setGit(paneId: String, _ snapshot: GitSnapshot) { setContents(GitPaneKind.self, paneId, snapshot) }
```

5. Rewrite every other match on the old enum, mechanically (keep each method's doc comments and
   other lines verbatim):

| Old | New |
|---|---|
| `guard case .api(var contents)? = panes[paneId] else { return }` | `guard holds(ApiPaneKind.self, paneId) else { return }` + `var contents = api(paneId)` |
| `guard case .api(var contents)? = panes[paneId] else { continue }` | `guard holds(ApiPaneKind.self, paneId) else { continue }` + `var contents = api(paneId)` |
| `panes[paneId] = .api(contents)` | `setApi(paneId, contents)` |
| `panes[paneId] = .api(ApiContents())` | `setApi(paneId, ApiContents())` |
| `guard case .dataSurface(let contents)? = panes[paneId] else { return nil }` | `guard holds(DataSurfacePaneKind.self, paneId) else { return nil }` + `let contents = dataSurface(paneId)` |
| `flightScope`'s body | `scope(holding: ApiPaneKind.self, paneId: paneId) { $0.flight?.token == token }` |

   `panes.keys`, `panes[paneId] == nil`, `panes[paneId] = nil` and `holdsContents(paneId:)` work
   unchanged on slots. `inScope(_:_:)`: drop `private` (Task 6 moves its caller out).

6. `switchScope(to:)`: replace `apiResolutionGeneration += 1` (and its comment) with
   `for (id, entry) in sharedByKind { sharedByKind[id] = (entry.kind, switching(entry.kind, entry.value)) }`
   and the comment "Each kind's store-wide state hears of it (Api: a listing read for the scope left
   behind must not land on this one's panes)". `switchScope(to:adoptingFrom:)` is unchanged.

7. `clearAllScopes()`:

```swift
    public func clearAllScopes() {
        byScope = [:]
        for (id, entry) in sharedByKind { sharedByKind[id] = (entry.kind, clearing(entry.kind, entry.value)) }
        scope = .initial
    }
```

8. `failure(paneId:)`:

```swift
    public func failure(paneId: String) -> String? {
        guard let slot = panes[paneId] else { return nil }
        return slotFailure(slot.kind, slot.contents)
    }
```
   Keep the two explanatory comments (api: never a failure; git: a root's own `error`) by moving them
   to `ApiPaneKind` and `GitPaneKind` as doc lines on the kind.

9. `snapshot(paneId:kind:)`:

```swift
    public func snapshot(paneId: String, kind: String?) -> PaneSnapshot {
        guard let kind else { return PaneSnapshot(kind: nil, failure: nil, contents: nil) }
        if let slot = panes[paneId] { return slotSnapshot(slot.kind, slot.contents, label: kind) }
        // A pane that exists and has never been written to answers with its own kind and an empty
        // payload of that kind. An unknown kind says so rather than answering as an empty grid.
        guard let paneKind = kinds.first(where: { $0.names.contains(kind) }) else {
            return PaneSnapshot(
                kind: kind,
                failure: "this build has no contents for a pane of kind \"\(kind)\"",
                contents: nil)
        }
        return emptySnapshot(paneKind, label: kind)
    }
```

- [ ] **Step 7: Write `App/PaneKinds.swift`**

```swift
import Foundation

/// Every pane kind this build knows — the one place they are all named (`App/` may use every folder).
/// `WakilWiring.build` hands it to `PaneStore(kinds:)`. A new kind adds one line here
/// (`CONTRIBUTING.md`, "A new pane kind").
enum PaneKinds {
    static let standard: [any PaneKind.Type] = [
        DataSurfacePaneKind.self,
        TerminalPaneKind.self,
        ApiPaneKind.self,
        SettingsPaneKind.self,
        GitPaneKind.self,
    ]

    static func kind(named name: String) -> (any PaneKind.Type)? {
        standard.first { $0.names.contains(name) }
    }

    /// Whether `name` is served by `kind`.
    static func `is`(_ name: String, _ kind: any PaneKind.Type) -> Bool {
        kind(named: name).map { ObjectIdentifier($0) == ObjectIdentifier(kind) } ?? false
    }
}
```

Change `let panes = PaneStore()` in `App/AppWiring.swift` (`WakilWiring.build`) and in
`App/WindowModel.swift` (`forTesting`) to `let panes = PaneStore(kinds: PaneKinds.standard)`.

- [ ] **Step 8: Rewrite the consumers' matches**

Mechanical, no logic change. A `switch snapshot.contents { case .dataSurface(let x): A … case .none: break }`
becomes an `if let x = snapshot.dataSurface { A } else if let y = snapshot.terminal { B } …` chain in
the same order; `guard case .terminal(let t) = snapshot.contents else { … }` becomes
`guard let t = snapshot.terminal else { … }`; `contents: .none` becomes `contents: nil`;
`contents: .git(s)` becomes `contents: s` (and likewise each kind). Sites:
- `App/WindowModel.swift`: `refreshPanes()` and `refreshTerminal(pane:)`.
- `MCP/PaneSnapshotJSON.swift`: `paneSnapshotJSON`'s switch.
- `Identifiers/IdentifierSources.swift`: `PaneSource.identifiers(for:)`'s switch (`default: break` → the chain's end).
- `Layout/Pane.swift`: delete `Contents.emptySnapshot` (its only reader was `PaneStore.snapshot`).
- Tests: the 7 files with `case .terminal(let`, `.api(`, `.git(`, `.dataSurface(`, `.none` on
  `contents` — find them with
  `grep -rlnE "case \.(terminal|api|git|dataSurface)\(let|contents == \.none|contents: \.(none|terminal|api|git|dataSurface)" app/Tests`.
- Tests constructing `PaneStore()` that then read a never-written pane's snapshot fail with
  "no contents for kind"; give exactly those `PaneStore(kinds: PaneKinds.standard)`.

- [ ] **Step 9: Run the pins and the Panes-touching suites**

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindStorage|aPaneHolding|aNeverWritten|switchingScope|clearingAllScopes|adoptingAScope|PaneStore|Api|Terminal|Git|MCPServer|Identifier|WindowModel|OrgSwitch|PaneContent|Layout'`
Expected: PASS. Then `make app-test` (controller): `Test run with N tests … passed`.

- [ ] **Step 10: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "PaneStore: a slot per pane and store-wide state per kind behind PaneKind; PaneSnapshotContents goes (PR 2 of 9)"
```

---

### Task 3: `Pane.contentsByKind` and `Pane.Contents` go (PR 3)

`gh stack add yehia-khalil/pane-kinds-3-kinds-list`

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (delete `Contents` and `contentsByKind`; keep `kinds`, `settingsKind`, `defaultTitle`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (six readers)
- Test: `app/Tests/WakilKitTests/GitPaneSnapshotTests.swift`, `PaneKindClassificationTests.swift`

**Interfaces:**
- Consumes: `PaneKinds.kind(named:)`, `PaneKinds.is(_:_:)`, `PaneKind.rerunsSubjectOnRestore` (Task 2).

- [ ] **Step 1: Rewrite the classification tests to the kinds list (fail to compile until Step 3)**

In `PaneKindClassificationTests.swift`, replace each `Pane.contentsByKind[k] == .x` with
`PaneKinds.is(k, XPaneKind.self)` and each `Pane.contentsByKind[k]?.rerunsSubjectOnRestore` with
`PaneKinds.kind(named: k)?.rerunsSubjectOnRestore`; replace a check that every `Pane.kinds` entry
has contents with:

```swift
@Test func everyLayoutKindHasAPaneKind() {
    for kind in Pane.kinds { #expect(PaneKinds.kind(named: kind) != nil, "\(kind) has no PaneKind") }
}

@Test func onlyReadsRerunOnRestore() {
    #expect(PaneKinds.kind(named: "db")?.rerunsSubjectOnRestore == true)
    #expect(PaneKinds.kind(named: "git")?.rerunsSubjectOnRestore == true)
    #expect(PaneKinds.kind(named: "api")?.rerunsSubjectOnRestore == false)
    #expect(PaneKinds.kind(named: "terminal")?.rerunsSubjectOnRestore == false)
    #expect(PaneKinds.kind(named: Pane.settingsKind)?.rerunsSubjectOnRestore == false)
}
```
In `GitPaneSnapshotTests.swift`: `#expect(Pane.contentsByKind["git"] == .git)` →
`#expect(PaneKinds.is("git", GitPaneKind.self))`.

- [ ] **Step 2: Delete `Pane.Contents` and `Pane.contentsByKind`** (keep their doc reasoning: move the
  `rerunsSubjectOnRestore` per-kind comments onto each kind's `rerunsSubjectOnRestore` line in Task 2's
  files if not already there).

- [ ] **Step 3: Rewrite `WindowModel`'s readers**

| Old | New |
|---|---|
| `Pane.contentsByKind[$0.kind] == .apiClient` | `PaneKinds.is($0.kind, ApiPaneKind.self)` |
| `Pane.contentsByKind[pane.kind]?.rerunsSubjectOnRestore == true` | `PaneKinds.kind(named: pane.kind)?.rerunsSubjectOnRestore == true` |
| `Pane.contentsByKind[pane.kind] == .git` / `[$0.kind] == .git` | `PaneKinds.is(pane.kind, GitPaneKind.self)` / `PaneKinds.is($0.kind, GitPaneKind.self)` |

- [ ] **Step 4: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindClassification|GitPaneSnapshot|everyLayoutKind|onlyReadsRerun|WindowModel|Restore|Layout'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "Layout: Pane.contentsByKind and Pane.Contents give way to PaneKinds (PR 3 of 9)"
```

---

### Task 4: Git's kind and store methods move to `Git/` (PR 4)

`gh stack add yehia-khalil/pane-kinds-4-git`

**Files:**
- Move: `app/Sources/WakilKit/Panes/GitPaneKind.swift` → `app/Sources/WakilKit/Git/GitPaneKind.swift` (`git mv`)
- Create: `app/Sources/WakilKit/Git/PaneStore+Git.swift`
- Modify: `app/Sources/WakilKit/Panes/PaneStore.swift` (cut), `Panes/PaneSnapshot.swift` (cut two lines)

- [ ] **Step 1: Move** — `git mv` the kind file. Cut `gitSnapshot(paneId:)`, `setGit(paneId:_:)` and
  `updateGit(paneId:_:)` (with doc comments and `@discardableResult`) from `PaneStore.swift` into:

```swift
import Foundation

// The git kind's store methods (pluggable pane kinds): same actor, same names as before.
extension PaneStore {
    // <the three methods, verbatim>
}
```
  Cut `public var git: GitSnapshot? { contents as? GitSnapshot }` and
  `extension GitSnapshot: PaneKindSnapshot {}` from `PaneSnapshot.swift` into `GitPaneKind.swift`
  (as `extension PaneSnapshot { … }` and the conformance).

- [ ] **Step 2: Verify `Panes/` no longer names Git**

Run: `grep -rn "Git" app/Sources/WakilKit/Panes/ | grep -v "///\|//" `
Expected: no type references to `GitSnapshot` or `GitPaneKind` (comments only).

- [ ] **Step 3: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'Git|PaneKind|Layering'`
Expected: Git tests PASS. `wakilKitKeepsItsLayering` FAILS with a stale entry `Panes -> Git` — remove
that line from `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`, rerun, PASS.

- [ ] **Step 4: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "Git: its pane kind and store methods live in Git/ (PR 4 of 9)"
```

---

### Task 5: Terminal's kind, contents, snapshot and store methods move to `Terminal/` (PR 5)

`gh stack add yehia-khalil/pane-kinds-5-terminal`

**Files:**
- Move: `Panes/TerminalPaneKind.swift` → `Terminal/TerminalPaneKind.swift` (`git mv`)
- Create: `Terminal/PaneStore+Terminal.swift`, `Terminal/TerminalSnapshot.swift`
- Modify: `Panes/PaneStore.swift`, `Panes/PaneSnapshot.swift` (cut)

- [ ] **Step 1: Move** — `git mv` the kind file. Cut `public struct TerminalSnapshot` (with its doc
  comment, `empty` and extensions) from `PaneSnapshot.swift` into `Terminal/TerminalSnapshot.swift`
  (`import Foundation` first). Cut `public var terminal: TerminalSnapshot? { … }` and
  `extension TerminalSnapshot: PaneKindSnapshot {}` into `TerminalPaneKind.swift`.
  Cut from `PaneStore.swift`, verbatim with doc comments, into
  `Terminal/PaneStore+Terminal.swift` as `extension PaneStore { … }`:
  `terminal(_:)` and `setTerminal(_:_:)` (drop `private`, make them internal — other kinds' files may
  not use them, by convention), `recordTerminal(paneId:block:)`, `setTerminalLiveState(…)`,
  `setTerminalProposal(paneId:_:)`, `terminalProposal(paneId:)`, `setTerminalScrollTarget(paneId:blockId:)`,
  `terminalScrollTarget(paneId:)`, `setTerminalBackfilledAt(paneId:_:)`, `terminalBackfilledAt(paneId:)`,
  `terminalBlocks(paneId:)`, `clearTerminalBlocks(paneId:)`, `clearTerminal(paneId:)`,
  `appendMirrored(paneId:block:)`.

- [ ] **Step 2: Verify `Panes/` no longer names Terminal**

Run: `grep -rnE "\bTerminal[A-Z]\w*" app/Sources/WakilKit/Panes/ | grep -vE "^\S+:\s*///|//"`
Expected: none outside comments.

- [ ] **Step 3: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'Terminal|PaneKind|Layering'`
Expected: PASS after removing the now-stale `Panes -> Terminal` line from `layering-allowed.txt`.

- [ ] **Step 4: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "Terminal: its pane kind, contents, snapshot and store methods live in Terminal/ (PR 5 of 9)"
```

---

### Task 6: Api's kind, contents, shared state, snapshot types and store methods move to `Api/` (PR 6)

`gh stack add yehia-khalil/pane-kinds-6-api`

**Files:**
- Move: `Panes/ApiPaneKind.swift` → `Api/ApiPaneKind.swift`; `Panes/ApiSnapshot.swift` → `Api/ApiSnapshot.swift` (`git mv`)
- Create: `Api/PaneStore+Api.swift`
- Modify: `Panes/PaneStore.swift`, `Panes/PaneSnapshot.swift` (cut)

- [ ] **Step 1: Move** — `git mv` both files. Cut `public var api: ApiSnapshot? { … }` and
  `extension ApiSnapshot: PaneKindSnapshot {}` from `PaneSnapshot.swift` into `ApiPaneKind.swift`.
  Cut from `PaneStore.swift`, verbatim with doc comments, into `Api/PaneStore+Api.swift` as
  `extension PaneStore { … }`:
  - the computed `apiResolutionGeneration`, `flightSubscribers`, `apiRecent` (from Task 2, now
    internal), `api(_:)`, `setApi(_:_:)` (internal)
  - `apiResolutionMark()`, `apiFlights()`, `unsubscribeApiFlights(_:)`, `apiFlightSubscriberCount`,
    `publishFlight(_:)`, `flightScope(paneId:token:)` (internal)
  - `openApi(…)`, `apiDraft(paneId:)`, `keepApiDraft(paneId:_:line:)`, `apiKeptDraft(paneId:)`,
    `apiFillLine(paneId:)`, `forgetApiKeptDraft(paneId:)`, `setApiDraft(…)`, `setApiResponse(paneId:response:)`,
    `clearApiResponses(to:)`, `reresolveApis(…)`, `beginApiSend(…)`, `armApiSend(…)`, `cancelApiSend(paneId:)`,
    `finishApiSend(…)`, `recentCap`, `recentKey(_:)`, `apiSnapshot(of:)`, `recordApiSend(…)`,
    both `reopenApiRow(…)`, `apiResponse(paneId:)`, `setApiFocus(…)`, `addApiFocus(…)`, `apiFocus(paneId:)`,
    `apiSnapshot(paneId:)`
  - the data-surface reads Api owns: `sourcePane(paneId:)`, `apiSources()`, `dropSource(paneId:row:)`
    (they return `ApiSourcePane` / `ApiDropSource`); `dataSurface(_:)` in `PaneStore.swift` drops
    `private` so they can call it.
  Keep `public static let recentCap = 200` as is: a static stored property is allowed in an extension.

- [ ] **Step 2: Verify `Panes/` no longer names Api**

Run: `grep -rnE "\bApi[A-Z]\w*|\bapi[A-Z]\w*\(" app/Sources/WakilKit/Panes/ | grep -vE "^\S+:\s*///|//"`
Expected: none outside comments.

- [ ] **Step 3: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'Api|PaneKind|PaneStore|Layering'`
Expected: PASS after removing the now-stale `Panes -> Api` line from `layering-allowed.txt`.

- [ ] **Step 4: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "Api: its pane kind, shared state, snapshot types and store methods live in Api/ (PR 6 of 9)"
```

---

### Task 7: `read_pane` and identifiers through the kinds; a cell per pane in `WindowModel` (PR 7)

`gh stack add yehia-khalil/pane-kinds-7-consumers`

**Files:**
- Modify: `Panes/PaneKind.swift` (add `readPane`), `Panes/PaneStore.swift` (add `readPane(paneId:kind:)`)
- Modify: each kind file (`Panes/DataSurfacePaneKind.swift`, `Panes/SettingsPaneKind.swift`,
  `Git/GitPaneKind.swift`, `Terminal/TerminalPaneKind.swift`, `Api/ApiPaneKind.swift`) — its `readPane`
- Delete: `MCP/PaneSnapshotJSON.swift`'s `paneSnapshotJSON` (move its helpers `apiPartsJSON`,
  `apiNamedRowJSON` and any other api-only helpers into `Api/ApiPaneKind+ReadPane.swift`)
- Modify: `MCP/MCPServer.swift` (`readPane`), `Git/GitActions.swift` (`snapshot(_:)`)
- Modify: `Identifiers/IdentifierSources.swift` (`OffersIdentifiers`, `PaneSource`)
- Create: `Terminal/TerminalSnapshot+Identifiers.swift`, `Api/ApiSnapshot+Identifiers.swift`
- Create: `App/PaneSnapshotCell.swift`; Modify: `App/WindowModel.swift`, `WakilApp/Canvas.swift`
- Test: `app/Tests/WakilKitTests/PaneSnapshotCellTests.swift`; rewrites in tests calling
  `paneSnapshotJSON` or reading `terminalSnapshots`/`apiSnapshots`/`gitSnapshots`; `InvalidationContractTests.swift`

**Interfaces:**
- Produces: `static func readPane(_ snapshot: Snapshot, in store: isolated PaneStore) -> [String: JSONValue]`
  on `PaneKind`; `public func readPane(paneId: String, kind: String?) -> JSONValue` on `PaneStore`;
  `public protocol OffersIdentifiers { func identifiers(origin: String) -> [Identifier] }`;
  `WindowModel.api(_:) -> ApiSnapshot?`, `WindowModel.git(_:) -> GitSnapshot?` (with existing `terminal(_:)`).

- [ ] **Step 1: Write the redraw pin (fails to compile: no `paneCells` yet)**

```swift
import Foundation
import Observation
import Testing
@testable import WakilKit

/// A pane's update redraws only that pane (pluggable pane kinds, PR 7) — the 240.5 ms/frame
/// regression `refreshTerminal`'s doc comment records must not come back.
@MainActor
@Test func aTerminalTickInvalidatesOnlyItsOwnPane() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    // A terminal pane in the store; the first refresh adds its cell (a pane opening may redraw).
    await model.panesForTesting.setTerminalProposal(paneId: "t1", nil)
    await model.refreshTerminal(pane: "t1")
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking {
        _ = model.api("a1")
        _ = model.git("g1")
    } onChange: { flag.fired = true }
    // Every later tick must touch only t1's own cell.
    await model.refreshTerminal(pane: "t1")
    #expect(!flag.fired)
    #expect(model.terminal("t1") != nil)
}
```

- [ ] **Step 2: Run it**

Run: `cd app && ../scripts/swift-test.sh --filter 'aTerminalTickInvalidatesOnlyItsOwnPane'`
Expected: build FAIL (`api(_:)` and `git(_:)` do not exist yet). The pin guards against a wrong
merge, so its behavioural RED is proven in Step 5 against a deliberately wrong `refreshTerminal`.

- [ ] **Step 3: Write `App/PaneSnapshotCell.swift`**

```swift
import Foundation
import Observation

/// One pane's snapshot, observed on its own: an update to one pane redraws only the views reading
/// that pane. `WindowModel.paneCells` changes only when a pane opens or closes. (A single shared
/// dictionary would make every terminal tick redraw every pane — see `refreshTerminal`.)
@MainActor
@Observable
public final class PaneSnapshotCell {
    public internal(set) var snapshot: PaneSnapshot
    init(_ snapshot: PaneSnapshot) { self.snapshot = snapshot }
}
```

- [ ] **Step 4: `WindowModel`: cells, per-pane reads**

Replace `terminalSnapshots`, `apiSnapshots`, `gitSnapshots` with:

```swift
    /// Every open pane's snapshot, one observable cell per pane (`PaneSnapshotCell`).
    public private(set) var paneCells: [String: PaneSnapshotCell] = [:]

    public func terminal(_ paneId: String) -> TerminalSnapshot? { paneCells[paneId]?.snapshot.terminal }
    public func api(_ paneId: String) -> ApiSnapshot? { paneCells[paneId]?.snapshot.api }
    public func git(_ paneId: String) -> GitSnapshot? { paneCells[paneId]?.snapshot.git }

    /// Puts `snapshot` in `paneId`'s cell, adding the cell only if the pane is new.
    private func setCell(_ paneId: String, _ snapshot: PaneSnapshot) {
        if let cell = paneCells[paneId] { cell.snapshot = snapshot } else { paneCells[paneId] = PaneSnapshotCell(snapshot) }
    }
```

`refreshPanes()`: keep the data-surface branch building `tables`/`editables`; for every pane call
`setCell(pane.id, snapshot)`; after the loop drop cells whose pane is gone, reassigning `paneCells`
only if its key set changed:

```swift
        let open = Set(layoutPanes.map(\.id))
        if Set(paneCells.keys) != open { paneCells = paneCells.filter { open.contains($0.key) } }
```
(`layoutPanes` = the `await layout.snapshot().panes` the loop already reads; bind it to a `let` first.)

`refreshTerminal(pane:)`: `guard snapshot.terminal != nil else { return }` then `setCell(pane, snapshot)`.

`invalidateForOrgChange()`: replace the three `= [:]` lines with `paneCells = [:]`.

The two internal readers: `apiSnapshots[$0.id]?.sending` → `api($0.id)?.sending`;
`apiSnapshots[pane.id]?.entry` → `api(pane.id)?.entry`; `gitSnapshots[pane.id]?.roots.count` →
`git(pane.id)?.roots.count`.

`WakilApp/Canvas.swift`: `model.apiSnapshots[pane.id] ?? .empty` → `model.api(pane.id) ?? .empty`
(twice) and `model.gitSnapshots[pane.id] ?? .empty` → `model.git(pane.id) ?? .empty`.

Tests: `model.apiSnapshots[id]` → `model.api(id)`; `model.gitSnapshots[id]` → `model.git(id)`.

`InvalidationContractTests.swift`: in `orgDerived`, replace `"terminalSnapshots", "apiSnapshots",`
and `"gitSnapshots",` with `"paneCells",`, and rewrite their comment to say each open pane's snapshot
lives in one cell and `invalidateForOrgChange` empties `paneCells`.

- [ ] **Step 5: Prove the pin can fail, then pass**

Temporarily make `refreshTerminal` reassign the whole dictionary
(`paneCells = paneCells.merging([pane: PaneSnapshotCell(snapshot)]) { $1 }`), run Step 2's command:
Expected FAIL (`!flag.fired`). Restore `setCell(pane, snapshot)`, rerun: Expected PASS.

- [ ] **Step 6: `read_pane` through the kinds**

Add to `PaneKind` (in `Panes/PaneKind.swift`) the requirement, with the doc line "what the agent's
`read_pane` sees for this kind, merged into the envelope (`kind`, `failure`); store-isolated because
Api's previews read data-surface rows (#192)":

```swift
    static func readPane(_ snapshot: Snapshot, in store: isolated PaneStore) -> [String: JSONValue]
```

Add to `PaneStore`:

```swift
    /// `read_pane`'s answer for one pane: the envelope every kind shares, plus the kind's own keys.
    public func readPane(paneId: String, kind: String?) -> JSONValue {
        let snapshot = snapshot(paneId: paneId, kind: kind)
        var object: [String: JSONValue] = [
            "kind": snapshot.kind.map { .string($0) } ?? .null,
            "failure": snapshot.failure.map { .string($0) } ?? .null,
        ]
        if let slot = panes[paneId] {
            object.merge(slotReadPane(slot.kind, snapshot.contents)) { _, kindKey in kindKey }
        } else if let kind, let paneKind = kinds.first(where: { $0.names.contains(kind) }) {
            object.merge(slotReadPane(paneKind, snapshot.contents)) { _, kindKey in kindKey }
        }
        return .object(object)
    }

    private func slotReadPane<K: PaneKind>(_ kind: K.Type, _ contents: (any PaneKindSnapshot)?) -> [String: JSONValue] {
        guard let typed = contents as? K.Snapshot else { return [:] }
        return K.readPane(typed, in: self)
    }
```

Move each `case` body of `paneSnapshotJSON` verbatim into its kind's `readPane` (building and
returning the `[String: JSONValue]` it used to write into `object`): data surface →
`DataSurfacePaneKind.readPane`; api → `ApiPaneKind.readPane`, replacing the `sources` parameter with
`store.apiSources()`; git → `GitPaneKind.readPane`; terminal → `TerminalPaneKind.readPane`; settings →
`return [:]`. Delete `paneSnapshotJSON`.

`MCPServer.readPane`: replace the `paneSnapshotJSON(await panes.snapshot(…), sources: await panes.apiSources())`
call with `await panes.readPane(paneId: paneId, kind: kind)`; keep the #192 comment, reworded: "Api's
`readPane` reads `apiSources()` itself, inside the store — an omitted lookup would make every bound
value read as from a closed pane." `GitActions`' `snapshot(_:)`: `await panes.readPane(paneId: pane, kind: "git")`.

Tests calling `paneSnapshotJSON(snapshot)`: rewrite to `await store.readPane(paneId: id, kind: kind)`
using the store, pane id and kind the snapshot came from.

- [ ] **Step 7: Identifiers through the kinds**

In `Identifiers/IdentifierSources.swift`:

```swift
/// A pane kind's snapshot that offers names to the vocabulary (`PaneSource`). Conform in the kind's
/// own folder; a kind that offers none (git: `GitSource` reads repositories instead) does not.
public protocol OffersIdentifiers {
    func identifiers(origin: String) -> [Identifier]
}

extension DataSurfaceSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        var out: [Identifier] = []
        if let table = editable?.table {
            out.append(Identifier(text: table, kind: .table, origin: origin, source: .panes))
        }
        out += columns.map { Identifier(text: $0, kind: .column, origin: origin, source: .panes) }
        return out
    }
}
```
and `PaneSource.identifiers(for:)`'s loop body becomes:

```swift
            let origin = "pane · \(pane.title)"
            let contents = await panes.snapshot(paneId: pane.id, kind: pane.kind).contents
            if let offering = contents as? any OffersIdentifiers { out += offering.identifiers(origin: origin) }
```
`Terminal/TerminalSnapshot+Identifiers.swift`:
```swift
extension TerminalSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        [Identifier(text: cwd, kind: .path, origin: origin, source: .panes)]
    }
}
```
`Api/ApiSnapshot+Identifiers.swift`:
```swift
extension ApiSnapshot: OffersIdentifiers {
    public func identifiers(origin: String) -> [Identifier] {
        [Identifier(text: entry, kind: .endpoint, origin: origin, source: .panes),
         Identifier(text: apiRenderedPath(request.path), kind: .endpoint, origin: origin, source: .panes)]
    }
}
```
(Each with `import Foundation`; `DataSurfaceSnapshot`'s conformance lives in `Identifiers/` because
`Panes -> Identifiers` would create a new mutual pair.)

- [ ] **Step 8: Run**

Run: `cd app && ../scripts/swift-test.sh --filter 'aTerminalTick|PaneSnapshot|ReadPane|MCPServer|Identifier|Vocabulary|Api|Git|Terminal|WindowModel|InvalidationContract|OrgSwitch|Layering'`
Expected: PASS. `wakilKitKeepsItsLayering` may report new links (`Terminal -> Identifiers`,
`Api -> Identifiers`) and stale ones (`Identifiers -> Api`, `MCP -> Api` if gone): add the new
intended ones and delete the stale ones in `layering-allowed.txt`, each change named in the commit
message. Then `make app-test` (controller).

- [ ] **Step 9: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "read_pane and identifiers ask the pane's kind; WindowModel keeps one observable cell per pane (PR 7 of 9)"
```

---

### Task 8: `PaneContentActions` moves to `Registry/`; Panes' reverse links go; `PaneKindsTests` (PR 8)

`gh stack add yehia-khalil/pane-kinds-8-lock`

**Files:**
- Move: `app/Sources/WakilKit/Panes/PaneContentActions.swift` → `app/Sources/WakilKit/Registry/PaneContentActions.swift` (`git mv`)
- Modify: `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`
- Create: `app/Tests/WakilKitTests/PaneKindsTests.swift`

- [ ] **Step 1: Write `PaneKindsTests`**

```swift
import Foundation
import Testing
@testable import WakilKit

/// The kinds list's rules (pluggable pane kinds): every kind is listed once, no two kinds serve the
/// same name, every layout kind has a kind, and every kind's empty pane answers `read_pane`.

@Test func everyKindIsListedOnceAndNamesAreUnique() {
    let ids = PaneKinds.standard.map { ObjectIdentifier($0) }
    #expect(Set(ids).count == ids.count)
    let names = PaneKinds.standard.flatMap { $0.names }
    #expect(Set(names).count == names.count, "two kinds serve the same name: \(names)")
}

@Test func everyLayoutKindIsServed() {
    for kind in Pane.kinds { #expect(PaneKinds.kind(named: kind) != nil, "\(kind) has no PaneKind") }
}

@Test func everyKindsEmptyPaneAnswersReadPane() async {
    let store = PaneStore(kinds: PaneKinds.standard)
    for kind in PaneKinds.standard.flatMap(\.names) {
        guard case .object(let fields) = await store.readPane(paneId: "empty-\(kind)", kind: kind) else {
            Issue.record("\(kind): read_pane is not an object"); continue
        }
        #expect(fields["kind"] == .string(kind))
        #expect(fields["failure"] == .null, "\(kind): \(String(describing: fields["failure"]))")
    }
}
```

- [ ] **Step 2: Run it**

Run: `cd app && ../scripts/swift-test.sh --filter 'PaneKindsTests|everyKindIsListedOnce|everyLayoutKindIsServed|everyKindsEmptyPane'`
Expected: PASS (these pin what Tasks 2–7 built; RED was proven per task).

- [ ] **Step 3: Move `PaneContentActions.swift`** with `git mv`; nothing in it changes.

- [ ] **Step 4: Shrink the allow-list**

Run: `cd app && ../scripts/swift-test.sh --filter 'wakilKitKeepsItsLayering'`
Expected: FAIL listing stale entries `Panes -> Layout` and `Panes -> Registry` (and a new link
`Registry -> Layout` only if not already listed). Delete the stale lines; confirm no `Panes -> X`
line remains except links to folders that are not pane kinds (expected: none). Rerun: PASS.

- [ ] **Step 5: Run the gates**

Run: `make build && make app-test && make test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A app/Sources app/Tests
git commit -m "Panes names no pane kind: PaneContentActions moves to Registry/, the reverse links leave the allow-list, PaneKindsTests (PR 8 of 9)"
```

---

### Task 9: The docs, updated to what was built; the remeasure (PR 9)

`gh stack add yehia-khalil/pane-kinds-9-docs`

**Files:**
- Modify: `docs/architecture/wakilkit.md`, `docs/architecture/wakilapp.md`, `docs/architecture/runtime.md`,
  `docs/architecture/flows.md`, `docs/architecture/testing.md`, `CONTRIBUTING.md`

- [ ] **Step 1: Update the docs**

- `wakilkit.md` `## Pane kinds`: drop "Being built"; describe what exists — `Panes/PaneKind.swift`,
  slots, `kindState`, the two scope hooks, `PaneStore(kinds:)`, `App/PaneKinds.swift`, each kind's
  files by folder, `readPane`, `OffersIdentifiers`, `PaneSnapshotCell`. Update each folder section that
  gained or lost files (Panes, Git, Terminal, Api, Registry, Identifiers, MCP, App).
- `CONTRIBUTING.md` `### A new pane kind`: replace the seven-place list with the three-place recipe
  (folder: conformance + `PaneStore+<Kind>.swift` + `readPane` + optional `OffersIdentifiers` +
  actions + tests; `WakilApp`: view + one canvas `case`; `App/PaneKinds.swift`: one line) and the
  tests it needs (`PaneKindsTests` covers registration automatically).
- `flows.md`: the click flow's last hops now read `refreshPanes()` → `setCell` → the pane's view.
- `testing.md`: add `PaneKindsTests`, `PaneKindStorageTests`, `PaneSnapshotCellTests`.

- [ ] **Step 2: Remeasure and record it in `wakilkit.md` `## The cycle`**

Run:
```bash
python3 - <<'EOF'
lines=[l.strip() for l in open("app/Tests/WakilKitTests/Fixtures/layering-allowed.txt") if l.strip() and not l.startswith("#")]
E={tuple(x.strip() for x in l.split("->")) for l in lines}
nodes=sorted({a for a,b in E}|{b for a,b in E}); adj={n:set() for n in nodes}
for a,b in E: adj[a].add(b)
idx={};low={};st=[];on=set();out=[];c=[0]
def sc(v):
    idx[v]=low[v]=c[0];c[0]+=1;st.append(v);on.add(v)
    for w in adj[v]:
        if w not in idx: sc(w);low[v]=min(low[v],low[w])
        elif w in on: low[v]=min(low[v],idx[w])
    if low[v]==idx[v]:
        comp=[]
        while True:
            w=st.pop();on.discard(w);comp.append(w)
            if w==v: break
        out.append(sorted(comp))
for n in nodes:
    if n not in idx: sc(n)
print("links",len(E)); print("cycles",[x for x in out if len(x)>1])
print("mutual",sorted({tuple(sorted(e)) for e in E if (e[1],e[0]) in E}))
EOF
```
Expected: no mutual pair containing `Panes`; record links, cycle groups and mutual pairs before
(61 links; one cycle of 11; 10 pairs) and after.

- [ ] **Step 3: Run**

Run: `go test ./scripts/ -run TestArchitectureDocs && make test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add docs/architecture CONTRIBUTING.md
git commit -m "Architecture docs: pane kinds as built, and the remeasured folder graph (PR 9 of 9)"
```

---

## Top of the stack, before merge (controller)

- [ ] `make build && make app-test && make test` — all green.
- [ ] Launch check: `make app-build`, run `WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil`, open a
  terminal, an api and a git pane, type in the terminal; quit. (Ask the operator for the screen.)
- [ ] `make e2e` (operator's OK for the screen; quit any running Wakil first).
- [ ] One fresh whole-stack review on the most capable model, checking every fact in
  `docs/architecture/` against the code as well as the refactor.
- [ ] `gh stack submit --auto`; PR bodies drafted to the operator before `gh pr edit`; merge only on
  the operator's word.
