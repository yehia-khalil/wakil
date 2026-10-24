package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// stubFixture is the smallest store `wakilcore.ListSessions` reads: an
// organisation, one Claude Code provider whose config directory holds the
// stub's script, and one active project rooted at projDir. HOME is resolved
// through EvalSymlinks because the stub records the cwd it runs in, which the
// kernel reports resolved (/private/var, not /var), as `claude` does.
func stubFixture(t *testing.T) (configDir, projDir string) {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolving the temp HOME: %v", err)
	}
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "stub-org")
	if err := wakilcore.CreateOrg("stub-org", wakilcore.Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	configDir = filepath.Join(home, ".claude-stub")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := wakilcore.AddProvider("stub-org", wakilcore.Provider{
		ID: "primary", Kind: wakilcore.ProviderKindClaudeCode, ConfigDir: configDir,
	}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}
	// The script the e2e checks run against, so a rule the test leans on is
	// the rule they lean on.
	script, err := os.ReadFile("script.json")
	if err != nil {
		t.Fatalf("reading the stub's script: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, driver.AgentScriptFile), script, 0o644); err != nil {
		t.Fatalf("laying down the script: %v", err)
	}

	projDir = filepath.Join(home, "proj")
	if err := os.MkdirAll(filepath.Join(projDir, ".wakil"), 0o755); err != nil {
		t.Fatalf("mkdir project: %v", err)
	}
	project, err := json.Marshal(wakilcore.Project{
		Name: "proj", Org: "stub-org", Roots: []wakilcore.Root{{Path: "."}},
		Environments: map[string]wakilcore.Environment{},
	})
	if err != nil {
		t.Fatalf("marshal project: %v", err)
	}
	projectPath := filepath.Join(projDir, ".wakil", "project.json")
	if err := os.WriteFile(projectPath, project, 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}
	if err := wakilcore.SaveRegistry("stub-org", map[string]wakilcore.ProjectEntry{"proj": {Path: projectPath}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := wakilcore.SetProjectChecked("proj"); err != nil {
		t.Fatalf("SetProjectChecked: %v", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	return configDir, projDir
}

// runStub runs one stub session in dir, as the window launches it: argv,
// then the operator's prompts as stream-json user frames on stdin.
func runStub(t *testing.T, dir string, args []string, prompts ...string) {
	t.Helper()
	t.Chdir(dir)
	in, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatalf("stdin: %v", err)
	}
	for _, prompt := range prompts {
		frame, _ := json.Marshal(map[string]interface{}{
			"type": "user",
			"message": map[string]interface{}{
				"role":    "user",
				"content": []interface{}{map[string]interface{}{"type": "text", "text": prompt}},
			},
		})
		in.Write(append(frame, '\n'))
	}
	if _, err := in.Seek(0, 0); err != nil {
		t.Fatalf("rewinding stdin: %v", err)
	}
	out, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatalf("stdout: %v", err)
	}
	if err := run(args, in, out); err != nil {
		t.Fatalf("the stub failed: %v", err)
	}
}

// The window's agent session: `--session-id` and an `--mcp-config` naming a
// socket. No rule used here calls the window, so the socket is never dialled.
func agentArgs(session string) []string {
	return []string{
		"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--session-id", session,
		"--mcp-config", `{"mcpServers":{"wakil":{"command":"wakil","args":["--mcp-shim","--socket","/nonexistent/wakil.sock"]}}}`,
	}
}

// TestTheStubWritesATranscriptListSessionsReads pins plan 3's ruling 2: a
// closed conversation can appear in the Landing's Continue only if its
// session left a transcript, so the stub writes one per session — its first
// prompt, as a `user` record carrying the cwd — where `claude` would, and
// `wakilcore.ListSessions` reads it back under the session's id with that
// prompt as its label.
func TestTheStubWritesATranscriptListSessionsReads(t *testing.T) {
	_, projDir := stubFixture(t)
	const session = "6f1d1c4e-9a7b-4c2e-8d55-1b2f3a4c5d6e"

	runStub(t, projDir, agentArgs(session), "thread turn one", "thread turn two")

	list, err := wakilcore.ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(list.Sessions) != 1 {
		t.Fatalf("ListSessions found %d session(s), want the stub's one: %+v", len(list.Sessions), list)
	}
	got := list.Sessions[0]
	if got.ID != session {
		t.Errorf("ID = %q, want the --session-id the window passed, %q", got.ID, session)
	}
	if got.FirstPrompt != "thread turn one" {
		t.Errorf("FirstPrompt = %q, want the session's first prompt, %q", got.FirstPrompt, "thread turn one")
	}
	if got.Cwd != projDir {
		t.Errorf("Cwd = %q, want the directory the stub ran in, %q", got.Cwd, projDir)
	}
	if list.Skipped != 0 {
		t.Errorf("Skipped = %d: the transcript could not be confirmed as this project's", list.Skipped)
	}
}
