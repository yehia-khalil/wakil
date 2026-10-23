package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

// FileCap is the most text files_read returns at once; over it, the file's last FileCap bytes (3b-vii).
const FileCap = 2 << 20

// FileListCap is the most files plus ignored entries files_list returns for one root.
const FileListCap = 50000

// FileRead is one file's text and facts. Text is empty when the file is over the cap,
// binary, not UTF-8, or missing; the flags say which.
type FileRead struct {
	Path    string `json:"path"`
	Root    string `json:"root"`
	Text    string `json:"text"`
	Size    int    `json:"size"`
	Mtime   int64  `json:"mtime"`
	Binary  bool   `json:"binary"`
	UTF8    bool   `json:"utf8"`
	OverCap bool   `json:"over_cap"`
	Exists  bool   `json:"exists"`
	// Tail: over the cap, Text is the file's last FileCap bytes from the first line start; Start is
	// its offset. End is the offset after Text (3b-vii).
	Tail   bool `json:"tail"`
	Start  int  `json:"start"`
	End    int  `json:"end"`
	Shrunk bool `json:"shrunk"`  // from: the file is now shorter than from
	TooFar bool `json:"too_far"` // from: more than FileCap bytes lie past from
}

// FileWritten is what a write left on disk.
type FileWritten struct {
	Path  string `json:"path"`
	Size  int    `json:"size"`
	Mtime int64  `json:"mtime"`
}

func outsideRoots(path string) error {
	return UserError(path + " is outside the active project's roots; editor writes and reads are " +
		"confined to them")
}

// realRoots answers each root symlink-resolved; a root that cannot be resolved is skipped.
func realRoots(roots []string) []string {
	var out []string
	for _, r := range roots {
		if rr, err := filepath.EvalSymlinks(r); err == nil {
			out = append(out, rr)
		}
	}
	return out
}

func under(path, root string) bool {
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

// ConfineFilePath resolves path (absolute) through symlinks and answers it with the root
// holding it. A path that does not exist yet (mustExist false) is resolved through its
// nearest existing ancestor, so a link anywhere above it is followed before the check.
func ConfineFilePath(path string, roots []string, mustExist bool) (string, string, error) {
	if !filepath.IsAbs(path) {
		return "", "", UserError("path must be absolute, got " + path)
	}
	clean := filepath.Clean(path)
	real, err := filepath.EvalSymlinks(clean)
	if err != nil {
		if mustExist || !errors.Is(err, fs.ErrNotExist) {
			return "", "", UserError(path + " is not readable: " + err.Error())
		}
		// A name Lstat can see but EvalSymlinks cannot resolve is a dangling link: its target
		// is unknowable, so it is refused rather than treated as a missing name.
		if _, lerr := os.Lstat(clean); lerr == nil {
			return "", "", outsideRoots(path)
		}
		// Walk up to the nearest ancestor that exists, resolve it, and re-attach the rest.
		rest := []string{filepath.Base(clean)}
		dir := filepath.Dir(clean)
		for {
			if r, e := filepath.EvalSymlinks(dir); e == nil {
				real = filepath.Join(append([]string{r}, rest...)...)
				break
			} else if !errors.Is(e, fs.ErrNotExist) || dir == filepath.Dir(dir) {
				return "", "", UserError(path + " is not reachable: " + e.Error())
			}
			if _, lerr := os.Lstat(dir); lerr == nil {
				return "", "", outsideRoots(path)
			}
			rest = append([]string{filepath.Base(dir)}, rest...)
			dir = filepath.Dir(dir)
		}
	}
	for _, r := range realRoots(roots) {
		if under(real, r) {
			return real, r, nil
		}
	}
	return "", "", outsideRoots(path)
}

// skippedDirs are folders a walk never enters: version-control metadata and the heavy,
// conventionally ignored dependency, cache and build folders. Only the walk uses this; a
// git repository's own ignores decide what git lists.
var skippedDirs = map[string]bool{
	".git": true, ".hg": true, ".svn": true,
	"node_modules": true, "bower_components": true,
	".venv": true, "venv": true, "__pycache__": true, ".mypy_cache": true, ".pytest_cache": true, ".tox": true,
	".gradle": true, ".next": true, ".nuxt": true, ".turbo": true, ".parcel-cache": true, ".cache": true,
	".build": true, "DerivedData": true, "Pods": true, "vendor": true,
}

// errListFull stops a walk once it holds more than FileListCap files.
var errListFull = errors.New("file list full")

// FileList is one root's files, relative and slash-separated, sorted. Ignored are the gitignored
// files outside the heavy folders; Heavy the heavy folders found, never walked; Repos the child
// repositories of a folder of repositories (3b-ii).
type FileList struct {
	Root    string   `json:"root"`
	Files   []string `json:"files"`
	Ignored []string `json:"ignored"`
	Heavy   []string `json:"heavy"`
	Repos   []string `json:"repos"`
	// Empty is the folders holding nothing git or the walk lists (3b-iv ruling R1): a folder New
	// Folder just made, which a file listing alone would never show.
	Empty     []string `json:"empty"`
	Truncated bool     `json:"truncated"`
}

// DirEntry is one entry of a folder files_list_dir read.
type DirEntry struct {
	Name string `json:"name"`
	Kind string `json:"kind"` // "file" or "dir"
}

// DirList is one folder's direct entries, folders first, each sorted by name.
type DirList struct {
	Root    string     `json:"root"`
	Dir     string     `json:"dir"`
	Entries []DirEntry `json:"entries"`
}

// gitLines runs git in dir and splits its -z output.
func gitLines(ctx context.Context, dir string, args ...string) ([]string, error) {
	cmd := exec.CommandContext(ctx, "git", append(append([]string{}, gitSafetyArgs...), args...)...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var lines []string
	for _, f := range bytes.Split(out, []byte{0}) {
		if len(f) > 0 {
			lines = append(lines, string(f))
		}
	}
	return lines, nil
}

// gitListFiles answers git's view of the repository at dir: tracked plus untracked, ignores
// applied, relative to dir. Its exec-and-split body is now gitLines'.
func gitListFiles(ctx context.Context, dir string) ([]string, error) {
	return gitLines(ctx, dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
}

// gitListIgnored answers the ignored files of the repository at dir, outside the heavy folders.
// Pathspec excludes, not --exclude: --exclude would ADD an ignore pattern (measured).
func gitListIgnored(ctx context.Context, dir string, heavy []string) ([]string, error) {
	args := []string{"ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", "."}
	for _, h := range heavy {
		args = append(args, ":(exclude,glob)**/"+globLiteral(h)+"/**")
	}
	return gitLines(ctx, dir, args...)
}

// gitListHeavy answers the repository's ignored heavy folders, plus its own .git. `--directory`
// collapses an ignored folder to one "name/" entry; the base name decides heaviness (a pathspec
// does not filter --directory output reliably — measured: `storage/` came back for `**/vendor`).
func gitListHeavy(ctx context.Context, dir string, names []string) ([]string, error) {
	lines, err := gitLines(ctx, dir, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	heavy := []string{".git"}
	for _, l := range lines {
		if strings.HasSuffix(l, "/") {
			d := strings.TrimSuffix(l, "/")
			if slices.Contains(names, filepath.Base(d)) {
				heavy = append(heavy, d)
			}
		}
	}
	return heavy, nil
}

// gitListEmpty answers the repository's untracked folders that hold no file git lists: `--directory`
// reports such a folder as one "name/" entry, collapsed to its top, even when it holds files; the
// caller walks each for the folders inside that have no entry (addEmptyUnder).
func gitListEmpty(ctx context.Context, dir string) ([]string, error) {
	lines, err := gitLines(ctx, dir, "ls-files", "-z", "--others", "--exclude-standard", "--directory")
	if err != nil {
		return nil, err
	}
	var out []string
	for _, l := range lines {
		if strings.HasSuffix(l, "/") && !isNestedRepo(dir, l) {
			out = append(out, strings.TrimSuffix(l, "/"))
		}
	}
	return out, nil
}

// addEmptyUnder adds every folder in d, an untracked folder git collapsed to one "d/" entry
// ("made/deeper" comes back as "made/"), that holds no entry, d itself included; it skips
// nested repositories and heavy folders as the walk does.
func (w *walked) addEmptyUnder(real, d string) {
	top := filepath.Join(real, filepath.FromSlash(d))
	_ = filepath.WalkDir(top, func(p string, e fs.DirEntry, err error) error {
		if err != nil || !e.IsDir() {
			return nil
		}
		if p != top {
			if w.isHeavy(e.Name()) || skippedDirs[e.Name()] {
				return filepath.SkipDir
			}
			if _, serr := os.Lstat(filepath.Join(p, ".git")); serr == nil {
				return filepath.SkipDir
			}
		}
		if entries, rerr := os.ReadDir(p); rerr == nil && len(entries) == 0 {
			rel, _ := filepath.Rel(real, p)
			w.empty = append(w.empty, filepath.ToSlash(rel))
		}
		return nil
	})
}

// walked is one listing in progress. heavyNames is the heavy folder names, .git first (3b-v part 2:
// the active project's list, HeavyNames); the non-git walk's skippedDirs stay built in. Heavy
// folders are listed as one entry each and never walked: their contents load only when the
// operator opens one (files_list_dir, 3b-ii).
type walked struct {
	files, ignored, heavy, repos, empty []string
	heavyNames                          []string
}

func (w *walked) isHeavy(name string) bool { return slices.Contains(w.heavyNames, name) }

// globLiteral escapes a folder name for a glob pathspec, so a name holding * ? [ or \ matches
// only itself (Review Focus 2).
func globLiteral(name string) string {
	var b strings.Builder
	for _, r := range name {
		if strings.ContainsRune(`*?[\`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func (w *walked) full() bool { return len(w.files) > FileListCap }

func (w *walked) addIgnored(f string) {
	if len(w.ignored) <= FileListCap {
		w.ignored = append(w.ignored, f)
	}
}

// isNestedRepo: git lists an untracked repository inside a repository as one "name/" entry
// (measured); it is a child repository when it holds its own .git.
func isNestedRepo(dir, entry string) bool {
	if !strings.HasSuffix(entry, "/") {
		return false
	}
	_, err := os.Lstat(filepath.Join(dir, filepath.FromSlash(entry), ".git"))
	return err == nil
}

// addTracked adds a repository's git listing under prefix, each nested repository in it listed
// as a child repository (final review I3), never as a "name/" file row.
func (w *walked) addTracked(ctx context.Context, dir, prefix string, files []string) {
	for _, f := range files {
		if isNestedRepo(dir, f) {
			w.addChildRepo(ctx, filepath.Join(dir, filepath.FromSlash(f)), prefix+strings.TrimSuffix(f, "/"))
			continue
		}
		w.files = append(w.files, prefix+f)
	}
}

// addIgnoredOf adds a repository's ignored files under prefix. An ignored nested repository
// comes back as one "name/" entry: it is a heavy folder, shown and loaded on demand, never
// searched.
func (w *walked) addIgnoredOf(dir, prefix string, ignored []string) {
	for _, f := range ignored {
		if isNestedRepo(dir, f) {
			// git's heavy-folder exclude does not drop a collapsed "vendor/pkg/" (measured).
			if !w.underHeavy(f) {
				w.heavy = append(w.heavy, prefix+strings.TrimSuffix(f, "/"))
			}
			continue
		}
		w.addIgnored(prefix + f)
	}
}

// underHeavy: some folder of rel, a "/"-separated path, is a heavy folder.
func (w *walked) underHeavy(rel string) bool {
	parts := strings.Split(strings.TrimSuffix(rel, "/"), "/")
	for _, p := range parts[:len(parts)-1] {
		if w.isHeavy(p) {
			return true
		}
	}
	return false
}

// addChildRepo lists the repository at p, rel to the root, through git: its files, ignored and
// heavy folders under rel/. It answers false when p is not one git can list.
func (w *walked) addChildRepo(ctx context.Context, p, rel string) bool {
	sub, err := gitListFiles(ctx, p)
	if err != nil {
		return false
	}
	w.repos = append(w.repos, rel)
	prefix := rel + "/"
	w.addTracked(ctx, p, prefix, sub)
	if ig, ierr := gitListIgnored(ctx, p, w.heavyNames); ierr == nil {
		w.addIgnoredOf(p, prefix, ig)
	}
	if hv, herr := gitListHeavy(ctx, p, w.heavyNames); herr == nil {
		for _, h := range hv {
			w.heavy = append(w.heavy, prefix+h)
		}
	}
	return true
}

func walkFiles(ctx context.Context, real string, heavy []string) (walked, error) {
	w := walked{heavyNames: heavy}
	err := filepath.WalkDir(real, func(p string, d fs.DirEntry, e error) error {
		if cerr := ctx.Err(); cerr != nil {
			return cerr
		}
		if e != nil {
			if d != nil && d.IsDir() && p != real {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(real, p)
		rel = filepath.ToSlash(rel)
		if !d.IsDir() {
			w.files = append(w.files, rel)
			if w.full() {
				return errListFull
			}
			return nil
		}
		if p == real {
			return nil
		}
		if skippedDirs[d.Name()] {
			w.heavy = append(w.heavy, rel)
			return filepath.SkipDir
		}
		if _, serr := os.Lstat(filepath.Join(p, ".git")); serr == nil {
			if w.addChildRepo(ctx, p, rel) {
				if w.full() {
					return errListFull
				}
				return filepath.SkipDir
			}
		}
		if entries, rerr := os.ReadDir(p); rerr == nil && len(entries) == 0 {
			w.empty = append(w.empty, rel)
		}
		return nil
	})
	if errors.Is(err, errListFull) {
		err = nil
	}
	return w, err
}

// ListFiles lists one root: git's view (tracked plus untracked, ignores applied) in a repo, each
// repository nested in it listed as a child repository; otherwise a walk that lists child repositories through git and skips heavy folders.
// heavy is the heavy folder names, .git included (HeavyNames).
func ListFiles(ctx context.Context, root string, roots []string, heavy []string) (FileList, error) {
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		return FileList{}, UserError("root " + root + " is not readable: " + err.Error())
	}
	ok := false
	for _, r := range realRoots(roots) {
		if r == real {
			ok = true
		}
	}
	if !ok {
		return FileList{}, UserError("root " + root + " is not a root of the active project")
	}
	w := walked{heavyNames: heavy}
	if files, gerr := gitListFiles(ctx, real); gerr == nil {
		ignored, ierr := gitListIgnored(ctx, real, heavy)
		if ierr != nil {
			return FileList{}, ierr
		}
		foundHeavy, herr := gitListHeavy(ctx, real, heavy)
		if herr != nil {
			return FileList{}, herr
		}
		w.heavy = foundHeavy
		w.addTracked(ctx, real, "", files)
		w.addIgnoredOf(real, "", ignored)
		if empty, eerr := gitListEmpty(ctx, real); eerr == nil {
			// d itself is reported only when it has no entry, so never when it holds a listed file.
			for _, d := range empty {
				w.addEmptyUnder(real, d)
			}
		}
		if cerr := ctx.Err(); cerr != nil {
			return FileList{}, cerr
		}
	} else {
		if cerr := ctx.Err(); cerr != nil {
			return FileList{}, cerr
		}
		if w, err = walkFiles(ctx, real, heavy); err != nil {
			return FileList{}, err
		}
	}
	for _, s := range []*[]string{&w.files, &w.ignored, &w.heavy, &w.repos, &w.empty} {
		sort.Strings(*s)
		if *s == nil {
			*s = []string{}
		}
	}
	// Tracked first (spec): ignored files fill only what the tracked ones leave of the cap.
	truncated := false
	if len(w.files) > FileListCap {
		w.files, truncated = w.files[:FileListCap], true
	}
	if room := FileListCap - len(w.files); len(w.ignored) > room {
		w.ignored, truncated = w.ignored[:room], true
	}
	return FileList{Root: real, Files: w.files, Ignored: w.ignored, Heavy: w.heavy, Repos: w.repos, Empty: w.empty, Truncated: truncated}, nil
}

// ListDir lists one folder of a root: its direct entries, folders first, each sorted. dir is
// relative to root; it is resolved through symlinks and refused outside the roots (Invariant 6,
// Decision 36).
func ListDir(root, dir string, roots []string) (DirList, error) {
	real, _, err := ConfineFilePath(filepath.Join(root, filepath.FromSlash(dir)), roots, true)
	if err != nil {
		return DirList{}, err
	}
	ents, err := os.ReadDir(real)
	if err != nil {
		return DirList{}, UserError(dir + " is not readable: " + err.Error())
	}
	var dirs, files []DirEntry
	for _, e := range ents {
		isDir := e.IsDir()
		if e.Type()&os.ModeSymlink != 0 {
			// A link to a folder is a folder (pnpm links every package); a broken link stays a file.
			if st, serr := os.Stat(filepath.Join(real, e.Name())); serr == nil && st.IsDir() {
				isDir = true
			}
		}
		if isDir {
			dirs = append(dirs, DirEntry{Name: e.Name(), Kind: "dir"})
		} else {
			files = append(files, DirEntry{Name: e.Name(), Kind: "file"})
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].Name < dirs[j].Name })
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })
	out := append(dirs, files...)
	if out == nil {
		out = []DirEntry{}
	}
	return DirList{Root: root, Dir: dir, Entries: out}, nil
}

// ReadFile reads one file inside the roots.
func ReadFile(path string, roots []string) (FileRead, error) {
	real, root, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileRead{}, err
	}
	info, err := os.Stat(real)
	if errors.Is(err, fs.ErrNotExist) {
		return FileRead{Path: real, Root: root, UTF8: true}, nil
	}
	if err != nil {
		return FileRead{}, err
	}
	if info.IsDir() {
		return FileRead{}, UserError(path + " is a folder, not a file")
	}
	// A FIFO, socket or device would block or never end a read, hanging every later call.
	if !info.Mode().IsRegular() {
		return FileRead{}, UserError(path + " is not a regular file; the editor opens regular files only")
	}
	r := FileRead{Path: real, Root: root, Size: int(info.Size()), Mtime: info.ModTime().UnixNano(), Exists: true}
	var data []byte
	if r.Size > FileCap {
		r.OverCap, r.Tail = true, true
		chunk, rerr := readAt(real, r.Size-FileCap, FileCap)
		if rerr != nil {
			return FileRead{}, rerr
		}
		r.Start = r.Size - FileCap
		if i := bytes.IndexByte(chunk, '\n'); i >= 0 && i+1 < len(chunk) {
			chunk, r.Start = chunk[i+1:], r.Start+i+1
		}
		data = chunk
	} else if data, err = os.ReadFile(real); err != nil {
		return FileRead{}, err
	}
	r.End = r.Start + len(data)
	classify(&r, data)
	return r, nil
}

// classify sets Binary, UTF8 and Text from data, as files_read always has.
func classify(r *FileRead, data []byte) {
	switch {
	case bytes.IndexByte(data, 0) >= 0:
		r.Binary = true
	case !utf8.Valid(data):
		r.UTF8 = false
	default:
		r.UTF8 = true
		r.Text = string(data)
	}
}

// readAt reads up to n bytes of the file at real from off.
func readAt(real string, off, n int) ([]byte, error) {
	f, err := os.Open(real)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, n)
	m, err := f.ReadAt(buf, int64(off))
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return buf[:m], nil
}

// ReadFileFrom reads the whole lines past byte offset from (3b-vii: a growing log). Shrunk when
// the file is now shorter than from; TooFar when more than FileCap bytes lie past it. Text stops
// after the last newline, so a line still being written waits for the next read.
func ReadFileFrom(path string, from int, roots []string) (FileRead, error) {
	real, root, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileRead{}, err
	}
	info, err := os.Stat(real)
	if errors.Is(err, fs.ErrNotExist) {
		return FileRead{Path: real, Root: root, UTF8: true}, nil
	}
	if err != nil {
		return FileRead{}, err
	}
	if info.IsDir() {
		return FileRead{}, UserError(path + " is a folder, not a file")
	}
	if !info.Mode().IsRegular() {
		return FileRead{}, UserError(path + " is not a regular file; the editor opens regular files only")
	}
	r := FileRead{Path: real, Root: root, Size: int(info.Size()), Mtime: info.ModTime().UnixNano(), Exists: true,
		Start: from, End: from, UTF8: true}
	switch {
	case from < 0 || r.Size < from:
		r.Shrunk = true
		return r, nil
	case r.Size-from > FileCap:
		r.TooFar = true
		return r, nil
	}
	data, err := readAt(real, from, r.Size-from)
	if err != nil {
		return FileRead{}, err
	}
	data = data[:bytes.LastIndexByte(data, '\n')+1]
	r.End = from + len(data)
	classify(&r, data)
	return r, nil
}

// WriteFile writes text to a file inside the roots: to a temporary file in the same folder,
// then renamed into place, so a failed write never leaves half a file.
func WriteFile(path, text string, create bool, roots []string) (FileWritten, error) {
	real, _, err := ConfineFilePath(path, roots, false)
	if err != nil {
		return FileWritten{}, err
	}
	mode := fs.FileMode(0o644)
	if info, serr := os.Stat(real); serr == nil {
		if info.IsDir() {
			return FileWritten{}, UserError(path + " is a folder, not a file")
		}
		mode = info.Mode().Perm()
	} else if errors.Is(serr, fs.ErrNotExist) {
		if !create {
			return FileWritten{}, UserError(path + " does not exist; save it as a new file to create it")
		}
		if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
			return FileWritten{}, err
		}
	} else {
		return FileWritten{}, serr
	}
	tmp, err := os.CreateTemp(filepath.Dir(real), "."+filepath.Base(real)+".wakil-*")
	if err != nil {
		return FileWritten{}, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return FileWritten{}, err
	}
	if err := tmp.Close(); err != nil {
		return FileWritten{}, err
	}
	if err := os.Chmod(tmp.Name(), mode); err != nil {
		return FileWritten{}, err
	}
	if err := os.Rename(tmp.Name(), real); err != nil {
		return FileWritten{}, err
	}
	info, err := os.Stat(real)
	if err != nil {
		return FileWritten{}, err
	}
	return FileWritten{Path: real, Size: int(info.Size()), Mtime: info.ModTime().UnixNano()}, nil
}

// SearchCap is the most matches files_search returns (3b-ii).
const SearchCap = 2000

// previewRunes is how much of a matching line a match carries, around the match.
const previewRunes = 400

type SearchQuery struct {
	Query string `json:"query"`
	Case  bool   `json:"case"`
	Word  bool   `json:"word"`
	Regex bool   `json:"regex"`
}

type SearchMatch struct {
	Root    string `json:"root"`
	Path    string `json:"path"`
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Preview string `json:"preview"`
}

type SearchResult struct {
	Matches   []SearchMatch `json:"matches"`
	Truncated bool          `json:"truncated"`
	// FilesTruncated: some root's listing hit FileListCap, so it was searched only in part.
	FilesTruncated bool `json:"files_truncated"`
	// SkippedLarge: the files over FileCap that were not searched, root-relative (3b-vii).
	SkippedLarge []string `json:"skipped_large"`
}

// searchPattern compiles q the one way both kinds of root are searched, so a pattern means the
// same thing inside and outside a repository, and an invalid one is Go's own error (spec).
func searchPattern(q SearchQuery) (*regexp.Regexp, error) {
	p := q.Query
	if !q.Regex {
		p = regexp.QuoteMeta(p)
	}
	if q.Word {
		p = `\b(?:` + p + `)\b`
	}
	if !q.Case {
		p = `(?i)` + p
	}
	re, err := regexp.Compile(p)
	if err != nil {
		return nil, UserError(err.Error())
	}
	return re, nil
}

// utf16Col is the 1-based UTF-16 column of byte offset off in line.
func utf16Col(line string, off int) int {
	return len(utf16.Encode([]rune(line[:off]))) + 1
}

func trimPreview(line string, start, end int) string {
	r := []rune(line)
	if len(r) <= previewRunes {
		return line
	}
	s := utf8.RuneCountInString(line[:start])
	e := s + utf8.RuneCountInString(line[start:end])
	lo := max(0, s-(previewRunes-(e-s))/2)
	hi := min(len(r), lo+previewRunes)
	lo = max(0, hi-previewRunes)
	return string(r[lo:hi])
}

// SearchFiles searches the files ListFiles lists in each root (only, when given, else every
// root): tracked and untracked, never ignored or heavy. Binary files and files over FileCap are
// skipped. It stops at SearchCap and when ctx ends. A match's Root is the root as passed, not
// l.Root (the real path): the app's roots and editor_refresh {root} compare against it.
func SearchFiles(ctx context.Context, roots []string, heavy []string, only []string, q SearchQuery) (SearchResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return SearchResult{}, err
	}
	targets := roots
	if len(only) > 0 {
		real := realRoots(roots)
		for _, o := range only {
			ro, rerr := filepath.EvalSymlinks(o)
			if rerr != nil || !slices.Contains(real, ro) {
				return SearchResult{}, outsideRoots(o)
			}
		}
		targets = only
	}
	res := SearchResult{Matches: []SearchMatch{}, SkippedLarge: []string{}}
	for _, root := range targets {
		l, lerr := ListFiles(ctx, root, roots, heavy)
		if lerr != nil {
			return SearchResult{}, lerr
		}
		res.FilesTruncated = res.FilesTruncated || l.Truncated
		for _, rel := range l.Files {
			if cerr := ctx.Err(); cerr != nil {
				return SearchResult{}, cerr
			}
			// A listed link may point outside the roots; files_read refuses it, so skip it.
			p, _, cerr := ConfineFilePath(filepath.Join(l.Root, filepath.FromSlash(rel)), roots, true)
			if cerr != nil {
				continue
			}
			info, serr := os.Stat(p)
			if serr != nil || !info.Mode().IsRegular() {
				continue
			}
			if info.Size() > FileCap {
				res.SkippedLarge = append(res.SkippedLarge, rel)
				continue
			}
			data, rerr := os.ReadFile(p)
			if rerr != nil || bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
				continue
			}
			for i, line := range strings.Split(string(data), "\n") {
				for _, loc := range re.FindAllStringIndex(line, -1) {
					if loc[0] == loc[1] {
						continue // an empty match marks nothing
					}
					if len(res.Matches) == SearchCap {
						res.Truncated = true
						return res, nil
					}
					res.Matches = append(res.Matches, SearchMatch{
						Root: root, Path: rel, Line: i + 1, Column: utf16Col(line, loc[0]),
						Preview: trimPreview(line, loc[0], loc[1]),
					})
				}
			}
		}
	}
	return res, nil
}

// ReplaceEdit is one replacement in a text: the UTF-16 span [Start, End) it replaces, as Monaco
// counts, and what goes there (3b-ii-b).
type ReplaceEdit struct {
	Start int    `json:"start"`
	End   int    `json:"end"`
	Text  string `json:"text"`
}

type byteEdit struct {
	start, end int
	text       string
}

// replaceByteEdits finds re's matches the way SearchFiles does — line by line, empty matches
// skipped — and what each becomes: replacement expanded by regexp.Expand when expand ($1, ${name},
// $$), taken literally otherwise. A match whose replacement equals it is no edit (spec: a
// replacement that leaves the text the same counts nothing).
func replaceByteEdits(re *regexp.Regexp, text string, expand bool, replacement string) []byteEdit {
	var out []byteEdit
	off := 0
	for _, line := range strings.Split(text, "\n") {
		for _, m := range re.FindAllStringSubmatchIndex(line, -1) {
			if m[0] == m[1] {
				continue
			}
			with := replacement
			if expand {
				with = string(re.ExpandString(nil, replacement, line, m))
			}
			if with == line[m[0]:m[1]] {
				continue
			}
			out = append(out, byteEdit{start: off + m[0], end: off + m[1], text: with})
		}
		off += len(line) + 1
	}
	return out
}

func applyByteEdits(text string, edits []byteEdit) string {
	var b strings.Builder
	last := 0
	for _, e := range edits {
		b.WriteString(text[last:e.start])
		b.WriteString(e.text)
		last = e.end
	}
	b.WriteString(text[last:])
	return b.String()
}

func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

func utf16Edits(text string, edits []byteEdit) []ReplaceEdit {
	out := make([]ReplaceEdit, 0, len(edits))
	units, at := 0, 0
	for _, e := range edits {
		units += utf16Len(text[at:e.start])
		start := units
		units += utf16Len(text[e.start:e.end])
		at = e.end
		out = append(out, ReplaceEdit{Start: start, End: units, Text: e.text})
	}
	return out
}

// ReplaceEdits is every replacement ReplaceText would make in text, as UTF-16 spans.
func ReplaceEdits(text string, q SearchQuery, replacement string) ([]ReplaceEdit, error) {
	re, err := searchPattern(q)
	if err != nil {
		return nil, err
	}
	return utf16Edits(text, replaceByteEdits(re, text, q.Regex, replacement)), nil
}

// ReplaceText is text with every match of q replaced — the pattern SearchFiles compiles, line by
// line — and how many were (3b-ii-b).
func ReplaceText(text string, q SearchQuery, replacement string) (string, int, error) {
	re, err := searchPattern(q)
	if err != nil {
		return "", 0, err
	}
	edits := replaceByteEdits(re, text, q.Regex, replacement)
	return applyByteEdits(text, edits), len(edits), nil
}

type ReplacedText struct {
	Text  string        `json:"text"`
	Count int           `json:"count"`
	Edits []ReplaceEdit `json:"edits"`
}

type ReplaceTextsResult struct {
	Results []ReplacedText `json:"results"`
}

// ReplaceTexts is ReplaceText over each text, in order: the open tabs' buffers and the preview's
// lines, so both agree with what files_replace writes. It touches no file.
func ReplaceTexts(texts []string, q SearchQuery, replacement string) (ReplaceTextsResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return ReplaceTextsResult{}, err
	}
	out := ReplaceTextsResult{Results: make([]ReplacedText, 0, len(texts))}
	for _, t := range texts {
		edits := replaceByteEdits(re, t, q.Regex, replacement)
		out.Results = append(out.Results, ReplacedText{Text: applyByteEdits(t, edits), Count: len(edits), Edits: utf16Edits(t, edits)})
	}
	return out, nil
}

// ReplaceBatchTime bounds a batched files_replace call (MaxFiles > 0): it stops between files once
// this long has passed and at least one file was handled, so a caller looping on Next can stop
// between calls (3b-ii-b ruling 1). A var for tests.
var ReplaceBatchTime = 250 * time.Millisecond

// ReplaceBatchBytes bounds the originals one batched call answers, so a reply stays a few MB.
const ReplaceBatchBytes = 8 << 20

// replaceAfterWrite is a test seam, called after each file a replace writes.
var replaceAfterWrite func()

// replaceAfterList is a test seam, called right after a root is listed and before the batch clock
// starts: a test sleeps in it to stand for a slow listing.
var replaceAfterList func()

type ReplaceOptions struct {
	Roots    []string // the roots to walk, each a root of roots; every root when empty
	Only     string   // one file (absolute): only it, when the walk covers it
	Skip     []string // files left on disk (open tabs); those the walk covers come back in Skipped
	After    string   // a previous call's Next: resume after it
	MaxFiles int      // stop after writing this many, or ReplaceBatchTime (0: neither)
}

type ReplacedFile struct {
	Path     string `json:"path"`
	Count    int    `json:"count"`
	Original string `json:"original"`
	Mtime    int64  `json:"mtime"`
}

type ReplaceFailure struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

type ReplaceResult struct {
	Files          []ReplacedFile   `json:"files"`
	Failures       []ReplaceFailure `json:"failures"`
	Skipped        []string         `json:"skipped"`
	TruncatedFiles bool             `json:"truncated_files"`
	Cancelled      bool             `json:"cancelled"`
	Next           string           `json:"next"`
}

// ReplaceFiles writes every match of q, replaced, in the files SearchFiles walks (o.Roots, else
// every root): never ignored, heavy, binary or over-cap files, never past a link out of the roots,
// never a file in o.Skip. Each file is written whole and atomically (WriteFile), keeping its mode;
// one that cannot be written is listed and the rest go on (Rule 8). A cancelled ctx stops it between
// files with what it wrote. With MaxFiles it stops early and Next resumes it (3b-ii-b ruling 1).
func ReplaceFiles(ctx context.Context, roots []string, heavy []string, q SearchQuery, replacement string, o ReplaceOptions) (ReplaceResult, error) {
	re, err := searchPattern(q)
	if err != nil {
		return ReplaceResult{}, err
	}
	res := ReplaceResult{Files: []ReplacedFile{}, Failures: []ReplaceFailure{}, Skipped: []string{}}
	if q.Query == "" {
		return res, nil // ruling 9: an empty query replaces nothing
	}
	targets := roots
	if len(o.Roots) > 0 {
		real := realRoots(roots)
		for _, r := range o.Roots {
			if slices.Contains(roots, r) {
				continue // one of the project's roots as given, even one missing on disk (listed below)
			}
			rr, rerr := filepath.EvalSymlinks(r)
			if rerr != nil || !slices.Contains(real, rr) {
				return ReplaceResult{}, outsideRoots(r)
			}
		}
		targets = o.Roots
	}
	only := ""
	if o.Only != "" {
		p, _, cerr := ConfineFilePath(o.Only, roots, true)
		if cerr != nil {
			return ReplaceResult{}, cerr
		}
		only = p
	}
	skip := map[string]string{} // real path → the path as given
	for _, s := range o.Skip {
		if p, serr := filepath.EvalSymlinks(s); serr == nil {
			skip[p] = s
		}
	}
	afterRoot, afterRel := -1, ""
	if o.After != "" {
		i := strings.IndexByte(o.After, '/')
		n, aerr := -1, error(nil)
		if i > 0 {
			n, aerr = strconv.Atoi(o.After[:i])
		}
		if i <= 0 || aerr != nil {
			return ReplaceResult{}, UserError("files_replace: after " + o.After + " is not a cursor files_replace answered")
		}
		afterRoot, afterRel = n, o.After[i+1:]
	}
	var start time.Time // the batch clock: started after a root is listed, so a listing never spends it
	held, handled := 0, 0
	for ri, root := range targets {
		if ri < afterRoot {
			continue
		}
		l, lerr := ListFiles(ctx, root, roots, heavy)
		if lerr != nil {
			if ctx.Err() != nil {
				res.Cancelled = true
				return res, nil
			}
			res.Failures = append(res.Failures, ReplaceFailure{Path: root, Error: lerr.Error()})
			continue
		}
		res.TruncatedFiles = res.TruncatedFiles || l.Truncated
		if replaceAfterList != nil {
			replaceAfterList()
		}
		start = time.Now() // pre-flight F3: each resumed call re-lists its root; only file handling is timed
		for _, rel := range l.Files {
			if ri == afterRoot && rel <= afterRel {
				continue
			}
			if ctx.Err() != nil {
				res.Cancelled = true
				return res, nil
			}
			if o.MaxFiles > 0 && handled > 0 &&
				(len(res.Files) >= o.MaxFiles || held >= ReplaceBatchBytes || time.Since(start) >= ReplaceBatchTime) {
				return res, nil // Next names the last file handled
			}
			handled++
			res.Next = fmt.Sprintf("%d/%s", ri, rel)
			listed := filepath.Join(l.Root, filepath.FromSlash(rel))
			p, _, cerr := ConfineFilePath(listed, roots, true)
			if cerr != nil || (only != "" && p != only) {
				continue
			}
			if p != listed {
				continue // a link to a file: its target is replaced through its own listing, once
			}
			if given, ok := skip[p]; ok {
				res.Skipped = append(res.Skipped, given)
				continue
			}
			info, serr := os.Stat(p)
			if serr != nil || !info.Mode().IsRegular() || info.Size() > FileCap {
				continue
			}
			data, rerr := os.ReadFile(p)
			if rerr != nil || bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
				continue
			}
			text := string(data)
			edits := replaceByteEdits(re, text, q.Regex, replacement)
			if len(edits) == 0 {
				continue
			}
			path := filepath.Join(root, filepath.FromSlash(rel))
			// Ruling 7: temp-and-rename would replace a read-only file; the spec says it fails.
			if aerr := syscall.Access(p, 2 /* W_OK */); aerr != nil {
				res.Failures = append(res.Failures, ReplaceFailure{Path: path, Error: path + " is not writable: " + aerr.Error()})
				continue
			}
			w, werr := WriteFile(p, applyByteEdits(text, edits), false, roots)
			if werr != nil {
				res.Failures = append(res.Failures, ReplaceFailure{Path: path, Error: werr.Error()})
				continue
			}
			res.Files = append(res.Files, ReplacedFile{Path: path, Count: len(edits), Original: text, Mtime: w.Mtime})
			held += len(text)
			if replaceAfterWrite != nil {
				replaceAfterWrite()
			}
		}
	}
	res.Next = ""
	return res, nil
}
