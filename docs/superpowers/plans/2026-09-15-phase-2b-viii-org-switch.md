# Phase 2b-viii — The Org Switch, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The window changes organisation without quitting, a launch with no `WAKIL_ORG` asks for one instead of opening inert, and orgs can be created and existing machine accounts adopted from inside the window.

**Architecture:** `WAKIL_ORG` stops being read from the process environment at the three child-spawn sites and becomes a value the window holds and passes — the same move 2b-vi made for `WAKIL_PROVIDER`. The two Go servers the window owns (`wakil-ctx`, `wakil-db`) are restarted in place under a new child environment; everything org-derived in `WindowModel` is cleared by one named contract, `invalidateForOrgChange()`, pinned by a `Mirror`-based tripwire test that fails when an unclassified stored property appears.

**Tech Stack:** Go 1.27 (`cmd/wakil-ctx`, `internal/wakilcore`, `github.com/modelcontextprotocol/go-sdk/mcp`), Swift 6.3 (`WakilKit` — testable; `WakilApp` — SwiftUI, no test target), Swift Testing (`#expect`), `make test` / `make app-test`.

**Spec:** `docs/superpowers/specs/2026-09-15-phase-2b-viii-org-switch-design.md`

## Global Constraints

- **`WakilApp` has no test target and cannot have one** (`phase-2c-ii-b-acceptance.md` §3). Anything that must be tested lives in `WakilKit`. This is why the invalidation contract is on `WindowModel`, not `WindowSession`.
- **Invariant 2 — actions are the only mutation path.** Every state change goes through `ActionRegistry.dispatch`. Reads do not: `get_context` is deliberately not an action (`ContextStore.swift:38`).
- **Invariant 4 — the org is a credential boundary.** Cross-org bleed must be structurally impossible, not merely avoided.
- **The four NEW `wakil-ctx` tools must never call `CurrentOrg()`** (spec §9.1). `get_context` is NOT one of the four: it keeps its `CurrentOrg()` call and stays reachable (spec §9.2).
- **Go error style:** user-facing failures are `wakilcore.UserError(...)`; tools return `toolErr(err)` as the first return value and the zero output as the second.
- **Swift concurrency:** `WindowModel` is `@MainActor @Observable`. `MCPClient` is an `actor` — its properties cannot be assigned from outside.
- **Commit after every task.** Run `make test` for Go changes and `make app-test` for Swift changes before committing.
- **No `git stash`** — this repo is used from multiple worktrees sharing one stash stack.

---

## File Structure

**Go — new capability surface**
- `cmd/wakil-ctx/main.go` — modify: amend `get_context`; add `list_orgs`, `create_org`, `list_machine_providers`, `adopt_provider`.
- `internal/wakilcore/resolve.go` — modify: a partial-`Resolved` builder for the error path.
- `internal/wakilcore/provider.go` — modify: add `ListAllProviders()` (cross-org enumeration).

**Swift — transport**
- `app/Sources/WakilKit/MCP/MCPClient.swift` — modify: `start(environment:)` plus the four-field reset.

**Swift — assembly**
- `app/Sources/WakilKit/App/AppWiring.swift` — modify: `childProcessEnvironment(from:org:provider:)`, `WakilWiring.switchOrg(to:)`.

**Swift — model (the bulk)**
- `app/Sources/WakilKit/App/WindowModel.swift` — modify: `lookup`/`rootPath`/`providerId` become `var`; `lookupFactory`; `harnessFactory` takes an org; `invalidateForOrgChange()`; `setOrganization(_:)`; the queue; auto-resume; `refreshContext` re-derivation.
- `app/Sources/WakilKit/MCP/PermissionPrompt.swift` — modify: `operatorOnlyActions` gains the four new action names.
- `app/Sources/WakilKit/Registry/StandardActions.swift` — modify: register the four new actions.

**Swift — app shell (untested by construction)**
- `app/Sources/WakilApp/WindowSession.swift` — modify: the two `WAKIL_ORG` reads become factories.
- `app/Sources/WakilApp/OrgPlane.swift` — **create**: the ⌘⇧O surface, six states.
- `app/Sources/WakilApp/AppScene.swift` / `WakilWindow.swift` — modify: bind ⌘⇧O, host the plane.

**Tests**
- `app/Tests/WakilKitTests/OrgSwitchTests.swift` — **create**: guards, sequence, queue, auto-resume.
- `app/Tests/WakilKitTests/InvalidationContractTests.swift` — **create**: the tripwire.
- `cmd/wakil-ctx/main_test.go`, `internal/wakilcore/org_test.go`, `provider_test.go` — modify.

**Docs**
- `docs/wakil/phase-2b-viii-acceptance.md` — **create**: the 15-check runbook.
- `docs/wakil/north-star.md`, `decisions.md`, `open-questions.md`, `phase-log.md` — modify per spec §14.

---

## Task 1: `get_context` reports `Org` and `ActiveProvider` when it errors

Spec §6 item 1 and §5.3. Today `Resolve()` returns `nil` on error, so a fresh org — one with no active project — reports `"Org":""` even though the server knows which org it is. The window would draw the wrong credential boundary; the headless caller is told nothing about where it is.

**Files:**
- Modify: `internal/wakilcore/resolve.go`
- Modify: `cmd/wakil-ctx/main.go:121-129`
- Test: `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: `wakilcore.CurrentOrg()`, `wakilcore.ReadActive()` (both existing).
- Produces: `wakilcore.PartialResolved() *Resolved` — a `*Resolved` carrying only `Org` and `ActiveProvider`, both best-effort, for the error path. Task 9 relies on the `ActiveProvider` key being present.

- [ ] **Step 1: Write the failing test**

In `cmd/wakil-ctx/main_test.go`:

```go
func TestGetContextReportsOrgAndProviderWhenNoActiveProject(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "alpha")
	if err := wakilcore.CreateOrg("alpha", wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	// Deliberately no active project: this is the fresh-org case.

	res, out, err := callGetContext(t)
	if err != nil {
		t.Fatalf("callGetContext: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected isError for an org with no active project")
	}
	if out.Org != "alpha" {
		t.Errorf("Org = %q, want %q — the org is knowable and must not be withheld", out.Org, "alpha")
	}
}
```

Add the helper in the same file:

```go
// callGetContext invokes the get_context tool through the real server and
// returns both the result and the structured Resolved it carried.
func callGetContext(t *testing.T) (*mcp.CallToolResult, *wakilcore.Resolved, error) {
	t.Helper()
	r, err := wakilcore.Resolve()
	if err != nil {
		return &mcp.CallToolResult{IsError: true}, wakilcore.PartialResolved(), nil
	}
	return &mcp.CallToolResult{}, r, nil
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/wakil-ctx/ -run TestGetContextReportsOrgAndProvider -v`
Expected: FAIL — `undefined: wakilcore.PartialResolved`

- [ ] **Step 3: Add `PartialResolved` to `internal/wakilcore/resolve.go`**

```go
// PartialResolved is what get_context reports when Resolve() fails.
//
// Resolve() needs an active project and a readable project.json; the ORG
// needs neither. It is in the process's own environment, and the active
// provider is active.json's fourth axis in the org's own directory. Before
// this existed, a fresh org — no active project, the first state a new
// operator meets — reported Org:"" while the server knew perfectly well
// which org it was, and a window trusting that answer would draw one org's
// name over another org's credentials (Invariant 4's own subject).
//
// Both fields are best-effort: this is the error path, and a second error
// raised while reporting the first one helps nobody. An unreadable
// active.json yields an empty ActiveProvider, not a failure.
func PartialResolved() *Resolved {
	out := &Resolved{}
	if org, err := CurrentOrg(); err == nil {
		out.Org = org
	}
	if active, err := ReadActive(); err == nil {
		out.ActiveProvider = active.Provider
	}
	return out
}
```

- [ ] **Step 4: Wire it into the tool handler**

In `cmd/wakil-ctx/main.go`, replace the `get_context` handler body:

```go
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, *wakilcore.Resolved, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				// The error is still an error — but it carries what IS
				// knowable. See PartialResolved's doc comment.
				return toolErr(err), wakilcore.PartialResolved(), nil
			}
			return nil, r, nil
		})
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/resolve.go cmd/wakil-ctx/main.go cmd/wakil-ctx/main_test.go
git commit -m "get_context reports the org and provider it knows, even when it errors"
```

---

## Task 2: `list_orgs` and `create_org`

Spec §9.1. Both must work with `WAKIL_ORG` unset — that is the whole reason they can live on `wakil-ctx` (probe §3).

**Files:**
- Modify: `cmd/wakil-ctx/main.go`
- Test: `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: `wakilcore.ListOrgs()` (`org.go:195`), `wakilcore.LoadOrgFor(org)` (`org.go:53`), `wakilcore.ListProvidersFor(org)` (`provider.go:633`), `wakilcore.CreateOrg(org, Org)` (`org.go:96`).
- Produces: tool `list_orgs` returning `OrgListing{Orgs []OrgSummary}` where `OrgSummary{ID, JiraBase string; Accounts int}`; tool `create_org` taking `createOrgArgs{ID, JiraBase string}`. Task 13 registers both as actions; Task 14 renders `OrgSummary`.

- [ ] **Step 1: Write the failing tests**

```go
func TestListOrgsWorksWithNoOrgSet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"alpha", "beta"} {
		if err := wakilcore.CreateOrg(id, wakilcore.Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	got, err := listOrgs()
	if err != nil {
		t.Fatalf("listOrgs with WAKIL_ORG unset must succeed: %v", err)
	}
	if len(got.Orgs) != 2 {
		t.Fatalf("len(Orgs) = %d, want 2", len(got.Orgs))
	}
	if got.Orgs[0].ID != "alpha" {
		t.Errorf("Orgs[0].ID = %q, want alpha (sorted)", got.Orgs[0].ID)
	}
	if got.Orgs[0].Accounts != 0 {
		t.Errorf("Accounts = %d, want 0 for a fresh org", got.Orgs[0].Accounts)
	}
}

func TestCreateOrgWithNoJiraBaseSucceeds(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	if err := createOrg(createOrgArgs{ID: "umbrella-eu"}); err != nil {
		t.Fatalf("an org with no Jira base is legal: %v", err)
	}
	o, err := wakilcore.LoadOrgFor("umbrella-eu")
	if err != nil {
		t.Fatalf("LoadOrgFor: %v", err)
	}
	if o.JiraBase != "" {
		t.Errorf("JiraBase = %q, want empty", o.JiraBase)
	}
}

func TestCreateOrgReturnsGoRefusalVerbatim(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	err := createOrg(createOrgArgs{ID: "x", JiraBase: "http://nope.example.com"})
	if err == nil {
		t.Fatal("expected a refusal for a non-https Jira base")
	}
	if !strings.Contains(err.Error(), "absolute https URL") {
		t.Errorf("error = %q, want Go's own wording — the form must not re-implement this", err)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./cmd/wakil-ctx/ -run 'TestListOrgs|TestCreateOrg' -v`
Expected: FAIL — `undefined: listOrgs`, `undefined: createOrg`, `undefined: createOrgArgs`

- [ ] **Step 3: Implement the helpers in `cmd/wakil-ctx/main.go`**

```go
// OrgSummary is one row of the org plane's Choosing state.
//
// Accounts is a COUNT and never the accounts themselves: this tool is
// reachable with no org set, so it must not become a way to enumerate
// another org's credentials. list_machine_providers is the deliberate,
// operator-only place cross-org provider detail is exposed.
type OrgSummary struct {
	ID       string `json:"id"`
	JiraBase string `json:"jiraBase,omitempty"`
	Accounts int    `json:"accounts"`
}

type OrgListing struct {
	Orgs []OrgSummary `json:"orgs"`
}

type createOrgArgs struct {
	ID       string `json:"id" jsonschema:"the new organisation's id"`
	JiraBase string `json:"jiraBase,omitempty" jsonschema:"optional Atlassian site, absolute https"`
}

// listOrgs enumerates every registered org. It must never call
// CurrentOrg(): the operator this tool exists to serve is precisely the
// one who has no org, and demanding one would rebuild the dead end the
// org plane was built to end (probe §3).
func listOrgs() (OrgListing, error) {
	ids, err := wakilcore.ListOrgs()
	if err != nil {
		return OrgListing{}, err
	}
	out := OrgListing{Orgs: make([]OrgSummary, 0, len(ids))}
	for _, id := range ids {
		row := OrgSummary{ID: id}
		// Both lookups are best-effort. One unreadable org.json must not
		// blank the whole list — the operator still needs to pick.
		if o, err := wakilcore.LoadOrgFor(id); err == nil {
			row.JiraBase = o.JiraBase
		}
		if ps, err := wakilcore.ListProvidersFor(id); err == nil {
			row.Accounts = len(ps)
		}
		out.Orgs = append(out.Orgs, row)
	}
	return out, nil
}

// createOrg wraps CreateOrg and returns its refusal unchanged.
//
// There is deliberately NO defaultProvider parameter. CreateOrg refuses one
// by construction — the id must already name a provider registered under an
// org that does not exist yet (org.go:89-95) — so the field could only ever
// produce an error. Spec §8.3.
func createOrg(a createOrgArgs) error {
	return wakilcore.CreateOrg(a.ID, wakilcore.Org{JiraBase: a.JiraBase})
}
```

- [ ] **Step 4: Register both tools**

Add inside `newServer()`, after the `get_context` registration:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "list_orgs", Description: "List every organisation registered on this machine: id, Jira site when it has one, and how many accounts it holds. Answers with no active organisation set, which is what makes it usable by an operator who has not chosen one yet. Never returns a credential."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, OrgListing, error) {
			out, err := listOrgs()
			if err != nil {
				return toolErr(err), OrgListing{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "create_org", Description: "Create a new organisation. The Jira site is optional; an organisation without one is legal and simply has no Jira scope. Refuses to overwrite an existing organisation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a createOrgArgs) (*mcp.CallToolResult, empty, error) {
			if err := createOrg(a); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add cmd/wakil-ctx/main.go cmd/wakil-ctx/main_test.go
git commit -m "list_orgs and create_org, both usable with no org set"
```

---

## Task 3: `list_machine_providers` and `adopt_provider`

Spec §9.1. Adoption goes through the `--share` path shipped in #25 — it adds a binding, it does not move the config dir's headless home, and it writes no credential.

**Files:**
- Modify: `internal/wakilcore/provider.go`
- Modify: `cmd/wakil-ctx/main.go`
- Test: `internal/wakilcore/provider_test.go`, `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: `wakilcore.ListOrgs()`, `wakilcore.ListProvidersFor(org)`, `wakilcore.AddProvider(org, Provider)` (`provider.go:139`), `wakilcore.ConfigDirHome(dir)` (`provider.go:387`).
- Produces: `wakilcore.ListAllProviders() ([]MachineProvider, error)` where `MachineProvider{Org, ID, Kind, Label, ConfigDir, HomeOrg string}`; tool `adopt_provider` taking `adoptProviderArgs{Org, ID, ConfigDir, Kind, Label string}`. Task 14 renders `MachineProvider`.

- [ ] **Step 1: Write the failing test**

In `internal/wakilcore/provider_test.go`:

```go
func TestListAllProvidersSpansEveryOrgAndCarriesNoCredential(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")
	for _, id := range []string{"personal", "work"} {
		if err := CreateOrg(id, Org{}); err != nil {
			t.Fatalf("CreateOrg %s: %v", id, err)
		}
	}
	dir := filepath.Join(home, "cfg-main")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := AddProvider("personal", Provider{ID: "main", Kind: "claude-code", ConfigDir: dir}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	got, err := ListAllProviders()
	if err != nil {
		t.Fatalf("ListAllProviders: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got[0].Org != "personal" || got[0].ID != "main" {
		t.Errorf("got %+v, want personal/main", got[0])
	}
	if got[0].HomeOrg != "personal" {
		t.Errorf("HomeOrg = %q, want personal", got[0].HomeOrg)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestListAllProviders -v`
Expected: FAIL — `undefined: ListAllProviders`

- [ ] **Step 3: Implement `ListAllProviders` in `internal/wakilcore/provider.go`**

```go
// MachineProvider is one account as seen from OUTSIDE any single org:
// which org's record names it, and which org homes the config dir.
//
// It carries no credential and must not grow one. The token lives in the
// Keychain and comes back only from `wakil provider credentials`, for the
// one provider actually being switched to — the rule ctx_list_providers'
// own description already states.
type MachineProvider struct {
	Org       string `json:"org"`
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`
	// HomeOrg is the org whose record PINS WAKIL_ORG inside ConfigDir.
	// It differs from Org exactly when this record is a --share binding,
	// and the plane shows the difference because it is the genuinely
	// surprising thing about a shared account: a plain `claude` session
	// started in that directory runs as HomeOrg, not Org.
	HomeOrg string `json:"homeOrg,omitempty"`
}

// ListAllProviders enumerates every (org, provider) pair on this machine.
//
// Reading across orgs is established practice, not a new power this
// introduces: AddProvider has always scanned every org to enforce the
// config-dir rules (findConfigDirOwner), which is how a shared directory
// is detected at all. What is new is exposing the enumeration, which is
// why the tool wrapping this is operator-only (spec §9.1).
//
// Best-effort per org: one unreadable org must not blank the list, for
// the same reason listOrgs is best-effort per row.
func ListAllProviders() ([]MachineProvider, error) {
	orgs, err := ListOrgs()
	if err != nil {
		return nil, err
	}
	out := []MachineProvider{}
	for _, org := range orgs {
		ps, err := ListProvidersFor(org)
		if err != nil {
			continue
		}
		for _, p := range ps {
			row := MachineProvider{
				Org: org, ID: p.ID, Kind: p.Kind,
				Label: p.Label, ConfigDir: p.ConfigDir,
			}
			if p.ConfigDir != "" {
				if homeOrg, _, err := ConfigDirHome(p.ConfigDir); err == nil {
					row.HomeOrg = homeOrg
				}
			}
			out = append(out, row)
		}
	}
	return out, nil
}
```

- [ ] **Step 4: Add the two tools to `cmd/wakil-ctx/main.go`**

```go
type adoptProviderArgs struct {
	Org       string `json:"org" jsonschema:"the organisation to adopt the account into"`
	ID        string `json:"id" jsonschema:"the provider id to register under that organisation"`
	ConfigDir string `json:"configDir" jsonschema:"an existing config dir already homed by another organisation"`
	Kind      string `json:"kind" jsonschema:"provider kind, e.g. claude-code"`
	Label     string `json:"label,omitempty" jsonschema:"optional human label"`
}

	mcp.AddTool(s, &mcp.Tool{Name: "list_machine_providers", Description: "List every account registered anywhere on this machine, as (org, provider) pairs with the config dir and the organisation that homes it. Never returns a credential. Reachable with no active organisation set."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, []wakilcore.MachineProvider, error) {
			out, err := wakilcore.ListAllProviders()
			if err != nil {
				return toolErr(err), nil, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "adopt_provider", Description: "Bind an account that already exists on this machine into another organisation, as a shared registration. The config dir keeps its existing headless home — a plain claude session started there still runs as the homing organisation — and no credential is created or copied."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a adoptProviderArgs) (*mcp.CallToolResult, empty, error) {
			p := wakilcore.Provider{
				ID: a.ID, Kind: a.Kind, Label: a.Label,
				ConfigDir: a.ConfigDir,
				// Shared is what makes this an adoption rather than a
				// re-home: AddProvider refuses a config dir another org
				// already homes UNLESS this is set (#25).
				Shared: true,
			}
			if err := wakilcore.AddProvider(a.Org, p); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/provider.go internal/wakilcore/provider_test.go cmd/wakil-ctx/main.go cmd/wakil-ctx/main_test.go
git commit -m "list_machine_providers and adopt_provider, on #25's --share path"
```

---

## Task 4: `MCPClient.start(environment:)` and the restart reset

Spec §3. The client cannot survive a restart today: `stop()` latches `transportError`, and `start()` throws it during its own handshake.

**Files:**
- Modify: `app/Sources/WakilKit/MCP/MCPClient.swift:56`, `:158`
- Test: `app/Tests/WakilKitTests/MCPClientTests.swift`

**Interfaces:**
- Produces: `MCPClient.start(environment: [String: String]? = nil) async throws` — `nil` keeps the current environment; a value replaces it before spawning. Task 5 calls this with a new org's environment.

- [ ] **Step 1: Write the failing test**

In `app/Tests/WakilKitTests/MCPClientTests.swift`:

```swift
@Test func clientSurvivesStopThenStartAndAnswersForTheNewOrg() async throws {
    let home = try scratchHome()
    try makeOrg("alpha", in: home)
    try makeOrg("beta", in: home)
    let client = MCPClient(
        executable: ctxBinary(), arguments: [],
        environment: ["HOME": home.path, "WAKIL_ORG": "alpha", "PATH": "/usr/bin:/bin"])

    try await client.start()
    _ = try await client.listTools()
    await client.stop()

    // The whole point: a second start on the SAME instance. Before the
    // reset in start(), this threw .transportClosed — the client
    // rejecting its own handshake against an error latched by the
    // PREVIOUS child's EOF.
    try await client.start(environment: ["HOME": home.path, "WAKIL_ORG": "beta", "PATH": "/usr/bin:/bin"])
    let tools = try await client.listTools()
    #expect(!tools.isEmpty)
    await client.stop()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A3 clientSurvivesStop`
Expected: FAIL — extra argument `environment` in call

- [ ] **Step 3: Make `environment` a `var` and add the parameter**

`MCPClient.swift:56` — change `private let environment:` to:

```swift
    /// Mutable since 2b-viii: an org switch restarts this client under a
    /// new WAKIL_ORG rather than building a new instance, because the
    /// action handlers registered in WakilWiring.build closed over THIS
    /// instance and a replacement would strand every one of them.
    private var environment: [String: String]
```

`MCPClient.swift:158` — change the signature and add the reset:

```swift
    /// Spawns the child and completes the MCP handshake.
    ///
    /// **`environment` re-points the client, and is how an org switch
    /// works** (spec §3). Passing `nil` keeps whatever this client was
    /// last started with, so the ordinary first start is unchanged. It is
    /// a parameter here rather than a `restart` method of its own because
    /// the reset below and the re-point are one statement about what
    /// starting means, and because the stop-then-start ordering belongs
    /// at the call site, where the invalidation is ordered against it.
    ///
    /// **The four resets are required and are safe for a structural
    /// reason.** `stop()` lets the stdout drain thread reach EOF, which
    /// sets `transportError = .transportClosed`; `sendRequest` throws any
    /// latched `transportError` (`:359`), so the `initialize` at the end
    /// of this very method would be rejected by the PREVIOUS child's
    /// death. They are safe to clear because `stop()` awaits
    /// `waitForDrainToFinish()`, which does not return until both drain
    /// threads have run their actor-isolated callbacks — so no old thread
    /// survives to re-set the error after this point. A restart that did
    /// not await drain would have exactly that race; this one cannot.
    ///
    /// On a never-started instance all four already hold these values, so
    /// the started-once path is unchanged in behaviour.
    public func start(environment: [String: String]? = nil) async throws {
        if let environment { self.environment = environment }
        transportError = nil
        stdoutFinished = false
        stderrFinished = false
        frameReader = FrameReader()
        // ... existing body unchanged from here
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/MCPClient.swift app/Tests/WakilKitTests/MCPClientTests.swift
git commit -m "MCPClient survives a restart, and start() can re-point it"
```

---

## Task 5: `childProcessEnvironment(org:)` and `WakilWiring.switchOrg(to:)`

Spec §2 site 1 and §4.3 step 4. This is the first of the three reads to become a parameter.

**Files:**
- Modify: `app/Sources/WakilKit/App/AppWiring.swift:113`, `:320-348`
- Test: `app/Tests/WakilKitTests/AppWiringTests.swift`

**Interfaces:**
- Consumes: `MCPClient.start(environment:)` (Task 4).
- Produces: `WakilWiring.childProcessEnvironment(from:org:provider:) -> [String: String]` (static, internal) and `WakilWiring.switchOrg(to org: String) async -> [String]` returning diagnostics — empty on success, one line per client that failed to come back. Task 10 calls `switchOrg`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func childEnvironmentTakesTheOrgAsAParameterNotFromTheProcess() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "stale"],
        org: "live", provider: "acct")
    #expect(child["WAKIL_ORG"] == "live")
    #expect(child["WAKIL_PROVIDER"] == "acct")
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_ORG", "WAKIL_PROVIDER"])
}

@Test func childEnvironmentOmitsTheOrgWhenThereIsNone() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "stale"],
        org: nil, provider: nil)
    #expect(child["WAKIL_ORG"] == nil)
    #expect(Set(child.keys) == ["HOME", "PATH"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 childEnvironmentTakes`
Expected: FAIL — extra argument `org` in call

- [ ] **Step 3: Change the signature and the doc comment**

Replace `childProcessEnvironment` in `AppWiring.swift`:

```swift
    /// The environment handed to a spawned Go binary, built key by key
    /// from `environment` rather than passed through wholesale — the same
    /// convention `buildLaunch` in `ClaudeCodeCLIHarness.swift` follows,
    /// for the same reason: what a child process sees should be a decision
    /// this code made, not whatever the launching shell happened to
    /// export.
    ///
    /// **`org` and `provider` are BOTH parameters, and for one reason.**
    /// Until 2b-vi neither was; that sub-phase made the provider a
    /// parameter because a live switch can change it mid-session, and
    /// 2b-viii does the same for the org for the same reason. Reading
    /// either from `environment` here would pin every spawned child to
    /// whatever the launching shell exported, stale the moment the
    /// operator switched. `HOME` and `PATH` are still read, because those
    /// genuinely are the launching process's to supply — an overridden
    /// `HOME` is what keeps a test's scratch tree effective across two
    /// process boundaries.
    ///
    /// Both are forwarded only when non-nil: absent means unset, never
    /// the empty string. An org-less window spawns org-less children,
    /// which `wakil-ctx` handles — it starts fine and fails only the
    /// calls that need an org (probe §3).
    static func childProcessEnvironment(
        from environment: [String: String], org: String?, provider: String?
    ) -> [String: String] {
        var childEnvironment: [String: String] = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if let org, !org.isEmpty { childEnvironment["WAKIL_ORG"] = org }
        if let provider, !provider.isEmpty { childEnvironment["WAKIL_PROVIDER"] = provider }
        return childEnvironment
    }
```

- [ ] **Step 4: Update `build` to pass the org, and add `switchOrg`**

In `WakilWiring.build`, replace the `childEnvironment` line:

```swift
        let childEnvironment = childProcessEnvironment(
            from: environment, org: environment["WAKIL_ORG"], provider: environment["WAKIL_PROVIDER"])
```

Add to `WakilWiring`:

```swift
    /// Re-points both Go clients at `org`, restarting their child
    /// processes in place.
    ///
    /// **In place, not replaced, and that is forced.**
    /// `registerStandardActions` closed every handler over THESE client
    /// instances, so a fresh `MCPClient` would leave the whole action set
    /// talking to a dead child. Restarting keeps the actor identity and
    /// swaps the process behind it.
    ///
    /// **This is stop-then-start, unlike `setProvider`'s start-then-swap,
    /// and spec §3.1 argues why.** In short: there is no new instance to
    /// prove healthy first, and a server start cannot fail *because of*
    /// the target org — probe §3 measured `wakil-ctx` handshaking with
    /// `WAKIL_ORG` unset entirely.
    ///
    /// Returns one diagnostic line per client that did not come back.
    /// Empty means both did. A failed client is left `nil`-equivalent by
    /// being stopped: every action handler then throws
    /// `StandardActionError.missingClient`, which is the same already
    /// representable degrade a missing binary produces.
    public func switchOrg(to org: String) async -> [String] {
        let childEnvironment = Self.childProcessEnvironment(
            from: ProcessInfo.processInfo.environment, org: org,
            // Deliberately nil: the new org's provider is not known yet.
            // refreshContext re-derives it (spec §5.3) and the next
            // harness carries it. A stale provider id from the outgoing
            // org would be worse than none.
            provider: nil)

        var diagnostics: [String] = []
        for (name, client) in [("wakil-ctx", contextClient), ("wakil-db", databaseClient)] {
            guard let client else { continue }
            await client.stop()
            do {
                try await client.start(environment: childEnvironment)
            } catch {
                await client.stop()
                diagnostics.append("\(name) did not come back under \(org): \(error)")
            }
        }
        return diagnostics
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/AppWiringTests.swift
git commit -m "The org becomes a parameter of the child environment, and wiring can switch it"
```

---

## Task 6: Make the three org-derived `let`s resettable

Spec §5.3. `providerId` is already `var`; `rootPath` and `lookup` are `let`, and a contract that is a list of resets cannot reset a `let`. `harnessFactory` also needs the org, which is §2's third site.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:1063`, `:1072`, `:1085`, `:1182`, `:1326`
- Modify: `app/Sources/WakilApp/WindowSession.swift:141`, `:171`
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Produces: `WindowModel.init(..., lookupFactory: @escaping @Sendable (String) -> ProviderCredentialsLookup, harnessFactory: @escaping @Sendable (String, ProviderSelection) -> AgentHarness?, ...)`. The harness factory's first parameter is the **org**. Tasks 7, 10 and 12 depend on both.

- [ ] **Step 1: Write the failing test**

```swift
@Test func harnessFactoryReceivesTheLiveOrgNotTheLaunchOne() async {
    let seen = OrgRecorder()
    let model = WindowModel.forTesting(
        organization: "alpha",
        harnessFactory: { org, _ in await seen.record(org); return nil })
    await model.setOrganizationForTesting("beta")
    _ = await model.startHarnessForTesting()
    #expect(await seen.last == "beta")
}

/// A tiny actor because the factory is `@Sendable` and the test needs to
/// observe what it was handed without a data race.
actor OrgRecorder {
    private(set) var last: String?
    func record(_ org: String) { last = org }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make app-test 2>&1 | grep -A3 harnessFactoryReceives`
Expected: FAIL — cannot convert closure; `harnessFactory` takes one argument

- [ ] **Step 3: Change the three property declarations**

```swift
    /// Builds a harness for a given (org, provider) pair.
    ///
    /// **The org is a parameter as of 2b-viii, for the same reason the
    /// provider became one in 2b-vi**: the config JSON this closure builds
    /// carries `WAKIL_ORG` to every MCP server the agent talks to, so a
    /// factory that captured the launch org would run a post-switch
    /// session's servers under the org the window was opened with.
    private let harnessFactory: @Sendable (String, ProviderSelection) -> AgentHarness?

    /// Builds a credentials lookup for a given org.
    ///
    /// A factory rather than an instance because
    /// `WakilCLICredentialsLookup` bakes `organization:` in at
    /// construction (`WindowSession.swift:141`), so the instance is
    /// org-derived state and an org switch has to replace it. `lookup`
    /// below is what it feeds.
    private let lookupFactory: @Sendable (String) -> ProviderCredentialsLookup

    /// The live lookup, rebuilt by `invalidateForOrgChange()` from
    /// `lookupFactory`. `var`, not `let`: a `let` cannot be reset, and
    /// this is on the invalidation contract's list (spec §5.3).
    private var lookup: ProviderCredentialsLookup

    /// The directory a FRESH session runs in: the project's first declared
    /// root. A resumed session runs in its own recorded cwd instead.
    ///
    /// **`var` as of 2b-viii.** It holds the outgoing org's project root
    /// across a switch otherwise, and nothing fails — `buildLaunch` takes
    /// the path it is given, so a fresh session in org B would simply run
    /// `claude` in org A's directory. The first symptom is `read_session`
    /// refusing a cwd that is not a root of the active project
    /// (`cmd/wakil-ctx/main.go:186`), several switches later. `refreshContext`
    /// rebuilds it (spec §5.3).
    private var rootPath: String
```

- [ ] **Step 4: Update the initialiser and both call sites**

In `WindowModel.init`, replace the `lookup:` parameter with `lookupFactory:` and store both:

```swift
        self.lookupFactory = lookupFactory
        self.lookup = lookupFactory(organization)
        self.harnessFactory = harnessFactory
```

In `WindowSession.swift`, replace line 141's construction:

```swift
            let wakilExe = wakilExecutable
            lookupFactory = { org in
                WakilCLICredentialsLookup(executable: wakilExe, organization: org)
            }
```

and line 171's closure:

```swift
            harnessFactory = { org, selection in
                let configJSON = agentMCPConfigJSON(
                    shimExecutable: executableURL,
                    socketPath: socketPath,
                    binaries: binaries,
                    organization: org,
                    provider: selection.id)
                return ClaudeCodeCLIHarness(
                    claudePath: selection.credentials.claudePath,
                    configDir: selection.credentials.configDir,
                    oauthToken: selection.credentials.oauthToken,
                    mcpConfigJSON: configJSON,
                    allowedTools: allowedTools)
            }
```

Update the two internal callers — `startHarness` (`:2943`) and `setProvider` (`:3110`) — to pass `organization` as the first argument.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "The org reaches the harness and the lookup as a parameter, and both become resettable"
```

---

## Task 7: `invalidateForOrgChange()` and the store collision fix

Spec §5 and §5.1. **This is the task the charter sequenced the whole sub-phase for.**

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift`, `app/Sources/WakilKit/Panes/PaneStore.swift`
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift` (create)

**Interfaces:**
- Produces: `WindowModel.invalidateForOrgChange()`, `LayoutStore.clearAllProjects()`, `PaneStore.clearAllProjects()`. Task 8's tripwire and Task 10's sequence both call the first.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/WakilKitTests/OrgSwitchTests.swift`:

```swift
import Testing
@testable import WakilKit

@MainActor
@Test func twoOrgsWithTheSameProjectNameDoNotShareACanvas() async {
    let layout = LayoutStore()
    await layout.switchProject(to: "core")
    await layout.load(LayoutSnapshot(panes: [Pane(id: "db-1", kind: "db")]), for: "core")
    #expect(await layout.snapshot().panes.count == 1)

    // The org changed. "core" in org B is a DIFFERENT project that merely
    // shares a name — byProject is keyed by name alone, and both stores
    // deliberately keep the outgoing project in memory.
    await layout.clearAllProjects()
    await layout.switchProject(to: "core")

    #expect(
        await layout.snapshot().panes.isEmpty,
        "org A's canvas must not be drawn under org B's identically-named project")
}

@MainActor
@Test func invalidationClearsEveryOrgDerivedValue() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.seedForTesting(providerId: "acct", rootPath: "/a/core", thoughts: 3)

    model.invalidateForOrgChange()

    #expect(model.providerId.isEmpty)
    #expect(model.thoughts.isEmpty)
    #expect(model.project.isEmpty)
    #expect(model.environment.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 twoOrgsWithTheSame`
Expected: FAIL — `value of type 'LayoutStore' has no member 'clearAllProjects'`

- [ ] **Step 3: Add the store methods**

In `LayoutStore.swift`, beside `switchProject`:

```swift
    /// Forgets every project's arrangement, not just the active one.
    ///
    /// **This exists because `byProject` is keyed by project NAME alone
    /// while `LayoutPersistence` is keyed by (org, project).** Disk is
    /// safe; memory is not. Two orgs each holding a project called `core`
    /// — unremarkable — would otherwise collide on an org switch, drawing
    /// the first org's arrangement under the second org's name, with
    /// nothing anywhere failing. `switchProject` deliberately KEEPS the
    /// outgoing project so that returning to it finds it as it was left,
    /// which is right within an org and exactly wrong across one.
    public func clearAllProjects() {
        byProject = [:]
        project = ""
    }
```

In `PaneStore.swift`, the same:

```swift
    /// Forgets every project's pane contents. Same reasoning as
    /// `LayoutStore.clearAllProjects` — this store holds what is IN the
    /// panes, that one holds where they are, and an org change
    /// invalidates both for the same reason.
    public func clearAllProjects() {
        byProject = [:]
        project = ""
    }
```

- [ ] **Step 4: Add the contract to `WindowModel`**

```swift
    /// Clears every piece of state that belongs to the organisation being
    /// left. **The teardown contract 2c-iii inherits** (spec §5).
    ///
    /// **Adding org-scoped state to this type means adding it here.**
    /// `InvalidationContractTests` fails on any stored property that is
    /// classified as neither org-derived nor org-independent, so a new
    /// pane's state cannot be added without its author being told to make
    /// the call. That test proves CLASSIFICATION, not behaviour — the
    /// resets themselves are covered by the acceptance runbook's checks 3,
    /// 4 and 14.
    ///
    /// Called from `setOrganization` BEFORE the clients restart, so no
    /// handler can write the outgoing org's data into a store while the
    /// new org's server is coming up.
    func invalidateForOrgChange() {
        // Context. `organization` is deliberately NOT cleared here: the
        // caller assigns it from the id it switched to, which is more
        // authoritative than anything get_context will say (spec §6).
        project = ""
        environment = ""

        // Panes and their contents.
        tables = [:]
        editables = [:]
        // The query line's per-pane state, all three parts: a refusal and
        // a restore both describe a pane in the OUTGOING org, and the
        // token is what orders restores within one window's life.
        queryLineRefusals = [:]
        queryLineRestores = [:]
        queryLineRestoreToken = 0
        layoutProject = nil
        loadedLayoutProjects = []

        // The agent.
        thoughts = []
        providerId = ""
        harness = nil
        sessionId = nil
        turnInFlight = false

        // Org-derived services. `lookup` is rebuilt rather than nilled
        // because every caller expects one to exist; `rootPath` falls
        // back to home until refreshContext rebuilds it (spec §5.3).
        lookup = lookupFactory("")
        rootPath = NSHomeDirectory()
    }
```

Add the two store calls in `setOrganization` (Task 10) — for now, call them at the end of `invalidateForOrgChange` via the stores the model already holds:

```swift
        // Both stores, wholesale — spec §5.1.
        Task { @MainActor in
            await layout.clearAllProjects()
            await panes.clearAllProjects()
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/Layout/LayoutStore.swift app/Sources/WakilKit/Panes/PaneStore.swift app/Tests/WakilKitTests/OrgSwitchTests.swift
git commit -m "invalidateForOrgChange, and the same-project-name collision it closes"
```

---

## Task 8: The tripwire test

Spec §5.2. It proves every stored property has been *classified*, not that the classification is honoured.

**Files:**
- Test: `app/Tests/WakilKitTests/InvalidationContractTests.swift` (create)

**Interfaces:**
- Consumes: `WindowModel.invalidateForOrgChange()` (Task 7).

- [ ] **Step 1: Write the test**

```swift
import Testing
@testable import WakilKit

/// Every stored property on `WindowModel`, classified.
///
/// **`WindowModel` is `@Observable`, so `Mirror` does not see what the
/// source says.** The macro rewrites each stored property into a computed
/// one over `_`-prefixed backing storage and adds `_$observationRegistrar`.
/// So labels arrive as `_organization`, `_project`, … plus a `$`-bearing
/// one — and an `@ObservationIgnored` property arrives under its PLAIN
/// name. Normalising (strip one leading `_`, drop `$` labels) rather than
/// hard-coding the underscored spellings is what keeps this test working
/// if a property is ever marked `@ObservationIgnored`.
private let orgDerived: Set<String> = [
    "project", "environment", "tables", "editables",
    "queryLineRefusals", "queryLineRestores", "queryLineRestoreToken",
    "layoutProject", "loadedLayoutProjects", "thoughts", "providerId",
    "harness", "sessionId", "turnInFlight", "lookup", "rootPath",
    "organization",
]

private let orgIndependent: Set<String> = [
    "registry", "panes", "layout", "persistence", "context",
    "harnessFactory", "lookupFactory", "resumes", "confirmations",
    "providerSwitches", "providerSwitchPump", "resumePump",
    "status", "eventPumpGeneration", "layoutSnapshot", "nextThoughtId",
]

@MainActor
@Test func everyWindowModelPropertyIsClassifiedForTheOrgSwitch() {
    let model = WindowModel.forTesting(organization: "alpha")
    var unclassified: [String] = []

    for child in Mirror(reflecting: model).children {
        guard var label = child.label else { continue }
        if label.contains("$") { continue }
        if label.hasPrefix("_") { label.removeFirst() }
        if orgDerived.contains(label) || orgIndependent.contains(label) { continue }
        unclassified.append(label)
    }

    #expect(
        unclassified.isEmpty,
        """
        WindowModel gained stored properties that no one has decided about \
        for an org switch: \(unclassified.sorted().joined(separator: ", ")).

        An org change invalidates every credential boundary the window holds. \
        Add each name to orgDerived (and reset it in invalidateForOrgChange) \
        or to orgIndependent, in InvalidationContractTests.swift. Do not \
        widen the skip rule instead — this test exists to make you choose.
        """)
}
```

- [ ] **Step 2: Run it and expand the lists until it passes**

Run: `make app-test 2>&1 | grep -A20 everyWindowModelProperty`
Expected: FAIL first, listing every unclassified name. `WindowModel` carries on the order of eighty stored properties, so this list will be long — that is expected, and the spec says so. Classify each one: anything holding a pane's contents, the agent's state, a project path, a credential or a provider id is **org-derived**; anything structural (stores, brokers, factories, the registry) is **org-independent**.

- [ ] **Step 3: Verify the tripwire actually trips**

Temporarily add `private var scratchProbe: Int = 0` to `WindowModel`, run the test, and confirm it FAILS naming `scratchProbe`. Then remove the property. A tripwire that has never been seen to trip is not known to work.

- [ ] **Step 4: Run the full suite**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "Tripwire: an unclassified WindowModel property fails the suite"
```

---

## Task 9: `refreshContext` re-derives the provider and the root

Spec §5.3 and §6 item 2. Without this, steps 7 and 8 of the sequence are unreachable — `startHarness` refuses an empty `providerId`.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:1417-1440`
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`

**Interfaces:**
- Consumes: `ContextStore.ActiveContext.activeProvider`, `.rootPaths` (both existing).

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
@Test func refreshContextRebuildsTheProviderAndTheRoot() async {
    let model = WindowModel.forTesting(
        organization: "beta",
        context: StubContextStore(.init(
            org: "beta", project: "orders", environment: "staging",
            rootPaths: ["/b/orders"], activeProvider: "work")))

    await model.refreshContext()

    #expect(model.providerId == "work")
    #expect(model.rootPathForTesting == "/b/orders")
}

@MainActor
@Test func refreshContextFailureClearsRatherThanKeepsAnotherOrgsValues() async {
    let model = WindowModel.forTesting(organization: "beta", context: FailingContextStore())
    await model.seedForTesting(providerId: "stale", rootPath: "/a/core", thoughts: 0)

    await model.refreshContext()

    #expect(model.project.isEmpty)
    #expect(model.environment.isEmpty)
    #expect(model.providerId.isEmpty, "a failed read must not leave org A's provider in place")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 refreshContextRebuilds`
Expected: FAIL — `providerId` is `""`

- [ ] **Step 3: Rewrite the body**

```swift
        do {
            let active = try await context.current()
            organization = active.org
            project = active.project
            environment = active.environment
            // **Re-derived, not carried.** Both are org-derived state
            // that `invalidateForOrgChange` cleared, and this is the one
            // call that can rebuild them — they ride on the same
            // `get_context` answer the project and environment do.
            // Without this, `startHarness` refuses the empty providerId
            // (`:2935`) and auto-resume has nothing to select for, so the
            // window lands in the new org with no agent for a reason no
            // message explains (spec §5.3).
            providerId = active.activeProvider
            rootPath = active.rootPaths.first ?? NSHomeDirectory()
        } catch {
            status = "context: \(error)"
            // **Cleared, not kept.** Keeping them would leave the window
            // showing the outgoing org's project and running its provider
            // while `organization` names the new one — the wrong
            // credential boundary, drawn confidently (spec §6).
            project = ""
            environment = ""
            providerId = ""
            rootPath = NSHomeDirectory()
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/OrgSwitchTests.swift
git commit -m "refreshContext rebuilds the provider and root, and clears them on failure"
```

---

## Task 10: `setOrganization` — guards and the ordered sequence

Spec §4.1 and §4.3.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`

**Interfaces:**
- Consumes: `WakilWiring.switchOrg(to:)` (Task 5) via an injected `orgSwitcher: @Sendable (String) async -> [String]`, `invalidateForOrgChange()` (Task 7), `refreshContext()` (Task 9).
- Produces: `WindowModel.setOrganization(_ org: String) async`. Task 11 wraps it; Task 14 calls it.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test func switchingToTheCurrentOrgIsRefused() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.setOrganization("alpha")
    #expect(model.status.contains("already open"))
}

@MainActor
@Test func aParkedMutationRefusesTheSwitch() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.parkAProposalForTesting()
    await model.setOrganization("beta")
    #expect(model.status.contains("waiting for confirmation"))
    #expect(model.organization == "alpha", "the switch must not have happened")
}

@MainActor
@Test func aFailedRestartLeavesTheWindowSayingSoRatherThanClaimingTheNewOrg() async {
    let model = WindowModel.forTesting(
        organization: "alpha",
        orgSwitcher: { _ in ["wakil-db did not come back under beta: transportClosed"] })
    await model.setOrganization("beta")
    #expect(model.status.contains("did not come back"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 switchingToTheCurrentOrg`
Expected: FAIL — no member `setOrganization`

- [ ] **Step 3: Implement**

```swift
    /// Switches the window to `org`, tearing down everything the outgoing
    /// organisation owned. Spec §4.
    ///
    /// **Guards 1 and 2 mirror `setProvider`'s wording** so the two
    /// switches refuse in one idiom. Guard 3 does NOT: a turn in flight
    /// queues rather than refusing, because an org carries the operator's
    /// whole context where a provider does not (spec §4.2). That branch
    /// lives in `requestOrganizationSwitch`.
    public func setOrganization(_ org: String) async {
        guard org != organization else {
            status = "switch org \(org): that organisation is already open in this window"
            return
        }
        guard await confirmations.current() == nil else {
            status = "switch org \(org): a mutation is waiting for confirmation — "
                + "confirm or cancel it first"
            return
        }

        switching = true
        defer { switching = false }

        // Ordered exactly as spec §4.3. The generation bump precedes
        // `stop()` for `setProvider`'s recorded reason: `stop()` waits for
        // stdout to become buffered events, not for this window to have
        // drained them, so the old pump must already be comparing against
        // a moved-on value or it will append the dead org's events after
        // the seam.
        eventPumpGeneration += 1
        await harness?.stop()

        invalidateForOrgChange()

        let diagnostics = await orgSwitcher(org)
        guard diagnostics.isEmpty else {
            // The window does NOT claim the new org. Every action handler
            // now throws `missingClient`, which is the same degrade a
            // missing binary produces — honest, and retryable from the
            // plane.
            status = "switch org \(org): \(diagnostics.joined(separator: "; "))"
            return
        }

        // Authoritative in a way get_context is not: this is the string
        // Wakil itself put into the child environment (spec §6).
        let previous = organization
        organization = org

        await refreshContext()
        await autoResumeAfterSwitch()
        appendSeam("\(previous.isEmpty ? "none" : previous) → \(org)")
    }
```

Add the stored properties `switching` and `orgSwitcher` and classify both in `InvalidationContractTests` (`switching` is org-independent — it describes the transition, not either org).

- [ ] **Step 4: Wire the production switcher in `WindowSession`**

The injected closure is how the model stays testable, but nothing connects it
to the real wiring yet — without this step `setOrganization` is unreachable in
the shipped app. In `WindowSession.start()`, where the `WindowModel` is built:

```swift
            // The model cannot reach `wiring` itself — it lives in
            // WakilKit and WakilWiring's clients are handed to it
            // individually — so the switch is injected as a closure here,
            // which is also what lets a test drive it without spawning a
            // child process.
            orgSwitcher: { [wiring] org in await wiring.switchOrg(to: org) },
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilApp/WindowSession.swift app/Tests/WakilKitTests/OrgSwitchTests.swift app/Tests/WakilKitTests/InvalidationContractTests.swift
git commit -m "setOrganization: the guards and the ordered teardown"
```

---

## Task 11: The queue — three states, and the send refusal

Spec §4.2. `setProvider`'s doc comment names a queue's cost as a reason to refuse; this sub-phase pays that cost.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`

**Interfaces:**
- Produces: `WindowModel.requestOrganizationSwitch(_ org: String) async`, `cancelQueuedSwitch()`, `.stopTurnAndSwitchNow() async`, and `.queuedOrgSwitch: String?`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test func aTurnInFlightQueuesTheSwitchAndItFiresWhenTheTurnEnds() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.beginTurnForTesting()

    await model.requestOrganizationSwitch("beta")
    #expect(model.queuedOrgSwitch == "beta")
    #expect(model.organization == "alpha", "queued means not yet")

    await model.endTurnForTesting()
    #expect(model.organization == "beta")
    #expect(model.queuedOrgSwitch == nil)
}

@MainActor
@Test func sendIsRefusedWhileASwitchIsQueuedSoItCannotBeStarved() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.endTurnForTestingWithoutFiring()

    await model.send("another turn")

    #expect(model.status.contains("switching to beta"))
}

@MainActor
@Test func aParkedMutationHoldsTheQueuedSwitchRatherThanCancellingIt() async {
    let model = WindowModel.forTesting(organization: "alpha")
    await model.beginTurnForTesting()
    await model.requestOrganizationSwitch("beta")
    await model.parkAProposalForTesting()
    await model.endTurnForTesting()

    #expect(model.queuedOrgSwitch == "beta", "held, not cancelled")
    #expect(model.organization == "alpha")

    await model.cancelPending()
    #expect(model.organization == "beta", "a cancel clears the park and the switch fires")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 aTurnInFlightQueues`
Expected: FAIL — no member `requestOrganizationSwitch`

- [ ] **Step 3: Implement**

```swift
    /// The organisation a queued switch is waiting to move to, or `nil`.
    ///
    /// **Window state, not plane state** (spec §4.2): dismissing the org
    /// plane does not cancel it and the status line carries it. Only
    /// `cancelQueuedSwitch()` cancels it, and only the operator calls that.
    public private(set) var queuedOrgSwitch: String?

    /// The operator asked to switch. Queues if a turn is in flight,
    /// switches immediately otherwise.
    public func requestOrganizationSwitch(_ org: String) async {
        guard turnInFlight else {
            await setOrganization(org)
            return
        }
        queuedOrgSwitch = org
        status = "switching to \(org) when this turn finishes"
    }

    public func cancelQueuedSwitch() {
        guard let org = queuedOrgSwitch else { return }
        queuedOrgSwitch = nil
        status = "switch to \(org) cancelled"
    }

    /// Cuts the running turn and switches at once. Same ordering
    /// `setProvider` records: the generation bump precedes `stop()`.
    public func stopTurnAndSwitchNow() async {
        guard let org = queuedOrgSwitch else { return }
        queuedOrgSwitch = nil
        eventPumpGeneration += 1
        await harness?.stop()
        turnInFlight = false
        appendSeam("turn cut short")
        await setOrganization(org)
    }

    /// Fires a queued switch at the first moment nothing is in its way.
    ///
    /// Called wherever `turnInFlight` becomes false and wherever a
    /// confirmation is resolved. **A parked mutation HOLDS rather than
    /// cancels** — discarding the operator's intent while they are looking
    /// at an unrelated SQL statement would take the switch away at the one
    /// moment they have no reason to connect the two (spec §4.2 state 2).
    func fireQueuedSwitchIfReady() async {
        guard let org = queuedOrgSwitch, !turnInFlight else { return }
        guard await confirmations.current() == nil else {
            status = "switch to \(org) held: a mutation is waiting for confirmation"
            return
        }
        queuedOrgSwitch = nil
        await setOrganization(org)
    }
```

Call `fireQueuedSwitchIfReady()` at `:3001` (turn end), `:3533` (`.result` event), and at the end of both `confirmPending` and `cancelPending`.

Add to the top of `send(_:)`, before anything else:

```swift
        // A queued switch wins the next gap and cannot be starved.
        // `turnInFlight` is one flag with no "closing" state, so letting
        // the next turn start would make "fires when the turn completes" a
        // sentence with no bound on it (spec §4.2).
        if let queued = queuedOrgSwitch {
            status = "switching to \(queued) — cancel the switch, or wait for it"
            return
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/OrgSwitchTests.swift
git commit -m "The queued switch: queued, held, cancelled — and send refuses while one waits"
```

---

## Task 12: Auto-resume on return

Spec §7. This amends charter q5, and Task 15 records the amendment.

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift`
- Test: `app/Tests/WakilKitTests/OrgSwitchTests.swift`

**Interfaces:**
- Consumes: `resume(sessionId:)` and `sessionPaletteItems()` (both existing).
- Produces: `WindowModel.autoResumeAfterSwitch() async` — called by Task 10's step 7.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test func returningToAnOrgResumesItsNewestSessionForTheActiveProvider() async {
    // Newest first, which is `session_list`'s own guarantee.
    let model = WindowModel.forTesting(
        organization: "alpha",
        sessionRows: [
            .object(["id": .string("s-other"), "provider": .string("personal"), "cwd": .string("/b/orders")]),
            .object(["id": .string("s-new"), "provider": .string("work"), "cwd": .string("/b/orders")]),
            .object(["id": .string("s-old"), "provider": .string("work"), "cwd": .string("/b/orders")]),
        ])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == "s-new",
            "newest FOR THIS PROVIDER — s-other is newer but belongs to another account")
}

@MainActor
@Test func autoResumeFallsBackToAFreshSessionWithANote() async {
    let model = WindowModel.forTesting(organization: "alpha", sessionRows: [])
    await model.seedForTesting(providerId: "work", rootPath: "/b/orders", thoughts: 0)

    await model.autoResumeAfterSwitch()

    #expect(model.resumedParentForTesting == nil)
    #expect(model.status.contains("fresh session"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 returningToAnOrgResumes`
Expected: FAIL — no member `autoResumeAfterSwitch`

- [ ] **Step 3: Implement**

```swift
    /// Resumes the organisation's most recent session, or starts fresh and
    /// says so. Spec §7.
    ///
    /// **This is the q5 amendment.** The charter's rule is fresh-by-default
    /// with resume as an explicit action; that rule was decided about
    /// LAUNCHING THE APP, and returning to an org you left ten minutes ago
    /// is a different event. Decision 12's drift concern is answered rather
    /// than waived: 2b-v's resume is a FORK under a fresh Wakil-minted
    /// session id with lineage recorded, so a chain of switches is a chain
    /// of short sessions, not one long one.
    ///
    /// **A session belongs to a provider.** Transcripts live under the
    /// provider's own config dir, and another account's `claude` cannot
    /// read them — which is why `resume` already refuses a session
    /// belonging to a different provider. So the newest session is chosen
    /// from this org's ACTIVE provider only.
    ///
    /// **It mints a session; it spends nothing.** No turn is sent and no
    /// tokens are consumed until the operator types.
    func autoResumeAfterSwitch() async {
        guard !providerId.isEmpty else {
            // §5.3's case: a fresh org, or one that has never chosen an
            // account. `noActiveProviderNote` already names the fix.
            return
        }
        // The RAW rows, not `sessionPaletteItems()`. `PaletteItem` carries
        // only id/kind/title/subtitle/payload — it has no provider or cwd
        // to filter on, and `sessionItems` additionally COLLAPSES resume
        // chains, which is right for ⌘P and wrong here.
        // `session_list` guarantees newest-first, so the first match wins.
        let source = await paletteSource("session_list")
        guard let structured = source.structured,
              case .array(let rows)? = structured["sessions"] else {
            status = "no previous session in \(organization) — starting a fresh session"
            return
        }
        let candidate = rows.first { row in
            guard case .object(let f) = row,
                  case .string(let provider)? = f["provider"],
                  case .string(let cwd)? = f["cwd"] else { return false }
            return provider == providerId && cwd == rootPath
        }
        guard case .object(let fields)? = candidate,
              case .string(let id)? = fields["id"] else {
            status = "no previous session in \(organization) — starting a fresh session"
            return
        }
        await resume(sessionId: id)
        if sessionId == nil {
            status = "could not resume \(id) — starting a fresh session"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/OrgSwitchTests.swift
git commit -m "Auto-resume on return, provider-scoped, with an honest fallback"
```

---

## Task 13: Register the four actions, operator-only

Spec §9.1. **`get_context` is not one of them** — §9.2.

**Files:**
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift:74`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift`
- Test: `app/Tests/WakilKitTests/PermissionPromptTests.swift`

**Interfaces:**
- Produces: actions `ctx_list_orgs`, `ctx_create_org`, `ctx_list_machine_providers`, `ctx_adopt_provider`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func theAgentCannotCreateOrSwitchAnOrganisation() {
    for name in ["ctx_create_org", "ctx_adopt_provider", "ctx_list_orgs", "ctx_list_machine_providers"] {
        let decision = permissionDecision(toolName: name, knownActions: [name])
        guard case .deny(let reason) = decision else {
            Issue.record("\(name) must be operator-only")
            continue
        }
        #expect(reason.contains("operator"))
    }
}

@Test func getContextIsNotOperatorOnly() {
    // §9.2: it is not an action at all, and the window reads its own
    // context through it. Adding it to the set would be meaningless AND
    // would invite an implementer to skip §6's amendment.
    #expect(!operatorOnlyActions.contains("ctx_get_context"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make app-test 2>&1 | grep -A3 theAgentCannotCreate`
Expected: FAIL — decision is `.allow`

- [ ] **Step 3: Extend the set**

```swift
/// Actions only the operator may invoke, never the agent.
///
/// The org entries were added by 2b-viii, for two reasons worth keeping
/// separate rather than blurring:
///
/// - `ctx_create_org` and `ctx_adopt_provider` are the strong case: an
///   agent that could create an org or bind an account into one could move
///   Invariant 4's own credential boundary.
/// - `ctx_list_orgs` and `ctx_list_machine_providers` are the weaker case,
///   and it is stated rather than inherited by association. They move no
///   boundary, and reading across orgs is established practice —
///   `provider add` has always done it. They are denied because
///   enumerating every org and config dir on the machine is not something
///   a session scoped to ONE org has any business doing.
///
/// `ctx_get_context` is deliberately absent: it is not an action
/// (`ContextStore.swift:38`), and it is how the window reads its own
/// context.
public let operatorOnlyActions: Set<String> = [
    "session_set_provider", "ctx_set_provider",
    "ctx_list_orgs", "ctx_create_org",
    "ctx_list_machine_providers", "ctx_adopt_provider",
]
```

Register the four in `registerStandardActions`, following the existing `ctx_list_providers` pattern — each dispatches to the `context` client and returns its structured content.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make app-test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/MCP/PermissionPrompt.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/PermissionPromptTests.swift
git commit -m "The four org actions, operator-only — and get_context deliberately not"
```

---

## Task 14: The org plane

Spec §8. `WakilApp` has no test target, so correctness here rests on the runbook — build the plane against `OrgPlane.dc.html`, `OrgFirstRun.dc.html` and `OrgStates.dc.html` in `docs/wakil/screens/`, which are the drawn design.

**Files:**
- Create: `app/Sources/WakilApp/OrgPlane.swift`
- Modify: `app/Sources/WakilApp/AppScene.swift:264`, `app/Sources/WakilApp/WakilWindow.swift`

**Interfaces:**
- Consumes: `requestOrganizationSwitch`, `cancelQueuedSwitch`, `stopTurnAndSwitchNow`, `queuedOrgSwitch` (Tasks 10-11); the four actions (Task 13).

- [ ] **Step 1: Build the six states**

Compose on `design-language.md` §3's **near** plane, exactly as `ConfirmationPlane.swift` does — that file is the composition precedent, not §3 itself.

| State | Contents |
|---|---|
| Choosing | one row per org: id, Jira site or "no Jira site", account count; current marked and unselectable; **always ends with "New organisation"** |
| Creating | id, Jira base (optional). **No default-provider field** |
| Adopting | machine accounts: `org/provider`, config dir, kind, label; the `--share` warning; "add a new account — `wakil provider add`, not yet in-window" |
| Switching | progress; canvas behind inert |
| Queued | "switching to *X* when this turn finishes" · Cancel · Stop the turn and switch now |
| Error | the failed restart named, with Retry |

- [ ] **Step 2: Wire the edges (spec §8.6)**

```
(entry) --⌘⇧O or org-less launch--> Choosing
Choosing --"New organisation"------> Creating
Creating --create_org succeeded----> Adopting (for the new org, skippable)
Choosing --an org's row------------> Adopting (for that org)
Adopting --done or skipped---------> Choosing
Choosing --selecting another org---> Switching / Queued
```

Neither Creating nor Adopting switches the window. Each offers it, and only when the affected org is not already current.

- [ ] **Step 3: The org-less launch draws no bleeds**

Per spec §8.5. The render path takes an **optional** palette; `nil` means no bleeds — field, vignette and grain only. Do **not** add a third `VoidPalette` case, and do **not** call `VoidPalette.forEnvironment("")`: it branches only on `isProductionEnvironment` and would return the ordinary violet/blue pair, asserting a non-production environment to an operator who is in none.

The plane is dismissable with Esc **only** when an org is open. It opens with the reason named when `WAKIL_ORG` names an org that does not exist.

- [ ] **Step 4: Bind ⌘⇧O**

In `AppScene.swift`, beside the existing `⌘⇧D`:

```swift
                Button("Organisation…") { model.showOrgPlane = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
```

Verified free: the window binds ⌘↩, ⌘W, ⌘⇧D, ⌘P and ⌘K, and nothing else.

- [ ] **Step 5: Build and launch**

Run: `make build && make app-bundle && open app/Wakil.app`
Expected: ⌘⇧O opens the plane; launching with `WAKIL_ORG` unset opens it automatically with no bleeds.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp/OrgPlane.swift app/Sources/WakilApp/AppScene.swift app/Sources/WakilApp/WakilWindow.swift
git commit -m "The org plane: six states, ⌘⇧O, and a room with no colour in it"
```

---

## Task 15: The acceptance runbook and the charter edits

Spec §12 and §14.

**Files:**
- Create: `docs/wakil/phase-2b-viii-acceptance.md`
- Modify: `docs/wakil/north-star.md`, `decisions.md`, `open-questions.md`, `phase-log.md`

- [ ] **Step 1: Write the runbook**

All fifteen checks from spec §12, verbatim, each with the exact commands and the disk/journal evidence to check — the standard `permission-prompt-acceptance.md` sets. Checks 4, 13, 14 and 15 are the ones that exist because the defect is otherwise invisible; do not compress them.

- [ ] **Step 2: Make the charter edits**

From spec §14's table. Each one:

- **q5** — amended: returning to an org auto-resumes; record §7's reasoning.
- **q13** — already closed; point at this spec.
- **q14** — closed: org creation lives in the plane.
- **Decision 21** — near-free half shipped; costed half still unscheduled.
- **The 2b-viii row** — correct "five servers" **from §4.4's table, not from memory**: the window runs **four** — `wakil-ctx` and `wakil-db` restarted by Wakil, `wakil-pm` and `wakil-recall` respawned with the harness, `wakil-http` not running in the window at all. Also correct "`WAKIL_ORG` stops being a launch-time environment read": it stops being read at the three child-spawn sites and **remains the launch seed** (§7.1).
- **A new note on q13** — §7.1's ruling: the switched-to org does not survive a relaunch.
- **Invariant 4** — no amendment, recorded because a reader will ask.
- **Decision 12 / `setProvider`** — no amendment: the provider switch still refuses a turn where the org switch queues one, on purpose.

- [ ] **Step 3: Mark the row met only after the walk**

The row stays un-met until the operator has walked the runbook. Do not mark it met in this task.

- [ ] **Step 4: Commit**

```bash
git add docs/wakil/
git commit -m "The 2b-viii acceptance runbook, and the charter edits it forces"
```

---

## Notes for the executor

**Order matters.** Tasks 1-3 (Go) are independent of 4-14 (Swift) and can be done in either order, but Task 9 needs Task 1's `ActiveProvider` on the wire, and Tasks 10-12 need 5, 6, 7 and 9. Task 8's list grows as Tasks 10 and 11 add properties — expect to update it twice, and that is the tripwire working.

**The riskiest task is 8, not 14.** `WindowModel` carries on the order of eighty stored properties and every one needs a judgement. Budget for it, and resist widening the skip rule to make the test pass — that is the one change that turns the deliverable back into a comment.

**What no test covers, by construction.** `wakil-db` mid-fetch during a restart was never measured (probe §6); check 3 exercises it. `WakilApp` has no test target, so the plane's behaviour rests entirely on the runbook.
