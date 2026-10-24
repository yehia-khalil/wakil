package wakilcore

import (
	"context"
	"path/filepath"
	"strings"
)

// Resolve settles one unmerged path by a side (3a-v-b): take "current" (HEAD's whole file) or
// "incoming" (the other side's), each then staged; "keep" stages the file as it is in the tree; "delete"
// removes it from the index and the tree — Keep File and Delete File for a delete/modify conflict.
func (w *GitWriter) Resolve(ctx context.Context, path, take string) error {
	ps, err := w.paths([]string{path})
	if err != nil {
		return err
	}
	p := ps[0]
	side, ok := map[string]string{"current": "--ours", "incoming": "--theirs", "keep": "", "delete": ""}[take]
	if !ok {
		return UserError("take must be current, incoming, keep or delete, got " + take)
	}
	unmerged, err := w.git(ctx, nil, "ls-files", "-u", "-z", "--", p)
	if err != nil {
		return err
	}
	if len(unmergedPaths(unmerged)) == 0 {
		return UserError(p + " has no conflict")
	}
	if take == "delete" {
		_, err = w.git(ctx, nil, "rm", "-q", "--", p)
		return err
	}
	if side != "" {
		if _, err := w.git(ctx, nil, "checkout", side, "--", p); err != nil {
			return err
		}
	}
	_, err = w.git(ctx, nil, "add", "--", p)
	return err
}

// GitClashFile is a file a stash clash touched, with its work-tree blob id right after the clash ("" if
// the file was absent then): Undo Apply puts it back only while it still holds that.
type GitClashFile struct {
	Path string `json:"path"`
	Hash string `json:"hash"`
}

// GitStashClash records a Wakil stash apply, pop or Bring Them Along that stopped on conflicts, for Undo
// Apply (call 13): the stash's id, the files it touched (tracked, and the untracked ones it created),
// the part of those it created, and the paths left unmerged.
type GitStashClash struct {
	ID        string         `json:"id"`
	Files     []GitClashFile `json:"files"`
	Created   []string       `json:"created"`
	Conflicts []string       `json:"conflicts"`
}

// stashUntrackedBefore is a stash's untracked files, and the part of them already in the tree before
// it is applied: git leaves those alone, so a clash's record never claims them.
func (w *GitWriter) stashUntrackedBefore(ctx context.Context, id string) (untracked, existed map[string]bool) {
	g := w.runner()
	untracked, existed = map[string]bool{}, map[string]bool{}
	for _, f := range stashUntracked(ctx, g, id) {
		untracked[f] = true
		if r, err := g.ResolvePath(f); err == nil && fileExists(filepath.Join(w.Root, r)) {
			existed[f] = true
		}
	}
	return untracked, existed
}

// stashClash reads what a failed apply of stash id left: nil when it stopped before changing anything
// (no path unmerged), else the clash with each touched file's hash as it is now.
func (w *GitWriter) stashClash(ctx context.Context, id string, untracked, existed map[string]bool) *GitStashClash {
	conflicts, _ := w.conflicts(ctx)
	if len(conflicts) == 0 {
		return nil
	}
	c := &GitStashClash{ID: id, Files: []GitClashFile{}, Created: []string{}, Conflicts: conflicts}
	for _, f := range stashFiles(ctx, w.runner(), id) {
		h := w.hashOf(ctx, f)
		if untracked[f] {
			if existed[f] || h == "" {
				continue // the operator's own, or one the apply did not restore
			}
			c.Created = append(c.Created, f)
		}
		c.Files = append(c.Files, GitClashFile{Path: f, Hash: h})
	}
	return c
}

// hashOf is the blob id of rel's work-tree file, "" when there is none.
func (w *GitWriter) hashOf(ctx context.Context, rel string) string {
	r, err := w.runner().ResolvePath(rel)
	if err != nil || !fileExists(filepath.Join(w.Root, r)) {
		return ""
	}
	return w.oneOf(ctx, "hash-object", "--", filepath.ToSlash(r))
}

// clashPaths is the clash's unmerged paths for a note: "a.txt, b c.txt".
func clashPaths(c *GitStashClash) string { return strings.Join(c.Conflicts, ", ") }

// StashUndoApply puts a stash clash back (call 13, 3a-iv's recovery): the tracked files it touched go
// back to HEAD, index and tree, and the untracked files it created are removed; the stash stays. It is
// refused, naming the first, while any file differs from the clash: an edit since would be lost.
func (w *GitWriter) StashUndoApply(ctx context.Context, c GitStashClash) error {
	paths := make([]string, 0, len(c.Files))
	for _, f := range c.Files {
		paths = append(paths, f.Path)
	}
	ps, err := w.paths(paths)
	if err != nil {
		return err
	}
	for i, f := range c.Files {
		if w.hashOf(ctx, ps[i]) != f.Hash {
			return UserError(ps[i] + " changed since the clash; Undo Apply would lose that — resolve it by hand")
		}
	}
	created := map[string]bool{}
	for _, f := range c.Created {
		created[f] = true
	}
	var tracked []string
	for i, f := range c.Files {
		if created[f.Path] {
			removeInRoot(w.Root, ps[i]) // checked above: only a file the clash recorded as created
		} else {
			tracked = append(tracked, ps[i])
		}
	}
	if len(tracked) == 0 {
		return nil
	}
	steady := context.WithoutCancel(ctx)
	atHead := map[string]bool{}
	if out, err := w.git(steady, nil, "ls-tree", append([]string{"-z", "--name-only", "HEAD", "--"}, tracked...)...); err == nil {
		for _, p := range nulFields(out) {
			atHead[p] = true
		}
	}
	var restore, absent []string
	for _, p := range tracked {
		if atHead[p] {
			restore = append(restore, p)
		} else {
			absent = append(absent, p)
		}
	}
	if len(restore) > 0 {
		if _, err := w.git(steady, nil, "restore", append([]string{"--source=HEAD", "--staged", "--worktree", "--"}, restore...)...); err != nil {
			return err
		}
	}
	// Not at HEAD, so back to HEAD is gone: restore refuses an unmerged one, so the index entries
	// (any stage) are cleared, and the file goes — its contents are still in the stash.
	if len(absent) > 0 {
		if _, err := w.git(steady, nil, "rm", append([]string{"--cached", "-q", "--ignore-unmatch", "--"}, absent...)...); err != nil {
			return err
		}
		for _, p := range absent {
			removeInRoot(w.Root, p)
		}
	}
	return nil
}
