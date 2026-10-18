package wakilcore

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// trashBin moves a path to the user's Trash. macOS ships it from 15; Go is built without cgo, so
// NSFileManager is out of reach (3b-iv, Decision 41). A variable so tests point it at a fake.
var trashBin = "/usr/bin/trash"

// FileEntry is a file or folder a 3b-iv write made or trashed.
type FileEntry struct {
	Path string `json:"path"`
	Root string `json:"root"`
	Kind string `json:"kind"` // "file" or "dir"
}

// FileMoved is a rename or move.
type FileMoved struct {
	From string `json:"from"`
	To   string `json:"to"`
	Kind string `json:"kind"`
}

func entryKind(fi fs.FileInfo) string {
	if fi.IsDir() {
		return "dir"
	}
	return "file"
}

// confineEntry confines path's parent folder and keeps its last name unresolved, so a link is
// created, moved or trashed as itself and nothing outside the roots is touched (3b-iv). A root
// itself, and "." or ".." as the name, are refused.
func confineEntry(path string, roots []string, mustExist bool) (string, string, error) {
	if !filepath.IsAbs(path) {
		return "", "", UserError("path must be absolute, got " + path)
	}
	if b := filepath.Base(path); b == "." || b == ".." {
		return "", "", UserError(path + " names no file or folder")
	}
	clean := filepath.Clean(path)
	name := filepath.Base(clean)
	if dir, e := filepath.EvalSymlinks(filepath.Dir(clean)); e == nil && slices.Contains(realRoots(roots), filepath.Join(dir, name)) {
		return "", "", UserError(path + " is a root of the active project; a root is not moved or trashed")
	}
	parent, root, err := ConfineFilePath(filepath.Dir(clean), roots, false)
	if err != nil {
		return "", "", err
	}
	real := filepath.Join(parent, name)
	if mustExist {
		if _, err := os.Lstat(real); err != nil {
			return "", "", UserError(path + " does not exist")
		}
	}
	return real, root, nil
}

func existsOr(path string, err error) error {
	if errors.Is(err, fs.ErrExist) {
		return UserError(path + " already exists")
	}
	return err
}

// CreateEntry makes an empty file (0644) or a folder, and any missing folders above it. It never
// overwrites: an existing name is refused.
func CreateEntry(path, kind string, roots []string) (FileEntry, error) {
	if kind != "file" && kind != "dir" {
		return FileEntry{}, UserError(`kind must be "file" or "dir", got ` + strconv.Quote(kind))
	}
	real, root, err := confineEntry(path, roots, false)
	if err != nil {
		return FileEntry{}, err
	}
	if _, err := os.Lstat(real); err == nil {
		return FileEntry{}, UserError(path + " already exists")
	}
	if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
		return FileEntry{}, err
	}
	if kind == "dir" {
		if err := os.Mkdir(real, 0o755); err != nil {
			return FileEntry{}, existsOr(path, err)
		}
	} else {
		f, err := os.OpenFile(real, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			return FileEntry{}, existsOr(path, err)
		}
		if err := f.Close(); err != nil {
			return FileEntry{}, err
		}
	}
	return FileEntry{Path: real, Root: root, Kind: kind}, nil
}

// MoveEntry renames or moves from to to, making missing folders above to. An existing to is
// refused unless it is from itself (a case-only rename on a case-insensitive volume); the same
// name is ignored (Rule 7); a move across volumes is refused (ruling R3).
func MoveEntry(from, to string, roots []string) (FileMoved, error) {
	src, _, err := confineEntry(from, roots, true)
	if err != nil {
		return FileMoved{}, err
	}
	dst, _, err := confineEntry(to, roots, false)
	if err != nil {
		return FileMoved{}, err
	}
	si, err := os.Lstat(src)
	if err != nil {
		return FileMoved{}, err
	}
	moved := FileMoved{From: src, To: dst, Kind: entryKind(si)}
	if dst == src {
		return moved, nil
	}
	if strings.HasPrefix(dst, src+string(filepath.Separator)) {
		return FileMoved{}, UserError("cannot move " + from + " into itself (" + to + ")")
	}
	if di, err := os.Lstat(dst); err == nil && !os.SameFile(si, di) {
		return FileMoved{}, UserError(to + " already exists")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return FileMoved{}, err
	}
	if err := os.Rename(src, dst); err != nil {
		if errors.Is(err, syscall.EXDEV) {
			return FileMoved{}, UserError(from + " and " + to + " are on different volumes; a move across volumes is not offered")
		}
		return FileMoved{}, err
	}
	return moved, nil
}

// TrashEntry moves path to the user's Trash through trashBin; a link goes as itself.
func TrashEntry(ctx context.Context, path string, roots []string) (FileEntry, error) {
	real, root, err := confineEntry(path, roots, true)
	if err != nil {
		return FileEntry{}, err
	}
	if _, err := os.Stat(trashBin); err != nil {
		return FileEntry{}, UserError("Move to Trash needs macOS 15: " + trashBin + " is missing")
	}
	fi, err := os.Lstat(real)
	if err != nil {
		return FileEntry{}, err
	}
	if out, err := exec.CommandContext(ctx, trashBin, "-s", real).CombinedOutput(); err != nil {
		return FileEntry{}, UserError("could not move " + path + " to the Trash: " + strings.TrimSpace(string(out)) + " (" + err.Error() + ")")
	}
	return FileEntry{Path: real, Root: root, Kind: entryKind(fi)}, nil
}
