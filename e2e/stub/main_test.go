package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
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
func runStub(t *testing.T, dir string, args []string, prompts ...string) string {
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
	written, err := os.ReadFile(out.Name())
	if err != nil {
		t.Fatalf("reading the stub's output: %v", err)
	}
	return string(written)
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

// fakeWindow answers the stub's MCP calls on a unix socket: `initialize` with an empty result,
// and every `tools/call` with the text it is given, as an error when refuse is set. It records
// the actions it was asked for. Returns the socket's path.
func fakeWindow(t *testing.T, text string, refuse bool) (string, *[]string) {
	t.Helper()
	dir, err := os.MkdirTemp("", "w")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "s")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	var calls []string
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				for {
					line, err := reader.ReadBytes('\n')
					if err != nil {
						return
					}
					var request struct {
						ID     int    `json:"id"`
						Method string `json:"method"`
						Params struct {
							Name string `json:"name"`
						} `json:"params"`
					}
					if json.Unmarshal(line, &request) != nil {
						return
					}
					result := map[string]interface{}{"serverInfo": map[string]interface{}{"name": "fake"}}
					if request.Method == "tools/call" {
						calls = append(calls, request.Params.Name)
						result = map[string]interface{}{
							"content": []interface{}{map[string]interface{}{"type": "text", "text": text}},
							"isError": refuse,
						}
					}
					reply, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": request.ID, "result": result})
					conn.Write(append(reply, '\n'))
				}
			}()
		}
	}()
	return path, &calls
}

func argsFor(session, socket string) []string {
	return []string{
		"-p", "--session-id", session,
		"--mcp-config", `{"mcpServers":{"wakil":{"command":"wakil","args":["--mcp-shim","--socket","` + socket + `"]}}}`,
	}
}

// frames decodes the stub's stdout, one JSON object a line.
func frames(t *testing.T, out string) []map[string]interface{} {
	t.Helper()
	var all []map[string]interface{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var frame map[string]interface{}
		if err := json.Unmarshal([]byte(line), &frame); err != nil {
			t.Fatalf("a frame is not JSON: %q", line)
		}
		all = append(all, frame)
	}
	return all
}

// block returns the first content block of a frame's message.
func block(frame map[string]interface{}) map[string]interface{} {
	content, _ := frame["message"].(map[string]interface{})["content"].([]interface{})
	if len(content) == 0 {
		return nil
	}
	first, _ := content[0].(map[string]interface{})
	return first
}

// TestAnEchoedCallWritesToolUseAndResult — a rule with `echo` puts the call in the stream as a
// real agent's turn would: the `tool_use` before the call, the `tool_result` (the call's content,
// verbatim) after it, and `is_error` on a refusal.
func TestAnEchoedCallWritesToolUseAndResult(t *testing.T) {
	_, projDir := stubFixture(t)

	socket, calls := fakeWindow(t, "typed into \"Guest name\"", false)
	out := frames(t, runStub(t, projDir, argsFor("echo-ok", socket), "fill the guest name"))
	// system/init, tool_use, tool_result, the reply, the result.
	if len(out) != 5 {
		t.Fatalf("got %d frames, want 5: %v", len(out), out)
	}
	use := block(out[1])
	if out[1]["type"] != "assistant" || use["type"] != "tool_use" || use["name"] != "mcp__wakil__browser_type" {
		t.Errorf("frame 2 = %v, want an assistant tool_use of mcp__wakil__browser_type", out[1])
	}
	input, _ := use["input"].(map[string]interface{})
	if input["ref"] != "e1" || input["text"] != "Ada Lovelace" || input["pane"] != "browser-1" {
		t.Errorf("the tool_use input = %v, want the rule's params", input)
	}
	result := block(out[2])
	if out[2]["type"] != "user" || result["type"] != "tool_result" || result["tool_use_id"] != use["id"] {
		t.Errorf("frame 3 = %v, want a user tool_result for %v", out[2], use["id"])
	}
	if _, flagged := result["is_error"]; flagged {
		t.Errorf("a call that ran carries is_error: %v", result)
	}
	content, _ := result["content"].([]interface{})
	if len(content) != 1 || content[0].(map[string]interface{})["text"] != "typed into \"Guest name\"" {
		t.Errorf("the tool_result's content = %v, want the call's text verbatim", content)
	}
	if out[3]["type"] != "assistant" || block(out[3])["text"] != "typed the guest name" {
		t.Errorf("frame 4 = %v, want the reply after the result", out[3])
	}
	if len(*calls) != 1 || (*calls)[0] != "browser_type" {
		t.Errorf("the window was asked for %v, want one browser_type", *calls)
	}

	refusedSocket, _ := fakeWindow(t, "browser_click: read the page first (browser_read_page) — refs come from the last read.", true)
	refused := frames(t, runStub(t, projDir, argsFor("echo-no", refusedSocket), "confirm the booking"))
	if len(refused) != 4 {
		t.Fatalf("got %d frames for a refusal, want 4 (init, tool_use, tool_result, result): %v", len(refused), refused)
	}
	refusal := block(refused[2])
	if refusal["is_error"] != true {
		t.Errorf("a refused call's tool_result = %v, want is_error true", refusal)
	}
	text := refusal["content"].([]interface{})[0].(map[string]interface{})["text"]
	if text != "browser_click: read the page first (browser_read_page) — refs come from the last read." {
		t.Errorf("the refusal's content = %q, want the window's text without the driver's prefix", text)
	}
	if refused[3]["is_error"] != true ||
		refused[3]["result"] != "browser_click was refused: read the page first (browser_read_page) — refs come from the last read." {
		t.Errorf("the turn's result = %v, want `<action> was refused: <the window's reason>`", refused[3])
	}
}

// TestACallWithoutEchoWritesNoToolFrames — every rule written before the browser's still calls the
// window and says nothing of it: no tool_use, no tool_result.
func TestACallWithoutEchoWritesNoToolFrames(t *testing.T) {
	_, projDir := stubFixture(t)
	socket, calls := fakeWindow(t, "opened", false)
	out := runStub(t, projDir, argsFor("echo-off", socket), "start the second agent in qa")
	if len(*calls) != 1 {
		t.Fatalf("the window was asked %d times, want 1", len(*calls))
	}
	if strings.Contains(out, "tool_use") || strings.Contains(out, "tool_result") {
		t.Errorf("a call without echo wrote tool frames:\n%s", out)
	}
	if got := len(frames(t, out)); got != 3 {
		t.Errorf("got %d frames, want 3 (init, reply, result)", got)
	}
}
