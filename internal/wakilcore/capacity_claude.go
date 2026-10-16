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
