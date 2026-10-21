# 3a-ii Git Writes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage, unstage, discard, stage a hunk, commit, amend and undo the last commit from the editor's Changes view, by hand, by voice and by the agent, under the organisation's author identity.

**Architecture:** `wakil-git` gains a `GitWriter` beside the read-only `GitRunner` (same root check and scrubbed env, but hooks, signing and clean filters allowed) and seven write tools plus one read (`git_identity`). WakilKit registers seven `editor_changes_*` `.mutate` actions priced allow everywhere that call those tools and re-read `GitStatus`. WakilApp draws the VS Code-style controls in `EditorColumn`'s Changes view, Stage Change in the Monaco peek, and a GIT section in Settings → Organisation.

**Tech Stack:** Go 1.2x (`internal/wakilcore`, `cmd/wakil-git`, `cmd/wakil-ctx`, MCP go-sdk), Swift 6 / SwiftUI (`app/Sources/WakilKit`, `app/Sources/WakilApp`), Swift Testing, the e2e harness (`e2e/`).

**Spec:** `docs/superpowers/specs/2026-10-21-3a-ii-git-writes-design.md`

## Global Constraints

- Price of every new action: `price: (production: .allow, otherwise: .allow)`; kind `.mutate`; `audience: .agentReachable`.
- Action names exactly: `editor_changes_stage`, `editor_changes_unstage`, `editor_changes_discard`, `editor_changes_stage_hunk`, `editor_changes_commit`, `editor_changes_amend`, `editor_changes_undo_commit`.
- Tool names exactly: `git_stage`, `git_unstage`, `git_discard`, `git_stage_hunk`, `git_commit`, `git_amend`, `git_undo_commit`, `git_identity`.
- Reads keep their guarantee: `GitRunner`, `gitReadSubcommands`, `gitSafetyArgs` are not changed.
- Discarded copy name: `<name> (discarded HH:MM)` (24-hour local time).
- Refusal texts verbatim: `the message is empty`; `a git write is already running in <root name>`; `the change moved — open the peek again`; `nothing to undo: this is the first commit`; a newline in an identity value: `gitName and gitEmail cannot hold a newline`.
- Placeholder: `Message (⌘⏎ to commit)`. Hint: `committing as <email>` or `committing as <email> (from git config)`.
- Hook output captured to 64 KB, keeping the end. No timeout on a write; cancel kills git's process group.
- Message history: last 20 messages committed from Wakil, per root.
- Never add Co-Authored-By or "Generated with" lines to commits.
- Committed docs must not contain home paths (public-check pre-push hook).

## Rulings (where this plan settles what the spec left to mechanism)

- **R1 — Stage Change stages content, not a patch.** The spec names `git apply --cached` with a hunk header. The peek's hunks are computed in WakilKit from the tab's buffer against the index (`EditorSnapshot.baseline`), which may be unsaved, so a patch from `git diff` (disk) would not match what the peek shows. Instead WakilKit computes the new index text (the baseline with that one hunk applied) and `git_stage_hunk` writes it as the index blob (`git hash-object -w --stdin` then `git update-index --cacheinfo`), refusing when the index blob changed since the baseline was read (`expect` = the baseline's blob id). Same behavior the spec describes, including its refusal text. Cost if wrong: Stage Change reworked; nothing else depends on it.
- **R2 — The identity hint comes from `git_identity` in wakil-git, not `config_tree`.** `wakil-ctx` runs no git today; the read belongs with the git capability. Cost if wrong: one call moves.
- **R4 — Concluding a merge.** `GitWriter.Commit` with an empty message while `MERGE_HEAD` exists runs `git commit --no-edit` (git's prepared message), as the spec's edge table says; the box's button still needs a message, so from the UI the operator types one (or the agent concludes it). Test in Task 1. Cost if wrong: the button's enable rule gains a merge flag.
- **R3 — Message drafts and history live for the window's life, not across relaunch.** The composer's drafts are never persisted (`LayoutScope.swift:101`), and Rule 2 is met by keeping text when the view is left. Cost if wrong: a small persistence task later.

## Review Focus

1. A path with spaces, unicode or a leading `-` (e.g. `-rf.txt`) — staged/discarded as that file, never read as a flag. Test in Task 1 and Task 2.
2. A commit message that is only whitespace — treated as empty (button disabled; tool refuses `the message is empty`). Test in Task 1 and Task 6.
3. Two roots committing at once — both proceed (the lock is per root), one root twice — the second refused. Test in Task 5.
4. Discard of a file whose `(discarded HH:MM)` name already exists in that folder (two discards in one minute) — the second gets ` 2`, never overwrites. Test in Task 2.
5. An organisation switch while a commit's hook runs — the commit finishes in the repository it started in, and its result is not shown in the new org's view. Test in Task 6.

---

### Task 1: `GitWriter` — stage, unstage, commit, amend, undo, identity args

**Files:**
- Create: `internal/wakilcore/gitwrite.go`
- Test: `internal/wakilcore/gitwrite_test.go`

**Interfaces:**
- Consumes: `NewGitRunner(root string, allowedRoots []string) (*GitRunner, error)` and `(*GitRunner).ResolvePath(rel string) (string, error)` (`gitread.go:84`, `:281`); `gitScrubbedEnv(root string) []string` (`gitread.go`); `UserError(string) error` (`mcperr.go:17`).
- Produces:
  - `type GitIdentity struct { Name, Email string }`
  - `type GitWriter struct { Root string; Identity GitIdentity }`
  - `func NewGitWriter(root string, allowedRoots []string, id GitIdentity) (*GitWriter, error)`
  - `func (w *GitWriter) Stage(ctx context.Context, paths []string) error`
  - `func (w *GitWriter) Unstage(ctx context.Context, paths []string) error`
  - `func (w *GitWriter) Commit(ctx context.Context, message string, all bool) (GitCommitResult, error)`
  - `func (w *GitWriter) Amend(ctx context.Context, message string) (GitCommitResult, error)`
  - `func (w *GitWriter) UndoCommit(ctx context.Context) (message string, err error)`
  - `type GitCommitResult struct { Commit string \`json:"commit"\`; Summary string \`json:"summary"\` }`
  - `var gitWriteSafetyArgs []string`

- [ ] **Step 1: Write the failing tests**

```go
package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// gitOut is gitIn (gitread_test.go:18) returning trimmed stdout.
func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return strings.TrimRight(string(out), "\n")
}

func writerFor(t *testing.T, dir string, id GitIdentity) *GitWriter {
	t.Helper()
	w, err := NewGitWriter(dir, []string{dir}, id)
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func TestStageUnstageAndCommitUnderTheOrganisationsIdentity(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "-rf.txt"), []byte("x\n"), 0o644)
	w := writerFor(t, dir, GitIdentity{Name: "Org Person", Email: "org@example.test"})
	ctx := context.Background()
	if err := w.Stage(ctx, []string{"a.txt", "-rf.txt"}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "diff", "--cached", "--name-only"); got != "-rf.txt\na.txt" {
		t.Fatalf("staged %q", got)
	}
	if err := w.Unstage(ctx, []string{"-rf.txt"}); err != nil {
		t.Fatal(err)
	}
	r, err := w.Commit(ctx, "fix login\n\nbody line", false)
	if err != nil {
		t.Fatal(err)
	}
	if r.Summary != "fix login" || len(r.Commit) < 7 {
		t.Fatalf("result %+v", r)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%an <%ae>|%cn <%ce>|%B"); got != "Org Person <org@example.test>|Org Person <org@example.test>|fix login\n\nbody line" {
		t.Fatalf("log %q", got)
	}
}

func TestCommitWithoutAnIdentityUsesTheRepositorysConfig(t *testing.T) {
	dir := gitTestRepo(t) // sets user.email t@example.test, user.name T
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	if _, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "m", true); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%ae"); got != gitOut(t, dir, "config", "user.email") {
		t.Fatalf("author %q", got)
	}
}

func TestCommitAllTakesUntrackedFiles(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644)
	if _, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "add", true); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "show", "--name-only", "--format=", "HEAD"); got != "new.txt" {
		t.Fatalf("committed %q", got)
	}
}

func TestAnEmptyOrWhitespaceMessageIsRefused(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	_, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "  \n ", true)
	if err == nil || err.Error() != "the message is empty" {
		t.Fatalf("err %v", err)
	}
}

func TestAFailingHookCommitsNothingAndSaysWhy(t *testing.T) {
	dir := gitTestRepo(t)
	hook := filepath.Join(dir, ".git", "hooks", "pre-commit")
	os.WriteFile(hook, []byte("#!/bin/sh\necho 'lint: 3 problems' >&2\nexit 1\n"), 0o755)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	before := gitOut(t, dir, "rev-parse", "HEAD")
	_, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "m", true)
	if err == nil || !strings.Contains(err.Error(), "lint: 3 problems") {
		t.Fatalf("err %v", err)
	}
	if gitOut(t, dir, "rev-parse", "HEAD") != before {
		t.Fatal("a commit landed")
	}
}

func TestAnEmptyMessageConcludesAMerge(t *testing.T) {
	dir := gitTestRepo(t)
	gitIn(t, dir, "checkout", "-q", "-b", "side")
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644)
	gitIn(t, dir, "add", "b.txt")
	gitIn(t, dir, "commit", "-q", "-m", "side")
	gitIn(t, dir, "checkout", "-q", "main")
	os.WriteFile(filepath.Join(dir, "c.txt"), []byte("c\n"), 0o644)
	gitIn(t, dir, "add", "c.txt")
	gitIn(t, dir, "commit", "-q", "-m", "main")
	exec.Command("git", "-C", dir, "merge", "--no-commit", "--no-ff", "side").Run()
	if _, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "", false); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%s"); !strings.HasPrefix(got, "Merge branch 'side'") {
		t.Fatalf("subject %q", got)
	}
}

func TestAmendKeepsTheMessageWhenNoneIsGiven(t *testing.T) {
	dir := gitTestRepo(t)
	w := writerFor(t, dir, GitIdentity{})
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	w.Commit(context.Background(), "first msg", true)
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644)
	w.Stage(context.Background(), []string{"b.txt"})
	if _, err := w.Amend(context.Background(), ""); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%s"); got != "first msg" {
		t.Fatalf("subject %q", got)
	}
	if got := gitOut(t, dir, "show", "--name-only", "--format=", "HEAD"); got != "a.txt\nb.txt" {
		t.Fatalf("files %q", got)
	}
}

func TestUndoCommitIsSoftAndReturnsTheMessage(t *testing.T) {
	dir := gitTestRepo(t)
	w := writerFor(t, dir, GitIdentity{})
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	w.Commit(context.Background(), "undo me\n\nmore", true)
	msg, err := w.UndoCommit(context.Background())
	if err != nil || msg != "undo me\n\nmore" {
		t.Fatalf("%q %v", msg, err)
	}
	if got := gitOut(t, dir, "diff", "--cached", "--name-only"); got != "a.txt" {
		t.Fatalf("staged after undo %q", got)
	}
}

func TestUndoOnTheFirstCommitIsRefused(t *testing.T) {
	dir := gitTestRepo(t)
	_, err := writerFor(t, dir, GitIdentity{}).UndoCommit(context.Background())
	if err == nil || err.Error() != "nothing to undo: this is the first commit" {
		t.Fatalf("err %v", err)
	}
}

func TestAPathOutsideTheRootIsRefused(t *testing.T) {
	dir := gitTestRepo(t)
	if err := writerFor(t, dir, GitIdentity{}).Stage(context.Background(), []string{"../x"}); err == nil {
		t.Fatal("staged outside the root")
	}
}

func TestReadsStillRunNoHook(t *testing.T) {
	dir := gitTestRepo(t)
	marker := filepath.Join(dir, "hook-ran")
	os.WriteFile(filepath.Join(dir, ".git", "hooks", "post-index-change"),
		[]byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0o755)
	g, _ := NewGitRunner(dir, []string{dir})
	g.Run(context.Background(), "status", "--porcelain=v2")
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a read ran a hook")
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run 'Stage|Commit|Amend|Undo|PathOutside|ReadsStill' -count=1`
Expected: FAIL — `undefined: NewGitWriter` (and `GitIdentity`).

- [ ] **Step 3: Implement `gitwrite.go`**

```go
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
```

`gitTestRepo` (gitread_test.go:28) sets `user.email`/`user.name` locally; `TestCommitWithoutAnIdentityUsesTheRepositorysConfig` relies on that.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ -run 'Stage|Commit|Amend|Undo|PathOutside|ReadsStill' -count=1`
Expected: PASS. Then `go test ./internal/wakilcore/ -count=1` — PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/gitwrite.go internal/wakilcore/gitwrite_test.go
git commit -m "wakil-git: GitWriter — stage, unstage, commit, amend, undo, under the organisation's identity; hooks run, reads still run none"
```

---

### Task 2: `GitWriter` — discard through the Trash, stage content (Stage Change)

**Files:**
- Modify: `internal/wakilcore/gitwrite.go`
- Test: `internal/wakilcore/gitwrite_test.go`

**Interfaces:**
- Consumes: `TrashEntry(ctx, path string, roots []string) (FileEntry, error)` (`fileops.go:147`); `fakeTrash(t) string` (`fileops_test.go:159`); Task 1's `GitWriter`.
- Produces:
  - `func (w *GitWriter) Discard(ctx context.Context, paths []string, now time.Time) ([]string, error)` — returns the Trash names used.
  - `func (w *GitWriter) StageContent(ctx context.Context, path, content, expect string) error` — `expect` is the current index blob id (`git rev-parse :<path>`), refusal text `the change moved — open the peek again`.
  - `func (w *GitWriter) IndexBlob(ctx context.Context, path string) (string, error)`

- [ ] **Step 1: Write the failing tests**

```go
func TestDiscardTrashesTheCurrentCopyThenRestores(t *testing.T) {
	args := fakeTrash(t)
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644)
	at := time.Date(2026, 10, 21, 14, 2, 0, 0, time.Local)
	names, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"a.txt", "new.txt"}, at)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "one\n" {
		t.Fatalf("a.txt is %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "new.txt")); !os.IsNotExist(err) {
		t.Fatal("untracked file still there")
	}
	if want := []string{"a.txt (discarded 14:02)", "new.txt"}; strings.Join(names, "|") != strings.Join(want, "|") {
		t.Fatalf("names %v", names)
	}
	if b, _ := os.ReadFile(args); !strings.Contains(string(b), "a.txt (discarded 14:02)") {
		t.Fatalf("trash got %q", b)
	}
}

func TestTwoDiscardsInOneMinuteNeverOverwrite(t *testing.T) {
	fakeTrashKeeping(t) // like fakeTrash but leaves the file in place, so the name stays taken
	dir := gitTestRepo(t)
	w := writerFor(t, dir, GitIdentity{})
	at := time.Date(2026, 10, 21, 14, 2, 0, 0, time.Local)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("x\n"), 0o644)
	first, _ := w.Discard(context.Background(), []string{"a.txt"}, at)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("y\n"), 0o644)
	second, _ := w.Discard(context.Background(), []string{"a.txt"}, at)
	if first[0] != "a.txt (discarded 14:02)" || second[0] != "a.txt (discarded 14:02) 2" {
		t.Fatalf("%v %v", first, second)
	}
}

func TestStageContentWritesTheIndexAndRefusesAMovedChange(t *testing.T) {
	dir := gitTestRepo(t)
	w := writerFor(t, dir, GitIdentity{})
	ctx := context.Background()
	blob, _ := w.IndexBlob(ctx, "a.txt")
	if err := w.StageContent(ctx, "a.txt", "one\nstaged\n", blob); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "show", ":a.txt"); got != "one\nstaged" {
		t.Fatalf("index %q", got)
	}
	if err := w.StageContent(ctx, "a.txt", "other\n", blob); err == nil || err.Error() != "the change moved — open the peek again" {
		t.Fatalf("err %v", err)
	}
}
```

Add to `gitwrite_test.go`:

```go
func fakeTrashKeeping(t *testing.T) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "trash")
	os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ -run 'Discard|StageContent' -count=1`
Expected: FAIL — `w.Discard undefined`.

- [ ] **Step 3: Implement**

```go
// Discard sends each path's current copy to the Trash, then restores tracked ones from the index.
// A tracked file is renamed `<name> (discarded HH:MM)` first (` 2`, ` 3` … when taken), so the
// Trash says what it was; an untracked one goes as itself (Decision 41's Move to Trash).
func (w *GitWriter) Discard(ctx context.Context, paths []string, now time.Time) ([]string, error) {
	ps, err := w.paths(paths)
	if err != nil {
		return nil, err
	}
	var names, tracked []string
	for _, p := range ps {
		abs, _ := w.runner().ResolvePath(p)
		_, lsErr := w.runner().Run(ctx, "rev-parse", "--verify", ":"+p)
		isTracked := lsErr == nil
		target := abs
		if isTracked {
			base := filepath.Base(abs) + " (discarded " + now.Format("15:04") + ")"
			target = filepath.Join(filepath.Dir(abs), base)
			for n := 2; ; n++ {
				if _, err := os.Lstat(target); os.IsNotExist(err) {
					break
				}
				target = filepath.Join(filepath.Dir(abs), base+" "+strconv.Itoa(n))
			}
			if err := os.Rename(abs, target); err != nil {
				return names, UserError("discard " + p + ": " + err.Error())
			}
			tracked = append(tracked, p)
		}
		if _, err := TrashEntry(ctx, target, []string{w.Root}); err != nil {
			return names, err
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
```

Imports gain `path/filepath` and `time`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/gitwrite.go internal/wakilcore/gitwrite_test.go
git commit -m "wakil-git: discard through the Trash, and Stage Change as index content refused when the index moved"
```

---

### Task 3: the organisation's git identity — `Org`, `update_org`, `config_tree`

**Files:**
- Modify: `internal/wakilcore/org.go` (Org struct `:18-49`, `OrgPatch`, `UpdateOrg`, `normaliseOrg :164`)
- Modify: `internal/wakilcore/configtree.go` (`ConfigTreeOrg :14-23`, literal `:195`)
- Modify: `cmd/wakil-ctx/main.go` (`updateOrgArgs :147`, handler `:494-502`)
- Test: `internal/wakilcore/org_test.go`, `cmd/wakil-ctx/main_test.go`

**Interfaces:**
- Produces: `Org.GitName`, `Org.GitEmail` (`json:"gitName,omitempty"`, `json:"gitEmail,omitempty"`); `OrgPatch.GitName`, `OrgPatch.GitEmail` (`*string`); `ConfigTreeOrg.GitName`, `ConfigTreeOrg.GitEmail` (`json:"gitName"`, `json:"gitEmail"`); `func OrgGitIdentity(o *Org) GitIdentity`.

- [ ] **Step 1: Write the failing tests**

In `internal/wakilcore/org_test.go` (follow the file's existing temp-HOME setup used by its `UpdateOrg` tests):

```go
func TestUpdateOrgSetsAndClearsTheGitIdentity(t *testing.T) {
	setupOrgHome(t, "initech") // the file's existing helper; use whichever one its UpdateOrg tests use
	name, email := "Org Person", "org@example.test"
	if err := UpdateOrg("initech", OrgPatch{GitName: &name, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if OrgGitIdentity(o) != (GitIdentity{Name: name, Email: email}) {
		t.Fatalf("%+v", o)
	}
	empty := ""
	UpdateOrg("initech", OrgPatch{GitEmail: &empty})
	o, _ = LoadOrgFor("initech")
	if o.GitEmail != "" || o.GitName != name {
		t.Fatalf("%+v", o)
	}
}

func TestAGitIdentityWithANewlineIsRefused(t *testing.T) {
	setupOrgHome(t, "initech")
	bad := "a@b\nx"
	err := UpdateOrg("initech", OrgPatch{GitEmail: &bad})
	if err == nil || err.Error() != "gitName and gitEmail cannot hold a newline" {
		t.Fatalf("err %v", err)
	}
}
```

In `configtree_test.go`: assert `LoadConfigTreeFor("initech")` returns `Org.GitName`/`GitEmail` after an `UpdateOrg`.

In `cmd/wakil-ctx/main_test.go`: call the `update_org` tool with `{"id":"initech","gitName":"N","gitEmail":"e@x"}` and assert the org file holds both.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/ -run 'GitIdentity|Git' -count=1`
Expected: FAIL — unknown field `GitName`.

- [ ] **Step 3: Implement**

- `Org`: add `GitName string \`json:"gitName,omitempty"\`` and `GitEmail string \`json:"gitEmail,omitempty"\`` with a comment: the author identity every commit from Wakil uses (3a-ii, Decision 43); empty falls back to git config.
- `OrgPatch`: add `GitName, GitEmail *string`; `UpdateOrg` applies them like `JiraBase` (nil unchanged, `""` clears).
- `normaliseOrg`: `if strings.ContainsAny(o.GitName+o.GitEmail, "\r\n") { return Org{}, UserError("gitName and gitEmail cannot hold a newline") }`.
- `func OrgGitIdentity(o *Org) GitIdentity { if o == nil { return GitIdentity{} }; return GitIdentity{Name: o.GitName, Email: o.GitEmail} }`.
- `ConfigTreeOrg`: add the two fields; fill them from `record` in `LoadConfigTreeFor`.
- `updateOrgArgs`: `GitName *string \`json:"gitName,omitempty" jsonschema:"author name for commits from Wakil; omit to leave unchanged, send \"\" to clear"\``; same for `GitEmail`; pass both into `OrgPatch`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/wakilcore/ ./cmd/wakil-ctx/ -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/org.go internal/wakilcore/configtree.go cmd/wakil-ctx/main.go internal/wakilcore/*_test.go cmd/wakil-ctx/main_test.go
git commit -m "Org: a git author name and email per organisation, set through update_org and read on config_tree"
```

---

### Task 4: the `wakil-git` tools

**Files:**
- Modify: `cmd/wakil-git/main.go`
- Test: `cmd/wakil-git/main_test.go` (incl. `TestToolListIsExactlyTheThreeReads :154-168`)

**Interfaces:**
- Consumes: Tasks 1–3 (`NewGitWriter`, `GitIdentity`, `OrgGitIdentity`, `LoadOrg`), `runner(root)` pattern (`main.go:27-37`), `mcpx.ToolErr`.
- Produces (tool → args → result):
  - `git_stage` `{root, paths[]}` → `{}`; `git_unstage` same; `git_discard` `{root, paths[]}` → `{trashed: [names]}`
  - `git_stage_hunk` `{root, path, content, expect}` → `{}`
  - `git_commit` `{root, message, all}` → `{commit, summary}`; `git_amend` `{root, message?}` → `{commit, summary}`
  - `git_undo_commit` `{root}` → `{message}`
  - `git_identity` `{root}` → `{name, email, from: "organisation"|"git config"}` (read)
  - `git_blob` `{root, path}` → `{blob}` (read: `rev-parse --verify :<path>` through `GitRunner.Run`, which already allows `--verify`) — the `expect` Stage Change sends

- [ ] **Step 1: Write the failing tests**

```go
func TestToolListIsTheReadsAndTheWrites(t *testing.T) {
	cs := connectedClient(t)
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
	}
	sort.Strings(names)
	want := []string{"git_amend", "git_blob", "git_commit", "git_diff", "git_discard", "git_identity",
		"git_show", "git_stage", "git_stage_hunk", "git_status", "git_undo_commit", "git_unstage"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tools %v", names)
	}
}

func TestCommitThroughTheToolUsesTheOrganisationsIdentity(t *testing.T) {
	root := setupProject(t, `"local":{}`, "local")
	gitInit(t, root)
	name, email := "Org Person", "org@example.test"
	wakilcore.UpdateOrg("initech", wakilcore.OrgPatch{GitName: &name, GitEmail: &email})
	os.WriteFile(filepath.Join(root, "seed.txt"), []byte("changed\n"), 0o644)
	cs := connectedClient(t)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_commit",
		Arguments: map[string]any{"root": root, "message": "via tool", "all": true}})
	if err != nil || res.IsError {
		t.Fatalf("%v %+v", err, res)
	}
	out, _ := exec.Command("git", "-C", root, "log", "-1", "--format=%ae|%s").Output()
	if strings.TrimSpace(string(out)) != "org@example.test|via tool" {
		t.Fatalf("log %q", out)
	}
	id, _ := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_identity",
		Arguments: map[string]any{"root": root}})
	if !strings.Contains(fmt.Sprint(id.StructuredContent), "organisation") {
		t.Fatalf("identity %+v", id.StructuredContent)
	}
}

func TestAWriteOutsideTheProjectIsRefused(t *testing.T) {
	setupProject(t, `"local":{}`, "local")
	cs := connectedClient(t)
	res, _ := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "git_stage",
		Arguments: map[string]any{"root": t.TempDir(), "paths": []string{"a"}}})
	if !res.IsError {
		t.Fatal("staged in a root outside the project")
	}
}
```

Delete `TestToolListIsExactlyTheThreeReads` (superseded). If the org setup in `setupProject` does not create an org record `UpdateOrg` can patch, create it with `wakilcore.CreateOrg("initech", wakilcore.Org{})` in the test first.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./cmd/wakil-git/ -count=1`
Expected: FAIL — tool list mismatch; `git_commit` unknown.

- [ ] **Step 3: Implement**

Add a `writer(root)` beside `runner(root)`:

```go
func writer(root string) (*wakilcore.GitWriter, *mcp.CallToolResult) {
	r, err := wakilcore.Resolve()
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	org, _ := wakilcore.LoadOrg() // read at each write, so a Settings change applies at once
	w, err := wakilcore.NewGitWriter(root, wakilcore.ProjectRootPaths(*r), wakilcore.OrgGitIdentity(org))
	if err != nil {
		return nil, mcpx.ToolErr("wakil-git", err)
	}
	return w, nil
}
```

Arg structs (jsonschema descriptions in the file's style):

```go
type pathsArg struct {
	Root  string   `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Paths []string `json:"paths" jsonschema:"file paths relative to the root"`
}
type hunkArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path    string `json:"path" jsonschema:"file path relative to the root"`
	Content string `json:"content" jsonschema:"the file's whole new index text"`
	Expect  string `json:"expect" jsonschema:"the index blob id the content was computed against"`
}
type commitArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message" jsonschema:"the commit message"`
	All     bool   `json:"all,omitempty" jsonschema:"stage every change, untracked included, first"`
}
type amendArg struct {
	Root    string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Message string `json:"message,omitempty" jsonschema:"a new message; omit to keep the last commit's"`
}
type blobArg struct {
	Root string `json:"root" jsonschema:"absolute path of one of the active project's roots"`
	Path string `json:"path" jsonschema:"file path relative to the root"`
}
```

Each tool follows the `git_diff` block exactly (`writer` in place of `runner`, call the method, `mcpx.ToolErr("wakil-git", err)` on error). Descriptions start `"Writes."` for the seven writes and say what each runs (e.g. `"Writes. Commits what is staged (or, with all, every change) in one root, running the repository's hooks and signing, as the organisation's git identity when it sets one."`). `git_discard` passes `time.Now()`. `git_identity`: organisation identity when both fields are set (`from: "organisation"`), else read `user.name`/`user.email` with a fixed argv through a new `GitRunner` method `ConfigValue(ctx, key string) string` that runs `exec(ctx, gitSafetyArgs, "config", []string{"--get", key})` (like `repoFilterOverrides`), `from: "git config"`. Add a unit test for `ConfigValue` in `gitread_test.go` (`user.email` of `gitTestRepo` is `t@example.test` or whatever that helper sets).

- [ ] **Step 4: Run the tests**

Run: `go test ./cmd/wakil-git/ ./internal/wakilcore/ -count=1` then `go test ./... -count=1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil-git internal/wakilcore/gitread.go internal/wakilcore/gitread_test.go
git commit -m "wakil-git: the seven write tools, git_blob and git_identity"
```

---

### Task 5: the `editor_changes_*` actions

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorChangesWrites.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorActions.swift` (call the new registration from `registerEditorActions`, `:262`)
- Modify: `app/Sources/WakilKit/Editor/EditorHunks.swift` (add `editorStagedText`)
- Test: `app/Tests/WakilKitTests/EditorChangesWritesTests.swift`, `app/Tests/WakilKitTests/EditorHunksTests.swift` (or the file that tests `editorRevertEdit`)

**Interfaces:**
- Consumes: `GitStatus` (`git: (any ToolCaller)?`, `refresh(only: String?) async`, `roots`), `editorHunks(base:text:)`, `editorRevertEdit(_:text:)`, `editorReplacing(_:_:with:)`, `Action` init with `price:`.
- Produces:
  - `public func editorStagedText(base: String, text: String, hunk: Int) -> String?` — the baseline with only hunk `hunk` applied (every other hunk of `text` reverted), nil when out of range.
  - `func registerEditorChangesWrites(into: ActionRegistry, gitStatus: GitStatus?, panes: PaneStore, writes: GitWriteFlights) async`
  - `public actor GitWriteFlights { public func begin(_ root: String) -> Bool; public func end(_ root: String); public func running(_ root: String) -> Bool }`
  - Results: `editor_changes_commit`/`_amend` return `{commit, summary}`; `_undo_commit` returns `{message}`; `_discard` returns `{trashed}`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import WakilKit

@Test func stagedTextAppliesOnlyTheChosenHunk() {
    let base = "a\nb\nc\nd\n"
    let text = "a\nB\nc\nD\n"           // two changed hunks: line 2 and line 4
    #expect(editorStagedText(base: base, text: text, hunk: 0) == "a\nB\nc\nd\n")
    #expect(editorStagedText(base: base, text: text, hunk: 1) == "a\nb\nc\nD\n")
    #expect(editorStagedText(base: base, text: text, hunk: 2) == nil)
}

@Test func stagedTextHandlesAnAddedAndADeletedHunk() {
    #expect(editorStagedText(base: "a\nc\n", text: "a\nb\nc\n", hunk: 0) == "a\nb\nc\n")
    #expect(editorStagedText(base: "a\nb\nc\n", text: "a\nc\n", hunk: 0) == "a\nc\n")
}
```

In `EditorChangesWritesTests.swift`, with a recording `ToolCaller` fake for git (follow `GitStatusTests.swift`'s fake) registered through `registerEditorChangesWrites`:

```swift
@Test func eachWriteCallsItsToolWithTheRootAndIsAllowedEverywhere() async throws {
    let (registry, git) = await changesWritesFixture()     // fake git answers {} / {commit,summary}
    for (action, tool, params) in [
        ("editor_changes_stage", "git_stage", ["root": "/p", "paths": ["a.go"]]),
        ("editor_changes_unstage", "git_unstage", ["root": "/p", "paths": ["a.go"]]),
        ("editor_changes_discard", "git_discard", ["root": "/p", "paths": ["a.go"]]),
        ("editor_changes_commit", "git_commit", ["root": "/p", "message": "m"]),
        ("editor_changes_amend", "git_amend", ["root": "/p"]),
        ("editor_changes_undo_commit", "git_undo_commit", ["root": "/p"]),
    ] as [(String, String, [String: Any])] {
        _ = try await registry.dispatch(name: action, params: jsonObject(params), origin: .agent,
                                        caller: DispatchCaller(place: nil, session: nil), confirmation: nil)
        #expect(await git.lastCall?.name == tool, "\(action)")
        let d = try #require(await registry.descriptor(named: action))
        #expect(d.kind == .mutate)
        #expect(d.price.production == .allow && d.price.otherwise == .allow)
    }
}

@Test func aGroupStagesEveryPathInIt() async throws {
    // GitStatus seeded with /p: changed a.go, b.go; untracked c.go
    // dispatch editor_changes_stage {root:/p, group:changed} → git_stage paths [a.go, b.go]
}

@Test func commitWithNothingStagedDefaultsToAll() async throws {
    // GitStatus /p with no staged rows → git_commit called with all: true; with a staged row → all: false
}

@Test func aSecondWriteOnTheSameRootIsRefusedAndAnotherRootIsNot() async throws {
    // fake git blocks git_commit on /p until released; while blocked:
    // dispatch editor_changes_stage on /p → throws "a git write is already running in p"
    // dispatch editor_changes_stage on /q → succeeds
}

@Test func afterAWriteTheRootsStatusIsReadAgain() async throws {
    // count git_status calls for /p before and after editor_changes_stage → +1
}

@Test func stageHunkSendsTheIndexTextAndTheBlobItWasComputedFrom() async throws {
    // an editor pane tab on /p/a.go with baseline "a\nb\n", text "a\nB\nc\n", peek 0;
    // fake git_blob answers {blob: "abc123"};
    // dispatch editor_changes_stage_hunk {path:"/p/a.go", hunk:0} →
    // git_stage_hunk {root:"/p", path:"a.go", content: editorStagedText(...), expect:"abc123"}
}
```

Write each commented test out in full in the same style as the first (the comments state the exact fixture and expectation).

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && swift test --filter "EditorChangesWrites|stagedText"`
Expected: FAIL — `editorStagedText` and `registerEditorChangesWrites` not found.

- [ ] **Step 3: Implement**

`editorStagedText` in `EditorHunks.swift`:

```swift
/// The index text Stage Change writes (3a-ii, ruling R1): `text` with every hunk but `hunk` reverted
/// to `base`, so the index gains exactly the one change the peek shows. Reverted from the last hunk
/// up, so each earlier hunk's line numbers still hold.
public func editorStagedText(base: String, text: String, hunk: Int) -> String? {
    let hunks = editorHunks(base: base, text: text)
    guard hunks.indices.contains(hunk) else { return nil }
    var out = text
    for i in hunks.indices.reversed() where i != hunk {
        let e = editorRevertEdit(hunks[i], text: out)
        out = editorReplacing(out, e.range, with: e.text)
    }
    return out
}
```

`EditorChangesWrites.swift` — one `Action` per row of the spec's table, each:

```swift
await registry.register(Action(
    name: "editor_changes_commit",
    description: "Commit what is staged in one root — or, with all (the default when nothing is staged), every change there, untracked files included — with message. Runs the repository's hooks and signing, as the organisation's git identity when Settings sets one. Allowed everywhere: a commit stays on this Mac and editor_changes_undo_commit reverses it.",
    kind: .mutate, audience: .agentReachable,
    schema: schema(["root": .object(["type": .string("string")]),
                    "message": .object(["type": .string("string")]),
                    "all": .object(["type": .string("boolean")])], required: ["root", "message"]),
    handler: { params in
        let root = try requireStringParam(params, "root", action: "editor_changes_commit")
        let message = try requireStringParam(params, "message", action: "editor_changes_commit")
        let all = optionalBool(params, "all") ?? !(await hasStaged(root))
        return try await write(root, action: "editor_changes_commit") { git in
            try await git.callTool(name: "git_commit",
                arguments: .object(["root": .string(root), "message": .string(message), "all": .bool(all)]),
                timeout: nil)   // a hook may take minutes; cancel, not a timeout (Rule 4)
        }
    },
    price: (production: .allow, otherwise: .allow)))
```

with a shared `write(_ root:, action:, body:)` that: resolves `gitStatus?.git` or throws `StandardActionError.missingClient(action:, role: "git")`; `guard await writes.begin(root) else { throw StandardActionError.refused(action, "a git write is already running in \(rootName)") }` (use the file's existing refusal error type — `StandardActionError` has the cases the other editor actions throw; pick the one `editor_trash` uses for a refusal); `defer` → `writes.end(root)`; calls `body`; then `await gitStatus?.refresh(only: root)`; returns the tool's structured content. Group params expand to the paths of that group from `gitStatus.roots.first { $0.root == root }?.files.filter { $0.group == g }.map(\.path)`. Paths sent to the tools are root-relative (strip `root + "/"` when an absolute path is given). `editor_changes_stage_hunk` reads the focused editor tab for `path` (`panes` snapshot: `baseline`, `text`), finds its root (`gitStatus.roots`, longest prefix), calls `git_blob` for `expect`, computes `editorStagedText(base:text:hunk:)`, then `git_stage_hunk`.

Use `timeout: nil` only if `ToolCaller.callTool` accepts an optional; otherwise pass the longest timeout constant the file already uses for writes and note it. Check `ToolCaller.swift:37` for the signature before writing.

Register from `registerEditorActions` (`EditorActions.swift:262`) with `await registerEditorChangesWrites(into: registry, gitStatus: gitStatus, panes: panes, writes: GitWriteFlights())` — or take a `GitWriteFlights` passed in from `WindowModel` (Task 6 needs to read `running(_:)` for the spinners; pass the window's instance).

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter "EditorChanges|stagedText|ActionClassification|WriteGate"`
Expected: PASS (`ActionClassificationTests` requires the audience; `WriteGateTests` may list priced actions — add the seven where it enumerates them).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Editor app/Tests/WakilKitTests
git commit -m "WakilKit: the seven editor_changes_* git writes, priced allow, one per root at a time, status re-read after"
```

---

### Task 6: the window's Changes state — messages, history, flights, errors, hint

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (stored properties; `OrganisationField` `:2757` gains `gitName`, `gitEmail`)
- Create: `app/Sources/WakilKit/App/WindowModel+ChangesWrites.swift`
- Modify: `app/Tests/WakilKitTests/InvalidationContractTests.swift` (classify new properties)
- Test: `app/Tests/WakilKitTests/WindowModelChangesWritesTests.swift`

**Interfaces:**
- Consumes: Task 5's actions and `GitWriteFlights`; `registry.dispatch`.
- Produces (all `@MainActor` on `WindowModel`):
  - `public private(set) var changesMessages: [String: String]` (root → draft)
  - `public private(set) var changesHistory: [String: [String]]` (root → newest first, ≤ 20)
  - `public private(set) var changesErrors: [String: String]` (root → last write's error, whole)
  - `public private(set) var changesInFlight: Set<String>` (roots with a write running)
  - `public private(set) var changesIdentity: [String: (email: String, fromConfig: Bool)]` — read with `git_identity` when the Changes view shows a root, and after a Settings save of `gitName`/`gitEmail`
  - `public func changesMessageEdited(root: String, text: String)`
  - `public func changesHistoryStep(root: String, by delta: Int)` — ↑ (`-1`… older) / ↓
  - `public func changesCommit(root: String) async` — trims; empty → no-op; dispatches `editor_changes_commit` (origin `.ui`); success clears the draft, pushes the message into history, clears the error; failure keeps the draft and sets `changesErrors[root]`
  - `public func changesAmend(root: String) async`, `changesUndoCommit(root: String) async` (fills the draft with the returned message), `changesStage/Unstage/Discard(root: String, paths: [String]?, group: GitGroup?) async`, `changesStageHunk() async` (focused tab, current peek)
  - `public func changesCancel(root: String)` — cancels that root's in-flight dispatch task
  - `public func changesHint(root: String) -> String?` — `committing as <email>` / `committing as <email> (from git config)`

- [ ] **Step 1: Write the failing tests**

```swift
@Suite @MainActor struct WindowModelChangesWritesTests {
    @Test func aCommitClearsTheDraftAndRemembersTheMessage() async {
        let (window, git) = await changesWindow()           // fake git answers git_commit {commit:"abc1234",summary:"fix"}
        window.changesMessageEdited(root: "/p", text: "fix")
        await window.changesCommit(root: "/p")
        #expect(window.changesMessages["/p", default: ""] == "")
        #expect(window.changesHistory["/p"] == ["fix"])
        #expect(await git.lastCall?.name == "git_commit")
    }

    @Test func aWhitespaceMessageCommitsNothing() async {
        let (window, git) = await changesWindow()
        window.changesMessageEdited(root: "/p", text: "  \n")
        await window.changesCommit(root: "/p")
        #expect(await git.lastCall == nil)
    }

    @Test func aFailedCommitKeepsTheDraftAndShowsTheErrorWhole() async {
        let (window, _) = await changesWindow(failCommit: "git commit failed (exit 1):\nlint: 3 problems")
        window.changesMessageEdited(root: "/p", text: "fix")
        await window.changesCommit(root: "/p")
        #expect(window.changesMessages["/p"] == "fix")
        #expect(window.changesErrors["/p"]?.contains("lint: 3 problems") == true)
    }

    @Test func undoPutsTheMessageBackInTheBox() async {
        let (window, _) = await changesWindow(undoMessage: "undo me")
        await window.changesUndoCommit(root: "/p")
        #expect(window.changesMessages["/p"] == "undo me")
    }

    @Test func upAndDownStepThroughHistoryAndTypingLeavesIt() async {
        let (window, _) = await changesWindow()
        for m in ["one", "two"] { window.changesMessageEdited(root: "/p", text: m); await window.changesCommit(root: "/p") }
        window.changesHistoryStep(root: "/p", by: -1)
        #expect(window.changesMessages["/p"] == "two")
        window.changesHistoryStep(root: "/p", by: -1)
        #expect(window.changesMessages["/p"] == "one")
        window.changesHistoryStep(root: "/p", by: 1)
        #expect(window.changesMessages["/p"] == "two")
        window.changesMessageEdited(root: "/p", text: "two!")
        window.changesHistoryStep(root: "/p", by: -1)      // a typed box is not history: ↑ does nothing
        #expect(window.changesMessages["/p"] == "two!")
    }

    @Test func historyKeepsTheLastTwenty() async { /* commit 25 messages "m0"…"m24"; history count 20, first "m24" */ }

    @Test func theHintNamesWhoWillCommit() async {
        // git_identity answers {name:"O", email:"o@x", from:"organisation"} → "committing as o@x"
        // then {from:"git config", email:"me@y"} → "committing as me@y (from git config)"
    }

    @Test func aCommitThatLandsAfterAnOrgSwitchIsNotShown() async {
        // fake git_commit waits on a gate; start changesCommit, switch org (the file's existing helper
        // used by InvalidationContractTests / OrgSwitchTests), release the gate:
        // changesErrors and changesHistory for "/p" are empty in the new org
    }
}
```

Write `historyKeepsTheLastTwenty`, `theHintNamesWhoWillCommit` and `aCommitThatLandsAfterAnOrgSwitchIsNotShown` out in full with the fixtures named in their comments.

- [ ] **Step 2: Run them to see them fail**

Run: `cd app && swift test --filter WindowModelChangesWrites`
Expected: FAIL — `changesMessageEdited` not found.

- [ ] **Step 3: Implement**

`WindowModel+ChangesWrites.swift` holds the methods; the stored properties go in `WindowModel.swift` (extensions cannot hold them). A history cursor per root: `changesHistoryCursor: [String: Int]` — `nil` when the box was typed in; `changesHistoryStep` only moves when the box is empty or still showing the entry at the cursor. The org-switch guard: capture `organization` before the dispatch, and drop the result when it differs after (the pattern `runFastPath` uses with `quickTasksGeneration`/`organization`). `OrganisationField` gains `gitName` (label "Git name") and `gitEmail` (label "Git email"); `saveOrganisationField` already sends `field.rawValue`, which is `gitName`/`gitEmail`, matching `update_org`'s new args. After saving either, re-read `changesIdentity` for the shown roots.

Classify in `InvalidationContractTests.swift`: `changesMessages`, `changesHistory`, `changesHistoryCursor`, `changesErrors`, `changesIdentity` in `orgDerived` (reset in `invalidateForOrgChange`; add the resets there); `changesInFlight` and the flights/tasks holder in `orgDerivedBehindAReference` if they hold `Task`s that must be cancelled, else `orgDerived`.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter "WindowModelChangesWrites|InvalidationContract|OrgSwitch"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App app/Tests/WakilKitTests
git commit -m "Window: the Changes view's drafts, history, errors, writes in flight and commit hint, per root"
```

---

### Task 7: WakilApp — the Changes view controls, the peek's Stage Change, Settings → Git

**Files:**
- Modify: `app/Sources/WakilApp/EditorColumn.swift` (`changesView :363`, `changesHeader :398`, `changesRow :431`)
- Modify: `app/Sources/WakilApp/monaco-host.html` (peek buttons `:292`)
- Modify: `app/Sources/WakilApp/EditorPane.swift` (`peekOp :507`)
- Modify: `app/Sources/WakilApp/SettingsPane.swift` (`subject(of:) :433`, loop `:440`)
- Modify: `app/Sources/WakilApp/Canvas.swift` (pass the window's Changes state and closures into the editor pane / column)

**Interfaces:**
- Consumes: Task 6's `WindowModel` members.
- Produces: accessibility identifiers (exact):
  - `editor.changes.<rootName>.message`, `.commit`, `.menu`, `.amend`, `.undo`, `.cancel`, `.error`, `.hint`
  - `editor.changes.<rootName>.<group>.stageAll` / `.unstageAll` / `.discardAll` (`group` ∈ `staged`, `changed`, `untracked`)
  - `editor.changes.row:<rootName>/<path>:<group>.stage` / `.unstage` / `.discard` (suffixing the row's existing id, `EditorColumn.swift:456`)
  - peek button op `stage` (`post({type:'peek', key, op:'stage'})`)
  - `settings.org.gitName`, `settings.org.gitEmail` (from `OrganisationField.identifierFragment`)

- [ ] **Step 1: Root header (`changesHeader`)**

Under the existing header row, when the root is expanded: a `TextEditor`-backed multi-line field bound to `model.changesMessages[root.root, default: ""]` through `changesMessageEdited`, placeholder `Message (⌘⏎ to commit)`, 1–6 lines tall; `.onKeyPress` for ⌘⏎ → `changesCommit`, ↑/↓ → `changesHistoryStep` (only when the caret is on the first/last line, so ↑ inside a multi-line message still moves the caret); a **Commit** / **Commit All** button (`Commit All` when `root.files` has no `.staged` row), disabled when the trimmed draft is empty; a **▾** `Menu` with *Amend Last Commit* and *Undo Last Commit*; a `ProgressView` and **Cancel** in place of the button while `changesInFlight.contains(root.root)`; the hint (`changesHint`) in the meta style; the error (`changesErrors[root]`) in the caution colour, `.fixedSize(horizontal: false, vertical: true)` (whole, Rule 8).

- [ ] **Step 2: Group labels and rows**

Replace the inline group `Text` (`:376-380`) with an `HStack` of the label and, on hover, the group's buttons (`+` Stage All for changed/untracked, `−` Unstage All for staged, `↺` Discard All for changed/untracked; SF Symbols `plus`, `minus`, `arrow.uturn.backward`). In `changesRow`, the same per-row buttons on hover, trailing, each a `.plain` button with its identifier, dispatching `changesStage/Unstage/Discard(root:paths:[row.path], group: nil)`. Buttons are disabled while the root's write is in flight. Clicking a button must not select the row (they sit outside the row's tap gesture).

- [ ] **Step 3: The peek's Stage Change**

`monaco-host.html:292`: insert `['Stage Change','stage']` before `['Revert','revert']`. `EditorPane.peekOp` (`:507`): `case "stage": Task { await model.changesStageHunk() }` through the closure the pane already receives for dispatches (add one, `stageHunk: () async -> Void`, from Canvas). Shown only when the tab's file is tracked (the peek exists only then, since `baseline` is the index text).

- [ ] **Step 4: Settings → Organisation → GIT**

In `subject(of:)` (`SettingsPane.swift:433`), after the organisation fields loop: a `GIT` micro header (as QUICK TASKS is drawn) and `organisationEditor(.gitName, in: tree)`, `organisationEditor(.gitEmail, in: tree)`; exclude both from the generic loop's filter at `:440` so they draw only under GIT.

- [ ] **Step 5: Build and run the app tests**

Run: `make app-bundle` then `make app-test`
Expected: builds; all tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/WakilApp
git commit -m "Changes view: the commit box, Commit / Commit All, Amend, Undo, row and group buttons; the peek's Stage Change; Settings → Organisation → Git"
```

---

### Task 8: e2e checks, charter, runbook

**Files:**
- Create: `e2e/checks/seeded/3a-ii-commit.jsonl`, `3a-ii-commit-all.jsonl`, `3a-ii-discard.jsonl`, `3a-ii-undo.jsonl`, `3a-ii-hook-fails.jsonl`, `3a-ii-stage-change.jsonl`, `3a-ii-identity.jsonl`
- Modify: `e2e/checks/uncoverable.tsv` (only for display-only Texts: `.hint`, `.error`)
- Modify: `docs/wakil/north-star.md` (Invariant 6 table row; "Six have earned in"), `docs/wakil/decisions.md` (appendix entry; Decision 43; Decision 40's last sentence)
- Create: `docs/wakil/phase-3a-ii-acceptance.md` (with the two machine-walk markers copied from `phase-3b-ix-acceptance.md`)

- [ ] **Step 1: Write the checks** — each opens the seeded git project as `3b-iii-changes-list.jsonl` does (`cmd+p`, `e2e-git`, the project row), opens the Changes view (`cmd+shift+g`), then:
  - commit: click a row's `.stage`, type `e2e commit` into `editor.changes.<root>.message`, `cmd+Return`; expect `{"journal":{"contains":"\"summary\":\"e2e commit\""}}` (the tool's result is journalled), the row gone from the tree, and no `.error` text.
  - commit-all: nothing staged; expect the button text `Commit All`; commit; expect the Changes list empty for that root (`<root> · main · clean`-style text the view draws).
  - discard: hover/click a row's `.discard`; expect the row gone; expect the journal entry with `"trashed"`.
  - undo: as above, on its own.
  - hook-fails: the seed needs a failing `pre-commit` hook — add an option to `seedRepo` (`e2e/driver/seedgit.go:173`) to write `.git/hooks/pre-commit` (`echo 'e2e hook says no' >&2; exit 1`) for a second seeded repo, then commit and expect `e2e hook says no` in the tree and the message still in the box.
  - stage-change: open a file of the seeded repo, edit two separate lines (`editor_replace_range` dispatch), open the peek on the first (the existing `3b-iii-peek.jsonl` steps), click `Stage Change`; expect the file under both Staged and Changes.
  - identity: Settings → organisation, type `E2E Org` / `org@e2e.invalid` into `settings.org.gitName` / `.gitEmail`, click away; commit; expect the hint `committing as org@e2e.invalid`.

  `seedGitEnv` (`seedgit.go:207`) fixes the seed's author; Wakil's commit uses the org identity only when set, so the seed's own commits are unaffected.

- [ ] **Step 2: Prove them red against main and green here**

Run: `make e2e-new` — expected: each new check red against the merge-base, proofs written. Commit the checks and proofs.

- [ ] **Step 3: Charter**

- `north-star.md` Invariant 6: "Five have earned in" → "Six have earned in"; table row `| Stage, unstage, discard, commit — local git inside the project's roots | wakil-git | 2026-10-21 |`.
- `decisions.md` appendix *Invariant 6 — the writes that have earned in*: an entry dated 2026-10-21 with the spec's justification text (stays on this Mac; Undo Last Commit; the Trash holds a discard; hooks and signing run, no more than the agent's shell; reads still run none).
- `decisions.md` **Decision 43** with the spec's text and *Reverse if*; Decision 40's last sentence → "Stage, unstage, discard and commit are 3a-ii's (Decision 43)."

- [ ] **Step 4: Runbook** — `phase-3a-ii-acceptance.md`: setup (a scratch repo with a pre-commit hook), then ≤ 20 walk rows mirroring the spec's "What the operator gets" 1–11, by hand and by voice, ending with `git log -3 --format='%an <%ae> %s'` in a terminal; "Known and not fixed" (the agent's own shell commits under git config; R3: drafts don't survive relaunch); the machine-walk markers.

- [ ] **Step 5: Full verification**

Run: `go test ./... && make app-test && make e2e` — expected: all pass (known reds quarantined by name if they recur: `E2E_QUARANTINE=…`).

- [ ] **Step 6: Commit**

```bash
git add e2e docs/wakil
git commit -m "3a-ii: e2e checks, the sixth write in Invariant 6, Decision 43, runbook"
```
