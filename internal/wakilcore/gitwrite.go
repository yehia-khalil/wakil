package wakilcore

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// gitWriteSafetyArgs come before every write's subcommand. Unlike gitSafetyArgs they leave hooks,
// signing and the repository's clean filters on: a commit from Wakil is a real commit (spec 3a-ii,
// Decision 43). What a write still cannot reach: fsmonitor, a pager, an external diff, the network.
var gitWriteSafetyArgs = []string{
	"-c", "core.fsmonitor=false",
	"-c", "core.pager=cat",
	"-c", "diff.external=",
	"--no-pager",
}

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

// paths resolves each to a root-relative path; every one must stay inside the root.
func (w *GitWriter) paths(in []string) ([]string, error) {
	if len(in) == 0 {
		return nil, UserError("no paths given")
	}
	out := make([]string, 0, len(in))
	for _, p := range in {
		if _, err := w.runner().ResolvePath(p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

func (w *GitWriter) git(ctx context.Context, stdin []byte, sub string, args ...string) ([]byte, error) {
	m, _ := gitWriteLocks.LoadOrStore(w.Root, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	full := append([]string{"-C", w.Root}, gitWriteSafetyArgs...)
	if w.Identity.Name != "" {
		full = append(full, "-c", "user.name="+w.Identity.Name)
	}
	if w.Identity.Email != "" {
		full = append(full, "-c", "user.email="+w.Identity.Email)
	}
	full = append(append(full, sub), args...)
	cmd := exec.Command("git", full...)
	cmd.Env = gitScrubbedEnv(w.Root)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // a cancel kills hooks too
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-ctx.Done():
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return nil, ctx.Err()
	case err := <-done:
		if err != nil {
			return nil, gitWriteError(sub, out.Bytes(), errb.Bytes(), err)
		}
		return out.Bytes(), nil
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
	if w.hasNoHead(ctx) {
		_, err = w.git(ctx, nil, "rm", append([]string{"--cached", "-q", "--"}, ps...)...)
		return err
	}
	_, err = w.git(ctx, nil, "restore", append([]string{"--staged", "--"}, ps...)...)
	return err
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
	f.WriteString(message)
	f.Close()
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
	if _, err := w.git(ctx, nil, "commit", "-q", "--cleanup=strip", "-F", file); err != nil {
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
		args = append(args, "--cleanup=strip", "-F", file)
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
	msg, err := w.git(ctx, nil, "log", "-1", "--format=%B")
	if err != nil {
		return "", err
	}
	if _, err := w.git(ctx, nil, "reset", "-q", "--soft", "HEAD~1"); err != nil {
		return "", err
	}
	return strings.TrimRight(string(msg), "\n"), nil
}

func (w *GitWriter) merging(ctx context.Context) bool {
	_, err := w.runner().Run(ctx, "rev-parse", "--verify", "MERGE_HEAD")
	return err == nil
}

func (w *GitWriter) head(ctx context.Context) (GitCommitResult, error) {
	out, err := w.git(ctx, nil, "log", "-1", "--format=%h%x00%s")
	if err != nil {
		return GitCommitResult{}, err
	}
	h, s, _ := strings.Cut(strings.TrimRight(string(out), "\n"), "\x00")
	return GitCommitResult{Commit: h, Summary: s}, nil
}
