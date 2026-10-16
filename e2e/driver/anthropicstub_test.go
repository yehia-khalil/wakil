package driver

import (
	"net/http"
	"strings"
	"testing"
)

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
