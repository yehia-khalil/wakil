package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentScriptFile is what the stub agent reads its answers from, inside the
// provider's config directory.
//
// **The config directory, because it is the only channel that reaches the
// child.** `buildLaunch` constructs the agent's environment from a whitelist
// of exactly four keys — `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`,
// `HOME`, `PATH` — which is what makes `ANTHROPIC_API_KEY` unable to shadow a
// subscription by construction (Decision 16). A stub selected by an
// environment variable of its own would need that whitelist widened, which
// would weaken the property for a test's convenience.
const AgentScriptFile = "e2e-agent-script.json"

// AgentCall is one action the scripted agent takes before answering, through
// the window's own MCP surface — the same surface a real agent has.
type AgentCall struct {
	Action string                 `json:"action"`
	Params map[string]interface{} `json:"params,omitempty"`
}

// AgentRead is one pane field the scripted agent looks at, so its answer can
// carry what the window actually held rather than a canned string.
//
// **That is the difference between this stub and a mock.** A check asking
// *what did my last command print* must fail when the pane stops being
// readable, and an answer written into the script would pass whatever the
// window contained.
type AgentRead struct {
	Pane  string `json:"pane"`
	Field string `json:"field"`
}

// AgentRule is one prompt the stub knows how to answer.
type AgentRule struct {
	// Match is a case-folded substring of the prompt. A check types a
	// sentence at a composer, and a trigger that had to equal it would be one
	// nobody could keep in step with the check.
	Match string     `json:"match"`
	Call  *AgentCall `json:"call,omitempty"`
	Read  *AgentRead `json:"read,omitempty"`
	Reply string     `json:"reply,omitempty"`
	// Emit is stream-json frames written verbatim before the reply, for a
	// frame a real `claude` sends that is not an answer — a
	// `rate_limit_event`, which provider capacity reads from every turn.
	// Each must carry its own string `type`, the field `StreamJSON` decodes on.
	Emit []map[string]interface{} `json:"emit,omitempty"`
}

// ValuePlaceholder is what a reply interpolates the read value into.
const ValuePlaceholder = "{value}"

// Render fills the reply's placeholder with what was read.
func (r AgentRule) Render(value string) string {
	return strings.ReplaceAll(r.Reply, ValuePlaceholder, value)
}

// AgentScript is everything the stub agent can answer.
//
// **A deterministic agent, not a mock of one.** It drives the real MCP
// surface and reads the real pane; what is scripted is which prompt leads to
// which act, which is the part a live provider would make non-deterministic,
// cost tokens, and touch an account for.
type AgentScript struct {
	Rules []AgentRule `json:"rules"`
}

// LoadAgentScript reads a script and refuses one that cannot answer.
//
// **Every refusal here is a check that would otherwise pass on nothing.** A
// script with no rules, a rule that matches everything, a reply that
// interpolates a value nothing read: each produces an agent that responds
// without having done anything, which is exactly the shape of success this
// harness exists to refuse.
func LoadAgentScript(path string) (AgentScript, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return AgentScript{}, fmt.Errorf(
				"no agent script at %s: the scripted agent answers from this file, and one that "+
					"cannot be read would answer every prompt with nothing", path)
		}
		return AgentScript{}, fmt.Errorf("reading %s: %w", path, err)
	}
	var script AgentScript
	if err := json.Unmarshal(data, &script); err != nil {
		return AgentScript{}, fmt.Errorf("reading %s: %w", path, err)
	}
	if len(script.Rules) == 0 {
		return AgentScript{}, fmt.Errorf(
			"%s carries no rules, so the agent would answer nothing at all", path)
	}
	for index, rule := range script.Rules {
		where := fmt.Sprintf("%s rule %d", path, index+1)
		if strings.TrimSpace(rule.Match) == "" {
			return AgentScript{}, fmt.Errorf(
				"%s has no `match`, so it would answer every prompt — including the ones a later "+
					"rule was written for", where)
		}
		for frameIndex, frame := range rule.Emit {
			if kind, ok := frame["type"].(string); !ok || kind == "" {
				return AgentScript{}, fmt.Errorf(
					"%s emits frame %d with no string `type`, so the window would decode it as "+
						"nothing and a check would wait on a frame that never arrived", where, frameIndex+1)
			}
		}
		if rule.Reply == "" && rule.Call == nil && rule.Read == nil {
			return AgentScript{}, fmt.Errorf(
				"%s neither acts, reads nor replies, so a prompt it matched would be accepted and "+
					"do nothing — which reads exactly like a broken harness", where)
		}
		if strings.Contains(rule.Reply, ValuePlaceholder) && rule.Read == nil {
			return AgentScript{}, fmt.Errorf(
				"%s interpolates %s but reads nothing, so the placeholder would reach the thought "+
					"thread as text and a check would assert on it", where, ValuePlaceholder)
		}
		if rule.Call != nil && rule.Call.Action == "" {
			return AgentScript{}, fmt.Errorf("%s calls an action with no name", where)
		}
		if rule.Read != nil && (rule.Read.Pane == "" || rule.Read.Field == "") {
			return AgentScript{}, fmt.Errorf("%s reads without naming both a pane and a field", where)
		}
	}
	return script, nil
}

// Rule finds the first rule the prompt triggers.
//
// **In order, and the first wins.** A broad trigger written above a narrow one
// shadows it — visibly, in the file, where a reader can see it — rather than
// by some precedence rule nobody would remember.
//
// **A prompt no rule matches is not answered.** The stub reports that as an
// error turn, because a stub that improvised would let a check whose prompt
// had drifted pass on an answer that proves nothing.
func (s AgentScript) Rule(prompt string) (AgentRule, bool) {
	folded := strings.ToLower(prompt)
	for _, rule := range s.Rules {
		if strings.Contains(folded, strings.ToLower(rule.Match)) {
			return rule, true
		}
	}
	return AgentRule{}, false
}

// AgentStubBinary is where `make e2e-agent` puts the scripted agent, and
// AgentStubScript the answers it ships with.
//
// **Under e2e/bin for AXResolveBinary's reason**: `bin/` holds the binaries
// `make app-bundle` copies into `Wakil.app/Contents/Resources`, and a stand-in
// for the agent has no business in a shipped bundle even by accident.
const (
	AgentStubBinary = "e2e/bin/wakil-e2e-agent"
	AgentStubScript = "e2e/stub/script.json"
	// AgentStubLogFile is what the stub records each turn in, beside its
	// script. It is copied into the evidence of a failing check, because the
	// fixture holding it is deleted at teardown.
	AgentStubLogFile = "e2e-agent-log.txt"
)

// ResolveAgentStub returns the absolute path to the scripted agent, which is
// what goes on the provider record.
//
// **Absolute, because the record's path is launched directly.**
// `executableURL` does not search `PATH` and the app's working directory is
// not this repository's, so a relative path here would name nothing by the
// time the window used it.
func ResolveAgentStub(override string) (string, error) {
	path := override
	if path == "" {
		path = AgentStubBinary
	}
	if err := executable(path); err != nil {
		if override != "" {
			return "", fmt.Errorf("agent stub override %q is unusable: %w", override, err)
		}
		return "", fmt.Errorf(
			"no scripted agent at %s (%w) — run `make e2e-agent`. Without it the fixture's "+
				"provider record names no binary, so a check that drives the agent proves "+
				"nothing about the agent", AgentStubBinary, err)
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolving %s: %w", path, err)
	}
	return absolute, nil
}

// AgentFixture is the scripted agent a launch seeds: the binary the provider
// record names, and the answers copied into its config directory.
//
// **One value because the two never travel apart.** Three call sites paired
// them by hand — `wakil-e2e`, `wakil-e2e-new` and `Prover` — and a fourth
// would have had to remember that a stub without its script is a fixture whose
// agent answers nothing at all. The zero value is "no agent", which is what
// every check that does not drive one wants.
type AgentFixture struct {
	Stub   string
	Script string
}

// SeedsAnAgent reports whether this fixture puts an agent on the provider
// record.
func (a AgentFixture) SeedsAnAgent() bool { return a.Stub != "" }

// ResolveAgentFixture resolves the scripted agent and the script beside it,
// or returns the empty fixture when this run wants no agent.
//
// **Resolved before anything is staged, launched or built**, the rule Orca and
// the resolver already hold to: a missing stub is knowable at the start, and
// discovering it after a five-minute bundle build costs the build.
func ResolveAgentFixture(override string) (AgentFixture, error) {
	stub, err := ResolveAgentStub(override)
	if err != nil {
		return AgentFixture{}, err
	}
	return AgentFixture{Stub: stub, Script: AgentStubScript}, nil
}
