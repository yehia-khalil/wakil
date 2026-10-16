# Org / Provider Decoupling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an organisation an explicit, registered entity declared by whoever launches a Wakil process, with providers (Claude accounts, Codex, local models) as a separate axis, so one org can hold several providers and org names are free-form.

**Architecture:** Org identity moves from `OrgFromConfigDir(os.Getenv("CLAUDE_CONFIG_DIR"))` to `os.Getenv("WAKIL_ORG")` with no fallback. All per-org state moves under `~/.wakil/orgs/<org>/` — `org.json`, `active.json`, `projects.json`, `providers/<id>.json` — and every per-org file access funnels through one `OrgDir()` that refuses an unregistered org. Session discovery stops reading the ambient `CLAUDE_CONFIG_DIR` and instead enumerates the org's registered providers, tagging each session with the provider it came from.

**Tech Stack:** Go 1.27, `CGO_ENABLED=0`, no new dependencies. Bash for `scripts/register-provider.sh`.

**Spec:** `docs/superpowers/specs/2026-09-06-org-provider-decoupling-design.md` — read it before Task 1. Sections are cited per task.

## Global Constraints

- `CGO_ENABLED=0` project-wide (`Makefile` exports it for build/test/vet; pinned by `scripts/makefile_test.go`).
- **Do NOT set `WAKIL_KEYCHAIN_TEST`.** No test may reach `wakilcore.SecretSet` or touch the real login keychain. The `security` CLI is faked on `PATH` in existing tests — follow that pattern.
- No test may read or write the real `~/.claude*` or `~/.wakil`. Build fixtures in `t.TempDir()` and redirect `HOME` with `t.Setenv("HOME", dir)`, as `active_test.go:12` already does.
- **Comment accuracy is a hard failure.** Every claim written into a comment must have been run.
- **Probe, don't read.** Measure library and engine behaviour; do not infer it.
- **Mutation-test every guard**: break the production code, confirm the right test fails for the right reason and quote the message, revert, confirm the file is byte-identical against a `/tmp` backup and `git diff --exit-code` is clean. A mutation reporting `(cached)` has not run — force `-count=1`.
- A test that cannot fail is worse than no test. Assert the guard **fired**, not merely that the bad thing is absent.
- Never run `git checkout --` on a file with uncommitted changes. Never use bare `git stash` (the stack is shared across worktrees).
- Gate before finishing each task: `gofmt -l .` empty, `go vet ./...`, `go test ./... -count=2`, `go test ./... -race`, `go test ./... -shuffle=on`, `make build`.
- Org id validity is `orgFileTokenPattern` = `^[A-Za-z0-9][A-Za-z0-9._-]*$`. Provider ids use the same pattern. An invalid value is an ERROR, never sanitised.
- Every user-facing failure uses `wakilcore.UserError`, not a bare `fmt.Errorf`.

---

## File Structure

| File | Responsibility after this plan |
|---|---|
| `internal/wakilcore/paths.go` | `~/.wakil` roots, org identity (`CurrentOrg`), org-token validation, `OrgDir`/`OrgDirFor`. Owns everything that answers "which org am I, and where does its state live". `OrgFromConfigDir` and `LoadRegistry` leave. |
| `internal/wakilcore/org.go` | **new** — the `Org` record (`org.json`): load, save, create, list, remove. |
| `internal/wakilcore/provider.go` | **new** — the `Provider` record (`providers/<id>.json`): kinds, load, list, add, remove, `CurrentProvider`. |
| `internal/wakilcore/registry.go` | **new** — the per-org project registry (`projects.json`): `ProjectEntry`, load/save, `ListProjects` with misfiled reporting. Moved out of `paths.go`. |
| `internal/wakilcore/active.go` | Active context only. Legacy shared-file fallback deleted; paths come from `OrgDir()`. |
| `internal/wakilcore/resolve.go` | Unchanged cross-org check, plus the provider match report on `Resolved`. |
| `internal/wakilcore/sessions.go` | Provider-enumerating discovery. `sessionsRoot` deleted, `providerSessionsRoot` added. |
| `internal/wakilcore/secrets.go` | Keychain only. `validateOrgToken`/`CurrentOrgChecked` move to `paths.go`. |
| `internal/wakilcore/jira.go` | Base URL from `org.json`, `WAKIL_JIRA_BASE` as override. |
| `cmd/wakil/main.go` | Subcommand dispatch: `secrets`, `org`, `provider`; global `--org`. |
| `cmd/wakil-ctx/main.go` | `list_projects` returns the listing type; `get_context` carries the provider report. |
| `scripts/register-provider.sh` | **new**, replaces `register-org.sh`. |

---

## Task 1: Org identity from WAKIL_ORG

**Spec:** §3.1, §3.3.

**Files:**
- Modify: `internal/wakilcore/paths.go`
- Modify: `internal/wakilcore/secrets.go` (move `validateOrgToken`, `CurrentOrgChecked` out; update `CurrentOrg` call sites)
- Modify: `internal/wakilcore/active.go` (move `orgFileTokenPattern` out; update call sites)
- Modify: `internal/wakilcore/resolve.go`, `internal/wakilcore/jira.go`, `cmd/wakil-ctx/main.go` (call sites)
- Test: `internal/wakilcore/paths_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func CurrentOrg() (string, error)` — reads `WAKIL_ORG`, validates it against `orgFileTokenPattern`. Empty or invalid is a `UserError`.
  - `func CurrentOrgChecked() (string, error)` — retained as an alias of `CurrentOrg` for `cmd/wakil`; **delete the separate implementation**, since `CurrentOrg` now validates.
  - `var orgFileTokenPattern` and `func validateOrgToken(org string) error` live in `paths.go`.
  - `OrgFromConfigDir` no longer exists.

- [ ] **Step 1: Write the failing tests**

Add to `internal/wakilcore/paths_test.go`:

```go
func TestCurrentOrgRequiresWakilOrg(t *testing.T) {
	t.Setenv("WAKIL_ORG", "")
	t.Setenv("CLAUDE_CONFIG_DIR", "/home/someone/.claude-initech")

	got, err := CurrentOrg()
	if err == nil {
		t.Fatalf("CurrentOrg() = %q, nil; want an error when WAKIL_ORG is unset", got)
	}
	if !strings.Contains(err.Error(), "WAKIL_ORG") {
		t.Errorf("error must name the variable the operator has to set; got %q", err)
	}
	// The whole point: CLAUDE_CONFIG_DIR must NOT be consulted as a fallback.
	if strings.Contains(err.Error(), "initech") {
		t.Errorf("CurrentOrg fell back to CLAUDE_CONFIG_DIR; got %q", err)
	}
}

func TestCurrentOrgRejectsUnusableIDs(t *testing.T) {
	for _, bad := range []string{"/", "..", ".", "-x", " x", "a:b", "", "a/b"} {
		t.Run(strconv.Quote(bad), func(t *testing.T) {
			t.Setenv("WAKIL_ORG", bad)
			if got, err := CurrentOrg(); err == nil {
				t.Fatalf("CurrentOrg() = %q, nil; want an error for org %q", got, bad)
			}
		})
	}
}

func TestCurrentOrgAcceptsFreeFormNames(t *testing.T) {
	for _, ok := range []string{"initech", "client-a", "side.project", "A_b", "umbrella"} {
		t.Run(ok, func(t *testing.T) {
			t.Setenv("WAKIL_ORG", ok)
			got, err := CurrentOrg()
			if err != nil {
				t.Fatalf("CurrentOrg() error = %v; want %q accepted", err, ok)
			}
			if got != ok {
				t.Errorf("CurrentOrg() = %q; want %q — the value is used verbatim, never derived", got, ok)
			}
		})
	}
}
```

Delete every existing test of `OrgFromConfigDir` in `paths_test.go`, and delete `TestCurrentOrgChecked`-style tests in `secrets_test.go` that assert the `CLAUDE_CONFIG_DIR` wording.

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestCurrentOrg' -count=1 -v`
Expected: FAIL — `CurrentOrg() (string, error)` does not compile against the current single-return signature.

- [ ] **Step 3: Implement**

In `paths.go`, replace `OrgFromConfigDir` and `CurrentOrg` with:

```go
// orgFileTokenPattern is what an org id must match to be usable as a
// directory name under ~/.wakil/orgs and as the org component of a
// Keychain service name. Moved here from active.go: the org id is an
// identity concern, and both users of the pattern now sit downstream of
// this file.
//
// The filename use needs no "/" and no leading dot; the Keychain use
// needs no ":" (see keychainService for why a colon would let two
// distinct org/ref pairs collide on one credential). Requiring a leading
// alphanumeric rejects "/", "..", ".", a bare dash and a bare space.
//
// An invalid org is an ERROR rather than something to sanitise.
// Sanitising would silently map two different orgs onto one directory,
// which is the exact collision the per-org split exists to prevent.
var orgFileTokenPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// CurrentOrg returns the org this process was launched for.
//
// The value comes from WAKIL_ORG and from nothing else. There is
// deliberately NO fallback to CLAUDE_CONFIG_DIR: a fallback resolves
// silently to whatever config dir the process happened to inherit, and
// the failure then surfaces far from its cause as a missing credential.
//
// It must stay a launcher-declared value. A project.json declares which
// org it BELONGS to — that is what Resolve() checks against — but it must
// never be able to SET the ambient org, or the cross-org guard becomes a
// comparison of a value against itself.
func CurrentOrg() (string, error) {
	org := os.Getenv("WAKIL_ORG")
	if org == "" {
		return "", UserError("WAKIL_ORG is not set — every Wakil process runs for exactly one org. " +
			"Registered servers get it from scripts/register-provider.sh; on the CLI pass --org <org>.")
	}
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	return org, nil
}

// validateOrgToken reports whether org can be used as a directory name
// and as the org component of a Keychain service name.
func validateOrgToken(org string) error {
	if orgFileTokenPattern.MatchString(org) {
		return nil
	}
	// Quoted: an org id can contain a space or a newline (both measured as
	// accepted by `security`), and an unquoted one renders as an invisible
	// or line-breaking message that hides the actual problem.
	return UserError("unusable org id " + strconv.Quote(org) +
		" — an org id must start with a letter or digit and contain only letters, digits, dot, dash or underscore")
}

// CurrentOrgChecked is CurrentOrg. It survives as a name because
// cmd/wakil calls it to get the org BEFORE prompting for a secret, and
// that call site reads better spelled "checked". CurrentOrg now validates
// on every call, so there is nothing extra to do here.
func CurrentOrgChecked() (string, error) { return CurrentOrg() }
```

Delete `orgFileTokenPattern` from `active.go` and `validateOrgToken`/`CurrentOrgChecked` from `secrets.go`.

- [ ] **Step 4: Update every call site**

`CurrentOrg()` now returns two values. Fix, in order, propagating the error:

- `active.go:67` (`activePath`) — `org, err := CurrentOrg()`; return the error.
- `active.go:130` (`readLegacyActive`) — this function is deleted in Task 2; for now, treat a `CurrentOrg` error as "no legacy context" and return `ActiveContext{}, nil`.
- `resolve.go:25`, `resolve.go:57` — return the error.
- `jira.go:96`, `jira.go:476` — return the error; at 476 fall back to the literal `"this org"` in the message if `CurrentOrg` fails, so an error path cannot panic.
- `secrets.go:131`, `secrets.go:157`, `secrets.go:203` — return the error.
- `cmd/wakil-ctx/main.go:86` — the `list_projects` loop; hoist `org, err := wakilcore.CurrentOrg()` above the loop and return `toolErr(err)` on failure.

Also update the two `Resolve`/`SetProjectChecked` messages, which currently say "switch Claude config dir": replace with "relaunch with WAKIL_ORG=<the project's org>".

- [ ] **Step 5: Run tests**

Run: `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 6: Mutation-test the guard**

Temporarily change `CurrentOrg` to fall back to `os.Getenv("CLAUDE_CONFIG_DIR")` when `WAKIL_ORG` is empty. Run `go test ./internal/wakilcore/ -run TestCurrentOrgRequiresWakilOrg -count=1 -v`. Confirm it FAILS and quote the message in the commit body. Revert; confirm `git diff` on that file is clean.

- [ ] **Step 7: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore cmd/wakil-ctx
git commit -m "Org identity comes from WAKIL_ORG, with no config-dir fallback"
```

---

## Task 2: The orgs/<org>/ directory, and deleting the legacy active file

**Spec:** §3.1 (registry lookup), §4, §9.

**Files:**
- Modify: `internal/wakilcore/paths.go` (add `OrgsDir`, `OrgDir`, `OrgDirFor`)
- Modify: `internal/wakilcore/active.go` (path from `OrgDir`; delete legacy fallback)
- Test: `internal/wakilcore/paths_test.go`, `internal/wakilcore/active_test.go`

**Interfaces:**
- Consumes: `CurrentOrg() (string, error)`, `validateOrgToken` (Task 1).
- Produces:
  - `func OrgsDir() (string, error)` — `~/.wakil/orgs`, no existence requirement.
  - `func OrgDirFor(org string) (string, error)` — `~/.wakil/orgs/<org>`, **errors if the directory does not exist**.
  - `func OrgDir() (string, error)` — `OrgDirFor(CurrentOrg())`.
  - `func orgDirCreate(org string) (string, error)` — unexported; makes the directory. Used only by Task 3's `CreateOrg`.
  - `legacyActiveFile`, `legacyActivePath`, `readLegacyActive` no longer exist.

- [ ] **Step 1: Write the failing tests**

```go
func TestOrgDirRefusesUnregisteredOrg(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "umbrela")

	got, err := OrgDir()
	if err == nil {
		t.Fatalf("OrgDir() = %q, nil; want a refusal for an unregistered org", got)
	}
	if !strings.Contains(err.Error(), "umbrela") || !strings.Contains(err.Error(), "wakil org create") {
		t.Errorf("the refusal must name the org and the command that fixes it; got %q", err)
	}
}

func TestOrgDirAcceptsRegisteredOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	want := filepath.Join(home, ".wakil", "orgs", "initech")
	if err := os.MkdirAll(want, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := OrgDir()
	if err != nil {
		t.Fatalf("OrgDir() error = %v", err)
	}
	if got != want {
		t.Errorf("OrgDir() = %q; want %q", got, want)
	}
}

func TestActiveContextLivesInsideTheOrgDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := os.MkdirAll(filepath.Join(home, ".wakil", "orgs", "initech"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: "/p/.wakil/project.json", Environment: "staging"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "orgs", "initech", "active.json")); err != nil {
		t.Fatalf("active context not written inside the org directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "active-initech.json")); !os.IsNotExist(err) {
		t.Errorf("the old flat path must not be written any more")
	}
}

func TestNoLegacyActiveFallback(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	orgDir := filepath.Join(home, ".wakil", "orgs", "initech")
	if err := os.MkdirAll(orgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A pre-split shared file naming a project that DOES belong to this org.
	// Before this change readLegacyActive would have adopted it.
	projDir := t.TempDir()
	projPath := filepath.Join(projDir, "project.json")
	if err := os.WriteFile(projPath, []byte(`{"name":"p","org":"initech"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	legacy := filepath.Join(home, ".wakil", "active.json")
	if err := os.WriteFile(legacy, []byte(`{"project":"`+projPath+`","environment":"staging"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err := ReadActive()
	if err != nil {
		t.Fatal(err)
	}
	if a.Project != "" {
		t.Errorf("ReadActive adopted the legacy shared file (%q); the fallback must be gone", a.Project)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestOrgDir|TestActiveContextLives|TestNoLegacyActive' -count=1 -v`
Expected: FAIL — `OrgDir` undefined; `TestNoLegacyActiveFallback` fails with the adopted project path.

- [ ] **Step 3: Implement the directory helpers**

In `paths.go`:

```go
// OrgsDir is the root under which every org's state lives. It is not
// required to exist; OrgDirFor is what refuses a missing org.
func OrgsDir() (string, error) {
	wakilDir, err := WakilDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(wakilDir, "orgs"), nil
}

// OrgDirFor returns ~/.wakil/orgs/<org>, refusing an org that has not
// been created.
//
// This existence check is load-bearing. Before org ids were free-form, a
// mistyped org was caught by the filesystem: register-org.sh refused
// because ~/.claude-umbrela did not exist. Nothing else would catch
// WAKIL_ORG=umbrela — it is a legal token — so without this the typo would
// quietly create state under a phantom org and fail much later as a
// missing credential.
func OrgDirFor(org string) (string, error) {
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	root, err := OrgsDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, org)
	fi, err := os.Stat(dir)
	if os.IsNotExist(err) {
		return "", UserError("org " + strconv.Quote(org) + " is not registered — create it with: wakil org create " + org)
	}
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", UserError("org " + strconv.Quote(org) + " is not usable: " + dir + " exists but is not a directory")
	}
	return dir, nil
}

// OrgDir returns the current org's directory.
func OrgDir() (string, error) {
	org, err := CurrentOrg()
	if err != nil {
		return "", err
	}
	return OrgDirFor(org)
}

// orgDirCreate makes an org's directory. It is the ONLY thing that
// creates one, so that OrgDirFor's refusal means "nobody ran
// `wakil org create`" and never "some unrelated write happened to
// MkdirAll it into existence".
func orgDirCreate(org string) (string, error) {
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	root, err := OrgsDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, org)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}
```

- [ ] **Step 4: Rewrite active.go's paths and delete the legacy fallback**

Delete `legacyActiveFile`, `legacyActivePath`, `readLegacyActive`, and the fallback branch of `ReadActive`. Then:

```go
// activePath returns the active-context file for the CURRENT org.
//
// Safety does not rest on the per-org split. Resolve() re-checks
// proj.Org against CurrentOrg() on every call regardless of which file
// the context came from; that check is the cross-org boundary.
func activePath() (string, error) {
	dir, err := OrgDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "active.json"), nil
}

// ReadActive returns the current org's active context. A missing file is
// an ordinary state — no project set yet — not an error.
func ReadActive() (ActiveContext, error) {
	path, err := activePath()
	if err != nil {
		return ActiveContext{}, err
	}
	a, _, err := readActiveFile(path)
	return a, err
}
```

In `WriteActive`, replace `WakilDir()` with `OrgDir()` for both the `MkdirAll` target and `os.CreateTemp`'s directory, and drop the `MkdirAll` entirely — `OrgDir()` already guarantees the directory exists, and re-creating it here would defeat `OrgDirFor`'s refusal. Keep the per-call temp file and the rename exactly as they are; update the temp pattern to `"active-*.json.tmp"` (unchanged) and confirm the comment still describes what the code does.

- [ ] **Step 5: Run tests**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS. Existing `active_test.go` cases that set `CLAUDE_CONFIG_DIR` must be rewritten to set `WAKIL_ORG` and create the org directory; cases asserting the legacy fallback must be deleted, not weakened.

- [ ] **Step 6: Mutation-test**

Change `OrgDirFor` to `os.MkdirAll` instead of refusing. Run `go test ./internal/wakilcore/ -run TestOrgDirRefusesUnregisteredOrg -count=1 -v`, confirm FAIL, quote the message, revert, verify clean.

- [ ] **Step 7: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "Per-org state moves under ~/.wakil/orgs/<org>/; legacy active fallback deleted"
```

---

## Task 3: The org record (org.json)

**Spec:** §4.1.

**Files:**
- Create: `internal/wakilcore/org.go`, `internal/wakilcore/org_test.go`
- Modify: `internal/wakilcore/jira.go` (export `normalizeJiraBase` use — no signature change needed, it is package-local)

**Interfaces:**
- Consumes: `OrgDirFor`, `orgDirCreate`, `OrgDir`, `validateOrgToken`.
- Produces:
  - `type Org struct { DisplayName, JiraBase, DefaultProvider string }` with json tags `displayName,omitempty`, `jiraBase,omitempty`, `defaultProvider,omitempty`.
  - `func LoadOrg() (*Org, error)` — current org.
  - `func LoadOrgFor(org string) (*Org, error)`
  - `func CreateOrg(org string, o Org) error` — refuses if the org already exists; normalises `JiraBase`.
  - `func SaveOrg(org string, o Org) error` — requires the org to exist.
  - `func ListOrgs() ([]string, error)` — sorted; empty slice, never nil.
  - `func RemoveOrg(org string, force bool) error`

- [ ] **Step 1: Write the failing tests**

```go
func TestCreateOrgRefusesBadJiraBase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, bad := range []string{
		"http://site.atlassian.net",
		"https://u:p@site.atlassian.net",
		"https://site.atlassian.net/wiki",
		"https://site.atlassian.net?q=1",
	} {
		t.Run(bad, func(t *testing.T) {
			if err := CreateOrg("initech", Org{JiraBase: bad}); err == nil {
				t.Fatalf("CreateOrg accepted %q", bad)
			}
			if _, err := OrgDirFor("initech"); err == nil {
				t.Errorf("a rejected org must not be left half-created on disk")
			}
		})
	}
}

func TestCreateOrgNormalisesJiraBaseAndRoundTrips(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{DisplayName: "Initech Labs", JiraBase: "https://site.atlassian.net/"}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrg()
	if err != nil {
		t.Fatal(err)
	}
	if o.JiraBase != "https://site.atlassian.net" {
		t.Errorf("JiraBase = %q; want the trailing slash normalised away", o.JiraBase)
	}
	if o.DisplayName != "Initech Labs" {
		t.Errorf("DisplayName = %q", o.DisplayName)
	}
}

func TestCreateOrgRefusesDuplicate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("initech", Org{}); err == nil {
		t.Fatal("CreateOrg overwrote an existing org")
	}
}

func TestRemoveOrgRefusesWhenItHasDependants(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, ".wakil", "orgs", "initech", "providers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "primary.json"), []byte(`{"kind":"local"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RemoveOrg("initech", false); err == nil {
		t.Fatal("RemoveOrg deleted an org that still held a provider")
	}
	if err := RemoveOrg("initech", true); err != nil {
		t.Fatalf("forced RemoveOrg failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "orgs", "initech")); !os.IsNotExist(err) {
		t.Error("forced RemoveOrg must delete the whole org directory")
	}
}

func TestListOrgsIsSortedAndNeverNil(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, o := range []string{"umbrella", "initech", "personal"} {
		if err := CreateOrg(o, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	got, err := ListOrgs()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"initech", "umbrella", "personal"}
	if !slices.Equal(got, want) {
		t.Errorf("ListOrgs() = %v; want %v", got, want)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestCreateOrg|TestRemoveOrg|TestListOrgs' -count=1 -v`
Expected: FAIL — undefined: `CreateOrg`.

- [ ] **Step 3: Implement `org.go`**

```go
package wakilcore

// Org is the per-organisation record, stored at
// ~/.wakil/orgs/<org>/org.json.
//
// The org id itself is NOT a field: it is the directory name, so there is
// one place it can be written and no way for the two to disagree.
type Org struct {
	DisplayName string `json:"displayName,omitempty"`

	// JiraBase is the org's Jira site. It lives here rather than being
	// passed at registration because an org may have several providers,
	// and N registrations stating one fact is N chances for two of them to
	// disagree with nothing to catch it. Stored normalised, so every
	// reader gets the same string.
	JiraBase string `json:"jiraBase,omitempty"`

	// DefaultProvider is used for projects that name no provider of their
	// own. Advisory only — see Resolved.Provider; nothing is ever blocked
	// because of it.
	DefaultProvider string `json:"defaultProvider,omitempty"`
}

const orgFileName = "org.json"

func LoadOrg() (*Org, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return LoadOrgFor(org)
}

func LoadOrgFor(org string) (*Org, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, orgFileName))
	if os.IsNotExist(err) {
		// The directory exists but the record does not. Treat it as an
		// empty record rather than an error: an org with no Jira site and
		// no default provider is a legitimate configuration, and the
		// directory's existence is what "registered" means.
		return &Org{}, nil
	}
	if err != nil {
		return nil, err
	}
	var o Org
	if err := json.Unmarshal(b, &o); err != nil {
		return nil, UserError("org.json for org " + strconv.Quote(org) + " is unreadable: " + err.Error())
	}
	return &o, nil
}

// CreateOrg registers a new org. It refuses to overwrite an existing one:
// an accidental re-create would silently drop that org's jiraBase and
// defaultProvider, and the operator would not find out until a Jira call
// failed.
func CreateOrg(org string, o Org) error {
	if err := validateOrgToken(org); err != nil {
		return err
	}
	if _, err := OrgDirFor(org); err == nil {
		return UserError("org " + strconv.Quote(org) + " already exists")
	}
	// Validate BEFORE creating anything, so a rejected value leaves no
	// half-made directory behind.
	normalised, err := normaliseOrg(o)
	if err != nil {
		return err
	}
	dir, err := orgDirCreate(org)
	if err != nil {
		return err
	}
	if err := writeOrgFile(dir, normalised); err != nil {
		_ = os.RemoveAll(dir)
		return err
	}
	return nil
}

func SaveOrg(org string, o Org) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	normalised, err := normaliseOrg(o)
	if err != nil {
		return err
	}
	return writeOrgFile(dir, normalised)
}

func normaliseOrg(o Org) (Org, error) {
	if o.JiraBase != "" {
		base, err := normalizeJiraBase(o.JiraBase)
		if err != nil {
			return Org{}, err
		}
		o.JiraBase = base
	}
	if o.DefaultProvider != "" {
		if err := validateOrgToken(o.DefaultProvider); err != nil {
			return Org{}, UserError("defaultProvider is not a usable provider id: " + err.Error())
		}
	}
	return o, nil
}

func writeOrgFile(dir string, o Org) error {
	b, err := json.MarshalIndent(o, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, orgFileName), b)
}

func ListOrgs() ([]string, error) {
	root, err := OrgsDir()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, e := range entries {
		if e.IsDir() && orgFileTokenPattern.MatchString(e.Name()) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

// RemoveOrg deletes an org's whole directory. It refuses while the org
// still holds providers or projects unless forced, because those are the
// two things that make an org non-empty and the deletion is not undoable.
//
// It never touches the Keychain. A credential that outlives its org is
// recoverable; a deleted one is not.
func RemoveOrg(org string, force bool) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	if !force {
		// Counted off the filesystem rather than through ListProvidersFor
		// and LoadRegistryFor, so this file does not depend on types that
		// land in later tasks — and so a record this package cannot parse
		// still counts as a dependant. "Unreadable" must never read as
		// "absent" on a delete path.
		providers, err := os.ReadDir(filepath.Join(dir, "providers"))
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		hasProjects := false
		if fi, err := os.Stat(filepath.Join(dir, registryFileName)); err == nil && fi.Size() > len("{}") {
			hasProjects = true
		}
		if len(providers) > 0 || hasProjects {
			return UserError(fmt.Sprintf("org %s still holds %d provider record(s)%s — re-run with --force to delete the whole org directory. Keychain credentials are never removed.",
				strconv.Quote(org), len(providers), map[bool]string{true: " and a project registry", false: ""}[hasProjects]))
		}
	}
	return os.RemoveAll(dir)
}
```

Add `writeFileAtomic(path string, b []byte) error` to `paths.go`, factored out of `WriteActive`'s existing body (per-call `os.CreateTemp` in the destination directory, write, close, chmod 0644, rename, `defer os.Remove` of the temp). `WriteActive` then calls it. **Do not** change its semantics — the per-call temp name is what makes concurrent writers safe, and the comment explaining that moves with the code.

- [ ] **Step 4: Run tests**

Run: `go test ./internal/wakilcore/ -run 'TestCreateOrg|TestRemoveOrg|TestListOrgs|TestActive' -count=1 -v`
Expected: PASS. Declare `const registryFileName = "projects.json"` in this task (Task 5 uses the same constant and must not redeclare it); nothing else from Tasks 4 or 5 is needed here, because `RemoveOrg` counts dependants off the filesystem.

- [ ] **Step 5: Mutation-test**

Remove the duplicate check from `CreateOrg`. Confirm `TestCreateOrgRefusesDuplicate` fails, quote it, revert, verify clean.

- [ ] **Step 6: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "Add the org record: org.json with displayName, jiraBase and defaultProvider"
```

---

## Task 4: The provider record

**Spec:** §3.2, §4.2.

**Files:**
- Create: `internal/wakilcore/provider.go`, `internal/wakilcore/provider_test.go`
- Modify: none beyond the new files.

**Interfaces:**
- Consumes: `OrgDirFor`, `OrgDir`, `CurrentOrg`, `validateOrgToken`, `writeFileAtomic`.
- Produces:
  - `const ProviderKindClaudeCode = "claude-code"`, `ProviderKindCodex = "codex"`, `ProviderKindLocal = "local"`
  - `type Provider struct { ID string \`json:"-"\`; Kind string \`json:"kind"\`; Label string \`json:"label,omitempty"\`; ConfigDir string \`json:"configDir,omitempty"\` }`
  - `func ListProviders() ([]Provider, error)` / `func ListProvidersFor(org string) ([]Provider, error)` — sorted by ID, never nil.
  - `func LoadProviderFor(org, id string) (*Provider, error)`
  - `func AddProvider(org string, p Provider) error`
  - `func RemoveProvider(org, id string) error`
  - `func CurrentProvider() (string, error)` — `WAKIL_PROVIDER`; returns `""`, nil when unset; validates registration when set.

- [ ] **Step 1: Write the failing tests**

```go
func TestAddProviderRequiresExistingConfigDirForClaudeCode(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindClaudeCode, ConfigDir: filepath.Join(home, "nope")})
	if err == nil {
		t.Fatal("AddProvider accepted a claude-code provider whose configDir does not exist")
	}
	if !strings.Contains(err.Error(), "configDir") {
		t.Errorf("the refusal must name the field; got %q", err)
	}
}

func TestAddProviderRejectsUnknownKind(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "x", Kind: "gemini"}); err == nil {
		t.Fatal("AddProvider accepted an unknown kind")
	}
}

func TestProvidersRoundTripAndSort(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Label: "main"}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "backup", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	got, err := ListProviders()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].ID != "backup" || got[1].ID != "primary" {
		t.Fatalf("ListProviders() = %+v; want backup then primary", got)
	}
	// AddProvider stores the symlink-RESOLVED path, and on macOS t.TempDir()
	// sits under /var, which is a symlink to /private/var. Comparing against
	// the unresolved cfg would fail there for the right reason.
	wantCfg, err := filepath.EvalSymlinks(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got[1].ConfigDir != wantCfg || got[1].Label != "main" {
		t.Errorf("provider record did not round-trip: %+v (want configDir %q)", got[1], wantCfg)
	}
}

func TestCurrentProviderRejectsUnregisteredID(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_PROVIDER", "typo")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if got, err := CurrentProvider(); err == nil {
		t.Fatalf("CurrentProvider() = %q, nil; want a refusal for an unregistered id", got)
	}
}

func TestCurrentProviderIsOptional(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_PROVIDER", "")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	got, err := CurrentProvider()
	if err != nil {
		t.Fatalf("CurrentProvider() error = %v; unset WAKIL_PROVIDER is legitimate — the operator runs the CLI by hand", err)
	}
	if got != "" {
		t.Errorf("CurrentProvider() = %q; want empty", got)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'Provider' -count=1 -v`
Expected: FAIL — undefined: `AddProvider`.

- [ ] **Step 3: Implement `provider.go`**

```go
package wakilcore

// Provider is one agent account attached to an org, stored at
// ~/.wakil/orgs/<org>/providers/<id>.json.
//
// Providers and orgs are independent axes: an org may hold several
// providers (two Claude subscriptions for rate-limit headroom, plus a
// local model), and the same account may serve several orgs. Nothing
// about an org's credentials depends on which provider is running.
type Provider struct {
	// ID is the file's basename, not a field in the file, so the two
	// cannot disagree.
	ID string `json:"-"`

	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`
}

// Provider kinds. Only claude-code has a session adapter (see
// providerSessionsRoot) and automated MCP registration
// (scripts/register-provider.sh). The other two are recorded so an org
// can describe what it actually has: 14 of the 16 Wakil tools are plain
// stdio MCP and work under any MCP-capable client, so a codex or local
// provider is genuinely useful — it is only session discovery that goes
// dark. Recording a kind we do not automate is honest; claiming to
// automate a client that has never been tested would not be.
const (
	ProviderKindClaudeCode = "claude-code"
	ProviderKindCodex      = "codex"
	ProviderKindLocal      = "local"
)

func providersDirFor(org string) (string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "providers"), nil
}

func AddProvider(org string, p Provider) error {
	if err := validateOrgToken(p.ID); err != nil {
		return UserError("unusable provider id: " + err.Error())
	}
	switch p.Kind {
	case ProviderKindClaudeCode:
		if p.ConfigDir == "" {
			return UserError("a claude-code provider needs --config-dir (the CLAUDE_CONFIG_DIR that account uses)")
		}
		abs, err := filepath.Abs(p.ConfigDir)
		if err != nil {
			return err
		}
		// Resolve symlinks: the servers really do read the target, and the
		// recorded value is what session discovery will open later.
		resolved, err := filepath.EvalSymlinks(abs)
		if err != nil {
			return UserError("configDir does not exist: " + abs)
		}
		fi, err := os.Stat(resolved)
		if err != nil || !fi.IsDir() {
			return UserError("configDir is not a directory: " + resolved)
		}
		p.ConfigDir = resolved
	case ProviderKindCodex, ProviderKindLocal:
		if p.ConfigDir != "" {
			return UserError("configDir applies only to --kind claude-code")
		}
	default:
		return UserError("unknown provider kind " + strconv.Quote(p.Kind) +
			" — one of " + ProviderKindClaudeCode + ", " + ProviderKindCodex + ", " + ProviderKindLocal)
	}

	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, p.ID+".json")
	if _, err := os.Stat(path); err == nil {
		return UserError("provider " + strconv.Quote(p.ID) + " already exists in org " + strconv.Quote(org))
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

func RemoveProvider(org, id string) error {
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, id+".json")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return UserError("no provider " + strconv.Quote(id) + " in org " + strconv.Quote(org))
	}
	return os.Remove(path)
}

func LoadProviderFor(org, id string) (*Provider, error) {
	dir, err := providersDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, id+".json"))
	if os.IsNotExist(err) {
		return nil, UserError("no provider " + strconv.Quote(id) + " in org " + strconv.Quote(org) +
			" — register it with: wakil provider add " + id + " --org " + org)
	}
	if err != nil {
		return nil, err
	}
	var p Provider
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, UserError("provider record " + strconv.Quote(id) + " is unreadable: " + err.Error())
	}
	p.ID = id
	return &p, nil
}

func ListProviders() ([]Provider, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return ListProvidersFor(org)
}

func ListProvidersFor(org string) ([]Provider, error) {
	dir, err := providersDirFor(org)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return []Provider{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []Provider{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".json")
		p, err := LoadProviderFor(org, id)
		if err != nil {
			// One corrupt record must not hide every other provider.
			// It surfaces through session discovery's UnreadProviders.
			continue
		}
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// CurrentProvider returns the provider id this process was launched as,
// or "" when the launcher did not declare one.
//
// Unset is legitimate and must stay so: the operator runs `wakil secrets
// set` by hand, where the launcher is a human and there is no provider at
// all. When it IS set it must name a registered provider, for the same
// typo reason WAKIL_ORG must name a registered org.
func CurrentProvider() (string, error) {
	id := os.Getenv("WAKIL_PROVIDER")
	if id == "" {
		return "", nil
	}
	org, err := CurrentOrg()
	if err != nil {
		return "", err
	}
	if _, err := LoadProviderFor(org, id); err != nil {
		return "", err
	}
	return id, nil
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS.

- [ ] **Step 5: Mutation-test**

Delete the `EvalSymlinks`/`Stat` block for `claude-code`. Confirm `TestAddProviderRequiresExistingConfigDirForClaudeCode` fails, quote it, revert, verify clean.

- [ ] **Step 6: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "Add provider records: kind, label and a validated claude-code configDir"
```

---

## Task 5: Per-org project registry, with misfiled reporting

**Spec:** §4.3, §5.

**Files:**
- Create: `internal/wakilcore/registry.go`, `internal/wakilcore/registry_test.go`
- Modify: `internal/wakilcore/paths.go` (delete `LoadRegistry`), `internal/wakilcore/resolve.go` (`SetProjectChecked`), `cmd/wakil-ctx/main.go` (`list_projects`)

**Interfaces:**
- Consumes: `OrgDir`, `OrgDirFor`, `LoadProject`, `writeFileAtomic`.
- Produces:
  - `type ProjectEntry struct { Path string \`json:"path"\`; Provider string \`json:"provider,omitempty"\` }`
  - `func LoadRegistry() (map[string]ProjectEntry, error)` / `func LoadRegistryFor(org string) (map[string]ProjectEntry, error)` — empty map, never nil.
  - `func SaveRegistry(org string, reg map[string]ProjectEntry) error`
  - `type MisfiledProject struct { Name, Path, FiledUnder, DeclaredOrg string }` with json tags `name`, `path`, `filedUnder`, `declaredOrg`.
  - `type ProjectListing struct { Projects map[string]ProjectEntry \`json:"projects"\`; Misfiled []MisfiledProject \`json:"misfiled,omitempty"\`; Unreadable []string \`json:"unreadable,omitempty"\` }`
  - `func ListProjectsForOrg() (ProjectListing, error)`

- [ ] **Step 1: Write the failing tests**

```go
func newTestOrgWithProject(t *testing.T, org, declaredOrg string) (home, projPath string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", org)
	if err := CreateOrg(org, Org{}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), ".wakil")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	projPath = filepath.Join(dir, "project.json")
	body := `{"name":"booking","org":"` + declaredOrg + `","roots":[{"path":"/x"}]}`
	if err := os.WriteFile(projPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry(org, map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	return home, projPath
}

func TestListProjectsReportsMisfiledEntryInsteadOfDroppingIt(t *testing.T) {
	_, projPath := newTestOrgWithProject(t, "initech", "umbrella")

	got, err := ListProjectsForOrg()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Projects) != 0 {
		t.Errorf("a project whose file declares another org must not be listed as this org's: %+v", got.Projects)
	}
	if len(got.Misfiled) != 1 {
		t.Fatalf("Misfiled = %+v; want exactly one entry — silently dropping it is the behaviour being replaced", got.Misfiled)
	}
	m := got.Misfiled[0]
	if m.Name != "booking" || m.FiledUnder != "initech" || m.DeclaredOrg != "umbrella" || m.Path != projPath {
		t.Errorf("Misfiled[0] = %+v; want every field populated so the operator knows which side to fix", m)
	}
}

func TestListProjectsReturnsMatchingProjects(t *testing.T) {
	_, projPath := newTestOrgWithProject(t, "initech", "initech")

	got, err := ListProjectsForOrg()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Misfiled) != 0 {
		t.Errorf("Misfiled = %+v; want none", got.Misfiled)
	}
	if e, ok := got.Projects["booking"]; !ok || e.Path != projPath {
		t.Errorf("Projects = %+v; want booking -> %q", got.Projects, projPath)
	}
}

func TestRegistryIsPerOrgAndDoesNotReadOtherOrgs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("umbrella", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("umbrella", map[string]ProjectEntry{"other": {Path: "/nope/project.json"}}); err != nil {
		t.Fatal(err)
	}
	reg, err := LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	if _, found := reg["other"]; found {
		t.Error("the initech registry returned a umbrella project — registries must not be shared")
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "projects.json")); !os.IsNotExist(err) {
		t.Error("no global projects.json may be written any more")
	}
}

func TestProjectEntryCarriesProviderPreference(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: "/p/project.json", Provider: "backup"}}); err != nil {
		t.Fatal(err)
	}
	reg, err := LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	if reg["booking"].Provider != "backup" {
		t.Errorf("Provider = %q; want backup", reg["booking"].Provider)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'Registry|ListProjects|ProjectEntry' -count=1 -v`
Expected: FAIL — undefined: `SaveRegistry`.

- [ ] **Step 3: Implement `registry.go`**

```go
package wakilcore

// ProjectEntry is one row of an org's project registry.
//
// Provider names which of the org's providers should work on this
// project. It is a PREFERENCE, never a binding: nothing headless can
// enforce it, because by the time a Wakil server is running the provider
// has already launched it. Resolve() reports a mismatch and carries on. A
// binding would fire hardest exactly when the operator is rate-limited
// and reaching for the backup account, which is the case the preference
// exists to make easy.
type ProjectEntry struct {
	Path     string `json:"path"`
	Provider string `json:"provider,omitempty"`
}

// registryFileName is declared in org.go by Task 3, which needs it for
// RemoveOrg's dependant count. Do not redeclare it here.

func LoadRegistry() (map[string]ProjectEntry, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return LoadRegistryFor(org)
}

func LoadRegistryFor(org string) (map[string]ProjectEntry, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(dir, registryFileName))
	if os.IsNotExist(err) {
		return map[string]ProjectEntry{}, nil
	}
	if err != nil {
		return nil, err
	}
	m := map[string]ProjectEntry{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, UserError("projects.json for org " + strconv.Quote(org) + " is unreadable: " + err.Error())
	}
	return m, nil
}

func SaveRegistry(org string, reg map[string]ProjectEntry) error {
	dir, err := OrgDirFor(org)
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, registryFileName), b)
}

// MisfiledProject is a registry entry whose project file declares a
// different org than the registry it sits in.
type MisfiledProject struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	FiledUnder  string `json:"filedUnder"`
	DeclaredOrg string `json:"declaredOrg"`
}

// ProjectListing is what list_projects returns.
type ProjectListing struct {
	// Projects is never nil, so an org with none marshals to {}.
	Projects map[string]ProjectEntry `json:"projects"`

	// Misfiled names entries whose project.json declares another org.
	// Reporting rather than silently skipping is the point: before the
	// registry was per-org, such a project simply vanished from the
	// listing with nothing to explain why.
	Misfiled []MisfiledProject `json:"misfiled,omitempty"`

	// Unreadable names entries whose project.json could not be read at
	// all. Same house invariant as SessionList.Skipped and
	// IssuePage.Truncated: carry the partiality signal with the data.
	Unreadable []string `json:"unreadable,omitempty"`
}

// ListProjectsForOrg lists the current org's projects.
//
// The project's own project.json is AUTHORITATIVE for org. Registry
// placement is an index, not an assertion of ownership — if placement
// won, Resolve()'s proj.Org != CurrentOrg() check would be comparing the
// ambient org against a value derived from the directory that ambient org
// already selected, which is a value compared against itself.
func ListProjectsForOrg() (ProjectListing, error) {
	org, err := CurrentOrg()
	if err != nil {
		return ProjectListing{Projects: map[string]ProjectEntry{}}, err
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return ProjectListing{Projects: map[string]ProjectEntry{}}, err
	}
	out := ProjectListing{Projects: map[string]ProjectEntry{}}
	for name, entry := range reg {
		proj, err := LoadProject(entry.Path)
		if err != nil {
			out.Unreadable = append(out.Unreadable, name)
			continue
		}
		if proj.Org != org {
			out.Misfiled = append(out.Misfiled, MisfiledProject{
				Name: name, Path: entry.Path, FiledUnder: org, DeclaredOrg: proj.Org,
			})
			continue
		}
		out.Projects[name] = entry
	}
	sort.Slice(out.Misfiled, func(i, j int) bool { return out.Misfiled[i].Name < out.Misfiled[j].Name })
	sort.Strings(out.Unreadable)
	return out, nil
}
```

Delete `LoadRegistry` from `paths.go`. `registryFileName` is already declared in `org.go` by Task 3 — do not redeclare it.

- [ ] **Step 4: Update `SetProjectChecked` and `list_projects`**

In `resolve.go`, `SetProjectChecked` reads `entry, ok := reg[name]` and uses `entry.Path`. When `proj.Org != currentOrg`, extend the message to say the registry is misfiled:

```go
return UserError(fmt.Sprintf("project %q is filed under org %q but its project.json declares org %q — the project file wins, so fix the registry entry (wakil project add) or the project file", name, currentOrg, proj.Org))
```

In `cmd/wakil-ctx/main.go`, `list_projects` returns `wakilcore.ProjectListing` instead of `map[string]string`, and its body becomes a single `wakilcore.ListProjectsForOrg()` call. Update the tool `Description` to "List projects in the active organization, with any misfiled or unreadable entries named."

- [ ] **Step 5: Run tests**

Run: `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 6: Mutation-test**

Change `ListProjectsForOrg` to `continue` instead of appending to `Misfiled`. Confirm `TestListProjectsReportsMisfiledEntryInsteadOfDroppingIt` fails, quote it, revert, verify clean.

- [ ] **Step 7: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore cmd/wakil-ctx
git commit -m "Per-org project registry, with misfiled entries reported rather than dropped"
```

---

## Task 6: Jira base URL from org.json

**Spec:** §4.1.

**Files:**
- Modify: `internal/wakilcore/jira.go:87-96`
- Test: `internal/wakilcore/jira_test.go`

**Interfaces:**
- Consumes: `LoadOrg`, `normalizeJiraBase`.
- Produces: no new exported names. `NewJiraFromEnv` keeps its signature.

- [ ] **Step 1: Write the failing tests**

```go
func TestJiraBaseComesFromOrgRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "")
	if err := CreateOrg("initech", Org{JiraBase: "https://from-org.atlassian.net"}); err != nil {
		t.Fatal(err)
	}
	c, err := NewJiraFromEnv()
	if err != nil {
		t.Fatalf("NewJiraFromEnv() error = %v", err)
	}
	if c.base != "https://from-org.atlassian.net" {
		t.Errorf("base = %q; want the value from org.json", c.base)
	}
}

func TestJiraBaseEnvOverridesOrgRecord(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "https://override.atlassian.net")
	if err := CreateOrg("initech", Org{JiraBase: "https://from-org.atlassian.net"}); err != nil {
		t.Fatal(err)
	}
	c, err := NewJiraFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if c.base != "https://override.atlassian.net" {
		t.Errorf("base = %q; want the environment override", c.base)
	}
}

func TestJiraUnsetBaseNamesTheOrgAndTheFix(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "initech")
	t.Setenv("WAKIL_JIRA_BASE", "")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	_, err := NewJiraFromEnv()
	if err == nil {
		t.Fatal("NewJiraFromEnv succeeded with no Jira site configured")
	}
	if !strings.Contains(err.Error(), "initech") || !strings.Contains(err.Error(), "--jira-base") {
		t.Errorf("the error must name the org and the command that fixes it; got %q", err)
	}
}
```

If `JiraClient`'s base field is not named `base`, adapt the assertions to whatever accessor exists; do **not** export a new field just for the test — read it from the same package.

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run TestJira -count=1 -v`
Expected: FAIL — `NewJiraFromEnv` errors with "Jira base URL not set" because it never reads `org.json`.

- [ ] **Step 3: Implement**

Replace the head of `NewJiraFromEnv`:

```go
	// WAKIL_JIRA_BASE stays supported as an override, deliberately: it is
	// the only escape hatch when org.json is wrong and a Jira call is
	// needed to diagnose something. The org record is the normal source,
	// because an org may have several providers and a value baked into
	// each registration is N chances for two of them to disagree.
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	rawBase := os.Getenv("WAKIL_JIRA_BASE")
	if rawBase == "" {
		o, err := LoadOrg()
		if err != nil {
			return nil, err
		}
		rawBase = o.JiraBase
	}
	if rawBase == "" {
		return nil, UserError("no Jira site configured for org " + strconv.Quote(org) +
			" — set one with: wakil org set " + org + " --jira-base https://<site>.atlassian.net")
	}
	base, err := normalizeJiraBase(rawBase)
	if err != nil {
		return nil, err
	}
```

and delete the now-duplicated `org := CurrentOrg()` further down.

- [ ] **Step 4: Run tests**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS.

- [ ] **Step 5: Mutation-test**

Swap the precedence so `org.json` wins over the environment. Confirm `TestJiraBaseEnvOverridesOrgRecord` fails, quote it, revert, verify clean.

- [ ] **Step 6: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "Jira base URL comes from org.json, with WAKIL_JIRA_BASE as an override"
```

---

## Task 7: Provider-aware session discovery

**Spec:** §6.

**Files:**
- Modify: `internal/wakilcore/sessions.go` (`sessionsRoot` deleted, `ListSessions`, `GetSession`, `SessionMeta`, `SessionList`)
- Test: `internal/wakilcore/sessions_test.go`

**Interfaces:**
- Consumes: `ListProviders`, `Provider`, `ProviderKindClaudeCode`, `Resolve`.
- Produces:
  - `SessionMeta` gains `Provider string \`json:"provider"\``.
  - `SessionList` gains `UnreadProviders []string \`json:"unreadProviders,omitempty"\``.
  - `func NewSessionList(sessions []SessionMeta, skipped int, unread []string) SessionList` — **signature change**; update every caller.
  - `func providerSessionsRoot(p Provider) (string, bool)` — second value false when the provider has no session adapter.
  - `sessionsRoot` no longer exists.

- [ ] **Step 1: Write the failing tests**

```go
// twoProviderFixture builds an org with two claude-code providers whose
// transcript stores each hold one session for the active project.
func twoProviderFixture(t *testing.T) (projPath string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	wakilDir := filepath.Join(root, ".wakil")
	if err := os.MkdirAll(wakilDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projPath = filepath.Join(wakilDir, "project.json")
	body := `{"name":"booking","org":"initech","roots":[{"path":"` + root + `"}]}`
	if err := os.WriteFile(projPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: projPath}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, session string }{{"primary", "aaaaaaaa-0000-0000-0000-000000000001"}, {"backup", "bbbbbbbb-0000-0000-0000-000000000002"}} {
		cfg := filepath.Join(home, ".claude-"+p.id)
		dir := filepath.Join(cfg, "projects", EncodeRootPath(root))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		line := `{"type":"user","cwd":"` + root + `","message":{"content":"hello from ` + p.id + `"}}` + "\n"
		if err := os.WriteFile(filepath.Join(dir, p.session+".jsonl"), []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := AddProvider("initech", Provider{ID: p.id, Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
			t.Fatal(err)
		}
	}
	return projPath
}

func TestListSessionsSpansEveryProviderAndTagsEachSession(t *testing.T) {
	twoProviderFixture(t)
	t.Setenv("CLAUDE_CONFIG_DIR", "") // must be irrelevant now

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 2 {
		t.Fatalf("Sessions = %+v; want one from each provider", got.Sessions)
	}
	seen := map[string]bool{}
	for _, s := range got.Sessions {
		if s.Provider == "" {
			t.Errorf("session %s has no Provider tag", s.ID)
		}
		seen[s.Provider] = true
	}
	if !seen["primary"] || !seen["backup"] {
		t.Errorf("providers seen = %v; want both primary and backup", seen)
	}
}

func TestListSessionsIgnoresAmbientClaudeConfigDir(t *testing.T) {
	twoProviderFixture(t)
	// A config dir that is NOT a registered provider. Before this change
	// sessionsRoot() read exactly this variable.
	stray := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", stray)

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want the two provider-backed sessions, unaffected by CLAUDE_CONFIG_DIR", got.Sessions)
	}
}

func TestListSessionsNamesProvidersItCannotRead(t *testing.T) {
	twoProviderFixture(t)
	if err := AddProvider("initech", Provider{ID: "ollama", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(got.UnreadProviders, "ollama") {
		t.Errorf("UnreadProviders = %v; want it to name the local provider — an empty answer must be distinguishable from an unsearched one", got.UnreadProviders)
	}
}

func TestGetSessionReadsFromTheOwningProvider(t *testing.T) {
	twoProviderFixture(t)
	got, err := GetSession("bbbbbbbb-0000-0000-0000-000000000002")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != "backup" {
		t.Errorf("Provider = %q; want backup", got.Provider)
	}
	if !strings.Contains(got.FirstPrompt, "backup") {
		t.Errorf("FirstPrompt = %q; want the transcript read from backup's own store", got.FirstPrompt)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run 'TestListSessions|TestGetSession' -count=1 -v`
Expected: FAIL — `SessionMeta` has no field `Provider`.

- [ ] **Step 3: Implement**

Add the fields, then replace `sessionsRoot` with:

```go
// providerSessionsRoot returns the transcript root for one provider, and
// false when that provider has no session adapter.
//
// Session discovery is inherently per-harness: this reads Claude Code's
// own on-disk layout, which is not a leak of the wrong abstraction but
// the honest shape of the problem. A codex or local provider would need
// its own adapter with its own format, so it reports as unread rather
// than being silently omitted.
//
// This deliberately does NOT read CLAUDE_CONFIG_DIR. The old sessionsRoot
// did, and fell back to ~/.claude/projects when it was unset — harmless
// only while CurrentOrg() read the same variable. Once the org comes from
// WAKIL_ORG the two can disagree, and the result is operating as one org
// while listing another account's history.
func providerSessionsRoot(p Provider) (string, bool) {
	if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
		return "", false
	}
	return filepath.Join(p.ConfigDir, "projects"), true
}
```

`ListSessions` keeps its whole matching body — the encoded-prefix match, the `firstCwd` confirmation, the `skipped` accounting — and wraps it in a loop over `ListProviders()`. Restructure as:

1. `r, err := Resolve()` (unchanged).
2. Compute `prefixes` and `roots` once, outside the loop (unchanged logic).
3. `providers, err := ListProviders()`.
4. For each provider: `base, ok := providerSessionsRoot(p)`; if `!ok`, append `p.ID` to `unread` and continue. `os.ReadDir(base)`; on `os.IsNotExist` append to `unread` and continue; on any other error append to `unread` and continue.
5. Inside, the existing per-directory loop, setting `Provider: p.ID` on every `SessionMeta` it builds.
6. Sort the merged result newest-first exactly as today, and return `NewSessionList(out, skipped, unread)`.

`GetSession` becomes:

```go
func GetSession(id string) (SessionMeta, error) {
	all, err := ListSessions()
	if err != nil {
		return SessionMeta{}, err
	}
	var found []SessionMeta
	for _, s := range all.Sessions {
		if s.ID == id {
			found = append(found, s)
		}
	}
	switch len(found) {
	case 0:
		return SessionMeta{}, UserError("session not found for the active project: " + id)
	case 1:
	default:
		var ps []string
		for _, s := range found {
			ps = append(ps, s.Provider)
		}
		return SessionMeta{}, UserError("session id " + id + " exists under more than one provider (" +
			strings.Join(ps, ", ") + ") — this should not happen; report which providers share it")
	}
	s := found[0]
	org, err := CurrentOrg()
	if err != nil {
		return SessionMeta{}, err
	}
	p, err := LoadProviderFor(org, s.Provider)
	if err != nil {
		return SessionMeta{}, err
	}
	base, ok := providerSessionsRoot(*p)
	if !ok {
		return SessionMeta{}, UserError("provider " + s.Provider + " has no session adapter")
	}
	s.FirstPrompt = firstPrompt(filepath.Join(base, s.Root, id+".jsonl"))
	return s, nil
}
```

Note that the org is re-resolved rather than carried on `SessionList`: a wire type must not grow a field for an internal convenience.

Update `NewSessionList`'s signature and all its callers, including the error paths that pass `nil, 0` today — they become `nil, 0, nil`.

- [ ] **Step 4: Run tests**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS. Existing session tests that seed `CLAUDE_CONFIG_DIR` must be rewritten to register a provider instead.

- [ ] **Step 5: Mutation-test twice**

(a) Make `providerSessionsRoot` fall back to `os.Getenv("CLAUDE_CONFIG_DIR")` when `ConfigDir` is empty. Confirm `TestListSessionsIgnoresAmbientClaudeConfigDir` fails. (b) Make the `!ok` branch `continue` without appending to `unread`. Confirm `TestListSessionsNamesProvidersItCannotRead` fails. Quote both messages, revert both, verify clean.

- [ ] **Step 6: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "Session discovery enumerates the org's providers instead of reading CLAUDE_CONFIG_DIR"
```

---

## Task 8: The provider match report on get_context

**Spec:** §7.

**Files:**
- Modify: `internal/wakilcore/resolve.go`
- Test: `internal/wakilcore/resolve_test.go`

**Interfaces:**
- Consumes: `CurrentProvider`, `LoadOrgFor`, `LoadRegistryFor`, and `twoProviderFixture` from Task 7's `sessions_test.go` (same package — do not duplicate it).
- Produces: `type ProviderReport struct { Selected, Running string; Match bool; Note string }` with json tags `selected,omitempty`, `running,omitempty`, `match`, `note,omitempty`; `Resolved` gains `Provider ProviderReport`.

- [ ] **Step 1: Write the failing tests**

```go
func TestResolveReportsProviderMismatchWithoutBlocking(t *testing.T) {
	projPath := twoProviderFixture(t)
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath, Provider: "backup"}}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROVIDER", "primary")

	r, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve() must not fail on a provider mismatch: %v", err)
	}
	if r.Provider.Selected != "backup" || r.Provider.Running != "primary" || r.Provider.Match {
		t.Errorf("Provider = %+v; want selected=backup running=primary match=false", r.Provider)
	}
}

func TestResolveFallsBackToTheOrgDefaultProvider(t *testing.T) {
	projPath := twoProviderFixture(t)
	if err := SaveOrg("initech", Org{DefaultProvider: "primary"}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_PROVIDER", "primary")

	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.Provider.Selected != "primary" || !r.Provider.Match {
		t.Errorf("Provider = %+v; want the org default adopted and matched", r.Provider)
	}
}

func TestResolveSaysWhenTheLauncherDeclaredNoProvider(t *testing.T) {
	twoProviderFixture(t)
	t.Setenv("WAKIL_PROVIDER", "")

	r, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if r.Provider.Running != "" || r.Provider.Note == "" {
		t.Errorf("Provider = %+v; want an explicit note rather than a guess", r.Provider)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/wakilcore/ -run TestResolve -count=1 -v`
Expected: FAIL — `Resolved` has no field `Provider`.

- [ ] **Step 3: Implement**

```go
// ProviderReport says which provider should be working on the active
// project and which one actually is. It never blocks; see
// ProjectEntry.Provider for why.
type ProviderReport struct {
	Selected string `json:"selected,omitempty"`
	Running  string `json:"running,omitempty"`
	Match    bool   `json:"match"`
	Note     string `json:"note,omitempty"`
}

// providerReport builds the report. Every failure inside is soft: this is
// advisory information hanging off a call whose real job is resolving the
// active context, and a broken provider record must not take get_context
// down with it.
func providerReport(org string, projectPath string) ProviderReport {
	var rep ProviderReport
	// Matched by PATH, not by name. The registry key and project.json's
	// "name" field are written independently and can differ; the active
	// context stores a path, so the path is the only join key that cannot
	// silently miss.
	if reg, err := LoadRegistryFor(org); err == nil {
		for _, e := range reg {
			if e.Path == projectPath {
				rep.Selected = e.Provider
				break
			}
		}
	}
	if rep.Selected == "" {
		if o, err := LoadOrgFor(org); err == nil {
			rep.Selected = o.DefaultProvider
		}
	}
	running, err := CurrentProvider()
	if err == nil {
		rep.Running = running
	}
	switch {
	case rep.Running == "":
		rep.Note = "the launcher did not declare WAKIL_PROVIDER, so the running provider is unknown"
	case rep.Selected == "":
		rep.Note = "this project names no provider and the org has no default"
		rep.Match = true
	default:
		rep.Match = rep.Selected == rep.Running
		if !rep.Match {
			rep.Note = "this project is set to run on " + rep.Selected + " — nothing is blocked, but history and rate limits belong to " + rep.Running
		}
	}
	return rep
}
```

Call it at the end of `Resolve()`, after the org check passes, as `providerReport(currentOrg, active.Project)`, and set `Resolved.Provider`.

- [ ] **Step 4: Run tests**

Run: `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 5: Mutation-test**

Make `Resolve` return an error when `!rep.Match`. Confirm `TestResolveReportsProviderMismatchWithoutBlocking` fails, quote it, revert, verify clean.

- [ ] **Step 6: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add internal/wakilcore
git commit -m "get_context reports the selected vs running provider, without blocking"
```

---

## Task 9: The wakil CLI — org and provider subcommands

**Spec:** §8.

**Files:**
- Modify: `cmd/wakil/main.go` (usage, `run` dispatch, `--org`)
- Create: `cmd/wakil/orgcmd.go`, `cmd/wakil/providercmd.go`, `cmd/wakil/projectcmd.go`
- Test: `cmd/wakil/main_test.go` (existing), plus `cmd/wakil/orgcmd_test.go`

**Interfaces:**
- Consumes: everything from Tasks 3–5.
- Produces: no exported Go API. Commands:
  - `wakil org create <org> [--display S] [--jira-base URL] [--default-provider ID]`
  - `wakil org set <org> [same flags]`
  - `wakil org list`
  - `wakil org rm <org> [--force]`
  - `wakil provider add <id> --kind <claude-code|codex|local> [--config-dir D] [--label L]`
  - `wakil provider list`
  - `wakil provider rm <id>`
  - `wakil provider config-dir <id>` — prints ONLY the provider's resolved `configDir` and exits 0; exits 1 with a message on stderr for a kind that has none. This exists for `register-provider.sh`, which needs one value in one line of shell without depending on `jq`; a `--json` listing would have made the script's correctness depend on a JSON parser being installed.
  - `wakil project add <name> --path /abs/.wakil/project.json [--provider ID]`
  - `wakil project list`
  - `wakil project rm <name>`
  - Global `--org <org>` accepted anywhere in argv, consumed before dispatch.

- [ ] **Step 1: Write the failing tests**

```go
func TestGlobalOrgFlagSetsTheOrgForTheCommand(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "")

	var stderr bytes.Buffer
	if code := run([]string{"org", "create", "initech"}, strings.NewReader(""), &stderr, failingStore(t)); code != 0 {
		t.Fatalf("exit = %d, stderr = %q", code, stderr.String())
	}
	stderr.Reset()
	if code := run([]string{"--org", "initech", "provider", "list"}, strings.NewReader(""), &stderr, failingStore(t)); code != 0 {
		t.Fatalf("--org was not honoured: exit = %d, stderr = %q", code, stderr.String())
	}
}

func TestOrgCreateRefusesBadJiraBaseWithExitCode2(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	code := run([]string{"org", "create", "initech", "--jira-base", "http://insecure"}, strings.NewReader(""), &stderr, failingStore(t))
	if code != 2 {
		t.Errorf("exit = %d; want 2 (operator can fix by retyping)", code)
	}
	if !strings.Contains(stderr.String(), "https") {
		t.Errorf("stderr = %q; want it to say what is wrong", stderr.String())
	}
}

func TestUnknownSubcommandStillExits2WithUsage(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var stderr bytes.Buffer
	if code := run([]string{"frobnicate"}, strings.NewReader(""), &stderr, failingStore(t)); code != 2 {
		t.Errorf("exit = %d; want 2", code)
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Errorf("stderr must include usage; got %q", stderr.String())
	}
}
```

`failingStore` is a `secretStore` that calls `t.Fatal` if invoked — no org or provider command may ever touch the Keychain. Add it to the test file if an equivalent does not already exist.

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./cmd/wakil/ -count=1 -v`
Expected: FAIL — `run` treats `args[0]` as `secrets` unconditionally and rejects `org`.

- [ ] **Step 3: Restructure `run` into a dispatch**

```go
func run(args []string, stdin io.Reader, stderr io.Writer, store secretStore) int {
	args, err := applyOrgFlag(args)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	switch args[0] {
	case "secrets":
		return runSecrets(args, stdin, stderr, store)
	case "org":
		return runOrg(args[1:], stderr)
	case "provider":
		return runProvider(args[1:], stderr)
	case "project":
		return runProject(args[1:], stderr)
	default:
		fmt.Fprintln(stderr, message(wakilcore.UserError("unknown command\n\n"+usage)))
		return 2
	}
}

// applyOrgFlag consumes a global "--org <name>" from anywhere in argv and
// puts it in the environment, so every downstream wakilcore call resolves
// the same way a registered server would.
//
// Setting the variable rather than threading a parameter keeps ONE org
// resolution path. A flag is safe here where a config file would not be:
// a human typing it IS the launcher, which is exactly what the security
// model requires the org to come from.
func applyOrgFlag(args []string) ([]string, error) {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--org":
			if i+1 >= len(args) {
				return nil, wakilcore.UserError("--org needs a value")
			}
			if err := os.Setenv("WAKIL_ORG", args[i+1]); err != nil {
				return nil, err
			}
			i++
		case strings.HasPrefix(args[i], "--org="):
			if err := os.Setenv("WAKIL_ORG", strings.TrimPrefix(args[i], "--org=")); err != nil {
				return nil, err
			}
		default:
			out = append(out, args[i])
		}
	}
	return out, nil
}
```

Move the existing body of `run` (the `set-db` pre-dispatch and the `secrets set` path) verbatim into `runSecrets`.

- [ ] **Step 4: Implement the three command files**

`orgcmd.go`, `providercmd.go`, `projectcmd.go` each expose `runX(args []string, stderr io.Writer) int`, parse with `flag.NewFlagSet(..., flag.ContinueOnError)` writing errors to `stderr`, and return **2** for anything the operator can fix by retyping and **1** for a failure while doing the work — matching the exit-code contract already documented on `run`.

`wakil org create` takes the org from `args[0]`, not from `--org`: the org being created is the subject of the command, and reading it from the global flag would make `wakil --org a org create b` ambiguous. `org set`, `org rm` do the same. `provider *` and `project *` operate on the **current** org from `--org`/`WAKIL_ORG`.

`provider add` prints, for `--kind codex` and `--kind local`, the exact environment a client must pass — `WAKIL_ORG=<org> WAKIL_PROVIDER=<id>` plus the five binary paths — because those kinds are recorded but not automated.

`project add` writes a `ProjectEntry` into the current org's registry. Before writing it loads the project file and **refuses** if `proj.Org != currentOrg`, naming both — catching the misfiled case at the point it is created rather than only reporting it later.

- [ ] **Step 5: Extend `usage`**

Add every command above to the `usage` const, keeping the existing `secrets` text unchanged. Keep the stdin-only warning on `secrets set`.

- [ ] **Step 6: Run tests**

Run: `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 7: Mutation-test**

Make `project add` skip its org check. Confirm the corresponding test fails, quote it, revert, verify clean.

- [ ] **Step 8: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && go test ./... -race && go test ./... -shuffle=on && make build
git add cmd/wakil
git commit -m "wakil CLI: org, provider and project subcommands with a global --org"
```

---

## Task 10: register-provider.sh

**Spec:** §8.

**Files:**
- Create: `scripts/register-provider.sh`
- Delete: `scripts/register-org.sh`
- Modify: `Makefile` (any reference), `scripts/makefile_test.go` if it names the script

**Interfaces:**
- Consumes: the `wakil` binary (`wakil org list`, `wakil provider list`) and `claude mcp add`.
- Produces: a shell entry point. Usage:
  `scripts/register-provider.sh <org> <provider-id> /abs/path/to/bin`

- [ ] **Step 1: Write the failing test**

Extend `scripts/makefile_test.go` (or add `scripts/register_provider_test.go`) with a Go test that shells out to `bash scripts/register-provider.sh` with a stub `claude` and a stub `wakil` on `PATH` in `t.TempDir()`:

```go
func TestRegisterProviderPassesOrgAndProviderToEveryServer(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(t.TempDir(), "calls.log")
	writeStub(t, filepath.Join(bin, "claude"), "#!/bin/sh\necho \"$@\" >> "+log+"\n")
	// The stub must answer `provider config-dir`, which the script calls to
	// find the account whose config the registration lands in.
	cfgDir := t.TempDir()
	writeStub(t, filepath.Join(bin, "wakil"), "#!/bin/sh\ncase \"$1 $2\" in\n'provider config-dir') echo "+cfgDir+" ;;\n'org list') echo initech ;;\n'provider list') echo primary ;;\nesac\nexit 0\n")
	for _, s := range []string{"wakil-ctx", "wakil-db", "wakil-pm", "wakil-http", "wakil-recall"} {
		writeStub(t, filepath.Join(bin, s), "#!/bin/sh\nexit 0\n")
	}
	cmd := exec.Command("bash", "scripts/register-provider.sh", "initech", "primary", bin)
	cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("script failed: %v\n%s", err, out)
	}
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	calls := string(b)
	for _, s := range []string{"wakil-ctx", "wakil-db", "wakil-pm", "wakil-http", "wakil-recall"} {
		if !strings.Contains(calls, s) {
			t.Errorf("server %s was not registered", s)
		}
	}
	if strings.Count(calls, "WAKIL_ORG=initech") != 5 {
		t.Errorf("WAKIL_ORG must be pinned on all five servers; calls:\n%s", calls)
	}
	if strings.Count(calls, "WAKIL_PROVIDER=primary") != 5 {
		t.Errorf("WAKIL_PROVIDER must be pinned on all five servers; calls:\n%s", calls)
	}
	if strings.Contains(calls, "WAKIL_JIRA_BASE") {
		t.Errorf("the Jira base URL lives in org.json now and must not be baked into a registration; calls:\n%s", calls)
	}
}
```

`writeStub` writes the file and chmods it 0755.

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./scripts/ -run TestRegisterProvider -count=1 -v`
Expected: FAIL — `scripts/register-provider.sh` does not exist.

- [ ] **Step 3: Write the script**

Port `register-org.sh` with these changes, keeping its `set -euo pipefail`, its refuse-early checks, its per-server failure reporting and its non-zero exit on any failure:

- Arguments become `<org> <provider-id> <bin-dir>`; `CLAUDE_CONFIG_DIR` is **read from the provider record**, not from the environment.
- Refuse unless: `claude` is on `PATH`; all five binaries exist and are executable; `wakil org list` contains the org; `wakil provider list --org <org>` contains the provider id.
- Look up the provider's config dir with `wakil provider config-dir <id> --org <org>` (one value, one line, no `jq`) and export it as `CLAUDE_CONFIG_DIR` for `claude mcp add`, so the registration lands in that account's config.
- Pass `-e WAKIL_ORG=<org> -e WAKIL_PROVIDER=<id>` to every `claude mcp add`, with `--scope user`.
- Do **not** pass `WAKIL_JIRA_BASE`.
- Rewrite the header comment: the block explaining why `CLAUDE_CONFIG_DIR` is pinned is replaced by one explaining that org identity is now DECLARED, and that pinning `WAKIL_ORG` at registration is what stops a server inheriting a stale value. Keep the symlink note, now about the recorded `configDir`.

- [ ] **Step 4: Delete the old script and update references**

```bash
git rm scripts/register-org.sh
grep -rn "register-org" --include='*' . | grep -v '\.git/'
```

Fix every hit (`Makefile`, docs are Task 11).

- [ ] **Step 5: Run tests**

Run: `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 6: Mutation-test**

Drop `-e WAKIL_PROVIDER` from one of the five `claude mcp add` lines. Confirm the count assertion fails naming 4 vs 5, quote it, revert, verify clean.

- [ ] **Step 7: Gate and commit**

```bash
gofmt -l . && go vet ./... && go test ./... -count=2 && make build
git add -A scripts Makefile
git commit -m "register-provider.sh replaces register-org.sh; pins WAKIL_ORG and WAKIL_PROVIDER"
```

---

## Task 11: Documentation — charter amendment and operator runbook

**Spec:** §9, §10.

**Files:**
- Modify: `docs/wakil/north-star.md` (Invariant 4, Decision 4, Phase 1 entry)
- Modify: `docs/wakil/operator-todo.md` (replace the MIGRATION section and §3)
- Modify: `docs/wakil/org-and-provider-model.md` (mark superseded)
- Modify: `docs/wakil/phase-1-acceptance.md` (note the commands have changed)

**Interfaces:** none — documentation only. It is a task rather than a step of another task because it is the charter change the spec requires to happen *deliberately*, and a reviewer must be able to reject the wording without rejecting the code.

- [ ] **Step 1: Amend the charter**

In `north-star.md`, rewrite Invariant 4 to:

> 4. **An organisation is a credential boundary; a provider carries its own auth.**
>    An organisation owns its adapter credentials and secrets, stored in the Keychain
>    under `wakil:<org>:<ref>`. Cross-org bleed must be structurally impossible — by the
>    service name, by the per-org directory, and by `Resolve()`'s check — not merely
>    avoided. A **provider** (a Claude subscription, Codex, a local model) owns its own
>    authentication; for Claude Code that is a config dir and an OAuth token. One
>    organisation may hold several providers, and one provider may serve several
>    organisations. *(Amended 2026-09-06: the original text made the org's config dir the
>    whole boundary, which structurally forbade two Claude accounts on one org.)*

Amend Decision 4 to attach the harness credential bundle to the **provider** rather than the org, keeping its verified Agent-SDK findings intact and adding a dated line recording the change. Leave Decision 16 alone — note in the amendment that it is what this implements. Leave Invariant 5 alone; add one sentence saying the provider is session-scoped and deliberately not part of the active triple.

- [ ] **Step 2: Rewrite the operator runbook**

Replace `operator-todo.md`'s MIGRATION section and §3 with the spec's §9 rebuild procedure: deregister the five servers per org, `wakil org create`, `wakil provider add`, `register-provider.sh`, `wakil project add`, `set_project`. State plainly that `~/.wakil` was deleted and that Keychain entries are untouched because org strings did not change. Replace every `CLAUDE_CONFIG_DIR=~/.claude-<org> wakil ...` invocation with `wakil ... --org <org>`.

- [ ] **Step 3: Mark the deferred note superseded**

At the top of `org-and-provider-model.md`, replace the status line with:

> **Status: SUPERSEDED 2026-09-06** by
> `docs/superpowers/specs/2026-09-06-org-provider-decoupling-design.md`, which implements
> this model and answers the open questions below. Kept for the reasoning and the
> measurements, which the spec cites rather than repeats.

- [ ] **Step 4: Correct the acceptance record**

In `phase-1-acceptance.md`, add a dated note at the top: the run's results stand, but its commands no longer work verbatim — `CLAUDE_CONFIG_DIR` no longer selects the org, and `register-org.sh` is gone. Do **not** rewrite the recorded results; they are a record of what happened.

- [ ] **Step 5: Verify no stale references remain**

```bash
grep -rn "CLAUDE_CONFIG_DIR=.*wakil\|register-org\.sh\|OrgFromConfigDir" docs/ scripts/ internal/ cmd/ Makefile | grep -v '\.git/'
```
Expected: only historical mentions inside `phase-1-acceptance.md` and `org-and-provider-model.md`, both now explicitly marked as history.

- [ ] **Step 6: Commit**

```bash
git add docs
git commit -m "Amend the charter for the org/provider split and rewrite the operator runbook"
```

---

## Final verification

- [ ] `gofmt -l .` prints nothing
- [ ] `go vet ./...` clean
- [ ] `go test ./... -count=2` PASS
- [ ] `go test ./... -race` PASS
- [ ] `go test ./... -shuffle=on` PASS
- [ ] `make build` writes all six binaries
- [ ] `make test-live` PASS (needs the two throwaway containers; the target prints the `docker run` lines when one is missing)
- [ ] `grep -rn "CLAUDE_CONFIG_DIR" internal/ cmd/` returns **only** `provider.go`'s doc comments and `sessions.go`'s explanation of why it is no longer read
- [ ] A real end-to-end rehearsal in a throwaway `HOME`: create two orgs, add two providers to one, register a project, `set_project`, confirm `list_projects` and `get_context` behave, and confirm an unregistered `WAKIL_ORG` is refused
