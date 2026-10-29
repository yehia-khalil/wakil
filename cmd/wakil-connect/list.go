package main

import (
	"context"
	"encoding/json"
	"io"
)

// listTool is one tool as --list prints it: its name and the server's word on it now (readOnly,
// writes, destructive, or "" for a tool with no annotations).
type listTool struct {
	Name string `json:"name"`
	Hint string `json:"hint"`
}

// listOut is --list's one line as a reader decodes it: the tools, or the server's error with
// every stored secret blanked out.
type listOut struct {
	Tools []listTool `json:"tools,omitempty"`
	Error string     `json:"error,omitempty"`
}

// listed is the success line: "tools" is always there, empty for a server with none.
type listed struct {
	Tools []listTool `json:"tools"`
}

// list dials connection name exactly as serving does, credentials and all, prints its tools and
// exits: 0 with the tools, 1 with the error. It never serves and never asks the app — it is how
// Settings checks a connection and reads its hints.
func list(ctx context.Context, org, name string, dial dialFunc, w io.Writer) int {
	cs, tools, _, err := connectUpstream(ctx, org, name, dial)
	if err != nil {
		_ = json.NewEncoder(w).Encode(listOut{Error: scrubSecrets(org, name, errText(err))})
		return 1
	}
	defer cs.Close()
	out := listed{Tools: []listTool{}}
	for _, tool := range tools {
		hint, _ := liveHint(tool)
		out.Tools = append(out.Tools, listTool{Name: tool.Name, Hint: hint})
	}
	_ = json.NewEncoder(w).Encode(out)
	return 0
}
