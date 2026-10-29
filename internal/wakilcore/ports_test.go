package wakilcore

import (
	"net"
	"reflect"
	"strings"
	"testing"
)

func probeOf(busy ...int) PortProbe {
	set := map[int]bool{}
	for _, p := range busy {
		set[p] = true
	}
	return func(p int) bool { return set[p] }
}

func TestAllocatePortBlocksFromTheStartSkippingListening(t *testing.T) {
	got, err := AllocatePortBlocks(nil, []string{"ws/api", "ws/web", "ws/core"}, probeOf(41213, 41229))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{"ws/api": 41200, "ws/web": 41230, "ws/core": 41240}
	if !reflect.DeepEqual(got.Blocks, want) {
		t.Fatalf("blocks %v, want %v", got.Blocks, want)
	}
	if !reflect.DeepEqual(got.Taken, []int{41213, 41229}) {
		t.Fatalf("taken %v", got.Taken)
	}
}

func TestAllocatePortBlocksIsStableAndFillsGaps(t *testing.T) {
	existing := map[string]int{"a": 41200, "c": 41220}
	// a's own app is listening on its block: it keeps it anyway.
	got, err := AllocatePortBlocks(existing, []string{"a", "b", "c", "d"}, probeOf(41200))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{"a": 41200, "b": 41210, "c": 41220, "d": 41230}
	if !reflect.DeepEqual(got.Blocks, want) {
		t.Fatalf("blocks %v, want %v", got.Blocks, want)
	}
}

func TestAllocatePortBlocksRefusesBadExistingAndExhaustion(t *testing.T) {
	if _, err := AllocatePortBlocks(map[string]int{"a": 41205}, nil, probeOf()); err == nil {
		t.Fatal("an unaligned block must be refused")
	}
	if _, err := AllocatePortBlocks(map[string]int{"a": 41200, "b": 41200}, nil, probeOf()); err == nil {
		t.Fatal("a shared block must be refused")
	}
	all := func(int) bool { return true }
	_, err := AllocatePortBlocks(nil, []string{"x"}, all)
	if err == nil || !strings.HasPrefix(err.Error(), "No free port block for x:") || !strings.Contains(err.Error(), "ports in use, 41200 to 65529") {
		t.Fatalf("exhaustion: %v", err)
	}
}

func TestListeningProbeSeesARealListener(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer l.Close()
	port := l.Addr().(*net.TCPAddr).Port
	if !ListeningProbe(port) {
		t.Fatalf("port %d is listening", port)
	}
	l.Close()
	if ListeningProbe(port) {
		t.Fatalf("port %d is free again", port)
	}
}

func TestRepoEnvNameAndComposeProjectName(t *testing.T) {
	for in, want := range map[string]string{"api": "API", "ms-reservations": "MS_RESERVATIONS", "web.app": "WEB_APP", "2fa": "_2FA", "--": "_"} {
		if got := RepoEnvName(in); got != want {
			t.Errorf("RepoEnvName(%q) = %q, want %q", in, got, want)
		}
	}
	if got := ComposeProjectName("INI-142-login", "api.v2"); got != "ini-142-login-api-v2" {
		t.Errorf("compose name %q", got)
	}
}

func TestWakilEnvExportsTheBlockAndTheOtherRepos(t *testing.T) {
	env, err := WakilEnv(RunContext{Workspace: "ini-142", Repo: "web", Checkouts: []CheckoutPorts{
		{Repo: "api", Path: "/w/api", Port: 41200},
		{Repo: "web", Path: "/w/web", Port: 41210},
		{Repo: "core", Path: "/main/core"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{
		"WAKIL_WORKSPACE": "ini-142", "WAKIL_REPO": "web", "WAKIL_DIR": "/w/web",
		"WAKIL_PORT": "41210", "WAKIL_PORT_1": "41211", "WAKIL_PORT_9": "41219",
		"WAKIL_PORT_API": "41200", "WAKIL_PORT_WEB": "41210", "WAKIL_DIR_CORE": "/main/core",
		"COMPOSE_PROJECT_NAME": "ini-142-web",
	} {
		if env[k] != want {
			t.Errorf("%s = %q, want %q", k, env[k], want)
		}
	}
	if _, ok := env["WAKIL_PORT_CORE"]; ok {
		t.Error("a repo with no checkout has no port")
	}
	if _, ok := env["WAKIL_PORT_10"]; ok {
		t.Error("the block is ten ports")
	}
}

func TestWakilEnvRefusals(t *testing.T) {
	_, err := WakilEnv(RunContext{Workspace: "w", Repo: "a-b", Checkouts: []CheckoutPorts{{Repo: "a-b", Port: 41200}, {Repo: "a_b", Port: 41210}}})
	if err == nil || !strings.Contains(err.Error(), "both become WAKIL_PORT_A_B") {
		t.Fatalf("clash: %v", err)
	}
	if _, err := WakilEnv(RunContext{Workspace: "w", Repo: "x"}); err == nil || !strings.Contains(err.Error(), "has no checkout of x") {
		t.Fatalf("missing: %v", err)
	}
	if _, err := WakilEnv(RunContext{Workspace: "w", Repo: "x", Checkouts: []CheckoutPorts{{Repo: "x"}}}); err == nil || !strings.Contains(err.Error(), "no port block") {
		t.Fatalf("no port: %v", err)
	}
}

func TestExpandWakil(t *testing.T) {
	vars := map[string]string{"WAKIL_PORT": "41200", "WAKIL_PORT_API": "41210", "WAKIL_REPO": "web"}
	for in, want := range map[string]string{
		"$WAKIL_PORT":                        "41200",
		"http://localhost:${WAKIL_PORT_API}": "http://localhost:41210",
		"$HOME/x $$WAKIL_PORT":               "$HOME/x $WAKIL_PORT",
		"plain":                              "plain",
	} {
		got, err := ExpandWakil(in, vars)
		if err != nil || got != want {
			t.Errorf("ExpandWakil(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	_, err := ExpandWakil("http://localhost:$WAKIL_PORT_WEBB", vars)
	if err == nil || !strings.Contains(err.Error(), "uses $WAKIL_PORT_WEBB, which this workspace does not have") {
		t.Fatalf("unknown: %v", err)
	}
	_, err = ExpandWakil("$WAKIL_WORKSPACES", vars)
	if err == nil || !strings.Contains(err.Error(), "$WAKIL_PORT, $WAKIL_REPO") {
		t.Fatalf("unknown plain: %v", err)
	}
}
