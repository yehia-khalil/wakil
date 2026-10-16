# Wakil Phase 1 — Capability Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless Wakil capability layer — five Go MCP servers plus a file-based context model — driven from plain Claude Code, so the two exit-criterion prompts work with no Swift and no UI.

**Architecture:** One Go module. A shared internal package `wakilcore` holds config/context types, the `~/.wakil` state readers/writers, the Keychain secret store, the `DbDriver` interface, the read-only gate, and the Jira/HTTP clients. Five `cmd/` binaries (`wakil-ctx`, `wakil-db`, `wakil-pm`, `wakil-http`, `wakil-recall`) each expose MCP tools over stdio. Servers never call each other; they coordinate only through `~/.wakil/active.json`, which `wakil-ctx` alone writes.

**Tech Stack:** Go 1.23+, `github.com/modelcontextprotocol/go-sdk/mcp` (official Go MCP SDK, stdio transport), `github.com/go-sql-driver/mysql`, `modernc.org/sqlite` (pure-Go, CGO-free), `go.mongodb.org/mongo-driver/mongo`, macOS `security` CLI for Keychain via `os/exec`.

**Spec:** `docs/superpowers/specs/2026-09-03-phase-1-capability-layer.md` (read it alongside this plan). Charter: `docs/wakil/north-star.md`.

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec/charter):

- **Language: Go**, official Go MCP SDK, stdio transport. One module, one command per server under `cmd/`, shared internal package `wakilcore`.
- **Module path:** `github.com/yehia-khalil/wakil` (adjust to your VCS host if you publish; used consistently in every import below).
- **CGO must stay off** (`CGO_ENABLED=0`) so every binary is a single static binary — this forbids cgo SQLite/Keychain libraries; use `modernc.org/sqlite` and the `security` CLI.
- **Servers never call each other.** Shared state is `~/.wakil/active.json`, written only by `wakil-ctx`, read by the rest.
- **Read-only only.** Per-driver DB write rejection + HTTP GET/HEAD only. A connection or environment marked `readOnly: true` is absolute — no override in Phase 1.
- **Secrets live only in the macOS Keychain**, keyed by `ref`. Never in any JSON file, never in an env var beyond the single process that needs them.
- **Auth:** `CLAUDE_CODE_OAUTH_TOKEN` set; `ANTHROPIC_API_KEY` must be *truly unset* (`env -u`). Refresh-token/auth failures surface as a human "re-auth <org>" sentence, never a raw 401.
- **Errors** are returned as structured MCP tool errors carrying a human sentence (e.g. "staging DB unreachable"), never raw stack traces.
- **Session-path encoding is lossy** (`/`→`-`, `.`→`-`): always encode a known root path and look for that directory; never decode directory names back to paths. Match Conductor worktrees by encoded-root **prefix**.
- **No Swift, no UI.** Everything runs under plain Claude Code.
- **TDD, frequent commits.** Each task ends with passing tests and a commit.

---

## File Structure

```
go.mod                                  module github.com/yehia-khalil/wakil
internal/wakilcore/
  config.go        Project, Root, Scope, Environment, Database, ApiConfig structs + JSON load
  config_test.go
  paths.go         ~/.wakil locations, OrgFromConfigDir, project registry
  paths_test.go
  active.go        ActiveContext read/write (the only writer is wakil-ctx)
  active_test.go
  resolve.go       Resolve() → fully-resolved active (org, project, env, scopes)
  resolve_test.go
  secrets.go       Keychain get/set via `security`
  secrets_test.go
  sessions.go      EncodeRootPath, ListSessions, GetSession
  sessions_test.go
  mcperr.go        UserError helper → structured MCP error with human sentence
  readonly.go      SQL + HTTP read-only gates (shared helpers)
  readonly_test.go
  dbdriver.go      DbDriver interface + Connection/Container/Schema/Rows/QuerySpec types + registry
  driver_sqlite.go
  driver_sqlite_test.go
  driver_mysql.go
  driver_mysql_test.go
  driver_mongo.go
  driver_mongo_test.go
  jira.go          Jira REST client (my_issues/search/get_issue, scope prepend)
  jira_test.go
  httpclient.go    environment-bound GET/HEAD client
  httpclient_test.go
cmd/wakil-ctx/main.go     get_context/list_projects/set_project/set_environment/list_environments/list_sessions/get_session
cmd/wakil-db/main.go      list_databases/list_tables/describe_table/query
cmd/wakil-pm/main.go      my_issues/search_issues/get_issue
cmd/wakil-http/main.go    request
cmd/wakil-recall/main.go  recall
cmd/wakil/main.go         `wakil secrets set <ref>` CLI + `wakil register` launcher helper
scripts/register-org.sh   registers the built binaries in an org config dir's MCP settings
Makefile                  build all binaries CGO_ENABLED=0
```

---

## Task 1: Module bootstrap + config types

**Files:**
- Create: `go.mod`, `internal/wakilcore/config.go`
- Test: `internal/wakilcore/config_test.go`

**Interfaces:**
- Produces: types `Project{Name,Org string; Roots []Root; Scopes Scopes; Environments map[string]Environment}`, `Root{Path,Role string}`, `Scopes{PM *PMScope}`, `PMScope{Provider,ProjectKey string}`, `Environment{Databases []Database; API *ApiConfig}`, `Database{Name,Driver,Ref string; ReadOnly bool}`, `ApiConfig{BaseURL string; AuthRef string}`. Function `LoadProject(path string) (*Project, error)`.

- [ ] **Step 1: Initialize the module**

Run:
```bash
cd /Users/operator/conductor/workspaces/wakil/amsterdam
go mod init github.com/yehia-khalil/wakil
go get github.com/modelcontextprotocol/go-sdk/mcp
```
Expected: `go.mod` created with the SDK required.

- [ ] **Step 2: Write the failing test**

Create `internal/wakilcore/config_test.go`:
```go
package wakilcore

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadProject(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "project.json")
	os.WriteFile(p, []byte(`{
      "name":"booking-platform","org":"initech",
      "roots":[{"path":"api","role":"service"},{"path":"web-admin","role":"frontend"}],
      "scopes":{"pm":{"provider":"jira","projectKey":"RAF"}},
      "environments":{
        "staging":{"databases":[{"name":"core","driver":"mysql","ref":"bs-core"}],"api":{"baseUrl":"https://staging.internal"}},
        "production":{"databases":[{"name":"core","driver":"mysql","ref":"bp-core","readOnly":true}]}
      }}`), 0o644)

	proj, err := LoadProject(p)
	if err != nil {
		t.Fatalf("LoadProject: %v", err)
	}
	if proj.Name != "booking-platform" || proj.Org != "initech" {
		t.Fatalf("bad header: %+v", proj)
	}
	if len(proj.Roots) != 2 || proj.Roots[0].Path != "api" || proj.Roots[0].Role != "service" {
		t.Fatalf("bad roots: %+v", proj.Roots)
	}
	if proj.Scopes.PM == nil || proj.Scopes.PM.ProjectKey != "RAF" {
		t.Fatalf("bad pm scope: %+v", proj.Scopes)
	}
	if !proj.Environments["production"].Databases[0].ReadOnly {
		t.Fatalf("prod core should be readOnly")
	}
	if proj.Environments["staging"].API.BaseURL != "https://staging.internal" {
		t.Fatalf("bad api base url")
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestLoadProject -v`
Expected: FAIL (undefined: LoadProject).

- [ ] **Step 4: Write minimal implementation**

Create `internal/wakilcore/config.go`:
```go
package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
)

type Project struct {
	Name         string                 `json:"name"`
	Org          string                 `json:"org"`
	Roots        []Root                 `json:"roots"`
	Scopes       Scopes                 `json:"scopes"`
	Environments map[string]Environment `json:"environments"`
}

type Root struct {
	Path string `json:"path"`
	Role string `json:"role,omitempty"`
}

type Scopes struct {
	PM *PMScope `json:"pm,omitempty"`
}

type PMScope struct {
	Provider   string `json:"provider"`
	ProjectKey string `json:"projectKey"`
}

type Environment struct {
	Databases []Database `json:"databases"`
	API       *ApiConfig `json:"api,omitempty"`
}

type Database struct {
	Name     string `json:"name"`
	Driver   string `json:"driver"`
	Ref      string `json:"ref"`
	ReadOnly bool   `json:"readOnly,omitempty"`
}

type ApiConfig struct {
	BaseURL string `json:"baseUrl"`
	AuthRef string `json:"authRef,omitempty"`
}

func LoadProject(path string) (*Project, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read project.json: %w", err)
	}
	var p Project
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, fmt.Errorf("parse project.json: %w", err)
	}
	if p.Name == "" || p.Org == "" {
		return nil, fmt.Errorf("project.json missing name or org")
	}
	return &p, nil
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestLoadProject -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add go.mod go.sum internal/wakilcore/config.go internal/wakilcore/config_test.go
git commit -m "feat(wakilcore): module bootstrap + project config types"
```

---

## Task 2: Paths, org identity, and the project registry

**Files:**
- Create: `internal/wakilcore/paths.go`
- Test: `internal/wakilcore/paths_test.go`

**Interfaces:**
- Consumes: `LoadProject` (Task 1).
- Produces: `WakilDir() string` (→ `~/.wakil`), `OrgFromConfigDir(configDir string) string`, `CurrentOrg() string` (reads `CLAUDE_CONFIG_DIR` env), `LoadRegistry() (map[string]string, error)` (project name → project.json path from `~/.wakil/projects.json`).

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/paths_test.go`:
```go
package wakilcore

import "testing"

func TestOrgFromConfigDir(t *testing.T) {
	cases := map[string]string{
		"/Users/operator/.claude-initech":      "initech",
		"/Users/operator/.claude-personal": "personal",
		"/Users/operator/.claude":          "default",
		"":                              "default",
	}
	for in, want := range cases {
		if got := OrgFromConfigDir(in); got != want {
			t.Errorf("OrgFromConfigDir(%q)=%q want %q", in, got, want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestOrgFromConfigDir -v`
Expected: FAIL (undefined: OrgFromConfigDir).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/paths.go`:
```go
package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

func WakilDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".wakil")
}

// OrgFromConfigDir derives the org id from a Claude config dir path:
// ".claude-initech" -> "initech", ".claude-personal" -> "personal", ".claude" -> "default".
func OrgFromConfigDir(configDir string) string {
	if configDir == "" {
		return "default"
	}
	base := filepath.Base(configDir)
	base = strings.TrimPrefix(base, ".claude")
	base = strings.TrimPrefix(base, "-")
	if base == "" {
		return "default"
	}
	return base
}

func CurrentOrg() string { return OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR")) }

func LoadRegistry() (map[string]string, error) {
	b, err := os.ReadFile(filepath.Join(WakilDir(), "projects.json"))
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return m, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestOrgFromConfigDir -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/paths.go internal/wakilcore/paths_test.go
git commit -m "feat(wakilcore): wakil dir, org-from-config-dir, project registry"
```

---

## Task 3: Active context read/write

**Files:**
- Create: `internal/wakilcore/active.go`
- Test: `internal/wakilcore/active_test.go`

**Interfaces:**
- Consumes: `WakilDir` (Task 2).
- Produces: type `ActiveContext{Project string; Environment string}`, `ReadActive() (ActiveContext, error)`, `WriteActive(ActiveContext) error` (atomic write via temp file + rename; creates `~/.wakil` if missing).

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/active_test.go`:
```go
package wakilcore

import (
	"testing"
)

func TestActiveRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if _, err := ReadActive(); err != nil {
		t.Fatalf("ReadActive on empty should be nil error, got %v", err)
	}
	want := ActiveContext{Project: "/x/booking", Environment: "staging"}
	if err := WriteActive(want); err != nil {
		t.Fatalf("WriteActive: %v", err)
	}
	got, err := ReadActive()
	if err != nil {
		t.Fatalf("ReadActive: %v", err)
	}
	if got != want {
		t.Fatalf("round trip mismatch: %+v vs %+v", got, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestActiveRoundTrip -v`
Expected: FAIL (undefined: ActiveContext/ReadActive/WriteActive).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/active.go`:
```go
package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type ActiveContext struct {
	Project     string `json:"project"`
	Environment string `json:"environment"`
}

func activePath() string { return filepath.Join(WakilDir(), "active.json") }

func ReadActive() (ActiveContext, error) {
	var a ActiveContext
	b, err := os.ReadFile(activePath())
	if os.IsNotExist(err) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	return a, json.Unmarshal(b, &a)
}

func WriteActive(a ActiveContext) error {
	if err := os.MkdirAll(WakilDir(), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(a, "", "  ")
	if err != nil {
		return err
	}
	tmp := activePath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, activePath())
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestActiveRoundTrip -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/active.go internal/wakilcore/active_test.go
git commit -m "feat(wakilcore): active-context atomic read/write"
```

---

## Task 4: Context resolution + cross-org guard

**Files:**
- Create: `internal/wakilcore/resolve.go`, `internal/wakilcore/mcperr.go`
- Test: `internal/wakilcore/resolve_test.go`

**Interfaces:**
- Consumes: `LoadProject`, `LoadRegistry`, `CurrentOrg`, `ReadActive` (Tasks 1–3).
- Produces: type `Resolved{Org string; Project *Project; ProjectPath string; Environment string}`, `Resolve() (*Resolved, error)`, `ResolveEnvironment() (Environment, error)`; `SetProjectChecked(name string) error` (registry lookup + org guard + write active); `UserError(msg string) error` and `IsUserError(error) (string, bool)` in `mcperr.go`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/resolve_test.go`:
```go
package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeProject(t *testing.T, dir, name, org string) string {
	t.Helper()
	pj := filepath.Join(dir, ".wakil")
	os.MkdirAll(pj, 0o755)
	path := filepath.Join(pj, "project.json")
	os.WriteFile(path, []byte(`{"name":"`+name+`","org":"`+org+`","roots":[{"path":"."}],"environments":{"staging":{"databases":[]}}}`), 0o644)
	return path
}

func TestSetProjectRejectsCrossOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "/x/.claude-initech")

	proj247 := writeProject(t, filepath.Join(home, "p247"), "p247", "initech")
	projGath := writeProject(t, filepath.Join(home, "pgath"), "pgath", "umbrella")

	os.MkdirAll(WakilDir(), 0o755)
	reg, _ := json.Marshal(map[string]string{"p247": proj247, "pgath": projGath})
	os.WriteFile(filepath.Join(WakilDir(), "projects.json"), reg, 0o644)

	if err := SetProjectChecked("p247"); err != nil {
		t.Fatalf("same-org set should succeed: %v", err)
	}
	err := SetProjectChecked("pgath")
	if err == nil {
		t.Fatal("cross-org set must be rejected")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected user error, got %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestSetProjectRejectsCrossOrg -v`
Expected: FAIL (undefined symbols).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/mcperr.go`:
```go
package wakilcore

import "errors"

type userError struct{ msg string }

func (e *userError) Error() string { return e.msg }

// UserError wraps a human-facing message safe to show verbatim.
func UserError(msg string) error { return &userError{msg} }

func IsUserError(err error) (string, bool) {
	var ue *userError
	if errors.As(err, &ue) {
		return ue.msg, true
	}
	return "", false
}
```

Create `internal/wakilcore/resolve.go`:
```go
package wakilcore

import "fmt"

type Resolved struct {
	Org         string
	Project     *Project
	ProjectPath string
	Environment string
}

func Resolve() (*Resolved, error) {
	active, err := ReadActive()
	if err != nil {
		return nil, err
	}
	if active.Project == "" {
		return nil, UserError("no active project — run set_project first")
	}
	reg, err := LoadRegistry()
	if err != nil {
		return nil, err
	}
	// active.Project stores the project.json path.
	proj, err := LoadProject(active.Project)
	if err != nil {
		return nil, UserError("active project config unreadable: " + err.Error())
	}
	_ = reg
	return &Resolved{Org: CurrentOrg(), Project: proj, ProjectPath: active.Project, Environment: active.Environment}, nil
}

func ResolveEnvironment() (Environment, error) {
	r, err := Resolve()
	if err != nil {
		return Environment{}, err
	}
	env, ok := r.Project.Environments[r.Environment]
	if !ok {
		return Environment{}, UserError(fmt.Sprintf("no active environment — choose one of the project's environments"))
	}
	return env, nil
}

func SetProjectChecked(name string) error {
	reg, err := LoadRegistry()
	if err != nil {
		return err
	}
	path, ok := reg[name]
	if !ok {
		return UserError("unknown project: " + name)
	}
	proj, err := LoadProject(path)
	if err != nil {
		return UserError("project config unreadable: " + err.Error())
	}
	if proj.Org != CurrentOrg() {
		return UserError(fmt.Sprintf("project %q belongs to org %q but the active org is %q — switch Claude config dir first", name, proj.Org, CurrentOrg()))
	}
	active, _ := ReadActive()
	active.Project = path
	return WriteActive(active)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestSetProjectRejectsCrossOrg -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/resolve.go internal/wakilcore/mcperr.go internal/wakilcore/resolve_test.go
git commit -m "feat(wakilcore): context resolution + cross-org guard + user errors"
```

---

## Task 5: Keychain secret store

**Files:**
- Create: `internal/wakilcore/secrets.go`
- Test: `internal/wakilcore/secrets_test.go`

**Interfaces:**
- Produces: `SecretGet(ref string) (string, error)`, `SecretSet(ref, value string) error`. Keychain service name scheme: `wakil:<ref>`, account `wakil`.

**Note (spec open question / spike):** this task *is* the Keychain spike. Its test is gated behind `WAKIL_KEYCHAIN_TEST=1` because it touches the real login keychain and may prompt. Run it once manually on the target Mac to confirm a Go binary can read/write without a blocking prompt in the Claude Code launch context.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/secrets_test.go`:
```go
package wakilcore

import (
	"os"
	"testing"
)

func TestKeychainRoundTrip(t *testing.T) {
	if os.Getenv("WAKIL_KEYCHAIN_TEST") != "1" {
		t.Skip("set WAKIL_KEYCHAIN_TEST=1 to run the real-keychain spike test")
	}
	ref := "wakil-unit-test-ref"
	if err := SecretSet(ref, "hunter2://db"); err != nil {
		t.Fatalf("SecretSet: %v", err)
	}
	got, err := SecretGet(ref)
	if err != nil {
		t.Fatalf("SecretGet: %v", err)
	}
	if got != "hunter2://db" {
		t.Fatalf("got %q", got)
	}
	if _, err := SecretGet("definitely-missing-ref"); err == nil {
		t.Fatal("missing ref should error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestKeychainRoundTrip -v`
Expected: SKIP (gate unset) — confirms it compiles once implementation exists; before implementation, FAIL (undefined SecretGet/SecretSet).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/secrets.go`:
```go
package wakilcore

import (
	"bytes"
	"os/exec"
	"strings"
)

func keychainService(ref string) string { return "wakil:" + ref }

func SecretGet(ref string) (string, error) {
	cmd := exec.Command("security", "find-generic-password",
		"-s", keychainService(ref), "-a", "wakil", "-w")
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return "", UserError("no credential stored for ref " + ref + " — run: wakil secrets set " + ref)
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

func SecretSet(ref, value string) error {
	// -U updates if present.
	cmd := exec.Command("security", "add-generic-password",
		"-U", "-s", keychainService(ref), "-a", "wakil", "-w", value)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return UserError("could not write keychain entry for " + ref + ": " + strings.TrimSpace(errb.String()))
	}
	return nil
}
```

- [ ] **Step 4: Verify**

Run: `go test ./internal/wakilcore/ -run TestKeychainRoundTrip -v` (SKIP is acceptable in CI).
Then run the spike manually on the target Mac:
```bash
WAKIL_KEYCHAIN_TEST=1 go test ./internal/wakilcore/ -run TestKeychainRoundTrip -v
```
Expected: PASS with no blocking GUI prompt. If it prompts, note the resolution (add to login keychain / "Always Allow") in the spec's open-questions section.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/secrets.go internal/wakilcore/secrets_test.go
git commit -m "feat(wakilcore): keychain secret store via security CLI"
```

---

## Task 6: Session discovery (encoding + listing)

**Files:**
- Create: `internal/wakilcore/sessions.go`
- Test: `internal/wakilcore/sessions_test.go`

**Interfaces:**
- Consumes: `Resolve` (Task 4).
- Produces: `EncodeRootPath(abs string) string`, type `SessionMeta{ID string; Root string; ModTime time.Time; FirstPrompt string}`, `ListSessions() ([]SessionMeta, error)` (all roots of the active project, newest first, worktrees matched by encoded-root prefix), `GetSession(id string) (SessionMeta, error)`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/sessions_test.go`:
```go
package wakilcore

import "testing"

func TestEncodeRootPath(t *testing.T) {
	cases := map[string]string{
		"/Users/operator/conductor/workspaces/wakil/amsterdam": "-Users-operator-conductor-workspaces-wakil-amsterdam",
		"/Users/operator/Desktop/scripts/wakil":                "-Users-operator-Desktop-scripts-wakil",
		"/Users/operator/.claude":                              "-Users-operator--claude",
	}
	for in, want := range cases {
		if got := EncodeRootPath(in); got != want {
			t.Errorf("EncodeRootPath(%q)=%q want %q", in, got, want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestEncodeRootPath -v`
Expected: FAIL (undefined: EncodeRootPath).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/sessions.go`:
```go
package wakilcore

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// EncodeRootPath mirrors Claude Code's lossy project-dir encoding: "/" and "."
// both become "-". Always encode a known path; never decode a directory name.
func EncodeRootPath(abs string) string {
	r := strings.NewReplacer("/", "-", ".", "-")
	return r.Replace(abs)
}

type SessionMeta struct {
	ID          string    `json:"id"`
	Root        string    `json:"root"`
	ModTime     time.Time `json:"modTime"`
	FirstPrompt string    `json:"firstPrompt,omitempty"`
}

func sessionsRoot() string {
	cfg := os.Getenv("CLAUDE_CONFIG_DIR")
	if cfg == "" {
		home, _ := os.UserHomeDir()
		cfg = filepath.Join(home, ".claude")
	}
	return filepath.Join(cfg, "projects")
}

func ListSessions() ([]SessionMeta, error) {
	r, err := Resolve()
	if err != nil {
		return nil, err
	}
	base := sessionsRoot()
	entries, err := os.ReadDir(base)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	// Build encoded prefixes for each root (project dir + each root path joined).
	projDir := filepath.Dir(filepath.Dir(r.ProjectPath)) // <projectDir>/.wakil/project.json -> <projectDir>
	var prefixes []string
	for _, root := range r.Project.Roots {
		abs := filepath.Clean(filepath.Join(projDir, root.Path))
		prefixes = append(prefixes, EncodeRootPath(abs))
	}
	var out []SessionMeta
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		matched := false
		for _, p := range prefixes {
			if name == p || strings.HasPrefix(name, p) {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(base, name))
		for _, f := range files {
			if !strings.HasSuffix(f.Name(), ".jsonl") {
				continue
			}
			info, _ := f.Info()
			out = append(out, SessionMeta{
				ID:      strings.TrimSuffix(f.Name(), ".jsonl"),
				Root:    name,
				ModTime: info.ModTime(),
			})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out, nil
}

func GetSession(id string) (SessionMeta, error) {
	all, err := ListSessions()
	if err != nil {
		return SessionMeta{}, err
	}
	for _, s := range all {
		if s.ID == id {
			s.FirstPrompt = firstPrompt(filepath.Join(sessionsRoot(), s.Root, id+".jsonl"))
			return s, nil
		}
	}
	return SessionMeta{}, UserError("session not found for the active project: " + id)
}

func firstPrompt(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	for sc.Scan() {
		var rec map[string]any
		if json.Unmarshal(sc.Bytes(), &rec) != nil {
			continue
		}
		if c, ok := rec["content"].(string); ok && c != "" && rec["type"] == "user" {
			return c
		}
	}
	return ""
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestEncodeRootPath -v`
Expected: PASS.

- [ ] **Step 5: Verify encoding against the live machine**

Run:
```bash
ls ~/.claude/projects | head
```
Confirm at least one directory name equals `EncodeRootPath` of its real path (e.g. this workspace). If a mismatch appears (extra characters replaced), extend the `strings.NewReplacer` set and update the test, then re-run Step 4.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/sessions.go internal/wakilcore/sessions_test.go
git commit -m "feat(wakilcore): session discovery with lossy-encoding matcher"
```

---

## Task 7: `wakil-ctx` MCP server

**Files:**
- Create: `cmd/wakil-ctx/main.go`
- Test: `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: `Resolve`, `SetProjectChecked`, `LoadRegistry`, `ReadActive`, `WriteActive`, `ListSessions`, `GetSession`, `IsUserError` (wakilcore).
- Produces: MCP server binary exposing tools `get_context`, `list_projects`, `set_project`, `set_environment`, `list_environments`, `list_sessions`, `get_session`. Handler helper `toolErr(err) error` converting user errors to clean MCP errors.

- [ ] **Step 1: Write the failing test** (business logic, not the stdio loop)

Create `cmd/wakil-ctx/main_test.go`:
```go
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func TestSetEnvironmentValidates(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "/x/.claude-initech")

	pdir := filepath.Join(home, "proj")
	os.MkdirAll(filepath.Join(pdir, ".wakil"), 0o755)
	pp := filepath.Join(pdir, ".wakil", "project.json")
	os.WriteFile(pp, []byte(`{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{"staging":{"databases":[]}}}`), 0o644)
	os.MkdirAll(wakilcore.WakilDir(), 0o755)
	reg, _ := json.Marshal(map[string]string{"proj": pp})
	os.WriteFile(filepath.Join(wakilcore.WakilDir(), "projects.json"), reg, 0o644)
	wakilcore.SetProjectChecked("proj")

	if err := setEnvironment("staging"); err != nil {
		t.Fatalf("valid env should pass: %v", err)
	}
	if err := setEnvironment("nope"); err == nil {
		t.Fatal("unknown env must be rejected")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/wakil-ctx/ -run TestSetEnvironmentValidates -v`
Expected: FAIL (undefined: setEnvironment).

- [ ] **Step 3: Write minimal implementation**

Create `cmd/wakil-ctx/main.go`:
```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type empty struct{}
type nameArg struct {
	Name string `json:"name" jsonschema:"the name to select"`
}
type idArg struct {
	ID string `json:"id" jsonschema:"the session id"`
}

func toolErr(err error) error {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return &mcp.CallToolResultError{Message: msg} // human sentence, no stack
	}
	return err
}

func setEnvironment(name string) error {
	r, err := wakilcore.Resolve()
	if err != nil {
		return err
	}
	if _, ok := r.Project.Environments[name]; !ok {
		return wakilcore.UserError("unknown environment: " + name)
	}
	a, _ := wakilcore.ReadActive()
	a.Environment = name
	return wakilcore.WriteActive(a)
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-ctx", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "get_context", Description: "Show the active org, project, roots, environment, and scopes."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, *wakilcore.Resolved, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_projects", Description: "List projects in the active organization."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, map[string]string, error) {
			reg, err := wakilcore.LoadRegistry()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			out := map[string]string{}
			for name, path := range reg {
				if p, e := wakilcore.LoadProject(path); e == nil && p.Org == wakilcore.CurrentOrg() {
					out[name] = path
				}
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_project", Description: "Switch the active project (must belong to the active org)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nameArg) (*mcp.CallToolResult, empty, error) {
			return nil, empty{}, toolErr(wakilcore.SetProjectChecked(a.Name))
		})

	mcp.AddTool(s, &mcp.Tool{Name: "set_environment", Description: "Switch the active environment within the active project."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nameArg) (*mcp.CallToolResult, empty, error) {
			return nil, empty{}, toolErr(setEnvironment(a.Name))
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_environments", Description: "List the active project's environments and which are read-only."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, map[string]bool, error) {
			r, err := wakilcore.Resolve()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			out := map[string]bool{}
			for name, env := range r.Project.Environments {
				ro := false
				for _, d := range env.Databases {
					if d.ReadOnly {
						ro = true
					}
				}
				out[name] = ro
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_sessions", Description: "List Claude Code sessions for the active project's roots, newest first."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, []wakilcore.SessionMeta, error) {
			out, err := wakilcore.ListSessions()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_session", Description: "Get metadata and first prompt for one session."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a idArg) (*mcp.CallToolResult, wakilcore.SessionMeta, error) {
			out, err := wakilcore.GetSession(a.ID)
			if err != nil {
				return nil, wakilcore.SessionMeta{}, toolErr(err)
			}
			return nil, out, nil
		})

	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./cmd/wakil-ctx/ -run TestSetEnvironmentValidates -v`
Expected: PASS.

> If `mcp.CallToolResultError` is not the SDK's error-result type, consult the SDK docs (`go doc github.com/modelcontextprotocol/go-sdk/mcp`) for the current way to return a tool error carrying a message, and adjust `toolErr`. The behavior — return the human sentence, never a stack — is the contract.

- [ ] **Step 5: Build the binary**

Run: `CGO_ENABLED=0 go build -o bin/wakil-ctx ./cmd/wakil-ctx`
Expected: builds; `bin/wakil-ctx` exists.

- [ ] **Step 6: Commit**

```bash
git add cmd/wakil-ctx/
git commit -m "feat(wakil-ctx): context + session MCP server"
```

---

## Task 8: Read-only gates (SQL + HTTP)

**Files:**
- Create: `internal/wakilcore/readonly.go`
- Test: `internal/wakilcore/readonly_test.go`

**Interfaces:**
- Produces: `AssertSQLReadOnly(sql string) error`, `AssertHTTPReadOnly(method string) error`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/readonly_test.go`:
```go
package wakilcore

import "testing"

func TestAssertSQLReadOnly(t *testing.T) {
	ok := []string{
		"SELECT * FROM users WHERE id = 42",
		"  select 1",
		"EXPLAIN SELECT 1",
		"SHOW TABLES",
		"/* c */ SELECT 1",
	}
	for _, q := range ok {
		if err := AssertSQLReadOnly(q); err != nil {
			t.Errorf("should allow %q: %v", q, err)
		}
	}
	bad := []string{
		"INSERT INTO t VALUES (1)",
		"UPDATE t SET x=1",
		"DELETE FROM t",
		"DROP TABLE t",
		"SELECT 1; DROP TABLE t",
		"select 1; delete from t",
		"WITH x AS (SELECT 1) DELETE FROM t",
		"TRUNCATE t",
	}
	for _, q := range bad {
		if err := AssertSQLReadOnly(q); err == nil {
			t.Errorf("should reject %q", q)
		}
	}
}

func TestAssertHTTPReadOnly(t *testing.T) {
	for _, m := range []string{"GET", "get", "HEAD"} {
		if err := AssertHTTPReadOnly(m); err != nil {
			t.Errorf("allow %q: %v", m, err)
		}
	}
	for _, m := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		if err := AssertHTTPReadOnly(m); err == nil {
			t.Errorf("reject %q", m)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run 'ReadOnly' -v`
Expected: FAIL (undefined functions).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/readonly.go`:
```go
package wakilcore

import (
	"regexp"
	"strings"
)

var sqlLineComment = regexp.MustCompile(`--[^\n]*`)
var sqlBlockComment = regexp.MustCompile(`(?s)/\*.*?\*/`)
var writeKeyword = regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|REPLACE|MERGE|GRANT|REVOKE|CALL|LOCK|RENAME|SET)\b`)

func stripSQLComments(s string) string {
	s = sqlBlockComment.ReplaceAllString(s, " ")
	s = sqlLineComment.ReplaceAllString(s, " ")
	return s
}

// AssertSQLReadOnly allows only single read statements. It strips comments,
// rejects any statement after a ";", and rejects any write keyword anywhere
// (covers CTEs that end in DELETE and comment-smuggled writes).
func AssertSQLReadOnly(sql string) error {
	clean := strings.TrimSpace(stripSQLComments(sql))
	if clean == "" {
		return UserError("empty query")
	}
	// Reject anything after a statement separator (ignoring a trailing ";").
	trimmed := strings.TrimRight(clean, "; \t\n")
	if strings.Contains(trimmed, ";") {
		return UserError("multiple statements are not allowed in read-only mode")
	}
	upper := strings.ToUpper(strings.TrimSpace(trimmed))
	if !(strings.HasPrefix(upper, "SELECT") || strings.HasPrefix(upper, "EXPLAIN") ||
		strings.HasPrefix(upper, "SHOW") || strings.HasPrefix(upper, "WITH")) {
		return UserError("only SELECT/EXPLAIN/SHOW queries are allowed (read-only)")
	}
	if writeKeyword.MatchString(trimmed) {
		return UserError("query contains a write operation and was blocked (read-only)")
	}
	return nil
}

func AssertHTTPReadOnly(method string) error {
	switch strings.ToUpper(method) {
	case "GET", "HEAD":
		return nil
	default:
		return UserError("only GET/HEAD requests are allowed in read-only mode")
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run 'ReadOnly' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/readonly.go internal/wakilcore/readonly_test.go
git commit -m "feat(wakilcore): SQL + HTTP read-only gates with adversarial coverage"
```

---

## Task 9: `DbDriver` interface + driver registry

**Files:**
- Create: `internal/wakilcore/dbdriver.go`
- Test: `internal/wakilcore/dbdriver_test.go`

**Interfaces:**
- Produces: types `Connection{Ref, URL string; ReadOnly bool}`, `Container{Name, Kind string}`, `Column{Name, Type string; Key bool}`, `Schema{Columns []Column}`, `Rows{Columns []string; Rows [][]any; Millis int64}`, `QuerySpec{Raw string}`; interface `DbDriver` (as in spec); `RegisterDriver(kind string, d DbDriver)`, `GetDriver(kind string) (DbDriver, error)`, `Conn` interface `{ ListContainers(ctx)([]Container,error); Describe(ctx,name)(Schema,error); Read(ctx,QuerySpec,int)(Rows,error); Close()error }`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/dbdriver_test.go`:
```go
package wakilcore

import (
	"context"
	"testing"
)

type fakeDriver struct{}

func (fakeDriver) Kind() string { return "fake" }
func (fakeDriver) Connect(context.Context, Connection) (Conn, error) { return nil, nil }
func (fakeDriver) AssertReadOnly(QuerySpec) error { return nil }

func TestDriverRegistry(t *testing.T) {
	RegisterDriver("fake", fakeDriver{})
	d, err := GetDriver("fake")
	if err != nil || d.Kind() != "fake" {
		t.Fatalf("registry miss: %v", err)
	}
	if _, err := GetDriver("nope"); err == nil {
		t.Fatal("unknown driver must error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestDriverRegistry -v`
Expected: FAIL (undefined types).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/dbdriver.go`:
```go
package wakilcore

import "context"

type Connection struct {
	Ref      string
	URL      string
	ReadOnly bool
}

type Container struct {
	Name string `json:"name"`
	Kind string `json:"kind"` // "table" | "collection"
}

type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
	Key  bool   `json:"key,omitempty"`
}

type Schema struct {
	Columns []Column `json:"columns"`
}

type Rows struct {
	Columns []string `json:"columns"`
	Rows    [][]any  `json:"rows"`
	Millis  int64    `json:"millis"`
}

type QuerySpec struct {
	Raw string
}

type Conn interface {
	ListContainers(ctx context.Context) ([]Container, error)
	Describe(ctx context.Context, name string) (Schema, error)
	Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error)
	Close() error
}

type DbDriver interface {
	Kind() string
	Connect(ctx context.Context, conn Connection) (Conn, error)
	AssertReadOnly(spec QuerySpec) error
}

var drivers = map[string]DbDriver{}

func RegisterDriver(kind string, d DbDriver) { drivers[kind] = d }

func GetDriver(kind string) (DbDriver, error) {
	d, ok := drivers[kind]
	if !ok {
		return nil, UserError("no driver for database kind: " + kind)
	}
	return d, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestDriverRegistry -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/dbdriver.go internal/wakilcore/dbdriver_test.go
git commit -m "feat(wakilcore): DbDriver interface + registry + shared types"
```

---

## Task 10: SQLite driver (proves the pipeline end-to-end, no Docker)

**Files:**
- Create: `internal/wakilcore/driver_sqlite.go`
- Test: `internal/wakilcore/driver_sqlite_test.go`

**Interfaces:**
- Consumes: `DbDriver`, `Conn`, `AssertSQLReadOnly`, `RegisterDriver` (Tasks 8–9).
- Produces: `sqliteDriver` registered under `"sqlite"` in `init()`. `Connection.URL` is a file path (or `file:...` DSN).

- [ ] **Step 1: Add the dependency**

Run: `go get modernc.org/sqlite`

- [ ] **Step 2: Write the failing test**

Create `internal/wakilcore/driver_sqlite_test.go`:
```go
package wakilcore

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func seedSQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
		INSERT INTO customers (id,name) VALUES (42,'Layla'),(43,'Omar');`); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSQLiteReadAndGate(t *testing.T) {
	path := seedSQLite(t)
	d, err := GetDriver("sqlite")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := d.Connect(context.Background(), Connection{URL: path})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT id,name FROM customers WHERE id=42"}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows.Rows) != 1 || rows.Rows[0][1] != "Layla" {
		t.Fatalf("bad rows: %+v", rows)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: "DELETE FROM customers"}); err == nil {
		t.Fatal("driver must reject writes")
	}
	cs, err := conn.ListContainers(context.Background())
	if err != nil || len(cs) == 0 || cs[0].Kind != "table" {
		t.Fatalf("containers: %+v %v", cs, err)
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestSQLiteReadAndGate -v`
Expected: FAIL (sqlite driver not registered).

- [ ] **Step 4: Write minimal implementation**

Create `internal/wakilcore/driver_sqlite.go`:
```go
package wakilcore

import (
	"context"
	"database/sql"
	"time"

	_ "modernc.org/sqlite"
)

func init() { RegisterDriver("sqlite", sqliteDriver{}) }

type sqliteDriver struct{}

func (sqliteDriver) Kind() string { return "sqlite" }

func (sqliteDriver) AssertReadOnly(spec QuerySpec) error { return AssertSQLReadOnly(spec.Raw) }

func (sqliteDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	db, err := sql.Open("sqlite", c.URL)
	if err != nil {
		return nil, UserError("cannot open sqlite database: " + err.Error())
	}
	if err := db.PingContext(ctx); err != nil {
		return nil, UserError("sqlite database unreachable: " + err.Error())
	}
	return &sqlConn{db: db, gate: AssertSQLReadOnly, listSQL: "SELECT name FROM sqlite_master WHERE type='table'"}, nil
}
```

Create `internal/wakilcore/sqlconn.go` (shared by SQLite and MySQL):
```go
package wakilcore

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type sqlConn struct {
	db      *sql.DB
	gate    func(string) error
	listSQL string
}

func (c *sqlConn) Close() error { return c.db.Close() }

func (c *sqlConn) ListContainers(ctx context.Context) ([]Container, error) {
	rows, err := c.db.QueryContext(ctx, c.listSQL)
	if err != nil {
		return nil, UserError("cannot list tables: " + err.Error())
	}
	defer rows.Close()
	var out []Container
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, Container{Name: name, Kind: "table"})
	}
	return out, rows.Err()
}

func (c *sqlConn) Describe(ctx context.Context, name string) (Schema, error) {
	// Portable: read zero rows and use column types.
	rows, err := c.db.QueryContext(ctx, "SELECT * FROM "+quoteIdent(name)+" LIMIT 0")
	if err != nil {
		return Schema{}, UserError("cannot describe " + name + ": " + err.Error())
	}
	defer rows.Close()
	cts, _ := rows.ColumnTypes()
	var sch Schema
	for _, ct := range cts {
		sch.Columns = append(sch.Columns, Column{Name: ct.Name(), Type: ct.DatabaseTypeName()})
	}
	return sch, nil
}

func (c *sqlConn) Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) {
	if err := c.gate(spec.Raw); err != nil {
		return Rows{}, err
	}
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	q := spec.Raw
	start := time.Now()
	rows, err := c.db.QueryContext(ctx, q)
	if err != nil {
		return Rows{}, UserError("query failed: " + err.Error())
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out Rows
	out.Columns = cols
	for rows.Next() && len(out.Rows) < limit {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return Rows{}, err
		}
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				vals[i] = string(b)
			}
		}
		out.Rows = append(out.Rows, vals)
	}
	out.Millis = time.Since(start).Milliseconds()
	return out, rows.Err()
}

func quoteIdent(s string) string { return fmt.Sprintf("%q", s) }
```

Remove the unused `time` import from `driver_sqlite.go` (only `sqlconn.go` uses it).

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestSQLiteReadAndGate -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/driver_sqlite.go internal/wakilcore/sqlconn.go internal/wakilcore/driver_sqlite_test.go go.mod go.sum
git commit -m "feat(wakilcore): sqlite driver + shared sql connection"
```

---

## Task 11: MySQL driver

**Files:**
- Create: `internal/wakilcore/driver_mysql.go`
- Test: `internal/wakilcore/driver_mysql_test.go`

**Interfaces:**
- Consumes: `sqlConn`, `AssertSQLReadOnly` (Tasks 8, 10).
- Produces: `mysqlDriver` registered under `"mysql"`. `Connection.URL` is a Go MySQL DSN (`user:pass@tcp(host:port)/db`).

- [ ] **Step 1: Add the dependency**

Run: `go get github.com/go-sql-driver/mysql`

- [ ] **Step 2: Write the failing test** (Docker-gated)

Create `internal/wakilcore/driver_mysql_test.go`:
```go
package wakilcore

import (
	"context"
	"database/sql"
	"os"
	"testing"

	_ "github.com/go-sql-driver/mysql"
)

// Requires: docker run -d --name wakil-mysql -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=app -p 3307:3306 mysql:8
// Then: export WAKIL_MYSQL_DSN='root:root@tcp(127.0.0.1:3307)/app'
func TestMySQLReadAndGate(t *testing.T) {
	dsn := os.Getenv("WAKIL_MYSQL_DSN")
	if dsn == "" {
		t.Skip("set WAKIL_MYSQL_DSN to run the MySQL driver test")
	}
	raw, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	raw.Exec("DROP TABLE IF EXISTS customers")
	raw.Exec("CREATE TABLE customers (id INT PRIMARY KEY, name VARCHAR(64))")
	raw.Exec("INSERT INTO customers VALUES (42,'Layla')")
	raw.Close()

	d, _ := GetDriver("mysql")
	conn, err := d.Connect(context.Background(), Connection{URL: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	rows, err := conn.Read(context.Background(), QuerySpec{Raw: "SELECT name FROM customers WHERE id=42"}, 10)
	if err != nil || len(rows.Rows) != 1 || rows.Rows[0][0] != "Layla" {
		t.Fatalf("bad read: %+v %v", rows, err)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: "UPDATE customers SET name='x'"}); err == nil {
		t.Fatal("must reject write")
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestMySQLReadAndGate -v`
Expected: FAIL (mysql driver not registered) — or SKIP if DSN unset once the impl exists.

- [ ] **Step 4: Write minimal implementation**

Create `internal/wakilcore/driver_mysql.go`:
```go
package wakilcore

import (
	"context"
	"database/sql"

	_ "github.com/go-sql-driver/mysql"
)

func init() { RegisterDriver("mysql", mysqlDriver{}) }

type mysqlDriver struct{}

func (mysqlDriver) Kind() string { return "mysql" }

func (mysqlDriver) AssertReadOnly(spec QuerySpec) error { return AssertSQLReadOnly(spec.Raw) }

func (mysqlDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	db, err := sql.Open("mysql", c.URL)
	if err != nil {
		return nil, UserError("cannot open mysql: " + err.Error())
	}
	if err := db.PingContext(ctx); err != nil {
		return nil, UserError("mysql unreachable: " + err.Error())
	}
	// Belt-and-braces: force the session read-only where the server allows it.
	db.ExecContext(ctx, "SET SESSION TRANSACTION READ ONLY")
	return &sqlConn{db: db, gate: AssertSQLReadOnly, listSQL: "SHOW TABLES"}, nil
}
```

- [ ] **Step 5: Run the test**

Start MySQL (see test comment), export `WAKIL_MYSQL_DSN`, then:
Run: `go test ./internal/wakilcore/ -run TestMySQLReadAndGate -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/wakilcore/driver_mysql.go internal/wakilcore/driver_mysql_test.go go.mod go.sum
git commit -m "feat(wakilcore): mysql driver (read-only session + gate)"
```

---

## Task 12: Mongo driver + Mongo read-only gate

**Files:**
- Create: `internal/wakilcore/driver_mongo.go`
- Test: `internal/wakilcore/driver_mongo_test.go`

**Interfaces:**
- Consumes: `DbDriver`, `Conn` (Task 9).
- Produces: `mongoDriver` registered under `"mongo"`. Mongo `QuerySpec.Raw` is JSON: `{"collection":"users","op":"find","filter":{...}}` or `{"collection":"e","op":"aggregate","pipeline":[...]}`. Adds `AssertMongoReadOnly(raw string) error` in `readonly.go`.

- [ ] **Step 1: Add the Mongo read-only gate test**

Append to `internal/wakilcore/readonly_test.go`:
```go
func TestAssertMongoReadOnly(t *testing.T) {
	ok := []string{
		`{"collection":"u","op":"find","filter":{"id":42}}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$match":{"x":1}}]}`,
		`{"collection":"u","op":"count"}`,
	}
	for _, q := range ok {
		if err := AssertMongoReadOnly(q); err != nil {
			t.Errorf("allow %q: %v", q, err)
		}
	}
	bad := []string{
		`{"collection":"u","op":"insertOne","doc":{}}`,
		`{"collection":"u","op":"updateMany"}`,
		`{"collection":"u","op":"deleteOne"}`,
		`{"collection":"u","op":"bulkWrite"}`,
		`{"collection":"u","op":"findAndModify"}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$out":"copy"}]}`,
		`{"collection":"u","op":"aggregate","pipeline":[{"$merge":"copy"}]}`,
	}
	for _, q := range bad {
		if err := AssertMongoReadOnly(q); err == nil {
			t.Errorf("reject %q", q)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestAssertMongoReadOnly -v`
Expected: FAIL (undefined: AssertMongoReadOnly).

- [ ] **Step 3: Implement the Mongo gate**

Append to `internal/wakilcore/readonly.go`:
```go
import "encoding/json"

var mongoReadOps = map[string]bool{"find": true, "aggregate": true, "count": true, "distinct": true}

type mongoSpec struct {
	Collection string           `json:"collection"`
	Op         string           `json:"op"`
	Filter     json.RawMessage  `json:"filter,omitempty"`
	Pipeline   []map[string]any `json:"pipeline,omitempty"`
}

func parseMongo(raw string) (mongoSpec, error) {
	var m mongoSpec
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return m, UserError("invalid mongo query JSON: " + err.Error())
	}
	if m.Collection == "" || m.Op == "" {
		return m, UserError("mongo query needs collection and op")
	}
	return m, nil
}

func AssertMongoReadOnly(raw string) error {
	m, err := parseMongo(raw)
	if err != nil {
		return err
	}
	if !mongoReadOps[m.Op] {
		return UserError("mongo op " + m.Op + " is a write and was blocked (read-only)")
	}
	for _, stage := range m.Pipeline {
		if _, bad := stage["$out"]; bad {
			return UserError("aggregate $out writes data and was blocked (read-only)")
		}
		if _, bad := stage["$merge"]; bad {
			return UserError("aggregate $merge writes data and was blocked (read-only)")
		}
	}
	return nil
}
```
(Consolidate the `import` with the existing import block in `readonly.go`.)

- [ ] **Step 4: Run to verify the gate passes**

Run: `go test ./internal/wakilcore/ -run TestAssertMongoReadOnly -v`
Expected: PASS.

- [ ] **Step 5: Add the Mongo driver + integration test (Docker-gated)**

Run: `go get go.mongodb.org/mongo-driver/mongo`

Create `internal/wakilcore/driver_mongo_test.go`:
```go
package wakilcore

import (
	"context"
	"os"
	"testing"
)

// docker run -d --name wakil-mongo -p 27018:27017 mongo:7
// export WAKIL_MONGO_URI='mongodb://127.0.0.1:27018/app'
func TestMongoReadAndGate(t *testing.T) {
	uri := os.Getenv("WAKIL_MONGO_URI")
	if uri == "" {
		t.Skip("set WAKIL_MONGO_URI to run the Mongo driver test")
	}
	d, _ := GetDriver("mongo")
	conn, err := d.Connect(context.Background(), Connection{URL: uri})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, err = conn.Read(context.Background(),
		QuerySpec{Raw: `{"collection":"customers","op":"find","filter":{}}`}, 10)
	if err != nil {
		t.Fatalf("find failed: %v", err)
	}
	if err := d.AssertReadOnly(QuerySpec{Raw: `{"collection":"c","op":"deleteMany"}`}); err == nil {
		t.Fatal("must reject write")
	}
}
```

Create `internal/wakilcore/driver_mongo.go`:
```go
package wakilcore

import (
	"context"
	"encoding/json"
	"time"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

func init() { RegisterDriver("mongo", mongoDriver{}) }

type mongoDriver struct{}

func (mongoDriver) Kind() string { return "mongo" }
func (mongoDriver) AssertReadOnly(spec QuerySpec) error { return AssertMongoReadOnly(spec.Raw) }

func (mongoDriver) Connect(ctx context.Context, c Connection) (Conn, error) {
	cli, err := mongo.Connect(ctx, options.Client().ApplyURI(c.URL))
	if err != nil {
		return nil, UserError("cannot connect to mongo: " + err.Error())
	}
	if err := cli.Ping(ctx, nil); err != nil {
		return nil, UserError("mongo unreachable: " + err.Error())
	}
	// Database name comes from the URI path.
	db := cli.Database(databaseFromURI(c.URL))
	return &mongoConn{cli: cli, db: db}, nil
}

type mongoConn struct {
	cli *mongo.Client
	db  *mongo.Database
}

func (m *mongoConn) Close() error { return m.cli.Disconnect(context.Background()) }

func (m *mongoConn) ListContainers(ctx context.Context) ([]Container, error) {
	names, err := m.db.ListCollectionNames(ctx, map[string]any{})
	if err != nil {
		return nil, UserError("cannot list collections: " + err.Error())
	}
	var out []Container
	for _, n := range names {
		out = append(out, Container{Name: n, Kind: "collection"})
	}
	return out, nil
}

func (m *mongoConn) Describe(ctx context.Context, name string) (Schema, error) {
	// Infer fields from one document.
	var doc map[string]any
	err := m.db.Collection(name).FindOne(ctx, map[string]any{}).Decode(&doc)
	if err != nil {
		return Schema{}, nil // empty collection: no inferred fields
	}
	var sch Schema
	for k, v := range doc {
		sch.Columns = append(sch.Columns, Column{Name: k, Type: goType(v)})
	}
	return sch, nil
}

func (m *mongoConn) Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) {
	if err := AssertMongoReadOnly(spec.Raw); err != nil {
		return Rows{}, err
	}
	var q mongoSpec
	json.Unmarshal([]byte(spec.Raw), &q)
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	start := time.Now()
	coll := m.db.Collection(q.Collection)
	var cursor *mongo.Cursor
	var err error
	switch q.Op {
	case "find":
		filter := map[string]any{}
		if len(q.Filter) > 0 {
			json.Unmarshal(q.Filter, &filter)
		}
		cursor, err = coll.Find(ctx, filter, options.Find().SetLimit(int64(limit)))
	case "aggregate":
		cursor, err = coll.Aggregate(ctx, q.Pipeline)
	default:
		return Rows{}, UserError("op " + q.Op + " not supported for reads yet")
	}
	if err != nil {
		return Rows{}, UserError("mongo read failed: " + err.Error())
	}
	defer cursor.Close(ctx)
	var docs []map[string]any
	if err := cursor.All(ctx, &docs); err != nil {
		return Rows{}, err
	}
	return docsToRows(docs, limit, time.Since(start).Milliseconds()), nil
}
```

Create `internal/wakilcore/mongo_util.go`:
```go
package wakilcore

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
)

func databaseFromURI(uri string) string {
	u, err := url.Parse(uri)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(u.Path, "/")
}

func goType(v any) string { return fmt.Sprintf("%T", v) }

// docsToRows flattens heterogeneous documents into a columnar shape using the
// union of top-level keys (sorted, _id first) so the MCP output matches the SQL shape.
func docsToRows(docs []map[string]any, limit int, millis int64) Rows {
	keySet := map[string]bool{}
	for _, d := range docs {
		for k := range d {
			keySet[k] = true
		}
	}
	var cols []string
	for k := range keySet {
		if k != "_id" {
			cols = append(cols, k)
		}
	}
	sort.Strings(cols)
	if keySet["_id"] {
		cols = append([]string{"_id"}, cols...)
	}
	var out Rows
	out.Columns = cols
	out.Millis = millis
	for i, d := range docs {
		if i >= limit {
			break
		}
		row := make([]any, len(cols))
		for j, c := range cols {
			row[j] = d[c]
		}
		out.Rows = append(out.Rows, row)
	}
	return out
}
```

- [ ] **Step 6: Run the tests**

Run (gate first): `go test ./internal/wakilcore/ -run TestAssertMongoReadOnly -v` → PASS.
Then with Mongo up + `WAKIL_MONGO_URI` set: `go test ./internal/wakilcore/ -run TestMongoReadAndGate -v` → PASS.

> If the installed Mongo driver is v2 (`go.mongodb.org/mongo-driver/v2/mongo`), update the two imports and the `mongo.Connect` signature per `go doc`; the `Conn` behavior is unchanged.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/driver_mongo.go internal/wakilcore/mongo_util.go internal/wakilcore/driver_mongo_test.go internal/wakilcore/readonly.go internal/wakilcore/readonly_test.go go.mod go.sum
git commit -m "feat(wakilcore): mongo driver + mongo read-only gate"
```

---

## Task 13: `wakil-db` MCP server (multi-connection dispatch)

**Files:**
- Create: `cmd/wakil-db/main.go`, `internal/wakilcore/dbresolve.go`
- Test: `internal/wakilcore/dbresolve_test.go`

**Interfaces:**
- Consumes: `ResolveEnvironment`, `GetDriver`, `SecretGet`, `Database`, `Connection` (wakilcore).
- Produces: `PickDatabase(env Environment, name string) (Database, error)` (name optional when exactly one), `OpenDatabase(ctx, Database) (Conn, error)` (resolves ref → Keychain → Connection, applies `readOnly`). MCP tools `list_databases`, `list_tables`, `describe_table`, `query`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/dbresolve_test.go`:
```go
package wakilcore

import "testing"

func TestPickDatabase(t *testing.T) {
	env := Environment{Databases: []Database{
		{Name: "core", Driver: "mysql", Ref: "a"},
		{Name: "events", Driver: "sqlite", Ref: "b"},
	}}
	if _, err := PickDatabase(env, ""); err == nil {
		t.Fatal("ambiguous empty name with 2 dbs must error")
	}
	d, err := PickDatabase(env, "events")
	if err != nil || d.Driver != "sqlite" {
		t.Fatalf("pick events: %+v %v", d, err)
	}
	single := Environment{Databases: []Database{{Name: "only", Driver: "sqlite", Ref: "x"}}}
	d, err = PickDatabase(single, "")
	if err != nil || d.Name != "only" {
		t.Fatalf("single default: %+v %v", d, err)
	}
	if _, err := PickDatabase(env, "nope"); err == nil {
		t.Fatal("unknown name must error")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestPickDatabase -v`
Expected: FAIL (undefined: PickDatabase).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/dbresolve.go`:
```go
package wakilcore

import "context"

func PickDatabase(env Environment, name string) (Database, error) {
	if len(env.Databases) == 0 {
		return Database{}, UserError("no databases configured for this environment")
	}
	if name == "" {
		if len(env.Databases) == 1 {
			return env.Databases[0], nil
		}
		return Database{}, UserError("multiple databases in this environment — name one of them")
	}
	for _, d := range env.Databases {
		if d.Name == name {
			return d, nil
		}
	}
	return Database{}, UserError("no database named " + name + " in this environment")
}

func OpenDatabase(ctx context.Context, d Database) (Conn, error) {
	drv, err := GetDriver(d.Driver)
	if err != nil {
		return nil, err
	}
	url, err := SecretGet(d.Ref)
	if err != nil {
		return nil, err
	}
	return drv.Connect(ctx, Connection{Ref: d.Ref, URL: url, ReadOnly: d.ReadOnly})
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestPickDatabase -v`
Expected: PASS.

- [ ] **Step 5: Write the server**

Create `cmd/wakil-db/main.go`:
```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type dbArg struct {
	Database string `json:"database,omitempty" jsonschema:"connection name; optional when the environment has one database"`
}
type tableArg struct {
	Database string `json:"database,omitempty"`
	Name     string `json:"name" jsonschema:"table or collection name"`
}
type queryArg struct {
	Database string `json:"database,omitempty"`
	Query    string `json:"query" jsonschema:"SQL string, or a Mongo JSON spec {collection,op,filter|pipeline}"`
	Limit    int    `json:"limit,omitempty"`
}

func toolErr(err error) error {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return &mcp.CallToolResultError{Message: msg}
	}
	return err
}

func openPicked(ctx context.Context, name string) (wakilcore.Conn, error) {
	env, err := wakilcore.ResolveEnvironment()
	if err != nil {
		return nil, err
	}
	db, err := wakilcore.PickDatabase(env, name)
	if err != nil {
		return nil, err
	}
	return wakilcore.OpenDatabase(ctx, db)
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-db", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "list_databases", Description: "List the named database connections in the active environment."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ dbArg) (*mcp.CallToolResult, []wakilcore.Database, error) {
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			return nil, env.Databases, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_tables", Description: "List tables/collections for a database connection."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a dbArg) (*mcp.CallToolResult, []wakilcore.Container, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return nil, nil, toolErr(err)
			}
			defer conn.Close()
			out, err := conn.ListContainers(ctx)
			return nil, out, toolErr(err)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "describe_table", Description: "Describe a table/collection: columns/types or inferred fields."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a tableArg) (*mcp.CallToolResult, wakilcore.Schema, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return nil, wakilcore.Schema{}, toolErr(err)
			}
			defer conn.Close()
			out, err := conn.Describe(ctx, a.Name)
			return nil, out, toolErr(err)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "query", Description: "Run a read-only query and return rows. SQL string or Mongo JSON spec."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a queryArg) (*mcp.CallToolResult, wakilcore.Rows, error) {
			conn, err := openPicked(ctx, a.Database)
			if err != nil {
				return nil, wakilcore.Rows{}, toolErr(err)
			}
			defer conn.Close()
			out, err := conn.Read(ctx, wakilcore.QuerySpec{Raw: a.Query}, a.Limit)
			return nil, out, toolErr(err)
		})

	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 6: Build**

Run: `CGO_ENABLED=0 go build -o bin/wakil-db ./cmd/wakil-db`
Expected: builds.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/dbresolve.go internal/wakilcore/dbresolve_test.go cmd/wakil-db/
git commit -m "feat(wakil-db): multi-connection read-only database MCP server"
```

---

## Task 14: Jira client + `wakil-pm` server

**Files:**
- Create: `internal/wakilcore/jira.go`, `cmd/wakil-pm/main.go`
- Test: `internal/wakilcore/jira_test.go`

**Interfaces:**
- Consumes: `Resolve` (for `scopes.pm.projectKey`), `OrgConfigDir` auth.
- Produces: type `JiraClient{BaseURL, Email, Token string}`, `NewJiraFromEnv() (*JiraClient, error)` (reads Atlassian creds — see note), `Issue{Key, Summary, Status, Assignee, URL string}`, `(*JiraClient) MyIssues(ctx, projectKey string) ([]Issue, error)`, `SearchIssues(ctx, projectKey, jql string) ([]Issue, error)`, `GetIssue(ctx, key string) (Issue, error)`. MCP tools `my_issues`, `search_issues`, `get_issue`.

**Auth note:** the spec says wrap Jira REST directly, reusing the org's existing Atlassian OAuth. Reading Claude Code's stored MCP OAuth token is fragile. **For this task, source Jira credentials from environment/Keychain refs** (`WAKIL_JIRA_BASE`, and a Keychain ref `jira:<org>` holding `email:api_token`), which is the same ref→Keychain pattern used everywhere else and avoids depending on Claude Code's internal token store. Record this deviation in the spec's open questions.

- [ ] **Step 1: Write the failing test** (against `httptest`)

Create `internal/wakilcore/jira_test.go`:
```go
package wakilcore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestJiraMyIssuesScoped(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jql := r.URL.Query().Get("jql")
		if !strings.Contains(jql, "project = RAF") || !strings.Contains(jql, "assignee = currentUser()") {
			t.Errorf("jql not scoped: %q", jql)
		}
		w.Write([]byte(`{"issues":[{"key":"RAF-1","fields":{"summary":"Fix","status":{"name":"To Do"},"assignee":{"displayName":"Ada"}}}]}`))
	}))
	defer srv.Close()

	c := &JiraClient{BaseURL: srv.URL, Email: "e", Token: "t"}
	issues, err := c.MyIssues(context.Background(), "RAF")
	if err != nil {
		t.Fatal(err)
	}
	if len(issues) != 1 || issues[0].Key != "RAF-1" || issues[0].Summary != "Fix" {
		t.Fatalf("bad issues: %+v", issues)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestJiraMyIssuesScoped -v`
Expected: FAIL (undefined: JiraClient).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/jira.go`:
```go
package wakilcore

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type JiraClient struct {
	BaseURL string
	Email   string
	Token   string
	http    *http.Client
}

type Issue struct {
	Key      string `json:"key"`
	Summary  string `json:"summary"`
	Status   string `json:"status"`
	Assignee string `json:"assignee"`
	URL      string `json:"url"`
}

func NewJiraFromEnv() (*JiraClient, error) {
	base := os.Getenv("WAKIL_JIRA_BASE")
	if base == "" {
		return nil, UserError("Jira base URL not set — configure WAKIL_JIRA_BASE for this org")
	}
	creds, err := SecretGet("jira:" + CurrentOrg())
	if err != nil {
		return nil, UserError("not authenticated for " + CurrentOrg() + " Jira — run: wakil secrets set jira:" + CurrentOrg())
	}
	parts := strings.SplitN(creds, ":", 2)
	if len(parts) != 2 {
		return nil, UserError("stored Jira credential must be email:api_token")
	}
	return &JiraClient{BaseURL: base, Email: parts[0], Token: parts[1]}, nil
}

func (c *JiraClient) client() *http.Client {
	if c.http == nil {
		c.http = &http.Client{Timeout: 20 * time.Second}
	}
	return c.http
}

func (c *JiraClient) search(ctx context.Context, jql string) ([]Issue, error) {
	u := c.BaseURL + "/rest/api/2/search?jql=" + url.QueryEscape(jql) +
		"&fields=summary,status,assignee&maxResults=50"
	req, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	req.SetBasicAuth(c.Email, c.Token)
	req.Header.Set("Accept", "application/json")
	resp, err := c.client().Do(req)
	if err != nil {
		return nil, UserError("Jira unreachable: " + err.Error())
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return nil, UserError("re-auth " + CurrentOrg() + ": Jira rejected the stored credential")
	}
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return nil, UserError(fmt.Sprintf("Jira error %d: %s", resp.StatusCode, strings.TrimSpace(string(b))))
	}
	var raw struct {
		Issues []struct {
			Key    string `json:"key"`
			Fields struct {
				Summary string `json:"summary"`
				Status  struct {
					Name string `json:"name"`
				} `json:"status"`
				Assignee struct {
					DisplayName string `json:"displayName"`
				} `json:"assignee"`
			} `json:"fields"`
		} `json:"issues"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	var out []Issue
	for _, i := range raw.Issues {
		out = append(out, Issue{
			Key: i.Key, Summary: i.Fields.Summary,
			Status: i.Fields.Status.Name, Assignee: i.Fields.Assignee.DisplayName,
			URL: c.BaseURL + "/browse/" + i.Key,
		})
	}
	return out, nil
}

func (c *JiraClient) MyIssues(ctx context.Context, projectKey string) ([]Issue, error) {
	return c.search(ctx, fmt.Sprintf("project = %s AND assignee = currentUser() ORDER BY updated DESC", projectKey))
}

func (c *JiraClient) SearchIssues(ctx context.Context, projectKey, jql string) ([]Issue, error) {
	scoped := fmt.Sprintf("project = %s", projectKey)
	if strings.TrimSpace(jql) != "" {
		scoped += " AND (" + jql + ")"
	}
	return c.search(ctx, scoped)
}

func (c *JiraClient) GetIssue(ctx context.Context, key string) (Issue, error) {
	issues, err := c.search(ctx, "key = "+key)
	if err != nil {
		return Issue{}, err
	}
	if len(issues) == 0 {
		return Issue{}, UserError("issue not found: " + key)
	}
	return issues[0], nil
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestJiraMyIssuesScoped -v`
Expected: PASS.

- [ ] **Step 5: Write the server**

Create `cmd/wakil-pm/main.go`:
```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type empty struct{}
type jqlArg struct {
	JQL string `json:"jql,omitempty" jsonschema:"extra JQL, scoped to the active project automatically"`
}
type keyArg struct {
	Key string `json:"key" jsonschema:"issue key, e.g. RAF-142"`
}

func toolErr(err error) error {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return &mcp.CallToolResultError{Message: msg}
	}
	return err
}

func projectKey() (string, error) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return "", err
	}
	if r.Project.Scopes.PM == nil || r.Project.Scopes.PM.ProjectKey == "" {
		return "", wakilcore.UserError("this project has no Jira scope configured")
	}
	return r.Project.Scopes.PM.ProjectKey, nil
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-pm", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "my_issues", Description: "Issues assigned to you in the active project's Jira scope."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, []wakilcore.Issue, error) {
			key, err := projectKey()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			out, err := c.MyIssues(ctx, key)
			return nil, out, toolErr(err)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "search_issues", Description: "Search issues; automatically scoped to the active project."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a jqlArg) (*mcp.CallToolResult, []wakilcore.Issue, error) {
			key, err := projectKey()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return nil, nil, toolErr(err)
			}
			out, err := c.SearchIssues(ctx, key, a.JQL)
			return nil, out, toolErr(err)
		})

	mcp.AddTool(s, &mcp.Tool{Name: "get_issue", Description: "Fetch one issue by key."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a keyArg) (*mcp.CallToolResult, wakilcore.Issue, error) {
			c, err := wakilcore.NewJiraFromEnv()
			if err != nil {
				return nil, wakilcore.Issue{}, toolErr(err)
			}
			out, err := c.GetIssue(ctx, a.Key)
			return nil, out, toolErr(err)
		})

	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 6: Build**

Run: `CGO_ENABLED=0 go build -o bin/wakil-pm ./cmd/wakil-pm`
Expected: builds.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/jira.go internal/wakilcore/jira_test.go cmd/wakil-pm/
git commit -m "feat(wakil-pm): scoped read-only Jira MCP server"
```

---

## Task 15: `wakil-http` server

**Files:**
- Create: `internal/wakilcore/httpclient.go`, `cmd/wakil-http/main.go`
- Test: `internal/wakilcore/httpclient_test.go`

**Interfaces:**
- Consumes: `ResolveEnvironment` (for `env.API.BaseURL`), `AssertHTTPReadOnly`, `SecretGet` (for `env.API.AuthRef`).
- Produces: `HTTPResult{Status int; Headers map[string]string; Body string}`, `DoRequest(ctx, base, method, path string, query, headers map[string]string, authRef string) (HTTPResult, error)` (relative paths only; joins onto base; verb gate). MCP tool `request`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/httpclient_test.go`:
```go
package wakilcore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDoRequestGuardsAndJoins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/customers/42" {
			w.WriteHeader(200)
			w.Write([]byte(`{"id":42}`))
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()

	res, err := DoRequest(context.Background(), srv.URL, "GET", "/customers/42", nil, nil, "")
	if err != nil || res.Status != 200 {
		t.Fatalf("GET failed: %+v %v", res, err)
	}
	if _, err := DoRequest(context.Background(), srv.URL, "POST", "/customers", nil, nil, ""); err == nil {
		t.Fatal("POST must be rejected")
	}
	if _, err := DoRequest(context.Background(), srv.URL, "GET", "http://evil.example/x", nil, nil, ""); err == nil {
		t.Fatal("absolute path must be rejected")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestDoRequestGuardsAndJoins -v`
Expected: FAIL (undefined: DoRequest).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/httpclient.go`:
```go
package wakilcore

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type HTTPResult struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

func DoRequest(ctx context.Context, base, method, path string, query, headers map[string]string, authRef string) (HTTPResult, error) {
	if err := AssertHTTPReadOnly(method); err != nil {
		return HTTPResult{}, err
	}
	if strings.Contains(path, "://") || strings.HasPrefix(path, "//") {
		return HTTPResult{}, UserError("only relative paths are allowed; requests are bound to the environment's baseUrl")
	}
	u, err := url.Parse(strings.TrimRight(base, "/") + "/" + strings.TrimLeft(path, "/"))
	if err != nil {
		return HTTPResult{}, UserError("bad path: " + err.Error())
	}
	q := u.Query()
	for k, v := range query {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()

	req, _ := http.NewRequestWithContext(ctx, strings.ToUpper(method), u.String(), nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if authRef != "" {
		if tok, err := SecretGet(authRef); err == nil {
			req.Header.Set("Authorization", tok)
		}
	}
	cli := &http.Client{Timeout: 20 * time.Second}
	resp, err := cli.Do(req)
	if err != nil {
		return HTTPResult{}, UserError("request failed: " + err.Error())
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	hs := map[string]string{}
	for k := range resp.Header {
		hs[k] = resp.Header.Get(k)
	}
	return HTTPResult{Status: resp.StatusCode, Headers: hs, Body: string(body)}, nil
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestDoRequestGuardsAndJoins -v`
Expected: PASS.

- [ ] **Step 5: Write the server**

Create `cmd/wakil-http/main.go`:
```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type reqArg struct {
	Method  string            `json:"method" jsonschema:"GET or HEAD"`
	Path    string            `json:"path" jsonschema:"relative path, joined onto the environment baseUrl"`
	Query   map[string]string `json:"query,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
}

func toolErr(err error) error {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return &mcp.CallToolResultError{Message: msg}
	}
	return err
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-http", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "request", Description: "GET/HEAD against the active environment's API baseUrl (relative paths only)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a reqArg) (*mcp.CallToolResult, wakilcore.HTTPResult, error) {
			env, err := wakilcore.ResolveEnvironment()
			if err != nil {
				return nil, wakilcore.HTTPResult{}, toolErr(err)
			}
			if env.API == nil || env.API.BaseURL == "" {
				return nil, wakilcore.HTTPResult{}, toolErr(wakilcore.UserError("this environment has no API baseUrl configured"))
			}
			authRef := ""
			if env.API != nil {
				authRef = env.API.AuthRef
			}
			out, err := wakilcore.DoRequest(ctx, env.API.BaseURL, a.Method, a.Path, a.Query, a.Headers, authRef)
			return nil, out, toolErr(err)
		})

	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 6: Build**

Run: `CGO_ENABLED=0 go build -o bin/wakil-http ./cmd/wakil-http`
Expected: builds.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/httpclient.go internal/wakilcore/httpclient_test.go cmd/wakil-http/
git commit -m "feat(wakil-http): environment-bound read-only HTTP MCP server"
```

---

## Task 16: `wakil-recall` server

**Files:**
- Create: `cmd/wakil-recall/main.go`
- Test: `internal/wakilcore/recall_test.go`, `internal/wakilcore/recall.go`

**Interfaces:**
- Consumes: `Resolve`, `NewJiraFromEnv`, `JiraClient.SearchIssues` (wakilcore).
- Produces: type `RecallResult{Source, Title, Snippet, Link string}`, `Recall(ctx, query string) (map[string][]RecallResult, error)` (grouped by source; Jira only in Phase 1). MCP tool `recall`.

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/recall_test.go`:
```go
package wakilcore

import "testing"

func TestGroupIssuesToResults(t *testing.T) {
	issues := []Issue{{Key: "RAF-1", Summary: "Date picker bug", Status: "Open", URL: "http://j/RAF-1"}}
	out := issuesToResults(issues)
	if len(out) != 1 || out[0].Source != "jira" || out[0].Title != "RAF-1: Date picker bug" || out[0].Link != "http://j/RAF-1" {
		t.Fatalf("bad mapping: %+v", out)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestGroupIssuesToResults -v`
Expected: FAIL (undefined: issuesToResults).

- [ ] **Step 3: Write minimal implementation**

Create `internal/wakilcore/recall.go`:
```go
package wakilcore

import (
	"context"
	"fmt"
)

type RecallResult struct {
	Source  string `json:"source"`
	Title   string `json:"title"`
	Snippet string `json:"snippet"`
	Link    string `json:"link"`
}

func issuesToResults(issues []Issue) []RecallResult {
	var out []RecallResult
	for _, i := range issues {
		out = append(out, RecallResult{
			Source:  "jira",
			Title:   fmt.Sprintf("%s: %s", i.Key, i.Summary),
			Snippet: i.Status,
			Link:    i.URL,
		})
	}
	return out
}

// Recall fans out across bound sources and returns grouped, cited results.
// Phase 1: Jira only. A failing source contributes an empty group, never an error
// for the whole call.
func Recall(ctx context.Context, query string) (map[string][]RecallResult, error) {
	r, err := Resolve()
	if err != nil {
		return nil, err
	}
	out := map[string][]RecallResult{}
	if r.Project.Scopes.PM != nil && r.Project.Scopes.PM.ProjectKey != "" {
		if c, err := NewJiraFromEnv(); err == nil {
			jql := fmt.Sprintf("text ~ %q ORDER BY updated DESC", query)
			if issues, err := c.SearchIssues(ctx, r.Project.Scopes.PM.ProjectKey, jql); err == nil {
				out["jira"] = issuesToResults(issues)
			} else {
				out["jira"] = []RecallResult{}
			}
		}
	}
	return out, nil
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/wakilcore/ -run TestGroupIssuesToResults -v`
Expected: PASS.

- [ ] **Step 5: Write the server**

Create `cmd/wakil-recall/main.go`:
```go
package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type recallArg struct {
	Query string `json:"query" jsonschema:"what to search for across bound sources"`
}

func toolErr(err error) error {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return &mcp.CallToolResultError{Message: msg}
	}
	return err
}

func main() {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-recall", Version: "0.1.0"}, nil)
	mcp.AddTool(s, &mcp.Tool{Name: "recall", Description: "Search bound sources (Jira in Phase 1); returns grouped, cited results."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recallArg) (*mcp.CallToolResult, map[string][]wakilcore.RecallResult, error) {
			out, err := wakilcore.Recall(ctx, a.Query)
			return nil, out, toolErr(err)
		})
	if err := s.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
```

- [ ] **Step 6: Build**

Run: `CGO_ENABLED=0 go build -o bin/wakil-recall ./cmd/wakil-recall`
Expected: builds.

- [ ] **Step 7: Commit**

```bash
git add internal/wakilcore/recall.go internal/wakilcore/recall_test.go cmd/wakil-recall/
git commit -m "feat(wakil-recall): grouped, cited cross-source recall (Jira)"
```

---

## Task 17: `wakil` CLI (secrets) + Makefile + org registration

**Files:**
- Create: `cmd/wakil/main.go`, `Makefile`, `scripts/register-org.sh`
- Test: `cmd/wakil/main_test.go`

**Interfaces:**
- Consumes: `SecretSet` (wakilcore).
- Produces: `wakil secrets set <ref>` (reads the secret value from stdin so it never lands in shell history/argv), and a `wakil secrets set-db <ref>` prompt helper. Makefile target `build` compiles all six binaries with `CGO_ENABLED=0` into `bin/`.

- [ ] **Step 1: Write the failing test**

Create `cmd/wakil/main_test.go`:
```go
package main

import (
	"strings"
	"testing"
)

func TestParseSecretsArgs(t *testing.T) {
	ref, err := parseSecretsSet([]string{"secrets", "set", "booking-staging-core"})
	if err != nil || ref != "booking-staging-core" {
		t.Fatalf("parse: %q %v", ref, err)
	}
	if _, err := parseSecretsSet([]string{"secrets", "set"}); err == nil {
		t.Fatal("missing ref must error")
	}
	if _, err := parseSecretsSet([]string{"nonsense"}); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatal("unknown command must show usage")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./cmd/wakil/ -run TestParseSecretsArgs -v`
Expected: FAIL (undefined: parseSecretsSet).

- [ ] **Step 3: Write minimal implementation**

Create `cmd/wakil/main.go`:
```go
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func parseSecretsSet(args []string) (string, error) {
	if len(args) >= 2 && args[0] == "secrets" && args[1] == "set" {
		if len(args) < 3 || args[2] == "" {
			return "", errors.New("usage: wakil secrets set <ref>  (value read from stdin)")
		}
		return args[2], nil
	}
	return "", errors.New("usage: wakil secrets set <ref>")
}

func main() {
	ref, err := parseSecretsSet(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	fmt.Fprintf(os.Stderr, "Paste the secret for %q, then Ctrl-D:\n", ref)
	data, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	value := strings.TrimRight(data, "\r\n")
	if value == "" {
		// allow multi-line / no trailing newline: read all
		rest, _ := os.ReadFile("/dev/stdin")
		value = strings.TrimRight(string(rest), "\r\n")
	}
	if err := wakilcore.SecretSet(ref, value); err != nil {
		msg, _ := wakilcore.IsUserError(err)
		if msg == "" {
			msg = err.Error()
		}
		fmt.Fprintln(os.Stderr, msg)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "stored %q in the keychain.\n", ref)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./cmd/wakil/ -run TestParseSecretsArgs -v`
Expected: PASS.

- [ ] **Step 5: Create the Makefile**

Create `Makefile`:
```make
BINS = wakil-ctx wakil-db wakil-pm wakil-http wakil-recall wakil
build:
	@mkdir -p bin
	@for b in $(BINS); do CGO_ENABLED=0 go build -o bin/$$b ./cmd/$$b || exit 1; done
	@echo "built: $(BINS)"
test:
	go test ./...
```

Run: `make build` — Expected: all six binaries in `bin/`.

- [ ] **Step 6: Create the org registration script**

Create `scripts/register-org.sh`:
```bash
#!/usr/bin/env bash
# Register Wakil MCP servers in an org's Claude config dir.
# Usage: CLAUDE_CONFIG_DIR=~/.claude-initech scripts/register-org.sh /abs/path/to/bin
set -euo pipefail
BIN="${1:?path to built bin/ dir}"
CFG="${CLAUDE_CONFIG_DIR:?set CLAUDE_CONFIG_DIR to the org config dir}"
for s in wakil-ctx wakil-db wakil-pm wakil-http wakil-recall; do
  claude mcp add "$s" "$BIN/$s" --scope user 2>/dev/null || \
    echo "note: register $s manually in $CFG if 'claude mcp add' is unavailable"
done
echo "registered Wakil servers for org: $(basename "$CFG")"
```
Run: `chmod +x scripts/register-org.sh`

- [ ] **Step 7: Commit**

```bash
git add cmd/wakil/ Makefile scripts/register-org.sh
git commit -m "feat(wakil): secrets CLI, Makefile, org registration script"
```

---

## Task 18: End-to-end validation against the exit criteria

**Files:**
- Create: `docs/wakil/phase-1-acceptance.md` (a runbook; the human executes it on the target Mac)

**Interfaces:**
- Consumes: all binaries + `scripts/register-org.sh`.

This task has no unit test — it is the spec's §8 acceptance run, executed by the operator and recorded.

- [ ] **Step 1: Full build + unit suite**

Run:
```bash
make build
CGO_ENABLED=0 go test ./...
```
Expected: build succeeds; all non-gated tests PASS (Docker/Keychain-gated tests may SKIP).

- [ ] **Step 2: Run the gated integration tests once**

Start MySQL and Mongo (see Tasks 11–12 comments), export the DSNs and `WAKIL_KEYCHAIN_TEST=1`, then:
```bash
WAKIL_KEYCHAIN_TEST=1 go test ./internal/wakilcore/ -run 'MySQL|Mongo|Keychain' -v
```
Expected: PASS. If Keychain prompts, resolve (Always Allow) and note it.

- [ ] **Step 3: Seed configuration**

Create `~/.wakil/projects.json` mapping a real project name → its `.wakil/project.json`, write that `project.json` with at least one MySQL, one SQLite, and one Mongo connection under `staging`, and store each connection URL:
```bash
wakil secrets set booking-staging-core   # paste mysql DSN
wakil secrets set booking-staging-events # paste sqlite path
wakil secrets set booking-staging-mongo  # paste mongo URI
wakil secrets set jira:umbrella           # paste email:api_token
```

- [ ] **Step 4: Register both orgs and launch clean**

```bash
CLAUDE_CONFIG_DIR=~/.claude-initech     scripts/register-org.sh "$PWD/bin"
CLAUDE_CONFIG_DIR=~/.claude-umbrella scripts/register-org.sh "$PWD/bin"
env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=~/.claude-umbrella CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_UMBRELLA_TOKEN" claude
```

- [ ] **Step 5: Verify each exit criterion and record results**

In the Claude Code session, confirm and write the outcome of each into `docs/wakil/phase-1-acceptance.md`:
1. wakil servers are listed (`/mcp` or tool list).
2. "set project to <name>, environment staging" → `get_context` shows the right org/project/env.
3. "what's assigned to me on umbrella" → correct Jira issues.
4. "fetch customer 42 from staging" against each of the MySQL, SQLite, and Mongo connections → correct rows.
5. Ask it to run a write (`DELETE …`, a Mongo `deleteMany`, and an HTTP `POST`) → each is refused with a human sentence; the production connection refuses reads that would write and is not writable.
6. "show my recent sessions on this project" → sessions across all roots, including one started outside Wakil.
7. Cross-org guard: with the umbrella config dir active, "set project to <a initech project>" → rejected.

- [ ] **Step 6: Commit the acceptance record**

```bash
git add docs/wakil/phase-1-acceptance.md
git commit -m "docs: Phase 1 acceptance runbook + recorded results"
```

---

## Self-Review

**1. Spec coverage:**
- `wakil-ctx` (§4.1) → Tasks 4, 7. ✓
- `wakil-pm` (§4.2) → Task 14. ✓
- `wakil-db` pluggable/multi-connection (§4.3) → Tasks 9–13. ✓ (MySQL, SQLite, Mongo)
- `wakil-http` (§4.4) → Task 15. ✓
- `wakil-recall` (§4.5) → Task 16. ✓
- Config/state model, org=config-dir, project.json, active.json, registry (§3) → Tasks 1–4. ✓
- Credential model / Keychain (§3) → Task 5 + used in 13, 14, 15. ✓
- Session discovery + lossy encoding (§5) → Task 6, exposed in Task 7. ✓
- Read-only enforcement, per-driver + HTTP (§6) → Tasks 8, 10–12, 15. ✓
- Auth: `env -u ANTHROPIC_API_KEY`, re-auth messaging (§6) → Tasks 14, 18. ✓
- Errors as human sentences (§6) → `mcperr.go` (Task 4), `toolErr` in every server. ✓
- Testing incl. adversarial + isolation (§7) → Tasks 4, 8, 10–12, 18. ✓
- Exit criteria (§8) → Task 18. ✓

**2. Placeholder scan:** No TBD/TODO; every code step carries real code. Two explicit SDK-drift guards (MCP error-result type in Task 7; Mongo v1/v2 import in Task 12) tell the executor exactly what to check and what the contract is — these are verification instructions, not placeholders.

**3. Type consistency:** `DbDriver`/`Conn`/`QuerySpec`/`Rows`/`Container`/`Schema` defined in Task 9 and used unchanged in 10–13. `Issue` defined in Task 14, reused in 16. `toolErr` follows one shape across all five servers. `Resolve`/`ResolveEnvironment`/`SetProjectChecked`/`PickDatabase`/`OpenDatabase` signatures are consistent between definition and use.

**Known deviations from spec, recorded for the operator to ratify:**
- Jira auth sources from `WAKIL_JIRA_BASE` + a `jira:<org>` Keychain ref rather than reading Claude Code's stored Atlassian OAuth token (spec §4.2 open question). Simpler and consistent with the ref→Keychain pattern; revisit if reusing the existing Atlassian MCP token proves preferable.
- SQLite is implemented before MySQL (spec listed MySQL first) because it needs no Docker and proves the whole `DbDriver`→`sqlConn`→server pipeline with the fastest test loop.
