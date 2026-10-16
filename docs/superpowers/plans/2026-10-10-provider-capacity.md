# Provider capacity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show, for every provider account in the active organisation, how much of its 5-hour and weekly window is left and when each resets — beside ACCOUNT on the home window, in a strip above the Settings accounts table, and in ⌘P's provider rows.

**Architecture:** Claude Code's stream already carries `rate_limit_event`; the Swift harness decodes it, an operator-only action records it through `wakil-ctx` into a per-account file under `~/.wakil/capacity/`, and one read tool (`capacity`) answers every surface and the agent. Codex accounts are read on demand from Codex's own session logs. Nothing is billed and nothing is written into any Claude config dir.

**Tech Stack:** Go (`internal/wakilcore`, `cmd/wakil-ctx`, go-sdk `mcp`), Swift 6 / SwiftUI (`WakilKit`, `WakilApp`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-10-provider-capacity-design.md`

## Global Constraints

- Builds on the WindowModel-split stack; **this branch sits on `yehia-khalil/wm-8-layering`** (Task 0). `WakilKit/Core/` exists only there.
- **No new line in `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt`.** Every new folder link must already be listed or point into `Core/`.
- `Core/` files import Foundation only and reference nothing outside `Core/`.
- Percent shown is percent **left**: `round((1 − utilization) × 100)` for Claude, `round(100 − used_percent)` for Codex.
- **Abstain, never guess:** utilization outside 0…1, used_percent outside 0…100, a missing or non-numeric reset time, or an unknown shape drops that window; no valid 5-hour window → no reading.
- Low = **20% or less left** in a window → §5 amber `#e8b45a`. **Red is never used.**
- Times on the wire and on disk are RFC 3339 UTC with whole seconds (`2026-10-10T17:20:00Z`), never fractional.
- Store: `~/.wakil/capacity/<first 16 hex of sha256(filepath.Clean(configDir))>.json`; a newer `asOf` replaces, an older one is ignored.
- `capacity_record` is **operator-only**; `ctx_capacity` is agent-reachable `.read`.
- No `Co-Authored-By` or "Generated with" lines in commits (operator's rule).
- Copy (verbatim): `not read yet`, `no limits`, `capacity unreadable`, `IN USE`, `as of HH:MM`, `reset HH:MM · not read since`, `5h reset`.

## Review Focus

1. **A shared Claude account seen from two orgs** — both orgs show the same numbers (spec: keyed by config dir). Pinned in Task 1.
2. **A reading recorded late, older than the stored one** (two windows finishing turns out of order) — the newer one must stay. Pinned in Task 1.
3. **Utilization exactly 0 or 1** arrives as a JSON integer and decodes to `JSONValue.integer`, not `.number` — must still parse. Pinned in Task 5.
4. **A provider switch while a turn is in flight** — the event must be recorded against the provider that ran the turn, not the newly chosen one. Pinned in Task 7.
5. **Codex: the newest logs have no `rate_limits` line** (a session that never reached the model) — the reader must fall back to older logs, not report "not read yet". Pinned in Task 2.

---

### Task 0: Put the branch on the stack

**Files:** none.

- [ ] **Step 1: Rebase this branch's three spec commits onto the stack's top**

```bash
cd /Users/operator/orca/workspaces/wakil/jarvis
git rebase --onto yehia-khalil/wm-8-layering origin/main yehia-khalil/provider-capacity
ls app/Sources/WakilKit/Core   # must list Action.swift, JSONValue.swift, ToolCaller.swift …
```

Expected: rebase succeeds (the commits touch only `docs/superpowers/`), and `Core/` exists.

- [ ] **Step 2: Build once to know the baseline is green**

```bash
make build && (cd app && swift build)
```

Expected: both succeed.

---

### Task 1: Go — the capacity store

**Files:**
- Create: `internal/wakilcore/capacity.go`
- Test: `internal/wakilcore/capacity_test.go`

**Interfaces:**
- Produces:
  - `type CapacityWindow struct { PercentLeft int \`json:"percentLeft"\`; ResetsAt string \`json:"resetsAt"\` }`
  - `type CapacityRecord struct { FiveHour CapacityWindow \`json:"fiveHour"\`; SevenDay *CapacityWindow \`json:"sevenDay,omitempty"\`; AsOf string \`json:"asOf"\` }`
  - `type CapacityReading struct { Account, Kind, State string; FiveHour, SevenDay *CapacityWindow; AsOf, Error string }` (json: `account, kind, state, fiveHour?, sevenDay?, asOf?, error?`)
  - `type CapacityListing struct { Readings []CapacityReading \`json:"readings"\` }`
  - `const CapacityRead, CapacityNotRead, CapacityNoLimits, CapacityError = "read", "notRead", "noLimits", "error"`
  - `func RecordCapacity(org, providerID string, r CapacityRecord) error`
  - `func ReadCapacityFor(org string) (CapacityListing, error)`
  - `func ReadCapacityForCurrentOrg() (CapacityListing, error)`
  - `var codexReader = ReadCodexCapacity` (replaced in Task 2's tests; Task 2 defines `ReadCodexCapacity`)

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"os"
	"path/filepath"
	"testing"
)

func win(pct int, at string) CapacityWindow { return CapacityWindow{PercentLeft: pct, ResetsAt: at} }

func TestCapacity_RecordThenRead(t *testing.T) {
	setupHome(t) // org initech, claude-code provider "primary"
	rec := CapacityRecord{FiveHour: win(28, "2026-10-10T17:20:00Z"), SevenDay: &CapacityWindow{PercentLeft: 59, ResetsAt: "2026-10-16T06:00:00Z"}, AsOf: "2026-10-10T16:18:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatalf("RecordCapacity: %v", err)
	}
	got, err := ReadCapacityFor("initech")
	if err != nil {
		t.Fatalf("ReadCapacityFor: %v", err)
	}
	if len(got.Readings) != 1 {
		t.Fatalf("readings = %d, want 1", len(got.Readings))
	}
	r := got.Readings[0]
	if r.Account != "primary" || r.Kind != ProviderKindClaudeCode || r.State != CapacityRead {
		t.Errorf("reading = %+v", r)
	}
	if r.FiveHour == nil || r.FiveHour.PercentLeft != 28 || r.SevenDay == nil || r.SevenDay.PercentLeft != 59 || r.AsOf != "2026-10-10T16:18:00Z" {
		t.Errorf("windows = %+v / %+v asOf %q", r.FiveHour, r.SevenDay, r.AsOf)
	}
}

func TestCapacity_NeverRecordedIsNotRead(t *testing.T) {
	setupHome(t)
	got, _ := ReadCapacityFor("initech")
	if got.Readings[0].State != CapacityNotRead {
		t.Errorf("state = %q, want notRead", got.Readings[0].State)
	}
}

// Review Focus 2.
func TestCapacity_OlderReadingDoesNotReplaceNewer(t *testing.T) {
	setupHome(t)
	newer := CapacityRecord{FiveHour: win(20, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:30:00Z"}
	older := CapacityRecord{FiveHour: win(80, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}
	if err := RecordCapacity("initech", "primary", newer); err != nil {
		t.Fatal(err)
	}
	if err := RecordCapacity("initech", "primary", older); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadCapacityFor("initech")
	if got.Readings[0].FiveHour.PercentLeft != 20 {
		t.Errorf("percentLeft = %d, want the newer 20", got.Readings[0].FiveHour.PercentLeft)
	}
}

// Review Focus 1: Decisions 22 and 32 — the account is the config dir.
func TestCapacity_SharedConfigDirReadsTheSameInBothOrgs(t *testing.T) {
	_, cfg := setupHome(t)
	if err := CreateOrg("personal", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("personal", Provider{ID: "work", Kind: ProviderKindClaudeCode, ConfigDir: cfg, Shared: true}); err != nil {
		t.Fatalf("AddProvider shared: %v", err)
	}
	if err := RecordCapacity("initech", "primary", CapacityRecord{FiveHour: win(41, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCapacityFor("personal")
	if err != nil {
		t.Fatal(err)
	}
	if got.Readings[0].Account != "work" || got.Readings[0].FiveHour == nil || got.Readings[0].FiveHour.PercentLeft != 41 {
		t.Errorf("personal sees %+v, want work at 41%%", got.Readings[0])
	}
}

func TestCapacity_LocalProviderHasNoLimits(t *testing.T) {
	setupHome(t)
	if err := AddProvider("initech", Provider{ID: "ollama", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadCapacityFor("initech")
	var local *CapacityReading
	for i := range got.Readings {
		if got.Readings[i].Account == "ollama" {
			local = &got.Readings[i]
		}
	}
	if local == nil || local.State != CapacityNoLimits {
		t.Errorf("ollama = %+v, want noLimits", local)
	}
}

// Rule 8: one unreadable account shows its own error; the others still draw.
func TestCapacity_CorruptFileIsThatAccountsErrorOnly(t *testing.T) {
	home, cfg := setupHome(t)
	other := filepath.Join(home, ".claude-other")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: other}); err != nil {
		t.Fatal(err)
	}
	if err := RecordCapacity("initech", "second", CapacityRecord{FiveHour: win(50, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	path, _ := capacityPath(cfg)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCapacityFor("initech")
	if err != nil {
		t.Fatalf("one bad file must not fail the call: %v", err)
	}
	states := map[string]string{}
	for _, r := range got.Readings {
		states[r.Account] = r.State
		if r.State == CapacityError && r.Error == "" {
			t.Errorf("%s: error state with no message", r.Account)
		}
	}
	if states["primary"] != CapacityError || states["second"] != CapacityRead {
		t.Errorf("states = %v, want primary error, second read", states)
	}
}

func TestCapacity_RecordRefusesBadInput(t *testing.T) {
	setupHome(t)
	cases := map[string]CapacityRecord{
		"percent over 100": {FiveHour: win(101, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"},
		"percent negative": {FiveHour: win(-1, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"},
		"reset not a time": {FiveHour: win(10, "soon"), AsOf: "2026-10-10T16:00:00Z"},
		"asOf missing":     {FiveHour: win(10, "2026-10-10T17:20:00Z")},
	}
	for name, rec := range cases {
		if err := RecordCapacity("initech", "primary", rec); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := RecordCapacity("initech", "nobody", CapacityRecord{FiveHour: win(10, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err == nil {
		t.Error("unknown provider accepted")
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore -run 'TestCapacity_' -count=1`
Expected: FAIL — `undefined: CapacityRecord` (and the rest).

- [ ] **Step 3: Write the implementation**

```go
package wakilcore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Capacity is how much of a provider account's rate-limit windows is left.
// It is keyed by the ACCOUNT — the config dir (Decision 32) — not by the
// org, because one Claude account may serve several orgs (Decision 22) and
// its limits are the same in each. It is not a credential, so sharing it
// across orgs does not touch Invariant 4's boundary.

const (
	CapacityRead     = "read"
	CapacityNotRead  = "notRead"
	CapacityNoLimits = "noLimits"
	CapacityError    = "error"
)

// CapacityWindow is one window. Times are RFC 3339 UTC strings with whole
// seconds, on the wire and on disk: a Swift ISO 8601 decoder rejects
// fractional seconds, and a string field keeps the MCP schema plain.
type CapacityWindow struct {
	PercentLeft int    `json:"percentLeft"`
	ResetsAt    string `json:"resetsAt"`
}

// CapacityRecord is what record_capacity stores for one account.
type CapacityRecord struct {
	FiveHour CapacityWindow  `json:"fiveHour"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	AsOf     string          `json:"asOf"`
}

type capacityFile struct {
	ConfigDir string `json:"configDir"`
	CapacityRecord
}

// CapacityReading is one provider's row in the `capacity` answer.
type CapacityReading struct {
	Account  string          `json:"account"`
	Kind     string          `json:"kind"`
	State    string          `json:"state"`
	FiveHour *CapacityWindow `json:"fiveHour,omitempty"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	AsOf     string          `json:"asOf,omitempty"`
	Error    string          `json:"error,omitempty"`
}

type CapacityListing struct {
	Readings []CapacityReading `json:"readings"`
}

// codexReader is ReadCodexCapacity, held in a variable so the store's tests
// never scan the real ~/.codex.
var codexReader = func() (CapacityReading, bool, error) { return ReadCodexCapacity(codexSessionsDir()) }

func capacityPath(configDir string) (string, error) {
	dir, err := WakilDir()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(filepath.Clean(configDir)))
	return filepath.Join(dir, "capacity", hex.EncodeToString(sum[:])[:16]+".json"), nil
}

func validWindow(w CapacityWindow) error {
	if w.PercentLeft < 0 || w.PercentLeft > 100 {
		return UserError(fmt.Sprintf("percentLeft %d is outside 0…100", w.PercentLeft))
	}
	if _, err := time.Parse(time.RFC3339, w.ResetsAt); err != nil {
		return UserError("resetsAt " + w.ResetsAt + " is not an RFC 3339 time")
	}
	return nil
}

// RecordCapacity stores a Claude Code account's reading. A reading older
// than the one already stored is ignored, not an error: two windows can
// finish turns on the same account out of order.
func RecordCapacity(org, providerID string, r CapacityRecord) error {
	p, err := LoadProviderFor(org, providerID)
	if err != nil {
		return err
	}
	if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
		return UserError("provider " + providerID + " is not a claude-code account with a config dir")
	}
	if err := validWindow(r.FiveHour); err != nil {
		return err
	}
	if r.SevenDay != nil {
		if err := validWindow(*r.SevenDay); err != nil {
			return err
		}
	}
	asOf, err := time.Parse(time.RFC3339, r.AsOf)
	if err != nil {
		return UserError("asOf " + r.AsOf + " is not an RFC 3339 time")
	}
	path, err := capacityPath(p.ConfigDir)
	if err != nil {
		return err
	}
	if prev, err := readCapacityFile(path); err == nil && prev != nil {
		if prevAt, err := time.Parse(time.RFC3339, prev.AsOf); err == nil && prevAt.After(asOf) {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(capacityFile{ConfigDir: filepath.Clean(p.ConfigDir), CapacityRecord: r}, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// readCapacityFile returns nil, nil for a file that does not exist.
func readCapacityFile(path string) (*capacityFile, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var f capacityFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("capacity file %s is unreadable: %w", path, err)
	}
	return &f, nil
}

// ReadCapacityFor answers every provider of org, in ListProvidersFor's
// order. One account that cannot be read is that row's error; the call
// itself fails only when the org's providers cannot be listed (Rule 8).
func ReadCapacityFor(org string) (CapacityListing, error) {
	providers, err := ListProvidersFor(org)
	if err != nil {
		return CapacityListing{Readings: []CapacityReading{}}, err
	}
	out := make([]CapacityReading, 0, len(providers))
	for _, p := range providers {
		r := CapacityReading{Account: p.ID, Kind: p.Kind, State: CapacityNotRead}
		switch p.Kind {
		case ProviderKindClaudeCode:
			path, err := capacityPath(p.ConfigDir)
			if err != nil {
				r.State, r.Error = CapacityError, err.Error()
				break
			}
			f, err := readCapacityFile(path)
			switch {
			case err != nil:
				r.State, r.Error = CapacityError, err.Error()
			case f != nil:
				r.State, r.FiveHour, r.SevenDay, r.AsOf = CapacityRead, &f.FiveHour, f.SevenDay, f.AsOf
			}
		case ProviderKindCodex:
			got, found, err := codexReader()
			switch {
			case err != nil:
				r.State, r.Error = CapacityError, err.Error()
			case found:
				r.State, r.FiveHour, r.SevenDay, r.AsOf = CapacityRead, got.FiveHour, got.SevenDay, got.AsOf
			}
		case ProviderKindLocal:
			r.State = CapacityNoLimits
		}
		out = append(out, r)
	}
	return CapacityListing{Readings: out}, nil
}

func ReadCapacityForCurrentOrg() (CapacityListing, error) {
	org, err := CurrentOrg()
	if err != nil {
		return CapacityListing{Readings: []CapacityReading{}}, err
	}
	return ReadCapacityFor(org)
}
```

Until Task 2 lands, add this stub at the bottom of `capacity.go` so the package compiles; Task 2 deletes it:

```go
func codexSessionsDir() string { return "" }
func ReadCodexCapacity(string) (CapacityReading, bool, error) { return CapacityReading{}, false, nil }
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore -run 'TestCapacity_' -count=1`
Expected: PASS. If `AddProvider` with `Shared: true` refuses in the shared-dir test, read `provider.go`'s `AddProvider` for the field `--share` sets and use that — do not weaken the test.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/capacity.go internal/wakilcore/capacity_test.go
git commit -m "wakilcore: a capacity store keyed by account"
```

---

### Task 2: Go — the Codex log reader

**Files:**
- Create: `internal/wakilcore/capacity_codex.go`
- Modify: `internal/wakilcore/capacity.go` (delete Task 1's two stub functions)
- Test: `internal/wakilcore/capacity_codex_test.go`

**Interfaces:**
- Consumes: `CapacityReading`, `CapacityWindow` (Task 1).
- Produces: `func ReadCodexCapacity(sessionsDir string) (CapacityReading, bool, error)` — `bool` is "found a reading"; `func codexSessionsDir() string`.

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCodexLog(t *testing.T, dir, day, name string, lines ...string) {
	t.Helper()
	d := filepath.Join(dir, day)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, name), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

const codexLine = `{"timestamp":"2026-10-10T13:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1791660120},"secondary":{"used_percent":36.0,"window_minutes":10080,"resets_at":1792064400}}}}`

func TestCodex_NewestReadingWins(t *testing.T) {
	dir := t.TempDir()
	writeCodexLog(t, dir, "2026/10/09", "rollout-2026-10-09T10-00-00-a.jsonl", strings.Replace(codexLine, `"used_percent":9.0`, `"used_percent":50.0`, 1))
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-b.jsonl", `{"type":"other"}`, codexLine)
	got, found, err := ReadCodexCapacity(dir)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v", found, err)
	}
	if got.FiveHour.PercentLeft != 91 || got.SevenDay == nil || got.SevenDay.PercentLeft != 64 {
		t.Errorf("windows = %+v / %+v, want 91 / 64", got.FiveHour, got.SevenDay)
	}
	if got.FiveHour.ResetsAt != "2026-10-10T19:22:00Z" || got.AsOf != "2026-10-10T13:35:00Z" {
		t.Errorf("resetsAt %q asOf %q", got.FiveHour.ResetsAt, got.AsOf)
	}
}

// Review Focus 5.
func TestCodex_FallsBackPastLogsWithNoRateLimits(t *testing.T) {
	dir := t.TempDir()
	writeCodexLog(t, dir, "2026/10/08", "rollout-2026-10-08T10-00-00-a.jsonl", codexLine)
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T11-00-00-b.jsonl", `{"type":"session_meta"}`)
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T12-00-00-c.jsonl", `{"type":"session_meta"}`)
	_, found, err := ReadCodexCapacity(dir)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v, want the 10/08 reading", found, err)
	}
}

func TestCodex_NoSessionsDirIsNotFound(t *testing.T) {
	_, found, err := ReadCodexCapacity(filepath.Join(t.TempDir(), "absent"))
	if err != nil || found {
		t.Errorf("found=%v err=%v, want not found and no error", found, err)
	}
}

func TestCodex_OutOfRangeAbstains(t *testing.T) {
	dir := t.TempDir()
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", strings.Replace(codexLine, `"used_percent":9.0`, `"used_percent":0.09e4`, 1))
	_, found, _ := ReadCodexCapacity(dir)
	if found {
		t.Error("used_percent 900 produced a reading")
	}
}

func TestCodex_LargeLogIsReadFromItsEnd(t *testing.T) {
	dir := t.TempDir()
	filler := `{"type":"noise","pad":"` + strings.Repeat("x", 1<<20) + `"}`
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", filler, filler, filler, codexLine)
	_, found, err := ReadCodexCapacity(dir)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v", found, err)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore -run 'TestCodex_' -count=1`
Expected: FAIL — the stub returns not found.

- [ ] **Step 3: Write the implementation** (and delete the two stub functions from `capacity.go`)

```go
package wakilcore

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Codex writes its own rate limits into every session log it keeps, as
// `rate_limits {primary, secondary}` on token_count events — the figures its
// /status screen shows. Reading them costs nothing. A codex provider record
// has no config dir, so every codex provider on the machine reads the same
// $CODEX_HOME, which is what the CLI itself does.

const (
	codexLogsToScan = 6
	codexTailBytes  = 256 << 10
)

func codexSessionsDir() string {
	if h := os.Getenv("CODEX_HOME"); h != "" {
		return filepath.Join(h, "sessions")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex", "sessions")
}

// newestCodexLogs walks YYYY/MM/DD newest first; names sort by time.
func newestCodexLogs(dir string, limit int) []string {
	var found []string
	var walk func(d string, depth int)
	walk = func(d string, depth int) {
		entries, err := os.ReadDir(d)
		if err != nil {
			return
		}
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		sort.Sort(sort.Reverse(sort.StringSlice(names)))
		for _, n := range names {
			if len(found) >= limit {
				return
			}
			p := filepath.Join(d, n)
			if depth < 3 {
				walk(p, depth+1)
			} else if strings.HasPrefix(n, "rollout-") && strings.HasSuffix(n, ".jsonl") {
				found = append(found, p)
			}
		}
	}
	walk(dir, 0)
	return found
}

func readTail(path string, n int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	start := info.Size() - n
	if start < 0 {
		start = 0
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return nil, err
	}
	return io.ReadAll(f)
}

func codexWindow(v any) *CapacityWindow {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	used, ok1 := m["used_percent"].(float64)
	reset, ok2 := m["resets_at"].(float64)
	if !ok1 || !ok2 || used < 0 || used > 100 || reset <= 0 {
		return nil
	}
	return &CapacityWindow{
		PercentLeft: int(math.Round(100 - used)),
		ResetsAt:    time.Unix(int64(reset), 0).UTC().Format(time.RFC3339),
	}
}

// findRateLimits looks a few levels down: the field has moved between Codex
// releases (payload.rate_limits, payload.info.rate_limits).
func findRateLimits(v any, depth int) map[string]any {
	m, ok := v.(map[string]any)
	if !ok || depth > 4 {
		return nil
	}
	if rl, ok := m["rate_limits"].(map[string]any); ok {
		return rl
	}
	for _, nested := range m {
		if rl := findRateLimits(nested, depth+1); rl != nil {
			return rl
		}
	}
	return nil
}

// ReadCodexCapacity returns the newest reading in the newest logs. A missing
// sessions dir, or logs with no rate_limits line, is "not found", never an
// error: Codex simply has not reported yet.
func ReadCodexCapacity(sessionsDir string) (CapacityReading, bool, error) {
	for _, path := range newestCodexLogs(sessionsDir, codexLogsToScan) {
		b, err := readTail(path, codexTailBytes)
		if err != nil {
			continue
		}
		lines := bytes.Split(b, []byte("\n"))
		for i := len(lines) - 1; i >= 0; i-- {
			if !bytes.Contains(lines[i], []byte(`"rate_limits"`)) {
				continue
			}
			var ev map[string]any
			if json.Unmarshal(lines[i], &ev) != nil {
				continue // the first line of a tail may be cut mid-way
			}
			rl := findRateLimits(ev, 0)
			five := codexWindow(rl["primary"])
			if five == nil {
				continue
			}
			r := CapacityReading{Kind: ProviderKindCodex, State: CapacityRead, FiveHour: five, SevenDay: codexWindow(rl["secondary"])}
			if ts, ok := ev["timestamp"].(string); ok {
				if at, err := time.Parse(time.RFC3339Nano, ts); err == nil {
					r.AsOf = at.UTC().Truncate(time.Second).Format(time.RFC3339)
				}
			}
			return r, true, nil
		}
	}
	return CapacityReading{}, false, nil
}
```

- [ ] **Step 4: Run all capacity tests**

Run: `go test ./internal/wakilcore -run 'TestCapacity_|TestCodex_' -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/capacity.go internal/wakilcore/capacity_codex.go internal/wakilcore/capacity_codex_test.go
git commit -m "wakilcore: read Codex's capacity from its own session logs"
```

---

### Task 3: Go — the two `wakil-ctx` tools

**Files:**
- Modify: `cmd/wakil-ctx/main.go` (beside `record_session_parent`, ~line 344)
- Modify: `cmd/wakil-ctx/schema_test.go` (the tool list)
- Test: `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Consumes: `RecordCapacity`, `ReadCapacityForCurrentOrg`, `CapacityRecord`, `CapacityListing` (Task 1).
- Produces: MCP tools `record_capacity` (args `{provider, fiveHour{percentLeft,resetsAt}, sevenDay?, asOf}`, result `{}`) and `capacity` (no args, result `{readings:[…]}`).

- [ ] **Step 1: Add both names to `TestOutputSchemasAreObjects`' list**

```go
		// record_capacity and capacity added by provider capacity — the
		// write of one account's reading and the read every surface uses.
		"record_capacity",
		"capacity",
```

- [ ] **Step 2: Write a round-trip test in `main_test.go`**, built the way `TestListProvidersToolReturnsRegisteredProviders` (~line 387) is: `setupProject`, a real config dir, in-memory transports.

```go
func TestCapacityToolsRecordThenReadThroughTheWire(t *testing.T) {
	setupProject(t, `"staging":{"databases":[]}`)
	cfg := filepath.Join(os.Getenv("HOME"), "main-cfg")
	if err := os.MkdirAll(cfg, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := wakilcore.AddProvider("initech",
		wakilcore.Provider{ID: "main", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}

	ctx := context.Background()
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ss, err := newServer().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server Connect: %v", err)
	}
	t.Cleanup(func() { ss.Close() })
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "capacity-test-client", Version: "0.0.0"}, nil).
		Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client Connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })

	rec, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "record_capacity", Arguments: map[string]any{
		"provider": "main",
		"fiveHour": map[string]any{"percentLeft": 28, "resetsAt": "2026-10-10T17:20:00Z"},
		"asOf":     "2026-10-10T16:18:00Z",
	}})
	if err != nil || rec.IsError {
		t.Fatalf("record_capacity: err=%v res=%v", err, rec)
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "capacity"})
	if err != nil || res.IsError {
		t.Fatalf("capacity: err=%v res=%v", err, res)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var got wakilcore.CapacityListing
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode: %v (%s)", err, raw)
	}
	if len(got.Readings) != 1 || got.Readings[0].State != "read" || got.Readings[0].FiveHour.PercentLeft != 28 {
		t.Errorf("capacity = %s", raw)
	}
}
```

- [ ] **Step 3: Run to see it fail**

Run: `go test ./cmd/wakil-ctx -run 'TestOutputSchemasAreObjects|TestCapacityToolsRecordThenRead' -count=1`
Expected: FAIL — unknown tool `record_capacity`.

- [ ] **Step 4: Register the tools**

```go
	type recordCapacityArgs struct {
		Provider string                    `json:"provider"`
		FiveHour wakilcore.CapacityWindow  `json:"fiveHour"`
		SevenDay *wakilcore.CapacityWindow `json:"sevenDay,omitempty"`
		AsOf     string                    `json:"asOf"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "record_capacity", Description: "Record how much of a claude-code provider's 5-hour and weekly windows is left, as the window read it from the agent's own stream. Keyed by the account's config dir, so an account shared by two organisations reads the same in both. A reading older than the stored one is ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recordCapacityArgs) (*mcp.CallToolResult, empty, error) {
			org, err := wakilcore.CurrentOrg()
			if err == nil {
				err = wakilcore.RecordCapacity(org, a.Provider, wakilcore.CapacityRecord{FiveHour: a.FiveHour, SevenDay: a.SevenDay, AsOf: a.AsOf})
			}
			if err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "capacity", Description: "How much of each provider's 5-hour and weekly rate-limit window is left in the active organisation, with each window's reset time and when it was read. state is read, notRead (no session has run on it in Wakil), noLimits (a local model) or error (that account alone could not be read)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, wakilcore.CapacityListing, error) {
			out, err := wakilcore.ReadCapacityForCurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.CapacityListing{Readings: []wakilcore.CapacityReading{}}, nil
			}
			return nil, out, nil
		})
```

If the file declares its arg structs at package level (check how `sessionParentArgs` is declared), move `recordCapacityArgs` there to match.

- [ ] **Step 5: Run the Go suite for both packages**

Run: `go test ./internal/wakilcore ./cmd/wakil-ctx -count=1`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cmd/wakil-ctx/main.go cmd/wakil-ctx/schema_test.go cmd/wakil-ctx/main_test.go
git commit -m "wakil-ctx: record_capacity and capacity"
```

---

### Task 4: Swift Core — the reading and how it is shown

**Files:**
- Create: `app/Sources/WakilKit/Core/CapacityReading.swift`
- Create: `app/Sources/WakilKit/Core/CapacityDisplay.swift`
- Test: `app/Tests/WakilKitTests/CapacityReadingTests.swift`

**Interfaces:**
- Produces:
  - `public struct CapacityWindow: Codable, Sendable, Equatable { public let percentLeft: Int; public let resetsAt: Date }`
  - `public struct CapacityWindows: Sendable, Equatable { public let fiveHour: CapacityWindow; public let sevenDay: CapacityWindow? }`
  - `public struct CapacityReading: Codable, Sendable, Equatable, Identifiable` with `account, kind, state: State, fiveHour?, sevenDay?, asOf: Date?, error: String?`, `id == account`; `enum State: String { read, notRead, noLimits, error }`
  - `public struct CapacityListing: Codable, Sendable, Equatable { public let readings: [CapacityReading] }`
  - `public func decodeCapacityListing(fromResult: JSONValue?) -> CapacityListing?`
  - `public enum CapacityDisplay` with `static let lowThreshold = 20`, `isLow(_:)`, `hasReset(_:now:)`, `resetLabel(_:now:calendar:)`, `asOfLabel(_:calendar:)`, `paletteText(_:now:calendar:) -> (text: String, low: Bool)`
  - `public func capacityRecordParams(provider: String, windows: CapacityWindows, asOf: Date) -> JSONValue`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

private let cairo: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Africa/Cairo")!   // UTC+3 on these dates
    return c
}()
private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Test func decodesTheCapacityToolsAnswer() throws {
    let result: JSONValue = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("read"),
                 "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
                 "asOf": .string("2026-10-10T16:18:00Z")]),
        .object(["account": .string("ollama"), "kind": .string("local"), "state": .string("noLimits")]),
    ])])])
    let listing = try #require(decodeCapacityListing(fromResult: result))
    #expect(listing.readings.map(\.account) == ["main", "ollama"])
    #expect(listing.readings[0].fiveHour?.percentLeft == 28)
    #expect(listing.readings[0].fiveHour?.resetsAt == at("2026-10-10T17:20:00Z"))
    #expect(listing.readings[0].sevenDay == nil)
    #expect(listing.readings[1].state == .noLimits)
}

@Test func lowIsTwentyOrLess() {
    let reset = at("2026-10-10T17:20:00Z")
    #expect(CapacityDisplay.isLow(CapacityWindow(percentLeft: 20, resetsAt: reset)))
    #expect(!CapacityDisplay.isLow(CapacityWindow(percentLeft: 21, resetsAt: reset)))
}

@Test func resetLabelIsTimeTodayAndWeekdayLater() {
    let now = at("2026-10-10T10:00:00Z")
    #expect(CapacityDisplay.resetLabel(at("2026-10-10T17:20:00Z"), now: now, calendar: cairo) == "20:20")
    #expect(CapacityDisplay.resetLabel(at("2026-10-16T06:00:00Z"), now: now, calendar: cairo) == "Fri 09:00")
}

@Test func paletteTextNamesBothWindowsAndFlagsLow() {
    let now = at("2026-10-10T16:30:00Z")
    let r = CapacityReading(account: "work", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 50, resetsAt: at("2026-10-10T18:05:00Z")),
        sevenDay: CapacityWindow(percentLeft: 12, resetsAt: at("2026-10-13T11:00:00Z")),
        asOf: at("2026-10-10T16:18:00Z"), error: nil)
    let shown = CapacityDisplay.paletteText(r, now: now, calendar: cairo)
    #expect(shown.text == "5h 50% · week 12%")
    #expect(shown.low)
}

@Test func paletteTextSaysWhenAWindowHasResetAndWhenItIsOld() {
    let now = at("2026-10-10T19:00:00Z")
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 28, resetsAt: at("2026-10-10T17:20:00Z")),
        sevenDay: CapacityWindow(percentLeft: 59, resetsAt: at("2026-10-16T06:00:00Z")),
        asOf: at("2026-10-10T16:18:00Z"), error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now, calendar: cairo).text == "5h reset · week 59% · as of 19:18")
}

@Test func paletteTextForTheOtherStates() {
    func reading(_ s: CapacityReading.State) -> CapacityReading {
        CapacityReading(account: "x", kind: "claude-code", state: s, fiveHour: nil, sevenDay: nil, asOf: nil, error: "boom")
    }
    let now = Date()
    #expect(CapacityDisplay.paletteText(reading(.notRead), now: now, calendar: cairo).text == "not read yet")
    #expect(CapacityDisplay.paletteText(reading(.noLimits), now: now, calendar: cairo).text == "no limits")
    #expect(CapacityDisplay.paletteText(reading(.error), now: now, calendar: cairo).text == "capacity unreadable")
}

@Test func recordParamsAreWholeSecondUTC() {
    let w = CapacityWindows(fiveHour: CapacityWindow(percentLeft: 28, resetsAt: at("2026-10-10T17:20:00Z")), sevenDay: nil)
    let p = capacityRecordParams(provider: "main", windows: w, asOf: at("2026-10-10T16:18:00Z"))
    #expect(p == .object([
        "provider": .string("main"),
        "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
        "asOf": .string("2026-10-10T16:18:00Z"),
    ]))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter CapacityReadingTests`
Expected: FAIL — `cannot find 'decodeCapacityListing' in scope`.

- [ ] **Step 3: Write `CapacityReading.swift`**

```swift
import Foundation

/// How much of one provider account's rate-limit windows is left, as
/// `wakil-ctx`'s `capacity` tool answers it. Times arrive as RFC 3339 UTC
/// with whole seconds (`internal/wakilcore/capacity.go`).
public struct CapacityWindow: Codable, Sendable, Equatable {
    public let percentLeft: Int
    public let resetsAt: Date
    public init(percentLeft: Int, resetsAt: Date) {
        self.percentLeft = percentLeft
        self.resetsAt = resetsAt
    }
}

/// The pair one `rate_limit_event` carries. The weekly window may be absent;
/// the 5-hour one never is, or there is no reading at all.
public struct CapacityWindows: Sendable, Equatable {
    public let fiveHour: CapacityWindow
    public let sevenDay: CapacityWindow?
    public init(fiveHour: CapacityWindow, sevenDay: CapacityWindow?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct CapacityReading: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case read, notRead, noLimits, error }
    public let account: String
    public let kind: String
    public let state: State
    public let fiveHour: CapacityWindow?
    public let sevenDay: CapacityWindow?
    public let asOf: Date?
    public let error: String?
    public var id: String { account }
    public init(account: String, kind: String, state: State, fiveHour: CapacityWindow?,
                sevenDay: CapacityWindow?, asOf: Date?, error: String?) {
        self.account = account; self.kind = kind; self.state = state
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.asOf = asOf; self.error = error
    }
}

public struct CapacityListing: Codable, Sendable, Equatable {
    public let readings: [CapacityReading]
}

public func decodeCapacityListing(fromResult result: JSONValue?) -> CapacityListing? {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          structured["readings"] != nil,
          let data = try? JSONEncoder().encode(JSONValue.object(structured))
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CapacityListing.self, from: data)
}

private func rfc3339(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
}

private func windowJSON(_ w: CapacityWindow) -> JSONValue {
    .object(["percentLeft": .integer(Int64(w.percentLeft)), "resetsAt": .string(rfc3339(w.resetsAt))])
}

/// `record_capacity`'s arguments for one stream reading.
public func capacityRecordParams(provider: String, windows: CapacityWindows, asOf: Date) -> JSONValue {
    var fields: [String: JSONValue] = [
        "provider": .string(provider),
        "fiveHour": windowJSON(windows.fiveHour),
        "asOf": .string(rfc3339(asOf)),
    ]
    if let week = windows.sevenDay { fields["sevenDay"] = windowJSON(week) }
    return .object(fields)
}
```

- [ ] **Step 4: Write `CapacityDisplay.swift`**

```swift
import Foundation

/// The words and thresholds every capacity surface shares, so the home
/// indicator, the Settings strip and ⌘P cannot disagree.
public enum CapacityDisplay {
    /// §5 amber at this many percent left or fewer. Never red: §5 reserves
    /// red for production, and a low account is not a production hazard.
    public static let lowThreshold = 20

    public static func isLow(_ w: CapacityWindow) -> Bool { w.percentLeft <= lowThreshold }

    public static func hasReset(_ w: CapacityWindow, now: Date) -> Bool { now >= w.resetsAt }

    private static func formatter(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f
    }

    /// `20:20` today, `Fri 09:00` within the week, `16 Oct` beyond.
    public static func resetLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return formatter("HH:mm", calendar).string(from: date) }
        if date.timeIntervalSince(now) < 7 * 86_400 { return formatter("EEE HH:mm", calendar).string(from: date) }
        return formatter("d MMM", calendar).string(from: date)
    }

    public static func asOfLabel(_ date: Date, calendar: Calendar = .current) -> String {
        "as of " + formatter("HH:mm", calendar).string(from: date)
    }

    /// ⌘P's one line. `as of` is added only when the reading is over an hour old.
    public static func paletteText(_ r: CapacityReading, now: Date, calendar: Calendar = .current) -> (text: String, low: Bool) {
        switch r.state {
        case .notRead: return ("not read yet", false)
        case .noLimits: return ("no limits", false)
        case .error: return ("capacity unreadable", false)
        case .read: break
        }
        var parts: [String] = []
        var low = false
        for (name, window) in [("5h", r.fiveHour), ("week", r.sevenDay)] {
            guard let window else { continue }
            if hasReset(window, now: now) {
                parts.append("\(name) reset")
            } else {
                parts.append("\(name) \(window.percentLeft)%")
                low = low || isLow(window)
            }
        }
        if let asOf = r.asOf, now.timeIntervalSince(asOf) > 3_600 {
            parts.append(asOfLabel(asOf, calendar: calendar))
        }
        return (parts.joined(separator: " · "), low)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd app && ../scripts/swift-test.sh --filter CapacityReadingTests`
Expected: PASS. The old-reading test expects `as of 19:18` because 16:18Z is 19:18 in Cairo.

- [ ] **Step 6: Run the layering tests** (both new files are in `Core/`, which may use nothing else)

Run: `cd app && ../scripts/swift-test.sh --filter LayeringTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Core/CapacityReading.swift app/Sources/WakilKit/Core/CapacityDisplay.swift app/Tests/WakilKitTests/CapacityReadingTests.swift
git commit -m "WakilKit Core: a capacity reading and the words every surface shows it in"
```

---

### Task 5: Swift Harness — decode `rate_limit_event`

**Files:**
- Modify: `app/Sources/WakilKit/Harness/StreamJSON.swift` (`HarnessEvent`, `decodeFrame`)
- Modify: `app/Sources/WakilKit/App/ThoughtRow.swift:49` (switch)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`debugLogIfEnabled`'s switch, ~line 6420)
- Modify: `app/Tests/WakilKitTests/StreamJSONTests.swift` (`tag(_:)`, the two fixture sequences at lines ~42 and ~99, the unknown-types test at ~213–227)
- Test: `app/Tests/WakilKitTests/StreamJSONTests.swift`

**Interfaces:**
- Consumes: `CapacityWindow`, `CapacityWindows` (Task 4).
- Produces: `case rateLimit(CapacityWindows)` on `HarnessEvent`; `func decodeRateLimit(_ frame: [String: JSONValue]) -> CapacityWindows?` (internal).

- [ ] **Step 1: Write the failing tests** (append to `StreamJSONTests.swift`)

```swift
// MARK: - rate_limit_event

private func rateLine(_ fiveHourUtil: String, _ sevenDay: String = #","seven_day":{"utilization":0.41,"resetsAt":1788854400}"#) -> Data {
    Data(#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":\#(fiveHourUtil),"resetsAt":1788818400}\#(sevenDay)}}}"#.utf8)
}

@Test func rateLimitEventDecodesBothWindowsAsPercentLeft() throws {
    let events = try decodeHarnessEvents(rateLine("0.01"))
    guard case .rateLimit(let w)? = events.first else { Issue.record("got \(events)"); return }
    #expect(w.fiveHour.percentLeft == 99)
    #expect(w.fiveHour.resetsAt == Date(timeIntervalSince1970: 1788818400))
    #expect(w.sevenDay?.percentLeft == 59)
}

// Review Focus 3: 0 and 1 arrive as JSON integers.
@Test func rateLimitUtilizationZeroAndOneDecode() throws {
    for (util, left) in [("0", 100), ("1", 0)] {
        let events = try decodeHarnessEvents(rateLine(util))
        guard case .rateLimit(let w)? = events.first else { Issue.record("\(util): \(events)"); continue }
        #expect(w.fiveHour.percentLeft == left)
    }
}

@Test func rateLimitWithABadFiveHourWindowStaysUnknown() throws {
    for bad in ["1.3", "-0.1", #""half""#] {
        let events = try decodeHarnessEvents(rateLine(bad))
        #expect(events == [.unknown(type: "rate_limit_event")], "utilization \(bad)")
    }
}

@Test func rateLimitWithABadWeekKeepsTheFiveHourWindow() throws {
    let events = try decodeHarnessEvents(rateLine("0.5", #","seven_day":{"utilization":7,"resetsAt":1788854400}"#))
    guard case .rateLimit(let w)? = events.first else { Issue.record("got \(events)"); return }
    #expect(w.fiveHour.percentLeft == 50)
    #expect(w.sevenDay == nil)
}

@Test func aBareRateLimitEventStaysUnknown() throws {
    #expect(try decodeHarnessEvents(Data(#"{"type":"rate_limit_event"}"#.utf8)) == [.unknown(type: "rate_limit_event")])
}
```

- [ ] **Step 2: Run to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter StreamJSONTests`
Expected: FAIL to compile — `type 'HarnessEvent' has no member 'rateLimit'`.

- [ ] **Step 3: Add the case and the decoder in `StreamJSON.swift`**

In `HarnessEvent`, after `case result(...)`:

```swift
    /// A `rate_limit_event` whose `rate_limit_info.unifiedWindows` carried a
    /// usable 5-hour window. Every other field of the frame dies here. A frame
    /// without one stays `.unknown(type: "rate_limit_event")` — abstain, never
    /// guess (provider capacity spec).
    case rateLimit(CapacityWindows)
```

In `decodeFrame`'s switch, before `default:`:

```swift
    case "rate_limit_event":
        if let windows = decodeRateLimit(frame) { return [.rateLimit(windows)] }
```

At the end of the file:

```swift
func decodeRateLimit(_ frame: [String: JSONValue]) -> CapacityWindows? {
    guard case .object(let info)? = frame["rate_limit_info"],
          case .object(let windows)? = info["unifiedWindows"],
          let five = capacityWindow(windows["five_hour"])
    else { return nil }
    return CapacityWindows(fiveHour: five, sevenDay: capacityWindow(windows["seven_day"]))
}

private func capacityWindow(_ value: JSONValue?) -> CapacityWindow? {
    guard case .object(let w)? = value else { return nil }
    let utilization: Double
    switch w["utilization"] {
    case .number(let d)?: utilization = d
    case .integer(let i)?: utilization = Double(i)
    default: return nil
    }
    let resets: Double
    switch w["resetsAt"] {
    case .integer(let i)?: resets = Double(i)
    case .number(let d)?: resets = d
    default: return nil
    }
    guard (0...1).contains(utilization), resets > 0 else { return nil }
    return CapacityWindow(percentLeft: Int(((1 - utilization) * 100).rounded()),
                          resetsAt: Date(timeIntervalSince1970: resets))
}
```

- [ ] **Step 4: Update the exhaustive switches**

`ThoughtRow.swift`: `case .unknown, .rateLimit: return nil` — capacity is not work the thread describes.

`WindowModel.debugLogIfEnabled`:

```swift
        case .rateLimit(let w):
            line = "rateLimit fiveHourLeft=\(w.fiveHour.percentLeft) sevenDayLeft=\(w.sevenDay.map { String($0.percentLeft) } ?? "-")"
```

`StreamJSONTests.tag(_:)`: `case .rateLimit: return "rateLimit"`.

- [ ] **Step 5: Update the fixture sequences**

The recorded fixtures carry the real payload, so the two pinned sequences (lines ~42 and ~99) change `"unknown(rate_limit_event)"` to `"rateLimit"`. In the unknown-types test (~213–227), `rate_limit_event` leaves both sets: `["system", "stream_event"]` for basic-turn and `["system"]` for tool-call, and delete the `basicTags.filter { $0 == "rate_limit_event" }.count == 1` line. Leave `ClaudeCodeCLIHarnessTests.swift:441` alone: its `{"type":"rate_limit_event"}` has no windows and still decodes to `.unknown`.

- [ ] **Step 6: Run the stream, harness and thought-row tests**

Run: `cd app && ../scripts/swift-test.sh --filter 'StreamJSONTests|ClaudeCodeCLIHarnessTests|WindowModelTests'`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/Harness/StreamJSON.swift app/Sources/WakilKit/App/ThoughtRow.swift app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/StreamJSONTests.swift
git commit -m "StreamJSON: rate_limit_event becomes a capacity reading"
```

---

### Task 6: Swift Registry — `capacity_record` and `ctx_capacity`

**Files:**
- Create: `app/Sources/WakilKit/Registry/CapacityActions.swift`
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:2568` (`private func callChecked` → `func callChecked`, internal)
- Modify: `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (`operatorOnlyActions`, `operatorOnlyDenialMessage`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift` (after `registerGitActions`, ~line 345)
- Test: `app/Tests/WakilKitTests/CapacityActionsTests.swift`

**Interfaces:**
- Consumes: `ToolCaller`, `ActionRegistry`, `Action`, `callChecked` (made internal here), `MCPClient.readReplyTimeout`.
- Produces: `public func registerCapacityActions(into registry: ActionRegistry, context: (any ToolCaller)?) async`; actions `capacity_record` (`.control`, `.operatorOnly`, params = `capacityRecordParams` shape) → tool `record_capacity`; `ctx_capacity` (`.read`, `.agentReachable`, no params) → tool `capacity`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

private actor CapacityCaller: ToolCaller {
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        calls.append((name, arguments))
        return .object(["structuredContent": .object(["readings": .array([])])])
    }
    func recorded() -> [(tool: String, arguments: JSONValue)] { calls }
}

private func capacityRegistry() async throws -> (ActionRegistry, CapacityCaller) {
    let caller = CapacityCaller()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let registry = ActionRegistry(journalDirectory: dir, sessionId: "capacity")
    await registerCapacityActions(into: registry, context: caller)
    return (registry, caller)
}

@Test func capacityRecordSendsTheReadingToRecordCapacity() async throws {
    let (registry, caller) = try await capacityRegistry()
    let params: JSONValue = .object(["provider": .string("main"),
        "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
        "asOf": .string("2026-10-10T16:18:00Z")])
    _ = try await registry.dispatch(name: "capacity_record", params: params, origin: .ui,
                                    environment: "local", confirmation: nil)
    let calls = await caller.recorded()
    #expect(calls.map(\.tool) == ["record_capacity"])
    #expect(calls.first?.arguments == params)
}

@Test func ctxCapacityReadsTheCapacityTool() async throws {
    let (registry, caller) = try await capacityRegistry()
    _ = try await registry.dispatch(name: "ctx_capacity", params: .object([:]), origin: .agent,
                                    environment: "local", confirmation: nil)
    #expect(await caller.recorded().map(\.tool) == ["capacity"])
}

@Test func theAgentCannotRecordAReading() {
    #expect(operatorOnlyActions.contains("capacity_record"))
    #expect(!operatorOnlyActions.contains("ctx_capacity"))
}
```

If `ActionRegistry`'s initialiser or `scratch()` helper differs from the above, copy the construction used in `OrganisationEditTests.swift:42` exactly.

- [ ] **Step 2: Run to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter CapacityActionsTests`
Expected: FAIL to compile — `cannot find 'registerCapacityActions'`.

- [ ] **Step 3: Make `callChecked` internal**

In `StandardActions.swift` change `private func callChecked(` to `func callChecked(`.

- [ ] **Step 4: Write `CapacityActions.swift`**

```swift
import Foundation

/// Provider capacity's two actions. Recording is operator-only — the agent
/// must not be able to forge a reading the operator chooses accounts by —
/// and goes through the registry rather than straight to `wakil-ctx`
/// because actions are the only mutation path (Invariant 2), as
/// `session_record_parent` already does. Reading is agent-reachable: "which
/// account has room?" is a fair question for the agent to answer.
public func registerCapacityActions(into registry: ActionRegistry, context: (any ToolCaller)?) async {
    await registry.register(Action(
        name: "capacity_record",
        description: "Record how much of a claude-code account's 5-hour and weekly windows is left, "
            + "as read from the agent's own stream.",
        kind: .control,
        audience: .operatorOnly,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "provider": .object(["type": .string("string")]),
                "fiveHour": .object(["type": .string("object")]),
                "sevenDay": .object(["type": .string("object")]),
                "asOf": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("provider"), .string("fiveHour"), .string("asOf")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "capacity_record", role: "context")
            }
            return try await callChecked(context, tool: "record_capacity", arguments: params,
                                         action: "capacity_record", timeout: MCPClient.readReplyTimeout)
        }
    ))

    await registry.register(Action(
        name: "ctx_capacity",
        description: "How much of each provider account's 5-hour and weekly rate-limit window is left "
            + "in the active organisation, with reset times and when each was read.",
        kind: .read,
        audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object([:])]),
        handler: { _ in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_capacity", role: "context")
            }
            return try await callChecked(context, tool: "capacity", arguments: .object([:]),
                                         action: "ctx_capacity", timeout: MCPClient.readReplyTimeout)
        }
    ))
}
```

- [ ] **Step 5: Classify it in `PermissionPrompt.swift`**

Add `"capacity_record",` to `operatorOnlyActions` with a one-line comment (`// provider capacity: the agent may not forge a reading the operator chooses accounts by.`), and in `operatorOnlyDenialMessage` add, before `default:`:

```swift
    case "capacity_record":
        return "\(toolName): readings are recorded from the agent's own stream, not supplied by the "
            + "agent. Read them with ctx_capacity."
```

- [ ] **Step 6: Wire it in `AppWiring.swift`** after `registerGitActions(...)`:

```swift
        // Provider capacity: the record path and the one read every surface uses.
        await registerCapacityActions(into: registry, context: contextClient)
```

- [ ] **Step 7: Run the tests**

Run: `cd app && ../scripts/swift-test.sh --filter 'CapacityActionsTests|ActionClassificationTests|LayeringTests'`
Expected: PASS. `Registry -> MCP` (for `MCPClient.readReplyTimeout`) is already in `layering-allowed.txt`.

- [ ] **Step 8: Commit**

```bash
git add app/Sources/WakilKit/Registry/CapacityActions.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/MCP/PermissionPrompt.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/CapacityActionsTests.swift
git commit -m "Registry: capacity_record (operator-only) and ctx_capacity"
```

---

### Task 7: Swift App — `CapacityFeed`, and the ⌘P subtitle

**Files:**
- Create: `app/Sources/WakilKit/App/CapacityFeed.swift`
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (a `capacity` property built in `init` beside `mirror` ~line 822; the event pump ~line 4848; `refreshSettings` ~line 2345; `providerPaletteItems` ~line 4330)
- Modify: `app/Sources/WakilKit/App/PaletteItems.swift` (`providerItems(from:running:)` gains `capacity:`)
- Modify: `app/Sources/WakilKit/Command/PaletteItem.swift` (`caution: Bool = false`)
- Test: `app/Tests/WakilKitTests/CapacityFeedTests.swift`

**Interfaces:**
- Consumes: `CapacityWindows`, `CapacityReading`, `decodeCapacityListing`, `capacityRecordParams`, `CapacityDisplay.paletteText` (Task 4); actions `capacity_record`, `ctx_capacity` (Task 6); `HarnessEvent.rateLimit` (Task 5).
- Produces:
  - `@MainActor @Observable public final class CapacityFeed` with `public private(set) var readings: [CapacityReading]`, `public private(set) var failure: String?`, `public func reading(for account: String) -> CapacityReading?`, `func receive(_ windows: CapacityWindows, provider: String) async`, `public func refresh() async`
  - `public init(now: @escaping () -> Date = Date.init)` and `func attach(dispatch: @escaping @MainActor (String, JSONValue) async throws -> JSONValue)` — the model attaches its registry at the end of `init`, when `self` exists
  - `WindowModel.receiveForTesting(_ event: HarnessEvent, provider: String? = nil) async` — `provider` defaults to `providerId`
  - `WindowModel.capacity: CapacityFeed` (public, read-only)
  - `PaletteItem.caution: Bool`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import WakilKit

@MainActor
private final class Dispatches {
    var calls: [(String, JSONValue)] = []
    var listing: JSONValue = .object(["structuredContent": .object(["readings": .array([])])])
    func dispatch(_ name: String, _ params: JSONValue) async throws -> JSONValue {
        calls.append((name, params))
        return name == "ctx_capacity" ? listing : .object([:])
    }
}

private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-10T16:18:00Z")!
private let windows = CapacityWindows(
    fiveHour: CapacityWindow(percentLeft: 28, resetsAt: ISO8601DateFormatter().date(from: "2026-10-10T17:20:00Z")!),
    sevenDay: nil)

@MainActor @Test func aStreamReadingIsRecordedThenReRead() async {
    let d = Dispatches()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.receive(windows, provider: "main")
    #expect(d.calls.map(\.0) == ["capacity_record", "ctx_capacity"])
    #expect(d.calls[0].1 == capacityRecordParams(provider: "main", windows: windows, asOf: fixedNow))
}

@MainActor @Test func noProviderMeansNothingIsRecorded() async {
    let d = Dispatches()
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.receive(windows, provider: "")
    #expect(d.calls.isEmpty)
}

@MainActor @Test func refreshKeepsTheLastReadingsWhenTheReadFails() async {
    let d = Dispatches()
    d.listing = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("notRead")])])])])
    let feed = CapacityFeed(now: { fixedNow })
    feed.attach(dispatch: d.dispatch)
    await feed.refresh()
    #expect(feed.readings.map(\.account) == ["main"])
    d.listing = .string("garbage")
    await feed.refresh()
    #expect(feed.readings.map(\.account) == ["main"])   // Rule 8: last readings stay
    #expect(feed.failure != nil)
}

@Test func providerRowsCarryTheCapacitySubtitleAndCaution() {
    let rows: [JSONValue] = [.object(["id": .string("work"), "kind": .string("claude-code")])]
    let low = CapacityReading(account: "work", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 50, resetsAt: fixedNow.addingTimeInterval(3_600)),
        sevenDay: CapacityWindow(percentLeft: 12, resetsAt: fixedNow.addingTimeInterval(86_400 * 3)),
        asOf: fixedNow, error: nil)
    let items = WindowModel.providerItems(from: rows, running: "", capacity: [low], now: fixedNow)
    #expect(items.first?.subtitle == "account · claude-code · 5h 50% · week 12%")
    #expect(items.first?.caution == true)
}
```

Review Focus 4 (switch mid-turn): the pump records against the provider captured when the pump **started** (Step 4), and a superseded pump's events are already dropped by the `eventPumpGeneration` guard. This test pins that the model records against the provider it is handed, never against `providerId` at the moment the event lands. Add it to `CapacityFeedTests.swift`:

```swift
@MainActor @Test func aRateLimitIsRecordedAgainstThePumpsProvider() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let d = Dispatches()
    model.capacity.attach(dispatch: d.dispatch)
    // The pump started under "main"; the window has since switched (providerId is not "main").
    #expect(model.providerId != "main")
    await model.receiveForTesting(.rateLimit(windows), provider: "main")
    guard case .object(let params)? = d.calls.first(where: { $0.0 == "capacity_record" })?.1 else {
        Issue.record("nothing recorded: \(d.calls.map(\.0))"); return
    }
    #expect(params["provider"] == .string("main"))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `cd app && ../scripts/swift-test.sh --filter 'CapacityFeedTests'`
Expected: FAIL to compile — `cannot find 'CapacityFeed'`.

- [ ] **Step 3: Write `CapacityFeed.swift`**

```swift
import Foundation
import Observation

/// The window's capacity readings: records what the stream reports, and
/// holds the latest `ctx_capacity` answer for the three surfaces. Extracted
/// from `WindowModel` the way `GitRootWatcher` and `TerminalMirrorFeed` were;
/// the model only owns it and forwards events.
@MainActor @Observable
public final class CapacityFeed {
    public private(set) var readings: [CapacityReading] = []
    public private(set) var failure: String?

    @ObservationIgnored private var dispatch: (@MainActor (String, JSONValue) async throws -> JSONValue)?
    @ObservationIgnored private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The registry route. Attached by `WindowModel` at the end of its
    /// `init`, because the closure needs `self`; until then nothing is sent.
    func attach(dispatch: @escaping @MainActor (String, JSONValue) async throws -> JSONValue) {
        self.dispatch = dispatch
    }

    public func reading(for account: String) -> CapacityReading? {
        readings.first { $0.account == account }
    }

    /// One stream reading for `provider`, the account the producing session
    /// ran under. An empty provider (none chosen yet) records nothing.
    func receive(_ windows: CapacityWindows, provider: String) async {
        guard !provider.isEmpty, let dispatch else { return }
        _ = try? await dispatch("capacity_record",
                                capacityRecordParams(provider: provider, windows: windows, asOf: now()))
        await refresh()
    }

    /// Re-reads every provider. A failed read keeps the last readings on
    /// screen with their own "as of", and says why (Rule 8).
    public func refresh() async {
        guard let dispatch else { return }
        do {
            let result = try await dispatch("ctx_capacity", .object([:]))
            guard let listing = decodeCapacityListing(fromResult: result) else {
                failure = "capacity could not be read: the reply was not a capacity listing"
                return
            }
            readings = listing.readings
            failure = nil
        } catch {
            failure = "capacity could not be read: \(error)"
        }
    }
}
```

- [ ] **Step 4: Own it from `WindowModel`**

Beside `private let mirror: TerminalMirrorFeed` add:

```swift
    /// Provider capacity — see `CapacityFeed`.
    public let capacity: CapacityFeed
```

In `init`, after `self.mirror = TerminalMirrorFeed(...)`: `self.capacity = CapacityFeed()`. As the **last** statement of `init`:

```swift
        capacity.attach { [weak self] name, params in
            guard let self else { return .null }
            return try await self.registry.dispatch(name: name, params: params, origin: .ui,
                                                    environment: self.environment, confirmation: nil)
        }
```

Route pumped events through one helper so the test path and the live path are the same code. Change `receiveForTesting` to:

```swift
    func receiveForTesting(_ event: HarnessEvent, provider: String? = nil) async {
        append(event)
        await mirror.pump(event)
        await recordCapacity(event, provider: provider ?? providerId)
    }

    private func recordCapacity(_ event: HarnessEvent, provider: String) async {
        if case .rateLimit(let windows) = event {
            await capacity.receive(windows, provider: provider)
        }
    }
```

In `startEventPump`, capture the provider when the pump starts, beside `let generation = eventPumpGeneration`:

```swift
        let pumpProvider = providerId
```

and in the loop, after `self.append(event)`:

```swift
                await self.recordCapacity(event, provider: pumpProvider)
```

In `refreshSettings()`, after the `ctx_list_accounts` read: `await capacity.refresh()`. In `providerPaletteItems` (~line 4330), before building items: `await capacity.refresh()`, then pass `capacity: capacity.readings, now: Date()`.

- [ ] **Step 5: The ⌘P subtitle**

`PaletteItem.swift`: add `public let caution: Bool` and an init parameter `caution: Bool = false` (existing call sites keep compiling).

`providerItems(from:running:)` becomes `providerItems(from rows: [JSONValue], running: String, capacity: [CapacityReading] = [], now: Date = Date())`; after the `running` suffix:

```swift
            var caution = false
            if let reading = capacity.first(where: { $0.account == id }) {
                let shown = CapacityDisplay.paletteText(reading, now: now)
                if !shown.text.isEmpty { subtitle += " \u{00b7} \(shown.text)" }
                caution = shown.low
            }
```

and pass `caution: caution` to `PaletteItem(...)`. Keep `WindowModel.providerItems` forwarding to `PaletteItems.providerItems` with the new parameters.

- [ ] **Step 6: Run the tests**

Run: `cd app && ../scripts/swift-test.sh --filter 'CapacityFeedTests|WindowModelTests|PaletteItemsTests|LayeringTests'`
Expected: PASS. `App -> Registry`, `App -> Command` and `App -> Harness` are already allowed.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilKit/App/CapacityFeed.swift app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/App/PaletteItems.swift app/Sources/WakilKit/Command/PaletteItem.swift app/Tests/WakilKitTests/CapacityFeedTests.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "CapacityFeed: record stream readings and show them in ⌘P"
```

---

### Task 8: WakilApp — the indicator, the hover card and the Settings strip

`WakilApp` has no test target; this task is verified by building and by the e2e auditor afterwards.

**Files:**
- Create: `app/Sources/WakilApp/CapacityRows.swift`
- Create: `app/Sources/WakilApp/CapacityIndicator.swift`
- Modify: `app/Sources/WakilApp/WakilWindow.swift:229` (`accountIndicator`) and `:378` (its call site)
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (a `capacity: [CapacityReading]` input; the strip just above `accountTableHeader()` ~line 777)
- Modify: `app/Sources/WakilApp/Canvas.swift:411` (pass `capacity: model.capacity.readings`)
- Modify: `app/Sources/WakilApp/Palettes.swift:52` (subtitle amber when `item.caution`)

**Interfaces:**
- Consumes: `CapacityReading`, `CapacityWindow`, `CapacityDisplay` (Task 4); `WindowModel.capacity` (Task 7); `PaletteItem.caution` (Task 7).
- Produces: `struct CapacityRows: View` (`init(readings: [CapacityReading], inUse: String, now: Date)`), `struct CapacityHairlines: View` (`init(reading: CapacityReading?)`), `struct CapacityHoverCard: View`.

- [ ] **Step 1: `CapacityRows.swift`** — the rows the hover card and the strip share

```swift
import SwiftUI
import WakilKit

private let coolWhite = Color(red: 0.910, green: 0.925, blue: 0.965)          // #e8ecf6
private let violet = Color(red: 0.486, green: 0.361, blue: 1.0)                // #7c5cff
private let amber = Color(red: 0.910, green: 0.706, blue: 0.353)               // #e8b45a, §5 caution

/// One account: name, then a 5H and a WEEK line — bar, percent left, reset.
/// Bars show what is left; amber at 20% or less; never red.
struct CapacityRows: View {
    let readings: [CapacityReading]
    let inUse: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(readings) { reading in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(reading.account).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.92))
                        if reading.account == inUse {
                            Text("IN USE").font(.system(size: 8, weight: .medium)).tracking(1.4)
                                .foregroundStyle(violet.opacity(0.9))
                        }
                    }
                    switch reading.state {
                    case .read:
                        if let w = reading.fiveHour { line("5H", w) }
                        if let w = reading.sevenDay { line("WEEK", w) }
                        if let asOf = reading.asOf {
                            Text(CapacityDisplay.asOfLabel(asOf)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(coolWhite.opacity(0.3))
                        }
                    case .notRead: note("not read yet")
                    case .noLimits: note("no limits")
                    case .error: note(reading.error ?? "capacity unreadable", tone: amber)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("capacity.row.\(reading.account)")
            }
        }
    }

    private func line(_ name: String, _ w: CapacityWindow) -> some View {
        let reset = CapacityDisplay.hasReset(w, now: now)
        let tone = (!reset && CapacityDisplay.isLow(w)) ? amber : coolWhite.opacity(0.72)
        return HStack(spacing: 8) {
            Text(name).frame(width: 34, alignment: .leading).foregroundStyle(coolWhite.opacity(0.38))
            ZStack(alignment: .leading) {
                Capsule().fill(coolWhite.opacity(0.08))
                if !reset {
                    GeometryReader { g in
                        Capsule().fill(CapacityDisplay.isLow(w) ? amber : violet)
                            .frame(width: g.size.width * CGFloat(w.percentLeft) / 100)
                    }
                }
            }
            .frame(width: 96, height: 3)
            Text(reset ? "reset \(CapacityDisplay.resetLabel(w.resetsAt, now: now)) · not read since"
                       : "\(w.percentLeft)% · \(CapacityDisplay.resetLabel(w.resetsAt, now: now))")
                .foregroundStyle(tone)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private func note(_ text: String, tone: Color = coolWhite.opacity(0.55)) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 2: `CapacityIndicator.swift`** — hairlines (design A) and the hover card

```swift
import SwiftUI
import WakilKit

private let violet = Color(red: 0.486, green: 0.361, blue: 1.0)
private let amber = Color(red: 0.910, green: 0.706, blue: 0.353)

/// Two 2-pt bars, 44 pt wide: 5 hours on top, the week below. Nothing is
/// drawn for a reading that is not `.read`.
struct CapacityHairlines: View {
    let reading: CapacityReading?
    let now: Date

    var body: some View {
        if let reading, reading.state == .read {
            VStack(spacing: 3) {
                bar(reading.fiveHour)
                bar(reading.sevenDay)
            }
            .frame(width: 44)
            .accessibilityElement()
            .accessibilityLabel(CapacityDisplay.paletteText(reading, now: now).text)
            .accessibilityIdentifier("capacity.hairlines")
        }
    }

    @ViewBuilder private func bar(_ w: CapacityWindow?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(violet.opacity(0.18))
            if let w {
                if CapacityDisplay.hasReset(w, now: now) {
                    Capsule().strokeBorder(violet.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                } else {
                    GeometryReader { g in
                        Capsule().fill(CapacityDisplay.isLow(w) ? amber : violet.opacity(0.85))
                            .frame(width: g.size.width * CGFloat(w.percentLeft) / 100)
                    }
                }
            }
        }
        .frame(height: 2)
    }
}

/// The card every capacity indicator opens: every provider in the org.
struct CapacityHoverCard: View {
    let organisation: String
    let readings: [CapacityReading]
    let inUse: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CAPACITY · \(organisation.uppercased())")
                Spacer()
                Text("LEFT")
            }
            .font(.system(size: 8.5, weight: .medium)).tracking(1.6)
            .foregroundStyle(Color.white.opacity(0.5))
            CapacityRows(readings: readings, inUse: inUse, now: now)
        }
        .padding(12)
        .frame(width: 272)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.055, green: 0.063, blue: 0.098)))   // §2 slab #0e1019
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .accessibilityIdentifier("capacity.card")
    }
}
```

- [ ] **Step 3: Put them beside ACCOUNT in `WakilWindow.swift`**

Change `accountIndicator(_ label: String)` to take the model's capacity:

```swift
    @State private var capacityCardOpen = false

    private func accountIndicator(_ label: String, model: WindowModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // … the existing "ACCOUNT" and label Texts, unchanged …
            CapacityHairlines(reading: model.capacity.reading(for: model.providerId), now: Date())
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
        }
        .contentShape(Rectangle())
        .onHover { capacityCardOpen = $0 }
        .focusable()
        .onFocusChange { capacityCardOpen = $0 }
        .overlay(alignment: .bottomTrailing) {
            if capacityCardOpen {
                CapacityHoverCard(organisation: model.organization, readings: model.capacity.readings,
                                  inUse: model.providerId, now: Date())
                    .offset(y: -28)
                    .allowsHitTesting(false)          // Rule 6: it takes no focus and moves nothing
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: capacityCardOpen)   // §7: 250 ms fade
        // … keep the existing GeometryReader width preference on the outer view …
    }
```

and at the call site (`:378`): `accountIndicator(session.model.providerLabel, model: session.model)`. If `model.organization` has a different name, use the property `Canvas.swift:417` passes as `organisation:`.

- [ ] **Step 4: The Settings strip (design S3)**

Add `let capacity: [CapacityReading]` to `SettingsPane`'s inputs (beside `let accounts`), pass `capacity: model.capacity.readings` from `Canvas.swift:411`, and immediately above `accountTableHeader()`:

```swift
            let mineIds = Set(accounts.accounts.filter(\.mine).map(\.accountId))
            let strip = capacity.filter { mineIds.contains($0.account) }
            if !strip.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(strip) { reading in
                            CapacityRows(readings: [reading], inUse: runningAccountId, now: Date())
                        }
                    }
                    .padding(.bottom, 14)
                }
                .accessibilityIdentifier("settings.capacity.strip")
            }
```

`runningAccountId` is whatever the row code already compares against to draw `RUNNING` (find that `Text("RUNNING")` condition and reuse its value). The table below is not touched.

- [ ] **Step 5: ⌘P amber** — in `Palettes.swift:52`:

```swift
                        Text(item.subtitle)
                            .foregroundStyle(item.caution ? Color(red: 0.910, green: 0.706, blue: 0.353) : .secondary)
```

- [ ] **Step 6: Build**

Run: `make app-build`
Expected: succeeds with no new warnings in the files touched.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/WakilApp/CapacityRows.swift app/Sources/WakilApp/CapacityIndicator.swift app/Sources/WakilApp/WakilWindow.swift app/Sources/WakilApp/SettingsPane.swift app/Sources/WakilApp/Canvas.swift app/Sources/WakilApp/Palettes.swift
git commit -m "WakilApp: capacity beside ACCOUNT, above the accounts table, and in ⌘P"
```

---

### Task 9: Whole-branch gates (controller only — never a subagent)

- [ ] **Step 1:** `make build && make test && make app-test` — read `.context/app-test.log` on failure. `app-test` runs against whatever `bin/` holds, so `make build` comes first.
- [ ] **Step 2:** Launch check: ask the operator before opening the GUI (shared screen), then `make app-bundle` and open it; run one agent turn and confirm the hairlines appear beside ACCOUNT.
- [ ] **Step 3:** Hand the branch to the e2e auditor (the **Cover** rung, `docs/agents/e2e.md`) for the spec's e2e list: indicator after a turn, amber at 12%, the hover card lists every provider, the strip above an unchanged table, the ⌘P subtitle, `not read since` after a passed reset. Ask the operator before it drives the screen.
