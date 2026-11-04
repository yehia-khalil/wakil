package wakilcore

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// A workspace's checkout is a git worktree of a project root (workspaces, piece 1). These are the
// writes that make, list, remove and prune them, run from the repository's own folder (Main's), and
// the snapshot that keeps a checkout's uncommitted work when it is removed.

// GitWorktree is one entry of `git worktree list`: Main is the repository's own folder, Prunable a
// worktree whose folder is gone.
type GitWorktree struct {
	Path     string `json:"path"`
	Head     string `json:"head"`
	Branch   string `json:"branch,omitempty"`
	Detached bool   `json:"detached,omitempty"`
	Main     bool   `json:"main,omitempty"`
	Prunable bool   `json:"prunable,omitempty"`
}

// BranchHeldError refuses a checkout of a branch another worktree has checked out, naming where.
// The write rule never lets it reach anyone: a held branch is taken over or branched off instead.
type BranchHeldError struct {
	Branch string
	Path   string
}

func (e *BranchHeldError) Error() string {
	return e.Branch + " is checked out in " + e.Path
}

// Unwrap makes it a UserError too, so a tool shows its sentence whole (mcpx.ToolErr).
func (e *BranchHeldError) Unwrap() error { return UserError(e.Error()) }

func asBranchHeld(err error, out **BranchHeldError) bool { return errors.As(err, out) }

// WorktreeList lists the repository's worktrees, its own folder first.
func (w *GitWriter) WorktreeList(ctx context.Context) ([]GitWorktree, error) {
	out, err := w.git(ctx, nil, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		return nil, err
	}
	var list []GitWorktree
	var cur *GitWorktree
	for _, f := range strings.Split(string(out), "\x00") {
		switch {
		case strings.HasPrefix(f, "worktree "):
			list = append(list, GitWorktree{Path: strings.TrimPrefix(f, "worktree ")})
			cur = &list[len(list)-1]
		case cur == nil:
		case strings.HasPrefix(f, "HEAD "):
			cur.Head = strings.TrimPrefix(f, "HEAD ")
		case strings.HasPrefix(f, "branch "):
			cur.Branch = strings.TrimPrefix(strings.TrimPrefix(f, "branch "), "refs/heads/")
		case f == "detached":
			cur.Detached = true
		case f == "prunable" || strings.HasPrefix(f, "prunable "):
			cur.Prunable = true
		}
	}
	if len(list) > 0 {
		list[0].Main = true
	}
	return list, nil
}

// WorktreeAddOptions: Branch is checked out in a new worktree at Path. An existing local branch is
// checked out as it is; with Create a missing one is made from From (a commit or branch). With
// FromIsBase, a From that does not resolve (a base missing on the remote) falls back to the remote's
// default branch, else HEAD, and the result's Note says so.
//
// A name never fails a checkout (amendment 2026-10-30, the walk): with NewBranch, Branch is a name
// to mint, so one the repo has, one another worktree has checked out or one in TakenBranches (the
// record's) gives way to the next free `-2`, `-3`; with FreeBranch, only a branch another worktree
// holds (or TakenBranches names) does, and an existing free one is checked out as it is.
//
// Base is one the agent chose (workspace_start, amendment 2026-10-30): Branch is a new branch,
// minted as with NewBranch, from the remote's copy of Base (origin/<Base>) when there is one, else
// the local branch. A Base that is neither is refused whole and nothing is made.
type WorktreeAddOptions struct {
	Path          string   `json:"path"`
	Branch        string   `json:"branch"`
	From          string   `json:"from,omitempty"`
	Create        bool     `json:"create,omitempty"`
	FromIsBase    bool     `json:"fromIsBase,omitempty"`
	NewBranch     bool     `json:"newBranch,omitempty"`
	FreeBranch    bool     `json:"freeBranch,omitempty"`
	TakenBranches []string `json:"takenBranches,omitempty"`
	Base          string   `json:"base,omitempty"`
}

// WorktreeAddResult is where the checkout is, its branch and commit, whether the branch was made
// for it (so a checkout taken back takes its branch too), and a sentence when its start was not
// the one asked for.
type WorktreeAddResult struct {
	Path    string `json:"path"`
	Branch  string `json:"branch"`
	Head    string `json:"head"`
	Created bool   `json:"created,omitempty"`
	Note    string `json:"note,omitempty"`
	// Base is what a chosen base resolved to: origin/<base> or the local branch.
	Base string `json:"base,omitempty"`
}

// FreeName is base, else base-2, base-3 … the first taken does not answer true for.
func FreeName(base string, taken func(string) bool) string {
	if !taken(base) {
		return base
	}
	for i := 2; ; i++ {
		if n := base + "-" + strconv.Itoa(i); !taken(n) {
			return n
		}
	}
}

func (w *GitWriter) resolves(ctx context.Context, rev string) bool {
	_, err := w.runner().Run(ctx, "rev-parse", "--verify", rev+"^{commit}")
	return err == nil
}

// WorktreeAdd makes a checkout. A branch already checked out in another worktree is refused with a
// BranchHeldError; git's own refusal otherwise comes back whole, and nothing is left at Path.
func (w *GitWriter) WorktreeAdd(ctx context.Context, o WorktreeAddOptions) (WorktreeAddResult, error) {
	for _, v := range []string{o.Branch, o.From, o.Base} {
		if err := notAFlag(v); err != nil {
			return WorktreeAddResult{}, err
		}
	}
	base := ""
	if o.Base != "" {
		switch {
		case w.resolves(ctx, "refs/remotes/origin/"+o.Base):
			base = "origin/" + o.Base
		case w.localBranchExists(ctx, o.Base):
			base = o.Base
		default:
			return WorktreeAddResult{}, UserError("There is no branch " + o.Base + " here nor on the remote (origin/" + o.Base +
				"), so no copy was made. Name a base the repo has, or leave it out to start from the remote's default branch")
		}
		o.From, o.Create, o.NewBranch, o.FromIsBase = base, true, true, false
	}
	if o.Path == "" || !filepath.IsAbs(o.Path) {
		return WorktreeAddResult{}, UserError("a checkout's path must be absolute: " + o.Path)
	}
	if _, err := os.Stat(o.Path); err == nil {
		return WorktreeAddResult{}, UserError(o.Path + " already exists")
	}
	list, err := w.WorktreeList(ctx)
	if err != nil {
		return WorktreeAddResult{}, err
	}
	heldAt := func(b string) (string, bool) {
		for _, t := range list {
			if t.Branch == b && b != "" && !t.Prunable {
				return t.Path, true
			}
		}
		return "", false
	}
	if o.NewBranch || o.FreeBranch {
		recorded := map[string]bool{}
		for _, b := range o.TakenBranches {
			recorded[b] = true
		}
		o.Branch = FreeName(o.Branch, func(b string) bool {
			_, held := heldAt(b)
			return recorded[b] || held || (o.NewBranch && w.localBranchExists(ctx, b))
		})
	}
	if p, held := heldAt(o.Branch); held {
		return WorktreeAddResult{}, &BranchHeldError{Branch: o.Branch, Path: p}
	}
	var args []string
	var note string
	created := false
	switch {
	case w.localBranchExists(ctx, o.Branch):
		args = []string{"add", o.Path, o.Branch}
	case o.Create:
		if err := w.validName(ctx, o.Branch); err != nil {
			return WorktreeAddResult{}, err
		}
		from := o.From
		if from == "" {
			from = "HEAD"
			if o.FromIsBase && w.resolves(ctx, "refs/remotes/origin/HEAD") {
				from = "origin/HEAD"
			}
		}
		if !w.resolves(ctx, from) {
			if !o.FromIsBase {
				return WorktreeAddResult{}, UserError("There is no commit or branch " + from)
			}
			fallback := "HEAD"
			if w.resolves(ctx, "refs/remotes/origin/HEAD") {
				fallback = "origin/HEAD"
			}
			note = "The base " + from + " was not found; the checkout starts from " + fallback + " instead"
			from = fallback
		}
		args = []string{"add", "-b", o.Branch, o.Path, from}
		created = true
	default:
		return WorktreeAddResult{}, UserError("There is no branch " + o.Branch)
	}
	if err := os.MkdirAll(filepath.Dir(o.Path), 0o755); err != nil {
		return WorktreeAddResult{}, err
	}
	if _, err := w.git(ctx, nil, "worktree", args...); err != nil {
		// git removes what it made on a refusal; a folder a failed hook left is ours to clear.
		if _, statErr := os.Stat(o.Path); statErr == nil {
			w.git(context.WithoutCancel(ctx), nil, "worktree", "remove", "--force", o.Path)
			os.RemoveAll(o.Path)
		}
		return WorktreeAddResult{}, err
	}
	head, _ := (&GitRunner{Root: o.Path}).Run(ctx, "rev-parse", "HEAD")
	return WorktreeAddResult{Path: o.Path, Branch: o.Branch, Head: strings.TrimSpace(string(head)), Created: created, Note: note, Base: base}, nil
}

// WorktreeDiscard takes back a checkout just made for a record that could not be saved
// (amendment 2026-10-30, the walk): its folder, the workspace folder above it when that is left
// empty, and branch when given (the one the add made). Never the repository's own folder; a
// checkout with anything written in it is refused in git's words, so no work is lost.
func (w *GitWriter) WorktreeDiscard(ctx context.Context, path, branch string) error {
	if err := notAFlag(branch); err != nil {
		return err
	}
	if err := w.WorktreeRemove(ctx, path); err != nil {
		return err
	}
	os.Remove(filepath.Dir(path)) // only when empty: another repo's checkout keeps it
	if branch == "" || !w.localBranchExists(ctx, branch) {
		return nil
	}
	_, err := w.git(context.WithoutCancel(ctx), nil, "branch", "-D", branch)
	return err
}

// worktreeAt is the listed worktree at path, compared through symlinks.
func worktreeAt(list []GitWorktree, path string) (GitWorktree, bool) {
	want := path
	if real, err := filepath.EvalSymlinks(path); err == nil {
		want = real
	}
	for _, t := range list {
		p := t.Path
		if real, err := filepath.EvalSymlinks(p); err == nil {
			p = real
		}
		if p == want || t.Path == path {
			return t, true
		}
	}
	return GitWorktree{}, false
}

// WorktreeRemove removes a checkout the repository lists, never its own folder. One with uncommitted
// changes (untracked included) is refused in git's words: the caller snapshots it first.
func (w *GitWriter) WorktreeRemove(ctx context.Context, path string) error {
	list, err := w.WorktreeList(ctx)
	if err != nil {
		return err
	}
	t, ok := worktreeAt(list, path)
	if !ok {
		return UserError(path + " is not a checkout of " + w.Root)
	}
	if t.Main {
		return UserError(path + " is the repository's own folder; it is never removed")
	}
	if t.Prunable {
		_, err := w.git(ctx, nil, "worktree", "prune")
		return err
	}
	_, err = w.git(ctx, nil, "worktree", "remove", t.Path)
	return err
}

// WorktreeRemoveForce removes a checkout whose work a snapshot already holds (Archive, Bring to Main).
func (w *GitWriter) WorktreeRemoveForce(ctx context.Context, path string) error {
	_, err := w.git(ctx, nil, "worktree", "remove", "--force", path)
	return err
}

// WorktreePrune forgets worktrees whose folders were deleted outside Wakil.
func (w *GitWriter) WorktreePrune(ctx context.Context) error {
	_, err := w.git(ctx, nil, "worktree", "prune")
	return err
}

// SnapshotCreate keeps the checkout's uncommitted work — staged, changed and untracked (not
// ignored) — as a stash-shaped commit under ref (which must be under refs/wakil/), without touching
// the stash list the repository's worktrees share or the files in the tree. "" when there is
// nothing to keep.
func (w *GitWriter) SnapshotCreate(ctx context.Context, ref string) (string, error) {
	if !strings.HasPrefix(ref, "refs/wakil/") || strings.Contains(ref, "..") {
		return "", UserError("a snapshot is kept under refs/wakil/, not " + ref)
	}
	out, err := w.git(ctx, nil, "stash", "create", "wakil snapshot")
	if err != nil {
		return "", err
	}
	stash := strings.TrimSpace(string(out))
	untracked, err := w.git(ctx, nil, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return "", err
	}
	if stash == "" && len(untracked) == 0 {
		return "", nil
	}
	snap := stash
	if len(untracked) > 0 {
		u, err := w.untrackedCommit(ctx, untracked)
		if err != nil {
			return "", err
		}
		tree, index := "HEAD^{tree}", ""
		if stash != "" {
			tree = stash + "^{tree}"
			index = stash + "^2"
		} else {
			i, err := w.git(ctx, nil, "commit-tree", "-p", "HEAD", "-m", "index on wakil snapshot", "HEAD^{tree}")
			if err != nil {
				return "", err
			}
			index = strings.TrimSpace(string(i))
		}
		c, err := w.git(ctx, nil, "commit-tree", "-p", "HEAD", "-p", index, "-p", u, "-m", "wakil snapshot", tree)
		if err != nil {
			return "", err
		}
		snap = strings.TrimSpace(string(c))
	}
	if _, err := w.git(ctx, nil, "update-ref", ref, snap); err != nil {
		return "", err
	}
	return snap, nil
}

// untrackedCommit is stash's third parent: a root commit of the untracked files, built in a
// temporary index so the checkout's own index is untouched.
func (w *GitWriter) untrackedCommit(ctx context.Context, paths []byte) (string, error) {
	f, err := os.CreateTemp("", "wakil-snapshot-index-*")
	if err != nil {
		return "", err
	}
	index := f.Name()
	f.Close()
	os.Remove(index) // git makes a fresh one at the name
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, _, err := w.gitEnv(ctx, nil, env, paths, "add", "--pathspec-from-file=-", "--pathspec-file-nul"); err != nil {
		return "", err
	}
	tree, _, err := w.gitEnv(ctx, nil, env, nil, "write-tree")
	if err != nil {
		return "", err
	}
	c, err := w.git(ctx, nil, "commit-tree", "-m", "untracked files on wakil snapshot", strings.TrimSpace(string(tree)))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(c)), nil
}

// SnapshotApply puts a snapshot's work back into this checkout, staged files staged again when git
// can; a clash comes back in git's words with the snapshot kept.
func (w *GitWriter) SnapshotApply(ctx context.Context, ref string) error {
	if !strings.HasPrefix(ref, "refs/wakil/") {
		return UserError("a snapshot is kept under refs/wakil/, not " + ref)
	}
	sha, err := w.runner().Run(ctx, "rev-parse", "--verify", ref)
	if err != nil {
		return UserError("There is no snapshot " + ref)
	}
	id := strings.TrimSpace(string(sha))
	if _, err := w.git(ctx, nil, "stash", "apply", "--index", id); err != nil {
		if !strings.Contains(err.Error(), "--index") {
			return err
		}
		_, err = w.git(ctx, nil, "stash", "apply", id)
		return err
	}
	return nil
}

// DeleteRef drops one of Wakil's own refs (a snapshot put back, a carry done).
func (w *GitWriter) DeleteRef(ctx context.Context, ref string) error {
	if !strings.HasPrefix(ref, "refs/wakil/") {
		return UserError("only refs under refs/wakil/ are Wakil's to delete, not " + ref)
	}
	_, err := w.git(ctx, nil, "update-ref", "-d", ref)
	return err
}

// TakeFromMainOptions: Main's folder (the writer's root) is on Branch; it goes back to Base, and
// Branch is checked out at Path with Main's uncommitted work carried along, through the snapshot Ref.
type TakeFromMainOptions struct {
	Branch string `json:"branch"`
	Base   string `json:"base"`
	Path   string `json:"path"`
	Ref    string `json:"ref"`
}

// TakeFromMainResult: Carried when Main had uncommitted work that is now in the checkout; Note a
// sentence when something was left (a clash, the work kept under the ref).
type TakeFromMainResult struct {
	Head    string `json:"head"`
	Carried bool   `json:"carried"`
	Note    string `json:"note,omitempty"`
}

// TakeFromMain moves a branch out of Main's folder into a new checkout (decision 8). Main's work is
// snapshotted before its folder is touched, so every failure puts it back; a refusal is whole.
func (w *GitWriter) TakeFromMain(ctx context.Context, o TakeFromMainOptions) (TakeFromMainResult, error) {
	if err := w.inProgress(ctx); err != nil {
		return TakeFromMainResult{}, err
	}
	b, err := ReadBranches(ctx, w.runner())
	if err != nil {
		return TakeFromMainResult{}, err
	}
	if b.Current != o.Branch {
		return TakeFromMainResult{}, UserError("Your folder " + w.Root + " is not on " + o.Branch)
	}
	if o.Base == "" {
		o.Base = w.DefaultBranch(ctx)
	}
	if o.Base == "" || o.Base == o.Branch {
		return TakeFromMainResult{}, UserError("Your folder " + w.Root + " has no other branch to go back to than " + o.Branch)
	}
	steady := context.WithoutCancel(ctx)
	snap, err := w.SnapshotCreate(steady, o.Ref)
	if err != nil {
		return TakeFromMainResult{}, err
	}
	restore := func(cause error) (TakeFromMainResult, error) {
		if cur, _ := ReadBranches(steady, w.runner()); cur.Current != o.Branch {
			w.git(steady, nil, "switch", "-q", o.Branch)
		}
		if snap != "" {
			if err := w.SnapshotApply(steady, o.Ref); err != nil {
				return TakeFromMainResult{}, UserError(cause.Error() + "\nYour changes could not be put back in " + w.Root +
					"; they are kept under " + o.Ref + ": " + err.Error())
			}
			w.DeleteRef(steady, o.Ref)
		}
		return TakeFromMainResult{}, cause
	}
	if snap != "" {
		if _, err := w.git(steady, nil, "reset", "-q", "--hard", "HEAD"); err != nil {
			return restore(err)
		}
		if _, err := w.git(steady, nil, "clean", "-fdq"); err != nil {
			return restore(err)
		}
	}
	sw, err := w.Switch(steady, o.Base, SwitchOptions{})
	if err != nil {
		return restore(err)
	}
	if !sw.Switched {
		return restore(UserError("Your folder " + w.Root + " could not switch to " + o.Base + ": " + strings.Join(sw.Blocked, ", ")))
	}
	add, err := w.WorktreeAdd(steady, WorktreeAddOptions{Path: o.Path, Branch: o.Branch})
	if err != nil {
		return restore(err)
	}
	r := TakeFromMainResult{Head: add.Head}
	if snap == "" {
		return r, nil
	}
	cw := &GitWriter{Root: o.Path, Identity: w.Identity}
	if err := cw.SnapshotApply(steady, o.Ref); err != nil {
		r.Note = "Your changes could not be applied in the checkout; they are kept under " + o.Ref + ": " + err.Error()
		return r, nil
	}
	w.DeleteRef(steady, o.Ref)
	r.Carried = true
	return r, nil
}

// DefaultBranch names the branch the repository's remote calls its default (origin/HEAD), else a
// local main or master; "" when none is.
func (w *GitWriter) DefaultBranch(ctx context.Context) string {
	if out, err := w.git(ctx, nil, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil {
		if name, ok := strings.CutPrefix(strings.TrimSpace(string(out)), "origin/"); ok && name != "" {
			return name
		}
	}
	for _, name := range []string{"main", "master"} {
		if w.localBranchExists(ctx, name) {
			return name
		}
	}
	return ""
}

// ReleaseBranch lets go of the branch a folder has checked out, so another checkout can take it
// (a switch to a branch held elsewhere): a checkout detaches, keeping its files; the repository's
// own folder (Main's) goes back to the default branch, bringing its changes along.
func (w *GitWriter) ReleaseBranch(ctx context.Context) (string, error) {
	list, err := w.WorktreeList(ctx)
	if err != nil {
		return "", err
	}
	if t, ok := worktreeAt(list, w.Root); ok && t.Main {
		base := w.DefaultBranch(ctx)
		if base == "" || base == t.Branch {
			return "", UserError("Your folder " + w.Root + " has no other branch to go back to than " + t.Branch)
		}
		r, err := w.Switch(ctx, base, SwitchOptions{Carry: "bring"})
		if err != nil {
			return "", err
		}
		if !r.Switched {
			return "", UserError("Your folder " + w.Root + " could not switch to " + base + ": " + strings.Join(r.Blocked, ", "))
		}
		return "Your folder " + w.Root + " went back to " + base, nil
	}
	return "", w.Detach(ctx)
}

// Detach lets go of a checkout's branch without touching its files (git switch --detach).
func (w *GitWriter) Detach(ctx context.Context) error {
	if err := w.inProgress(ctx); err != nil {
		return err
	}
	_, err := w.git(ctx, nil, "switch", "--detach", "-q")
	return err
}
