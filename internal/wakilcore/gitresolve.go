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

// GitClashIndex is a file the stash touches whose index entry differed from HEAD before the apply: an
// edit staged then is in no stash, so Undo Apply puts that entry back (Mode and Hash "" for a staged
// deletion) rather than HEAD's.
type GitClashIndex struct {
	Path string `json:"path"`
	Mode string `json:"mode"`
	Hash string `json:"hash"`
}

// GitStashClash records a Wakil stash apply, pop or Bring Them Along that stopped on conflicts, for Undo
// Apply (call 13): the stash's id, the files it touched (tracked, and the untracked ones it created),
// the part of those it created, the paths left unmerged, the index entries staged before it, and the
// tracked ones whose tree file had unstaged edits before it.
type GitStashClash struct {
	ID        string          `json:"id"`
	Files     []GitClashFile  `json:"files"`
	Created   []string        `json:"created"`
	Conflicts []string        `json:"conflicts"`
	Staged    []GitClashIndex `json:"staged,omitempty"`
	Unstaged  []string        `json:"unstaged,omitempty"`
}

// stashStagedBefore is the index entries, before stash id is applied, of the files it touches that
// differ from HEAD, and the tracked files it touches whose tree differs from the index. git applies a
// stash over a staged edit (the edit becomes the upstream side), so putting those files back to HEAD
// would lose it; and where the index (staged or HEAD's) already matches the stash's copy, git applies
// without looking at the tree, so an unstaged edit survives the apply but not the put-back.
func (w *GitWriter) stashStagedBefore(ctx context.Context, id string) (staged []GitClashIndex, unstaged []string) {
	staged, unstaged = []GitClashIndex{}, []string{}
	files := stashFiles(ctx, w.runner(), id)
	if len(files) == 0 {
		return staged, unstaged
	}
	if out, err := w.git(ctx, nil, "diff", append([]string{"--name-only", "-z", "--"}, files...)...); err == nil {
		unstaged = nulFields(out)
	}
	out, err := w.git(ctx, nil, "diff", append([]string{"--cached", "--name-only", "-z", "HEAD", "--"}, files...)...)
	if err != nil {
		return staged, unstaged
	}
	changed := nulFields(out)
	if len(changed) == 0 {
		return staged, unstaged
	}
	entries := map[string]GitClashIndex{}
	if out, err := w.git(ctx, nil, "ls-files", append([]string{"-s", "-z", "--"}, changed...)...); err == nil {
		for _, rec := range nulFields(out) {
			meta, p, ok := strings.Cut(rec, "\t") // "<mode> <id> <stage>\t<path>"
			if f := strings.Fields(meta); ok && len(f) == 3 && f[2] == "0" {
				entries[p] = GitClashIndex{Path: p, Mode: f[0], Hash: f[1]}
			}
		}
	}
	for _, p := range changed {
		if e, ok := entries[p]; ok {
			staged = append(staged, e)
		} else {
			staged = append(staged, GitClashIndex{Path: p}) // staged as deleted
		}
	}
	return staged, unstaged
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
func (w *GitWriter) stashClash(ctx context.Context, id string, untracked, existed map[string]bool, staged []GitClashIndex, unstaged []string) *GitStashClash {
	conflicts, _ := w.conflicts(ctx)
	if len(conflicts) == 0 {
		return nil
	}
	c := &GitStashClash{ID: id, Files: []GitClashFile{}, Created: []string{}, Conflicts: conflicts, Staged: staged, Unstaged: unstaged}
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
// back to HEAD, index and tree, or to the entry staged before the apply, and the untracked files it
// created are removed; the stash stays. It is refused, naming the first, while any file differs from
// the clash, or had unstaged edits before it: either would be lost.
func (w *GitWriter) StashUndoApply(ctx context.Context, c GitStashClash) error {
	paths := make([]string, 0, len(c.Files))
	for _, f := range c.Files {
		paths = append(paths, f.Path)
	}
	ps, err := w.paths(paths)
	if err != nil {
		return err
	}
	stagedPaths := make([]string, 0, len(c.Staged))
	for _, e := range c.Staged {
		if e.Hash != "" && !slices.Contains([]string{"100644", "100755", "120000"}, e.Mode) {
			return UserError(e.Path + " has no file mode to put back")
		}
		stagedPaths = append(stagedPaths, e.Path)
	}
	var staged []string
	if len(stagedPaths) > 0 {
		if staged, err = w.paths(stagedPaths); err != nil {
			return err
		}
	}
	var unstaged []string
	if len(c.Unstaged) > 0 {
		if unstaged, err = w.paths(c.Unstaged); err != nil {
			return err
		}
	}
	// The stash holds the only copy of what the put-back removes: once it is dropped, nothing is.
	if _, ok := w.stashRef(ctx, c.ID); !ok || c.ID == "" {
		return UserError("The stash is gone, so Undo Apply would lose its changes; resolve it by hand")
	}
	for i, f := range c.Files {
		if w.hashOf(ctx, ps[i]) != f.Hash {
			return UserError(ps[i] + " changed since the clash; Undo Apply would lose that — resolve it by hand")
		}
	}
	// The put-back writes the staged copy, or HEAD's, over the tree; an unstaged edit made before the
	// apply that git left alone is in no stash.
	if len(unstaged) > 0 {
		return UserError(unstaged[0] + " has unstaged edits; Undo Apply would lose them — resolve it by hand")
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
	return w.putBackStaged(steady, c.Staged, staged)
}

// putBackStaged restores, after the put-back to HEAD, the index entries staged before the apply, and
// writes each one's blob to the tree (git refused the apply over a tree file that differed from its
// index, so the tree held that too). A staged deletion is staged again; HEAD's copy stays in the tree.
func (w *GitWriter) putBackStaged(ctx context.Context, entries []GitClashIndex, paths []string) error {
	for i, e := range entries {
		p := paths[i]
		if e.Hash == "" {
			if _, err := w.git(ctx, nil, "rm", "--cached", "-q", "--ignore-unmatch", "--", p); err != nil {
				return err
			}
			continue
		}
		if _, err := w.git(ctx, nil, "update-index", "--add", "--cacheinfo", e.Mode+","+e.Hash+","+p); err != nil {
			return err
		}
		if _, err := w.git(ctx, nil, "checkout-index", "-f", "--", p); err != nil {
			return err
		}
	}
	return nil
}
