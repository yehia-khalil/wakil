# 3b-viii: Quick Tasks and AI Ghost-Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A quick-task seam (`infill` and `respond`) that runs on the org's quick-tasks provider — its active Claude provider by default, or a local endpoint the operator runs — with automatic ghost-text in the editor and the DB query line as its first caller.

**Architecture:** Go records a `local` provider's `baseURL` and `serves`, an org's `quickProvider`, and the operator's `ghostText` switch, and publishes them in `config_tree`. WakilKit adds `QuickModel` (two implementations: a warm `claude` session wrapped around `ClaudeCodeCLIHarness`, and HTTP to a llama.cpp-style endpoint), `QuickTasks` (routing per operation, one fallback, endpoint status), and a ghost-text layer (context windows, schema matching from the cached vocabulary, clean-up, debounce/cancel). WakilApp draws suggestions through Monaco's inline completions and an overlay on the query line, and Settings gains the controls.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`, `cmd/wakil`), Swift 6 (WakilKit, WakilApp, SwiftUI/AppKit), Monaco `registerInlineCompletionsProvider` in `monaco-host.html`, `URLSession`.

**Spec:** `docs/superpowers/specs/2026-10-19-3b-viii-ghost-text-design.md`

## Global Constraints

- Claude is reached only through the `claude` CLI with the provider's config dir and OAuth token (`buildLaunch`'s whitelist). Never the Anthropic API, never an API key (charter §5).
- Nothing outside `app/Sources/WakilKit/Harness/` names Claude, Haiku, llama.cpp or Qwen (Invariant 1). Callers use `QuickTasks`.
- Claude quick process flags, exactly: `--model haiku --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence --system-prompt <QuickPrompts.system>`.
- Recycle the Claude quick process after **20** turns; stop it after **10** idle minutes, on org switch and on quit.
- Debounce: **250 ms** when the routed provider is `local`, **500 ms** otherwise. Pending pulse after **400 ms**.
- Context windows: prefix ≤ **6,000** characters (≈1,500 tokens) cut at a line start; suffix ≤ **2,000** characters cut at a line end.
- Schema: at most **5** tables, matched by name in the file (singular/plural, snake/camel).
- `/infill`: `n_predict` **64**, **128** when multiline; `temperature: 0`; `cache_prompt: true`; `stop: ["\n"]` unless multiline. Multiline replies keep at most **6** lines.
- `serves` defaults to `["infill"]`; the only values are `infill` and `respond`.
- Ghost colour: `rgba(232,236,246,0.34)`.
- Settings strings, exactly: `Quick tasks`, `Same as agent`, `URL`, `Serves`, `Code completion`, `Instructions`, `reachable`, `Ghost-text`, `Ghost-text needs a Claude or local provider`.
- A `baseURL` or `serves` on a non-`local` provider is refused with: `baseURL and serves apply only to --kind local — only a local endpoint speaks /infill (Decision 42)`.
- Never add `Co-Authored-By` or "Generated with" lines to commits.
- Tests: `go test ./internal/wakilcore -run <Name>` / `go test ./cmd/... -run <Name>`; `cd app && ../scripts/swift-test.sh --filter <Name>`. The suite: `go test ./...` and `make app-test` (after `make build` in a fresh worktree).

**Rulings made while planning** (spec silent):
- **R1:** local providers are created and edited from Settings through one new upsert tool, `set_local_provider` (id, label, baseURL, serves). It overrides an existing `local` record of that id (Rule 7) and refuses an existing record of another kind. `wakil provider add --kind local` gains `--base-url` and `--serves`.
- **R2:** the query line shows a suggestion only when the caret is at the end of its line (nothing but whitespace after it on that line). An overlay cannot push text aside; Monaco can, so the editor has no such rule.
- **R3:** the schema comes from the window's cached vocabulary (`VocabularyStore.current()`, source `.schema`), which already rebuilds per environment and drops on org switch. Its flat list is table-then-columns in order; `GhostSchema.tables(from:)` regroups it. No second schema read.
- **R4:** `QuickTasks` is rebuilt (old one shut down) on org switch, on a provider switch, and after any Settings save that touches providers, `quickProvider` or `ghostText`.
- **R5:** `respond` on the Claude path validates JSON by parsing it (`JSONSerialization`) and checking that the top-level type matches the schema's `type`; full JSON-Schema validation is the server's job on the local path and not reimplemented.

## Review Focus

1. **The operator types fast through a slow Claude reply:** each keystroke cancels; the stale reply must never draw over newer text — pinned in Task 6 (`staleReplyIsDropped`) and Task 8 (a resolve for an old id is ignored by the page).
2. **The local server is stopped mid-session:** suggestions must keep coming from Claude and Settings must show the error whole, then recover when the server is back — pinned in Task 3 (`fallsBackOnceThenRetriesEndpointNextCall`).
3. **A file with CRLF line endings or a caret inside a multi-byte character run:** windows are cut on `String` indices, never bytes — pinned in Task 6 (`windowsKeepCRLFAndEmoji`).
4. **Org switch with a request in flight:** the reply must not land in the new org's pane — pinned in Task 7 (`orgSwitchCancelsAndRebuilds`).
5. **Tab in an empty query line with no suggestion:** must still leave the line, as today — pinned in Task 9 (`tabWithoutSuggestionLeavesLine`, a pure key-decision test).

---

### Task 1: Go — `local` providers carry `baseURL` and `serves`

**Files:**
- Modify: `internal/wakilcore/provider.go` (struct `Provider` ~L19, `AddProvider` ~L139)
- Create: `internal/wakilcore/localprovider.go`
- Modify: `internal/wakilcore/configtree.go` (`ConfigTreeProvider` ~L37, its fill ~L202)
- Modify: `cmd/wakil-ctx/main.go` (new tool beside `add_provider` ~L600)
- Modify: `cmd/wakil/providercmd.go` (`provider add` flags ~L72)
- Test: `internal/wakilcore/localprovider_test.go`, `cmd/wakil/orgcmd_test.go`

**Interfaces:**
- Produces (Go): `Provider.BaseURL string json:"baseURL,omitempty"`, `Provider.Serves []string json:"serves,omitempty"`; `const QuickOpInfill = "infill"`, `QuickOpRespond = "respond"`; `func SetLocalProvider(org string, p Provider) error`; `ConfigTreeProvider.BaseURL`, `.Serves` (json `baseURL`, `serves`; `serves` resolved — `["infill"]` when unset on a `local`, `["infill","respond"]` on `claude-code`, `[]` on `codex`).
- Produces (tool): `set_local_provider` with args `id` (string), `label` (string, optional), `baseURL` (string), `serves` (array of string, optional).

- [ ] **Step 1: Write the failing tests** in `internal/wakilcore/localprovider_test.go`:

```go
package wakilcore

import (
	"reflect"
	"strings"
	"testing"
)

func localOrg(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
}

func TestSetLocalProviderWritesURLAndDefaultServes(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: " http://127.0.0.1:8012/ "}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProviderFor("initech", "qwen")
	if err != nil {
		t.Fatal(err)
	}
	if p.Kind != ProviderKindLocal || p.BaseURL != "http://127.0.0.1:8012" {
		t.Errorf("got kind %q baseURL %q", p.Kind, p.BaseURL)
	}
	if !reflect.DeepEqual(p.Serves, []string{QuickOpInfill}) {
		t.Errorf("serves = %v, want [infill]", p.Serves)
	}
}

func TestSetLocalProviderOverridesItsOwnRecord(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	if err := SetLocalProvider("initech", Provider{ID: "qwen", Label: "Qwen", BaseURL: "http://localhost:9000",
		Serves: []string{QuickOpRespond, QuickOpInfill, QuickOpInfill}}); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProviderFor("initech", "qwen")
	if p.BaseURL != "http://localhost:9000" || p.Label != "Qwen" ||
		!reflect.DeepEqual(p.Serves, []string{QuickOpInfill, QuickOpRespond}) {
		t.Errorf("got %+v", p)
	}
}

func TestSetLocalProviderRefusesBadURLUnknownOpAndOtherKinds(t *testing.T) {
	localOrg(t)
	for _, tc := range []struct {
		p    Provider
		want string
	}{
		{Provider{ID: "a", BaseURL: "ftp://x"}, "baseURL"},
		{Provider{ID: "a", BaseURL: ""}, "baseURL"},
		{Provider{ID: "a", BaseURL: "http://x", Serves: []string{"chat"}}, "serves"},
	} {
		if err := SetLocalProvider("initech", tc.p); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%+v: got %v, want an error naming %q", tc.p, err, tc.want)
		}
	}
	if err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex}); err != nil {
		t.Fatal(err)
	}
	if err := SetLocalProvider("initech", Provider{ID: "cx", BaseURL: "http://x"}); err == nil {
		t.Error("SetLocalProvider overwrote a codex record")
	}
}

func TestAddProviderRefusesBaseURLOnOtherKinds(t *testing.T) {
	localOrg(t)
	err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex, BaseURL: "http://x"})
	if err == nil || !strings.Contains(err.Error(), "only to --kind local") {
		t.Errorf("got %v", err)
	}
}

func TestConfigTreeResolvesServes(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "cx", Kind: ProviderKindCodex}); err != nil {
		t.Fatal(err)
	}
	tree, err := ConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string][]string{}
	for _, p := range tree.Providers {
		got[p.ID] = p.Serves
	}
	if !reflect.DeepEqual(got["qwen"], []string{"infill"}) || len(got["cx"]) != 0 || got["cx"] == nil {
		t.Errorf("serves = %v", got)
	}
}
```

If the config-tree builder is not called `ConfigTreeFor`, use the function `TestConfigTreeCarriesSpeechProvider` (`configtree_test.go:302`) calls.

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore -run 'LocalProvider|BaseURLOnOther|ResolvesServes'`
Expected: FAIL — `SetLocalProvider` and `BaseURL` undefined.

- [ ] **Step 3: Implement.**

In `provider.go`, add to `Provider` after `ClaudePath`:

```go
	// BaseURL and Serves are a local endpoint's (3b-viii, Decision 42): where the operator's
	// model server listens, and which quick operations its model is fit for. A server cannot
	// say the second itself — a code model answers a chat request badly, not with an error.
	BaseURL string   `json:"baseURL,omitempty"`
	Serves  []string `json:"serves,omitempty"`
```

In `AddProvider`'s `case ProviderKindClaudeCode` and for `codex`, refuse a `BaseURL` or `Serves` with `errLocalOnly`; for `local`, call `normaliseLocal` only when `BaseURL` or `Serves` is set — a `local` record with no URL stays valid (existing adds pass none) and simply has no quick model. Put the shared pieces in `localprovider.go`:

```go
package wakilcore

import (
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	QuickOpInfill  = "infill"
	QuickOpRespond = "respond"
)

const errLocalOnly = "baseURL and serves apply only to --kind local — only a local endpoint speaks /infill (Decision 42)"

// normaliseLocal trims and checks a local provider's URL and operations, filling the default.
func normaliseLocal(p *Provider) error {
	raw := strings.TrimRight(strings.TrimSpace(p.BaseURL), "/")
	u, err := url.Parse(raw)
	if raw == "" || err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return UserError("baseURL must be an http or https URL, e.g. http://127.0.0.1:8012; got " + strconv.Quote(p.BaseURL))
	}
	p.BaseURL = raw
	seen := map[string]bool{}
	out := []string{}
	for _, op := range p.Serves {
		op = strings.TrimSpace(op)
		if op != QuickOpInfill && op != QuickOpRespond {
			return UserError("serves: unknown operation " + strconv.Quote(op) + " — one of infill, respond")
		}
		if !seen[op] {
			seen[op] = true
			out = append(out, op)
		}
	}
	if len(out) == 0 {
		out = []string{QuickOpInfill}
	}
	sort.Strings(out) // infill < respond
	p.Serves = out
	return nil
}

// resolvedServes is what config_tree publishes: what the provider's kind can serve.
func resolvedServes(p Provider) []string {
	switch p.Kind {
	case ProviderKindClaudeCode:
		return []string{QuickOpInfill, QuickOpRespond}
	case ProviderKindLocal:
		if len(p.Serves) == 0 {
			return []string{QuickOpInfill}
		}
		return p.Serves
	default:
		return []string{}
	}
}

// SetLocalProvider creates or overrides org's local provider id (Ruling R1). It refuses an
// existing record of another kind: that is a different account, not this endpoint's settings.
func SetLocalProvider(org string, p Provider) error {
	if err := validateProviderToken(p.ID); err != nil {
		return err
	}
	p.Kind = ProviderKindLocal
	if err := normaliseLocal(&p); err != nil {
		return err
	}
	if existing, err := LoadProviderFor(org, p.ID); err == nil && existing.Kind != ProviderKindLocal {
		return UserError("provider " + strconv.Quote(p.ID) + " is a " + existing.Kind + " account, not a local endpoint")
	}
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return writeProviderFile(filepath.Join(dir, p.ID+".json"), p)
}
```

`writeProviderFile` is whatever `AddProvider` uses to marshal and write the record (find its final write after the duplicate check); if that write is inline, extract it into `writeProviderFile(path string, p Provider) error` and call it from both. In `configtree.go` add `BaseURL string json:"baseURL,omitempty"` and `Serves []string json:"serves"` to `ConfigTreeProvider` and fill them (`BaseURL: p.BaseURL, Serves: resolvedServes(p)`).

In `cmd/wakil-ctx/main.go` register `set_local_provider` beside `add_provider`, operator-facing, args `{ID string; Label string; BaseURL string; Serves []string}` with jsonschema descriptions; it resolves the current org the way `update_org`'s handler does and calls `wakilcore.SetLocalProvider`, returning the updated `config_tree` provider row. In `cmd/wakil/providercmd.go` add `fs.StringVar(&p.BaseURL, "base-url", "", "a local endpoint's URL (--kind local only)")` and a `--serves` string flag split on commas into `p.Serves`.

- [ ] **Step 4: Add the CLI test** to `cmd/wakil/orgcmd_test.go`, following the `provider add backup --kind codex` test at ~L397: `provider add qwen --kind local --base-url http://127.0.0.1:8012 --serves infill,respond` exits 0, and `provider list` output contains `qwen`.

- [ ] **Step 5: Run to verify they pass**

Run: `go test ./internal/wakilcore ./cmd/... -run 'LocalProvider|BaseURLOnOther|ResolvesServes|Provider'`
Expected: PASS (the existing provider tests too).

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/provider.go internal/wakilcore/localprovider.go internal/wakilcore/localprovider_test.go internal/wakilcore/configtree.go cmd/wakil-ctx/main.go cmd/wakil/providercmd.go cmd/wakil/orgcmd_test.go
git commit -m "wakilcore: a local provider carries baseURL and serves; set_local_provider"
```

---

### Task 2: Go — `quickProvider` on the org, `ghostText` for the operator

**Files:**
- Modify: `internal/wakilcore/org.go` (`Org` ~L18, validation ~L176-188)
- Modify: `internal/wakilcore/orgupdate.go` (`OrgPatch`, `isEmpty`, `apply`)
- Modify: `internal/wakilcore/unlink.go` (`clearStalePointers` ~L251)
- Modify: `internal/wakilcore/configtree.go` (`ConfigTreeOrg` ~L14, fill ~L193)
- Modify: `internal/wakilcore/editorsettings.go` (stored ~L61, values ~L78/96, resolve ~L106-115, patch ~L211-245, copy ~L323)
- Modify: `cmd/wakil-ctx/main.go` (`update_org` args ~L156/485, `set_editor_settings` args ~L165/503)
- Test: `internal/wakilcore/orgupdate_test.go`, `internal/wakilcore/unlink_test.go`, `internal/wakilcore/editorsettings_test.go`

**Interfaces:**
- Produces: `Org.QuickProvider string json:"quickProvider,omitempty"`; `OrgPatch.QuickProvider *string`; `ConfigTreeOrg.QuickProvider string json:"quickProvider"`; stored `GhostText *bool json:"ghostText,omitempty"`, resolved `GhostText bool json:"ghostText"` (default true); `EditorAppPatch.GhostText *bool`. Tool args `update_org.quickProvider`, `set_editor_settings.ghostText`.

- [ ] **Step 1: Write the failing tests.**

In `orgupdate_test.go`:

```go
func TestUpdateOrgSetsAndClearsQuickProvider(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	id := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if o.QuickProvider != "qwen" {
		t.Fatalf("quickProvider = %q", o.QuickProvider)
	}
	empty := ""
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &empty}); err != nil {
		t.Fatal(err)
	}
	o, _ = LoadOrgFor("initech")
	if o.QuickProvider != "" {
		t.Errorf("not cleared: %q", o.QuickProvider)
	}
}

func TestUpdateOrgRefusesAnUnboundQuickProvider(t *testing.T) {
	localOrg(t)
	id := "ghost"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err == nil {
		t.Error("accepted a quickProvider that names no provider")
	}
}
```

In `unlink_test.go`:

```go
func TestUnlinkClearsQuickProvider(t *testing.T) {
	localOrg(t)
	if err := SetLocalProvider("initech", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}
	id := "qwen"
	if err := UpdateOrg("initech", OrgPatch{QuickProvider: &id}); err != nil {
		t.Fatal(err)
	}
	if _, err := UnlinkProvider("initech", "qwen"); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if o.QuickProvider != "" {
		t.Errorf("org.json still names the gone provider: %q", o.QuickProvider)
	}
}
```

In `editorsettings_test.go`:

```go
func TestGhostTextDefaultsOnAndIsWrittenAndRead(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	s, err := LoadAppSettings()
	if err != nil {
		t.Fatal(err)
	}
	if !s.Editor.Resolved().GhostText {
		t.Fatal("ghostText must default on")
	}
	if err := UpdateEditorAppSettings(EditorAppPatch{GhostText: boolp(false)}); err != nil {
		t.Fatal(err)
	}
	s, _ = LoadAppSettings()
	if s.Editor.Resolved().GhostText {
		t.Error("ghostText stayed on after writing off")
	}
}
```

If unlinking a `local` provider trips on a missing Keychain item, that is a real defect in `UnlinkProvider` for local kinds: make the Keychain delete a no-op for kinds with no credential, and keep the test.

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore -run 'QuickProvider|GhostText'`
Expected: FAIL — fields undefined.

- [ ] **Step 3: Implement**, each field beside its precedent:
  - `Org.QuickProvider` after `SpeechProvider`, comment: "the provider quick tasks run on (3b-viii, Decision 42); empty means the active provider." In the org validation, after the `DefaultProvider` block, trim it and, when non-empty, apply the same `validateProviderToken` + `LoadProviderFor` checks with the prefix `quickProvider: `.
  - `OrgPatch.QuickProvider *string` in the struct, `isEmpty` and `apply`.
  - `clearStalePointers`: also clear `record.QuickProvider == id` in the same load/save, appending `"org.json quickProvider"` to `cleared` (one `SaveOrg` for both fields).
  - `ConfigTreeOrg.QuickProvider` filled from the record.
  - `GhostText` exactly as `ShowIgnored` (stored `*bool`, resolved `bool` defaulting to true, patch, the copy at ~L323).
  - `update_org`: `QuickProvider *string json:"quickProvider,omitempty"` (description: "optional provider id quick tasks run on; omit to leave unchanged, send \"\" for the active provider") passed into `OrgPatch`. `set_editor_settings`: `GhostText *bool json:"ghostText,omitempty"` ("false turns AI ghost-text off in every editor and query line").

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./internal/wakilcore ./cmd/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore cmd/wakil-ctx/main.go
git commit -m "wakilcore: org quickProvider and the operator's ghostText switch"
```

---

### Task 3: WakilKit — the `QuickModel` seam and `QuickTasks` routing

**Files:**
- Create: `app/Sources/WakilKit/Harness/QuickModel.swift`
- Create: `app/Sources/WakilKit/App/QuickTasks.swift`
- Test: `app/Tests/WakilKitTests/QuickTasksTests.swift`

**Interfaces:**
- Produces:

```swift
public enum QuickOperation: String, Sendable, CaseIterable, Codable { case infill, respond }
public struct QuickExtra: Sendable, Equatable { public var name: String; public var text: String }
public struct InfillRequest: Sendable, Equatable { prefix, suffix, path, language: String; extras: [QuickExtra]; multiline: Bool }
public struct RespondRequest: Sendable, Equatable { instructions, input: String; jsonSchema: String?; maxTokens: Int }
public enum QuickModelError: Error, Equatable, CustomStringConvertible {
    case unsupported(QuickOperation), noProvider(QuickOperation), unreachable(String), invalidReply(String), failed(String)
}
public protocol QuickModel: Sendable {
    var serves: Set<QuickOperation> { get }
    func infill(_ request: InfillRequest) async throws -> String
    func respond(_ request: RespondRequest) async throws -> String
    func shutdown() async
}
public struct QuickProviderRecord: Sendable, Equatable { id, kind, baseURL: String; serves: Set<QuickOperation> }
public struct QuickTasksConfig: Sendable, Equatable { quickProvider: QuickProviderRecord?; active: QuickProviderRecord? }
public func quickRoute(_ op: QuickOperation, _ config: QuickTasksConfig) -> [QuickProviderRecord]
public actor QuickTasks {
    public init(config: QuickTasksConfig, makeModel: @escaping @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?)
    public func infill(_ r: InfillRequest) async throws -> String
    public func respond(_ r: RespondRequest) async throws -> String
    public func routedKind(_ op: QuickOperation) -> String?          // "local", "claude-code", or nil
    public func endpointErrors() -> [String: String]                 // provider id → last error, whole
    public func shutdown() async
}
```

- [ ] **Step 1: Write the failing tests** in `QuickTasksTests.swift`:

```swift
import Testing
@testable import WakilKit

private actor FakeModel: QuickModel {
    nonisolated let serves: Set<QuickOperation>
    var replies: [Result<String, QuickModelError>]
    private(set) var calls = 0
    init(serves: Set<QuickOperation>, replies: [Result<String, QuickModelError>]) { self.serves = serves; self.replies = replies }
    func next() throws -> String { calls += 1; return try replies.removeFirst().get() }
    func infill(_ r: InfillRequest) async throws -> String { try next() }
    func respond(_ r: RespondRequest) async throws -> String { try next() }
    func shutdown() async {}
}

private let local = QuickProviderRecord(id: "qwen", kind: "local", baseURL: "http://127.0.0.1:8012", serves: [.infill])
private let claude = QuickProviderRecord(id: "main", kind: "claude-code", baseURL: "", serves: [.infill, .respond])
private let infillReq = InfillRequest(prefix: "b.", suffix: "", path: "a.go", language: "go", extras: [], multiline: false)
private let respondReq = RespondRequest(instructions: "title", input: "x", jsonSchema: nil, maxTokens: 16)

@Suite struct QuickTasksTests {
    @Test func routeTakesQuickProviderThenActiveForEachOperation() {
        let both = QuickTasksConfig(quickProvider: local, active: claude)
        #expect(quickRoute(.infill, both).map(\.id) == ["qwen", "main"])
        #expect(quickRoute(.respond, both).map(\.id) == ["main"])
        #expect(quickRoute(.infill, QuickTasksConfig(quickProvider: nil, active: claude)).map(\.id) == ["main"])
        #expect(quickRoute(.respond, QuickTasksConfig(quickProvider: local, active: nil)).isEmpty)
        let codex = QuickProviderRecord(id: "cx", kind: "codex", baseURL: "", serves: [])
        #expect(quickRoute(.infill, QuickTasksConfig(quickProvider: nil, active: codex)).isEmpty)
    }

    @Test func noProviderThrowsNamedError() async {
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: nil)) { _ in nil }
        await #expect(throws: QuickModelError.noProvider(.infill)) { try await tasks.infill(infillReq) }
    }

    @Test func respondNeverReachesACodeOnlyLocalModel() async throws {
        let localModel = FakeModel(serves: [.infill], replies: [])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("Title")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        #expect(try await tasks.respond(respondReq) == "Title")
        #expect(await localModel.calls == 0)
    }

    @Test func fallsBackOnceThenRetriesEndpointNextCall() async throws {
        let localModel = FakeModel(serves: [.infill], replies: [.failure(.unreachable("connection refused")), .success("i++ {")])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("status")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        #expect(try await tasks.infill(infillReq) == "status")
        #expect(await tasks.endpointErrors() == ["qwen": "connection refused"])
        #expect(try await tasks.infill(infillReq) == "i++ {")
        #expect(await tasks.endpointErrors().isEmpty)
        #expect(await claudeModel.calls == 1)
    }

    @Test func aNonConnectionErrorDoesNotFallBack() async {
        let localModel = FakeModel(serves: [.infill], replies: [.failure(.failed("HTTP 500: boom"))])
        let claudeModel = FakeModel(serves: [.infill, .respond], replies: [.success("x")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: local, active: claude)) { r in
            r.id == "qwen" ? localModel : claudeModel
        }
        await #expect(throws: QuickModelError.failed("HTTP 500: boom")) { try await tasks.infill(infillReq) }
        #expect(await claudeModel.calls == 0)
    }

    @Test func modelsAreMadeOncePerProvider() async throws {
        let counter = Counter()
        let model = FakeModel(serves: [.infill, .respond], replies: [.success("a"), .success("b")])
        let tasks = QuickTasks(config: QuickTasksConfig(quickProvider: nil, active: claude)) { _ in await counter.bump(); return model }
        _ = try await tasks.infill(infillReq)
        _ = try await tasks.respond(respondReq)
        #expect(await counter.value == 1)
        #expect(await tasks.routedKind(.infill) == "claude-code")
    }
}

private actor Counter { var value = 0; func bump() { value += 1 } }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter QuickTasksTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement.** `QuickModel.swift` (in `Harness/`, doc comment: "the harness axis's second seam (Decision 16, amended 3b-viii): one-shot quick tasks. `AgentHarness` is for sessions."), holding the types above with public memberwise inits; `QuickModelError.description` returns the associated string whole (`unsupported`/`noProvider` → `"no quick-tasks provider serves \(op.rawValue)"`). `QuickTasks.swift` in `App/`:

```swift
public func quickRoute(_ op: QuickOperation, _ config: QuickTasksConfig) -> [QuickProviderRecord] {
    var out: [QuickProviderRecord] = []
    for record in [config.quickProvider, config.active].compactMap({ $0 })
    where record.serves.contains(op) && !out.contains(where: { $0.id == record.id }) {
        out.append(record)
    }
    return out
}

/// The one entry point every quick task calls (Decision 42). It picks the model per operation,
/// falls back once from an unreachable endpoint to the next candidate, and keeps each endpoint's
/// last error whole for Settings (Interaction Rule 8). A new quick task is a caller of this, nothing more.
public actor QuickTasks {
    private let config: QuickTasksConfig
    private let makeModel: @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?
    private var models: [String: any QuickModel] = [:]
    private var errors: [String: String] = [:]

    public init(config: QuickTasksConfig, makeModel: @escaping @Sendable (QuickProviderRecord) async throws -> (any QuickModel)?) {
        self.config = config
        self.makeModel = makeModel
    }

    public func infill(_ r: InfillRequest) async throws -> String { try await run(.infill) { try await $0.infill(r) } }
    public func respond(_ r: RespondRequest) async throws -> String { try await run(.respond) { try await $0.respond(r) } }
    public func routedKind(_ op: QuickOperation) -> String? { quickRoute(op, config).first?.kind }
    public func endpointErrors() -> [String: String] { errors }

    public func shutdown() async {
        for model in models.values { await model.shutdown() }
        models = [:]
    }

    private func model(for record: QuickProviderRecord) async throws -> (any QuickModel)? {
        if let m = models[record.id] { return m }
        guard let m = try await makeModel(record) else { return nil }
        models[record.id] = m
        return m
    }

    private func run(_ op: QuickOperation, _ call: (any QuickModel) async throws -> String) async throws -> String {
        let candidates = quickRoute(op, config)
        guard !candidates.isEmpty else { throw QuickModelError.noProvider(op) }
        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let m = try await model(for: record), m.serves.contains(op) else { continue }
            do {
                let reply = try await call(m)
                errors[record.id] = nil
                return reply
            } catch QuickModelError.unreachable(let why) where index < candidates.count - 1 {
                errors[record.id] = why
            }
        }
        throw QuickModelError.noProvider(op)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter QuickTasksTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/QuickModel.swift app/Sources/WakilKit/App/QuickTasks.swift app/Tests/WakilKitTests/QuickTasksTests.swift
git commit -m "WakilKit: the QuickModel seam and QuickTasks routing"
```

---

### Task 4: WakilKit — `LocalEndpointQuickModel`

**Files:**
- Create: `app/Sources/WakilKit/Harness/LocalEndpointQuickModel.swift`
- Test: `app/Tests/WakilKitTests/LocalEndpointQuickModelTests.swift`

**Interfaces:**
- Consumes: Task 3's types.
- Produces: `public final class LocalEndpointQuickModel: QuickModel, Sendable { public init(baseURL: URL, serves: Set<QuickOperation>, session: URLSession = .shared) }`.

- [ ] **Step 1: Write the failing tests.** Use a `URLProtocol` stub registered on an ephemeral `URLSessionConfiguration` (`protocolClasses = [StubProtocol.self]`); the stub records the last request's path and JSON body and answers from a static handler.

```swift
import Foundation
import Testing
@testable import WakilKit

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var lastPath = ""
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            return d
        } ?? Data()
        Self.lastPath = request.url?.path ?? ""
        Self.lastBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        guard let (status, data) = Self.handler?(request, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LocalEndpointQuickModelTests {
    func model(_ serves: Set<QuickOperation> = [.infill, .respond]) -> LocalEndpointQuickModel {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return LocalEndpointQuickModel(baseURL: URL(string: "http://127.0.0.1:8012")!, serves: serves, session: URLSession(configuration: c))
    }

    @Test func infillPostsTheLlamaShape() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"content":"ConfirmedAt = time.Now()"}"#.utf8)) }
        let r = InfillRequest(prefix: "b.", suffix: "\n}", path: "a.go", language: "go",
                              extras: [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id);")], multiline: false)
        #expect(try await model().infill(r) == "ConfirmedAt = time.Now()")
        #expect(StubProtocol.lastPath == "/infill")
        let b = StubProtocol.lastBody
        #expect(b["input_prefix"] as? String == "b.")
        #expect(b["input_suffix"] as? String == "\n}")
        #expect(b["n_predict"] as? Int == 64)
        #expect(b["cache_prompt"] as? Bool == true)
        #expect(b["stop"] as? [String] == ["\n"])
        #expect((b["input_extra"] as? [[String: String]])?.first?["filename"] == "schema.sql")
    }

    @Test func multilineAsksForMoreAndDoesNotStopAtNewline() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"content":"x"}"#.utf8)) }
        _ = try await model().infill(InfillRequest(prefix: "", suffix: "", path: "a.go", language: "go", extras: [], multiline: true))
        #expect(StubProtocol.lastBody["n_predict"] as? Int == 128)
        #expect(StubProtocol.lastBody["stop"] == nil)
    }

    @Test func respondUsesChatCompletionsWithSchema() async throws {
        StubProtocol.handler = { _, _ in (200, Data(#"{"choices":[{"message":{"content":"{\"a\":1}"}}]}"#.utf8)) }
        let out = try await model().respond(RespondRequest(instructions: "pick", input: "open a.go",
                                                           jsonSchema: #"{"type":"object"}"#, maxTokens: 32))
        #expect(out == #"{"a":1}"#)
        #expect(StubProtocol.lastPath == "/v1/chat/completions")
        let msgs = StubProtocol.lastBody["messages"] as? [[String: String]]
        #expect(msgs?.map { $0["role"] ?? "" } == ["system", "user"])
        #expect((StubProtocol.lastBody["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func respondRejectsNonJSONWhenSchemaSet() async {
        StubProtocol.handler = { _, _ in (200, Data(#"{"choices":[{"message":{"content":"sure!"}}]}"#.utf8)) }
        await #expect(throws: QuickModelError.self) {
            try await model().respond(RespondRequest(instructions: "", input: "", jsonSchema: #"{"type":"object"}"#, maxTokens: 8))
        }
    }

    @Test func connectionFailureIsUnreachableAndHTTPErrorIsFailedWhole() async {
        StubProtocol.handler = nil
        await #expect(throws: QuickModelError.self) { try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        do { _ = try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        catch let e as QuickModelError { if case .unreachable = e {} else { Issue.record("want unreachable, got \(e)") } }
        catch { Issue.record("\(error)") }
        StubProtocol.handler = { _, _ in (500, Data("model not loaded".utf8)) }
        await #expect(throws: QuickModelError.failed("HTTP 500: model not loaded")) {
            try await model().infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        }
    }

    @Test func anOperationItDoesNotServeThrowsUnsupported() async {
        await #expect(throws: QuickModelError.unsupported(.respond)) {
            try await model([.infill]).respond(RespondRequest(instructions: "", input: "", jsonSchema: nil, maxTokens: 8))
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter LocalEndpointQuickModelTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement.** Bodies: infill `{"input_prefix","input_suffix","input_extra":[{"filename","text"}],"n_predict":64|128,"temperature":0,"cache_prompt":true}` plus `"stop":["\n"]` unless multiline; respond `{"messages":[{"role":"system","content":instructions},{"role":"user","content":input}],"max_tokens","temperature":0}` plus, when `jsonSchema` is set, `"response_format":{"type":"json_schema","json_schema":{"name":"reply","schema":<parsed schema>}}`. Map `URLError` codes `.cannotConnectToHost`, `.cannotFindHost`, `.timedOut`, `.networkConnectionLost`, `.notConnectedToInternet` to `.unreachable(error.localizedDescription)`; `CancellationError` and `URLError(.cancelled)` rethrow as `CancellationError()`; a non-2xx status to `.failed("HTTP \(status): \(body as UTF-8)")`; a reply that does not decode to `content` / `choices[0].message.content` to `.invalidReply(<the body whole>)`. When `jsonSchema` is set, run the reply through `QuickJSON.validate(_:schema:)` (put it in this file; it is reused by Task 5): parse with `JSONSerialization` (`.fragmentsAllowed`), and when the schema's top-level `type` is `object`/`array`/`string`/`number`/`integer`/`boolean`, check the parsed value's type; throw `.invalidReply("<reason>: <reply>")`. Request timeout 10 s. `shutdown()` does nothing.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter LocalEndpointQuickModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/LocalEndpointQuickModel.swift app/Tests/WakilKitTests/LocalEndpointQuickModelTests.swift
git commit -m "WakilKit: LocalEndpointQuickModel — /infill and chat completions"
```

---

### Task 5: WakilKit — `ClaudeCodeQuickModel`, a warm session per provider

**Files:**
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift` (`buildLaunch` ~L103, `init` ~L265)
- Create: `app/Sources/WakilKit/Harness/ClaudeCodeQuickModel.swift`
- Test: `app/Tests/WakilKitTests/ClaudeCodeQuickModelTests.swift`, `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`

**Interfaces:**
- Consumes: `AgentHarness` (`start/send/events/interrupt/stop`), `HarnessEvent.result(isError:text:)`, Task 3's types, Task 4's `QuickJSON.validate`.
- Produces: `buildLaunch(…, extraArguments: [String] = [])`; `ClaudeCodeCLIHarness.init(…, extraArguments: [String] = [])`; `public enum QuickPrompts { static let system: String; static func infill(_:) -> String; static func respond(_:) -> String }`; `public func quickLaunchArguments() -> [String]`; `public actor ClaudeCodeQuickModel: QuickModel { public init(recycleAfter: Int = 20, idleTimeout: Duration = .seconds(600), makeHarness: @escaping @Sendable () -> any AgentHarness) }`.

- [ ] **Step 1: Write the failing tests.** In `ClaudeCodeCLIHarnessTests.swift`, add: `buildLaunch(... extraArguments: ["--model", "haiku"])`'s `arguments` end with `["--model", "haiku"]` and the environment is still exactly the four whitelisted keys. In `ClaudeCodeQuickModelTests.swift`, a `FakeHarness` actor conforming to `AgentHarness` that records `sent` texts, counts `start`/`stop`/`interrupt`, and answers each `send` by yielding `.result(isError: false, text: <next scripted reply>)` on its events stream:

```swift
@Suite struct ClaudeCodeQuickModelTests {
    @Test func quickLaunchArgumentsAreTheGlobalConstraint() {
        let a = quickLaunchArguments()
        #expect(a.starts(with: ["--model", "haiku", "--tools", "", "--no-session-persistence", "--system-prompt"]))
        #expect(a.last == QuickPrompts.system)
    }

    @Test func infillTurnCarriesExtrasAndCursor() async throws {
        let h = FakeHarness(replies: ["ConfirmedAt = time.Now()"])
        let m = ClaudeCodeQuickModel { h }
        let out = try await m.infill(InfillRequest(prefix: "b.", suffix: "\n}", path: "a.go", language: "go",
                                                  extras: [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id);")], multiline: false))
        #expect(out == "ConfirmedAt = time.Now()")
        let turn = try #require(await h.sent.first)
        #expect(turn.contains("schema.sql") && turn.contains("CREATE TABLE bookings"))
        #expect(turn.contains("b.<CURSOR>\n}"))
    }

    @Test func respondWithSchemaReasksOnceThenThrows() async throws {
        let ok = FakeHarness(replies: ["not json", #"{"action":"open"}"#])
        #expect(try await ClaudeCodeQuickModel { ok }.respond(RespondRequest(instructions: "i", input: "x", jsonSchema: #"{"type":"object"}"#, maxTokens: 32)) == #"{"action":"open"}"#)
        #expect(await ok.sent.count == 2)
        let bad = FakeHarness(replies: ["no", "still no"])
        await #expect(throws: QuickModelError.self) {
            try await ClaudeCodeQuickModel { bad }.respond(RespondRequest(instructions: "i", input: "x", jsonSchema: #"{"type":"object"}"#, maxTokens: 32))
        }
    }

    @Test func recyclesAfterTwentyTurnsWithAWarmSpare() async throws {
        let made = HarnessLog()
        let m = ClaudeCodeQuickModel(recycleAfter: 2) { made.next(replies: Array(repeating: "x", count: 10)) }
        for _ in 0..<5 { _ = try await m.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        // turns 1-2 on #0, 3-4 on #1 (the spare started at turn 2), 5 on #2; #0 and #1 stopped.
        #expect(made.count >= 3)
        #expect(await made.harness(0).stops == 1)
        #expect(await made.harness(1).stops == 1)
    }

    @Test func cancellingInterruptsTheTurnAndTheNextRequestIsNotStale() async throws {
        let h = FakeHarness(replies: ["late", "fresh"], holdFirst: true)
        let m = ClaudeCodeQuickModel { h }
        let first = Task { try await m.infill(InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false)) }
        await h.waitUntilSent(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await h.interrupts == 1)
        await h.release()
        #expect(try await m.infill(InfillRequest(prefix: "b", suffix: "", path: "", language: "", extras: [], multiline: false)) == "fresh")
    }

    @Test func anErrorResultIsFailedWhole() async {
        let h = FakeHarness(replies: [], errorText: "rate limited")
        await #expect(throws: QuickModelError.failed("rate limited")) {
            try await ClaudeCodeQuickModel { h }.infill(InfillRequest(prefix: "", suffix: "", path: "", language: "", extras: [], multiline: false))
        }
    }
}
```

`FakeHarness` (`holdFirst`: the first reply waits for `release()`, and a reply produced after `interrupt()` is still yielded so the model must drop it), `HarnessLog` (a lock-guarded array of made fakes) are test helpers in the same file; write them fully.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'ClaudeCodeQuickModelTests|ClaudeCodeCLIHarnessTests'`
Expected: FAIL — `extraArguments`, `ClaudeCodeQuickModel` undefined.

- [ ] **Step 3: Implement.**
  - `buildLaunch` gains `extraArguments: [String] = []`, appended last; the harness `init` gains the same and passes it through. Existing callers are unchanged.
  - `QuickPrompts.system`: `"You are a completion engine inside a code editor. Do exactly what each message asks. Reply with the result only — no prose, no code fences, no explanation."` `QuickPrompts.infill(r)`: each extra as `"--- \(name)\n\(text)\n"`, then `"--- \(r.path) (\(r.language))\n\(r.prefix)<CURSOR>\(r.suffix)\n---\nReply with only the text to insert at <CURSOR>\(r.multiline ? " (up to six lines)" : " (one line)")."` `QuickPrompts.respond(r)`: instructions, a blank line, `"Input:\n\(r.input)"`, and when `jsonSchema` is set `"\n\nReply with one JSON value matching this schema:\n\(schema)"`.
  - `quickLaunchArguments()`: `["--model", "haiku", "--tools", "", "--no-session-persistence", "--system-prompt", QuickPrompts.system]` (the `--mcp-config '{"mcpServers":{}}'` / `--strict-mcp-config` pair is already emitted by `buildLaunch` from `mcpConfigJSON`; Task 7 passes `#"{"mcpServers":{}}"#` and `allowedTools: []`).
  - `ClaudeCodeQuickModel` (actor): holds `current: (harness, events iterator, turns)` and `spare`. `ensureStarted()` makes and `start(sessionId: UUID().uuidString.lowercased(), resumingFrom: nil, workingDirectory: NSTemporaryDirectory())`. `turn(_ text:)`: sends, then reads events until `.result`; returns its text (`.result(isError: true, text)` → `.failed(text ?? "claude quick turn failed")`). Wrap the read in `withTaskCancellationHandler`: on cancel call `interrupt()` and mark `drainOne = true`, so the next `turn` first reads and discards one `.result` before sending. After a turn, `turns += 1`; at `recycleAfter - 1` start the spare; at `recycleAfter` stop current and promote the spare. An idle task (restarted each turn) stops everything after `idleTimeout`. `infill` returns the result text; `respond` with a schema validates via `QuickJSON.validate`, on failure sends one more turn `"That reply was not valid: \(reason). Reply again with only the JSON value."`, then throws `.invalidReply`. `shutdown()` stops current and spare. `serves = [.infill, .respond]`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'ClaudeCodeQuickModelTests|ClaudeCodeCLIHarnessTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness app/Tests/WakilKitTests/ClaudeCodeQuickModelTests.swift app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift
git commit -m "WakilKit: ClaudeCodeQuickModel — a warm claude session for quick tasks"
```

---

### Task 6: WakilKit — ghost-text: context, schema, clean-up, debounce

**Files:**
- Create: `app/Sources/WakilKit/Editor/GhostText.swift`
- Test: `app/Tests/WakilKitTests/GhostTextTests.swift`

**Interfaces:**
- Consumes: `Identifier`, `IdentifierKind`, `IdentifierSourceKind.schema`; Task 3's `InfillRequest`, `QuickExtra`.
- Produces:

```swift
public struct GhostTable: Sendable, Equatable { public let name: String; public let columns: [String] }
public enum GhostSchema {
    public static func tables(from names: [Identifier]) -> [GhostTable]          // regroups the flat .schema list (R3)
    public static func matching(_ tables: [GhostTable], in text: String, limit: Int = 5) -> [GhostTable]
    public static func extra(_ tables: [GhostTable]) -> QuickExtra?               // "schema.sql", CREATE TABLE lines; nil when empty
}
public func ghostRequest(text: String, caret: String.Index, path: String, language: String, schema: [GhostTable]) -> InfillRequest
public func ghostClean(_ reply: String, suffix: String, multiline: Bool) -> String
public actor GhostTextSession {
    public init(suggest: @escaping @Sendable (InfillRequest) async throws -> String, debounce: @escaping @Sendable () async -> Duration)
    /// Cancels whatever is in flight; waits the debounce; asks; returns the cleaned suggestion, or nil if superseded, empty or failed.
    public func request(_ r: InfillRequest) async -> String?
    public func cancel()
}
```

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
@testable import WakilKit

private func schemaIDs() -> [Identifier] {
    func t(_ s: String) -> Identifier { Identifier(text: s, kind: .table, origin: "staging · core db", source: .schema) }
    func c(_ s: String) -> Identifier { Identifier(text: s, kind: .column, origin: "staging · core db", source: .schema) }
    return [t("bookings"), c("id"), c("status"), c("confirmed_at"), t("guests"), c("id"), c("email"),
            t("booking_items"), c("id"), t("audit_logs"), c("id")]
}

@Suite struct GhostTextTests {
    @Test func tablesRegroupTheFlatList() {
        let ts = GhostSchema.tables(from: schemaIDs())
        #expect(ts.map(\.name) == ["bookings", "guests", "booking_items", "audit_logs"])
        #expect(ts[0].columns == ["id", "status", "confirmed_at"])
    }

    @Test func matchingTakesSingularPluralSnakeAndCamel() {
        let ts = GhostSchema.tables(from: schemaIDs())
        #expect(GhostSchema.matching(ts, in: "func confirm(b *Booking) {").map(\.name) == ["bookings"])
        #expect(GhostSchema.matching(ts, in: "$item = BookingItem::find($id);").map(\.name) == ["booking_items"])
        #expect(GhostSchema.matching(ts, in: "SELECT guest_id FROM x").map(\.name) == ["guests"])
        #expect(GhostSchema.matching(ts, in: "AuditLog.create()").map(\.name) == ["audit_logs"])
        #expect(GhostSchema.matching(ts, in: "const x = 1").isEmpty)
        #expect(GhostSchema.extra([]) == nil)
    }

    @Test func matchingStopsAtFive() {
        let many = (0..<8).map { GhostTable(name: "t\($0)s", columns: ["id"]) }
        let text = (0..<8).map { "t\($0)" }.joined(separator: " ")
        #expect(GhostSchema.matching(many, in: text).count == 5)
    }

    @Test func extraIsCreateTableLines() {
        #expect(GhostSchema.extra([GhostTable(name: "bookings", columns: ["id", "status"])]) ==
                QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id, status);\n"))
    }

    @Test func windowsCutAtLinesAndFlagEmptyLines() {
        let body = String(repeating: "x\n", count: 4_000)
        let text = body + "b.\n}\n"
        let caret = text.index(text.startIndex, offsetBy: body.count + 2)
        let r = ghostRequest(text: text, caret: caret, path: "a.go", language: "go", schema: [])
        #expect(r.prefix.hasSuffix("b."))
        #expect(r.prefix.count <= 6_000 && (r.prefix.first == "x"))
        #expect(r.suffix == "\n}\n")
        #expect(!r.multiline)
        let blank = "func f() {\n    \n}"
        let at = blank.index(blank.startIndex, offsetBy: 15)
        #expect(ghostRequest(text: blank, caret: at, path: "a.go", language: "go", schema: []).multiline)
    }

    @Test func windowsKeepCRLFAndEmoji() {
        let text = "a = \"🙂\"\r\nb."
        let r = ghostRequest(text: text, caret: text.endIndex, path: "a.go", language: "go", schema: [])
        #expect(r.prefix == text && r.suffix.isEmpty)
    }

    @Test func requestCarriesMatchedSchemaOnly() {
        let ts = GhostSchema.tables(from: schemaIDs())
        let text = "b := Booking{}\nb."
        let r = ghostRequest(text: text, caret: text.endIndex, path: "a.go", language: "go", schema: ts)
        #expect(r.extras == [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id, status, confirmed_at);\n")])
    }

    @Test func cleanTrimsSuffixEchoWhitespaceAndLines() {
        #expect(ghostClean("guest_id, status FROM bookings WHERE guest_id = ?\", gid)", suffix: " FROM bookings WHERE guest_id = ?\", gid)", multiline: false) == "guest_id, status")
        #expect(ghostClean("i++ {  \n", suffix: "", multiline: false) == "i++ {")
        #expect(ghostClean("a\nb", suffix: "", multiline: false) == "a")
        #expect(ghostClean((1...9).map(String.init).joined(separator: "\n"), suffix: "", multiline: true).split(separator: "\n").count == 6)
        #expect(ghostClean("   ", suffix: "", multiline: false) == "")
    }

    @Test func staleReplyIsDropped() async {
        let gate = Gate()
        let s = GhostTextSession(suggest: { r in await gate.wait(r.prefix); return r.prefix + "!" }, debounce: { .zero })
        async let first = s.request(InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false))
        await gate.waitUntilWaiting("a")
        async let second = s.request(InfillRequest(prefix: "ab", suffix: "", path: "", language: "", extras: [], multiline: false))
        await gate.open("a"); await gate.open("ab")
        #expect(await first == nil)
        #expect(await second == "ab!")
    }

    @Test func debounceSupersedesWithoutAsking() async {
        let asked = Counter()
        let s = GhostTextSession(suggest: { _ in await asked.bump(); return "x" }, debounce: { .milliseconds(50) })
        async let a = s.request(InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false))
        try? await Task.sleep(for: .milliseconds(5))
        async let b = s.request(InfillRequest(prefix: "ab", suffix: "", path: "", language: "", extras: [], multiline: false))
        #expect(await a == nil)
        #expect(await b == "x")
        #expect(await asked.value == 1)
    }
}
```

`Gate` (per-key continuations with `wait`, `waitUntilWaiting`, `open`) and `Counter` are test helpers in this file; write them fully (name `Counter` `GhostCounter` if Task 3's private one clashes).

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter GhostTextTests`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement.**
  - `tables(from:)`: walk the list; a `.table` or `.collection` starts a table, following `.column`s join it; skip non-`.schema` sources.
  - `matching`: split the text into words on non-alphanumerics; split each word further on camel humps (`BookingItem` → `booking`, `item`) and on `_`; build candidate forms per table name `n`: `n`, its singular (drop a trailing `s`, `es` after `s/x/ch/sh`, `ies` → `y`), and its snake parts joined (`booking_items` matches the camel pair `booking`+`item` and `booking_item`). A table matches when the lower-cased text contains its singular as a whole word, or its snake singular (`booking_item`) as a whole token, or its camel-joined singular (`bookingitem`) after lower-casing camel words. Keep table order from the schema, at most `limit`.
  - `ghostRequest`: prefix = text before the caret, trimmed from the front to the last 6,000 characters and then to the next line start (unless the whole prefix fits); suffix = text after the caret, cut to 2,000 characters then back to the last line end (unless whole). `multiline` = the caret's line is whitespace only. `extras` = `[GhostSchema.extra(GhostSchema.matching(schema, in: prefix + suffix))]` compacted.
  - `ghostClean`: drop the longest tail of the reply that equals a prefix of `suffix` (try lengths from `min(reply.count, suffix.count)` down to 1); trim trailing whitespace on each line and trailing newlines; single line unless multiline, then at most six lines.
  - `GhostTextSession`: a generation counter; `request` bumps it, cancels the held task, sleeps `await debounce()` (returns nil if the generation moved), runs `suggest` in a new held `Task`, and returns `ghostClean(reply, suffix: r.suffix, multiline: r.multiline)` only if the generation is unchanged and the result is non-empty; errors and cancellation return nil.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter GhostTextTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor/GhostText.swift app/Tests/WakilKitTests/GhostTextTests.swift
git commit -m "WakilKit: ghost-text context, schema matching, clean-up and debounce"
```

---

### Task 7: WakilKit — the window owns `QuickTasks` and answers ghost requests

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsEditor` ~L109, `SettingsOrg` ~L163, `SettingsProvider` ~L206)
- Create: `app/Sources/WakilKit/App/WindowModel+QuickTasks.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (init params ~L860, stored deps, org-switch and provider-switch paths)
- Modify: `app/Sources/WakilApp/WindowSession.swift` (build the quick-model factory beside `harnessFactory` ~L189)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_update_org` ~L969 forwards `quickProvider`; `ctx_set_editor_settings` ~L1038 forwards `ghostText`; new operator-only `ctx_set_local_provider` forwarding `id,label,baseURL,serves` to `set_local_provider`)
- Test: `app/Tests/WakilKitTests/WindowModelQuickTasksTests.swift`, `app/Tests/WakilKitTests/SettingsTreeTests.swift` (or the file that decodes `SettingsTree` today)

**Interfaces:**
- Consumes: Tasks 1–6; `ProviderCredentialsLookup.credentials(forProvider:)`; `VocabularyStore.current()`.
- Produces: `SettingsEditor.ghostText: Bool` (default true); `SettingsOrg.quickProvider: String`; `SettingsProvider.baseURL: String`, `.serves: [String]`; on `WindowModel`: `public var ghostTextEnabled: Bool { get }`, `public func ghostSuggestion(pane: PaneID, request: InfillRequest) async -> String?`, `public func ghostCancel(pane: PaneID)`, `public func ghostDebounce() async -> Duration`, `public func quickTaskErrors() async -> [String: String]`, `public func ghostSchema() async -> [GhostTable]`, `func rebuildQuickTasks() async` (called per Ruling R4). Init gains `quickModelFactory: (@Sendable (QuickProviderRecord, String) async throws -> (any QuickModel)?)? = nil` (record, org).

- [ ] **Step 1: Write the failing tests.** `SettingsTree` decoding: a tree JSON with `"org":{"id":"initech","quickProvider":"qwen"}`, a provider `{"id":"qwen","kind":"local","baseURL":"http://127.0.0.1:8012","serves":["infill"]}` and `"editor":{"ghostText":false}` decodes to those values; absent keys decode to `""`, `[]` and `true`. `WindowModelQuickTasksTests`, using `WindowModel.forTesting` with a stub context client whose `config_tree` returns that JSON (follow how existing `WindowModel` tests stub `config_tree`) and a `quickModelFactory` returning a fake model:

```swift
@Test func ghostSuggestionRoutesThroughTheQuickProvider() async throws {
    let fake = ScriptedQuickModel(serves: [.infill], reply: "ConfirmedAt = time.Now()")
    let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { record, _ in record.id == "qwen" ? fake : nil }
    let r = InfillRequest(prefix: "b.", suffix: "", path: "a.go", language: "go", extras: [], multiline: false)
    #expect(await model.ghostSuggestion(pane: PaneID("p1"), request: r) == "ConfirmedAt = time.Now()")
    #expect(await model.ghostDebounce() == .milliseconds(250))
}

@Test func switchedOffAsksNothing() async {
    let fake = ScriptedQuickModel(serves: [.infill], reply: "x")
    let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: false)) { _, _ in fake }
    #expect(await model.ghostSuggestion(pane: PaneID("p1"), request: InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false)) == nil)
    #expect(await fake.calls == 0)
}

@Test func orgSwitchCancelsAndRebuilds() async throws {
    let slow = ScriptedQuickModel(serves: [.infill], reply: "old org", delay: .seconds(5))
    let model = await makeWindow(tree: treeJSON(quick: "qwen", ghost: true)) { _, _ in slow }
    let pending = Task { await model.ghostSuggestion(pane: PaneID("p1"), request: InfillRequest(prefix: "a", suffix: "", path: "", language: "", extras: [], multiline: false)) }
    try await Task.sleep(for: .milliseconds(300))
    await model.rebuildQuickTasks()          // what the org-switch path calls
    #expect(await pending.value == nil)
    #expect(await slow.shutdowns == 1)
}
```

Write `makeWindow`, `treeJSON` and `ScriptedQuickModel` in the test file. Use the `PaneID` constructor the existing tests use.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelQuickTasksTests|SettingsTree'`
Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `SettingsTree.swift`: the three fields with `decodeIfPresent` defaults, added to `CodingKeys` and memberwise inits (defaulted, so existing call sites compile).
  - `WindowModel+QuickTasks.swift`: `rebuildQuickTasks()` shuts the old `QuickTasks` down, cancels every pane's `GhostTextSession`, reads `config_tree` through the context client (the same call `StandardActions` makes at ~L2749), maps `tree.providers` to `QuickProviderRecord` (`serves` from strings via `QuickOperation(rawValue:)`), picks `quickProvider` by `tree.org.quickProvider` and `active` by the window's current provider id, stores `ghostTextEnabled = tree.editor.ghostText`, and builds `QuickTasks(config:makeModel:)` with `makeModel = { record in try await factory(record, org) }`. Per-pane `GhostTextSession`s live in a dictionary keyed by `PaneID`, created on first request with `suggest: { [quickTasks] in try await quickTasks.infill($0) }` and `debounce: { await self.ghostDebounce() }`. `ghostDebounce()` is 250 ms when `routedKind(.infill) == "local"`, else 500 ms. `ghostSuggestion` returns nil at once when disabled or when no `QuickTasks` exists; `ghostSchema()` returns `GhostSchema.tables(from: vocabulary.current().names)` (empty when there is no vocabulary).
  - `WindowModel.swift`: store the factory; call `rebuildQuickTasks()` at the end of window start, after the org-switch completes, after a provider switch, and after `ctx_update_org`, `ctx_set_editor_settings`, `ctx_set_local_provider` and `unlink_provider` succeed from Settings (R4).
  - `WindowSession.swift`: build the factory beside `harnessFactory`: for `kind == "local"` with a valid `baseURL` → `LocalEndpointQuickModel(baseURL:serves:)`; for `claude-code` → resolve `lookupFactory(org).credentials(forProvider: record.id)` and return `ClaudeCodeQuickModel { ClaudeCodeCLIHarness(claudePath:configDir:oauthToken:mcpConfigJSON: #"{"mcpServers":{}}"#, allowedTools: [], extraArguments: quickLaunchArguments()) }`; otherwise nil. Pass it to `WindowModel`.
  - `StandardActions.swift`: forward the new keys; register `ctx_set_local_provider` (kind `.control`, audience `.operatorOnly`, schema `id` required, `label`, `baseURL`, `serves` array of strings) calling `set_local_provider` with `callChecked`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app && ../scripts/swift-test.sh --filter 'WindowModelQuickTasksTests|SettingsTree|StandardActions'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests
git commit -m "WakilKit: the window owns QuickTasks and answers ghost requests"
```

---

### Task 8: WakilApp — ghost-text in the editor (Monaco inline completions)

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html` (after the editor is created, ~L102)
- Modify: `app/Sources/WakilApp/MonacoEditorRenderer.swift` (`receive` ~L179, a new resolve call)
- Modify: `app/Sources/WakilApp/EditorPane.swift` (`EditorHost.start` ~L778, the view's closure hand-off)
- Modify: `app/Sources/WakilApp/Canvas.swift` (~L434, pass the model's ghost closures to the editor pane)
- Create: `app/Sources/WakilKit/Editor/GhostBridge.swift`
- Test: `app/Tests/WakilKitTests/GhostBridgeTests.swift`

**Interfaces:**
- Consumes: Task 7's `WindowModel.ghostSuggestion`, `ghostCancel`, `ghostSchema`, `ghostTextEnabled`; Task 6's `ghostRequest`.
- Produces: page message `{type:'ghost', key, id, text, offset}` (offset in UTF-16 units) and `{type:'ghostCancel', id}`; page function `window.wakilGhostResolve(id, textOrNull)`; renderer `var onGhost: ((String, Int, String, Int) -> Void)?`, `var onGhostCancel: ((Int) -> Void)?`, `func resolveGhost(id: Int, text: String?)`; WakilKit `public func ghostCaret(text: String, utf16Offset: Int) -> String.Index?` (pure).

- [ ] **Step 1: Write the failing test** `GhostBridgeTests.swift`: `ghostCaret(text: "a = \"🙂\"\nb.", utf16Offset: 11)` is `text.endIndex`; an offset inside the emoji's surrogate pair returns nil; an offset past the end returns nil; `ghostCaret(text: "", utf16Offset: 0) == "".startIndex`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && ../scripts/swift-test.sh --filter GhostBridgeTests`
Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `GhostBridge.swift`: `ghostCaret` via `String.Index(utf16Offset:in:)` guarded by `samePosition(in: text.unicodeScalars)`.
  - `monaco-host.html`: set `inlineSuggest: { enabled: true, mode: 'subword' }` on `ed`, add the `.ghost` colour (`.monaco-editor .ghost-text-decoration, .monaco-editor .ghost-text-decoration-preview { color: rgba(232,236,246,0.34) !important; }`), and register one provider for every language:

```js
    // 3b-viii: ghost-text. Swift owns the debounce, the model and the clean-up; the page asks
    // and draws. A resolve for an id that is no longer pending is ignored, so a stale reply never
    // lands over newer typing. Tab accepts, ⌘→ a word, Esc dismisses — Monaco's own keys.
    let ghostSeq = 0;
    const ghostPending = new Map();
    window.wakilGhostResolve = function (id, text) {
      const p = ghostPending.get(id);
      if (!p) return;
      ghostPending.delete(id);
      p(text);
    };
    monaco.languages.registerInlineCompletionsProvider({ pattern: '**' }, {
      provideInlineCompletions: function (model, position, context, token) {
        if (model !== ed.getModel() || ed.getOption(monaco.editor.EditorOption.readOnly)) return { items: [] };
        const key = keyOfModel(model);
        if (!key) return { items: [] };
        const id = ++ghostSeq;
        const offset = model.getOffsetAt(position);
        return new Promise(function (resolve) {
          ghostPending.set(id, function (text) {
            resolve({ items: text ? [{ insertText: text, range: new monaco.Range(position.lineNumber, position.column, position.lineNumber, position.column) }] : [] });
          });
          token.onCancellationRequested(function () {
            if (ghostPending.delete(id)) { post({ type: 'ghostCancel', id: id }); resolve({ items: [] }); }
          });
          post({ type: 'ghost', key: key, id: id, text: model.getValue(), offset: offset });
        });
      },
      freeInlineCompletions: function () {}
    });
```

  `keyOfModel` is the page's existing reverse lookup from a model to its tab key; if none exists, add one beside the map that holds a model per key.
  - The pending pulse: when a `ghost` request is still unresolved after 400 ms, add a decoration with class `ghost-pending` at the caret (a 2 px dot pulsing in `rgba(232,236,246,0.34)`, CSS `@keyframes`), removed on resolve or cancel.
  - `MonacoEditorRenderer.receive`: `case "ghost"` → `onGhost?(key, id, text, offset)`; `case "ghostCancel"` → `onGhostCancel?(id)`. `resolveGhost(id:text:)` runs `wakilGhostResolve(<id>, <JSON string or null>)` through `run`, encoding the text with `JSONSerialization` (fragments allowed) the way the renderer already encodes strings for the page.
  - `EditorHost.start`: hand `onGhost` to a closure the view provides — `ghostAsk: ((String, Int, String, Int) async -> String?)?` — that maps the key to the tab's path via `subjects`, builds `ghostRequest(text:caret:path:language: editorLanguage(forPath:), schema: await model.ghostSchema())`, awaits `model.ghostSuggestion(pane:request:)`, then calls `renderer.resolveGhost(id:text:)`. `onGhostCancel` calls `model.ghostCancel(pane:)` and resolves nothing (the page already did). When `model.ghostTextEnabled` is false, resolve with nil at once.
  - `Canvas.swift`: pass those closures from the window model into `EditorPane` as it passes `showIgnored`.

- [ ] **Step 4: Run tests, build, and see it.**

Run: `cd app && ../scripts/swift-test.sh --filter GhostBridgeTests` → PASS. Then `make build`. Start a stub `/infill` (`python3 -I` one-liner answering `{"content":"ConfirmedAt = time.Now()"}` on 127.0.0.1:8012, in `.scratch/3b-viii/`), set the org's quick provider to it with `./bin/wakil provider add stub --kind local --base-url http://127.0.0.1:8012` and `update_org`, open a `.go` file, type `b.` and pause: the ghost appears, Tab accepts it as one undo step, Esc drops it. Delete the stub script after.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/monaco-host.html app/Sources/WakilApp/MonacoEditorRenderer.swift app/Sources/WakilApp/EditorPane.swift app/Sources/WakilApp/Canvas.swift app/Sources/WakilKit/Editor/GhostBridge.swift app/Tests/WakilKitTests/GhostBridgeTests.swift
git commit -m "Editor: AI ghost-text through Monaco's inline completions"
```

---

### Task 9: WakilApp — ghost-text in the DB query line

**Files:**
- Create: `app/Sources/WakilKit/Query/QueryLineGhost.swift`
- Modify: `app/Sources/WakilApp/QueryLineEditor.swift` (`doCommandBy` ~L185, text change, caret moves, drawing)
- Modify: `app/Sources/WakilApp/DBPane.swift` (hand the window model's ghost closures to the query line)
- Test: `app/Tests/WakilKitTests/QueryLineGhostTests.swift`

**Interfaces:**
- Consumes: Task 6's `ghostRequest`, Task 7's `WindowModel` ghost API.
- Produces (pure, WakilKit):

```swift
public enum QueryLineGhostKey: Equatable { case accept, leaveLine, dismiss, cancelRead, passThrough }
public func queryLineGhostKey(_ key: QueryLineKey, ghostShowing: Bool, readRunning: Bool) -> QueryLineGhostKey
public enum QueryLineKey { case tab, escape, returnKey }
public func queryLineAsksForGhost(text: String, caret: String.Index) -> Bool   // Ruling R2: rest of the line is whitespace
```

- [ ] **Step 1: Write the failing tests:**

```swift
@Suite struct QueryLineGhostTests {
    @Test func tabAcceptsOnlyWhileAGhostShows() {
        #expect(queryLineGhostKey(.tab, ghostShowing: true, readRunning: false) == .accept)
    }
    @Test func tabWithoutSuggestionLeavesLine() {
        #expect(queryLineGhostKey(.tab, ghostShowing: false, readRunning: false) == .leaveLine)
    }
    @Test func escapeDismissesThenCancelsThenLeaves() {
        #expect(queryLineGhostKey(.escape, ghostShowing: true, readRunning: true) == .dismiss)
        #expect(queryLineGhostKey(.escape, ghostShowing: false, readRunning: true) == .cancelRead)
        #expect(queryLineGhostKey(.escape, ghostShowing: false, readRunning: false) == .leaveLine)
    }
    @Test func returnNeverAccepts() {
        #expect(queryLineGhostKey(.returnKey, ghostShowing: true, readRunning: false) == .passThrough)
    }
    @Test func asksOnlyAtTheEndOfALine() {
        let t = "SELECT * FROM bookings WHERE \nLIMIT 10"
        #expect(queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 29)))
        #expect(!queryLineAsksForGhost(text: t, caret: t.index(t.startIndex, offsetBy: 7)))
        #expect(queryLineAsksForGhost(text: "SELECT ", caret: "SELECT ".endIndex))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter QueryLineGhostTests`
Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `QueryLineGhost.swift`: the two pure functions.
  - `QueryLineEditor`: hold `ghost: String?` and a request `Task`. On every text change or selection change: clear the ghost, cancel the task, and when `queryLineAsksForGhost` holds and the line is enabled, start a task that builds `ghostRequest(text:caret:path: "query.sql", language: "sql", schema: await ghostSchema())`, awaits the pane's `ghostAsk`, and sets `ghost` if the text and caret are unchanged. Draw it in the text view's `draw(_:)` override after `super`: at the caret's glyph rect (`firstRect(forCharacterRange:actualRange:)` converted to view coordinates), the ghost string in the view's font and `NSColor(red: 232/255, green: 236/255, blue: 246/255, alpha: 0.34)`, first line only beside the caret, further lines below at the line height. Never insert it into the text storage. `needsDisplay = true` on change.
  - `doCommandBy`: route `insertTab` and `cancelOperation` through `queryLineGhostKey`. `.accept` inserts the ghost with `insertText(_:replacementRange:)` at the selection (one undo group, reported like typing) and clears it; `.dismiss` clears it and redraws; `.cancelRead` and `.leaveLine` keep today's behaviour. Return is unchanged.
  - Pending pulse: after 400 ms without a reply, draw a 2 px dot at the caret pulsing (a `Timer` toggling alpha), until the reply or a cancel.
  - `DBPane`: pass `ghostAsk` / `ghostSchema` from the window model as the editor does.

- [ ] **Step 4: Run tests, build, and see it.**

Run: `cd app && ../scripts/swift-test.sh --filter QueryLineGhostTests` → PASS; `make build`; with the stub from Task 8 answering `{"content":"status = 'confirmed'"}`, type `SELECT * FROM bookings WHERE ` in a DB pane and pause: the ghost shows; Tab accepts; Tab in an empty line leaves it; Esc drops the ghost, and a second Esc leaves the line.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Query/QueryLineGhost.swift app/Sources/WakilApp/QueryLineEditor.swift app/Sources/WakilApp/DBPane.swift app/Tests/WakilKitTests/QueryLineGhostTests.swift
git commit -m "DB pane: AI ghost-text in the query line"
```

---

### Task 10: WakilApp — Settings: Quick tasks, local providers, Ghost-text

**Files:**
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (org form ~L420-690: a `quickProvider` picker beside the speech picker; provider rows)
- Modify: `app/Sources/WakilApp/EditorSettingsForms.swift` (~L168: a `Ghost-text` On/Off beside `Show ignored files`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`OrganisationField` gains `.quickProvider`; the save path forwards it)
- Create: `app/Sources/WakilKit/Panes/QuickTaskSettings.swift`
- Test: `app/Tests/WakilKitTests/QuickTaskSettingsTests.swift`

**Interfaces:**
- Consumes: `SettingsTree` (Task 7), `ctx_update_org`, `ctx_set_local_provider`, `ctx_set_editor_settings`, `WindowModel.quickTaskErrors()`.
- Produces (pure, WakilKit): `public func quickTaskOptions(_ tree: SettingsTree) -> [(id: String, label: String)]` — first `("", "Same as agent")`, then each provider that serves anything, labelled by `label` or id; `public func quickTaskNote(_ tree: SettingsTree, activeProvider: String) -> String?` — `"Ghost-text needs a Claude or local provider"` when neither the chosen quick provider nor the active one serves `infill`, else nil; `public func localProviderStatus(id: String, errors: [String: String]) -> String` — the error whole, or `"reachable"`.

- [ ] **Step 1: Write the failing tests** for the three functions: options list a `local` and a `claude-code` provider and omit a `codex` one; the note appears for an org whose only provider is `codex` and is nil once a local provider with `serves: ["infill"]` is chosen; the status returns the error string whole (a 300-character error is returned unchanged) or `"reachable"`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app && ../scripts/swift-test.sh --filter QuickTaskSettingsTests`
Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `QuickTaskSettings.swift`: the three functions.
  - Org form: a `Quick tasks` row drawn like the speech-engine row (~L637-680), options from `quickTaskOptions`, saving `.quickProvider` through the same `save(_:tree:)` path (`OrganisationField.quickProvider` maps to `tree.org.quickProvider` and the `quickProvider` key of `ctx_update_org`); accessibility ids `settings.org.quickProvider.<id or "same">` and `settings.org.quickProvider.note` for `quickTaskNote`.
  - Provider rows: for `kind == "local"`, a `URL` text field and `Serves` checkboxes (`Code completion` → `infill`, `Instructions` → `respond`), each saving on change or focus loss (Interaction Rule 2) through `ctx_set_local_provider` with the row's id, label, URL and the ticked operations; a status line from `localProviderStatus` (async from `quickTaskErrors()`, refreshed when the pane appears and after each save); a refusal shown whole under the field as other rows do. An **Add local model** control at the end of the providers list opens a new focused URL field (Rule 3) with id `local`, or `local-2`, … the first unused.
  - Editor form: `Ghost-text` On/Off, saving `["ghostText": .bool(option == "On")]`, ids `settings.editor.ghostText.<On|Off>` and `.refusal`.

- [ ] **Step 4: Run tests, build, and see it.**

Run: `cd app && ../scripts/swift-test.sh --filter QuickTaskSettingsTests` → PASS; `make build`; open Settings: add a local model at `http://127.0.0.1:8012`, pick it in Quick tasks, stop the stub and see the error whole on its row; switch Ghost-text off and see no suggestion in the editor.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/SettingsPane.swift app/Sources/WakilApp/EditorSettingsForms.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/Panes/QuickTaskSettings.swift app/Tests/WakilKitTests/QuickTaskSettingsTests.swift
git commit -m "Settings: quick-tasks provider, local models and the ghost-text switch"
```

---

### Task 11: Charter, docs and the whole suite

**Files:**
- Modify: `docs/wakil/decisions.md` (Decision 16 amendment; Decision 14 clarification; new Decision 42 after the last entry)
- Modify: `docs/wakil/design-language.md` (§11 autocomplete tier 3, ~L512-517)
- Modify: `PRODUCT.md` (~L69)
- Modify: `docs/architecture/README.md` and `CONTRIBUTING.md` (where the Harness and Editor sections list files: add `QuickModel`, `QuickTasks`, `GhostText`)
- Create: `docs/wakil/phase-3b-viii-acceptance.md` (the walk runbook, following `phase-3b-vii-acceptance.md`'s shape)

- [ ] **Step 1: Write the charter text.**
  - Decision 16, appended: *Amended 2026-10-19 (3b-viii):* the harness axis has two seams — `AgentHarness` for sessions and `QuickModel` for one-shot quick tasks, with two operations, `infill` and `respond`. `ClaudeCodeQuickModel` runs a warm `claude` session through `buildLaunch`'s whitelist; `LocalEndpointQuickModel` speaks a llama.cpp-style `/infill` and the OpenAI chat shape.
  - Decision 14, appended: *Clarified 2026-10-19 (3b-viii):* ghost-text is reactive — it answers the operator's own typing, never moves focus, makes no sound, and is gone on the next keystroke.
  - **Decision 42. Quick tasks run on one provider per org, and a local model is the operator's to run.** *(2026-10-19, operator, during the 3b-viii design.)* The org's `quickProvider`, else its active provider; each call routes to the first of the two that serves its operation, and an unreachable endpoint falls back once. A `local` provider is a URL plus what it serves (`infill` by default); Wakil installs, starts and downloads nothing. A new quick task is a caller of `QuickTasks` — a prompt and a parser — and adds no harness work. Measured 2026-10-19 on an M5 Pro: one-shot `claude -p` ~4.5 s, a warm session 1.0–1.8 s, Apple's on-device model fast but poor, `llama-server` with Qwen2.5-Coder 1.5B 30–210 ms. The Anthropic API with the subscription token stays excluded (§5). **Next quick tasks:** the ⌘K fast path (must amend Decision 10 first), then agent status lines. **Candidates, unscheduled:** shrinking what the agent reads (lossy; opt-in at most), session titles and commit drafts, voice cleanup. **Never a quick task:** the write gate, statement classification, anything touching credentials. *Reverse if:* quick tasks on the default provider cost enough quota to crowd out agent turns — then ghost-text defaults off without a local provider.
  - design-language §11 tier 3: "AI ghost-text — runs on the org's quick-tasks provider: its Claude account by default, a local model when the operator adds one (Decision 42). Context: the file and the active environment's schema."
  - PRODUCT.md L69: same change in one sentence.
  - The runbook: the checks of the spec's "What the operator gets", each with exact steps against a real `llama-server --fim-qwen-1.5b-default --port 8012` and against Claude, and a Walked column.

- [ ] **Step 2: Run the whole suite**

Run: `go test ./...` then `make app-test` (after `make build`), then `make test`.
Expected: all PASS except the known `docs-check` failure on the north-star word count (4025/4000, pre-existing on main); record any other failure with its output and fix it before continuing. Do not touch `north-star.md`.

- [ ] **Step 3: Commit**

```bash
git add docs PRODUCT.md CONTRIBUTING.md
git commit -m "Charter: Decision 42 (quick tasks), Decisions 14 and 16 amended, 3b-viii runbook"
```
