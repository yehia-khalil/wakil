// wakil-connect fronts one of an organisation's MCP connections: it dials the real server with
// the organisation's credentials, offers the agent that server's tools unchanged, and gates every
// call (gate.go). It is the only way the agent reaches a connection.
//
//	wakil-connect --connection <name>
//
// The organisation is WAKIL_ORG, as for every Wakil binary; the app's approval socket is
// WAKIL_APPROVAL_SOCKET, absent when no app is running to ask.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
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
		return unavailableServer(name, err), func() {}
	}
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-connect", Version: "0.1.0"}, &mcp.ServerOptions{Instructions: instructions})
	for _, tool := range tools {
		addFronted(s, tool, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			if err := gateCall(ctx, org, name, socket, tool, req.Params.Arguments); err != nil {
				return mcpx.ToolErr("wakil-connect", err), nil
			}
			res, err := upstream.CallTool(ctx, &mcp.CallToolParams{Name: tool.Name, Arguments: req.Params.Arguments})
			if err != nil {
				return mcpx.ToolErr("wakil-connect", wakilcore.UserError("connection "+name+" could not run "+tool.Name+": "+err.Error())), nil
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

// unavailableServer is the server for a connection that cannot be fronted: no tools, and why in
// its instructions, so the session starts and the agent can say what is wrong.
func unavailableServer(name string, err error) *mcp.Server {
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		msg = err.Error()
	}
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

func main() {
	name := flag.String("connection", "", "the organization's connection to front")
	flag.Parse()
	if *name == "" {
		log.Fatal("wakil-connect: --connection <name> is required")
	}
	ctx := context.Background()
	var s *mcp.Server
	if org, err := wakilcore.CurrentOrg(); err != nil {
		s = unavailableServer(*name, err)
	} else {
		var closeUpstream func()
		s, closeUpstream = newServer(ctx, org, *name, os.Getenv("WAKIL_APPROVAL_SOCKET"), upstreamTransport)
		defer closeUpstream()
	}
	if err := s.Run(ctx, &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
