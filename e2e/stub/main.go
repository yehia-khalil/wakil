// Command wakil-e2e-agent is a deterministic agent: it stands in for
// `claude` behind the fixture's provider record, speaks the stream-json
// protocol the window already parses, and drives the window's own MCP surface
// exactly as a real agent would.
//
// **Why a stub rather than a real session.** A provider turn is
// non-deterministic, costs tokens and touches an account. What varies between
// runs — which prompt leads to which act — is the only part scripted here;
// the acts themselves go through the live socket and the answers carry what
// the window actually held.
//
// **Why it is seeded onto the provider record rather than put on `PATH`.**
// The record's `claudePath` is the absolute path the app launches
// (`ProviderCredentialsLookup`, and #238's rule that it is "the only absolute
// path the app has"), and `executableURL` does not search `PATH` at all. So
// this runs the production resolution path — listing, row, credentials,
// `buildLaunch` — and an unwired dependency still fails the check.
//
// **Why not `ANTHROPIC_BASE_URL` and a local endpoint.** That is what the
// ticket proposed, on Decision 16's measurement that `claude` honours it. The
// shipped code disagrees and the code is what ships: `buildLaunch` builds the
// child environment from a whitelist of exactly four keys, which is what makes
// `ANTHROPIC_API_KEY` unable to shadow a subscription by construction. Routing
// a stub in that way needs `baseURL`/`authToken` on the provider record and
// two more conditional keys — the fallback Decision 16 names and deliberately
// leaves unbuilt. Widening that whitelist for a test's convenience would spend
// a property the charter relies on.
//
// **It bypasses the MCP shim, deliberately.** The agent normally reaches the
// window through `--mcp-shim --socket <path>`, and this reads that same socket
// path out of the `--mcp-config` the window generated — so the config is still
// proved to name a reachable window — then dials it directly, with the
// driver's own tested client. What is not covered by this is the shim's own
// transport, and no check here claims otherwise.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/yehia-khalil/wakil/e2e/driver"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		// **The fault goes to stderr and the exit is non-zero**, which is what
		// the window reports as a failed turn. A stub that died quietly would
		// look like an agent with nothing to say.
		fmt.Fprintln(os.Stderr, "wakil-e2e-agent:", err)
		os.Exit(1)
	}
}

// openLog opens the stub's log, and never fails the run over it: a stub that
// refused to start because it could not write a diagnostic would be harder to
// diagnose than one with no diagnostics at all.
func openLog(configDir string) *os.File {
	file, err := os.OpenFile(filepath.Join(configDir, driver.AgentStubLogFile),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return os.NewFile(0, os.DevNull)
	}
	return file
}

func run(args []string, in *os.File, out *os.File) error {
	flags := parseFlags(args)
	configDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if configDir == "" {
		return fmt.Errorf("CLAUDE_CONFIG_DIR is unset, so there is no script to answer from — " +
			"the window sets it from the provider record on every launch")
	}
	// **Everything this agent does is logged beside its script.** A stub that
	// left no trace was diagnosable only by what the window showed, and when
	// the window showed nothing there was nothing to read at all — which is
	// how a turn that never started and a turn that answered wrongly became
	// the same observation.
	log := openLog(configDir)
	defer log.Close()
	script, err := driver.LoadAgentScript(filepath.Join(configDir, driver.AgentScriptFile))
	if err != nil {
		fmt.Fprintf(log, "script: %v\n", err)
		return err
	}
	fmt.Fprintf(log, "started: %d rule(s), argv %q\n", len(script.Rules), args)
	socket, err := socketFromMCPConfig(flags["--mcp-config"])
	if err != nil {
		fmt.Fprintf(log, "socket: %v\n", err)
		return err
	}
	fmt.Fprintf(log, "socket: %s\n", socket)

	writer := bufio.NewWriter(out)
	defer writer.Flush()
	// **`system/init` first, carrying the session id the window minted.**
	// `StreamJSON.decodeFrame` maps exactly that frame to `.systemInit`, and
	// the window matches it against the id it passed — an agent that answered
	// under another id would be a session nobody could resume.
	if err := emit(writer, map[string]interface{}{
		"type": "system", "subtype": "init", "session_id": flags["--session-id"],
	}); err != nil {
		return err
	}

	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 1<<20), 1<<24)
	recorded := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		prompt, ok := promptOf(line)
		if !ok {
			// Not a user turn — the window sends control frames too. Nothing
			// to answer, and answering anyway would put a turn in the thread
			// that nobody asked for.
			continue
		}
		fmt.Fprintf(log, "prompt: %q\n", prompt)
		// Before the answer, so a held turn's session is on disk while it is
		// held — as `claude`'s is from its first prompt.
		if !recorded {
			recorded = true
			if path, err := writeTranscript(configDir, flags["--session-id"], prompt); err != nil {
				fmt.Fprintf(log, "transcript: %v\n", err)
			} else if path != "" {
				fmt.Fprintf(log, "transcript: %s\n", path)
			}
		}
		// **What it answered, not that it answered. #284.** A turn that
		// answered the wrong thing and a turn whose answer never reached the
		// thread are the same word in this log, and they are opposite
		// findings: the first is the window reading back something the check
		// did not expect, the second is the thread dropping a reply it was
		// given. One measured failure was ambiguous between them for exactly
		// this reason.
		text, err := answer(writer, script, socket, prompt)
		if err != nil {
			fmt.Fprintf(log, "answer: %v\n", err)
			return err
		}
		fmt.Fprintf(log, "answered: %q\n", text)
	}
	return scanner.Err()
}

// writeTranscript leaves the session's transcript where `claude` would:
// `<CLAUDE_CONFIG_DIR>/projects/<encoded cwd>/<session id>.jsonl`, holding the
// first prompt as one `user` record that carries the cwd (plan 3, ruling 2).
//
// **Why the stub writes one at all.** Continue lists the sessions
// `wakilcore.ListSessions` finds, and it confirms each by the cwd a record
// carries (`firstCwd`) and labels it by its first prompt (`firstPrompt`). A
// stub that wrote nothing left every closed conversation out of Continue, so
// "Close moves it to Continue" was something no check could see.
//
// **One record, never rewritten.** It is what the listing reads and no more;
// the file is created exclusively, so a session id that already has a
// transcript keeps it. A session with no id (none passed) writes nothing.
// A failure is logged, not fatal: the turn itself is still the thing a check
// is about, and a check that reads Continue says what it found there.
func writeTranscript(configDir, session, prompt string) (string, error) {
	if session == "" {
		return "", nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("no cwd to record: %w", err)
	}
	dir := filepath.Join(configDir, "projects", wakilcore.EncodeRootPath(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, session+".jsonl")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if os.IsExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer file.Close()
	record, err := json.Marshal(map[string]interface{}{
		"type": "user", "cwd": cwd, "sessionId": session,
		"message": map[string]interface{}{
			"role":    "user",
			"content": []interface{}{map[string]interface{}{"type": "text", "text": prompt}},
		},
	})
	if err != nil {
		return "", err
	}
	if _, err := file.Write(append(record, '\n')); err != nil {
		return "", err
	}
	return path, nil
}

// answer performs one turn: find the rule, do what it says, say what happened.
//
// It returns the text it emitted, so the caller can write it down. Every
// return here is a turn the window was given something for; what that
// something was is the fact a red check needs.
func answer(writer *bufio.Writer, script driver.AgentScript, socket, prompt string) (string, error) {
	rule, found := script.Rule(prompt)
	if !found {
		// **An unmatched prompt is an error turn, not a polite refusal.** A
		// stub that improvised would let a check whose prompt had drifted pass
		// on an answer that proves nothing.
		text := fmt.Sprintf(
			"no rule in %s matches %q, so this agent has nothing to do — the check and the "+
				"script have drifted apart", driver.AgentScriptFile, prompt)
		return text, emitResult(writer, true, text)
	}

	// A held turn stays in flight until the check releases it (AgentRule.Hold):
	// that is what keeps an agent working while the operator is elsewhere. It
	// holds BEFORE the call, so the call is made after the operator has moved:
	// a call that lands in the place the agent started in, and not the one on
	// screen, is then something a check can see.
	if rule.Hold != "" {
		if err := awaitRelease(rule.Hold); err != nil {
			return err.Error(), emitResult(writer, true, err.Error())
		}
	}

	value := ""
	if rule.Call != nil || rule.Read != nil {
		client, err := driver.DialMCPPath(socket, 10*time.Second)
		if err != nil {
			return "", fmt.Errorf("the window's MCP socket could not be reached: %w", err)
		}
		defer client.Close()
		if _, err := client.Initialize(); err != nil {
			return "", fmt.Errorf("the window's MCP socket refused the handshake: %w", err)
		}
		if rule.Call != nil {
			var echo *echoedCall
			if rule.Call.Echo {
				echo = &echoedCall{writer: writer, id: fmt.Sprintf("toolu_e2e_%d", time.Now().UnixNano())}
				if err := echo.use(rule.Call); err != nil {
					return "", err
				}
			}
			result, err := client.Call(rule.Call.Action, rule.Call.Params)
			if err != nil {
				if echo != nil {
					if werr := echo.result(strings.TrimPrefix(err.Error(), refusedPrefix), true); werr != nil {
						return "", werr
					}
				}
				text := fmt.Sprintf("%s was refused: %v", rule.Call.Action, err)
				return text, emitResult(writer, true, text)
			}
			if echo != nil {
				if err := echo.result(result.Text, false); err != nil {
					return "", err
				}
			}
		}
		if rule.Read != nil {
			value, err = readField(client, *rule.Read)
			if err != nil {
				return err.Error(), emitResult(writer, true, err.Error())
			}
		}
	}

	// Frames a real turn carries besides its answer, before the answer as
	// `claude` sends them: the window reads a `rate_limit_event` mid-turn.
	for _, frame := range rule.Emit {
		if err := emit(writer, frame); err != nil {
			return "", err
		}
	}

	text := rule.Render(value)
	if text == "" {
		text = "done"
	}
	if err := emit(writer, map[string]interface{}{
		"type": "assistant",
		"message": map[string]interface{}{
			"role":    "assistant",
			"content": []interface{}{map[string]interface{}{"type": "text", "text": text}},
		},
	}); err != nil {
		return text, err
	}
	return text, emitResult(writer, false, text)
}

// awaitRelease waits for ~/<name> to exist — the file a check makes with
// `touch ~/<name>` in a terminal — up to driver.HoldCeiling.
func awaitRelease(name string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("a held turn has no HOME to be released in: %w", err)
	}
	release := filepath.Join(home, name)
	deadline := time.Now().Add(driver.HoldCeiling)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(release); err == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("the turn was held for %s and %s never appeared, so nothing released it",
		driver.HoldCeiling, release)
}

// readField reads one pane field through the same path a check's `expect`
// takes, so the agent's answer is what the window holds rather than what the
// script hoped it would hold.
func readField(client *driver.MCP, read driver.AgentRead) (string, error) {
	result, err := client.ReadPane(read.Pane)
	if err != nil {
		return "", fmt.Errorf("pane %q could not be read: %w", read.Pane, err)
	}
	var fields map[string]interface{}
	if err := json.Unmarshal(driver.ResultBody(result), &fields); err != nil {
		return "", fmt.Errorf("pane %q answered something that is not an object: %w", read.Pane, err)
	}
	value, err := driver.PanePath(fields, read.Field)
	if err != nil {
		return "", fmt.Errorf("pane %q: %w", read.Pane, err)
	}
	return fmt.Sprintf("%v", value), nil
}

// promptOf pulls the operator's text out of one stream-json user frame.
//
// It reads the shape `ClaudeCodeCLIHarness.encodeUserMessage` writes, and
// nothing else: a frame it cannot read is not a prompt, and guessing at one
// would answer a turn nobody sent.
func promptOf(line string) (string, bool) {
	var frame struct {
		Type    string `json:"type"`
		Message struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(line), &frame); err != nil || frame.Type != "user" {
		return "", false
	}
	var parts []string
	for _, block := range frame.Message.Content {
		if block.Type == "text" && block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, "\n"), true
}

// socketFromMCPConfig finds the window's socket in the config the window
// generated.
//
// **Read out of the config rather than guessed at.** That is what makes this
// prove something about production: `agentMCPConfigJSON` is what hands the
// agent its only route back into the window, and a config naming a socket
// nothing listens on fails here rather than silently answering from memory.
func socketFromMCPConfig(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("no --mcp-config was passed, so this agent has no route back into " +
			"the window it is answering for")
	}
	var config struct {
		Servers map[string]struct {
			Args []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return "", fmt.Errorf("the --mcp-config could not be read: %w", err)
	}
	for _, server := range config.Servers {
		for index, arg := range server.Args {
			if arg == "--socket" && index+1 < len(server.Args) {
				return server.Args[index+1], nil
			}
		}
	}
	return "", fmt.Errorf("no server in the --mcp-config carries a --socket, so the window " +
		"published no route back to itself")
}

// parseFlags reads the `--name value` pairs this stub cares about out of the
// argv `buildLaunch` produces. Everything else is ignored on purpose: the argv
// is production's and will grow, and a stub that refused an unknown flag would
// fail the day it did.
func parseFlags(args []string) map[string]string {
	flags := map[string]string{}
	for index := 0; index < len(args)-1; index++ {
		switch args[index] {
		case "--mcp-config", "--session-id":
			flags[args[index]] = args[index+1]
		}
	}
	return flags
}

func emit(writer *bufio.Writer, frame map[string]interface{}) error {
	encoded, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("encoding a frame: %w", err)
	}
	if _, err := writer.Write(append(encoded, '\n')); err != nil {
		return err
	}
	// **Flushed per frame.** The window reads this as a stream and shows a
	// turn as it arrives; a buffered answer would land all at once at exit,
	// which is a different thing from what production does.
	return writer.Flush()
}

func emitResult(writer *bufio.Writer, isError bool, text string) error {
	return emit(writer, map[string]interface{}{
		"type": "result", "subtype": "success", "is_error": isError, "result": text,
	})
}

// refusedPrefix is what ParseToolResult puts before a refusal's text; the echoed result carries
// the text alone, as the window handed it over.
const refusedPrefix = "the action was refused: "

// echoedCall writes an action's `tool_use` and `tool_result` into the stream, as a real agent's
// turn carries them, so the thread has the rows a browser tool produces (AgentCall.Echo).
type echoedCall struct {
	writer *bufio.Writer
	id     string
}

// use is the assistant's `tool_use`, named as the MCP server names its tools: `mcp__wakil__<action>`.
func (e *echoedCall) use(call *driver.AgentCall) error {
	input := call.Params
	if input == nil {
		input = map[string]interface{}{}
	}
	return emit(e.writer, map[string]interface{}{
		"type": "assistant",
		"message": map[string]interface{}{
			"role": "assistant",
			"content": []interface{}{map[string]interface{}{
				"type": "tool_use", "id": e.id, "name": "mcp__wakil__" + call.Action, "input": input,
			}},
		},
	})
}

// result is the user's `tool_result` for it: the call's text content, flagged on a refusal.
func (e *echoedCall) result(text string, isError bool) error {
	block := map[string]interface{}{
		"type": "tool_result", "tool_use_id": e.id,
		"content": []interface{}{map[string]interface{}{"type": "text", "text": text}},
	}
	if isError {
		block["is_error"] = true
	}
	return emit(e.writer, map[string]interface{}{
		"type":    "user",
		"message": map[string]interface{}{"role": "user", "content": []interface{}{block}},
	})
}
