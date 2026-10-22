package main

import (
	"context"
	"log"
	"os"
	"strings"
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
		{"git_pull", "Writes. Pulls one root's upstream by the organisation's pull strategy (rebase, merge or ff-only). A conflict aborts and lists the paths; nothing is changed.", (*wakilcore.GitRemote).Pull},
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
			path, r, err := wakilcore.CloneInto(ctx, org, a.URL, a.Folder, a.Operator, remoteOptions())
			if err != nil {
				return mcpx.ToolErr("wakil-git", err), cloneOut{}, nil
			}
			return nil, cloneOut{Path: path, Summary: r.Summary, Progress: r.Progress}, nil
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

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
