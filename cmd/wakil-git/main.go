package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// gitWritesEnv, set to "1", registers the seven write tools. Only the window's own copies of
// wakil-git (AppWiring) set it; the agent's copy (agentMCPConfigJSON) never does.
const gitWritesEnv = "WAKIL_GIT_WRITES"

type statusArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type diffArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path,omitempty" jsonschema:"file path relative to the root; omit for the whole root"`
	Side string `json:"side" jsonschema:"staged (index vs HEAD) or changed (work tree vs index)"`
}
type showArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
	Rev  string `json:"rev" jsonschema:"HEAD, index or worktree; or a stash side: stash:<id>, stash-base:<id>, stash-untracked:<id>; or a commit side: commit:<id> (the file after it), commit-parent:<id> (before it), commit-parent:<id>:<old path> (before it, under the name it had there); or a conflict's sides: ours (HEAD's, index stage 2) / theirs (the other side's, stage 3)"`
}
type historyArg struct {
	Root  string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path  string `json:"path" jsonschema:"file path relative to the root"`
	Skip  int    `json:"skip,omitempty" jsonschema:"commits to skip, for the next page"`
	Count int    `json:"count,omitempty" jsonschema:"commits to return; 50 when omitted"`
}
type historyResult struct {
	Commits []wakilcore.GitCommit `json:"commits"`
}
type blameArg struct {
	Root string  `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string  `json:"path" jsonschema:"file path relative to the root"`
	Text *string `json:"text,omitempty" jsonschema:"the file's unsaved text, blamed in place of the file on disk"`
}
type blameResult struct {
	Lines []wakilcore.GitBlameLine `json:"lines"`
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

type pathsArg struct {
	Root  string   `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Paths []string `json:"paths" jsonschema:"file paths relative to the root"`
}
type hunkArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path    string `json:"path" jsonschema:"file path relative to the root"`
	Content string `json:"content" jsonschema:"the file's whole new index text"`
	Expect  string `json:"expect" jsonschema:"the index blob id the content was computed against"`
}
type commitArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message" jsonschema:"the commit message"`
	All     bool   `json:"all,omitempty" jsonschema:"stage every change, untracked included, first"`
}
type amendArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message,omitempty" jsonschema:"a new message; omit to keep the last commit's"`
}
type blobArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
}
type switchArg struct {
	Root   string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Branch string `json:"branch" jsonschema:"the branch to switch to, or to create"`
	Create bool   `json:"create,omitempty" jsonschema:"make the branch (an existing name is switched to)"`
	From   string `json:"from,omitempty" jsonschema:"with create: the commit or branch to start it from"`
	Track  string `json:"track,omitempty" jsonschema:"with create: the remote branch it tracks, e.g. origin/feature"`
	Carry  string `json:"carry,omitempty" jsonschema:"changes in the way: refuse (default), stash, or bring (stash, switch, pop)"`
}
type renameArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	To   string `json:"to" jsonschema:"the current branch's new name"`
}
type deleteArg struct {
	Root   string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Branch string `json:"branch" jsonschema:"the local branch to delete"`
	Force  bool   `json:"force,omitempty" jsonschema:"delete even with commits no other branch has"`
}
type stashArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message,omitempty" jsonschema:"what the stash holds"`
	Mode    string `json:"mode,omitempty" jsonschema:"default (tracked changes), untracked (with untracked files) or staged"`
}
type stashRefArg struct {
	Root  string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Index int    `json:"index" jsonschema:"the stash's position in git_stashes"`
	ID    string `json:"id" jsonschema:"the stash's commit id from git_stashes; refused if the position no longer holds it"`
}
type dropAllArg struct {
	Root string   `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	IDs  []string `json:"ids" jsonschema:"the ids of the stashes shown (git_stashes); one pushed since is kept"`
}
type stashesResult struct {
	Stashes []wakilcore.GitStash `json:"stashes"`
}
type noteResult struct {
	Note string `json:"note"`
}

// stashResult is a stash apply's note, and the clash it left in the tree (for git_stash_undo_apply).
type stashResult struct {
	Note  string                   `json:"note"`
	Clash *wakilcore.GitStashClash `json:"clash,omitempty"`
}
type mergeArg struct {
	Root   string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Branch string `json:"branch" jsonschema:"the branch to merge into the current one"`
}
type rebaseArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Onto string `json:"onto" jsonschema:"the branch to rebase the current one onto"`
}
type continueArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message,omitempty" jsonschema:"a merge, cherry-pick or revert's commit message; omit to keep git's own. A rebase keeps each commit's message"`
}
type rootArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
}
type resolveArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"the conflicted file, relative to the root"`
	Take string `json:"take" jsonschema:"current (HEAD's side), incoming (the other side), keep (a delete/modify conflict: keep the file) or delete (remove it)"`
}
type undoApplyArg struct {
	Root  string                  `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Clash wakilcore.GitStashClash `json:"clash" jsonschema:"the clash object git_stash_apply or git_stash_pop returned"`
}

type emptyResult struct{}
type trashedResult struct {
	Trashed []string `json:"trashed"`
}
type messageResult struct {
	Message string `json:"message"`
}
type blobResult struct {
	Blob string `json:"blob"`
}
type identityResult struct {
	Name  string `json:"name"`
	Email string `json:"email"`
	From  string `json:"from"`
}

// writer confines every write to a root the active project declares. The organisation's
// identity is read at each write, so a Settings change applies at once.
func writer(root string) (*wakilcore.GitWriter, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	// An unreadable org.json is refused, not read as "no identity": that would commit as git
	// config's identity, which may be another organisation's (Invariant 4).
	org, err := wakilcore.LoadOrg()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	w, err := wakilcore.NewGitWriter(root, wakilcore.ProjectRootPaths(*r), wakilcore.OrgGitIdentity(org))
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	return w, nil
}

// remoteOptions: file:// remotes only when the e2e fixture's launch asks (R5).
func remoteOptions() wakilcore.GitRemoteOptions {
	return wakilcore.GitRemoteOptions{AllowFileProtocol: os.Getenv("WAKIL_GIT_ALLOW_FILE") == "1"}
}

// remote is writer's counterpart for the remote operations: a root the active project declares.
func remote(root string) (*wakilcore.GitRemote, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	g, err := wakilcore.NewGitRemote(org, root, wakilcore.ProjectRootPaths(*r), remoteOptions())
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	return g, nil
}

type cloneArg struct {
	URL      string `json:"url" jsonschema:"the repository's link: https://…, git@host:… or ssh://…"`
	Folder   string `json:"folder,omitempty" jsonschema:"absolute folder to clone under; default the last one"`
	Operator bool   `json:"operator,omitempty" jsonschema:"true when the operator asked (any folder); false for the agent"`
}

type cloneOut struct {
	Path     string `json:"path"`
	Summary  string `json:"summary"`
	Progress string `json:"progress,omitempty"`
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-git", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "git_status", Description: "Read-only. One root's branch, ahead/behind against its local tracking ref (never fetched), and its files in four groups: conflicts (an unmerged file, with its kind: UU, AA, DU, UD, AU, UA or DD), staged (index vs HEAD), changed (work tree vs index), untracked. A partly staged file appears in both staged and changed; a staged file still holding a whole conflict block has markers set. state names a merge, rebase, cherry-pick or revert stopped part-way (kind, incoming, onto, step/steps, head, subject)."},
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

	mcp.AddTool(s, &mcp.Tool{Name: "git_diff", Description: "Read-only. The unified diff of one file, or of the whole root when path is omitted, on one side: staged or changed. Capped at 5,000 lines; truncated says so and lines is the true total."},
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

	mcp.AddTool(s, &mcp.Tool{Name: "git_show", Description: "Read-only. One file's text at HEAD, in the index, in the work tree, or at a stash's or a commit's side. Capped at 2 MB; binary files return no text."},
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

	if os.Getenv(gitWritesEnv) == "1" {
		addWriteTools(s)
	}

	mcp.AddTool(s, &mcp.Tool{Name: "git_blob", Description: "Read-only. The id of one file's blob in the index (git rev-parse --verify :path): the expect value git_stage_hunk needs."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a blobArg) (*mcp.CallToolResult, blobResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, blobResult{}, nil
			}
			out, err := g.Run(ctx, "rev-parse", "--verify", ":"+a.Path)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), blobResult{}, nil
			}
			return nil, blobResult{Blob: strings.TrimSpace(string(out))}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_branches", Description: "Read-only. One root's branches: local ones most recently committed first, with upstream, ahead/behind and the commits the current branch lacks; remote ones no local tracks; the current branch or a detached HEAD's SHA."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, wakilcore.GitBranches, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, wakilcore.GitBranches{}, nil
			}
			b, err := wakilcore.ReadBranches(ctx, g)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitBranches{}, nil
			}
			return nil, b, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_file_history", Description: "Read-only. One file's commits, newest first, following renames: id, parents, author, email, date, subject, body, and the file's path at that commit. 50 a page; skip for the next."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a historyArg) (*mcp.CallToolResult, historyResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, historyResult{}, nil
			}
			h, err := wakilcore.ReadFileHistory(ctx, g, a.Path, a.Skip, a.Count)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), historyResult{}, nil
			}
			return nil, historyResult{Commits: h}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_blame", Description: "Read-only. Who last changed each line of one file: line, commit id, author, date, subject. A line not yet committed has an all-zero id. With text, that text is blamed in place of the file on disk."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a blameArg) (*mcp.CallToolResult, blameResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, blameResult{}, nil
			}
			b, err := wakilcore.ReadBlame(ctx, g, a.Path, a.Text)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), blameResult{}, nil
			}
			return nil, blameResult{Lines: b}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_stashes", Description: "Read-only. One root's stashes, newest first: index, id, message, the branch it was made on, date, and the files it holds (untracked ones included)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, stashesResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, stashesResult{}, nil
			}
			st, err := wakilcore.ReadStashes(ctx, g)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), stashesResult{}, nil
			}
			return nil, stashesResult{Stashes: st}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_identity", Description: "Read-only. The name and email a commit here would carry. When the organisation sets both, those (from: organisation). Otherwise the repository's git config user.name and user.email. If the organisation sets only one of the two, that one is used and the other comes from git config. from names where the email came from: organisation or git config."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, identityResult, error) {
			g, fail := runner(a.Root)
			if fail != nil {
				return fail, identityResult{}, nil
			}
			org, err := wakilcore.LoadOrg()
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), identityResult{}, nil
			}
			id := wakilcore.OrgGitIdentity(org)
			// from names the email's source: the hint the window shows is the email.
			res := identityResult{Name: id.Name, Email: id.Email, From: "organisation"}
			if res.Name == "" {
				res.Name = g.ConfigValue(ctx, "user.name")
			}
			if res.Email == "" {
				res.Email = g.ConfigValue(ctx, "user.email")
				res.From = "git config"
			}
			return nil, res, nil
		})
	return s
}

// addWriteTools registers the 3a-ii writes. Each runs the repository's hooks and signing.
func addWriteTools(s *mcp.Server) {
	// 3a-iii-a: the remote operations, with the organisation's account for the remote's host.
	for _, op := range []struct {
		name, desc string
		run        func(*wakilcore.GitRemote, context.Context) (wakilcore.GitRemoteResult, error)
	}{
		{"git_fetch", "Writes. Fetches one root's remote (git fetch --prune) with the organisation's account; answers how far the branch is ahead and behind.", (*wakilcore.GitRemote).Fetch},
		{"git_pull", "Writes. Pulls one root's upstream by the organisation's pull strategy (rebase, merge or ff-only). A conflict stops it with the conflicts left in the tree; the paths are listed, and git_resolve and git_continue (or git_abort) finish it.", (*wakilcore.GitRemote).Pull},
		{"git_push", "Writes. Pushes one root's branch to its upstream with the organisation's account. Never forces; a branch with no upstream needs git_publish.", (*wakilcore.GitRemote).Push},
		{"git_publish", "Writes. Pushes one root's branch to origin and sets it as the upstream.", (*wakilcore.GitRemote).Publish},
		{"git_sync", "Writes. Pulls one root's upstream (the organisation's strategy) then pushes, stopping at the first failure.", (*wakilcore.GitRemote).Sync},
	} {
		op := op
		mcp.AddTool(s, &mcp.Tool{Name: op.name, Description: op.desc},
			func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, wakilcore.GitRemoteResult, error) {
				g, fail := remote(a.Root)
				if fail != nil {
					return fail, wakilcore.GitRemoteResult{}, nil
				}
				ctx, done := remoteContext(ctx)
				defer done()
				r, err := op.run(g, ctx)
				if err != nil {
					// A conflicting pull reports its paths beside the refusal.
					if len(r.Conflicts) > 0 {
						return mcpx.ToolErr("wakil-git", err), r, nil
					}
					return mcpx.ToolErr("wakil-git", err), wakilcore.GitRemoteResult{}, nil
				}
				return nil, r, nil
			})
	}

	mcp.AddTool(s, &mcp.Tool{Name: "git_clone", Description: "Writes. Clones url into folder/<repository name> with the organisation's account for its host; a failed clone leaves nothing behind. The operator may name any folder (it becomes the last clone folder); otherwise only the last one is allowed, and is the default."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a cloneArg) (*mcp.CallToolResult, cloneOut, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), cloneOut{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			path, r, err := wakilcore.CloneInto(ctx, org, a.URL, a.Folder, a.Operator, remoteOptions())
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), cloneOut{}, nil
			}
			return nil, cloneOut{Path: path, Summary: r.Summary, Progress: r.Progress}, nil
		})

	// 3a-v-b: conflicts. A conflict stop is a result (done false, the paths), not an error.
	mcp.AddTool(s, &mcp.Tool{Name: "git_merge", Description: "Writes. Merges a branch into the current one (autostashing the changes in the way; no editor opens). Conflicts stop it with done false and the paths, left in the tree to resolve with git_resolve; then git_continue, or git_abort."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a mergeArg) (*mcp.CallToolResult, wakilcore.GitMergeResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitMergeResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Merge(ctx, a.Branch)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitMergeResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_rebase", Description: "Writes. Rebases the current branch onto another (autostashing; no editor opens). Conflicts stop it with done false and the paths, at one commit; resolve them with git_resolve, then git_continue, git_skip that commit, or git_abort."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rebaseArg) (*mcp.CallToolResult, wakilcore.GitMergeResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitMergeResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Rebase(ctx, a.Onto)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitMergeResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_continue", Description: "Writes. Finishes the merge, rebase, cherry-pick or revert in progress once its conflicts are resolved and staged; refused naming the files that still conflict. A rebase may stop again at the next commit (done false)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a continueArg) (*mcp.CallToolResult, wakilcore.GitMergeResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitMergeResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Continue(ctx, a.Message)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitMergeResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_skip", Description: "Writes. Skips the commit a rebase stopped on; its changes are left out of the rebase. May stop again at the next commit (done false)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rootArg) (*mcp.CallToolResult, wakilcore.GitMergeResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitMergeResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Skip(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitMergeResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_abort", Description: "Writes. Abandons the merge, rebase, cherry-pick or revert in progress; the tree goes back to before it and any resolutions made are lost."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a rootArg) (*mcp.CallToolResult, wakilcore.GitMergeResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitMergeResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Abort(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitMergeResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_resolve", Description: "Writes. Resolves one conflicted file by taking a side whole: current (HEAD's) or incoming, or for a delete/modify conflict keep or delete. Stages the result. current, incoming and delete lose edits made to the file; keep stages the file as it is in the tree."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a resolveArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			if err := w.Resolve(ctx, a.Path, a.Take); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_stash_undo_apply", Description: "Writes. Puts back the files a stash apply or pop clashed in, to HEAD, from the clash that call returned; the stash stays in the list. Refused naming any file changed since the clash."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a undoApplyArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			if err := w.StashUndoApply(ctx, a.Clash); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	// 3a-iv: branches and stash. Never --force or --discard-changes.
	mcp.AddTool(s, &mcp.Tool{Name: "git_switch", Description: "Writes. Switches one root to a branch, or creates it (create; from a base, or tracking a remote branch). Changes a switch would overwrite are listed in blocked unless carry is stash or bring; with bring, a clash is left in the tree to resolve (the stash kept) and returned as clash, for git_stash_undo_apply."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a switchArg) (*mcp.CallToolResult, wakilcore.SwitchResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.SwitchResult{}, nil
			}
			ctx, done := remoteContext(ctx)
			defer done()
			r, err := w.Switch(ctx, a.Branch, wakilcore.SwitchOptions{Create: a.Create, From: a.From, Track: a.Track, Carry: a.Carry})
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.SwitchResult{}, nil
			}
			return nil, r, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_branch_rename", Description: "Writes. Renames one root's current branch; a name that exists is refused."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a renameArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.RenameBranch(ctx, a.To); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_branch_delete", Description: "Writes. Deletes one root's local branch; one with commits no other branch has is refused unless force."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a deleteArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.DeleteBranch(ctx, a.Branch, a.Force); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_stash", Description: "Writes. Stashes one root's changes: mode default, untracked or staged, with an optional message."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a stashArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.Stash(ctx, a.Message, a.Mode); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})
	for _, op := range []struct {
		name, desc string
		pop        bool
	}{
		{"git_stash_apply", "Writes. Applies one stash (by index and id) and keeps it. A clash is left in the tree to resolve and the stash is kept; the result's clash is what git_stash_undo_apply takes to put the files back.", false},
		{"git_stash_pop", "Writes. Applies one stash (by index and id) and drops it. A clash is left in the tree to resolve and the stash is kept (not dropped); the result's clash is what git_stash_undo_apply takes to put the files back.", true},
	} {
		op := op
		mcp.AddTool(s, &mcp.Tool{Name: op.name, Description: op.desc},
			func(ctx context.Context, _ *mcp.CallToolRequest, a stashRefArg) (*mcp.CallToolResult, stashResult, error) {
				w, fail := writer(a.Root)
				if fail != nil {
					return fail, stashResult{}, nil
				}
				note, clash, err := w.StashApply(ctx, a.Index, a.ID, op.pop)
				if err != nil {
					return mcpx.ToolErr("wakil-git", err), stashResult{}, nil
				}
				return nil, stashResult{Note: note, Clash: clash}, nil
			})
	}
	mcp.AddTool(s, &mcp.Tool{Name: "git_stash_drop", Description: "Writes. Drops one stash (by index and id); it cannot be applied again."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a stashRefArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.StashDrop(ctx, a.Index, a.ID); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})
	mcp.AddTool(s, &mcp.Tool{Name: "git_stash_drop_all", Description: "Writes. Drops the listed stashes (by id) of the repository a root is in — the stash list is shared by its worktrees; one pushed since the list was read is kept. None can be applied again."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a dropAllArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.StashDropAll(ctx, a.IDs); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_stage", Description: "Writes. Runs `git add` on the given paths in one root."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a pathsArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.Stage(ctx, a.Paths); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_unstage", Description: "Writes. Takes the given paths out of the index of one root (git restore --staged); the work tree is untouched."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a pathsArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.Unstage(ctx, a.Paths); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_discard", Description: "Writes. Throws away the work-tree changes to the given paths in one root, moving each file to the Trash first; returns the trashed names."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a pathsArg) (*mcp.CallToolResult, trashedResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, trashedResult{}, nil
			}
			names, err := w.Discard(ctx, a.Paths, time.Now())
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), trashedResult{}, nil
			}
			if names == nil {
				names = []string{}
			}
			return nil, trashedResult{Trashed: names}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_stage_hunk", Description: "Writes. Replaces one file's index entry with the given whole text, if the index still holds the blob the text was computed against (expect); otherwise refuses."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a hunkArg) (*mcp.CallToolResult, emptyResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, emptyResult{}, nil
			}
			if err := w.StageContent(ctx, a.Path, a.Content, a.Expect); err != nil {
				return mcpx.ToolErr("wakil-git", err), emptyResult{}, nil
			}
			return nil, emptyResult{}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_commit", Description: "Writes. Commits what is staged (or, with all, every change) in one root, running the repository's hooks and signing, as the organisation's git identity when it sets one."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a commitArg) (*mcp.CallToolResult, wakilcore.GitCommitResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitCommitResult{}, nil
			}
			r, err := w.Commit(ctx, a.Message, a.All)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitCommitResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_amend", Description: "Writes. Rewrites the last commit of one root with what is staged, keeping its message unless a new one is given (git commit --amend), running the repository's hooks and signing."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a amendArg) (*mcp.CallToolResult, wakilcore.GitCommitResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, wakilcore.GitCommitResult{}, nil
			}
			r, err := w.Amend(ctx, a.Message)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), wakilcore.GitCommitResult{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "git_undo_commit", Description: "Writes. Undoes the last commit of one root with a soft reset (git reset --soft HEAD~1): its changes stay staged. Returns the undone commit's message."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a statusArg) (*mcp.CallToolResult, messageResult, error) {
			w, fail := writer(a.Root)
			if fail != nil {
				return fail, messageResult{}, nil
			}
			m, err := w.UndoCommit(ctx)
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), messageResult{}, nil
			}
			return nil, messageResult{Message: m}, nil
		})
}

// shutdown is cancelled by SIGTERM — how the window stops wakil-git, an org switch included — and
// remoteWork counts the remote operations and clones running. Stopping cancels them through their
// context, so a pull aborts what it started and a clone removes its folder, and the process exits
// once they have (3a-iii review I4); git itself runs in its own process group and would otherwise
// outlive this process with closed pipes.
var (
	shutdown   = context.Background()
	remoteWork sync.WaitGroup
)

// remoteContext is ctx, also cancelled by shutdown, and counted in remoteWork until done is called.
func remoteContext(ctx context.Context) (context.Context, func()) {
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(shutdown, cancel)
	remoteWork.Add(1)
	return ctx, func() {
		stop()
		cancel()
		remoteWork.Done()
	}
}

func main() {
	var stop context.CancelFunc
	shutdown, stop = signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	go func() {
		<-shutdown.Done()
		remoteWork.Wait()
		os.Exit(0)
	}()
	err := newServer().Run(context.Background(), &mcp.StdioTransport{})
	remoteWork.Wait()
	if err != nil {
		log.Fatal(err)
	}
}
