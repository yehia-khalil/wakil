package wakilcore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func win(pct int, at string) CapacityWindow { return CapacityWindow{PercentLeft: pct, ResetsAt: at} }

func TestCapacity_RecordThenRead(t *testing.T) {
	setupHome(t) // org initech, claude-code provider "primary"
	rec := CapacityRecord{FiveHour: winp(28, "2026-10-10T17:20:00Z"), SevenDay: &CapacityWindow{PercentLeft: 59, ResetsAt: "2026-10-16T06:00:00Z"}, AsOf: "2026-10-10T16:18:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatalf("RecordCapacity: %v", err)
	}
	got, err := ReadCapacityFor("initech", false)
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
	got, _ := ReadCapacityFor("initech", false)
	if got.Readings[0].State != CapacityNotRead {
		t.Errorf("state = %q, want notRead", got.Readings[0].State)
	}
}

// Review Focus 2.
func TestCapacity_OlderReadingDoesNotReplaceNewer(t *testing.T) {
	setupHome(t)
	newer := CapacityRecord{FiveHour: winp(20, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:30:00Z"}
	older := CapacityRecord{FiveHour: winp(80, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}
	if err := RecordCapacity("initech", "primary", newer); err != nil {
		t.Fatal(err)
	}
	if err := RecordCapacity("initech", "primary", older); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadCapacityFor("initech", false)
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
	if err := RecordCapacity("initech", "primary", CapacityRecord{FiveHour: winp(41, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCapacityFor("personal", false)
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
	got, _ := ReadCapacityFor("initech", false)
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
	if err := RecordCapacity("initech", "second", CapacityRecord{FiveHour: winp(50, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	path, _ := capacityPath(cfg)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCapacityFor("initech", false)
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
		"percent over 100": {FiveHour: winp(101, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"},
		"percent negative": {FiveHour: winp(-1, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"},
		"reset not a time": {FiveHour: winp(10, "soon"), AsOf: "2026-10-10T16:00:00Z"},
		"asOf missing":     {FiveHour: winp(10, "2026-10-10T17:20:00Z")},
	}
	for name, rec := range cases {
		if err := RecordCapacity("initech", "primary", rec); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := RecordCapacity("initech", "nobody", CapacityRecord{FiveHour: winp(10, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T16:00:00Z"}); err == nil {
		t.Error("unknown provider accepted")
	}
}

// Swift's .iso8601 decoder rejects fractional seconds and offsets would make the
// stored strings differ in spelling: every time is stored as whole-second UTC.
func TestCapacity_TimesAreStoredAsWholeSecondUTC(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{
		FiveHour: winp(28, "2026-10-10T20:20:00.5+03:00"),
		SevenDay: &CapacityWindow{PercentLeft: 59, ResetsAt: "2026-10-16T09:00:00.999Z"},
		AsOf:     "2026-10-10T19:30:00.5+03:00",
	}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatal(err)
	}
	// An older reading, spelled with an offset, still loses to the newer one.
	older := CapacityRecord{FiveHour: winp(80, "2026-10-10T17:20:00Z"), AsOf: "2026-10-10T19:00:00+03:00"}
	if err := RecordCapacity("initech", "primary", older); err != nil {
		t.Fatal(err)
	}
	got, _ := ReadCapacityFor("initech", false)
	r := got.Readings[0]
	if r.FiveHour.PercentLeft != 28 {
		t.Fatalf("percentLeft = %d, want the newer 28", r.FiveHour.PercentLeft)
	}
	if r.FiveHour.ResetsAt != "2026-10-10T17:20:00Z" || r.SevenDay.ResetsAt != "2026-10-16T09:00:00Z" || r.AsOf != "2026-10-10T16:30:00Z" {
		t.Errorf("times = %q %q %q", r.FiveHour.ResetsAt, r.SevenDay.ResetsAt, r.AsOf)
	}
}

func winp(pct int, at string) *CapacityWindow { w := win(pct, at); return &w }

func TestCapacity_MonthOnlyRecordReads(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{Month: winp(95, "2026-11-01T00:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatalf("RecordCapacity: %v", err)
	}
	got, _ := ReadCapacityFor("initech", false)
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

func TestCapacity_MonthIsDroppedWhenFiveHourPresent(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{FiveHour: winp(40, "2026-10-11T15:00:00Z"), Month: winp(95, "2026-11-01T00:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err != nil {
		t.Fatalf("RecordCapacity: %v", err)
	}
	got, _ := ReadCapacityFor("initech", false)
	if r := got.Readings[0]; r.FiveHour == nil || r.Month != nil {
		t.Errorf("reading = %+v month %+v, want fiveHour and no month", r, r.Month)
	}
}

func TestCapacity_SevenDayWithMonthNoFiveHourIsRefused(t *testing.T) {
	setupHome(t)
	rec := CapacityRecord{SevenDay: winp(50, "2026-10-16T06:00:00Z"), Month: winp(95, "2026-11-01T00:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}
	if err := RecordCapacity("initech", "primary", rec); err == nil {
		t.Fatal("want an error: month is dropped beside sevenDay, leaving neither fiveHour nor month")
	}
	got, _ := ReadCapacityFor("initech", false)
	if r := got.Readings[0]; r.State != CapacityNotRead {
		t.Errorf("reading = %+v, want nothing stored", r)
	}
}

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
	stubProbe(t, func(string) (CapacityRecord, error) {
		return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered 429")
	})
	got, _ := ReadCapacityFor("initech", true)
	r := got.Readings[0]
	if r.State != CapacityRead || r.FiveHour.PercentLeft != 40 || r.AsOf != "2026-10-11T08:00:00Z" || r.Error != "" {
		t.Errorf("reading = %+v", r)
	}
}

func TestCapacity_FailedProbeWithNothingStoredIsThatRowsError(t *testing.T) {
	setupHome(t)
	stubProbe(t, func(string) (CapacityRecord, error) {
		return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered 401")
	})
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

// Review Focus 2.
func TestCapacity_OneAccountFailingLeavesTheOthers(t *testing.T) {
	home, _ := setupHome(t)
	cfg2 := filepath.Join(home, ".claude-second")
	if err := os.MkdirAll(cfg2, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "second", Kind: ProviderKindClaudeCode, ConfigDir: cfg2}); err != nil {
		t.Fatal(err)
	}
	stubProbe(t, func(token string) (CapacityRecord, error) {
		if token == "tok-second" {
			return CapacityRecord{}, fmt.Errorf("capacity probe: the API answered 401")
		}
		return CapacityRecord{FiveHour: winp(70, "2026-10-11T14:00:00Z"), AsOf: "2026-10-11T10:00:00Z"}, nil
	})
	got, err := ReadCapacityFor("initech", true)
	if err != nil || len(got.Readings) != 2 {
		t.Fatalf("err %v readings %+v", err, got.Readings)
	}
	by := map[string]CapacityReading{}
	for _, r := range got.Readings {
		by[r.Account] = r
	}
	if r := by["primary"]; r.State != CapacityRead || r.FiveHour == nil || r.FiveHour.PercentLeft != 70 {
		t.Errorf("primary = %+v", r)
	}
	if r := by["second"]; r.State != CapacityError || !strings.Contains(r.Error, "401") {
		t.Errorf("second = %+v", r)
	}
}
