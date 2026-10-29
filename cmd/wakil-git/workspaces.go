package main

import (
	"context"
	"path/filepath"
	"slices"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// Workspaces, piece 1: the record and the worktrees behind it. Registered only in the window's
// copy (WAKIL_GIT_WRITES): an agent reaches them through the registry's write rule, never directly.

type workspacesArg struct {
	Workspaces []wakilcore.Workspace `json:"workspaces" jsonschema:"the whole record, every workspace of the organisation"`
}
type worktreeAddArg struct {
	Root       string `json:"root" jsonschema:"absolute path of one of the active project's own roots (Main's folder of the repo)"`
	Project    string `json:"project" jsonschema:"the project's registry key"`
	Slug       string `json:"slug" jsonschema:"the workspace's folder name"`
	Branch     string `json:"branch" jsonschema:"the branch the checkout is on"`
	From       string `json:"from,omitempty" jsonschema:"with create: the commit or branch a new branch starts from"`
	Create     bool   `json:"create,omitempty" jsonschema:"make the branch when it does not exist"`
	FromIsBase bool   `json:"fromIsBase,omitempty" jsonschema:"from is the repo's base: when missing, start from the remote's default branch and say so"`
}
type worktreeRemoveArg struct {
	Root     string `json:"root" jsonschema:"absolute path of the project root (Main's folder) the checkout belongs to"`
	Path     string `json:"path" jsonschema:"the checkout's folder, as workspaces.json records it"`
	Snapshot string `json:"snapshot,omitempty" jsonschema:"keep its uncommitted work under this ref (refs/wakil/snapshots/...) first, then remove it even when dirty"`
}
type worktreeRemoveResult struct {
	Snapshot string `json:"snapshot"`
}
type worktreeListResult struct {
	Worktrees []wakilcore.GitWorktree `json:"worktrees"`
}
type snapshotApplyArg struct {
	Root string `json:"root" jsonschema:"the checkout to put the work back into"`
	Ref  string `json:"ref" jsonschema:"the snapshot's ref (refs/wakil/snapshots/...)"`
}
type takeFromMainArg struct {
	Root    string `json:"root" jsonschema:"absolute path of the project root (Main's folder) on branch"`
	Project string `json:"project" jsonschema:"the project's registry key"`
	Slug    string `json:"slug" jsonschema:"the workspace's folder name"`
	Branch  string `json:"branch" jsonschema:"the branch Main's folder is on, taken into the checkout"`
	Base    string `json:"base,omitempty" jsonschema:"the branch Main's folder goes back to; omit for the remote's default branch"`
}
type takeFromMainResult struct {
	Path string `json:"path"`
	wakilcore.TakeFromMainResult
}

// mainRootWriter is a writer on one of the active project's OWN roots (never a checkout): worktrees
// are added and removed from the repository's own folder.
func mainRootWriter(root string) (*wakilcore.GitWriter, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	real := func(p string) string {
		if e, err := filepath.EvalSymlinks(p); err == nil {
			return e
		}
		return p
	}
	if !slices.ContainsFunc(wakilcore.ProjectRootPaths(*r), func(p string) bool { return real(p) == real(root) }) {
		return nil, mcpx.ToolErr("wakil-git", wakilcore.UserError(root+" is not one of the active project's own roots"))
	}
	return writer(root)
}

func checkoutPath(project, slug, root string) (string, *mcp.CallToolResult) {
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return "", mcpx.ToolErr("wakil-git", err)
	}
	p, err := wakilcore.WorkspaceCheckoutPath(org, project, slug, filepath.Base(root))
	if err != nil {
		return "", mcpx.ToolErr("wakil-git", err)
	}
	return p, nil
}

func addWorkspaceTools(s *mcp.Server) {
	mcp.AddTool(s, &mcp.Tool{Name: "workspaces_read", Description: "Read-only. The organisation's workspaces.json whole: each workspace's name, project, environment, tickets, parent, branch, checkouts (repo, path, branch, base, ports, last holder, in Main, snapshot), conversations, view and archived. An unreadable file is an error naming it."},
		func(_ context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, wakilcore.WorkspacesFile, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.WorkspacesFile{}, nil
			}
			f, err := wakilcore.LoadWorkspaces(org)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.WorkspacesFile{}, nil
			}
			if f.Workspaces == nil {
				f.Workspaces = []wakilcore.Workspace{}
			}
			return nil, f, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "workspaces_write", Description: "Writes. Replaces the organisation's workspaces.json with the given record, atomically. Refused over a file that cannot be read, for a duplicate id, and for a checkout outside the organisation's workspaces folder."},
		func(_ context.Context, _ *mcp.CallToolRequest, a workspacesArg) (*mcp.CallToolResult, emptyResult, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			if err := wakilcore.SaveWorkspaces(org, wakilcore.WorkspacesFile{Workspaces: a.Workspaces}); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_worktree_add", Description: "Writes. Makes a workspace's checkout of one of the project's roots: a git worktree at ~/.wakil/orgs/<org>/workspaces/<project>/<slug>/<repo folder>, on branch (an existing one as it is; with create, a new one from from). A branch checked out elsewhere is refused naming where; git's own refusal is whole and leaves nothing behind."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a worktreeAddArg) (*mcp.CallToolResult, wakilcore.WorktreeAddResult, error) {
			w, fail := mainRootWriter(a.Root)
			if fail != nil {
				return fail, wakilcore.WorktreeAddResult{}, nil
			}
			path, fail := checkoutPath(a.Project, a.Slug, a.Root)
			if fail != nil {
				return fail, wakilcore.WorktreeAddResult{}, nil
			}
			r, err := w.WorktreeAdd(ctx, wakilcore.WorktreeAddOptions{Path: path, Branch: a.Branch, From: a.From, Create: a.Create, FromIsBase: a.FromIsBase})
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.WorktreeAddResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_worktree_remove", Description: "Writes. Removes one recorded checkout (never Main's folder). With snapshot, its uncommitted work (untracked included) is kept under that ref first and the folder removed even when dirty; without, a dirty checkout is refused in git's words. The branch stays."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a worktreeRemoveArg) (*mcp.CallToolResult, worktreeRemoveResult, error) {
			w, fail := mainRootWriter(a.Root)
			if fail != nil {
				return fail, worktreeRemoveResult{}, nil
			}
			cw, fail := writer(a.Path) // confined: only a checkout the record holds
			if fail != nil {
				return fail, worktreeRemoveResult{}, nil
			}
			if a.Snapshot == "" {
				if err := w.WorktreeRemove(ctx, cw.Root); err != nil {
					return mcpx.ToolErr("wakil-git", err), worktreeRemoveResult{}, nil
				}
				return nil, worktreeRemoveResult{}, nil
			}
			if !strings.HasPrefix(a.Snapshot, "refs/wakil/snapshots/") {
				return mcpx.ToolErr("wakil-git", wakilcore.UserError("a snapshot is kept under refs/wakil/snapshots/, not "+a.Snapshot)), worktreeRemoveResult{}, nil
			}
			sha, err := cw.SnapshotCreate(ctx, a.Snapshot)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), worktreeRemoveResult{}, nil
			}
			if err := w.WorktreeRemoveForce(context.WithoutCancel(ctx), cw.Root); err != nil {
				return mcpx.ToolErr("wakil-git", err), worktreeRemoveResult{Snapshot: sha}, nil
			}
			return nil, worktreeRemoveResult{Snapshot: sha}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_worktree_list", Description: "Read-only. The worktrees of the repository one of the project's roots is: its own folder first, then each checkout with its branch or detached HEAD, and prunable when its folder is gone."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rootArg) (*mcp.CallToolResult, worktreeListResult, error) {
			w, fail := mainRootWriter(a.Root)
			if fail != nil {
				return fail, worktreeListResult{}, nil
			}
			l, err := w.WorktreeList(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), worktreeListResult{}, nil
			}
			if l == nil {
				l = []wakilcore.GitWorktree{}
			}
			return nil, worktreeListResult{Worktrees: l}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_worktree_prune", Description: "Writes. Forgets the repository's worktrees whose folders were deleted outside Wakil (git worktree prune)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rootArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := mainRootWriter(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.WorktreePrune(ctx); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_snapshot_apply", Description: "Writes. Puts a snapshot's work (refs/wakil/snapshots/...) back into a checkout, staged files staged again when git can; a clash is git's words, the snapshot kept."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a snapshotApplyArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.SnapshotApply(ctx, a.Ref); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			w.DeleteRef(context.WithoutCancel(ctx), a.Ref)
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_detach", Description: "Writes. Lets go of a checkout's branch without touching its files (git switch --detach), so another checkout can take the branch."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rootArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.Detach(ctx); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_take_from_main", Description: "Writes. Takes branch out of Main's folder (root) into the workspace's new checkout: Main's uncommitted work is snapshotted, Main's folder goes back to base, and the work is carried into the checkout. Any failure puts Main's folder back as it was and is shown whole."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a takeFromMainArg) (*mcp.CallToolResult, takeFromMainResult, error) {
			w, fail := mainRootWriter(a.Root)
			if fail != nil {
				return fail, takeFromMainResult{}, nil
			}
			path, fail := checkoutPath(a.Project, a.Slug, a.Root)
			if fail != nil {
				return fail, takeFromMainResult{}, nil
			}
			ref := "refs/wakil/carry/" + a.Slug + "/" + filepath.Base(a.Root)
			r, err := w.TakeFromMain(ctx, wakilcore.TakeFromMainOptions{Branch: a.Branch, Base: a.Base, Path: path, Ref: ref})
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), takeFromMainResult{}, nil
			}
			return nil, takeFromMainResult{Path: path, TakeFromMainResult: r}, nil
		})
}
