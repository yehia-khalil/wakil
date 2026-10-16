# Provider capacity: the Claude probe — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude accounts get a capacity reading from a 1-token probe's rate-limit headers, read at launch, on a switch and after each turn; Enterprise accounts and Codex's 30-day window read as a `month` window.

**Architecture:** Go owns the probe (`internal/wakilcore/capacity_claude.go`) and runs it inside `wakil-ctx capacity {refresh: true}`, writing the same per-account store the stream path writes. Swift passes `refresh` only for operator-origin dispatches and asks for it at the three triggers. A `month` window is added end to end (Go store, Codex reader, Swift types, display).

**Tech Stack:** Go 1.x (`net/http`, `httptest`), Swift 6 / SwiftUI (WakilKit, WakilApp), the repo's e2e harness (`e2e/driver`).

**Spec:** `docs/superpowers/specs/2026-10-10-provider-capacity-design.md` — read the "Amendment, 2026-10-11" section and "When a probe is sent" first. This plan is a delta on the built branch (plan `docs/superpowers/plans/2026-10-10-provider-capacity.md`, all tasks complete).

## Global Constraints

- Probe: `POST {base}/v1/messages`, headers `Authorization: Bearer <token>`, `anthropic-version: 2023-06-01`, `anthropic-beta: oauth-2025-04-20`, `content-type: application/json`; body model `claude-haiku-5-5`, `max_tokens: 1`, system `You are Claude Code, Anthropic's official CLI for Claude.`, one user message `hi`.
- `{base}` = `https://api.anthropic.com`, overridden by env `WAKIL_ANTHROPIC_BASE_URL` (tests and e2e only).
- 8-second timeout per account; accounts probed in parallel.
- Headers: `anthropic-ratelimit-unified-5h-utilization` / `-5h-reset` → fiveHour; `-7d-utilization` / `-7d-reset` → sevenDay; `-overage-utilization` / `-overage-reset` → month, only when neither 5h nor 7d is present. Utilization 0…1, reset Unix seconds.
- `percentLeft = round((1 − utilization) × 100)`. Utilization outside 0…1 or a non-numeric reset drops that window. A reading with neither fiveHour nor month is not recorded.
- A Claude account is probed only when its stored `asOf` is older than **60 seconds** (or absent).
- A failed probe: stored reading exists → return it unchanged, no error; none → state `error` with the reason.
- **The token never appears** in any log, error string, returned value or stored file.
- `refresh` is honoured only when the dispatch origin is not `.agent`.
- Codex `window_minutes` 43200 → `month`.
- Display: month-only reads `month 95%` (⌘P), a `MONTH` row (strip/card), one hairline (home). Amber at ≤ 20, never red.
- Commit messages: plain; **no `Co-Authored-By`, no "Generated with" lines.**
- Subagents run scoped tests only (`go test ./internal/wakilcore/ -run X`, `cd app && swift test --filter X`); never `make test`, `make app-test` or `make e2e`. Run `make build` before `swift test` (app-test does not build Go).

## Review Focus

1. **An agent asks for `refresh: true`** — must be sent without it; the agent cannot spend the operator's limit. Test in Task 4.
2. **A 401 / 429 / timeout on one account while another succeeds** — the good one reads, the bad one keeps its stored reading or shows its own error (Rule 8). Test in Task 3.
3. **The token leaking into an error** — an `httptest` server that echoes the Authorization header into its body on 500; the error must not contain the token. Test in Task 2.
4. **Headers with a 7d window but no 5h and no overage** — not a reading (a reading needs fiveHour or month); the probe errors rather than drawing a week-only row. Test in Task 2.
5. **Probe storms** — launch + provider switch + turn end within a minute send one probe per account, not three. Test in Task 3.

---

### Task 1: `month` in the Go store and the Codex reader

**Files:**
- Modify: `internal/wakilcore/capacity.go`
- Modify: `internal/wakilcore/capacity_codex.go:96-125, 148-176`
- Modify: `cmd/wakil-ctx/main.go:27-32, 358-368` (record args)
- Test: `internal/wakilcore/capacity_test.go`, `internal/wakilcore/capacity_codex_test.go`

**Interfaces:**
- Produces: `CapacityRecord{FiveHour *CapacityWindow; SevenDay *CapacityWindow; Month *CapacityWindow; AsOf string}` (FiveHour becomes a pointer); `CapacityReading.Month *CapacityWindow` (`json:"month,omitempty"`); `RecordCapacity` unchanged signature, now requires FiveHour or Month.

- [ ] **Step 1: Write the failing tests**

In `capacity_test.go` add a helper and tests (update existing literals `FiveHour: win(...)` to `FiveHour: winp(...)`):

```go
func winp(pct int, at string) *CapacityWindow { w := win(pct, at); return &w }

func TestCapacity_MonthOnlyRecordReads(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{Month: winp(95, "2026-11-01T00:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatalf("RecordCapacity: %v", err)
	}
	got, _ := ReadCapacityFor("initech")
	r := got.Readings[0]
	if r.State != CapacityRead || r.FiveHour != nil || r.Month == nil || r.Month.PercentLeft != 95 {
		t.Errorf("reading = %+v month %+v", r, r.Month)
	}
}

func TestCapacity_NeitherFiveHourNorMonthIsRefused(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{SevenDay: winp(50, "2026-10-16T06:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err == nil {
		t.Fatal("want an error for a reading with neither fiveHour nor month")
	}
}
```

In `capacity_codex_test.go` add (follow that file's existing fixture-writing helper for a rollout line):

```go
func TestCodexCapacity_ThirtyDayWindowIsMonth(t *testing.T) {
	// primary: used_percent 51, window_minutes 43200, resets_at 1793491200; secondary null
	// expect found, FiveHour nil, Month.PercentLeft 49, Month.ResetsAt "2026-11-01T00:00:00Z"
}
```

Write that test body with the file's existing helper, the values in its comment, and these assertions.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run 'TestCapacity_|TestCodexCapacity_'`
Expected: compile errors (`Month` undefined, `FiveHour` type), then FAIL.

- [ ] **Step 3: Implement**

`capacity.go`:

```go
type CapacityRecord struct {
	FiveHour *CapacityWindow `json:"fiveHour,omitempty"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	Month    *CapacityWindow `json:"month,omitempty"`
	AsOf     string          `json:"asOf"`
}

type CapacityReading struct {
	Account  string          `json:"account"`
	Kind     string          `json:"kind"`
	State    string          `json:"state"`
	FiveHour *CapacityWindow `json:"fiveHour,omitempty"`
	SevenDay *CapacityWindow `json:"sevenDay,omitempty"`
	Month    *CapacityWindow `json:"month,omitempty"`
	AsOf     string          `json:"asOf,omitempty"`
	Error    string          `json:"error,omitempty"`
}

// normaliseWindow validates an optional window in place.
func normaliseWindow(w **CapacityWindow) error {
	if *w == nil {
		return nil
	}
	v, err := validWindow(**w)
	if err != nil {
		return err
	}
	*w = &v
	return nil
}
```

In `RecordCapacity`, replace the fiveHour/sevenDay validation with:

```go
	if r.FiveHour == nil && r.Month == nil {
		return UserError("a capacity reading needs a fiveHour or a month window")
	}
	for _, w := range []**CapacityWindow{&r.FiveHour, &r.SevenDay, &r.Month} {
		if err := normaliseWindow(w); err != nil {
			return err
		}
	}
```

In `ReadCapacityFor`, the claude-code read case becomes
`r.State, r.FiveHour, r.SevenDay, r.Month, r.AsOf = CapacityRead, f.FiveHour, f.SevenDay, f.Month, f.AsOf`
and the codex case adds `r.Month = got.Month`.

`capacity_codex.go`: `codexWindows` returns `(five, seven, month *CapacityWindow)`; add the case
`case hasMins && mins == 43200: if month == nil { month = w }`; update its doc comment (30-day → month).
In `ReadCodexCapacity`: `five, seven, month := codexWindows(...)`; skip when `five == nil && month == nil`; set `Month: month` on the reading.

`cmd/wakil-ctx/main.go` `recordCapacityArgs`:

```go
type recordCapacityArgs struct {
	Provider string                    `json:"provider" jsonschema:"the claude-code provider (account) id"`
	FiveHour *wakilcore.CapacityWindow `json:"fiveHour,omitempty" jsonschema:"the 5-hour window"`
	SevenDay *wakilcore.CapacityWindow `json:"sevenDay,omitempty" jsonschema:"the weekly window, when reported"`
	Month    *wakilcore.CapacityWindow `json:"month,omitempty" jsonschema:"the monthly window, when there is no 5-hour one"`
	AsOf     string                    `json:"asOf" jsonschema:"when the reading was taken, RFC 3339"`
}
```

and pass `Month: a.Month` into `CapacityRecord`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/`
Expected: PASS (fix any other literal that used the value `FiveHour`).

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/capacity.go internal/wakilcore/capacity_codex.go internal/wakilcore/capacity_test.go internal/wakilcore/capacity_codex_test.go cmd/wakil-ctx/main.go
git commit -m "Capacity: a month window in the store; Codex's 30-day window reads as month"
```

---

### Task 2: The probe and its header parser

**Files:**
- Create: `internal/wakilcore/capacity_claude.go`
- Test: `internal/wakilcore/capacity_claude_test.go`

**Interfaces:**
- Consumes: `CapacityRecord`, `CapacityWindow`, `wholeSecondUTC` (Task 1 / existing).
- Produces:
  - `const AnthropicBaseURLEnv = "WAKIL_ANTHROPIC_BASE_URL"`
  - `func anthropicBaseURL() string`
  - `func ProbeClaudeCapacity(ctx context.Context, baseURL, token string, now time.Time) (CapacityRecord, error)`
  - `func capacityFromHeaders(h http.Header, now time.Time) (CapacityRecord, bool)`

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var probeNow = time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC)

func probeServer(t *testing.T, status int, headers map[string]string, check func(*http.Request)) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if check != nil {
			check(r)
		}
		for k, v := range headers {
			w.Header().Set(k, v)
		}
		w.WriteHeader(status)
		io.WriteString(w, `{"type":"message"}`)
	}))
	t.Cleanup(s.Close)
	return s
}

func TestProbe_TeamHeadersGiveFiveHourAndWeek(t *testing.T) {
	s := probeServer(t, 200, map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "0.05",
		"anthropic-ratelimit-unified-5h-reset":       "1791725400",
		"anthropic-ratelimit-unified-7d-utilization": "0.16",
		"anthropic-ratelimit-unified-7d-reset":       "1792144800",
	}, nil)
	rec, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow)
	if err != nil {
		t.Fatal(err)
	}
	if rec.FiveHour == nil || rec.FiveHour.PercentLeft != 95 || rec.FiveHour.ResetsAt != "2026-10-11T14:50:00Z" {
		t.Errorf("fiveHour = %+v", rec.FiveHour)
	}
	if rec.SevenDay == nil || rec.SevenDay.PercentLeft != 84 || rec.Month != nil {
		t.Errorf("sevenDay = %+v month = %+v", rec.SevenDay, rec.Month)
	}
	if rec.AsOf != "2026-10-11T10:00:00Z" {
		t.Errorf("asOf = %q", rec.AsOf)
	}
}

func TestProbe_EnterpriseOverageIsMonth(t *testing.T) {
	s := probeServer(t, 200, map[string]string{
		"anthropic-ratelimit-unified-overage-utilization": "0.05",
		"anthropic-ratelimit-unified-overage-reset":       "1793491200",
	}, nil)
	rec, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow)
	if err != nil {
		t.Fatal(err)
	}
	if rec.FiveHour != nil || rec.Month == nil || rec.Month.PercentLeft != 95 || rec.Month.ResetsAt != "2026-11-01T00:00:00Z" {
		t.Errorf("rec = %+v month %+v", rec, rec.Month)
	}
}

func TestProbe_OverageIgnoredWhenFiveHourPresent(t *testing.T) {
	s := probeServer(t, 200, map[string]string{
		"anthropic-ratelimit-unified-5h-utilization":      "0.5",
		"anthropic-ratelimit-unified-5h-reset":            "1791725400",
		"anthropic-ratelimit-unified-overage-utilization": "0.05",
		"anthropic-ratelimit-unified-overage-reset":       "1793491200",
	}, nil)
	rec, _ := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow)
	if rec.Month != nil {
		t.Errorf("month = %+v, want nil when a 5h window is present", rec.Month)
	}
}

// Review Focus 4.
func TestProbe_WeekOnlyIsNotAReading(t *testing.T) {
	s := probeServer(t, 200, map[string]string{
		"anthropic-ratelimit-unified-7d-utilization": "0.16",
		"anthropic-ratelimit-unified-7d-reset":       "1792144800",
	}, nil)
	if _, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow); err == nil {
		t.Fatal("want an error: no fiveHour and no month")
	}
}

func TestProbe_BadValuesAbstain(t *testing.T) {
	for name, h := range map[string]map[string]string{
		"utilization 1.3": {"anthropic-ratelimit-unified-5h-utilization": "1.3", "anthropic-ratelimit-unified-5h-reset": "1791725400"},
		"reset not a number": {"anthropic-ratelimit-unified-5h-utilization": "0.1", "anthropic-ratelimit-unified-5h-reset": "soon"},
		"no headers": {},
	} {
		s := probeServer(t, 200, h, nil)
		if _, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestProbe_Non2xxIsAnError(t *testing.T) {
	for _, status := range []int{401, 429, 500} {
		s := probeServer(t, status, map[string]string{
			"anthropic-ratelimit-unified-5h-utilization": "0.1",
			"anthropic-ratelimit-unified-5h-reset":       "1791725400",
		}, nil)
		if _, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok", probeNow); err == nil {
			t.Errorf("status %d: want an error", status)
		}
	}
}

func TestProbe_SendsTheTokenAndAOneTokenBody(t *testing.T) {
	s := probeServer(t, 200, map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "0.1",
		"anthropic-ratelimit-unified-5h-reset":       "1791725400",
	}, func(r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/v1/messages" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer tok-123" {
			t.Errorf("authorization = %q", got)
		}
		if r.Header.Get("anthropic-beta") != "oauth-2025-04-20" || r.Header.Get("anthropic-version") != "2023-06-01" {
			t.Errorf("headers = %v", r.Header)
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		if body["max_tokens"] != float64(1) || body["model"] != "claude-haiku-5-5" {
			t.Errorf("body = %v", body)
		}
	})
	if _, err := ProbeClaudeCapacity(context.Background(), s.URL, "tok-123", probeNow); err != nil {
		t.Fatal(err)
	}
}

// Review Focus 3.
func TestProbe_ErrorNeverQuotesTheToken(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		io.WriteString(w, "echo: "+r.Header.Get("Authorization"))
	}))
	defer s.Close()
	_, err := ProbeClaudeCapacity(context.Background(), s.URL, "secret-token-xyz", probeNow)
	if err == nil || strings.Contains(err.Error(), "secret-token-xyz") {
		t.Errorf("err = %v", err)
	}
}

func TestProbe_TimesOut(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := ProbeClaudeCapacity(ctx, s.URL, "tok", probeNow); err == nil {
		t.Fatal("want a timeout error")
	}
}

func TestAnthropicBaseURL_EnvOverrides(t *testing.T) {
	t.Setenv(AnthropicBaseURLEnv, "http://127.0.0.1:9")
	if anthropicBaseURL() != "http://127.0.0.1:9" {
		t.Errorf("base = %q", anthropicBaseURL())
	}
	t.Setenv(AnthropicBaseURLEnv, "")
	if anthropicBaseURL() != "https://api.anthropic.com" {
		t.Errorf("default = %q", anthropicBaseURL())
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run 'TestProbe_|TestAnthropicBaseURL_'`
Expected: compile error, `ProbeClaudeCapacity` undefined.

- [ ] **Step 3: Implement**

```go
package wakilcore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// The Claude capacity probe (spec amendment 2026-10-11). Claude Code stopped
// sending rate_limit_event every turn in 2.1.294, and /api/oauth/usage refuses
// the setup-tokens Wakil stores (no user:profile scope). A 1-token request
// with the account's own token answers with the unified rate-limit headers,
// which is what this reads. It costs a sliver of the account's limit; the
// callers bound that (ReadCapacityFor's 60-second floor, three triggers).

const (
	AnthropicBaseURLEnv  = "WAKIL_ANTHROPIC_BASE_URL"
	claudeProbeTimeout   = 8 * time.Second
	claudeProbeModel     = "claude-haiku-5-5"
	claudeProbeSystem    = "You are Claude Code, Anthropic's official CLI for Claude."
	rateLimitHeaderStart = "anthropic-ratelimit-unified-"
)

func anthropicBaseURL() string {
	if b := strings.TrimRight(os.Getenv(AnthropicBaseURLEnv), "/"); b != "" {
		return b
	}
	return "https://api.anthropic.com"
}

// headerWindow reads one <name>-utilization / <name>-reset pair. Anything
// out of range or unparseable abstains (nil), never clamps.
func headerWindow(h http.Header, name string) *CapacityWindow {
	u, err := strconv.ParseFloat(h.Get(rateLimitHeaderStart+name+"-utilization"), 64)
	if err != nil || u < 0 || u > 1 || math.IsNaN(u) {
		return nil
	}
	reset, err := strconv.ParseInt(h.Get(rateLimitHeaderStart+name+"-reset"), 10, 64)
	if err != nil || reset <= 0 {
		return nil
	}
	return &CapacityWindow{
		PercentLeft: int(math.Round((1 - u) * 100)),
		ResetsAt:    wholeSecondUTC(time.Unix(reset, 0)),
	}
}

// capacityFromHeaders maps 5h, 7d and — only when neither is present —
// overage (an Enterprise account's monthly limit) into a record. ok is false
// when there is neither a 5-hour nor a month window.
func capacityFromHeaders(h http.Header, now time.Time) (CapacityRecord, bool) {
	rec := CapacityRecord{FiveHour: headerWindow(h, "5h"), SevenDay: headerWindow(h, "7d"), AsOf: wholeSecondUTC(now)}
	if rec.FiveHour == nil && rec.SevenDay == nil {
		rec.Month = headerWindow(h, "overage")
	}
	return rec, rec.FiveHour != nil || rec.Month != nil
}

// ProbeClaudeCapacity sends one 1-token request with token and reads the
// rate-limit headers. The token goes nowhere but the Authorization header:
// no error built here quotes a header or the response body.
func ProbeClaudeCapacity(ctx context.Context, baseURL, token string, now time.Time) (CapacityRecord, error) {
	body, _ := json.Marshal(map[string]any{
		"model":      claudeProbeModel,
		"max_tokens": 1,
		"system":     claudeProbeSystem,
		"messages":   []map[string]string{{"role": "user", "content": "hi"}},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return CapacityRecord{}, fmt.Errorf("capacity probe: could not build the request")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("content-type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return CapacityRecord{}, fmt.Errorf("capacity probe: no answer within %s", claudeProbeTimeout)
		}
		return CapacityRecord{}, fmt.Errorf("capacity probe: the request failed (%T)", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered %d", resp.StatusCode)
	}
	rec, ok := capacityFromHeaders(resp.Header, now)
	if !ok {
		return CapacityRecord{}, fmt.Errorf("capacity probe: the answer carried no 5-hour or monthly limit")
	}
	return rec, nil
}
```

(The `%T` keeps a transport error's message — which can include the URL but never the header — out of the string; the type alone says which kind of failure it was. If a reviewer prefers `url.Error.Err`'s text, it carries no header either.)

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ -run 'TestProbe_|TestAnthropicBaseURL_'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/capacity_claude.go internal/wakilcore/capacity_claude_test.go
git commit -m "Capacity: the Claude probe — one 1-token request, read the unified rate-limit headers"
```

---

### Task 3: `refresh` in the read path and the `capacity` tool

**Files:**
- Modify: `internal/wakilcore/capacity.go` (`ReadCapacityFor`, `ReadCapacityForCurrentOrg`)
- Modify: `cmd/wakil-ctx/main.go:370-377` (the `capacity` tool)
- Test: `internal/wakilcore/capacity_test.go`, `cmd/wakil-ctx/main_test.go` (whatever file holds the tool-list / capacity tool tests)

**Interfaces:**
- Consumes: `ProbeClaudeCapacity`, `anthropicBaseURL`, `claudeProbeTimeout` (Task 2); `SecretGetFor(org, ref string) (string, error)`, `ProviderTokenRef(id string) string` (existing).
- Produces:
  - `func ReadCapacityFor(org string, refresh bool) (CapacityListing, error)`
  - `func ReadCapacityForCurrentOrg(refresh bool) (CapacityListing, error)`
  - test seams: `var claudeTokenReader = func(org, id string) (string, error)`, `var claudeProber = ProbeClaudeCapacity`, `var capacityNow = time.Now`
  - `const capacityProbeFloor = 60 * time.Second`
  - wakil-ctx `capacity` tool takes `{"refresh": bool}` (optional).

- [ ] **Step 1: Write the failing tests**

Update every existing `ReadCapacityFor("initech")` call to `ReadCapacityFor("initech", false)`. Add:

```go
func stubProbe(t *testing.T, fn func(token string) (CapacityRecord, error)) *int {
	t.Helper()
	calls := 0
	var mu sync.Mutex
	prevTok, prevProbe, prevNow := claudeTokenReader, claudeProber, capacityNow
	claudeTokenReader = func(org, id string) (string, error) { return "tok-" + id, nil }
	claudeProber = func(ctx context.Context, base, token string, now time.Time) (CapacityRecord, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		return fn(token)
	}
	capacityNow = func() time.Time { return time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC) }
	t.Cleanup(func() { claudeTokenReader, claudeProber, capacityNow = prevTok, prevProbe, prevNow })
	return &calls
}

func TestCapacity_RefreshProbesAndStores(t *testing.T) {
	setupHome(t)
	calls := stubProbe(t, func(string) (CapacityRecord, error) {
		return CapacityRecord{FiveHour: winp(88, "2026-10-11T14:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}, nil
	})
	got, err := ReadCapacityFor("initech", true)
	if err != nil {
		t.Fatal(err)
	}
	if *calls != 1 || got.Readings[0].State != CapacityRead || got.Readings[0].FiveHour.PercentLeft != 88 {
		t.Errorf("calls %d reading %+v", *calls, got.Readings[0])
	}
	again, _ := ReadCapacityFor("initech", false)
	if again.Readings[0].FiveHour == nil || again.Readings[0].FiveHour.PercentLeft != 88 {
		t.Errorf("not stored: %+v", again.Readings[0])
	}
}

func TestCapacity_NoRefreshNeverProbes(t *testing.T) {
	setupHome(t)
	calls := stubProbe(t, func(string) (CapacityRecord, error) { t.Fatal("probed"); return CapacityRecord{}, nil })
	ReadCapacityFor("initech", false)
	if *calls != 0 {
		t.Errorf("calls = %d", *calls)
	}
}

// Review Focus 5.
func TestCapacity_ReadingUnderAMinuteOldIsNotProbedAgain(t *testing.T) {
	setupHome(t)
	calls := stubProbe(t, func(string) (CapacityRecord, error) {
		return CapacityRecord{FiveHour: winp(88, "2026-10-11T14:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}, nil
	})
	ReadCapacityFor("initech", true)
	capacityNow = func() time.Time { return time.Date(2026, 10, 11, 10, 0, 59, 0, time.UTC) }
	ReadCapacityFor("initech", true)
	if *calls != 1 {
		t.Errorf("calls = %d, want 1 within the floor", *calls)
	}
	capacityNow = func() time.Time { return time.Date(2026, 10, 11, 10, 1, 1, 0, time.UTC) }
	ReadCapacityFor("initech", true)
	if *calls != 2 {
		t.Errorf("calls = %d, want 2 after the floor", *calls)
	}
}

func TestCapacity_FailedProbeKeepsTheStoredReading(t *testing.T) {
	setupHome(t)
	if err := RecordCapacity("initech", "primary", CapacityRecord{FiveHour: winp(40, "2026-10-11T14:00:00Z"), AsOf: "2026-10-11T08:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	stubProbe(t, func(string) (CapacityRecord, error) { return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered 429") })
	got, _ := ReadCapacityFor("initech", true)
	r := got.Readings[0]
	if r.State != CapacityRead || r.FiveHour.PercentLeft != 40 || r.AsOf != "2026-10-11T08:00:00Z" || r.Error != "" {
		t.Errorf("reading = %+v", r)
	}
}

func TestCapacity_FailedProbeWithNothingStoredIsThatRowsError(t *testing.T) {
	setupHome(t)
	stubProbe(t, func(string) (CapacityRecord, error) { return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered 401") })
	got, _ := ReadCapacityFor("initech", true)
	if r := got.Readings[0]; r.State != CapacityError || !strings.Contains(r.Error, "401") {
		t.Errorf("reading = %+v", r)
	}
}

func TestCapacity_MissingTokenIsThatRowsError(t *testing.T) {
	setupHome(t)
	stubProbe(t, func(string) (CapacityRecord, error) { t.Fatal("probed without a token"); return CapacityRecord{}, nil })
	claudeTokenReader = func(org, id string) (string, error) { return "", UserError("no credential stored for provider:" + id) }
	got, _ := ReadCapacityFor("initech", true)
	if got.Readings[0].State != CapacityError {
		t.Errorf("reading = %+v", got.Readings[0])
	}
}
```

Review Focus 2 (two accounts, one fails): `setupHome` gives one claude-code provider; add a second with the existing `AddProvider` test helper pattern used in `TestCapacity_SharedConfigDirReadsTheSameInBothOrgs` (a second config dir under the temp home), make `stubProbe`'s fn fail for `"tok-<second id>"` and succeed for `"tok-primary"`, and assert the first row is `read` and the second `error`. Name it `TestCapacity_OneAccountFailingLeavesTheOthers`.

In the wakil-ctx tests, add a case that calls the `capacity` tool with `{"refresh": false}` and with `{}` and both succeed (the tool accepts the argument). Find the existing `capacity` tool test with `grep -n '"capacity"' cmd/wakil-ctx/*_test.go` and follow it.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run TestCapacity_ && go test ./cmd/wakil-ctx/`
Expected: compile errors (signature, seams), then FAIL.

- [ ] **Step 3: Implement**

In `capacity.go` add (imports `context`, `sync`):

```go
const capacityProbeFloor = 60 * time.Second

// Seams, so the store's tests never read the Keychain or reach the network.
var (
	claudeTokenReader = func(org, id string) (string, error) { return SecretGetFor(org, ProviderTokenRef(id)) }
	claudeProber      = ProbeClaudeCapacity
	capacityNow       = time.Now
)

// probeStale probes, in parallel, every claude-code provider whose stored
// reading is missing or older than the floor, and stores what each answers.
// It returns the failures by provider id; a success is only in the store.
func probeStale(org string, providers []Provider) map[string]string {
	now := capacityNow()
	failures := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, p := range providers {
		if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
			continue
		}
		if path, err := capacityPath(p.ConfigDir); err == nil {
			if f, err := readCapacityFile(path); err == nil && f != nil {
				if at, err := time.Parse(time.RFC3339, f.AsOf); err == nil && now.Sub(at) < capacityProbeFloor {
					continue
				}
			}
		}
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			fail := func(msg string) { mu.Lock(); failures[id] = msg; mu.Unlock() }
			token, err := claudeTokenReader(org, id)
			if err != nil {
				fail(err.Error())
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), claudeProbeTimeout)
			defer cancel()
			rec, err := claudeProber(ctx, anthropicBaseURL(), token, now)
			if err != nil {
				fail(err.Error())
				return
			}
			if err := RecordCapacity(org, id, rec); err != nil {
				fail(err.Error())
			}
		}(p.ID)
	}
	wg.Wait()
	return failures
}
```

Change `ReadCapacityFor(org string)` to `ReadCapacityFor(org string, refresh bool)`: after listing providers,

```go
	var failures map[string]string
	if refresh {
		failures = probeStale(org, providers)
	}
```

and in the claude-code case, after the existing switch on `readCapacityFile`:

```go
			if msg, failed := failures[p.ID]; failed && r.State == CapacityNotRead {
				r.State, r.Error = CapacityError, msg
			}
```

(A stored reading stays `read` with its old `asOf`; only an account with nothing stored shows the failure.)

`ReadCapacityForCurrentOrg(refresh bool)` passes it through. Check `Provider`'s type name with `grep -n 'func ListProvidersFor' internal/wakilcore/*.go` and use what it returns.

`cmd/wakil-ctx/main.go`:

```go
type capacityArgs struct {
	Refresh bool `json:"refresh,omitempty" jsonschema:"probe each claude-code account whose reading is over a minute old before answering; costs a 1-token request per account"`
}
```

and the tool handler takes `a capacityArgs` and calls `wakilcore.ReadCapacityForCurrentOrg(a.Refresh)`. Extend its description with: `With refresh, stale claude-code accounts are probed first (one 1-token request each).`

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/capacity.go internal/wakilcore/capacity_test.go cmd/wakil-ctx/
git commit -m "Capacity: capacity {refresh} probes stale Claude accounts in parallel, once a minute at most"
```

---

### Task 4: Swift — `month`, operator-only `refresh`, `CapacityFeed.refresh(probe:)`

**Files:**
- Modify: `app/Sources/WakilKit/Core/CapacityReading.swift`
- Modify: `app/Sources/WakilKit/Core/CapacityDisplay.swift`
- Modify: `app/Sources/WakilKit/Registry/CapacityActions.swift`
- Modify: `app/Sources/WakilKit/App/CapacityFeed.swift`
- Test: `app/Tests/WakilKitTests/` — the existing capacity test files (`grep -ln 'CapacityFeed\|CapacityDisplay\|ctx_capacity' app/Tests/WakilKitTests/*.swift`)

**Interfaces:**
- Consumes: Go `capacity {refresh}` (Task 3); `ActionRegistry.dispatchOrigin` (`@TaskLocal static var`, `ActionRegistry.swift:625`), `ActionOrigin.agent`.
- Produces: `CapacityReading.month: CapacityWindow?` (init gains `month:` with default `nil`, after `sevenDay:`); `CapacityFeed.refresh(probe: Bool = false) async`; `ctx_capacity` schema property `refresh` (boolean).

- [ ] **Step 1: Write the failing tests**

```swift
// CapacityDisplay
@Test func monthOnlyReadingReadsAsMonth() {
    let now = Date(timeIntervalSince1970: 1_791_712_000)
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read, fiveHour: nil, sevenDay: nil,
                            month: CapacityWindow(percentLeft: 95, resetsAt: now.addingTimeInterval(20 * 86_400)),
                            asOf: now, error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now).text == "month 95%")
}

@Test func monthAtTwentyIsLow() {
    let now = Date(timeIntervalSince1970: 1_791_712_000)
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read, fiveHour: nil, sevenDay: nil,
                            month: CapacityWindow(percentLeft: 20, resetsAt: now.addingTimeInterval(86_400)),
                            asOf: now, error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now).low)
}

// decode
@Test func listingDecodesMonth() {
    // a structuredContent listing with one reading carrying "month":{"percentLeft":95,"resetsAt":"2026-11-01T00:00:00Z"}
    // and no fiveHour → decodeCapacityListing returns it with month.percentLeft == 95
}

// CapacityFeed
@MainActor @Test func refreshWithProbeAsksForRefresh() async {
    var sent: [(String, JSONValue)] = []
    let feed = CapacityFeed()
    feed.attach { name, params in sent.append((name, params)); return .null }
    await feed.refresh(probe: true)
    await feed.refresh()
    #expect(sent.map(\.0) == ["ctx_capacity", "ctx_capacity"])
    #expect(sent[0].1 == .object(["refresh": .bool(true)]))
    #expect(sent[1].1 == .object([:]))
}

// ctx_capacity handler — Review Focus 1
@Test func agentOriginRefreshIsDropped() async throws {
    // Register capacity actions against a fake ToolCaller that records the arguments of each "capacity" call
    // (follow the existing CapacityActions test's fake). Dispatch ctx_capacity with {"refresh": true}
    // once with origin .agent and once with origin .ui through the registry's dispatch.
    // Expect the .agent call's arguments == .object([:]) and the .ui call's == .object(["refresh": .bool(true)]).
}
```

Write `listingDecodesMonth` and `agentOriginRefreshIsDropped` in full by following the neighbouring tests in the same files (the decode test's JSON fixture, the actions test's fake `ToolCaller` and registry dispatch). Use the JSONValue boolean case the codebase defines (`grep -n 'case bool' app/Sources/WakilKit/*/JSONValue.swift`).

- [ ] **Step 2: Run them to see them fail**

Run: `make build && cd app && swift test --filter 'Capacity'`
Expected: compile errors (`month:`, `refresh(probe:)`), then FAIL.

- [ ] **Step 3: Implement**

`CapacityReading.swift` — add `public let month: CapacityWindow?` after `sevenDay`; the init becomes

```swift
    public init(account: String, kind: String, state: State, fiveHour: CapacityWindow?,
                sevenDay: CapacityWindow?, month: CapacityWindow? = nil, asOf: Date?, error: String?) {
        self.account = account; self.kind = kind; self.state = state
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.month = month
        self.asOf = asOf; self.error = error
    }
```

`CapacityDisplay.paletteText` — the loop list becomes
`[("5h", r.fiveHour), ("week", r.sevenDay), ("month", r.month)]`.

`CapacityActions.swift` — `ctx_capacity`'s schema properties become
`["refresh": .object(["type": .string("boolean")])]`, its description gains
`" With refresh (operator only), stale Claude accounts are probed first."`, and the handler:

```swift
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "ctx_capacity", role: "context")
            }
            // The agent cannot spend the operator's limit: refresh is a
            // 1-token request per account, honoured only for the operator.
            var arguments: [String: JSONValue] = [:]
            if ActionRegistry.dispatchOrigin != .agent,
               case .object(let fields) = params, fields["refresh"] == .bool(true) {
                arguments["refresh"] = .bool(true)
            }
            return try await callChecked(context, tool: "capacity", arguments: .object(arguments),
                                         action: "ctx_capacity", timeout: MCPClient.readReplyTimeout)
        }
```

`CapacityFeed.swift`:

```swift
    /// Re-reads every account. `probe` asks Go to probe stale Claude
    /// accounts first (a 1-token request each, at most once a minute per
    /// account); only launch, a switch and a turn's end pass it.
    public func refresh(probe: Bool = false) async {
        guard let dispatch else { return }
        do {
            let params: JSONValue = probe ? .object(["refresh": .bool(true)]) : .object([:])
            let result = try await dispatch("ctx_capacity", params)
            ...unchanged...
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter 'Capacity|ActionClassification'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Core/CapacityReading.swift app/Sources/WakilKit/Core/CapacityDisplay.swift app/Sources/WakilKit/Registry/CapacityActions.swift app/Sources/WakilKit/App/CapacityFeed.swift app/Tests/WakilKitTests/
git commit -m "Capacity (Swift): month window; refresh is operator-only; CapacityFeed.refresh(probe:)"
```

---

### Task 5: Swift wiring — the three triggers and the base-URL env

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (~1640 `refreshContext`, ~4882 the pump loop, ~5202 `setProvider`, ~6488 `receiveForTesting`)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift:583` (`childProcessEnvironment`)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift` (or the capacity WindowModel tests file), `app/Tests/WakilKitTests/AppWiringTests.swift`

**Interfaces:**
- Consumes: `CapacityFeed.refresh(probe:)` (Task 4).
- Produces: nothing new for later tasks; `WAKIL_ANTHROPIC_BASE_URL` reaches `wakil-ctx` when set in the app's environment.

- [ ] **Step 1: Write the failing tests**

```swift
// WindowModel: a turn's end asks for a probe (use the existing capacity WindowModel test's
// fake dispatch that records (name, params) and answers ctx_capacity with an empty listing)
@MainActor @Test func turnEndRefreshesWithProbe() async {
    // model.receiveForTesting(.result(isError: false, text: "ok"))
    // expect the recorded ctx_capacity calls to contain params == .object(["refresh": .bool(true)])
}

@MainActor @Test func refreshContextRefreshesWithProbe() async {
    // after await model.refreshContext(), the ctx_capacity call carried refresh: true
}

@MainActor @Test func setProviderRefreshesWithProbe() async {
    // after await model.setProvider("<second fixture provider>"), a ctx_capacity call carried refresh: true
}

// AppWiring
@Test func childEnvironmentForwardsTheAnthropicBaseURL() {
    let env = AppWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ANTHROPIC_BASE_URL": "http://127.0.0.1:4545"],
        org: "initech", provider: "main")
    #expect(env["WAKIL_ANTHROPIC_BASE_URL"] == "http://127.0.0.1:4545")
    let without = AppWiring.childProcessEnvironment(from: ["HOME": "/h", "PATH": "/p"], org: "initech", provider: "main")
    #expect(without["WAKIL_ANTHROPIC_BASE_URL"] == nil)
}
```

Write the three WindowModel tests in full by following the existing test that pins `refreshContext` reading capacity (added in commit 47ba6c32; `git show 47ba6c32 --stat` names it). Check the real type name holding `childProcessEnvironment` (`grep -n 'static func childProcessEnvironment' -B30 app/Sources/WakilKit/App/AppWiring.swift | grep -m1 'enum\|struct'`).

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && swift test --filter 'WindowModel|AppWiring'` (scoped to the new test names with `--filter` if the suites are long)
Expected: FAIL — calls carry `{}`; the env lacks the key.

- [ ] **Step 3: Implement**

- `refreshContext()` ~1640: `await capacity.refresh()` → `await capacity.refresh(probe: true)` (keep the comment; add "with a probe: this is launch and an org switch").
- The pump loop ~4883: inside `if case .result = event {`, before `await self.fireQueuedSwitchIfReady()`, add `await self.capacity.refresh(probe: true)`.
- `receiveForTesting` ~6491: after `await recordCapacity(...)`, add `if case .result = event { await capacity.refresh(probe: true) }` — the same order as the pump.
- `setProvider(_:)`: if it does not already reach `refreshContext()`, add `await capacity.refresh(probe: true)` after the provider is persisted and `providerId` updated (read the function; place it on the success path only).
- `childProcessEnvironment`: after the `WAKIL_KEYCHAIN` forwarding, add

```swift
        // Forwarded for the same reason as WAKIL_KEYCHAIN: fixed for the
        // life of the process and set by the launcher. Only tests and e2e
        // set it, to keep the capacity probe off the real API.
        if let base = environment["WAKIL_ANTHROPIC_BASE_URL"], !base.isEmpty {
            childEnvironment["WAKIL_ANTHROPIC_BASE_URL"] = base
        }
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter 'WindowModel|AppWiring|InvalidationContract'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/
git commit -m "Capacity: probe at launch, on a switch and when a turn ends; forward WAKIL_ANTHROPIC_BASE_URL"
```

---

### Task 6: WakilApp views — the month row and the single hairline

**Files:**
- Modify: `app/Sources/WakilApp/CapacityRows.swift:34-36`
- Modify: `app/Sources/WakilApp/CapacityIndicator.swift:14-18`

**Interfaces:**
- Consumes: `CapacityReading.month` (Task 4).

- [ ] **Step 1: Implement** (WakilApp has no test target; the e2e auditor covers it)

`CapacityRows` `.read` case:

```swift
                    case .read:
                        if let w = reading.fiveHour { line("5H", w) }
                        if let w = reading.sevenDay { line("WEEK", w) }
                        if let w = reading.month { line("MONTH", w) }
```

The `line` label column is 34 pt wide; `MONTH` at 10.5 pt monospaced needs ~40 pt — change `.frame(width: 34, ...)` to `.frame(width: 42, ...)`.

`CapacityHairlines`:

```swift
            VStack(spacing: 3) {
                if let month = reading.month, reading.fiveHour == nil {
                    bar(month)
                } else {
                    bar(reading.fiveHour)
                    bar(reading.sevenDay)
                }
            }
```

- [ ] **Step 2: Build**

Run: `make app-build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add app/Sources/WakilApp/CapacityRows.swift app/Sources/WakilApp/CapacityIndicator.swift
git commit -m "Capacity views: a MONTH row and a single hairline for a month-only account"
```

---

### Task 7: e2e harness — a stub API, never the real one

**Files:**
- Modify: `e2e/driver/fixture.go` (`Env`)
- Create: `e2e/driver/anthropicstub.go`, `e2e/driver/anthropicstub_test.go`
- Modify: the driver's launch path that calls `Fixture.Env` (`grep -rn '\.Env(' e2e/driver/*.go | grep -v _test`) to start the stub first and stop it at teardown.
- Modify: `e2e/driver/isolation.go` if it lists the env keys an app child may carry (`grep -n 'WAKIL_KEYCHAIN' e2e/driver/isolation.go`)

**Interfaces:**
- Produces:
  - `func StartAnthropicStub(headers map[string]string) (url string, stop func(), err error)` — an `httptest`-style server on 127.0.0.1 that answers every `POST /v1/messages` with 200, `{"type":"message","content":[]}` and the given headers.
  - `Fixture.AnthropicBaseURL string`; `Env` always emits `WAKIL_ANTHROPIC_BASE_URL=` + that value, and when it is empty emits `WAKIL_ANTHROPIC_BASE_URL=http://127.0.0.1:9` (a closed port) so no run ever reaches the real API.
  - `DefaultStubCapacityHeaders`: 5h utilization `0.88` / reset `4085222400` (2099-06-15T12:00:00Z), 7d `0.41` / same reset — the 12% / 59% the existing checks read.

- [ ] **Step 1: Write the failing tests**

```go
func TestFixtureEnv_NeverReachesTheRealAPI(t *testing.T) {
	f := Fixture{Home: "/h", TmpDir: "/t", BinDir: "/b", Keychain: "/k"}
	env := strings.Join(f.Env("/usr/bin", Seeded{}), "\n")
	if !strings.Contains(env, "WAKIL_ANTHROPIC_BASE_URL=http://127.0.0.1:9") {
		t.Errorf("env = %s", env)
	}
	f.AnthropicBaseURL = "http://127.0.0.1:4545"
	env = strings.Join(f.Env("/usr/bin", Seeded{}), "\n")
	if !strings.Contains(env, "WAKIL_ANTHROPIC_BASE_URL=http://127.0.0.1:4545") {
		t.Errorf("env = %s", env)
	}
}

func TestAnthropicStub_AnswersWithTheHeaders(t *testing.T) {
	url, stop, err := StartAnthropicStub(DefaultStubCapacityHeaders)
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	resp, err := http.Post(url+"/v1/messages", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("anthropic-ratelimit-unified-5h-utilization") != "0.88" {
		t.Errorf("status %d headers %v", resp.StatusCode, resp.Header)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./e2e/driver/ -run 'TestFixtureEnv_|TestAnthropicStub_'`
Expected: compile errors.

- [ ] **Step 3: Implement**

`anthropicstub.go`:

```go
package driver

import (
	"io"
	"net"
	"net/http"
)

// DefaultStubCapacityHeaders are what the stub API answers every probe
// with: 12% of the 5-hour window and 59% of the week left, both resetting
// 2099-06-15T12:00:00Z — the figures the capacity checks read.
var DefaultStubCapacityHeaders = map[string]string{
	"anthropic-ratelimit-unified-5h-utilization": "0.88",
	"anthropic-ratelimit-unified-5h-reset":       "4085222400",
	"anthropic-ratelimit-unified-7d-utilization": "0.41",
	"anthropic-ratelimit-unified-7d-reset":       "4085222400",
}

// StartAnthropicStub serves the capacity probe locally, so an e2e run
// never spends a real account's limit or depends on the network.
func StartAnthropicStub(headers map[string]string) (string, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		for k, v := range headers {
			w.Header().Set(k, v)
		}
		w.Header().Set("content-type", "application/json")
		io.WriteString(w, `{"type":"message","content":[]}`)
	})}
	go srv.Serve(ln)
	return "http://" + ln.Addr().String(), func() { srv.Close() }, nil
}
```

`fixture.go`: add `AnthropicBaseURL string` to `Fixture` with a comment, and in `Env`:

```go
	// The capacity probe's API (spec amendment 2026-10-11). Always set:
	// a stub when the run started one, else a closed port, so no run can
	// reach api.anthropic.com with a fixture token or spend a real limit.
	base := f.AnthropicBaseURL
	if base == "" {
		base = "http://127.0.0.1:9"
	}
	env = append(env, "WAKIL_ANTHROPIC_BASE_URL="+base)
```

At the launch site: start the stub with `DefaultStubCapacityHeaders` before building the env, set `fixture.AnthropicBaseURL`, and register `stop` with the run's existing teardown. If `isolation.go` keeps an allow-list of environment keys, add `WAKIL_ANTHROPIC_BASE_URL`.

- [ ] **Step 4: Run the tests**

Run: `go test ./e2e/driver/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add e2e/driver/
git commit -m "e2e: a stub Anthropic API for the capacity probe; runs never reach the real one"
```

---

### Task 8: Gates, Cover, runbook (controller)

Not a subagent task. The controller:

1. `make test` and `make app-test` (after `make build`), full, in the background; record rc.
2. Asks the operator before any GUI run (shared screen) and tells peer sessions.
3. Dispatches the e2e auditor (`docs/agents/e2e.md`) over the delta: the indicator at launch with no turn (`5h 12% · week 59%` from the stub), after a turn, a passed reset, and — if the fixture can hold a second, month-only account behind a second stub header set — `month 95%`. The auditor updates `capacity-after-turn`, `capacity-low-reading`, `capacity-passed-reset` as the new source requires, proves new checks red against `wm-8-layering`, and lists what it could not cover.
4. `make e2e`, then `make e2e-runbook`; updates `docs/wakil/provider-capacity-acceptance.md`: step 1 now expects hairlines at launch, step 2 compares with `/usage`, a new step for an Enterprise account's month row, step 9 (Codex 30-day) expects `month N%`.
5. Ledger and handoff note.
