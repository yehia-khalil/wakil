package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeOrca writes a stand-in CLI that records its argv and prints body.
// The repo already fakes `security` this way in four test files; this is the
// same idiom pointed at Orca, and it is what lets the runner's orchestration
// be exercised with no GUI session at all.
func fakeOrca(t *testing.T, body string, exitCode int) (exe, argvLog string) {
	t.Helper()
	dir := t.TempDir()
	argvLog = filepath.Join(dir, "argv")
	exe = filepath.Join(dir, "orca")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + argvLog + "\ncat <<'PAYLOAD'\n" + body + "\nPAYLOAD\nexit " + itoa(exitCode) + "\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe, argvLog
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	return string(rune('0' + n))
}

func TestGetAppStateAddressesByPIDAndNeverByBundleID(t *testing.T) {
	exe, argvLog := fakeOrca(t, stateJSON, 0)

	if _, err := (Orca{Exe: exe}).GetAppState(44187); err != nil {
		t.Fatalf("GetAppState: %v", err)
	}

	recorded, err := os.ReadFile(argvLog)
	if err != nil {
		t.Fatal(err)
	}
	argv := string(recorded)
	if !strings.Contains(argv, "pid:44187") {
		t.Fatalf("argv must address by pid, got:\n%s", argv)
	}
	if strings.Contains(argv, "dev.wakil.app") {
		t.Fatalf("argv must never carry the bundle id — with two instances running it "+
			"silently resolves to one of them. Got:\n%s", argv)
	}
	for _, want := range []string{"computer", "get-app-state", "--json"} {
		if !strings.Contains(argv, want) {
			t.Fatalf("argv missing %q:\n%s", want, argv)
		}
	}
}

func TestGetAppStateReturnsTheSnapshot(t *testing.T) {
	exe, _ := fakeOrca(t, stateJSON, 0)

	got, err := (Orca{Exe: exe}).GetAppState(44187)
	if err != nil {
		t.Fatalf("GetAppState: %v", err)
	}
	if !got.Snapshot.Contains("NOTHING BEHIND THIS PLANE") {
		t.Fatal("snapshot did not come back")
	}
}

// A structured failure keeps its code, so a caller can act on app_not_found
// differently from element_not_found.
func TestGetAppStateSurfacesAStructuredFailure(t *testing.T) {
	exe, _ := fakeOrca(t, staleIndexJSON, 1)

	got, err := (Orca{Exe: exe}).GetAppState(44187)
	if err != nil {
		t.Fatalf("a structured failure is a Response, not a transport error: %v", err)
	}
	if got.OK || got.Err == nil || got.Err.Code != "element_not_found" {
		t.Fatalf("got %+v", got)
	}
}

// The symlink failure prints on stdout and exits zero. It must be an error
// naming what was printed, never an empty-but-successful snapshot.
func TestGetAppStateRejectsTheSymlinkFailure(t *testing.T) {
	exe, _ := fakeOrca(t, "Unable to determine Orca.app path from symlink: /usr/local/bin/orca", 0)

	_, err := (Orca{Exe: exe}).GetAppState(44187)
	if err == nil {
		t.Fatal("want an error, got a usable response")
	}
	if !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("error must carry what orca printed, got %q", err)
	}
}
