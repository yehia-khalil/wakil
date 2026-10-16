package main

import (
	"context"
	"log"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

type statusArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type diffArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
	Side string `json:"side" jsonschema:"staged (index vs HEAD) or changed (work tree vs index)"`
}
type showArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
	Rev  string `json:"rev" jsonschema:"HEAD, index or worktree"`
}

// runner confines every call to a root the active project declares.
func runner(root string) (*wakilcore.GitRunner, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	g, err := wakilcore.NewGitRunner(root, wakilcore.ProjectRootPaths(*r))
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	return g, nil
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-git", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "git_status", Description: "Read-only. One root's branch, ahead/behind against its local tracking ref (never fetched), and its files in three groups: staged (index vs HEAD), changed (work tree vs index), untracked. A partly staged file appears in both staged and changed."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, wakilcore.GitStatus, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitStatus{}, nil
			}
			st, err := wakilcore.ReadGitStatus(ctx, g)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitStatus{}, nil
			}
			return nil, st, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_diff", Description: "Read-only. The unified diff of one file on one side: staged or changed. Capped at 5,000 lines; truncated says so and lines is the true total."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a diffArg) (*mcp.CallToolResult, wakilcore.GitDiffResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitDiffResult{}, nil
			}
			r, err := wakilcore.GitDiff(ctx, g, a.Path, a.Side)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitDiffResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_show", Description: "Read-only. One file's text at HEAD, in the index, or in the work tree. Capped at 2 MB; binary files return no text."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a showArg) (*mcp.CallToolResult, wakilcore.GitShowResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitShowResult{}, nil
			}
			r, err := wakilcore.GitShow(ctx, g, a.Path, a.Rev)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitShowResult{}, nil
			}
			return nil, r, nil
		})
	return s
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
