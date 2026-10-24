package wakilcore

import (
	"context"
	"strconv"
	"strings"
	"time"
)

// GitBranch is one local branch (3a-iv): its upstream and how far it is from it, and how many of its
// commits the current branch lacks (what deleting it would lose).
type GitBranch struct {
	Name     string    `json:"name"`
	Upstream string    `json:"upstream,omitempty"`
	Ahead    int       `json:"ahead"`
	Behind   int       `json:"behind"`
	Unmerged int       `json:"unmerged"`
	Current  bool      `json:"current"`
	Date     time.Time `json:"date"`
}

// GitBranches is a root's branches: local ones most recently committed first, remote ones no local
// tracks, and the current branch — or, on a detached HEAD, its short SHA.
type GitBranches struct {
	Local    []GitBranch `json:"local"`
	Remote   []string    `json:"remote"`
	Current  string      `json:"current"`
	Detached string      `json:"detached,omitempty"`
}

// ReadBranches lists the root's branches through the read runner (no repository program runs).
func ReadBranches(ctx context.Context, g *GitRunner) (GitBranches, error) {
	var b GitBranches
	if head, err := g.Run(ctx, "rev-parse", "--abbrev-ref", "HEAD"); err == nil {
		if h := strings.TrimSpace(string(head)); h != "HEAD" {
			b.Current = h
		} else if sha, err := g.Run(ctx, "rev-parse", "--short", "HEAD"); err == nil {
			b.Detached = strings.TrimSpace(string(sha))
		}
	}
	out, err := g.Run(ctx, "for-each-ref", "--sort=-committerdate",
		"--format=%(refname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:iso-strict)", "refs/heads")
	if err != nil {
		return b, err
	}
	tracked := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Split(line, "\x00")
		if len(f) != 4 {
			continue
		}
		br := GitBranch{Name: f[0], Upstream: f[1], Current: f[0] == b.Current}
		br.Ahead, br.Behind = parseTrack(f[2])
		br.Date, _ = time.Parse(time.RFC3339, f[3])
		if f[1] != "" {
			tracked[f[1]] = true
		}
		if !br.Current {
			if n, err := g.Run(ctx, "rev-list", "--count", "HEAD.."+br.Name); err == nil {
				br.Unmerged, _ = strconv.Atoi(strings.TrimSpace(string(n)))
			}
		}
		b.Local = append(b.Local, br)
	}
	remotes, err := g.Run(ctx, "for-each-ref", "--format=%(refname:short)%00%(symref)", "refs/remotes")
	if err != nil {
		return b, err
	}
	for _, line := range strings.Split(strings.TrimSpace(string(remotes)), "\n") {
		f := strings.Split(line, "\x00")
		// A symbolic ref (origin/HEAD, shown as "origin") is not a branch.
		if len(f) != 2 || f[0] == "" || f[1] != "" || tracked[f[0]] {
			continue
		}
		b.Remote = append(b.Remote, f[0])
	}
	return b, nil
}

// parseTrack reads for-each-ref's %(upstream:track): "[ahead 1, behind 2]", "[gone]" or "".
func parseTrack(s string) (ahead, behind int) {
	for _, part := range strings.Split(strings.Trim(s, "[]"), ", ") {
		if n, ok := strings.CutPrefix(part, "ahead "); ok {
			ahead, _ = strconv.Atoi(n)
		}
		if n, ok := strings.CutPrefix(part, "behind "); ok {
			behind, _ = strconv.Atoi(n)
		}
	}
	return ahead, behind
}

// SwitchOptions: Create makes the branch (From its base, or tracking the remote branch Track); Carry
// says what to do with local changes a plain switch would overwrite — "refuse" (the default) lists
// them, "stash" stashes them and switches, "bring" stashes, switches and pops (VS Code's Migrate).
type SwitchOptions struct {
	Create bool   `json:"create,omitempty"`
	From   string `json:"from,omitempty"`
	Track  string `json:"track,omitempty"`
	Carry  string `json:"carry,omitempty"`
}

// SwitchResult: Blocked lists the paths a refused switch would overwrite; Stash is the id of the
// stash the switch left changes in; Note is a sentence for the operator; Clash is Bring Them Along's
// pop that stopped on conflicts, for Undo Apply.
type SwitchResult struct {
	Switched bool           `json:"switched"`
	Blocked  []string       `json:"blocked,omitempty"`
	Stash    string         `json:"stash,omitempty"`
	Note     string         `json:"note,omitempty"`
	Clash    *GitStashClash `json:"clash,omitempty"`
}

// NormaliseBranchName trims a typed name and turns each run of spaces into one "-" (VS Code's default).
func NormaliseBranchName(s string) string {
	return strings.Join(strings.Fields(s), "-")
}

// inProgress refuses a write while a merge, rebase, cherry-pick or revert is stopped part-way in
// the root, naming it; nil when none is.
func (w *GitWriter) inProgress(ctx context.Context) error {
	op, _ := ReadGitOp(ctx, w.runner())
	return op.InProgressError(w.Root)
}

// notAFlag refuses a branch name that starts with "-": handed to git as a word, it would be a flag.
func notAFlag(name string) error {
	if strings.HasPrefix(name, "-") {
		return UserError(strconv.Quote(name) + " is not a branch")
	}
	return nil
}

func (w *GitWriter) validName(ctx context.Context, name string) error {
	if _, err := w.git(ctx, nil, "check-ref-format", "--branch", name); err != nil {
		return UserError(strconv.Quote(name) + " is not a valid branch name")
	}
	return nil
}

// remoteBranchExists: some remote has name, which `git switch name` checks out as a tracking branch.
func (w *GitWriter) remoteBranchExists(ctx context.Context, name string) bool {
	out, err := w.runner().Run(ctx, "for-each-ref", "--format=%(refname:short)", "refs/remotes")
	if err != nil {
		return false
	}
	for _, ref := range strings.Fields(string(out)) {
		if _, rest, ok := strings.Cut(ref, "/"); ok && rest == name {
			return true
		}
	}
	return false
}

func (w *GitWriter) localBranchExists(ctx context.Context, name string) bool {
	_, err := w.runner().Run(ctx, "rev-parse", "--verify", "refs/heads/"+name)
	return err == nil
}

// Switch moves the root to branch. Never --force or --discard-changes: changes in the way are listed,
// stashed, or brought along, as o.Carry says. A cancel stops it only before git begins the checkout or
// between its steps, never mid-checkout.
func (w *GitWriter) Switch(ctx context.Context, branch string, o SwitchOptions) (SwitchResult, error) {
	if err := w.inProgress(ctx); err != nil {
		return SwitchResult{}, err
	}
	// Each is handed to git as a word: one that starts with "-" would be a flag (-C force-resets a
	// branch, --orphan empties the tree), so it is refused, never passed.
	for _, v := range []string{branch, o.From, o.Track} {
		if err := notAFlag(v); err != nil {
			return SwitchResult{}, err
		}
	}
	if !o.Create && !w.localBranchExists(ctx, branch) && !w.remoteBranchExists(ctx, branch) {
		return SwitchResult{}, UserError("There is no branch " + branch)
	}
	args := []string{branch}
	if o.Create {
		branch = NormaliseBranchName(branch)
		if err := w.validName(ctx, branch); err != nil {
			return SwitchResult{}, err
		}
		switch {
		case w.localBranchExists(ctx, branch): // Rule 7: an existing name is switched to
			args = []string{branch}
		case o.Track != "":
			args = []string{"-c", branch, "--track", o.Track}
		case o.From != "":
			args = []string{"-c", branch, o.From}
		default:
			args = []string{"-c", branch}
		}
	}
	if err := ctx.Err(); err != nil {
		return SwitchResult{}, err
	}
	// From here no cancel cuts a step short: each runs whole, and a cancel is honoured between them.
	steady := context.WithoutCancel(ctx)
	var stash string
	if o.Carry == "stash" || o.Carry == "bring" {
		out, err := w.git(steady, nil, "stash", "push", "--include-untracked", "-m", "wakil: switch to "+branch)
		if err != nil {
			return SwitchResult{}, err
		}
		if !strings.Contains(string(out), "No local changes to save") {
			id, _ := w.runner().Run(steady, "rev-parse", "--verify", "refs/stash")
			stash = strings.TrimSpace(string(id))
		}
	}
	var hookNote string
	if _, err := w.git(steady, nil, "switch", args...); err != nil {
		if paths := overwrittenPaths(err.Error()); len(paths) > 0 && stash == "" {
			return SwitchResult{Blocked: paths}, nil
		}
		// A post-checkout hook's failure is reported as the switch's own: if HEAD moved, the
		// switch happened, and the changes must not be popped back onto the new branch.
		if cur, _ := ReadBranches(steady, w.runner()); cur.Current != branch {
			if stash != "" { // put the changes back where they were, by the stash's own id
				if ref, ok := w.stashRef(steady, stash); ok {
					w.git(steady, nil, "stash", "pop", "--index", ref)
				}
			}
			return SwitchResult{}, err
		}
		hookNote = "Switched to " + branch + ", but: " + err.Error()
	}
	r := SwitchResult{Switched: true, Stash: stash, Note: hookNote}
	if o.Carry != "bring" || stash == "" {
		return r, nil
	}
	ref, ok := w.stashRef(steady, stash)
	if !ok {
		return r, nil // dropped elsewhere between the push and now: nothing of ours to pop
	}
	if ctx.Err() != nil {
		r.Note = "Your changes are in git stash (" + ref + ")"
		return r, nil
	}
	untracked, existed := w.stashUntrackedBefore(steady, stash)
	staged, unstaged := w.stashStagedBefore(steady, stash)
	if _, err := w.git(steady, nil, "stash", "pop", ref); err != nil {
		// git keeps the stash on a clash; the conflicts are left to resolve, as a stash apply's are
		// (R5), and recorded for Undo Apply.
		if r.Clash = w.stashClash(steady, stash, untracked, existed, staged, unstaged); r.Clash != nil {
			r.Note = "Switched to " + branch + "; your changes clash with it in " + clashPaths(r.Clash) +
				" — resolve them below, or Undo Apply"
		} else {
			r.Note = "Switched to " + branch + "; your changes clash with it and are kept in git stash"
		}
		return r, nil
	}
	r.Stash = ""
	return r, nil
}

// overwrittenPaths reads the paths from git's "would be overwritten by checkout" refusal.
func overwrittenPaths(text string) []string {
	if !strings.Contains(text, "would be overwritten by checkout") {
		return nil
	}
	var paths []string
	listing := false
	for _, line := range strings.Split(text, "\n") {
		switch {
		case strings.Contains(line, "would be overwritten by checkout"):
			listing = true
		case listing && strings.HasPrefix(line, "\t"):
			paths = append(paths, strings.TrimSpace(line))
		default:
			listing = false
		}
	}
	return paths
}

// RenameBranch renames the current branch (as VS Code does). A name that exists is refused in git's
// words: forcing it would destroy the other branch.
func (w *GitWriter) RenameBranch(ctx context.Context, to string) error {
	b, err := ReadBranches(ctx, w.runner())
	if err != nil {
		return err
	}
	if b.Current == "" {
		return UserError("HEAD is detached: there is no branch to rename")
	}
	to = NormaliseBranchName(to)
	if err := w.validName(ctx, to); err != nil {
		return err
	}
	_, err = w.git(ctx, nil, "branch", "-m", to)
	return err
}

// DeleteBranch deletes a local branch. Unmerged, it refuses unless force, saying how many commits
// would be lost; git's own refusal (the current branch, one checked out in another worktree) is whole.
func (w *GitWriter) DeleteBranch(ctx context.Context, name string, force bool) error {
	if !force {
		if n, err := w.runner().Run(ctx, "rev-list", "--count", "HEAD.."+name); err == nil {
			if c, _ := strconv.Atoi(strings.TrimSpace(string(n))); c > 0 {
				cur, _ := ReadBranches(ctx, w.runner())
				on := cur.Current
				if on == "" {
					on = "HEAD"
				}
				noun := "commits"
				if c == 1 {
					noun = "commit"
				}
				return UserError(name + " has " + strconv.Itoa(c) + " " + noun + " not on " + on + "; deleting it loses them")
			}
		}
	}
	flag := "-d"
	if force {
		flag = "-D"
	}
	_, err := w.git(ctx, nil, "branch", flag, "--", name)
	return err
}
