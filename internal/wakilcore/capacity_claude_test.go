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
	if rec.FiveHour == nil || rec.FiveHour.PercentLeft != 95 || rec.FiveHour.ResetsAt != "2026-10-11T13:30:00Z" {
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
		"utilization 1.3":    {"anthropic-ratelimit-unified-5h-utilization": "1.3", "anthropic-ratelimit-unified-5h-reset": "1791725400"},
		"reset not a number": {"anthropic-ratelimit-unified-5h-utilization": "0.1", "anthropic-ratelimit-unified-5h-reset": "soon"},
		"no headers":         {},
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
		// Drain the body so the server notices the client hanging up.
		io.Copy(io.Discard, r.Body)
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
