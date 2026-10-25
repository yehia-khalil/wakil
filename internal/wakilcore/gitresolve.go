package wakilcore

import (
	"context"
	"path/filepath"
	"slices"
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
	// The listing matches by pathspec, so a directory or "." would list every conflict under it:
	// only the one path named is resolved.
	if !slices.Contains(unmergedPaths(unmerged), p) {
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
// the part of those it created, and the paths left unmerged. One is recorded only when the stash's paths
// held nothing of the operator's own before the apply (stashCleanBefore), so putting them back is exact.
type GitStashClash struct {
	ID        string         `json:"id"`
	Files     []GitClashFile `json:"files"`
	Created   []string       `json:"created"`
	Conflicts []string       `json:"conflicts"`
}

// stashCleanBefore reports, before stash id is applied, whether every path it touches is clean: the
// tracked ones (both names of a rename) and its untracked ones with the index at HEAD and the tree at
// the index, none marked assume-unchanged or skip-worktree (git hides an edit there), and no untracked
// file at any of them. Only then does Undo Apply's put-back — HEAD for the tracked paths, removal of
// what the apply created — lose nothing; otherwise the clash is left to resolve by hand, as VS Code
// leaves it. A read that fails, or lists nothing, is not clean.
func (w *GitWriter) stashCleanBefore(ctx context.Context, id string) bool {
	tracked, untracked, err := stashPaths(ctx, w.runner(), id)
	files := append(tracked, untracked...)
	if err != nil || len(files) == 0 {
		return false
	}
	for _, args := range [][]string{
		{"diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--"},
		{"diff", "--name-only", "--no-renames", "-z", "--"},
		{"ls-files", "--others", "-z", "--"}, // ignored ones too: no --exclude-standard
	} {
		if out, err := w.git(ctx, nil, args[0], append(args[1:], files...)...); err != nil || len(nulFields(out)) > 0 {
			return false
		}
	}
	out, err := w.git(ctx, nil, "ls-files", append([]string{"-v", "-z", "--"}, files...)...)
	if err != nil {
		return false
	}
	for _, rec := range nulFields(out) { // "<tag> <path>": lower case is assume-unchanged, S skip-worktree
		if tag, _, ok := strings.Cut(rec, " "); !ok || tag == "S" || strings.ToLower(tag) == tag {
			return false
		}
	}
	return true
}

// stashClash reads what a failed apply of stash id left: nil when it stopped before changing anything
// (no path unmerged), else the clash with each touched file's hash as it is now. With an error the
// clash names only its conflicts: the record could not be read, so it is not one Undo Apply can use.
func (w *GitWriter) stashClash(ctx context.Context, id string) (*GitStashClash, error) {
	conflicts, _ := w.conflicts(ctx)
	if len(conflicts) == 0 {
		return nil, nil
	}
	c := &GitStashClash{ID: id, Files: []GitClashFile{}, Created: []string{}, Conflicts: conflicts}
	tracked, untracked, err := stashPaths(ctx, w.runner(), id)
	if err != nil {
		return c, err
	}
	isUntracked, atHead := map[string]bool{}, map[string]bool{}
	if len(untracked) > 0 {
		for _, f := range untracked {
			isUntracked[f] = true
		}
		out, err := w.git(ctx, nil, "ls-tree", append([]string{"-z", "--name-only", "HEAD", "--"}, untracked...)...)
		if err != nil {
			return c, err
		}
		for _, f := range nulFields(out) {
			atHead[f] = true
		}
	}
	for _, f := range append(tracked, untracked...) {
		h := w.hashOf(ctx, f)
		if isUntracked[f] {
			// HEAD's own, clean before the apply (stashCleanBefore), so git left it alone; or one the
			// apply did not restore.
			if atHead[f] || h == "" {
				continue
			}
			c.Created = append(c.Created, f)
		}
		c.Files = append(c.Files, GitClashFile{Path: f, Hash: h})
	}
	return c, nil
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
// back to HEAD, index and tree, and the untracked files it created are removed; the stash stays. A clash
// is recorded only over paths that were clean before the apply, so that is all they held. It is refused,
// naming the first, while any file differs from the clash: an edit made since would be lost.
func (w *GitWriter) StashUndoApply(ctx context.Context, c GitStashClash) error {
	paths := make([]string, 0, len(c.Files))
	for _, f := range c.Files {
		paths = append(paths, f.Path)
	}
	ps, err := w.paths(paths)
	if err != nil {
		return err
	}
	// The stash holds the only copy of what the put-back removes: once it is dropped, nothing is.
	if _, ok := w.stashRef(ctx, c.ID); !ok || c.ID == "" {
		return UserError("The stash is gone, so Undo Apply would lose its changes; resolve it by hand")
	}
	// The record comes back from the caller: it may name only the stash's own paths, and only its
	// untracked ones as created.
	tracked, untracked, err := stashPaths(ctx, w.runner(), c.ID)
	if err != nil {
		return err
	}
	own := map[string]bool{}
	for _, f := range tracked {
		own[f] = true
	}
	ownUntracked := map[string]bool{}
	for _, f := range untracked {
		own[f], ownUntracked[f] = true, true
	}
	mismatch := UserError("That clash record doesn't match the stash; resolve it by hand")
	for _, f := range c.Files {
		if !own[f.Path] {
			return mismatch
		}
	}
	for _, f := range c.Created {
		if !ownUntracked[f] {
			return mismatch
		}
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
	var remove, put []string
	for i, f := range c.Files {
		if created[f.Path] {
			remove = append(remove, ps[i])
		} else {
			put = append(put, ps[i])
		}
	}
	// Read before anything is written: a failed read would make every tracked path look absent from
	// HEAD, and be deleted.
	steady := context.WithoutCancel(ctx)
	atHead := map[string]bool{}
	if len(put) > 0 {
		out, err := w.git(steady, nil, "ls-tree", append([]string{"-z", "--name-only", "HEAD", "--"}, put...)...)
		if err != nil {
			return UserError("Undo Apply could not read HEAD; resolve it by hand")
		}
		for _, p := range nulFields(out) {
			atHead[p] = true
		}
	}
	for _, p := range remove {
		removeInRoot(w.Root, p) // checked above: only a file the clash recorded as created
	}
	var restore, absent []string
	for _, p := range put {
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
