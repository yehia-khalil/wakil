# 3b-ix Fast Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A composer line that asks for one navigation action runs it at once on the org's quick-tasks model, with a receipt; every other line goes to the agent unchanged.

**Architecture:** Go grows two per-org switches (`ghostText`, `fastPath`) on `config_tree` and stops reading a local provider's `serves`. WakilKit gains `FastPath` (allowed list, prompt, deadline, checks) behind `QuickTasks.respond`, and `ComposerModel.submit` asks it first, dispatching the chosen action as the operator's own click. Settings → Providers draws Model, Ghost-text and Fast path in one place.

**Tech Stack:** Go 1.x (`internal/wakilcore`, `cmd/wakil-ctx`), Swift 6 / SwiftUI (`WakilKit`, `WakilApp`), Swift Testing, the repo's e2e harness.

**Spec:** `docs/superpowers/specs/2026-10-20-3b-ix-fast-path-design.md`

## Global Constraints

- The allowed list is exactly the spec's 26 actions; none may be `.mutate`; `discard` is never sent.
- Dispatch from the fast path uses `origin: .ui` and the operator's `DispatchCaller` (Invariant 2); the journal marks it `via: "fastPath"`.
- Anything that fails a check, throws, or answers late goes to `window.send(line, via:)` unchanged.
- Deadline: **300 ms when the routed `respond` provider is `local`, 2.5 s otherwise** (Ruling R1 below).
- File scope is the top 20 of `PaletteSearch.rank` over the active project's file entries; other scope sets go in full.
- Defaults: `ghostText` = org value, else app-wide `editor.ghostText`, else on. `fastPath` = org value, else on when `quickProvider` names a `local` provider, else off.
- One model per org does every quick task; a `local` provider serves `infill` and `respond`.
- No `Co-Authored-By` or "Generated with" lines in commits. Throwaway output goes in `.scratch/3b-ix/`.
- The public-check pre-push hook rejects home paths in committed docs: use repo-relative paths.
- Interaction Rules 1–9 (PRODUCT.md) bind every UI change; the spec's §Interaction rules lists how.

## Rulings made while planning

- **R1, deadline per kind.** The spec's flat 300 ms would make *Fast path: On* over *Same as agent* never fire (Claude answers in 1.0–1.8 s). The deadline follows the routed provider's kind, as ghost-text's debounce already does: 300 ms local, 2.5 s otherwise. The spec is amended in Task 10.
- **R2, warm-up.** The spike's numbers are with the prompt cache warm. After each `rebuildQuickTasks()` with fast path on, one throwaway `respond` warms it, so the first real line is not a cold prefill past the deadline.
- **R3, numbers as strings.** The 1.5B answers `"line": "120"`. A string of digits for an `integer`/`number` param is converted before the schema check; anything else of the wrong type fails the check.
- **R4, `editor_changes_select`.** The model names an absolute `path` among the files sent; FastPath turns it into the containing project `root`, the relative `path` and `group: "changed"`. A staged-only file is refused by the handler and the refusal is shown whole.
- **R5, the tag lives on the caller.** `DispatchCaller` gains `via: String?` (default nil) and the journal entry records it, rather than a new `dispatch` parameter at every call site.
- **R6, e2e scope.** This plan keeps the existing e2e suite green (3b-viii checks that touch the removed checkboxes and the Editor Ghost-text row are updated). New fast-path checks and the loopback chat stub they need are the **Cover** rung's (the e2e auditor), not this plan's.

## Review Focus

1. **A cold prompt after launch or after switching model** — the first line must not silently always go to the agent. Pinned by R2's warm-up test in Task 7.
2. **A numeric param as a string** (`"line": "120"`) — must run `editor_goto 120`. Pinned in Task 5.
3. **An org switch while a fast-path request is in flight** — the answer must not dispatch into the new org. Pinned in Task 7 (generation check).
4. **A refused action** (`editor_close` on an unsaved tab) — the line must not be lost: the receipt shows the refusal and *Ask the agent instead* sends the original line. Pinned in Task 7.
5. **A pane param naming a pane of the wrong kind** (`db_page` on `editor-1`) — the handler refuses; the receipt shows it whole. Pinned in Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `internal/wakilcore/org.go`, `orgupdate.go`, `configtree.go`, `localprovider.go` | per-org switches, their resolved defaults on `config_tree`, `serves` retired |
| `cmd/wakil-ctx/main.go` | `update_org` takes `ghostText` / `fastPath`; `set_local_provider` ignores `serves` |
| `app/Sources/WakilKit/Panes/SettingsTree.swift` | `SettingsOrg.ghostText` / `fastPath` |
| `app/Sources/WakilKit/App/WindowModel+QuickTasks.swift` | org switches drive `ghostTextEnabled` / `fastPathEnabled`; `saveOrganisationSwitch`; warm-up |
| `app/Sources/WakilKit/Core/Place.swift`, `Registry/Journal.swift`, `Registry/ActionRegistry.swift` | `DispatchCaller.via`, journalled; `descriptor(named:)` |
| `app/Sources/WakilKit/App/FastPath.swift` (new) | allowed list, scope, prompt, checks, route |
| `app/Sources/WakilKit/App/WindowModel+FastPath.swift` (new) | scope gathering, `runFastPath`, receipt wording |
| `app/Sources/WakilKit/App/ComposerModel.swift` | ask the fast path first; receipt state; *Ask the agent instead* |
| `app/Sources/WakilApp/ComposerBar.swift` | the receipt line |
| `app/Sources/WakilApp/SettingsPane.swift`, `QuickTaskSettingsForms.swift`, `EditorSettingsForms.swift`, `Canvas.swift` | QUICK TASKS rows; checkboxes and Editor row removed; wiring |
| `docs/wakil/decisions.md`, `PRODUCT.md`, `docs/wakil/phase-3b-ix-acceptance.md`, the spec | charter changes, runbook |

---

### Task 1: Go — per-org `ghostText` and `fastPath`

**Files:**
- Modify: `internal/wakilcore/org.go:18-43` (struct), `internal/wakilcore/orgupdate.go:15-47`
- Modify: `internal/wakilcore/configtree.go:14-21` (`ConfigTreeOrg`), `:180-200` (`LoadConfigTreeFor`)
- Modify: `cmd/wakil-ctx/main.go:147-157` (`updateOrgArgs`), `:490-498`
- Test: `internal/wakilcore/orgupdate_test.go`, `internal/wakilcore/localprovider_test.go`

**Interfaces:**
- Produces: `Org.GhostText *bool` (`json:"ghostText,omitempty"`), `Org.FastPath *bool` (`json:"fastPath,omitempty"`); `OrgPatch.GhostText *bool`, `OrgPatch.FastPath *bool`; `ConfigTreeOrg.GhostText bool` (`json:"ghostText"`), `ConfigTreeOrg.FastPath bool` (`json:"fastPath"`), always present and resolved; `update_org` params `ghostText`, `fastPath` (booleans).

- [ ] **Step 1: Write the failing tests** (append to `orgupdate_test.go`)

```go
func TestUpdateOrgSetsTheQuickTaskSwitches(t *testing.T) {
	localOrg(t)
	on, off := true, false
	if err := UpdateOrg("initech", OrgPatch{GhostText: &off, FastPath: &on}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if o.GhostText == nil || *o.GhostText || o.FastPath == nil || !*o.FastPath {
		t.Fatalf("ghostText=%v fastPath=%v", o.GhostText, o.FastPath)
	}
}

func TestConfigTreeResolvesTheQuickTaskSwitches(t *testing.T) {
	localOrg(t)
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	// Nothing set: ghost-text on, fast path off (no local quick provider).
	if !tree.Org.GhostText || tree.Org.FastPath {
		t.Fatalf("defaults: ghostText=%v fastPath=%v", tree.Org.GhostText, tree.Org.FastPath)
	}
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	q := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &q}); err != nil {
		t.Fatal(err)
	}
	tree, _ = LoadConfigTreeFor("initech")
	if !tree.Org.FastPath {
		t.Fatal("a local quick provider should turn the fast path on by default")
	}
	off := false
	_ = UpdateOrg("initech", OrgPatch{FastPath: &off})
	tree, _ = LoadConfigTreeFor("initech")
	if tree.Org.FastPath {
		t.Fatal("the org's own value must win over the default")
	}
}

func TestConfigTreeGhostTextFallsBackToTheAppSetting(t *testing.T) {
	localOrg(t)
	off := false
	if err := SaveAppSettings(AppSettings{Editor: EditorAppSettings{GhostText: &off}}); err != nil {
		t.Fatal(err)
	}
	tree, _ := LoadConfigTreeFor("initech")
	if tree.Org.GhostText {
		t.Fatal("an operator who turned ghost-text off app-wide keeps it off")
	}
}
```

(If the app-settings writer is not named `SaveAppSettings`, use the existing writer in `editorsettings.go`; grep `func .*AppSettings` and adjust the call only.)

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore -run 'QuickTaskSwitches|GhostTextFallsBack'`
Expected: compile failure — `OrgPatch` has no field `GhostText`.

- [ ] **Step 3: Implement**

`org.go`, in `Org` after `QuickProvider`:

```go
	// GhostText and FastPath switch the org's quick tasks (3b-ix, Decision 42 amended). Nil is
	// the default, resolved on config_tree: ghost-text falls back to the app-wide setting, then
	// on; the fast path is on when QuickProvider names a local provider.
	GhostText *bool `json:"ghostText,omitempty"`
	FastPath  *bool `json:"fastPath,omitempty"`
```

`orgupdate.go`: add `GhostText *bool` and `FastPath *bool` to `OrgPatch`; add both to `isEmpty()`; in `apply`:

```go
	if p.GhostText != nil {
		v := *p.GhostText
		o.GhostText = &v
	}
	if p.FastPath != nil {
		v := *p.FastPath
		o.FastPath = &v
	}
```

`configtree.go`: add to `ConfigTreeOrg`:

```go
	GhostText bool `json:"ghostText"`
	FastPath  bool `json:"fastPath"`
```

and in `LoadConfigTreeFor`, after the org fields are copied (the app settings are already read for `tree.Editor`; reuse that value):

```go
	tree.Org.GhostText = resolveOrgSwitch(o.GhostText, app.Editor.Resolved().GhostText)
	tree.Org.FastPath = resolveOrgSwitch(o.FastPath, quickProviderIsLocal(org, o.QuickProvider))
```

with, in `configtree.go`:

```go
// resolveOrgSwitch is an org switch's value: the org's own, else the default it falls back to.
func resolveOrgSwitch(own *bool, fallback bool) bool {
	if own != nil {
		return *own
	}
	return fallback
}

// quickProviderIsLocal reports whether the org's quick provider is a local endpoint: the fast
// path's default (3b-ix), because over Claude every line would wait for it first.
func quickProviderIsLocal(org, id string) bool {
	if id == "" {
		return false
	}
	p, err := LoadProviderFor(org, id)
	return err == nil && p.Kind == ProviderKindLocal
}
```

`cmd/wakil-ctx/main.go`: add to `updateOrgArgs`:

```go
	GhostText *bool `json:"ghostText,omitempty" jsonschema:"ghost-text on or off for this organisation"`
	FastPath  *bool `json:"fastPath,omitempty" jsonschema:"the composer's fast path on or off for this organisation"`
```

(match the existing tag style on that struct) and pass `GhostText: a.GhostText, FastPath: a.FastPath` into the `OrgPatch` at 492-498.

- [ ] **Step 4: Run the Go tests**

Run: `go test ./internal/wakilcore ./cmd/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore cmd/wakil-ctx
git commit -m "wakilcore: per-org ghostText and fastPath switches, resolved on config_tree"
```

---

### Task 2: Go — a local provider serves both operations

**Files:**
- Modify: `internal/wakilcore/localprovider.go:20-60`, `internal/wakilcore/provider.go` (the `AddProvider` `errLocalOnly` branches), `cmd/wakil-ctx/main.go:196-200, 624-631`
- Test: `internal/wakilcore/localprovider_test.go`

**Interfaces:**
- Produces: `resolvedServes(p)` returns `[infill, respond]` for `local` and `claude-code`; `SetLocalProvider` writes no `serves`; `set_local_provider` ignores a `serves` param.

- [ ] **Step 1: Write the failing test** (and update the two existing ones that assert `[infill]`)

```go
func TestALocalProviderServesBothOperations(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012", Serves: []string{"infill"}}); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".wakil", "orgs", "initech", "providers", "qwen.json"))
	if strings.Contains(string(raw), "serves") {
		t.Fatalf("serves is retired and must not be written: %s", raw)
	}
	tree, _ := LoadConfigTreeFor("initech")
	for _, p := range tree.Providers {
		if p.ID == "qwen" && strings.Join(p.Serves, ",") != "infill,respond" {
			t.Fatalf("serves = %v", p.Serves)
		}
	}
}
```

In `TestSetLocalProviderWritesURLAndDefaultServes` and `TestConfigTreeResolvesServes`, change every expected `[infill]` for a local provider to `[infill respond]`, and rename the first to `TestSetLocalProviderWritesURL`.

- [ ] **Step 2: Run to see it fail**

Run: `go test ./internal/wakilcore -run 'LocalProvider|ResolvesServes'`
Expected: FAIL — `serves` written / `[infill]`.

- [ ] **Step 3: Implement**

In `normaliseLocal`, replace the `serves` validation with dropping it:

```go
	// 3b-ix: one model per org does every quick task, so a local provider serves both
	// operations. A record that still carries serves loads; the field is dropped on write.
	p.Serves = nil
```

In `resolvedServes`, return `[]string{QuickOpInfill, QuickOpRespond}` for `ProviderKindLocal` as for `ProviderKindClaudeCode`. In `AddProvider`, a `--kind local` with `Serves` set no longer errors (drop `Serves` silently); `errLocalOnly` stays for `BaseURL` on a non-local kind. In `cmd/wakil-ctx/main.go`, keep the `Serves` field on `setLocalProviderArgs` so old callers parse, change its schema text to `"ignored since 3b-ix: a local provider serves every quick task"`, and stop passing it to `Provider`.

- [ ] **Step 4: Run the Go tests**

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore cmd/wakil-ctx
git commit -m "wakilcore: a local provider serves every quick task; serves retired"
```

---

### Task 3: WakilKit — org switches drive quick tasks

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift:169-210` (`SettingsOrg`)
- Modify: `app/Sources/WakilKit/App/WindowModel+QuickTasks.swift:10-47, 124-140`, `app/Sources/WakilKit/App/WindowModel.swift:424` (add `fastPathEnabled` beside `ghostTextEnabled`)
- Test: `app/Tests/WakilKitTests/WindowModelQuickTasksTests.swift`, `app/Tests/WakilKitTests/QuickTaskSettingsTests.swift`

**Interfaces:**
- Produces: `SettingsOrg.ghostText: Bool` (decoded, default `true`), `SettingsOrg.fastPath: Bool` (default `false`); `WindowModel.fastPathEnabled: Bool` (`public internal(set)`); `WindowModel.OrganisationSwitch` enum `{ ghostText, fastPath }`; `func saveOrganisationSwitch(_ s: OrganisationSwitch, on: Bool) async -> String?`; `setLocalProvider(id:label:baseURL:)` (the `serves:` parameter removed).

- [ ] **Step 1: Write the failing tests** (in `WindowModelQuickTasksTests`, using its `makeWindow(tree:providerId:factory:)`)

```swift
@Test func theOrgSwitchesDriveGhostTextAndTheFastPath() async {
    var tree = SettingsTree(org: SettingsOrg(id: "acme", quickProvider: "qwen"), providers: [
        SettingsProvider(id: "qwen", kind: "local", baseURL: "http://127.0.0.1:8012", serves: ["infill", "respond"]),
    ])
    tree.org.ghostText = false
    tree.org.fastPath = true
    let window = makeWindow(tree: tree, providerId: "qwen", factory: { _, _ in FakeQuickModel() })
    await window.rebuildQuickTasks()
    #expect(window.ghostTextEnabled == false)
    #expect(window.fastPathEnabled == true)
}

@Test func savingASwitchDispatchesUpdateOrgWithABoolean() async {
    let backend = QuickBackend()
    let window = makeSettingsWindow(backend: backend, factory: { _, _ in FakeQuickModel() })
    let refusal = await window.saveOrganisationSwitch(.fastPath, on: true)
    #expect(refusal == nil)
    #expect(backend.lastUpdateOrg?["fastPath"] == .bool(true))
}
```

(`FakeQuickModel` is the file's existing fake; if it is named differently, use that name. Add `lastUpdateOrg: [String: JSONValue]?` to `QuickBackend`'s `update_org` case if it does not record params yet.)

In `QuickTaskSettingsTests`, add:

```swift
@Test func anOrgWithoutTheSwitchesDecodesTheirDefaults() throws {
    let json = #"{"id":"acme"}"#.data(using: .utf8)!
    let org = try JSONDecoder().decode(SettingsOrg.self, from: json)
    #expect(org.ghostText == true)
    #expect(org.fastPath == false)
}
```

- [ ] **Step 2: Run to see them fail**

Run: `make app-test` (or `swift test --package-path app --filter 'QuickTasks|QuickTaskSettings'`)
Expected: compile failure — `SettingsOrg` has no member `ghostText`.

- [ ] **Step 3: Implement**

`SettingsOrg`: add `public var ghostText: Bool` and `public var fastPath: Bool`, init params `ghostText: Bool = true, fastPath: Bool = false`, decode with `decodeIfPresent(...) ?? true` / `?? false`, add both to `CodingKeys`.

`rebuildQuickTasks()`: replace `ghostTextEnabled = tree.editor.ghostText` with

```swift
        ghostTextEnabled = tree.org.ghostText
        fastPathEnabled = tree.org.fastPath
```

and set `fastPathEnabled = false` on every early `return` that leaves no quick tasks built. Records keep `serves` from the tree (Go now resolves both for `local`).

`WindowModel.swift` beside `ghostTextEnabled`: `public internal(set) var fastPathEnabled = false`.

New in `WindowModel+QuickTasks.swift`:

```swift
    /// An org's quick-task switch (3b-ix): written with `ctx_update_org`, then re-read and rebuilt.
    public enum OrganisationSwitch: String, Sendable, CaseIterable { case ghostText, fastPath }

    public func saveOrganisationSwitch(_ s: OrganisationSwitch, on: Bool) async -> String? {
        do {
            _ = try await registry.dispatch(
                name: "ctx_update_org",
                params: .object(["id": .string(organization), s.rawValue: .bool(on)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            await refreshSettings()
            return statusDescribingFailure("ctx_update_org", error)
        }
        await refreshSettings()
        await rebuildQuickTasks()
        return nil
    }
```

`setLocalProvider`: drop the `serves` parameter and the `"serves"` key from its params; update its callers (`Canvas.swift:513-515` passes `serves` — leave Canvas to Task 8 but make it compile here by passing through the three remaining arguments).

- [ ] **Step 4: Run the Swift tests**

Run: `make app-test`
Expected: PASS (fix any existing test that called `setLocalProvider(..., serves:)` by dropping the argument).

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "WakilKit: the org's ghostText and fastPath switches drive quick tasks"
```

---

### Task 4: WakilKit — `DispatchCaller.via`, journalled; `descriptor(named:)`

**Files:**
- Modify: `app/Sources/WakilKit/Core/Place.swift:21-29`, `app/Sources/WakilKit/Registry/Journal.swift:40-52`, `app/Sources/WakilKit/Registry/ActionRegistry.swift:189, 597-620`
- Test: `app/Tests/WakilKitTests/ActionRegistryTests.swift`

**Interfaces:**
- Produces: `DispatchCaller.init(place:session:via:)` with `via: String? = nil`; `JournalEntry.via: String?` (`omitempty` in its encoding — nil is not written); `ActionRegistry.descriptor(named: String) -> ActionDescriptor?`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aDispatchTaggedFastPathIsJournalledWithVia() async throws {
    let (registry, journal) = try makeRegistryWithJournal()   // use the file's existing helper for a registry + journal
    registry.register(Action(name: "noop_read", description: "", kind: .read, audience: .agentReachable,
                             schema: .object(["type": .string("object")]), handler: { _ in .object([:]) }))
    _ = try await registry.dispatch(name: "noop_read", params: .object([:]), origin: .ui,
                                    caller: DispatchCaller(place: .window, session: nil, via: "fastPath"),
                                    confirmation: nil)
    let last = try #require(journal.entries().last)
    #expect(last.via == "fastPath")
    #expect(await registry.descriptor(named: "noop_read")?.kind == .read)
    #expect(await registry.descriptor(named: "nope") == nil)
}
```

(Match the file's existing way of building a registry with a journal and a `Place`; the names above are placeholders for those two helpers only.)

- [ ] **Step 2: Run to see it fail**

Run: `swift test --package-path app --filter ActionRegistryTests`
Expected: compile failure — extra argument `via`.

- [ ] **Step 3: Implement**

`DispatchCaller`: `public let via: String?`; `public init(place: Place, session: String?, via: String? = nil)`.
`JournalEntry`: `public let via: String?`, encoded with `encodeIfPresent`; decoded with `decodeIfPresent` so old journals read.
`appendJournalEntry(...)`: pass `via: caller.via` into the entry.
`ActionRegistry`:

```swift
    /// One action's descriptor by name, or nil (3b-ix: the fast path checks params against it).
    public func descriptor(named name: String) -> ActionDescriptor? {
        all().first { $0.name == name }
    }
```

- [ ] **Step 4: Run the Swift tests**

Run: `make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "WakilKit: a dispatch can say how it came (via), and the journal keeps it"
```

---

### Task 5: WakilKit — `FastPath`: allowed list, prompt, checks, route

**Files:**
- Create: `app/Sources/WakilKit/App/FastPath.swift`
- Test: `app/Tests/WakilKitTests/FastPathTests.swift`

**Interfaces:**
- Consumes: `RespondRequest(instructions:input:jsonSchema:maxTokens:)`; `ActionDescriptor.schema`.
- Produces:

```swift
public struct FastPathScope: Sendable, Equatable {
    public var files: [String]          // absolute paths, at most 20, best match first
    public var roots: [String]          // the active project's roots (for editor_changes_select)
    public var projects: [String]
    public var environments: [String]
    public var activeEnvironment: String
    public var tables: [String]
    public var panes: [FastPathPane]    // id, kind, title
    public var apiEntries: [String]
}
public struct FastPathPane: Sendable, Equatable, Codable { public var id, kind, title: String }
public enum FastPathRoute: Sendable, Equatable { case action(name: String, params: JSONValue), agent }
public enum FastPath {
    public static let allowed: [String: FastPathAction]           // the 26
    public static func instructions(actions: [String: JSONValue]) -> String   // rules + list + examples; stable
    public static func input(_ line: String, scope: FastPathScope) -> String  // scope JSON + the line
    public static let replySchema: String                          // {"action": enum, "params": object}
    public static func check(reply: String, scope: FastPathScope, schemas: [String: JSONValue]) -> FastPathRoute
    public static func route(_ line: String, scope: FastPathScope, schemas: [String: JSONValue],
                             deadline: Duration,
                             respond: @Sendable (RespondRequest) async throws -> String) async -> FastPathRoute
}
public struct FastPathAction: Sendable { public var params: [String: FastPathParam] }
public enum FastPathParam: Sendable { case file, project, environment, table, pane, apiEntry, root, free }
```

- [ ] **Step 1: Write the failing tests** (`FastPathTests.swift`)

```swift
import Testing
import Foundation
@testable import WakilKit

private let scope = FastPathScope(
    files: ["/p/api/confirm.go", "/p/web/Login.tsx"], roots: ["/p"], projects: ["rafiq", "wakil"],
    environments: ["staging", "qa", "production"], activeEnvironment: "qa",
    tables: ["bookings", "users"],
    panes: [FastPathPane(id: "editor-1", kind: "editor", title: "confirm.go"),
            FastPathPane(id: "db-1", kind: "db", title: "bookings")],
    apiEntries: ["billing"])

private let schemas: [String: JSONValue] = [
    "ctx_set_environment": .object(["type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]), "required": .array([.string("name")])]),
    "editor_goto": .object(["type": .string("object"),
        "properties": .object(["line": .object(["type": .string("integer")])]), "required": .array([.string("line")])]),
    "editor_open": .object(["type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")]), "line": .object(["type": .string("integer")])])]),
    "pane_close": .object(["type": .string("object"),
        "properties": .object(["id": .object(["type": .string("string")]), "discard": .object(["type": .string("boolean")])]),
        "required": .array([.string("id")])]),
    "editor_changes_select": .object(["type": .string("object"),
        "properties": .object(["root": .object(["type": .string("string")]), "path": .object(["type": .string("string")]),
                               "group": .object(["type": .string("string")])]),
        "required": .array([.string("root"), .string("path"), .string("group")])]),
]

@Test func aValidReplyRunsItsAction() {
    let r = FastPath.check(reply: #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#, scope: scope, schemas: schemas)
    #expect(r == .action(name: "ctx_set_environment", params: .object(["name": .string("staging")])))
}

@Test func agentAndEveryFailedCheckGoToTheAgent() {
    for reply in [
        #"{"action":"agent","params":{}}"#,
        #"not json"#,
        #"{"action":"db_run_mutation","params":{}}"#,                      // not on the list
        #"{"action":"ctx_set_environment","params":{}}"#,                   // required param missing
        #"{"action":"ctx_set_environment","params":{"name":"prod"}}"#,      // not in scope
        #"{"action":"editor_open","params":{"path":"/p/api/orders.go"}}"#,  // invented file
        #"{"action":"editor_goto","params":{"line":"twelve"}}"#,           // wrong type
    ] {
        #expect(FastPath.check(reply: reply, scope: scope, schemas: schemas) == .agent, "\(reply)")
    }
}

@Test func aNumberSentAsAStringIsConverted() {
    let r = FastPath.check(reply: #"{"action":"editor_goto","params":{"line":"120"}}"#, scope: scope, schemas: schemas)
    #expect(r == .action(name: "editor_goto", params: .object(["line": .integer(120)])))
}

@Test func discardAndParamsOffTheListAreDropped() {
    let r = FastPath.check(reply: #"{"action":"pane_close","params":{"id":"db-1","discard":true,"extra":1}}"#,
                           scope: scope, schemas: schemas)
    #expect(r == .action(name: "pane_close", params: .object(["id": .string("db-1")])))
}

@Test func aChangesSelectPathBecomesRootRelativeAndChanged() {
    let r = FastPath.check(reply: #"{"action":"editor_changes_select","params":{"path":"/p/api/confirm.go"}}"#,
                           scope: scope, schemas: schemas)
    #expect(r == .action(name: "editor_changes_select", params: .object([
        "root": .string("/p"), "path": .string("api/confirm.go"), "group": .string("changed")])))
}

@Test func aLateAnswerGoesToTheAgent() async {
    let r = await FastPath.route("switch to staging", scope: scope, schemas: schemas, deadline: .milliseconds(50)) { _ in
        try await Task.sleep(for: .milliseconds(500))
        return #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#
    }
    #expect(r == .agent)
}

@Test func aModelErrorGoesToTheAgent() async {
    let r = await FastPath.route("switch to staging", scope: scope, schemas: schemas, deadline: .seconds(1)) { _ in
        throw QuickModelError.unreachable("down")
    }
    #expect(r == .agent)
}

@Test func theInstructionsDoNotDependOnTheLineOrTheScope() {
    // The prompt cache holds them: everything that varies goes in `input`.
    let a = FastPath.instructions(actions: schemas)
    #expect(a == FastPath.instructions(actions: schemas))
    #expect(!a.contains("staging"))
    #expect(FastPath.input("switch to staging", scope: scope).contains("staging"))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path app --filter FastPathTests`
Expected: compile failure — `FastPathScope` not found.

- [ ] **Step 3: Implement `FastPath.swift`**

```swift
import Foundation

/// The composer's fast path (3b-ix, Decision 10 amended): a line that asks for exactly one
/// navigation action runs it without an agent turn. The model proposes; this checks.
public struct FastPathPane: Sendable, Equatable, Codable {
    public var id: String
    public var kind: String
    public var title: String
    public init(id: String, kind: String, title: String) { self.id = id; self.kind = kind; self.title = title }
}

public struct FastPathScope: Sendable, Equatable {
    public var files: [String]
    public var roots: [String]
    public var projects: [String]
    public var environments: [String]
    public var activeEnvironment: String
    public var tables: [String]
    public var panes: [FastPathPane]
    public var apiEntries: [String]
    public init(files: [String] = [], roots: [String] = [], projects: [String] = [], environments: [String] = [],
                activeEnvironment: String = "", tables: [String] = [], panes: [FastPathPane] = [],
                apiEntries: [String] = []) {
        self.files = files; self.roots = roots; self.projects = projects; self.environments = environments
        self.activeEnvironment = activeEnvironment; self.tables = tables; self.panes = panes
        self.apiEntries = apiEntries
    }
}

public enum FastPathRoute: Sendable, Equatable {
    case action(name: String, params: JSONValue)
    case agent
}

/// What a param must name: something in scope, or anything (`free`: a search query, a line).
public enum FastPathParam: Sendable { case file, project, environment, table, pane, apiEntry, free }

public struct FastPathAction: Sendable {
    public var params: [String: FastPathParam]
    public init(_ params: [String: FastPathParam]) { self.params = params }
}

public enum FastPath {
    /// The 26 navigation actions and the params the model may set (spec §The allowed list).
    /// Every other param — `discard` first — is dropped before dispatch.
    public static let allowed: [String: FastPathAction] = [
        "editor_open": .init(["path": .file, "line": .free]),
        "editor_goto": .init(["line": .free, "column": .free]),
        "editor_search": .init(["query": .free]),
        "editor_find": .init(["query": .free]),
        "editor_tree_reveal": .init(["path": .file]),
        "editor_new_scratch": .init(["language": .free]),
        "editor_close": .init(["path": .file]),
        "editor_focus_tab": .init(["index": .free]),
        "editor_changes_select": .init(["path": .file]),       // R4: root and group are derived
        "editor_set_language": .init(["language": .free]),
        "ctx_set_environment": .init(["name": .environment]),
        "ctx_set_project": .init(["name": .project]),
        "db_read_table": .init(["table": .table]),
        "db_describe_table": .init(["table": .table]),
        "db_list_tables": .init([:]),
        "db_page": .init(["pane": .pane, "to": .free]),
        "db_refetch": .init(["pane": .pane]),
        "pane_open": .init(["kind": .free]),
        "pane_focus": .init(["id": .pane]),
        "pane_close": .init(["id": .pane]),
        "pane_maximize": .init(["id": .pane]),
        "pane_restore": .init([:]),
        "pane_sort": .init(["pane": .pane, "column": .free, "direction": .free]),
        "term_open": .init(["path": .free]),
        "api_open": .init(["entry": .apiEntry]),
        "settings_open": .init([:]),
    ]

    public static let replySchema: String = {
        let names = (allowed.keys.sorted() + ["agent"]).map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"object","properties":{"action":{"type":"string","enum":["# + names
            + #"]},"params":{"type":"object"}},"required":["action","params"]}"#
    }()

    /// Rules, the action list and worked examples: stable for a window, so a server's prompt cache
    /// holds them (measured: worked examples took the 1.5B from 10 to 14 of 16).
    public static func instructions(actions schemas: [String: JSONValue]) -> String {
        let list = allowed.keys.sorted().map { name -> String in
            let params = allowed[name]!.params.keys.sorted().joined(separator: ", ")
            return "- \(name)(\(params))"
        }.joined(separator: "\n")
        return """
        You route one line an operator typed in a developer tool. If the line asks for exactly ONE \
        of the actions below and every name it needs is in SCOPE, answer with that action and its \
        params. Otherwise answer {"action": "agent", "params": {}}. A question, a change, a fix or \
        a delete is ALWAYS agent, even when it names a file or a table. Never invent a path, table, \
        pane id, project or environment: copy them exactly from SCOPE.

        ACTIONS:
        \(list)

        EXAMPLES (line -> answer):
        - "go to qa" -> {"action": "ctx_set_environment", "params": {"name": "qa"}}
        - "show payments" -> {"action": "db_read_table", "params": {"table": "payments"}}
        - "what columns does invoices have" -> {"action": "db_describe_table", "params": {"table": "invoices"}}
        - "close the terminal" -> {"action": "pane_close", "params": {"id": "terminal-1"}}
        - "line 40" -> {"action": "editor_goto", "params": {"line": 40}}
        - "how does refund work?" -> {"action": "agent", "params": {}}
        - "rename Confirm to Accept" -> {"action": "agent", "params": {}}
        - "drop the old refunds" -> {"action": "agent", "params": {}}
        - "open checkout.go" (not in SCOPE) -> {"action": "agent", "params": {}}
        """
    }

    public static func input(_ line: String, scope: FastPathScope) -> String {
        struct Wire: Encodable {
            let files: [String]; let projects: [String]; let environments: [String]
            let active_environment: String; let tables: [String]; let open_panes: [FastPathPane]
            let api_entries: [String]
        }
        let wire = Wire(files: scope.files, projects: scope.projects, environments: scope.environments,
                        active_environment: scope.activeEnvironment, tables: scope.tables,
                        open_panes: scope.panes, api_entries: scope.apiEntries)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(wire)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "SCOPE: \(json)\nLINE: \(line)"
    }

    /// The checks, in order; the first that fails answers `.agent`.
    public static func check(reply: String, scope: FastPathScope, schemas: [String: JSONValue]) -> FastPathRoute {
        guard let data = reply.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let top) = value,
              case .string(let name)? = top["action"] else { return .agent }
        guard name != "agent", let action = allowed[name], let schema = schemas[name] else { return .agent }
        let given: [String: JSONValue]
        if case .object(let p)? = top["params"] { given = p } else { given = [:] }

        var params: [String: JSONValue] = [:]
        for (key, kind) in action.params {
            guard let raw = given[key] else { continue }
            guard let typed = conform(raw, to: propertyType(schema, key)) else { return .agent }
            guard inScope(typed, kind, scope) else { return .agent }
            params[key] = typed
        }
        if name == "editor_changes_select" {
            guard case .string(let path)? = params["path"],
                  let root = scope.roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
            else { return .agent }
            params = ["root": .string(root), "path": .string(String(path.dropFirst(root.count + 1))),
                      "group": .string("changed")]
        }
        for key in required(schema) where params[key] == nil { return .agent }
        return .action(name: name, params: .object(params))
    }

    public static func route(_ line: String, scope: FastPathScope, schemas: [String: JSONValue],
                             deadline: Duration,
                             respond: @escaping @Sendable (RespondRequest) async throws -> String) async -> FastPathRoute {
        let request = RespondRequest(instructions: instructions(actions: schemas), input: input(line, scope: scope),
                                     jsonSchema: replySchema, maxTokens: 80)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await respond(request) }
            group.addTask { try? await Task.sleep(for: deadline); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply else { return .agent }
        return check(reply: reply, scope: scope, schemas: schemas)
    }

    // MARK: - Checks

    private static func propertyType(_ schema: JSONValue, _ key: String) -> String? {
        guard case .object(let s) = schema, case .object(let props)? = s["properties"],
              case .object(let p)? = props[key], case .string(let t)? = p["type"] else { return nil }
        return t
    }

    private static func required(_ schema: JSONValue) -> [String] {
        guard case .object(let s) = schema, case .array(let r)? = s["required"] else { return [] }
        return r.compactMap { if case .string(let k) = $0 { return k } else { return nil } }
    }

    /// The value as the schema's type, converting a string of digits for a number (R3), or nil.
    private static func conform(_ v: JSONValue, to type: String?) -> JSONValue? {
        switch (type, v) {
        case (nil, _): return v
        case ("string", .string): return v
        case ("integer", .integer), ("number", .integer), ("number", .number): return v
        case ("integer", .number(let n)) where n.rounded() == n: return .integer(Int64(n))
        case ("integer", .string(let s)):
            guard let n = Int64(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .integer(n)
        case ("number", .string(let s)):
            guard let n = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return .number(n)
        case ("boolean", .bool): return v
        default: return nil
        }
    }

    private static func inScope(_ v: JSONValue, _ kind: FastPathParam, _ scope: FastPathScope) -> Bool {
        guard kind != .free else { return true }
        guard case .string(let s) = v else { return false }
        switch kind {
        case .file: return scope.files.contains(s)
        case .project: return scope.projects.contains(s)
        case .environment: return scope.environments.contains(s)
        case .table: return scope.tables.contains(s)
        case .pane: return scope.panes.contains { $0.id == s }
        case .apiEntry: return scope.apiEntries.contains(s)
        case .free: return true
        }
    }
}
```

(`JSONValue` holds whole numbers as `.integer(Int64)` and others as `.number(Double)`; `conform` produces the case the schema's type names.)

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path app --filter FastPathTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/FastPath.swift app/Tests/WakilKitTests/FastPathTests.swift
git commit -m "WakilKit: FastPath — the allowed list, the prompt, and the checks"
```

---

### Task 6: WakilKit — the allowed list is pinned to the registry; scope gathering

**Files:**
- Create: `app/Sources/WakilKit/App/WindowModel+FastPath.swift`
- Test: `app/Tests/WakilKitTests/FastPathTests.swift` (pin test), `app/Tests/WakilKitTests/WindowModelFastPathTests.swift` (new)

**Interfaces:**
- Consumes: `FastPath.allowed`, `ActionRegistry.descriptor(named:)`, `PaletteSearch.rank(_:query:)`, `FilesSource` entries (as `WindowModel.paletteOpenSources` builds them, WindowModel.swift:5657-5671), `layoutSnapshot.panes`, `listProjects()`, `settings?.projects[].environments[]`, `apiListing(http:)`, `vocabulary?.current().names` (`Identifier.kind == .table`).
- Produces: `func fastPathScope(for line: String) async -> FastPathScope`; `func fastPathSchemas() async -> [String: JSONValue]`.

- [ ] **Step 1: Write the failing tests**

Pin test (in `FastPathTests.swift`), building the real registry the way `WindowModelQuickTasksTests.makeSettingsWindow` does (`registerStandardActions` plus the editor, terminal, layout and api registrations that file or `AppWiring` uses):

```swift
@Test func everyAllowedActionExistsIsNotAMutationAndTakesItsParams() async throws {
    let registry = try await makeFullRegistry()   // the existing helper that registers every action; add one if absent
    for (name, action) in FastPath.allowed {
        let d = try #require(await registry.descriptor(named: name), "\(name) is not registered")
        #expect(d.kind != .mutate, "\(name) is a mutation")
        guard case .object(let s) = d.schema, case .object(let props)? = s["properties"] else { continue }
        for key in action.params.keys where name != "editor_changes_select" {
            #expect(props[key] != nil, "\(name) has no param \(key)")
        }
    }
    #expect(FastPath.allowed.count == 26)
}
```

Scope test (`WindowModelFastPathTests.swift`), with a window whose file source answers 30 files and whose layout has two panes:

```swift
@Test @MainActor func theScopeHoldsTheTopTwentyFilesAndEveryPane() async {
    let window = makeFastPathWindow(files: (1...30).map { "/p/src/file\($0).go" } + ["/p/api/confirm.go"],
                                    panes: [("editor-1", "editor", "confirm.go"), ("db-1", "db", "bookings")])
    let scope = await window.fastPathScope(for: "open confirm.go")
    #expect(scope.files.count == 20)
    #expect(scope.files.first == "/p/api/confirm.go")
    #expect(scope.panes.map(\.id) == ["editor-1", "db-1"])
}
```

(`makeFastPathWindow` is a new private helper in that file built on the existing `makeWindow` helpers, injecting the files through the same seam `PaletteFilesSourceTests` uses for `files_list`.)

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path app --filter 'FastPath'`
Expected: compile failure — `fastPathScope` not found.

- [ ] **Step 3: Implement `WindowModel+FastPath.swift`**

```swift
import Foundation

extension WindowModel {
    /// What the fast path's model may name for `line` (spec §The prompt and the scope): the top 20
    /// file matches by ⌘P's matcher, and every project, environment, table, open pane and api entry.
    public func fastPathScope(for line: String) async -> FastPathScope {
        let files = await fastPathFileEntries()
        let ranked = PaletteSearch.rank(files, query: line).prefix(20).compactMap { entry -> String? in
            if case .openInEditor(let path) = entry.action { return path } else { return nil }
        }
        let environments = settings?.projects.first { $0.name == project }?.environments.map(\.name) ?? []
        let tables = await vocabulary?.current().names.filter { $0.kind == .table }.map(\.text) ?? []
        return FastPathScope(
            files: Array(ranked), roots: rootPaths, projects: await listProjects().map(\.name),
            environments: environments, activeEnvironment: environment,
            tables: Array(NSOrderedSet(array: tables)) as? [String] ?? tables,
            panes: layoutSnapshot.panes.map { FastPathPane(id: $0.id, kind: $0.kind, title: $0.title) },
            apiEntries: (await apiEntryNames()) ?? [])
    }

    /// The registry schema of each allowed action.
    public func fastPathSchemas() async -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for name in FastPath.allowed.keys {
            if let d = await registry.descriptor(named: name) { out[name] = d.schema }
        }
        return out
    }
}
```

`fastPathFileEntries()` returns the `FilesSource` entries built exactly as `paletteOpenSources` builds them (WindowModel.swift:5668-5671) — extract that construction into a private helper both call, rather than copying it. `apiEntryNames()` reads `apiListing(http:)` (ApiActions.swift:237) through the window's http client and maps `\.name`. `rootPaths` is the active project's roots (use the property the window already exposes for them; `activeContext?.rootPaths`).

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS. If the pin test names a param the registry lacks, fix `FastPath.allowed` to the registry's name (the registry is the authority) and note it in the commit.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "WakilKit: the fast path's scope, and its allowed list pinned to the registry"
```

---

### Task 7: WakilKit — the composer asks the fast path first

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel+FastPath.swift`, `app/Sources/WakilKit/App/ComposerModel.swift:9-84`, `app/Sources/WakilKit/App/WindowModel+QuickTasks.swift` (warm-up)
- Test: `app/Tests/WakilKitTests/ComposerModelTests.swift`, `app/Tests/WakilKitTests/WindowModelFastPathTests.swift`

**Interfaces:**
- Produces:

```swift
public struct FastPathReceipt: Sendable, Equatable {
    public var line: String        // the operator's words, for Ask the agent instead
    public var text: String        // "Ran: switch environment to staging" or the refusal, whole
    public var refused: Bool
}
// WindowModel
public enum FastPathOutcome: Sendable, Equatable { case ran(FastPathReceipt), refused(FastPathReceipt), toAgent }
public func runFastPath(_ line: String) async -> FastPathOutcome
public static func fastPathReceiptText(action: String, params: JSONValue) -> String
// ComposerModel
public private(set) var receipt: FastPathReceipt?
public func askAgentInstead() async
public func dismissReceipt()
```

- [ ] **Step 1: Write the failing tests**

In `WindowModelFastPathTests.swift` (fake quick model answering canned replies through `QuickTasks.respond`; a registry with a recording `ctx_set_environment` and an `editor_close` that throws "unsaved"):

```swift
@Test @MainActor func aLineTheModelRoutesRunsAsTheOperatorAndSaysSo() async {
    let (window, recorder) = makeFastPathWindow(reply: #"{"action":"ctx_set_environment","params":{"name":"staging"}}"#)
    let outcome = await window.runFastPath("switch to staging")
    #expect(outcome == .ran(FastPathReceipt(line: "switch to staging", text: "Ran: switch environment to staging", refused: false)))
    #expect(recorder.calls.last?.name == "ctx_set_environment")
    #expect(recorder.calls.last?.origin == .ui)
    #expect(recorder.calls.last?.via == "fastPath")
}

@Test @MainActor func aRefusedActionKeepsTheLineAndShowsTheRefusalWhole() async {
    let (window, _) = makeFastPathWindow(reply: #"{"action":"editor_close","params":{"path":"/p/api/confirm.go"}}"#)
    let outcome = await window.runFastPath("close confirm.go")
    guard case .refused(let r) = outcome else { Issue.record("\(outcome)"); return }
    #expect(r.line == "close confirm.go")
    #expect(r.text.contains("unsaved"))
}

@Test @MainActor func fastPathOffOrNoQuickTasksGoesToTheAgent() async {
    let (window, recorder) = makeFastPathWindow(reply: #"{"action":"settings_open","params":{}}"#, fastPath: false)
    #expect(await window.runFastPath("open settings") == .toAgent)
    #expect(recorder.calls.isEmpty)
}

@Test @MainActor func anAnswerThatLandsAfterAnOrgSwitchIsDropped() async {
    let (window, recorder) = makeFastPathWindow(reply: #"{"action":"settings_open","params":{}}"#, delay: .milliseconds(100))
    async let outcome = window.runFastPath("open settings")
    window.quickTasksGeneration += 1      // what rebuildQuickTasks does on an org switch
    #expect(await outcome == .toAgent)
    #expect(recorder.calls.isEmpty)
}

@Test @MainActor func aPaneParamOfTheWrongKindShowsTheHandlersRefusal() async {
    let (window, _) = makeFastPathWindow(reply: #"{"action":"db_page","params":{"pane":"editor-1","to":"next"}}"#)
    guard case .refused = await window.runFastPath("next page") else { Issue.record("not refused"); return }
}

@Test @MainActor func rebuildingWithTheFastPathOnWarmsThePrompt() async {
    let (window, _, model) = makeFastPathWindowWithModel(reply: #"{"action":"agent","params":{}}"#)
    await window.rebuildQuickTasks()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await model.respondCalls >= 1)
}

@Test func receiptTextNamesTheActionInWords() {
    #expect(WindowModel.fastPathReceiptText(action: "editor_open", params: .object(["path": .string("/p/api/confirm.go")]))
            == "Ran: open confirm.go")
    #expect(WindowModel.fastPathReceiptText(action: "pane_restore", params: .object([:])) == "Ran: restore the layout")
}
```

In `ComposerModelTests.swift`, using its helpers:

```swift
@Test @MainActor func aFastPathLineStartsNoTurnAndLeavesAReceipt() async {
    let made = makeComposerWithFastPath(outcome: .ran(FastPathReceipt(line: "switch to staging", text: "Ran: switch environment to staging", refused: false)))
    made.composer.edited(draft: "switch to staging", caret: 17)
    await made.composer.submit()
    #expect(made.harness.sent.isEmpty)
    #expect(made.composer.receipt?.text == "Ran: switch environment to staging")
    #expect(made.composer.draft == "")
}

@Test @MainActor func askTheAgentInsteadSendsTheOriginalLine() async {
    let made = makeComposerWithFastPath(outcome: .ran(FastPathReceipt(line: "switch to staging", text: "Ran: …", refused: false)))
    made.composer.edited(draft: "switch to staging", caret: 17)
    await made.composer.submit()
    await made.composer.askAgentInstead()
    #expect(made.harness.sent == ["switch to staging"])
    #expect(made.composer.receipt == nil)
}

@Test @MainActor func aLineTheFastPathDoesNotTakeIsSentAsToday() async {
    let made = makeComposerWithFastPath(outcome: .toAgent)
    made.composer.edited(draft: "why is it slow?", caret: 15)
    await made.composer.submit()
    #expect(made.harness.sent == ["why is it slow?"])
    #expect(made.composer.receipt == nil)
}
```

(`makeComposerWithFastPath` builds the file's existing `Made` with a window whose `runFastPath` answers `outcome`: inject it through a `fastPathRunner: ((String) async -> FastPathOutcome)?` on `ComposerModel`'s init, defaulting to `window.runFastPath`.)

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path app --filter 'FastPath|ComposerModel'`
Expected: compile failure — `runFastPath` not found.

- [ ] **Step 3: Implement**

In `WindowModel+FastPath.swift`:

```swift
public struct FastPathReceipt: Sendable, Equatable {
    public var line: String
    public var text: String
    public var refused: Bool
    public init(line: String, text: String, refused: Bool) { self.line = line; self.text = text; self.refused = refused }
}

public enum FastPathOutcome: Sendable, Equatable { case ran(FastPathReceipt), refused(FastPathReceipt), toAgent }

extension WindowModel {
    static let fastPathLocalDeadline: Duration = .milliseconds(300)
    static let fastPathSessionDeadline: Duration = .milliseconds(2500)

    /// Asks the org's quick model whether `line` is one allowed action and, if every check holds,
    /// dispatches it as the operator's own click (Invariant 2). Anything else is `.toAgent`.
    public func runFastPath(_ line: String) async -> FastPathOutcome {
        guard fastPathEnabled, let tasks = quickTasks else { return .toAgent }
        let generation = quickTasksGeneration
        let org = organization
        let scope = await fastPathScope(for: line)
        let schemas = await fastPathSchemas()
        let deadline = await tasks.routedKind(.respond) == "local" ? Self.fastPathLocalDeadline : Self.fastPathSessionDeadline
        let route = await FastPath.route(line, scope: scope, schemas: schemas, deadline: deadline) { try await tasks.respond($0) }
        guard generation == quickTasksGeneration, org == organization,
              case .action(let name, let params) = route else { return .toAgent }
        do {
            _ = try await registry.dispatch(name: name, params: params, origin: .ui,
                                            caller: DispatchCaller(place: place, session: nil, via: "fastPath"),
                                            confirmation: nil)
            return .ran(FastPathReceipt(line: line, text: Self.fastPathReceiptText(action: name, params: params), refused: false))
        } catch {
            return .refused(FastPathReceipt(line: line, text: statusDescribingFailure(name, error), refused: true))
        }
    }

    /// The receipt's words for an action and its params.
    public static func fastPathReceiptText(action: String, params: JSONValue) -> String {
        func p(_ k: String) -> String {
            guard case .object(let o) = params, let v = o[k] else { return "" }
            switch v {
            case .string(let s): return s
            case .integer(let n): return String(n)
            case .number(let n): return String(n)
            default: return ""
            }
        }
        let file = (p("path") as NSString).lastPathComponent
        let said: String
        switch action {
        case "editor_open": said = "open \(file)"
        case "editor_goto": said = "go to line \(p("line"))"
        case "editor_search": said = "search for \(p("query"))"
        case "editor_find": said = "find \(p("query"))"
        case "editor_tree_reveal": said = "reveal \(file)"
        case "editor_new_scratch": said = "new scratch tab"
        case "editor_close": said = "close \(file)"
        case "editor_focus_tab": said = "switch tab"
        case "editor_changes_select": said = "show the changes in \(file)"
        case "editor_set_language": said = "set the language to \(p("language"))"
        case "ctx_set_environment": said = "switch environment to \(p("name"))"
        case "ctx_set_project": said = "switch project to \(p("name"))"
        case "db_read_table": said = "show \(p("table"))"
        case "db_describe_table": said = "describe \(p("table"))"
        case "db_list_tables": said = "list the tables"
        case "db_page": said = "page \(p("to"))"
        case "db_refetch": said = "refresh \(p("pane"))"
        case "pane_open": said = "open a \(p("kind")) pane"
        case "pane_focus": said = "focus \(p("id"))"
        case "pane_close": said = "close \(p("id"))"
        case "pane_maximize": said = "maximize \(p("id"))"
        case "pane_restore": said = "restore the layout"
        case "pane_sort": said = "sort by \(p("column"))"
        case "term_open": said = "open a terminal"
        case "api_open": said = "open the \(p("entry")) api"
        case "settings_open": said = "open settings"
        default: said = action
        }
        return "Ran: \(said)"
    }
}
```


Warm-up (R2), at the end of `rebuildQuickTasks()` once `fastPathEnabled` is set:

```swift
        if fastPathEnabled, let tasks = quickTasks {
            let schemas = await fastPathSchemas()
            let warm = RespondRequest(instructions: FastPath.instructions(actions: schemas),
                                      input: FastPath.input("open settings", scope: FastPathScope()),
                                      jsonSchema: FastPath.replySchema, maxTokens: 8)
            Task { _ = try? await tasks.respond(warm) }   // fills the server's prompt cache; the reply is not used
        }
```

`ComposerModel`:
- add `public private(set) var receipt: FastPathReceipt?` and `private let fastPathRunner: (String) async -> FastPathOutcome` (init parameter `fastPathRunner: ((String) async -> FastPathOutcome)? = nil`, defaulting to `{ [window] in await window.runFastPath($0) }`);
- in `submit()`, after the draft is cleared and before `window.send`:

```swift
        receipt = nil
        switch await fastPathRunner(text) {
        case .ran(let r), .refused(let r):
            receipt = r          // Rule 2: a refused line is kept here, with Ask the agent instead
            return
        case .toAgent:
            break
        }
```

- `askAgentInstead()`: `guard let line = receipt?.line else { return }; receipt = nil; _ = await window.send(line, via: .typed)`;
- `dismissReceipt()`: `receipt = nil` (the bar calls it on Esc in an empty composer).

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app
git commit -m "WakilKit: the composer asks the fast path first, and keeps a receipt"
```

---

### Task 8: WakilApp — the receipt and the QUICK TASKS rows

**Files:**
- Modify: `app/Sources/WakilApp/ComposerBar.swift`, `app/Sources/WakilApp/SettingsPane.swift:452-460, 713-843`, `app/Sources/WakilApp/QuickTaskSettingsForms.swift:67-234`, `app/Sources/WakilApp/EditorSettingsForms.swift:177-186`, `app/Sources/WakilApp/Canvas.swift:495-520`

**Interfaces:**
- Consumes: `ComposerModel.receipt`, `askAgentInstead()`, `dismissReceipt()`; `SettingsOrg.ghostText` / `fastPath`; `WindowModel.saveOrganisationSwitch(_:on:)`; `setLocalProvider(id:label:baseURL:)`.
- Produces identifiers: `window.composer.receipt`, `window.composer.askAgent`, `settings.org.ghostText.on|off`, `settings.org.fastPath.on|off`.

WakilApp has no test target; this task is verified by `make build` and the e2e suite (Task 9) and the walk.

- [ ] **Step 1: The receipt** — in `ComposerBar`, under the field and beside the hint row, when `composer.receipt != nil`:

```swift
if let receipt = composer.receipt {
    HStack(spacing: 10) {
        Text(receipt.text)
            .font(.system(size: 11))
            .foregroundStyle(receipt.refused ? SettingsPalette.caution : Color.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)          // Rule 8: whole, wrapped
            .accessibilityIdentifier("window.composer.receipt")
        Button("Ask the agent instead") { Task { await composer.askAgentInstead() } }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.70))
            .accessibilityIdentifier("window.composer.askAgent")
    }
}
```

Esc in an empty composer calls `composer.dismissReceipt()` (wire it where the bar already handles Esc; it must not take Esc from a non-empty draft). Focus stays in the composer (Rule 6): nothing here moves it.

- [ ] **Step 2: QUICK TASKS rows** — in `SettingsPane.quickTasksRow`, keep the Model row (rename its leading label to **Model**), then two rows in the same table style (`Scale.rowHeight`, hairline at the bottom):

```swift
quickTaskSwitchRow("Ghost-text", hint: "suggestions as you type", on: tree.org.ghostText, key: .ghostText)
quickTaskSwitchRow("Fast path", hint: fastPathHint(tree), on: tree.org.fastPath, key: .fastPath)
```

with `quickTaskSwitchRow` drawing a `SegmentedChoice(options: ["Off", "On"], …)` whose identifiers are `settings.org.<key>.off|on`, calling a new `saveOrganisationSwitch: (WindowModel.OrganisationSwitch, Bool) async -> String?` closure, then `quickStatus = await quickTaskStatus()`, and showing a refusal whole under it. `fastPathHint`: *one-line commands without the agent*, plus, when the org has not set it, *· on: the model is local* or *· off: on Same as agent each line would wait for Claude first*. (Whether the org set it is not on the wire; draw the default reason only when the value equals the default for the current model — good enough for a hint, and Rule 9 holds since either can be chosen.)

- [ ] **Step 3: Remove the checkboxes** — in `LocalProviderRow`, delete the `serveToggle` HStack and `serveToggle(_:_:identifier:)`, the `ticked` state and its `onChange`, and pass no `serves` into `save`; `save`'s closure type becomes `(String, String, String) async -> String?`. Update `LocalProvidersSection` and `SettingsPane.saveLocalProvider` to the 3-argument form.

- [ ] **Step 4: Remove the Editor Ghost-text row** — delete lines 177-186 of `EditorSettingsForms.swift` (the `ChoiceSettingRow` for ghost-text).

- [ ] **Step 5: Wiring** — in `Canvas.swift` pass `saveOrganisationSwitch: { key, on in await model.saveOrganisationSwitch(key, on: on) }` and the 3-argument `saveLocalProvider`.

- [ ] **Step 6: Build**

Run: `make build && make app-test`
Expected: both succeed.

- [ ] **Step 7: Commit**

```bash
git add app
git commit -m "WakilApp: the fast-path receipt, and Model / Ghost-text / Fast path under QUICK TASKS"
```

---

### Task 9: e2e — keep the suite green

**Files:**
- Modify: `e2e/checks/seeded/3b-viii-local-provider-add.jsonl`, `3b-viii-local-provider-dispatch.jsonl`, `3b-viii-ghost-text-setting.jsonl`, any other check that references `.serves.infill`, `.serves.respond` or `settings.editor.ghostText`; `e2e/checks/uncoverable.tsv`

- [ ] **Step 1: Find what references the removed controls**

Run: `grep -rln 'serves\.\(infill\|respond\)\|settings\.editor\.ghostText\|"serves"' e2e/checks`

- [ ] **Step 2: Update each check**
  - Steps clicking `.serves.*` or expecting `checkbox (disabled)` are removed; expectations on `providers[N].serves` become `["infill","respond"]`.
  - `3b-viii-ghost-text-setting.jsonl`: navigate `settings.tree.providers` instead of `settings.tree.editor`, click `settings.org.ghostText.off` / `.on`, and assert `configuration.structuredContent.org.ghostText`; its parity step dispatches `ctx_update_org {"id":"e2e-fixture","ghostText":false}`.
  - Add `window.composer.receipt`, `window.composer.askAgent`, `settings.org.fastPath.on|off` to `uncoverable.tsv` only if `make e2e-cover` demands it, each with the reason *"covered by the Cover rung's fast-path checks (3b-ix); needs the loopback chat stub"*. (R6: the Cover rung replaces these lines with checks.)

- [ ] **Step 3: Run e2e** (no live Wakil open)

Run: `make app-bundle && make e2e`
Expected: exit 0. Use `rc=$?`, never `status=$?`.

- [ ] **Step 4: Commit**

```bash
git add e2e
git commit -m "e2e: the 3b-viii checks follow the QUICK TASKS switches; serves checkboxes gone"
```

---

### Task 10: Docs — charter changes, the spec's ruling, the runbook

**Files:**
- Modify: `docs/wakil/decisions.md` (Decision 10, Decision 42), `PRODUCT.md` (voice paragraph, ~line 84-87), `docs/superpowers/specs/2026-10-20-3b-ix-fast-path-design.md`
- Create: `docs/wakil/phase-3b-ix-acceptance.md`

- [ ] **Step 1: Decision 10** — append, under Decision 10's text in `decisions.md`, the amendment exactly as the spec's §Charter changes gives it, with "a late answer (past 300 ms on a local model, 2.5 s otherwise)".

- [ ] **Step 2: Decision 42** — append: *Amended 2026-10-20 (3b-ix): one model per org does every quick task; a `local` provider is a URL and serves both operations (the serves checkboxes are removed); each quick task has an on/off switch beside the model, per org (`ghostText`, `fastPath`). The fast path is built; next is agent status lines.* Move "the ⌘K fast path" out of **Next quick tasks**.

- [ ] **Step 3: PRODUCT.md** — after *"Release lands the transcript in the composer unsent; Return sends."* add: *"A line Return sends may run one navigation action at once on the org's quick-tasks model (the fast path, 3b-ix); anything else is an agent turn."*

- [ ] **Step 4: The spec** — in §Decisions and §Composer, replace "A 300 ms deadline" with "a deadline of 300 ms on a local model and 2.5 s otherwise (Ruling R1, plan 2026-10-20)".

- [ ] **Step 5: The runbook** — `docs/wakil/phase-3b-ix-acceptance.md`, in the 3b-viii runbook's shape: §0 Setup (`llama-server -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M --port 8012 -c 8192`; `./bin/wakil provider add local --kind local --base-url http://127.0.0.1:8012`; launch with `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`), §1 the walk table (at most 20 rows: QUICK TASKS rows and defaults; *switch to staging*, *open confirm.go*, *go to line 40*, *show bookings*, *close the db pane*, a question, *delete the draft bookings*, *open orders.go* (absent), Ask the agent instead, a refused close with an unsaved tab, the server stopped, Fast path Off, Same as agent with Fast path On, a dictated line with a mistranscribed file name), §2 Known and not fixed, §3 Residue, §4 the machine walk markers (`<!-- machine-walk: generated by \`make e2e-runbook\`; everything between these markers is overwritten -->` and its closing marker, copied from the 3b-viii runbook).

- [ ] **Step 6: Check the docs**

Run: `make test` (docs-check). Expected: only the pre-existing north-star word-count failure, if any.

- [ ] **Step 7: Commit**

```bash
git add docs PRODUCT.md
git commit -m "Charter: Decision 10 and 42 amended for the fast path; 3b-ix runbook"
```

---

## Self-review

- **Spec coverage:** allowed list (T5, pinned T6); prompt and scope (T5, T6); route, deadline, checks (T5, R1); routing one model / serves retired (T2, T3); Go switches and defaults (T1); composer, receipt, Ask the agent instead, journal `via` (T4, T7, T8); Settings rows, checkboxes and Editor row removed (T8); errors and edges table (T5, T7 tests; Review Focus); interaction rules (T7, T8); e2e (T9, R6 hands new checks to Cover); charter and runbook (T10).
- **Placeholders:** helper names in tests that depend on existing test files (`makeRegistryWithJournal`, `makeFullRegistry`, `makeFastPathWindow`) are named and said to be built on the named existing helpers; `JSONValue`'s `.integer` / `.number` cases are used as the repo defines them.
- **Type consistency:** `FastPathScope`, `FastPathRoute`, `FastPathReceipt`, `FastPathOutcome`, `runFastPath`, `fastPathScope(for:)`, `fastPathSchemas()`, `saveOrganisationSwitch(_:on:)`, `OrganisationSwitch`, `DispatchCaller(place:session:via:)`, `descriptor(named:)` are used with the same signatures in every task.
