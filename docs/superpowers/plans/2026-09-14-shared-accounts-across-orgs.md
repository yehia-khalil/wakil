# One Claude account, several organisations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one Claude Code account (one `CLAUDE_CONFIG_DIR`) be registered under several
Wakil organisations, so an operator whose account has hit its usage limit can move to one
that has quota left, whichever org it happens to live in.

**Architecture:** A config dir keeps at most one **headless home** — the org whose
`WAKIL_ORG` is pinned inside it by `scripts/register-provider.sh`. Additional
`(org, provider)` records may name the same dir behind an explicit `--share`; they are
Wakil-only bindings, because every Wakil session launches with `--strict-mcp-config` and a
generated MCP config carrying its own org, and so never reads the pin. Sharing is across
organisations only — never within one, where a second record would collide on
`WAKIL_PROVIDER` and buy nothing.

**Tech Stack:** Go 1.27 (`internal/wakilcore`, `cmd/wakil`), POSIX shell
(`scripts/register-provider.sh`). No Swift. `CGO_ENABLED=0` is exported by the Makefile
for build, test and vet alike — always go through `make`, never bare `go test`.

**Spec:** `docs/superpowers/specs/2026-09-14-shared-accounts-across-orgs-design.md`

## Global Constraints

- **`make test` and `make vet` must be green at every commit.** This project's most
  repeated finding is that a green suite is the floor and decides nothing above it — but
  it is still the floor.
- **A refusal must name the fix.** Every `UserError` in this codebase tells the operator
  what to run next; see the existing collision message at `internal/wakilcore/provider.go:150`.
  A test that asserts a refusal asserts its *content*, not just that it refused.
- **A refused write leaves nothing behind.** `TestAddProviderRejectsConfigDirClaimedByAnotherOrg`
  asserts this and new tests must too.
- **`omitempty` on the new field.** Every existing provider record must stay byte-identical
  when rewritten.
- **Never run `wakil provider add`, `wakil provider rm` or `scripts/register-provider.sh`
  against the operator's real `~/.wakil`.** Every test sets `t.Setenv("HOME", t.TempDir())`.
- **Nothing in this plan touches Swift, the write gate, the Keychain service scheme
  (`wakil:<org>:<ref>`), or the cross-org project guard.**

---

### Task 1: `Provider.Shared`, and a home-aware owner lookup

**Files:**
- Modify: `internal/wakilcore/provider.go:19-36` (the `Provider` struct)
- Modify: `internal/wakilcore/provider.go:187-204` (`findConfigDirOwner`)
- Test: `internal/wakilcore/provider_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Provider.Shared bool` with tag `json:"shared,omitempty"`
  - `func findConfigDirOwner(dir string, homeOnly bool) (org, providerID string, err error)`
  - `func ConfigDirHome(dir string) (org, providerID string, err error)`

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/provider_test.go`:

```go
func TestProviderSharedRoundTripsAndIsOmittedWhenFalse(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: cfg,
	}); err != nil {
		t.Fatal(err)
	}

	// An unshared record must write no "shared" key at all: every record
	// already on disk predates this field and must survive a rewrite
	// byte-identical.
	raw, err := os.ReadFile(filepath.Join(home, ".wakil/orgs/initech/providers/main.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "shared") {
		t.Errorf("an unshared provider record wrote a \"shared\" key: %s", raw)
	}

	p, err := LoadProviderFor("initech", "main")
	if err != nil {
		t.Fatal(err)
	}
	if p.Shared {
		t.Error("a record with no \"shared\" key loaded as Shared=true")
	}
}

func TestConfigDirHomeSkipsSharedRecordsRegardlessOfOrgOrder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// "alpha" sorts before "zulu", and ListOrgs sorts. The SHARED record is
	// deliberately the one that sorts first, so a ConfigDirHome that simply
	// returned the first match would pass this test for the wrong reason.
	for _, org := range []string{"alpha", "zulu"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	// zulu homes it; alpha only shares it. Written directly rather than
	// through AddProvider, which does not learn --share until Task 2.
	writeProviderRecord(t, home, "zulu", "home-acct", Provider{
		Kind: ProviderKindClaudeCode, ConfigDir: cfg,
	})
	writeProviderRecord(t, home, "alpha", "shared-acct", Provider{
		Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
	})

	org, id, err := ConfigDirHome(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if org != "zulu" || id != "home-acct" {
		t.Errorf("ConfigDirHome = (%q, %q); want (\"zulu\", \"home-acct\")", org, id)
	}

	// The unfiltered lookup still sees every record — AddProvider's
	// same-org duplicate check depends on it.
	org, id, err = findConfigDirOwner(cfg, false)
	if err != nil {
		t.Fatal(err)
	}
	if org != "alpha" || id != "shared-acct" {
		t.Errorf("findConfigDirOwner(homeOnly=false) = (%q, %q); want the first match (\"alpha\", \"shared-acct\")", org, id)
	}
}

func TestConfigDirHomeReportsNoneForAnUnclaimedDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	org, id, err := ConfigDirHome(filepath.Join(home, ".claude-nobody"))
	if err != nil {
		t.Fatal(err)
	}
	if org != "" || id != "" {
		t.Errorf("ConfigDirHome on an unclaimed dir = (%q, %q); want two empty strings", org, id)
	}
}
```

And add this helper beside `addClaudeProvider` (`provider_test.go:184`):

```go
// writeProviderRecord writes a provider record straight to disk, bypassing
// AddProvider. Needed because some fixtures are states AddProvider will
// not create for you — a shared record before AddProvider learns --share,
// for instance.
func writeProviderRecord(t *testing.T, home, org, id string, p Provider) {
	t.Helper()
	dir := filepath.Join(home, ".wakil/orgs", org, "providers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, id+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}
```

Make sure `encoding/json` and `strings` are in that file's imports.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -A 5 "provider_test"`
Expected: FAIL — `p.Shared` undefined, `ConfigDirHome` undefined, and
`findConfigDirOwner` called with 2 arguments when it takes 1.

- [ ] **Step 3: Add the field**

In `internal/wakilcore/provider.go`, inside `type Provider struct`, after `ClaudePath`:

```go
	// Shared records that this binding did NOT claim the config dir's
	// headless home — another org's registration did. It exists so
	// ConfigDirHome can name the org whose WAKIL_ORG is pinned inside the
	// directory, which is the only org a plain `claude` session started
	// there will ever run as.
	//
	// It is a property of the RECORD's relationship to the directory, not
	// of the account: the account is shared either way. The name was kept
	// despite that ambiguity because no better one was found; see the
	// design document's §8.
	Shared bool `json:"shared,omitempty"`
```

- [ ] **Step 4: Teach the lookup about homes**

Replace `findConfigDirOwner` (`provider.go:187-204`) with:

```go
func findConfigDirOwner(dir string, homeOnly bool) (org, providerID string, err error) {
	orgs, err := ListOrgs()
	if err != nil {
		return "", "", err
	}
	for _, o := range orgs {
		providers, _, err := listProvidersFor(o)
		if err != nil {
			return "", "", err
		}
		for _, p := range providers {
			if p.ConfigDir != dir {
				continue
			}
			// A shared record did not pin anything, so it cannot be the
			// home. It is still a real owner for the duplicate check,
			// which is why this is a parameter and not a fixed rule.
			if homeOnly && p.Shared {
				continue
			}
			return o, p.ID, nil
		}
	}
	return "", "", nil
}

// ConfigDirHome reports which org, and which of its providers, pinned
// WAKIL_ORG inside dir — the org a plain `claude` session started against
// that directory will run as, whatever else shares it. Returns "", "",
// nil when no org has claimed it.
//
// This is the question scripts/register-provider.sh has to ask before it
// runs `claude mcp add`: pinning a directory homed to another org would
// silently break that org's headless flow, which is the whole thing the
// one-dir-one-org rule was ever protecting.
func ConfigDirHome(dir string) (org, providerID string, err error) {
	return findConfigDirOwner(dir, true)
}
```

Update the existing call inside `AddProvider` (`provider.go:145`) to
`findConfigDirOwner(p.ConfigDir, false)` so it still sees every owner.

Extend `findConfigDirOwner`'s doc comment with one paragraph:

```go
// homeOnly selects between the two questions this function answers. False
// is "does ANY record claim this dir", which is what AddProvider's
// duplicate check needs. True is "which record PINNED it", which is what
// ConfigDirHome exposes. They differ only once a shared record exists,
// and conflating them would let a shared record be reported as the home —
// arbitrarily, since the answer would then depend on org sort order.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, including every pre-existing provider test.

- [ ] **Step 6: Vet and commit**

```bash
make vet
git add internal/wakilcore/provider.go internal/wakilcore/provider_test.go
git commit -m "Record which provider pinned a config dir, and ask for it separately

A config dir may soon be named by several orgs' provider records. Only one
of them pinned WAKIL_ORG inside it, and only that one decides what a plain
\`claude\` session there runs as. Provider.Shared marks the records that did
not, and findConfigDirOwner gains a homeOnly parameter so the duplicate
check (any owner) and the pin question (the home) stay distinguishable.

Nothing changes behaviour yet: no caller passes homeOnly=true except the
new ConfigDirHome, which nothing calls.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `AddProvider` learns `--share`

**Files:**
- Modify: `internal/wakilcore/provider.go:144-160` (the collision branch of `AddProvider`)
- Test: `internal/wakilcore/provider_test.go`

**Interfaces:**
- Consumes: `Provider.Shared`, `findConfigDirOwner(dir, homeOnly)` from Task 1.
- Produces: `AddProvider(org string, p Provider) error` — unchanged signature; the
  behaviour now keys off `p.Shared`.

- [ ] **Step 1: Write the failing tests**

Append to `internal/wakilcore/provider_test.go`:

```go
// The four cross-org rows of the design's §4.2 matrix, plus the same-org
// row, one subtest each. The matrix is the specification; this is it
// executed.
func TestAddProviderShareMatrix(t *testing.T) {
	t.Run("another org owns it, no --share: refused, and the message names --share", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"initech", "personal"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg})
		if err == nil {
			t.Fatal("AddProvider accepted a configDir owned by another org without --share")
		}
		// The operator's next question is "so how DO I use this account
		// here?", and the refusal must answer it without a second command.
		for _, want := range []string{`"initech"`, `"main"`, "--share"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("refusal must contain %s; got %q", want, err)
			}
		}
		if _, err := LoadProviderFor("personal", "work"); err == nil {
			t.Error("a refused AddProvider still wrote a provider record")
		}
	})

	t.Run("another org owns it, with --share: accepted and marked shared", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		for _, org := range []string{"initech", "personal"} {
			if err := CreateOrg(org, Org{}); err != nil {
				t.Fatal(err)
			}
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		if err := AddProvider("personal", Provider{
			ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		}); err != nil {
			t.Fatalf("AddProvider refused a legitimate --share: %v", err)
		}
		p, err := LoadProviderFor("personal", "work")
		if err != nil {
			t.Fatal(err)
		}
		if !p.Shared {
			t.Error("a --share registration did not persist Shared=true")
		}
		// The home does not move.
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "initech" || id != "main" {
			t.Errorf("sharing moved the home to (%q, %q); it must stay (\"initech\", \"main\")", org, id)
		}
	})

	t.Run("nobody owns it, with --share: refused", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("personal", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := filepath.Join(home, ".claude-fresh")
		if err := os.MkdirAll(cfg, 0o755); err != nil {
			t.Fatal(err)
		}
		err := AddProvider("personal", Provider{
			ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		})
		if err == nil {
			t.Fatal("AddProvider accepted --share for a dir no org has registered")
		}
		if !strings.Contains(err.Error(), "nothing to share") {
			t.Errorf("refusal should say there is nothing to share; got %q", err)
		}
		if _, err := LoadProviderFor("personal", "work"); err == nil {
			t.Error("a refused AddProvider still wrote a provider record")
		}
	})

	t.Run("the same org owns it, with --share: refused with its own message", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("initech", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")

		err := AddProvider("initech", Provider{
			ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true,
		})
		if err == nil {
			t.Fatal("--share let one org register the same configDir twice")
		}
		// Not the generic cross-org message: within one org WAKIL_PROVIDER
		// would collide, and a second id buys no second account and no
		// second quota, which is the entire point of the feature.
		if !strings.Contains(err.Error(), "same org") {
			t.Errorf("the same-org refusal must say so in its own words; got %q", err)
		}
		if strings.Contains(err.Error(), "--share") {
			t.Errorf("the same-org refusal must not suggest --share, which cannot help; got %q", err)
		}
	})

	t.Run("nobody owns it, no --share: registered as the home", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("HOME", home)
		if err := CreateOrg("initech", Org{}); err != nil {
			t.Fatal(err)
		}
		cfg := addClaudeProvider(t, home, "initech", "main", ".claude-initech")
		org, id, err := ConfigDirHome(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if org != "initech" || id != "main" {
			t.Errorf("ConfigDirHome = (%q, %q); want (\"initech\", \"main\")", org, id)
		}
	})
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -A 5 TestAddProviderShareMatrix`
Expected: FAIL — the `--share` subtests fail because `AddProvider` ignores
`p.Shared` and refuses every claimed dir with today's single message.

- [ ] **Step 3: Replace the collision branch**

In `internal/wakilcore/provider.go`, replace the whole `if p.ConfigDir != ""` block
(currently lines 144-160) with:

```go
	// Checked after the duplicate-id stat so that re-adding an existing id
	// against its own configDir reports the duplicate rather than a
	// collision with itself, and after the symlink resolution above so that
	// two names for one directory are recognised as one directory.
	if p.ConfigDir != "" {
		ownerOrg, ownerID, err := findConfigDirOwner(p.ConfigDir, false)
		if err != nil {
			return err
		}
		switch {
		case ownerID != "" && ownerOrg == org:
			// Within one org this is refused whatever the flags say, and
			// --share cannot reach it. WAKIL_ORG would survive a second
			// registration but WAKIL_PROVIDER would not, so sessions land
			// under the wrong provider — and a second id naming one account
			// buys no second account and no second quota, which is the only
			// reason sharing exists at all.
			return UserError("configDir " + strconv.Quote(p.ConfigDir) +
				" is already registered to provider " + strconv.Quote(ownerID) +
				" in this same org — one org may name one account once." +
				" Sharing is between different orgs; within one it would only" +
				" duplicate the record, and sessions would land under whichever" +
				" WAKIL_PROVIDER was registered last." +
				" Use a different config dir, or release this one with: wakil provider rm " +
				ownerID + " --org " + ownerOrg)
		case ownerID != "" && !p.Shared:
			return UserError("configDir " + strconv.Quote(p.ConfigDir) +
				" is already registered to provider " + strconv.Quote(ownerID) +
				" in org " + strconv.Quote(ownerOrg) +
				" — that org pins WAKIL_ORG inside the directory, so a plain" +
				" `claude` session started there runs as " + ownerOrg + "." +
				" To use this same account from org " + strconv.Quote(org) +
				" inside Wakil, re-run with --share: Wakil passes each session its" +
				" own org and never reads the pin, so the two do not collide." +
				" Plain Claude Code in that directory stays with " + ownerOrg + "." +
				" Or use a different config dir, or release this one with: wakil provider rm " +
				ownerID + " --org " + ownerOrg)
		case ownerID == "" && p.Shared:
			return UserError("nothing to share: no org has registered configDir " +
				strconv.Quote(p.ConfigDir) + " yet." +
				" Drop --share to register it normally — the first registration is" +
				" the one that pins WAKIL_ORG inside the directory, and later orgs" +
				" share it from there")
		}
	}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS. `TestAddProviderRejectsConfigDirClaimedWithinSameOrg` and
`TestAddProviderRejectsSymlinkToClaimedConfigDir` must still pass unchanged — if the
symlink test now fails, the switch is comparing an unresolved path and
`p.ConfigDir = resolved` above it was skipped.

- [ ] **Step 5: Vet and commit**

```bash
make vet
git add internal/wakilcore/provider.go internal/wakilcore/provider_test.go
git commit -m "Let a config dir be shared across orgs, behind --share

One Claude account could be registered to exactly one org, so an operator
whose account has hit its usage limit could not reach an account with quota
left unless it happened to live in the org they were already in. On this
machine that left the umbrella org with no account at all and no way to be
given one.

The refusal turns out to protect plain Claude Code rather than Invariant 4:
register-provider.sh pins WAKIL_ORG inside the config dir and a \`claude\`
session cannot override it, while every Wakil session launches with
--strict-mcp-config and a generated config carrying its own org. So --share
records an additional binding for Wakil's use and leaves the pin where it is.

Refused within one org whatever the flags say: WAKIL_PROVIDER would collide,
and a second id naming one account buys no second quota.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `--share` on the CLI, and `wakil provider home`

**Files:**
- Modify: `cmd/wakil/providercmd.go:38-48` (verb dispatch), `:66-72` (flags),
  `:92` (success output), and add `runProviderHome` beside `runProviderConfigDir` (`:174`)
- Modify: `cmd/wakil/main.go:97-105` (usage text)
- Create: `cmd/wakil/providercmd_test.go` (it does not exist today — `cmd/wakil/` holds `main_test.go`, `orgcmd_test.go` and `providercredentials_test.go` only)

**Interfaces:**
- Consumes: `Provider.Shared`, `ConfigDirHome` from Tasks 1-2.
- Produces: `wakil provider add <id> … [--share]`; `wakil provider home <id>` printing one
  line on stdout.

- [ ] **Step 1: Write the failing tests**

Create `cmd/wakil/providercmd_test.go`. Match the existing CLI test style in
`cmd/wakil/orgcmd_test.go:121` — it captures stdout and stderr separately and asserts
which stream carried what, because `provider home`'s output is data a script consumes.

```go
func TestProviderAddShareFlagRegistersASharedRecord(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, org := range []string{"initech", "personal"} {
		if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatalf("seed add: exit = %d", code)
	}

	t.Setenv("WAKIL_ORG", "personal")
	var stderr bytes.Buffer
	code := runProviderAdd([]string{
		"work", "--kind", "claude-code", "--config-dir", cfg, "--share",
	}, &stderr)
	if code != 0 {
		t.Fatalf("--share add: exit = %d, stderr = %q", code, stderr.String())
	}
	p, err := wakilcore.LoadProviderFor("personal", "work")
	if err != nil {
		t.Fatal(err)
	}
	if !p.Shared {
		t.Error("--share did not persist Shared=true")
	}
	// The operator must be told the pin did not move, at the moment they
	// create the binding — this is the one limitation of the feature and
	// discovering it later means discovering it as a bug.
	if !strings.Contains(stderr.String(), "initech") {
		t.Errorf("a --share add must name the org that still homes the dir; got %q", stderr.String())
	}
}

func TestProviderHomePrintsTheHomingOrgOnStdout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-shared")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, org := range []string{"initech", "personal"} {
		if err := wakilcore.CreateOrg(org, wakilcore.Org{}); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatal("seed add failed")
	}
	t.Setenv("WAKIL_ORG", "personal")
	if code := runProviderAdd([]string{"work", "--kind", "claude-code", "--config-dir", cfg, "--share"}, io.Discard); code != 0 {
		t.Fatal("share add failed")
	}

	// Asked from the SHARING org, the answer is still the homing one.
	stdout, stderr, code := captureProviderHome(t, []string{"work"})
	if code != 0 {
		t.Fatalf("provider home: exit = %d, stderr = %q", code, stderr)
	}
	if stdout != "initech\n" {
		t.Errorf("provider home stdout = %q; want %q", stdout, "initech\n")
	}
	if stderr != "" {
		t.Errorf("provider home wrote to stderr on success: %q", stderr)
	}
}

func TestProviderHomeOfAnUnsharedProviderIsItsOwnOrg(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := filepath.Join(home, ".claude-initech")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := wakilcore.CreateOrg("initech", wakilcore.Org{}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAKIL_ORG", "initech")
	if code := runProviderAdd([]string{"main", "--kind", "claude-code", "--config-dir", cfg}, io.Discard); code != 0 {
		t.Fatal("seed add failed")
	}
	stdout, _, code := captureProviderHome(t, []string{"main"})
	if code != 0 {
		t.Fatalf("provider home: exit = %d", code)
	}
	if stdout != "initech\n" {
		t.Errorf("provider home stdout = %q; want %q", stdout, "initech\n")
	}
}
```

Add the capture helper, modelled on however `runProviderConfigDir` is already tested — it
writes to `os.Stdout` directly, so the helper swaps that out:

```go
// captureProviderHome runs `provider home` with os.Stdout redirected to a
// pipe. runProviderHome prints to os.Stdout rather than to an injected
// writer because runProviderConfigDir does, and a script consuming either
// one must get the value on stdout and nothing else.
func captureProviderHome(t *testing.T, args []string) (stdout, stderr string, code int) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = w
	var errBuf bytes.Buffer
	code = runProviderHome(args, &errBuf)
	w.Close()
	os.Stdout = saved
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out), errBuf.String(), code
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -E "providercmd_test|runProviderHome"`
Expected: FAIL — `runProviderHome` undefined, and `--share` is rejected as an unknown flag.

- [ ] **Step 3: Add the flag and the verb**

In `cmd/wakil/providercmd.go`, inside `runProviderAdd`'s flag set (after the
`--claude-path` line at `:71`):

```go
	fs.BoolVar(&p.Shared, "share", false,
		"register an account another org already homes (--kind claude-code only)")
```

After the existing success line (`:92`, `added provider %q (kind %s) to org %q`), add:

```go
	if p.Shared {
		homeOrg, homeID, err := wakilcore.ConfigDirHome(p.ConfigDir)
		if err == nil && homeOrg != "" {
			fmt.Fprintf(stderr,
				"\nthis account is shared: %s/%s still pins WAKIL_ORG inside %s, so a plain `claude` session started there runs as %q, not %q.\nInside Wakil it runs as %q, because Wakil passes every session its own org.\n",
				homeOrg, homeID, p.ConfigDir, homeOrg, org, org)
		}
	}
```

Add the verb to the dispatch switch (beside `case "config-dir":` at `:40`):

```go
	case "home":
		return runProviderHome(rest, stderr)
```

And the function, beside `runProviderConfigDir`:

```go
// runProviderHome implements `wakil provider home <id>`.
//
// Prints, on stdout, the org that pinned WAKIL_ORG inside this provider's
// config dir — its own org when the record is not shared, the homing org
// when it is. One line, nothing else, exactly as `provider config-dir`
// does, because scripts/register-provider.sh consumes it with command
// substitution.
func runProviderHome(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	p, err := wakilcore.LoadProviderFor(org, args[0])
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if p.ConfigDir == "" {
		fmt.Fprintln(stderr, message(wakilcore.UserError(
			"provider "+strconv.Quote(args[0])+" has no config dir — only a claude-code provider pins an org inside one")))
		return 2
	}
	homeOrg, _, err := wakilcore.ConfigDirHome(p.ConfigDir)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if homeOrg == "" {
		// Every registered claude-code provider was either the first (and
		// so the home) or was added with --share against an existing home,
		// so this is unreachable through the CLI. It is reachable by hand:
		// delete the homing record's file and its sharers survive as
		// orphans. Say so rather than printing an empty line a script would
		// read as success.
		fmt.Fprintln(stderr, message(wakilcore.UserError(
			"no org pins an org inside "+p.ConfigDir+" — the record that homed it appears to have been removed; re-register it with: wakil provider add <id> --kind claude-code --config-dir "+p.ConfigDir+" --org <org>")))
		return 2
	}
	fmt.Fprintln(os.Stdout, homeOrg)
	return 0
}
```

In `cmd/wakil/main.go`, extend the usage block at `:97`:

```
  wakil provider add <id> --kind <claude-code|codex|local> [--config-dir DIR] [--label LABEL] [--share]
      Register a provider under the current org (--org, or WAKIL_ORG).
      --config-dir is required for --kind claude-code and rejected for
      --kind codex and --kind local, which Wakil does not register for
      you — see the command's own output for what to configure by hand.
      --share registers an account another org already homes. Wakil can
      then run it under this org too; a plain `claude` session in that
      directory still runs as the homing org.

  wakil provider home <id>
      Print the org that pinned WAKIL_ORG inside this provider's config
      dir. One line on stdout.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Vet and commit**

```bash
make vet
git add cmd/wakil/providercmd.go cmd/wakil/main.go cmd/wakil/providercmd_test.go
git commit -m "Expose --share and \`wakil provider home\` on the CLI

--share reaches AddProvider's new branch, and says at the moment of
registration what it does not buy: the homing org keeps the pin, so plain
Claude Code in that directory still runs as that org. Discovering that later
would mean discovering it as a bug.

\`provider home\` prints the homing org on stdout, one line, the way
\`provider config-dir\` already does — register-provider.sh consumes it next.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `register-provider.sh` refuses to steal a pin

**Files:**
- Modify: `scripts/register-provider.sh` — after the `[ -d "$CFG" ] || die …` line
  (~`:217`) and **before** `export CLAUDE_CONFIG_DIR="$CFG"`
- Modify: `scripts/register_provider_test.go:121-166` (`fakeWakil`), `:176-179`
  (`provRecord`), `:303-309` (the provider-line writer)
- Test: `scripts/register_provider_test.go` (append)

**Interfaces:**
- Consumes: `wakil provider home <id> --org <org>` from Task 3.
- Produces: nothing other tasks use.

This script already has a full Go test harness — `newEnv(t)`, `e.run(t, org, provider,
binDir)`, `res.code`, `res.calls`, `res.stderr`, with fake `claude` and `wakil` shims on
`PATH`. Use it. Do **not** write a shell test; `scripts/` is a Go test package and
`make test` already runs it.

- [ ] **Step 1: Teach the fake `wakil` about homes**

Add a `home` field to `provRecord` (`:176`):

```go
// provRecord is one line of the fake provider registry.
//
// home is the org that pinned WAKIL_ORG inside configDir. Empty means
// "this record's own org", which is what every unshared provider is and
// what every fixture predating sharing relies on.
type provRecord struct {
	id, kind, configDir, home string
}
```

In the provider-line writer (`:303-309`), emit it, defaulting to the fixture's own org so
every existing test is unchanged:

```go
	var provLines []string
	for _, p := range e.providers {
		cfg := p.configDir
		if cfg == "" {
			cfg = "-"
		}
		home := p.home
		if home == "" {
			home = e.org
		}
		provLines = append(provLines, fmt.Sprintf("%s %s %s %s", p.id, p.kind, cfg, home))
	}
```

In `fakeWakil` (`:121`), add a `provider home` case before the closing `esac`, and widen
the two existing `read` loops to take the fourth field:

```sh
"provider home")
	id="$3"
	if [ -n "${FAKE_WAKIL_PROVIDERS_FILE:-}" ] && [ -f "$FAKE_WAKIL_PROVIDERS_FILE" ]; then
		while IFS=' ' read -r pid kind cfg home; do
			if [ "$pid" = "$id" ]; then
				if [ -z "$cfg" ] || [ "$cfg" = "-" ]; then
					echo "provider \"$id\" has no config dir -- only a claude-code provider pins an org inside one" >&2
					exit 2
				fi
				printf '%s\n' "$home"
				exit 0
			fi
		done < "$FAKE_WAKIL_PROVIDERS_FILE"
	fi
	echo "no provider \"$id\" registered -- register it with: wakil provider add $id" >&2
	exit 2
	;;
```

Both `"provider list"` and `"provider config-dir"` read three fields today; change each
`read -r` to take a fourth (`home`, ignored there) so the extra column does not land in
`cfg`.

- [ ] **Step 2: Write the failing tests**

Append to `scripts/register_provider_test.go`:

```go
// The script is the only command that writes the pin, so it is the only
// place the one-dir-one-org rule can actually be enforced. AddProvider's
// --share rule is bookkeeping; this is the guard.
func TestRefusesToRegisterAProviderWhoseConfigDirAnotherOrgHomes(t *testing.T) {
	e := newEnv(t)
	e.orgs = append(e.orgs, "personal")
	e.providers = append(e.providers, provRecord{
		id: "shared", kind: "claude-code", configDir: e.configDir, home: "personal",
	})

	res := e.run(t, e.org, "shared", e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	// Nothing registered: the refusal must come before the first
	// `claude mcp add`, because a partial run leaves the other org's pin
	// already overwritten.
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for a shared provider\n%s", len(res.calls), res)
	}
	// The operator's next question is "homed by whom?".
	if !strings.Contains(res.stderr, "personal") {
		t.Fatalf("stderr = %q, want it to name the homing org", res.stderr)
	}
}

// The control. Without it this suite would pass if the script refused
// everything.
func TestStillRegistersTheProviderThatHomesItsOwnConfigDir(t *testing.T) {
	e := newEnv(t)
	e.providers = append(e.providers, provRecord{
		id: "shared", kind: "claude-code", configDir: e.configDir, home: "personal",
	})

	// e.provider ("primary") homes its own dir, so it is unaffected by the
	// presence of a shared record beside it.
	res := e.runDefault(t)
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	if len(res.calls) != len(providerServers) {
		t.Fatalf("registered %d servers, want %d\n%s", len(res.calls), len(providerServers), res)
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test 2>&1 | grep -A 6 TestRefusesToRegisterAProviderWhoseConfigDir`
Expected: FAIL — exit code 0 and five servers registered, because the script does not yet
ask who homes the directory.

- [ ] **Step 4: Add the refusal to the script**

In `scripts/register-provider.sh`, after `[ -d "$CFG" ] || die …` and before
`export CLAUDE_CONFIG_DIR="$CFG"`:

```sh
# Refuse to steal another org's pin.
#
# `claude mcp add -e WAKIL_ORG=$org` below writes the org INTO this
# directory, and a plain `claude` session started there reads it with no
# way to override. So exactly one org may pin a given directory, and this
# is the only command that writes it — AddProvider's --share rule is
# bookkeeping, this is enforcement.
#
# Registering a shared provider here would repoint the homing org's
# headless sessions at this org, silently, and the failure would surface
# far away as a credential lookup in the wrong org. Wakil itself needs no
# registration for a shared account: it passes every session its own org
# and launches with --strict-mcp-config, so it never reads this pin.
HOME_ORG="$(wakil provider home "$provider" --org "$org")" ||
	die "'wakil provider home $provider --org $org' failed — see its message above"
[ -n "$HOME_ORG" ] || die "'wakil provider home $provider --org $org' printed nothing"
if [ "$HOME_ORG" != "$org" ]; then
	die "provider '$provider' in org '$org' shares a config dir that org '$HOME_ORG' homes ($CFG). Registering it here would overwrite '$HOME_ORG''s WAKIL_ORG pin and silently repoint that org's plain \`claude\` sessions. Wakil already runs this account under '$org' without any registration. If you meant to move the pin, release it first: wakil provider rm <id> --org $HOME_ORG"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — including every pre-existing `register_provider_test.go` test. If
`TestExportsProviderConfigDirForClaudeMcpAdd` or `TestProviderIDPrefixDoesNotMatchTheWrongProvider`
now fails, the fake's `read -r` loops were not widened to four fields and the home column
is being parsed as part of `cfg`.

- [ ] **Step 6: Vet and commit**

```bash
make vet
git add scripts/register-provider.sh scripts/register_provider_test.go
git commit -m "Refuse to register a shared provider's servers, naming the org that homes it

This is where the one-dir-one-org rule is actually enforced: \`claude mcp add
-e WAKIL_ORG=\$org\` writes the org into the config dir, and a plain \`claude\`
session there reads it with no way to override. A shared provider's dir is
homed by another org, so registering it here would silently repoint that
org's headless sessions — a failure that would surface far away, as a
credential lookup in the wrong org.

The fake wakil grows a \`provider home\` verb and the fixture registry a fourth
column, defaulting to the record's own org so every existing test is unchanged.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The acceptance runbook, and the operator's migration

**Files:**
- Create: `docs/wakil/shared-accounts-acceptance.md`
- Modify: `docs/wakil/operator-todo.md` (append a section)
- Modify: `docs/wakil/north-star.md` (the §6 decisions list, and §7 open question 13's
  "Related" sentence)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code depends on.

- [ ] **Step 1: Write the runbook**

Create `docs/wakil/shared-accounts-acceptance.md` with a `Status: unwalked` header and
seven checks. Follow `docs/wakil/phase-2c-ii-b-acceptance.md`'s structure exactly: a
§1 scope saying what is and is not under test, a §2 of checks each with its own
*what to do / what must happen / result* table, a §3 recording the commands confirmed
green, a §4 for defects, a §5 result.

The seven checks, each stated as an operator action and an observable outcome:

1. `wakil provider add` **without** `--share`, against a dir another org homes: refused,
   and the message names the owning org, the owning provider, and `--share`.
2. The same command **with** `--share`: accepted, and the output names the org that still
   homes the directory.
3. `--share` against a dir nobody has registered: refused with "nothing to share".
4. `--share` against a dir **this same org** already registered: refused, the message says
   "same org", and does **not** suggest `--share`.
5. `scripts/register-provider.sh <sharing-org> <shared-provider>`: refuses, names the
   homing org, and no server is registered.
6. **In Wakil**, open a window in the sharing org, run a query against a database only
   that org defines, and confirm from the journal that the child saw the sharing org's
   `WAKIL_ORG` — *not* from the window's labels, which is the shortcut 2c-ii-b's D3 punished.
7. **Plain `claude` in the shared directory still runs as the homing org.** This is §3's
   stated limitation; an unwalked limitation is a guess.

Mark checks 6 and 7 as the two that no test in this repository can reach, and say why:
6 crosses a process boundary into a real agent session, and 7 leaves Wakil entirely.

- [ ] **Step 2: Write the operator's migration section**

Append to `docs/wakil/operator-todo.md`, in the style of its existing
"Write credentials" section — commands, then what only the operator can decide:

```markdown
## Shared accounts — give `umbrella` and `initech` the accounts they cannot have today

As of 2026-09-14 this machine reads:

| org | providers |
|---|---|
| `initech` | `main` → `~/.claude-initech` |
| `personal` | `main` → `~/.claude-personal`, `second` → `~/.claude-umbrella` |
| `umbrella` | none |

**The decision only you can make: which org should HOME `~/.claude-umbrella`?**
It is homed to `personal` today by history rather than by intent. Homing it to
`umbrella` means a plain `claude` session in that directory runs as `umbrella`, which
is almost certainly what you want from a directory named for it — but it means
removing `personal/second`, re-running `register-provider.sh` for `umbrella`, and
sharing it back to `personal`.

Nothing below is run by an agent. Every command touches your real accounts.
```

Then both option blocks verbatim. Do not guess which the operator picked — write both.

````markdown
### Option A — keep `personal` as the home of `~/.claude-umbrella`

Nothing is removed; `umbrella` and `initech` gain shared bindings to accounts other
orgs home. Plain `claude` in each directory keeps running as it does today.

```sh
# umbrella gains the enterprise account, shared from personal
wakil provider add main --kind claude-code   --config-dir ~/.claude-umbrella --share --org umbrella

# umbrella also gains the max account, shared from personal
wakil provider add personal --kind claude-code   --config-dir ~/.claude-personal --share --org umbrella

# initech gains the max account too, so an exhausted team account has somewhere to go
wakil provider add personal --kind claude-code   --config-dir ~/.claude-personal --share --org initech
```

No `register-provider.sh` run is needed or permitted for any of these — they are
shared bindings, and the script will now refuse them by design (Task 4).

### Option B — re-home `~/.claude-umbrella` to `umbrella`

A plain `claude` session in `~/.claude-umbrella` starts running as `umbrella`
rather than `personal`. This is the only option that changes existing headless
behaviour, and it is the reason the choice is yours.

```sh
# 1. release the dir from personal
wakil provider rm second --org personal

# 2. home it to umbrella, and pin the org inside it
wakil provider add main --kind claude-code   --config-dir ~/.claude-umbrella --org umbrella
scripts/register-provider.sh umbrella main

# 3. share it back to personal for Wakil's use
wakil provider add second --kind claude-code   --config-dir ~/.claude-umbrella --share --org personal

# 4. as in option A, give umbrella and initech the max account as well
wakil provider add personal --kind claude-code   --config-dir ~/.claude-personal --share --org umbrella
wakil provider add personal --kind claude-code   --config-dir ~/.claude-personal --share --org initech
```

**Check after either option:** `wakil provider list --org umbrella` names an
account, and `wakil provider home main --org umbrella` prints the org you
expect.
````

- [ ] **Step 3: Record the decision in the charter**

In `docs/wakil/north-star.md` §6, add decision 22, **A Claude account is shared across
orgs; an org's credentials are not**, stating: the config dir carries one org's pin for
plain Claude Code and any number of Wakil bindings; the Keychain scheme, `writeGate` and
the cross-org project guard are untouched; *Reverse if:* an operator turns out to want a
genuinely separate account per org, in which case the honest answer is separate config
dirs and no sharing at all.

In §7, extend open question 13's closing "**Related, not the same question**" sentence to
note that provider *sharing* is settled by decision 22 and is not what that question asks.

- [ ] **Step 4: Verify the docs build nothing and commit**

Run: `make test && make vet`
Expected: PASS — no code changed, so this is purely the regression check that Tasks 1-4
are still green with the docs in place.

```bash
git add docs/wakil/shared-accounts-acceptance.md docs/wakil/operator-todo.md docs/wakil/north-star.md
git commit -m "The shared-accounts runbook, the migration, and decision 22

Seven checks, two of which no test in this repository can reach: a Wakil
session under a shared account proving its children see the right WAKIL_ORG,
and a plain \`claude\` session in that directory proving it does not. The
second is the limitation the design states, and an unwalked limitation is a
guess.

The migration is the operator's: it touches real accounts, and which org
homes ~/.claude-umbrella is a decision history made rather than anyone
choosing. Both options are written out.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Not in this plan

- **Anything in the multi-org window design** (`2026-09-14-multi-org-window-design.md`).
  That sub-phase depends on this one and is planned separately.
- **`get_context` reporting `Org` when it errors** — found by the org-switch probe
  (`docs/wakil/org-switch-probe.md` §4) and belonging to the multi-org plan, whose §11.1
  is what it breaks.
- **`MCPClient.start()`'s transport-state reset** — same probe, §2. A real latent bug, and
  moot for both designs; it needs an owner, and it is not this one.
- **Surfacing an account's remaining quota.** The motivation for this work, and entirely
  unaddressed by it: Wakil still discovers an exhausted account by being refused
  mid-turn. Recorded as an open question in the design's §8.
