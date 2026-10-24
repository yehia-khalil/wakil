package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// gitWriteSafetyArgs come before every write's subcommand. Unlike gitSafetyArgs they leave hooks,
// signing and the repository's clean filters on: a commit from Wakil is a real commit (spec 3a-ii,
// Decision 43). What a write still cannot reach: fsmonitor, a pager, an external diff, the network.
var gitWriteSafetyArgs = []string{
	"-c", "core.fsmonitor=false",
	"-c", "core.pager=cat",
	"-c", "diff.external=",
	"--no-pager",
	"--literal-pathspecs",
}

// gitWriteWaitDelay is how long a write waits for its output pipes after git itself has exited.
const gitWriteWaitDelay = 2 * time.Second

// hookOutputCap bounds what a failed write reports; the end is kept, where a hook says why.
const hookOutputCap = 64 << 10

type GitIdentity struct{ Name, Email string }

type GitCommitResult struct {
	Commit  string `json:"commit"`
	Summary string `json:"summary"`
}

// GitWriter runs the 3a-ii writes in one project root.
type GitWriter struct {
	Root     string
	Identity GitIdentity
}

var gitWriteLocks sync.Map // root -> *sync.Mutex: one write per root at a time

func NewGitWriter(root string, allowedRoots []string, id GitIdentity) (*GitWriter, error) {
	r, err := NewGitRunner(root, allowedRoots)
	if err != nil {
		return nil, err
	}
	return &GitWriter{Root: r.Root, Identity: id}, nil
}

func (w *GitWriter) runner() *GitRunner { return &GitRunner{Root: w.Root} }

// paths resolves each to its cleaned root-relative path (`a/../b.txt` is `b.txt`); every one must
// stay inside the root. What git is handed, and what a refusal names, is the cleaned path.
func (w *GitWriter) paths(in []string) ([]string, error) {
	if len(in) == 0 {
		return nil, UserError("no paths given")
	}
	out := make([]string, 0, len(in))
	for _, p := range in {
		rel, err := w.runner().ResolvePath(p)
		if err != nil {
			return nil, err
		}
		out = append(out, filepath.ToSlash(rel))
	}
	return out, nil
}

func (w *GitWriter) git(ctx context.Context, stdin []byte, sub string, args ...string) ([]byte, error) {
	out, _, err := w.gitWith(ctx, nil, stdin, sub, args...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// gitWith is git with config (`-c` pairs) placed before the subcommand, returning stderr too: a
// rebase reports its result there.
func (w *GitWriter) gitWith(ctx context.Context, config []string, stdin []byte, sub string, args ...string) ([]byte, []byte, error) {
	m, _ := gitWriteLocks.LoadOrStore(w.Root, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	full := append([]string{"-C", w.Root}, gitWriteSafetyArgs...)
	// `stash` is handed no paths, and under --literal-pathspecs `stash push --include-untracked`
	// leaves the untracked files behind (git 2.54, measured 3a-iv), so it runs without it.
	if sub == "stash" {
		full = slices.DeleteFunc(full, func(a string) bool { return a == "--literal-pathspecs" })
	}
	// author.* and committer.* too: a repository's own author.email would otherwise beat user.email.
	if w.Identity.Name != "" {
		for _, k := range []string{"user", "author", "committer"} {
			full = append(full, "-c", k+".name="+w.Identity.Name)
		}
	}
	if w.Identity.Email != "" {
		for _, k := range []string{"user", "author", "committer"} {
			full = append(full, "-c", k+".email="+w.Identity.Email)
		}
	}
	full = append(append(append(full, config...), sub), args...)
	cmd := exec.Command("git", full...)
	cmd.Env = gitScrubbedEnv(w.Root)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // a cancel kills hooks too
	// A hook's background child can hold git's output open after git exits; Wait would block on it,
	// holding the root's lock. After this long the pipes are closed and git's own exit status stands.
	cmd.WaitDelay = gitWriteWaitDelay
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-ctx.Done():
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return nil, nil, ctx.Err()
	case err := <-done:
		if errors.Is(err, exec.ErrWaitDelay) {
			err = nil // git exited 0; only a leftover child's pipe was cut
		}
		if err != nil {
			return out.Bytes(), errb.Bytes(), gitWriteError(sub, out.Bytes(), errb.Bytes(), err)
		}
		return out.Bytes(), errb.Bytes(), nil
	}
}

// gitWriteError is git's own words, whole up to the cap with the end kept, and the exit status.
func gitWriteError(sub string, out, errb []byte, err error) error {
	text := strings.TrimSpace(string(out) + "\n" + string(errb))
	if len(text) > hookOutputCap {
		text = "…" + text[len(text)-hookOutputCap:]
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return UserError("git " + sub + " failed (exit " + strconv.Itoa(exit.ExitCode()) + "):\n" + text)
	}
	return UserError("git " + sub + " failed: " + err.Error())
}

func (w *GitWriter) Stage(ctx context.Context, paths []string) error {
	ps, err := w.paths(paths)
	if err != nil {
		return err
	}
	_, err = w.git(ctx, nil, "add", append([]string{"--"}, ps...)...)
	return err
}

func (w *GitWriter) Unstage(ctx context.Context, paths []string) error {
	ps, err := w.paths(paths)
	if err != nil {
		return err
	}
	// Only what is staged is unstaged (Rule 7): a path with nothing staged is no error, just nothing.
	noHead := w.hasNoHead(ctx)
	var list []byte
	if noHead {
		list, err = w.git(ctx, nil, "ls-files", append([]string{"-z", "--"}, ps...)...)
	} else {
		list, err = w.git(ctx, nil, "diff", append([]string{"--cached", "--name-only", "--no-renames", "-z", "--"}, ps...)...)
	}
	if err != nil {
		return err
	}
	staged := nulFields(list)
	if len(staged) == 0 {
		return nil
	}
	if noHead {
		_, err = w.git(ctx, nil, "rm", append([]string{"--cached", "-q", "--"}, staged...)...)
		return err
	}
	_, err = w.git(ctx, nil, "restore", append([]string{"--staged", "--"}, staged...)...)
	return err
}

// nulFields splits git's -z output into its paths.
func nulFields(b []byte) []string {
	var out []string
	for _, f := range strings.Split(string(b), "\x00") {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
}

func (w *GitWriter) hasNoHead(ctx context.Context) bool {
	_, err := w.runner().Run(ctx, "rev-parse", "--verify", "HEAD")
	return err != nil
}

// messageFile holds the message for `-F`, so no line of it is ever read as a flag.
func messageFile(message string) (string, func(), error) {
	f, err := os.CreateTemp("", "wakil-commit-*.txt")
	if err != nil {
		return "", nil, err
	}
	_, werr := f.WriteString(message)
	cerr := f.Close()
	if err := errors.Join(werr, cerr); err != nil {
		os.Remove(f.Name())
		return "", nil, UserError("could not write the commit message: " + err.Error())
	}
	return f.Name(), func() { os.Remove(f.Name()) }, nil
}

func (w *GitWriter) Commit(ctx context.Context, message string, all bool) (GitCommitResult, error) {
	if strings.TrimSpace(message) == "" && w.merging(ctx) { // R4: git's prepared merge message
		if _, err := w.git(ctx, nil, "commit", "-q", "--no-edit"); err != nil {
			return GitCommitResult{}, err
		}
		return w.head(ctx)
	}
	if strings.TrimSpace(message) == "" {
		return GitCommitResult{}, UserError("the message is empty")
	}
	if all {
		if _, err := w.git(ctx, nil, "add", "-A", "--", "."); err != nil {
			return GitCommitResult{}, err
		}
	}
	file, done, err := messageFile(message)
	if err != nil {
		return GitCommitResult{}, err
	}
	defer done()
	if _, err := w.git(ctx, nil, "commit", "-q", "--cleanup=whitespace", "-F", file); err != nil {
		return GitCommitResult{}, err
	}
	return w.head(ctx)
}

func (w *GitWriter) Amend(ctx context.Context, message string) (GitCommitResult, error) {
	args := []string{"-q", "--amend"}
	if strings.TrimSpace(message) == "" {
		args = append(args, "--no-edit")
	} else {
		file, done, err := messageFile(message)
		if err != nil {
			return GitCommitResult{}, err
		}
		defer done()
		args = append(args, "--cleanup=whitespace", "-F", file)
	}
	if _, err := w.git(ctx, nil, "commit", args...); err != nil {
		return GitCommitResult{}, err
	}
	return w.head(ctx)
}

func (w *GitWriter) UndoCommit(ctx context.Context) (string, error) {
	if _, err := w.runner().Run(ctx, "rev-parse", "--verify", "HEAD~1"); err != nil {
		return "", UserError("nothing to undo: this is the first commit")
	}
	msg, err := w.git(ctx, nil, "log", "-1", "--no-show-signature", "--format=%B")
	if err != nil {
		return "", err
	}
	if _, err := w.git(ctx, nil, "reset", "-q", "--soft", "HEAD~1"); err != nil {
		return "", err
	}
	return strings.TrimRight(string(msg), "\n"), nil
}

// merging: a merge, cherry-pick or revert is stopped part-way, so git has a message prepared for its
// commit. A rebase's commits are made by `rebase --continue`, not here.
func (w *GitWriter) merging(ctx context.Context) bool {
	op, _ := ReadGitOp(ctx, w.runner())
	return op.Kind != "" && op.Kind != "rebase"
}

func (w *GitWriter) head(ctx context.Context) (GitCommitResult, error) {
	out, err := w.git(ctx, nil, "log", "-1", "--no-show-signature", "--format=%h%x00%s")
	if err != nil {
		return GitCommitResult{}, err
	}
	h, s, _ := strings.Cut(strings.TrimRight(string(out), "\n"), "\x00")
	return GitCommitResult{Commit: h, Summary: s}, nil
}

// Discard sends each path's current copy to the Trash, then restores tracked ones from the index.
// A tracked file is renamed `<name> (discarded HH:MM)` first (` 2`, ` 3` … when taken), so the
// Trash says what it was; an untracked one goes as itself (Decision 41's Move to Trash). A tracked
// path already gone from disk has nothing to trash: it is only restored. A path with a merge
// conflict is refused before anything moves. On a failure part-way, the file being moved is put
// back and every tracked path already trashed is restored, so nothing is left half-discarded.
func (w *GitWriter) Discard(ctx context.Context, paths []string, now time.Time) ([]string, error) {
	ps, err := w.paths(paths)
	if err != nil {
		return nil, err
	}
	// Each path is classified before anything moves: a file the index holds (tracked), or one git
	// lists as untracked and not ignored. A directory, an ignored file, or anything else is refused,
	// so a discard never trashes more than the one changed file it names.
	isTracked := map[string]bool{}
	var todo []string
	for _, p := range ps {
		out, err := w.git(ctx, nil, "ls-files", "-u", "--", p)
		if err != nil {
			return nil, err
		}
		if len(bytes.TrimSpace(out)) > 0 {
			return nil, UserError(p + " has a merge conflict; resolve it before discarding")
		}
		fi, statErr := os.Lstat(filepath.Join(w.Root, p))
		if statErr == nil && fi.IsDir() {
			return nil, UserError(p + " is a directory, not a changed file")
		}
		if out, err = w.git(ctx, nil, "ls-files", "-z", "--", p); err != nil {
			return nil, err
		}
		if string(out) == p+"\x00" {
			isTracked[p] = true
			todo = append(todo, p)
			continue
		}
		if statErr != nil {
			continue // P2: an untracked path already gone has nothing left to discard
		}
		if out, err = w.git(ctx, nil, "ls-files", "--others", "--exclude-standard", "-z", "--", p); err != nil {
			return nil, err
		}
		if string(out) != p+"\x00" {
			return nil, UserError(p + " is not a changed file")
		}
		todo = append(todo, p)
	}
	names := []string{}
	var tracked []string
	fail := func(err error) ([]string, error) {
		if len(tracked) > 0 {
			if _, rerr := w.git(ctx, nil, "restore", append([]string{"--"}, tracked...)...); rerr != nil {
				err = UserError(err.Error() + "; restoring what was already discarded also failed: " + rerr.Error())
			}
		}
		return names, err
	}
	for _, p := range todo {
		abs := filepath.Join(w.Root, p)
		if _, statErr := os.Lstat(abs); isTracked[p] && statErr != nil {
			tracked = append(tracked, p)
			continue
		}
		target := abs
		if isTracked[p] {
			base := filepath.Base(abs) + " (discarded " + now.Format("15:04") + ")"
			target = filepath.Join(filepath.Dir(abs), base)
			for n := 2; ; n++ {
				if _, err := os.Lstat(target); os.IsNotExist(err) {
					break
				}
				target = filepath.Join(filepath.Dir(abs), base+" "+strconv.Itoa(n))
			}
			if err := os.Rename(abs, target); err != nil {
				return fail(UserError("discard " + p + ": " + err.Error()))
			}
		}
		if _, err := TrashEntry(ctx, target, []string{w.Root}); err != nil {
			if isTracked[p] {
				if rerr := os.Rename(target, abs); rerr != nil { // put the original name back
					err = UserError(err.Error() + "; putting the name back also failed, the current copy is " +
						filepath.Base(target) + ": " + rerr.Error())
				}
			}
			return fail(err)
		}
		if isTracked[p] {
			tracked = append(tracked, p)
		}
		names = append(names, filepath.Base(target))
	}
	if len(tracked) > 0 {
		if _, err := w.git(ctx, nil, "restore", append([]string{"--"}, tracked...)...); err != nil {
			return names, err
		}
	}
	return names, nil
}

func (w *GitWriter) IndexBlob(ctx context.Context, path string) (string, error) {
	if _, err := w.runner().ResolvePath(path); err != nil {
		return "", err
	}
	out, err := w.runner().Run(ctx, "rev-parse", "--verify", ":"+path)
	if err != nil {
		return "", UserError(path + " is not in the index")
	}
	return strings.TrimSpace(string(out)), nil
}

// StageContent makes content the index's version of path (Stage Change, ruling R1), when the
// index still holds expect — else the peek was computed against an index that has since moved.
func (w *GitWriter) StageContent(ctx context.Context, path, content, expect string) error {
	now, err := w.IndexBlob(ctx, path)
	if err != nil {
		return err
	}
	if now != expect {
		return UserError("the change moved — open the peek again")
	}
	mode, err := w.git(ctx, nil, "ls-files", "-s", "--", path)
	if err != nil {
		return err
	}
	fields := strings.Fields(string(mode))
	if len(fields) == 0 {
		return UserError(path + " is not in the index")
	}
	blob, err := w.git(ctx, []byte(content), "hash-object", "-w", "--stdin", "--path="+path)
	if err != nil {
		return err
	}
	_, err = w.git(ctx, nil, "update-index", "--cacheinfo",
		fields[0]+","+strings.TrimSpace(string(blob))+","+path)
	return err
}
