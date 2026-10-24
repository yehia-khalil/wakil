package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// GitStash is one entry of a root's stash list (3a-iv). Index is its position now; ID is its commit,
// which every action checks the position still holds — the list is shared with the terminal and every
// worktree, so positions move.
type GitStash struct {
	Index   int       `json:"index"`
	ID      string    `json:"id"`
	Message string    `json:"message"`
	Branch  string    `json:"branch"`
	Date    time.Time `json:"date"`
	Files   []string  `json:"files"`
	// Untracked is the part of Files the stash took untracked (its diff has no base side).
	Untracked []string `json:"untracked"`
}

// stashSubject reads a stash's reflog subject: "On main: msg" or "WIP on main: abc1234 msg".
var stashSubject = regexp.MustCompile(`^(?:WIP on|On) ([^:]+): (?:[0-9a-f]{7,40} )?(.*)$`)

// ReadStashes lists the root's stashes, newest first, through the read runner.
func ReadStashes(ctx context.Context, g *GitRunner) ([]GitStash, error) {
	if _, err := g.Run(ctx, "rev-parse", "--verify", "refs/stash"); err != nil {
		return []GitStash{}, nil // no stash at all
	}
	out, err := g.Run(ctx, "log", "-g", "--format=%H%x1f%gs%x1f%cI", "refs/stash", "--")
	if err != nil {
		return nil, err
	}
	stashes := []GitStash{}
	for i, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Split(line, "\x1f")
		if len(f) != 3 {
			continue
		}
		s := GitStash{Index: i, ID: f[0], Message: f[1]}
		if m := stashSubject.FindStringSubmatch(f[1]); m != nil {
			s.Branch, s.Message = m[1], m[2]
		}
		s.Date, _ = time.Parse(time.RFC3339, f[2])
		s.Files = stashFiles(ctx, g, s.ID)
		s.Untracked = stashUntracked(ctx, g, s.ID)
		stashes = append(stashes, s)
	}
	return stashes, nil
}

// stashFiles is what a stash holds: the tracked paths it changed, then its untracked ones. Read
// NUL-separated, so a name with a space or a non-ASCII letter comes back whole.
func stashFiles(ctx context.Context, g *GitRunner, id string) []string {
	files := []string{}
	if out, err := g.Run(ctx, "diff", "--name-only", "-z", id+"^1", id, "--"); err == nil {
		files = append(files, nulFields(out)...)
	}
	return append(files, stashUntracked(ctx, g, id)...)
}

// stashUntracked is the files a stash took untracked (its third parent).
func stashUntracked(ctx context.Context, g *GitRunner, id string) []string {
	out, err := g.Run(ctx, "show", "--name-only", "-z", "--format=", id+"^3", "--")
	if err != nil {
		return []string{}
	}
	return nulFields(out)
}

// Stash sets the root's changes aside: mode "default" (tracked changes), "untracked" (with untracked
// files) or "staged" (what is staged only).
func (w *GitWriter) Stash(ctx context.Context, message, mode string) error {
	// Mid-merge, a stash takes the merge's state with it and the merge is gone.
	if err := w.inProgress(ctx); err != nil {
		return err
	}
	args := []string{"push"}
	switch mode {
	case "untracked":
		args = append(args, "--include-untracked")
	case "staged":
		args = append(args, "--staged")
	}
	if message = strings.TrimSpace(message); message != "" {
		args = append(args, "-m", message)
	}
	out, err := w.git(ctx, nil, "stash", args...)
	if err != nil {
		return err
	}
	if strings.Contains(string(out), "No local changes to save") {
		return UserError("No local changes to stash")
	}
	return nil
}

// stashAt checks that position index still holds the stash id, and answers its ref.
func (w *GitWriter) stashAt(ctx context.Context, index int, id string) (string, error) {
	ref := "stash@{" + strconv.Itoa(index) + "}"
	at, err := w.runner().Run(ctx, "rev-parse", "--verify", ref)
	if err != nil || strings.TrimSpace(string(at)) != id {
		return "", UserError("The stash list changed; look again")
	}
	return ref, nil
}

// StashApply applies (or, with pop, pops) the stash at index, if it is still id. A clash keeps the
// stash and puts back what the apply changed: the tracked files it touched (each clean before, or git
// would have refused) and the untracked files it created — never a file that was there before it.
func (w *GitWriter) StashApply(ctx context.Context, index int, id string, pop bool) (string, error) {
	if err := w.inProgress(ctx); err != nil {
		return "", err
	}
	ref, err := w.stashAt(ctx, index, id)
	if err != nil {
		return "", err
	}
	g := w.runner()
	untracked := stashUntracked(ctx, g, id)
	untrackedSet := map[string]bool{}
	existed := map[string]bool{}
	for _, f := range untracked {
		untrackedSet[f] = true
		if r, err := g.ResolvePath(f); err == nil && fileExists(filepath.Join(w.Root, r)) {
			existed[f] = true
		}
	}
	verb := "apply"
	if pop {
		verb = "pop"
	}
	_, applyErr := w.git(ctx, nil, "stash", verb, ref)
	if applyErr == nil {
		return "", nil
	}
	steady := context.WithoutCancel(ctx)
	conflicted, _ := w.git(steady, nil, "ls-files", "-u", "-z")
	if len(conflicted) == 0 {
		return "", applyErr // refused before it changed anything (a file in the way)
	}
	var tracked []string
	for _, f := range stashFiles(ctx, g, id) {
		switch {
		case !untrackedSet[f]:
			tracked = append(tracked, f)
		case !existed[f]:
			removeInRoot(w.Root, f)
		}
	}
	if len(tracked) > 0 {
		w.git(steady, nil, "restore", append([]string{"--source=HEAD", "--staged", "--worktree", "--"}, tracked...)...)
	}
	b, _ := ReadBranches(ctx, g)
	on := b.Current
	if on == "" {
		on = "HEAD"
	}
	return "Your stash clashes with " + on + "; it is kept in git stash", nil
}

// StashDrop drops the stash at index, if it is still id.
func (w *GitWriter) StashDrop(ctx context.Context, index int, id string) error {
	ref, err := w.stashAt(ctx, index, id)
	if err != nil {
		return err
	}
	_, err = w.git(ctx, nil, "stash", "drop", ref)
	return err
}

// stashRef is the stash with commit id where it sits now ("stash@{n}"); false when it is gone. The
// list is shared with the terminal and every worktree, so a position is looked up, never assumed.
func (w *GitWriter) stashRef(ctx context.Context, id string) (string, bool) {
	out, err := w.runner().Run(ctx, "log", "-g", "--format=%H", "refs/stash", "--")
	if err != nil {
		return "", false
	}
	for i, h := range strings.Fields(string(out)) {
		if h == id {
			return "stash@{" + strconv.Itoa(i) + "}", true
		}
	}
	return "", false
}

// StashDropAll drops the stashes with these ids — the ones the operator was shown — and none pushed
// since, in this worktree or another. One already gone is skipped.
func (w *GitWriter) StashDropAll(ctx context.Context, ids []string) error {
	for _, id := range ids {
		ref, ok := w.stashRef(ctx, id)
		if !ok {
			continue
		}
		if _, err := w.git(ctx, nil, "stash", "drop", ref); err != nil {
			return err
		}
	}
	return nil
}

// removeInRoot deletes rel, an untracked file a failed apply restored, if it resolves inside root.
func removeInRoot(root, rel string) {
	g := &GitRunner{Root: root}
	if r, err := g.ResolvePath(rel); err == nil {
		os.Remove(filepath.Join(root, r))
	}
}
