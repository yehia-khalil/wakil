package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"testing"
)

// tryGit runs git in dir and ignores its exit: a merge, rebase or cherry-pick that stops on a
// conflict exits non-zero, and that stop is the fixture.
func tryGit(dir string, args ...string) {
	c := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=w", "-c", "user.email=w@x"}, args...)...)
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_EDITOR=true")
	c.CombinedOutput()
}

// commitA commits text as a.txt on the current branch.
func commitA(t *testing.T, work string, git func(args ...string) string, text, msg string) {
	t.Helper()
	writeIn(t, work, "a.txt", text)
	git("commit", "-qam", msg)
}

func readOp(t *testing.T, w *GitWriter) GitOp {
	t.Helper()
	op, err := ReadGitOp(context.Background(), w.runner())
	if err != nil {
		t.Fatal(err)
	}
	return op
}

var fullID = regexp.MustCompile(`^[0-9a-f]{40}$`)

func TestReadGitOpNamesAMerge(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "feature/search")
	commitA(t, work, git, "one\nSEARCH\nthree\n", "Seed search")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	tryGit(work, "merge", "--no-edit", "feature/search")
	op := readOp(t, w)
	if op.Kind != "merge" || op.Incoming != "feature/search" || op.Onto != "" || op.Steps != 0 {
		t.Fatalf("op = %+v", op)
	}
	if op.Message == "" || op.Message[0] == '#' || !regexp.MustCompile(`^Merge branch 'feature/search'`).MatchString(op.Message) {
		t.Fatalf("message = %q", op.Message)
	}
	if regexp.MustCompile(`(?m)^#`).MatchString(op.Message) {
		t.Fatalf("comment lines kept: %q", op.Message)
	}
}

func TestReadGitOpCountsARebase(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "topic")
	writeIn(t, work, "b.txt", "b\n")
	git("add", "b.txt")
	git("commit", "-qm", "first")
	commitA(t, work, git, "one\nTOPIC\nthree\n", "Seed search")
	second := git("rev-parse", "HEAD")
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "third")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	git("switch", "-q", "topic")
	tryGit(work, "-c", "core.editor=true", "-c", "sequence.editor=true", "rebase", "main")
	op := readOp(t, w)
	if op.Kind != "rebase" || op.Onto != "main" || op.Step != 2 || op.Steps != 3 {
		t.Fatalf("op = %+v", op)
	}
	if !fullID.MatchString(op.Head) || op.Head != second || op.Subject != "Seed search" {
		t.Fatalf("head = %q subject %q, want %s", op.Head, op.Subject, second)
	}
}

func TestReadGitOpSeesCherryPickAndRevert(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "other")
	commitA(t, work, git, "one\nOTHER\nthree\n", "other")
	pick := git("rev-parse", "HEAD")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	tryGit(work, "cherry-pick", "other")
	op := readOp(t, w)
	if op.Kind != "cherry-pick" || op.Head != pick || op.Subject != "other" || op.Message == "" {
		t.Fatalf("cherry-pick op = %+v", op)
	}
	git("cherry-pick", "--abort")

	commitA(t, work, git, "one\nAGAIN\nthree\n", "again")
	tryGit(work, "revert", "--no-edit", "HEAD~1")
	op = readOp(t, w)
	if op.Kind != "revert" || !fullID.MatchString(op.Head) || op.Subject != "main" {
		t.Fatalf("revert op = %+v", op)
	}
}

func TestReadGitOpIsEmptyOnACleanTree(t *testing.T) {
	_, w, _ := branchFixture(t)
	if op := readOp(t, w); op != (GitOp{}) {
		t.Fatalf("op = %+v", op)
	}
	if err := (GitOp{}).InProgressError("/r"); err != nil {
		t.Fatalf("err = %v", err)
	}
}

func TestEveryWriteRefusesMidCherryPick(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "other")
	commitA(t, work, git, "one\nOTHER\nthree\n", "other")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	tryGit(work, "cherry-pick", "other")
	g, err := NewGitRemote("initech", work, []string{work}, GitRemoteOptions{AllowFileProtocol: true})
	if err != nil {
		t.Fatal(err)
	}
	want := "A cherry-pick is in progress in " + w.Root + "; finish or abort it first"
	ctx := context.Background()
	_, switchErr := w.Switch(ctx, "other", SwitchOptions{})
	stashErr := w.Stash(ctx, "", "default")
	_, _, applyErr := w.StashApply(ctx, 0, "0000000000000000000000000000000000000000", false)
	_, pullErr := g.Pull(ctx)
	for name, err := range map[string]error{"Switch": switchErr, "Stash": stashErr, "StashApply": applyErr, "Pull": pullErr} {
		if err == nil || err.Error() != want {
			t.Errorf("%s: err = %v, want %q", name, err, want)
		}
	}
}
