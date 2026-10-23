package wakilcore

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func deviceServer(t *testing.T, answers ...string) *httptest.Server {
	t.Helper()
	var polls int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/code") {
			json.NewEncoder(w).Encode(map[string]any{"device_code": "dev-1", "user_code": "WDJB-MJHT",
				"verification_uri": "https://github.com/login/device", "interval": 0, "expires_in": 900})
			return
		}
		i := int(atomic.AddInt32(&polls, 1)) - 1
		if i >= len(answers) {
			i = len(answers) - 1
		}
		w.Write([]byte(answers[i]))
	}))
}

func withDevice(t *testing.T, srv *httptest.Server) {
	t.Helper()
	old, oldID := deviceEndpoints["github"], GitHubClientID
	deviceEndpoints["github"] = deviceEndpoint{Code: srv.URL + "/code", Token: srv.URL + "/token"}
	GitHubClientID = "client-1"
	t.Cleanup(func() { deviceEndpoints["github"], GitHubClientID = old, oldID })
}

func TestDeviceFlowPollsUntilApproved(t *testing.T) {
	srv := deviceServer(t, `{"error":"authorization_pending"}`, `{"access_token":"tok-7","token_type":"bearer"}`)
	defer srv.Close()
	withDevice(t, srv)
	code, err := DeviceStart(context.Background(), "github")
	if err != nil || code.UserCode != "WDJB-MJHT" || code.VerificationURI != "https://github.com/login/device" {
		t.Fatalf("code %+v err %v", code, err)
	}
	token, pending, err := DevicePoll(context.Background(), "github", code.DeviceCode)
	if err != nil || !pending || token != "" {
		t.Fatalf("first poll: %q %v %v", token, pending, err)
	}
	token, pending, err = DevicePoll(context.Background(), "github", code.DeviceCode)
	if err != nil || pending || token != "tok-7" {
		t.Fatalf("second poll: %q %v %v", token, pending, err)
	}
}

func TestDeviceFlowSlowDownIsStillPending(t *testing.T) {
	srv := deviceServer(t, `{"error":"slow_down","interval":10}`)
	defer srv.Close()
	withDevice(t, srv)
	_, pending, err := DevicePoll(context.Background(), "github", "dev-1")
	if err != nil || !pending {
		t.Fatalf("pending %v err %v", pending, err)
	}
}

func TestDeviceFlowExpiredOrDeniedSaysSo(t *testing.T) {
	for answer, want := range map[string]string{
		`{"error":"expired_token"}`: "the code expired — Try again",
		`{"error":"access_denied"}`: "the sign-in was declined",
	} {
		srv := deviceServer(t, answer)
		withDevice(t, srv)
		_, _, err := DevicePoll(context.Background(), "github", "dev-1")
		srv.Close()
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", answer, err)
		}
	}
}

func TestSignInNotOfferedWithoutAClientID(t *testing.T) {
	old := GitHubClientID
	GitHubClientID = ""
	defer func() { GitHubClientID = old }()
	if _, err := DeviceStart(context.Background(), "github"); err == nil || !strings.Contains(err.Error(), "Sign in is not set up") {
		t.Fatalf("err = %v", err)
	}
	if SignInProviders()["github"] {
		t.Fatal("github offered without a client id")
	}
}

func TestGhLoginsParsesAuthStatus(t *testing.T) {
	text := "github.com\n  ✓ Logged in to github.com account dev-initech (keyring)\n  - Active account: true\n" +
		"  ✓ Logged in to github.com account dev-umbrella (keyring)\n  - Active account: false\n"
	got := parseGhLogins(text)
	if len(got) != 2 || got[0] != (GhLogin{Host: "github.com", User: "dev-initech"}) || got[1].User != "dev-umbrella" {
		t.Fatalf("logins = %+v", got)
	}
}
