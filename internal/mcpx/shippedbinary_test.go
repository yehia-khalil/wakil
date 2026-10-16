package mcpx_test

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestShippedWakilDBPreservesLargeIntegers is #242's own measurement, run
// against the artefact that ships rather than against a test binary.
//
// It builds nothing: it drives bin/wakil-db over a real stdio pipe, exactly
// as the app does, and asserts on the bytes that come off that pipe. A
// compile-time-only change still has to be measured here, because "the fix
// is in the code" and "the fix is in the binary the app launches" are
// different claims.
//
// SKIPPED unless bin/wakil-db exists — run `make build` first. It never
// touches the login keychain: WAKIL_KEYCHAIN (#301, Decision 33) points
// every `security` call at a throwaway keychain file, so no authorization
// dialog can appear.
func TestShippedWakilDBPreservesLargeIntegers(t *testing.T) {
	repoRoot, err := filepath.Abs("../..")
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	bin := filepath.Join(repoRoot, "bin", "wakil-db")
	if _, err := os.Stat(bin); err != nil {
		t.Skipf("bin/wakil-db not built (run `make build`): %v", err)
	}

	sqlite3, err := exec.LookPath("sqlite3")
	if err != nil {
		t.Skipf("sqlite3 not on PATH: %v", err)
	}

	home := t.TempDir()
	dbPath := filepath.Join(home, "probe.db")
	const (
		idA = "9007199254740993" // 2^53 + 1
		idB = "9007199254740995" // 2^53 + 3
	)
	seed := "CREATE TABLE bookings (id BIGINT PRIMARY KEY, guest TEXT);" +
		"INSERT INTO bookings VALUES (" + idA + ",'Ada'),(" + idB + ",'Grace');"
	if out, err := exec.Command(sqlite3, dbPath, seed).CombinedOutput(); err != nil {
		t.Fatalf("seed sqlite: %v\n%s", err, out)
	}

	// The project the server will resolve against. A sqlite database needs
	// no credential, so nothing here reaches a keychain at all.
	projDir := filepath.Join(home, "proj", ".wakil")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	project := `{"name":"proj","org":"initech","roots":[{"path":"."}],"environments":{` +
		`"staging":{"databases":[{"name":"main","driver":"sqlite","ref":"db:probe"}]}}}`
	projPath := filepath.Join(projDir, "project.json")
	if err := os.WriteFile(projPath, []byte(project), 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}

	orgDir := filepath.Join(home, ".wakil", "orgs", "initech")
	if err := os.MkdirAll(orgDir, 0o755); err != nil {
		t.Fatalf("mkdir org: %v", err)
	}
	// SaveRegistry marshals map[string]ProjectEntry directly — the file is
	// the bare map, not wrapped in a "projects" key.
	registry := `{"proj":{"path":"` + projPath + `"}}`
	if err := os.WriteFile(filepath.Join(orgDir, "projects.json"), []byte(registry), 0o644); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	// active.Project stores the project.json PATH, not the project's name
	// (see wakilcore.Resolve).
	active := `{"project":"` + projPath + `","environment":"staging"}`
	if err := os.WriteFile(filepath.Join(orgDir, "active.json"), []byte(active), 0o644); err != nil {
		t.Fatalf("write active: %v", err)
	}

	// A throwaway keychain, so nothing here can reach — or prompt for —
	// the operator's login keychain. This is what #301/Decision 33 bought:
	// WAKIL_KEYCHAIN names the keychain FILE every `security` call in
	// wakilcore is scoped to, read in a shipped binary with no test gate.
	keychain := filepath.Join(home, "probe.keychain-db")
	env := append(os.Environ(),
		"HOME="+home,
		"WAKIL_ORG=initech",
		"WAKIL_KEYCHAIN="+keychain,
	)
	if out, err := exec.Command("security", "create-keychain", "-p", "probe", keychain).CombinedOutput(); err != nil {
		t.Skipf("cannot create a throwaway keychain: %v\n%s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("security", "delete-keychain", keychain).Run() })
	if out, err := exec.Command("security", "unlock-keychain", "-p", "probe", keychain).CombinedOutput(); err != nil {
		t.Fatalf("unlock keychain: %v\n%s", err, out)
	}

	setDB := exec.Command(filepath.Join(repoRoot, "bin", "wakil"),
		"secrets", "set-db", "db:probe", "--driver", "sqlite", "--db", dbPath)
	setDB.Env = env
	if out, err := setDB.CombinedOutput(); err != nil {
		t.Fatalf("store the sqlite dsn: %v\n%s", err, out)
	}

	cmd := exec.Command(bin)
	cmd.Env = env
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s: %v", bin, err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})

	send := func(v any) {
		t.Helper()
		raw, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if _, err := stdin.Write(append(raw, '\n')); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	lines := bufio.NewScanner(stdout)
	lines.Buffer(make([]byte, 0, 1<<20), 1<<20)
	type result struct {
		line string
		ok   bool
	}
	next := make(chan result, 16)
	go func() {
		for lines.Scan() {
			next <- result{line: lines.Text(), ok: true}
		}
		close(next)
	}()
	readLine := func() string {
		t.Helper()
		select {
		case r, open := <-next:
			if !open {
				t.Fatalf("server closed stdout")
			}
			return r.line
		case <-time.After(20 * time.Second):
			t.Fatalf("timed out waiting for a response line")
			return ""
		}
	}

	send(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize",
		"params": map[string]any{
			"protocolVersion": "2025-06-18",
			"capabilities":    map[string]any{},
			"clientInfo":      map[string]any{"name": "probe-242", "version": "0.0.0"},
		},
	})
	readLine()
	send(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})

	send(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": map[string]any{
			"name": "query",
			"arguments": map[string]any{
				"database": "main",
				"query":    "SELECT id, guest FROM bookings ORDER BY id",
			},
		},
	})

	var line string
	for {
		line = readLine()
		if strings.Contains(line, `"id":2`) {
			break
		}
	}
	t.Logf("bytes off the shipped binary's pipe:\n%s", line)

	if strings.Contains(line, `"isError":true`) || strings.Contains(line, `"error"`) {
		t.Fatalf("query failed; fixture is wrong, not the SDK:\n%s", line)
	}
	for _, want := range []string{idA, idB} {
		if !strings.Contains(line, want) {
			t.Errorf("response does not contain %s — lost before it reached the pipe", want)
		}
	}
	for _, lossy := range []string{"9007199254740992", "9007199254740996"} {
		if strings.Contains(line, lossy) {
			t.Errorf("response contains %s: the integer was round-tripped through float64", lossy)
		}
	}
}
