package driver

import (
	"fmt"
	"strings"
	"testing"
)

// fakeOperator stands in for the operator channel: a fakeChannel that serves a named set.
type fakeOperator struct {
	fakeChannel
	serves map[string]bool
}

func (f *fakeOperator) Serves(action string) bool { return f.serves[action] }

func newOperator(actions ...string) *fakeOperator {
	serves := map[string]bool{}
	for _, a := range actions {
		serves[a] = true
	}
	return &fakeOperator{serves: serves}
}

func callsOf(f *fakeChannel) string { return strings.Join(f.calls, "; ") }

// An action the operator channel serves is dispatched there, never over the agent socket.
func TestRunnerDispatchesAnOperatorOnlyActionOverTheOperatorChannel(t *testing.T) {
	agent := &fakeChannel{}
	operator := newOperator("ctx_update_org")
	runner, _ := newRunner(t, stateJSON, agent)
	runner.Operator = operator

	got := runner.Run([]Check{mustParse(t, "d",
		`{"dispatch":{"action":"ctx_update_org","params":{"id":"e2e-fixture"}}}`,
		`{"dispatch":{"action":"pane_open","params":{"kind":"db"}}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if len(operator.calls) != 1 || !strings.HasPrefix(operator.calls[0], "ctx_update_org ") {
		t.Errorf("operator calls = %s", callsOf(&operator.fakeChannel))
	}
	for _, call := range agent.calls {
		if strings.HasPrefix(call, "ctx_update_org ") {
			t.Errorf("ctx_update_org reached the agent socket: %s", callsOf(agent))
		}
	}
	if !strings.Contains(callsOf(agent), "pane_open ") {
		t.Errorf("pane_open must stay on the agent socket: %s", callsOf(agent))
	}
}

// A step expecting the operator-only refusal asserts about the AGENT, so it goes over the agent
// socket: the refusal it proves is the one a real agent would meet.
func TestRunnerSendsTheOperatorOnlyRefusalOverTheAgentSocket(t *testing.T) {
	agent := &fakeChannel{errs: map[string]error{
		"ctx_update_org": fmt.Errorf("tools/call: -32007: ctx_update_org: only the operator can run this — the agent may not."),
	}}
	operator := newOperator("ctx_update_org")
	runner, _ := newRunner(t, stateJSON, agent)
	runner.Operator = operator

	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"ctx_update_org","params":{"id":"e2e-fixture"},"refuses":"only the operator can run this"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if len(operator.calls) != 0 {
		t.Errorf("the refusal step reached the operator channel: %s", callsOf(&operator.fakeChannel))
	}
}

// Any other refusal of an operator-only action is the handler's, which only the operator reaches.
func TestRunnerSendsAHandlersRefusalOfAnOperatorOnlyActionOverTheOperatorChannel(t *testing.T) {
	agent := &fakeChannel{}
	operator := newOperator("ctx_update_org")
	operator.errs = map[string]error{"ctx_update_org": fmt.Errorf("tools/call: -32603: no provider nobody")}
	runner, _ := newRunner(t, stateJSON, agent)
	runner.Operator = operator

	got := runner.Run([]Check{mustParse(t, "r",
		`{"dispatch":{"action":"ctx_update_org","params":{"quickProvider":"nobody"},"refuses":"nobody"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if len(operator.calls) != 1 || !strings.HasPrefix(operator.calls[0], "ctx_update_org ") {
		t.Errorf("the handler's refusal did not come from the operator channel: %s", callsOf(&operator.fakeChannel))
	}
	if strings.Contains(callsOf(agent), "ctx_update_org") {
		t.Errorf("the handler's refusal went to the agent socket: %s", callsOf(agent))
	}
}

// **Routing reads what the step expects, not one spelling of it** (review M5). A `refuses` that
// the operator-only refusal would satisfy — the sentence, a part of it, or the sentence within a
// longer one — asserts what an agent meets, so it goes over the agent socket whatever its wording.
func TestRunnerSendsAnyWordingOfTheOperatorOnlyRefusalOverTheAgentSocket(t *testing.T) {
	for _, refuses := range []string{
		"only the operator can run this",
		"only the operator",
		"ctx_update_org: only the operator can run this",
	} {
		t.Run(refuses, func(t *testing.T) {
			agent := &fakeChannel{errs: map[string]error{
				"ctx_update_org": fmt.Errorf("tools/call: -32007: ctx_update_org: only the operator can run this"),
			}}
			operator := newOperator("ctx_update_org")
			runner, _ := newRunner(t, stateJSON, agent)
			runner.Operator = operator

			got := runner.Run([]Check{mustParse(t, "r",
				`{"dispatch":{"action":"ctx_update_org","params":{"id":"e2e-fixture"},"refuses":"`+refuses+`"}}`)})

			if err := got.Err(); err != nil {
				t.Fatalf("want a pass, got %v", err)
			}
			if len(operator.calls) != 0 {
				t.Errorf("the refusal step reached the operator channel: %s", callsOf(&operator.fakeChannel))
			}
		})
	}
}

// A refusal on the operator channel fails the step. Nothing retries it on the agent socket.
func TestRunnerNeverFallsBackToTheAgentSocketAfterARefusal(t *testing.T) {
	agent := &fakeChannel{}
	operator := newOperator("ctx_update_org")
	operator.errs = map[string]error{"ctx_update_org": fmt.Errorf("tools/call: -32002: ctx_update_org requires confirmation")}
	runner, _ := newRunner(t, stateJSON, agent)
	runner.Operator = operator

	got := runner.Run([]Check{mustParse(t, "d",
		`{"dispatch":{"action":"ctx_update_org","params":{"id":"e2e-fixture"}}}`,
		`{"expect":{"tree":"contains","text":"ORGANISATION"}}`)})

	if err := got.Err(); err == nil || !strings.Contains(err.Error(), "requires confirmation") {
		t.Fatalf("want the operator channel's refusal, got %v", err)
	}
	if strings.Contains(callsOf(agent), "ctx_update_org") {
		t.Errorf("the refused action was retried on the agent socket: %s", callsOf(agent))
	}
}

// A parity's dispatch half of an operator-only action is the operator channel's.
func TestParityDispatchesAnOperatorOnlyActionOverTheOperatorChannel(t *testing.T) {
	agent := &varyingChannel{replies: map[string][]string{
		"read_layout": {`{"focusedId":"db-0"}`, `{"focusedId":"db-1"}`, `{"focusedId":"db-1"}`},
	}}
	operator := newOperator("ctx_update_org")
	exe, _ := fakeOrca(t, verifiedClickJSON, 0)
	runner := &Runner{
		Orca: Orca{Exe: exe}, Resolver: Resolver{Exe: fakeResolver(t)},
		Channel: agent, Operator: operator, PID: 44187, Evidence: &Evidence{Dir: t.TempDir()},
	}

	got := runner.Run([]Check{mustParse(t, "par",
		`{"parity":{"action":"ctx_update_org","click":"landing.row.open:db","assert":"read_layout"}}`)})

	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
	if len(operator.calls) != 1 || !strings.HasPrefix(operator.calls[0], "ctx_update_org ") {
		t.Errorf("operator calls = %s", callsOf(&operator.fakeChannel))
	}
	if agent.seen["ctx_update_org"] != 0 {
		t.Errorf("the dispatch half reached the agent socket")
	}
}
