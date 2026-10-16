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

// The real shape of a 2026-08-26 log: a 30-day primary, no secondary.
const codexMonthlyLine = `{"timestamp":"2026-08-26T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":51.0,"window_minutes":43200,"resets_at":1790358897},"secondary":null}}}`

func TestCodex_WindowsChosenByLength(t *testing.T) {
	dir := t.TempDir()
	line := `{"timestamp":"2026-10-10T13:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":36.0,"window_minutes":10080,"resets_at":1792064400},"secondary":{"used_percent":9.0,"window_minutes":300,"resets_at":1791660120}}}}`
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", line)
	got, found, err := ReadCodexCapacity(dir)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v", found, err)
	}
	if got.FiveHour == nil || got.FiveHour.PercentLeft != 91 || got.FiveHour.ResetsAt != "2026-10-10T19:22:00Z" {
		t.Errorf("fiveHour = %+v, want 91 at 19:22", got.FiveHour)
	}
	if got.SevenDay == nil || got.SevenDay.PercentLeft != 64 || got.SevenDay.ResetsAt != "2026-10-15T11:40:00Z" {
		t.Errorf("sevenDay = %+v, want 64 at 2026-10-15T11:40", got.SevenDay)
	}
}

func TestCodex_NewestMonthlyLineWinsOverOlderWeeklyLine(t *testing.T) {
	dir := t.TempDir()
	writeCodexLog(t, dir, "2026/10/09", "rollout-2026-10-09T10-00-00-a.jsonl", codexLine)
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-b.jsonl", codexMonthlyLine)
	got, found, err := ReadCodexCapacity(dir)
	if err != nil || !found || got.FiveHour != nil || got.Month == nil || got.Month.PercentLeft != 49 {
		t.Errorf("found=%v err=%v reading=%+v, want the newer month reading", found, err, got)
	}
}

func TestCodex_NoWindowMinutesFallsBackToPosition(t *testing.T) {
	dir := t.TempDir()
	line := `{"timestamp":"2026-10-10T13:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9.0,"resets_at":1791660120},"secondary":{"used_percent":36.0,"resets_at":1792064400}}}}`
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", line)
	got, found, err := ReadCodexCapacity(dir)
	if err != nil || !found || got.FiveHour == nil || got.FiveHour.PercentLeft != 91 || got.SevenDay == nil || got.SevenDay.PercentLeft != 64 {
		t.Errorf("found=%v err=%v reading=%+v, want positional 91 / 64", found, err, got)
	}
}

func TestCodexCapacity_ThirtyDayWindowIsMonth(t *testing.T) {
	dir := t.TempDir()
	line := `{"timestamp":"2026-10-10T13:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":51.0,"window_minutes":43200,"resets_at":1793491200},"secondary":null}}}`
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", line)
	got, found, err := ReadCodexCapacity(dir)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v", found, err)
	}
	if got.FiveHour != nil || got.Month == nil || got.Month.PercentLeft != 49 || got.Month.ResetsAt != "2026-11-01T00:00:00Z" {
		t.Errorf("fiveHour %+v month %+v, want no fiveHour and month 49 at 2026-11-01", got.FiveHour, got.Month)
	}
}

func TestCodexCapacity_MonthWithSevenDayIsNotRecorded(t *testing.T) {
	dir := t.TempDir()
	line := `{"timestamp":"2026-10-10T13:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":51.0,"window_minutes":43200,"resets_at":1793491200},"secondary":{"used_percent":36.0,"window_minutes":10080,"resets_at":1792064400}}}}`
	writeCodexLog(t, dir, "2026/10/10", "rollout-2026-10-10T10-00-00-a.jsonl", line)
	_, seven, month := codexWindows(map[string]any{
		"primary":   map[string]any{"used_percent": 51.0, "window_minutes": 43200.0, "resets_at": 1793491200.0},
		"secondary": map[string]any{"used_percent": 36.0, "window_minutes": 10080.0, "resets_at": 1792064400.0},
	})
	if seven == nil || month != nil {
		t.Errorf("seven %+v month %+v, want sevenDay and no month", seven, month)
	}
	if _, found, err := ReadCodexCapacity(dir); err != nil || found {
		t.Errorf("found=%v err=%v, want not found: neither fiveHour nor month", found, err)
	}
}
