// wakil-connect fronts one of an organisation's MCP connections: it dials the real server with
// the organisation's credentials, offers the agent that server's tools unchanged, and gates every
// call (gate.go). It is the only way the agent reaches a connection.
//
//	wakil-connect --connection <name>
//	wakil-connect --list --connection <name>
//
// --list dials the server the same way, prints {"tools":[{name,hint}]} or {"error":...} and exits
// 0 or 1; it never serves and never asks the app (Settings → Connections checks with it).
//
// The organisation is WAKIL_ORG, as for every Wakil binary; the app's approval socket is
// WAKIL_APPROVAL_SOCKET, absent when no app is running to ask.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// startLimit bounds dialling the real server and listing its tools, so a server that never
// answers leaves the session with an empty connection instead of a hung one.
const startLimit = 30 * time.Second

// newServer dials connection name's real server once and fronts the tools it lists. If the
// connection or its server cannot be reached, the server still runs, with no tools and the reason
// in its instructions. The returned func closes the upstream session.
func newServer(ctx context.Context, org, name, socket string, dial dialFunc) (*mcp.Server, func()) {
	upstream, tools, instructions, err := connectUpstream(ctx, org, name, dial)
	if err != nil {
		return unavailableServer(name, scrubSecrets(org, name, errText(err))), func() {}
	}
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-connect", Version: "0.1.0"}, &mcp.ServerOptions{Instructions: instructions})
	for _, tool := range tools {
		addFronted(s, tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			args, err := canonicalArguments(req.Params.Arguments)
			if err != nil {
				return mcpx.ToolErr("wakil-connect", err), nil
			}
			if err := gateCall(ctx, org, name, socket, tool, args); err != nil {
				return mcpx.ToolErr("wakil-connect", err), nil
			}
			res, err := upstream.CallTool(ctx, &mcp.CallToolParams{Name: tool.Name, Arguments: args})
			if err != nil {
				return mcpx.ToolErr("wakil-connect", wakilcore.UserError("connection "+name+" could not run "+tool.Name+": "+
					scrubSecrets(org, name, err.Error()))), nil
			}
			return res, nil
		})
	}
	return s, func() {
		if upstream != nil {
			upstream.Close()
		}
	}
}

func errText(err error) string {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return msg
	}
	return err.Error()
}

// scrubSecrets blanks every value in the connection's Keychain item out of msg, so an upstream
// error that echoes a key or a token does not hand it to the agent.
func scrubSecrets(org, name, msg string) string {
	secrets, _ := wakilcore.ConnectionSecrets(org, name)
	values := make([]string, 0, len(secrets))
	for _, v := range secrets {
		if v != "" {
			values = append(values, v)
		}
	}
	sort.Slice(values, func(i, j int) bool { return len(values[i]) > len(values[j]) })
	for _, v := range values {
		msg = strings.ReplaceAll(msg, v, "[secret]")
	}
	return msg
}

// unavailableServer is the server for a connection that cannot be fronted: no tools, and why in
// its instructions, so the session starts and the agent can say what is wrong.
func unavailableServer(name, msg string) *mcp.Server {
	return mcp.NewServer(&mcp.Implementation{Name: "wakil-connect", Version: "0.1.0"},
		&mcp.ServerOptions{Instructions: "Connection " + name + " is unavailable, so it offers no tools: " + msg})
}

// connectUpstream opens the client session to the real server and reads its tools and its own
// instructions, which pass through to the agent.
func connectUpstream(ctx context.Context, org, name string, dial dialFunc) (*mcp.ClientSession, []*mcp.Tool, string, error) {
	c, ok := wakilcore.ConnectionFor(org, name)
	if !ok {
		return nil, nil, "", wakilcore.UserError("organization " + org + " has no connection named " + name)
	}
	ctx, cancel := context.WithTimeout(ctx, startLimit)
	defer cancel()
	tr, err := dial(ctx, org, c)
	if err != nil {
		return nil, nil, "", err
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "wakil-connect", Version: "0.1.0"}, nil).Connect(ctx, tr, nil)
	if err != nil {
		return nil, nil, "", err
	}
	var tools []*mcp.Tool
	for tool, err := range cs.Tools(ctx, nil) {
		if err != nil {
			cs.Close()
			return nil, nil, "", err
		}
		tools = append(tools, tool)
	}
	return cs, tools, cs.InitializeResult().Instructions, nil
}

// addFronted registers the upstream tool as it is. The SDK refuses (panics on) an input schema
// that is not an object; such a tool is left out, named on stderr, rather than taking the rest down.
func addFronted(s *mcp.Server, tool *mcp.Tool, h mcp.ToolHandler) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "wakil-connect: left out tool %q: %v\n", tool.Name, r)
		}
	}()
	if tool.InputSchema == nil {
		tool.InputSchema = json.RawMessage(`{"type":"object"}`)
	}
	s.AddTool(tool, h)
}

// serve fronts connection name over t until the agent hangs up, ctx ends or Run fails, and closes
// the upstream session however it ends.
func serve(ctx context.Context, name, socket string, dial dialFunc, t mcp.Transport) error {
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return unavailableServer(name, errText(err)).Run(ctx, t)
	}
	s, closeUpstream := newServer(ctx, org, name, socket, dial)
	defer closeUpstream()
	return s.Run(ctx, t)
}

func main() {
	name := flag.String("connection", "", "the organization's connection to front")
	listOnly := flag.Bool("list", false, "print the connection's tools and their hints, then exit")
	flag.Parse()
	if *name == "" {
		fmt.Fprintln(os.Stderr, "wakil-connect: --connection <name> is required")
		os.Exit(2)
	}
	if *listOnly {
		org, err := wakilcore.CurrentOrg()
		if err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(listOut{Error: errText(err)})
			os.Exit(1)
		}
		os.Exit(list(context.Background(), org, *name, upstreamTransport, os.Stdout))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	err := serve(ctx, *name, os.Getenv("WAKIL_APPROVAL_SOCKET"), upstreamTransport, &mcp.StdioTransport{})
	stopped := ctx.Err() != nil
	stop()
	if err != nil && !stopped {
		fmt.Fprintln(os.Stderr, "wakil-connect:", err)
		os.Exit(1)
	}
}
