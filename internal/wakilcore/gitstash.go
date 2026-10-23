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
		stashes = append(stashes, s)
	}
	return stashes, nil
}

// stashFiles is what a stash holds: the tracked paths it changed, then its untracked ones.
func stashFiles(ctx context.Context, g *GitRunner, id string) []string {
	files := []string{}
	if out, err := g.Run(ctx, "diff", "--name-only", id+"^1", id, "--"); err == nil {
		files = append(files, strings.Fields(string(out))...)
	}
	if out, err := g.Run(ctx, "show", "--name-only", "--format=", id+"^3", "--"); err == nil {
		files = append(files, strings.Fields(string(out))...)
	}
	return files
}

// Stash sets the root's changes aside: mode "default" (tracked changes), "untracked" (with untracked
// files) or "staged" (what is staged only).
func (w *GitWriter) Stash(ctx context.Context, message, mode string) error {
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

// StashApply applies (or, with pop, pops) the stash at index, if it is still id. A clash puts back the
// files the stash touched — each was clean before, or git would have refused — keeps the stash, and
// says so; the operator's other changes are left as they were.
func (w *GitWriter) StashApply(ctx context.Context, index int, id string, pop bool) (string, error) {
	ref, err := w.stashAt(ctx, index, id)
	if err != nil {
		return "", err
	}
	files := stashFiles(ctx, w.runner(), id)
	verb := "apply"
	if pop {
		verb = "pop"
	}
	if _, err := w.git(ctx, nil, "stash", verb, ref); err != nil {
		if !strings.Contains(err.Error(), "CONFLICT") && !strings.Contains(err.Error(), "conflict") {
			return "", err
		}
		untracked := map[string]bool{}
		if out, e := w.runner().Run(ctx, "show", "--name-only", "--format=", id+"^3", "--"); e == nil {
			for _, f := range strings.Fields(string(out)) {
				untracked[f] = true
			}
		}
		var tracked []string
		for _, f := range files {
			if untracked[f] {
				removeInRoot(w.Root, f)
			} else {
				tracked = append(tracked, f)
			}
		}
		if len(tracked) > 0 {
			w.git(context.WithoutCancel(ctx), nil, "restore", append([]string{"--source=HEAD", "--staged", "--worktree", "--"}, tracked...)...)
		}
		b, _ := ReadBranches(ctx, w.runner())
		on := b.Current
		if on == "" {
			on = "HEAD"
		}
		return "Your stash clashes with " + on + "; it is kept in git stash", nil
	}
	return "", nil
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

// StashDropAll drops every stash in the root.
func (w *GitWriter) StashDropAll(ctx context.Context) error {
	_, err := w.git(ctx, nil, "stash", "clear")
	return err
}

// removeInRoot deletes rel, an untracked file a failed apply restored, if it resolves inside root.
func removeInRoot(root, rel string) {
	g := &GitRunner{Root: root}
	if r, err := g.ResolvePath(rel); err == nil {
		os.Remove(filepath.Join(root, r))
	}
}
