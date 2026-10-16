package main

import (
	"context"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// The send tool sits beside request exactly as wakil-db's mutate sits
// beside its query: same server, same entry resolution, same refusals —
// a different verb set, a body, and one gate the read tool does not have.

// Every refusal request makes about resolving an entry, send makes
// identically, because both reach the entry through `targetEntry` — one
// resolver, not two copies with a test standing over them. The table is
// what proves the shared resolver is actually reached from this side.
func TestSendSharesRequestsEntryRefusals(t *testing.T) {
	cases := []struct {
		name        string
		environment string
		envName     string
		args        map[string]any
		want        string
	}{
		{
			name:        "no api configured",
			environment: `"staging":{"databases":[]}`,
			envName:     "staging",
			args:        map[string]any{"method": "POST", "path": "/x", "body": "{}"},
			want:        "no api configured for this environment",
		},
		{
			name: "several entries, no name",
			environment: `"staging":{"databases":[],"api":[` +
				`{"name":"api","baseUrl":"https://127.0.0.1:1"},` +
				`{"name":"billing","baseUrl":"https://127.0.0.1:2"}]}`,
			envName: "staging",
			args:    map[string]any{"method": "POST", "path": "/x", "body": "{}"},
			want:    "name one of them",
		},
		{
			name:        "unknown entry never falls back",
			environment: `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`,
			envName:     "staging",
			args:        map[string]any{"method": "POST", "path": "/x", "body": "{}", "api": "billing"},
			want:        "no api entry named billing",
		},
		{
			name:        "non-https base",
			environment: `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"http://insecure.example"}]}`,
			envName:     "staging",
			args:        map[string]any{"method": "POST", "path": "/x", "body": "{}"},
			want:        "must be an absolute https URL",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setupProject(t, tc.environment, tc.envName)
			t.Setenv(wakilcore.WindowMarkerEnv, "1")
			callToolExpectError(t, connectedClient(t), "send", tc.args, tc.want)
		})
	}
}

// The window marker gates the TOOL, not merely the package function: a
// wakil-http registered into a provider's config dir answers request and
// refuses send, and that is the whole difference between the two copies.
func TestSendRefusedOutsideTheWindow(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")
	t.Setenv(wakilcore.WindowMarkerEnv, "")

	callToolExpectError(t, connectedClient(t), "send",
		map[string]any{"method": "POST", "path": "/x", "body": "{}"}, "read-only")
}

// A read verb offered to send is refused by name, pointing at request.
func TestSendRefusesAReadVerb(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")
	t.Setenv(wakilcore.WindowMarkerEnv, "1")

	callToolExpectError(t, connectedClient(t), "send",
		map[string]any{"method": "GET", "path": "/x"}, "request tool")
}

// And request still refuses a mutation verb, so neither tool is a way
// round the other.
func TestRequestStillRefusesAMutationVerb(t *testing.T) {
	setupProject(t, `"staging":{"databases":[],"api":[{"name":"api","baseUrl":"https://127.0.0.1:1"}]}`, "staging")
	t.Setenv(wakilcore.WindowMarkerEnv, "1")

	callToolExpectError(t, connectedClient(t), "request",
		map[string]any{"method": "POST", "path": "/x"}, "read-only mode")
}

// The tool's own description is the one string an LLM caller reliably
// reads, so it must state what the schema cannot: the verb set, the
// window restriction, the body limit, and that a redirect is refused.
func TestSendDescriptionStatesItsRestrictions(t *testing.T) {
	ctx := context.Background()
	cs := connectedClient(t)
	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	var desc string
	for _, tool := range tools.Tools {
		if tool.Name == "send" {
			desc = tool.Description
		}
	}
	if desc == "" {
		t.Fatal("no send tool is registered")
	}
	for _, want := range []string{"POST", "PUT", "PATCH", "DELETE", "window", "1 MiB", "redirect"} {
		if !strings.Contains(desc, want) {
			t.Fatalf("send's description does not mention %q: %s", want, desc)
		}
	}
}
