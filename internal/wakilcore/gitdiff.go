package wakilcore

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const GitDiffLineCap = 5000
const GitFileByteCap = 2 << 20 // 2,097,152

type GitDiffResult struct {
	Text      string `json:"text"`
	Binary    bool   `json:"binary"`
	Lines     int    `json:"lines"` // true total
	Truncated bool   `json:"truncated"`
}

type GitShowResult struct {
	Text      string `json:"text"`
	Binary    bool   `json:"binary"`
	Bytes     int    `json:"bytes"` // true size
	Truncated bool   `json:"truncated"`
	// Absent: the file is not at this revision (untracked at index, added at HEAD), so its text
	// is empty without being an empty file. A baseline must not read it as one.
	Absent bool `json:"absent"`
}

// GitDiff returns the diff for a file at a given side (staged or changed).
func GitDiff(ctx context.Context, g *GitRunner, path, side string) (GitDiffResult, error) {
	// An empty path is the whole root (3a-ii-b): no pathspec, and git's per-file
	// "Binary files … differ" lines stay in the text.
	whole := path == ""
	rel := ""
	if !whole {
		r, err := g.ResolvePath(path)
		if err != nil {
			return GitDiffResult{}, err
		}
		rel = r
	}
	args := []string{"--no-color", "--"}
	switch side {
	case "staged":
		args = append([]string{"--cached"}, args...)
	case "changed":
	default:
		return GitDiffResult{}, UserError("side must be staged or changed, got " + side)
	}
	if !whole {
		args = append(args, rel)
	}
	out, err := g.Run(ctx, "diff", args...)
	if err != nil {
		return GitDiffResult{}, err
	}
	if !whole && (bytes.Contains(out, []byte("\nBinary files ")) || bytes.HasPrefix(out, []byte("Binary files "))) {
		return GitDiffResult{Binary: true}, nil
	}
	lines := strings.SplitAfter(string(out), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	r := GitDiffResult{Lines: len(lines)}
	if len(lines) > GitDiffLineCap {
		lines, r.Truncated = lines[:GitDiffLineCap], true
	}
	r.Text = strings.Join(lines, "")
	return r, nil
}

// GitShow returns the content of a file at a given revision (HEAD, index, or worktree).
func GitShow(ctx context.Context, g *GitRunner, path, rev string) (GitShowResult, error) {
	rel, err := g.ResolvePath(path)
	if err != nil {
		return GitShowResult{}, err
	}
	var data []byte
	switch rev {
	case "HEAD":
		data, err = g.Run(ctx, "show", "HEAD:"+filepath.ToSlash(rel))
	case "index":
		data, err = g.Run(ctx, "show", ":"+filepath.ToSlash(rel))
	case "worktree":
		var size int
		data, size, err = readWorktree(g.Root, rel)
		if err == nil {
			r := capShown(data)
			r.Bytes = size
			return r, nil
		}
	default:
		return GitShowResult{}, UserError("rev must be HEAD, index or worktree, got " + rev)
	}
	if err != nil {
		// A file absent at HEAD (added) or in the index (untracked) has an empty original side.
		// Also handle staged deletions: "does not exist (neither on disk nor in the index)".
		if (rev != "worktree") && (strings.Contains(err.Error(), "exists on disk, but not in") ||
			strings.Contains(err.Error(), "does not exist in") ||
			strings.Contains(err.Error(), "does not exist (neither on disk")) {
			return GitShowResult{Absent: true}, nil
		}
		return GitShowResult{}, err
	}
	r := capShown(data)
	r.Bytes = len(data)
	return r, nil
}

// readWorktree reads one work-tree file for git_show's worktree side, answering its bytes
// (at most GitFileByteCap+1 of them) and its true size.
//
//   - **Nothing under a `.git` directory.** That is the repository, not its work tree; the
//     name is compared without case, because APFS folds `.GIT` to `.git`.
//   - **A symlink is its target text**, which is what git diffs for one — and never the
//     file it names, which could be `.git/config`.
//   - **A regular file only.** A FIFO would block the read until a writer came and a device
//     never ends; both are refused by their mode, before anything opens them.
//   - **At most the cap and one byte**, so a file of any size costs 2 MB; the one byte
//     past it is what says the file was cut.
//
// A path that does not exist is a deletion: its side is empty.
func readWorktree(root, rel string) ([]byte, int, error) {
	inGit := UserError("path is inside the repository's .git, not its work tree: " + rel)
	if hasGitSegment(rel) {
		return nil, 0, inGit
	}
	full := filepath.Join(root, rel)
	// The name asked for is not the directory read: `sub -> .git` makes `sub/config` the
	// repository's config. The refusal is checked again on the parent directory with every
	// symlink resolved, relative to the real root. The last element is not resolved — a
	// symlink there is its target text, below. A parent that does not exist is a deletion,
	// answered empty by the Lstat that follows.
	if realRoot, err := filepath.EvalSymlinks(root); err == nil {
		if realDir, err := filepath.EvalSymlinks(filepath.Dir(full)); err == nil {
			if r, err := filepath.Rel(realRoot, realDir); err != nil || hasGitSegment(r) {
				return nil, 0, inGit
			}
		} else if !os.IsNotExist(err) {
			return nil, 0, UserError("path unreadable: " + err.Error())
		}
	}
	fi, err := os.Lstat(full)
	if os.IsNotExist(err) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, UserError("path unreadable: " + err.Error())
	}
	switch mode := fi.Mode(); {
	case mode&os.ModeSymlink != 0:
		target, err := os.Readlink(full)
		if err != nil {
			return nil, 0, UserError("path unreadable: " + err.Error())
		}
		return []byte(target), len(target), nil
	case !mode.IsRegular():
		return nil, 0, UserError("not a regular file (" + mode.Type().String() + "): " + rel)
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, 0, UserError("path unreadable: " + err.Error())
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, GitFileByteCap+1))
	if err != nil {
		return nil, 0, UserError("path unreadable: " + err.Error())
	}
	return data, int(max(fi.Size(), int64(len(data)))), nil
}

// hasGitSegment reports whether one element of the slash- or separator-split rel is `.git`,
// in any letter case (APFS folds `.GIT` to `.git`). `.github`, `foo.git` and `.gitignore`
// are ordinary names.
func hasGitSegment(rel string) bool {
	for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
		if strings.EqualFold(part, ".git") {
			return true
		}
	}
	return false
}

// capShown is what git_show shows of data: nothing for a binary, else the text cut to
// GitFileByteCap on a UTF-8 boundary. The caller sets Bytes.
func capShown(data []byte) GitShowResult {
	var r GitShowResult
	if bytes.IndexByte(data[:min(len(data), 8000)], 0) >= 0 {
		r.Binary = true
		return r
	}
	if len(data) > GitFileByteCap {
		data, r.Truncated = data[:GitFileByteCap], true
		// Trim back to UTF-8 rune boundary only at the very end.
		// Walk back from the end to find the start of the last rune.
		for i := len(data) - 1; i >= 0 && i > len(data)-utf8.UTFMax; i-- {
			if utf8.RuneStart(data[i]) {
				if !utf8.FullRune(data[i:]) {
					data = data[:i]
				}
				break
			}
		}
	}
	r.Text = string(data)
	return r
}
