package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// liveHint is the server's own word on tool as it lists it now: readOnly, destructive (only an
// explicit destructiveHint: true; MCP's default for an absent one is true, which would lock every
// unannotated tool) or writes. ok is false when the tool carries no annotations at all.
func liveHint(tool *mcp.Tool) (hint string, ok bool) {
	a := tool.Annotations
	if a == nil {
		return "", false
	}
	switch {
	case a.ReadOnlyHint:
		return "readOnly", true
	case a.DestructiveHint != nil && *a.DestructiveHint:
		return "destructive", true
	}
	return "writes", true
}

// gateFlags is the rule's input for one call: the operator's switch over the live hint, falling
// back to the stored hint when the server gave none, so a tool that turned destructive locks at once.
func gateFlags(c wakilcore.MCPConnection, tool *mcp.Tool) (allowed, readOnly, locked bool) {
	hint := c.Hints[tool.Name]
	if live, ok := liveHint(tool); ok {
		hint = live
	}
	withLive := c
	withLive.Hints = map[string]string{tool.Name: hint}
	allowed, locked = wakilcore.ToolAllowed(withLive, tool.Name)
	return allowed, hint == "readOnly", locked
}

// approvalRequest is the one line wakil-connect sends the app. It carries the agent's own
// arguments and the flags, never a credential.
type approvalRequest struct {
	Connection string          `json:"connection"`
	Tool       string          `json:"tool"`
	Arguments  json.RawMessage `json:"arguments"`
	Allowed    bool            `json:"allowed"`
	ReadOnly   bool            `json:"readOnly"`
	Locked     bool            `json:"locked"`
}

// approvalAnswer is the app's one line back: allow, or deny with the sentence the agent reads.
type approvalAnswer struct {
	Decision string `json:"decision"`
	Message  string `json:"message"`
}

// canonicalArguments is the agent's arguments decoded once and written again: what the app is
// asked about and what the server runs are these same bytes, so a repeated key cannot show the
// operator one value and send the server another. None, or null, is {}.
func canonicalArguments(raw json.RawMessage) (json.RawMessage, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return json.RawMessage(`{}`), nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var args map[string]any
	if err := dec.Decode(&args); err != nil || dec.More() {
		return nil, wakilcore.UserError("the arguments are not a JSON object: nothing was sent")
	}
	if args == nil {
		return json.RawMessage(`{}`), nil
	}
	out, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// gateCall decides one call: nil forwards it, an error is the refusal the agent reads. An allowed
// read-only tool goes straight through. Everything else asks the app over socket — a ticked write
// too, so the app can apply the spoken-turn rule. With no socket (no app to ask), only an allowed
// tool goes through. Any trouble reaching or reading the app refuses the call.
func gateCall(ctx context.Context, org, name, socket string, tool *mcp.Tool, args json.RawMessage) error {
	c, ok := wakilcore.ConnectionFor(org, name)
	if !ok {
		return wakilcore.UserError("connection " + name + " is no longer in " + org + ": nothing was sent")
	}
	allowed, readOnly, locked := gateFlags(c, tool)
	if allowed && readOnly {
		return nil
	}
	if socket == "" {
		if allowed && !locked {
			return nil
		}
		if locked {
			return wakilcore.UserError(tool.Name + " on connection " + name + " is marked destructive by its server, " +
				"so Wakil asks before every call, and Wakil is not running to ask: nothing was sent")
		}
		return wakilcore.UserError(tool.Name + " on connection " + name + " needs the operator's approval, and Wakil is not running to ask. " +
			"To let the agent run it, switch on \"Allow agent\" for it in Wakil's Settings → Connections → " + name + ".")
	}
	answer, err := askApp(ctx, socket, approvalRequest{
		Connection: name, Tool: tool.Name, Arguments: args, Allowed: allowed, ReadOnly: readOnly, Locked: locked,
	})
	if err != nil {
		return wakilcore.UserError("could not ask Wakil to approve " + tool.Name + " on connection " + name + " (" + err.Error() + "): nothing was sent")
	}
	switch answer.Decision {
	case "allow":
		return nil
	case "deny":
		if answer.Message == "" {
			answer.Message = "The operator refused " + tool.Name + " on connection " + name + "."
		}
		return wakilcore.UserError(answer.Message)
	}
	return wakilcore.UserError("Wakil answered " + tool.Name + " on connection " + name + " with neither allow nor deny: nothing was sent")
}

// askApp sends req and reads the answer. There is no timeout here: the operator's own wait is the
// app's, and the call ends only if the agent's call does.
func askApp(ctx context.Context, socket string, req approvalRequest) (approvalAnswer, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", socket)
	if err != nil {
		return approvalAnswer{}, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()

	line, err := json.Marshal(req)
	if err != nil {
		return approvalAnswer{}, err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return approvalAnswer{}, err
	}
	reply, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil && len(reply) == 0 {
		return approvalAnswer{}, err
	}
	var answer approvalAnswer
	if err := json.Unmarshal(reply, &answer); err != nil {
		return approvalAnswer{}, wakilcore.UserError("its answer was not JSON")
	}
	return answer, nil
}
