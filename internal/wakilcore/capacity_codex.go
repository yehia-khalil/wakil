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

func codexWindow(m map[string]any) *CapacityWindow {
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

// codexWindows assigns each window by its window_minutes: 300 is the 5-hour
// slot, 10080 the 7-day slot, 43200 (30 days) the month slot, and any other length
// is dropped. Without window_minutes the key decides: primary is the 5-hour
// window and secondary the 7-day one, as older logs had them. Both keys are
// candidates for either slot, so a weekly window reported as primary still
// lands in the 7-day slot.
func codexWindows(rl map[string]any) (five, seven, month *CapacityWindow) {
	for _, key := range []string{"primary", "secondary"} {
		m, ok := rl[key].(map[string]any)
		if !ok {
			continue
		}
		w := codexWindow(m)
		if w == nil {
			continue
		}
		mins, hasMins := m["window_minutes"].(float64)
		switch {
		case !hasMins && key == "primary", hasMins && mins == 300:
			if five == nil {
				five = w
			}
		case !hasMins && key == "secondary", hasMins && mins == 10080:
			if seven == nil {
				seven = w
			}
		case hasMins && mins == 43200:
			if month == nil {
				month = w
			}
		}
	}
	if five != nil || seven != nil {
		month = nil // the month slot exists only when neither of the others does
	}
	return five, seven, month
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
			five, seven, month := codexWindows(findRateLimits(ev, 0))
			if five == nil && month == nil {
				continue
			}
			r := CapacityReading{Kind: ProviderKindCodex, State: CapacityRead, FiveHour: five, SevenDay: seven, Month: month}
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
