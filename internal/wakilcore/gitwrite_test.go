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
	// The positive control: the same hook does run for a write, so its absence above is the read's doing.
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	if err := writerFor(t, dir, GitIdentity{}).Stage(context.Background(), []string{"a.txt"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("the hook did not run for a write either, so the read check proves nothing")
	}
}

func TestAMissingPathCanBeStaged(t *testing.T) {
	dir := gitTestRepo(t)
	os.Remove(filepath.Join(dir, "a.txt"))
	if err := writerFor(t, dir, GitIdentity{}).Stage(context.Background(), []string{"a.txt"}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "diff", "--cached", "--name-status"); got != "D\ta.txt" {
		t.Fatalf("staged %q", got)
	}
}

func TestPathsAreLiteralNotPathspecs(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b\n"), 0o644)
	gitIn(t, dir, "add", "b.txt")
	gitIn(t, dir, "commit", "-q", "-m", "b")
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("b2\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "*.txt"), []byte("star\n"), 0o644)
	if err := writerFor(t, dir, GitIdentity{}).Stage(context.Background(), []string{"*.txt"}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "diff", "--cached", "--name-only"); got != "*.txt" {
		t.Fatalf("staged %q", got)
	}
}

func fakeTrashKeeping(t *testing.T) {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "trash")
	os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
}

func TestDiscardTrashesTheCurrentCopyThenRestores(t *testing.T) {
	args := fakeTrash(t)
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644)
	at := time.Date(2026, 10, 21, 14, 2, 0, 0, time.Local)
	names, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"new.txt", "a.txt"}, at) // a.txt last: fakeTrash keeps only the last call's args
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "one\n" {
		t.Fatalf("a.txt is %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "new.txt")); !os.IsNotExist(err) {
		t.Fatal("untracked file still there")
	}
	if want := []string{"new.txt", "a.txt (discarded 14:02)"}; strings.Join(names, "|") != strings.Join(want, "|") {
		t.Fatalf("names %v", names)
	}
	if b, _ := os.ReadFile(args); !strings.Contains(string(b), "a.txt (discarded 14:02)") {
		t.Fatalf("trash got %q", b)
	}
}

func TestDiscardOfADeletedTrackedFileOnlyRestoresIt(t *testing.T) {
	args := fakeTrash(t)
	dir := gitTestRepo(t)
	os.Remove(filepath.Join(dir, "a.txt"))
	names, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"a.txt"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "one\n" {
		t.Fatalf("a.txt is %q", b)
	}
	if len(names) != 0 {
		t.Fatalf("names %v", names)
	}
	if _, err := os.Stat(args); !os.IsNotExist(err) {
		t.Fatal("the trash was called for a file that was not on disk")
	}
}

func TestTwoDiscardsInOneMinuteNeverOverwrite(t *testing.T) {
	fakeTrashKeeping(t) // like fakeTrash but leaves the file in place, so the name stays taken
	dir := gitTestRepo(t)
	w := writerFor(t, dir, GitIdentity{})
	at := time.Date(2026, 10, 21, 14, 2, 0, 0, time.Local)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("x\n"), 0o644)
	first, err := w.Discard(context.Background(), []string{"a.txt"}, at)
	if err != nil || len(first) != 1 {
		t.Fatalf("first discard: %v %v", first, err)
	}
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("y\n"), 0o644)
	second, err := w.Discard(context.Background(), []string{"a.txt"}, at)
	if err != nil || len(second) != 1 {
		t.Fatalf("second discard: %v %v", second, err)
	}
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

func TestADiscardThatFailsHalfwayLeavesNothingHalfDone(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "b.txt"), []byte("bee\n"), 0o644)
	gitOut(t, dir, "add", "b.txt")
	gitOut(t, dir, "commit", "-q", "-m", "b")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed\n"), 0o644)
	bin := filepath.Join(t.TempDir(), "trash")
	script := "#!/bin/sh\nif [ -e \"" + bin + ".n\" ]; then exit 1; fi\ntouch \"" + bin + ".n\"\nrm -rf \"$2\"\n"
	os.WriteFile(bin, []byte(script), 0o755)
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
	_, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"a.txt", "b.txt"}, time.Now())
	if err == nil {
		t.Fatal("want the failure")
	}
	for f, want := range map[string]string{"a.txt": "one\n", "b.txt": "bee\n"} {
		if b, _ := os.ReadFile(filepath.Join(dir, f)); string(b) != want {
			t.Fatalf("%s is %q", f, b)
		}
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.Contains(e.Name(), "(discarded") {
			t.Fatalf("left behind: %s", e.Name())
		}
	}
}

func TestDiscardRefusesAConflictedPath(t *testing.T) {
	fakeTrash(t)
	dir := gitTestRepo(t)
	gitOut(t, dir, "checkout", "-q", "-b", "other")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("theirs\n"), 0o644)
	gitOut(t, dir, "commit", "-q", "-am", "theirs")
	gitOut(t, dir, "checkout", "-q", "main")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("ours\n"), 0o644)
	gitOut(t, dir, "commit", "-q", "-am", "ours")
	exec.Command("git", "-C", dir, "merge", "other").Run() // conflicts; exit 1 expected
	if gitOut(t, dir, "ls-files", "-u") == "" {
		t.Fatal("no conflict was made")
	}
	_, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"a.txt"}, time.Now())
	if err == nil || err.Error() != "a.txt has a merge conflict; resolve it before discarding" {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); err != nil {
		t.Fatal("a.txt vanished")
	}
}

func TestDiscardRefusesADirectory(t *testing.T) {
	args := fakeTrash(t)
	dir := gitTestRepo(t)
	os.MkdirAll(filepath.Join(dir, "d"), 0o755)
	os.WriteFile(filepath.Join(dir, "d", "x.txt"), []byte("x\n"), 0o644)
	gitIn(t, dir, "add", "d/x.txt")
	gitIn(t, dir, "commit", "-q", "-m", "d")
	os.WriteFile(filepath.Join(dir, "d", "x.txt"), []byte("changed\n"), 0o644)
	_, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"d"}, time.Now())
	if err == nil || err.Error() != "d is a directory, not a changed file" {
		t.Fatalf("err %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "d", "x.txt")); string(b) != "changed\n" {
		t.Fatalf("d/x.txt is %q", b)
	}
	if _, err := os.Stat(args); !os.IsNotExist(err) {
		t.Fatal("the trash was called")
	}
}

func TestDiscardRefusesAnIgnoredFile(t *testing.T) {
	args := fakeTrash(t)
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("*.log\n"), 0o644)
	gitIn(t, dir, "add", ".gitignore")
	gitIn(t, dir, "commit", "-q", "-m", "ignore")
	os.WriteFile(filepath.Join(dir, "x.log"), []byte("keep\n"), 0o644)
	_, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"x.log"}, time.Now())
	if err == nil || err.Error() != "x.log is not a changed file" {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "x.log")); err != nil {
		t.Fatal("the ignored file was discarded")
	}
	if _, err := os.Stat(args); !os.IsNotExist(err) {
		t.Fatal("the trash was called")
	}
}

func TestDiscardNormalisesThePath(t *testing.T) {
	fakeTrash(t)
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("changed\n"), 0o644)
	at := time.Date(2026, 10, 21, 14, 2, 0, 0, time.Local)
	names, err := writerFor(t, dir, GitIdentity{}).Discard(context.Background(), []string{"x/../a.txt"}, at)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "one\n" {
		t.Fatalf("a.txt is %q", b)
	}
	if strings.Join(names, "|") != "a.txt (discarded 14:02)" {
		t.Fatalf("names %v (tracked a.txt went to the Trash as untracked)", names)
	}
}

func TestUnstageOfAPathNotStagedIsANoOp(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "new.txt"), []byte("n\n"), 0o644)
	w := writerFor(t, dir, GitIdentity{})
	if err := w.Unstage(context.Background(), []string{"new.txt"}); err != nil {
		t.Fatalf("unstage of an untracked path: %v", err)
	}
	if err := w.Unstage(context.Background(), []string{"a.txt"}); err != nil {
		t.Fatalf("unstage of an unstaged tracked path: %v", err)
	}
}

func TestUnstagingARenameUnstagesBothSides(t *testing.T) {
	dir := gitTestRepo(t)
	gitIn(t, dir, "mv", "a.txt", "b.txt")
	if err := writerFor(t, dir, GitIdentity{}).Unstage(context.Background(), []string{"b.txt", "a.txt"}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "diff", "--cached", "--name-status"); got != "" {
		t.Fatalf("still staged %q", got)
	}
}

func TestAHashLineInTheMessageIsKept(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	w := writerFor(t, dir, GitIdentity{})
	r, err := w.Commit(context.Background(), "#123 fix\n\n# not a comment", true)
	if err != nil {
		t.Fatal(err)
	}
	if r.Summary != "#123 fix" || gitOut(t, dir, "log", "-1", "--format=%B") != "#123 fix\n\n# not a comment" {
		t.Fatalf("result %+v, message %q", r, gitOut(t, dir, "log", "-1", "--format=%B"))
	}
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("three\n"), 0o644)
	w.Stage(context.Background(), []string{"a.txt"})
	if _, err := w.Amend(context.Background(), "#124 amended"); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%s"); got != "#124 amended" {
		t.Fatalf("amended subject %q", got)
	}
}

func TestTheOrganisationsIdentityBeatsARepositorysAuthorConfig(t *testing.T) {
	dir := gitTestRepo(t)
	gitIn(t, dir, "config", "author.email", "repo-author@example.test")
	gitIn(t, dir, "config", "author.name", "Repo Author")
	gitIn(t, dir, "config", "committer.email", "repo-committer@example.test")
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	w := writerFor(t, dir, GitIdentity{Name: "Org Person", Email: "org@example.test"})
	if _, err := w.Commit(context.Background(), "m", true); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, dir, "log", "-1", "--format=%an <%ae>|%cn <%ce>"); got != "Org Person <org@example.test>|Org Person <org@example.test>" {
		t.Fatalf("log %q", got)
	}
}

func TestAHookThatLeavesAChildHoldingItsOutputDoesNotHangTheWrite(t *testing.T) {
	dir := gitTestRepo(t)
	os.WriteFile(filepath.Join(dir, ".git", "hooks", "post-commit"), []byte("#!/bin/sh\nsleep 8 &\n"), 0o755)
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("two\n"), 0o644)
	start := time.Now()
	if _, err := writerFor(t, dir, GitIdentity{}).Commit(context.Background(), "m", true); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d > 6*time.Second {
		t.Fatalf("the commit waited %v for the hook's child", d)
	}
}
