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

// branchFixture is remoteFixture's clone, with a writer for it and a helper that runs git there.
func branchFixture(t *testing.T) (work string, w *GitWriter, git func(args ...string) string) {
	t.Helper()
	_, work, _ = remoteFixture(t)
	var err error
	w, err = NewGitWriter(work, []string{work}, GitIdentity{Name: "w", Email: "w@x"})
	if err != nil {
		t.Fatal(err)
	}
	git = func(args ...string) string {
		t.Helper()
		c := exec.Command("git", append([]string{"-C", work, "-c", "user.name=w", "-c", "user.email=w@x"}, args...)...)
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		out, err := c.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	return work, w, git
}

func writeIn(t *testing.T, dir, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func current(t *testing.T, w *GitWriter) string {
	t.Helper()
	b, err := ReadBranches(context.Background(), w.runner())
	if err != nil {
		t.Fatal(err)
	}
	return b.Current
}

func TestReadBranchesOrdersLocalAndHidesTrackedRemotes(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "older")
	git("switch", "-q", "main")
	time.Sleep(1100 * time.Millisecond) // committer dates are to the second
	git("switch", "-q", "-c", "newer")
	writeIn(t, work, "n.txt", "n\n")
	git("add", "n.txt")
	git("commit", "-qm", "newer")
	git("push", "-q", "origin", "newer:refs/heads/theirs")
	git("fetch", "-q", "origin")
	b, err := ReadBranches(context.Background(), w.runner())
	if err != nil {
		t.Fatal(err)
	}
	if b.Current != "newer" || len(b.Local) != 3 || b.Local[0].Name != "newer" {
		t.Fatalf("local = %+v current %q", b.Local, b.Current)
	}
	for _, l := range b.Local {
		if l.Name == "main" && (l.Upstream != "origin/main" || l.Unmerged != 0) {
			t.Fatalf("main = %+v", l)
		}
		if l.Current != (l.Name == "newer") {
			t.Fatalf("current mark on %+v", l)
		}
	}
	if len(b.Remote) != 1 || b.Remote[0] != "origin/theirs" {
		t.Fatalf("remote = %v (origin/main is tracked by main, origin/HEAD is not a branch)", b.Remote)
	}
}

func TestSwitchCarriesChangesItCan(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "other")
	writeIn(t, work, "a.txt", "one\nTWO\nthree\n")
	r, err := w.Switch(context.Background(), "other", SwitchOptions{})
	if err != nil || !r.Switched {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\nTWO\nthree\n" || current(t, w) != "other" {
		t.Fatalf("not carried: %q on %s", b, current(t, w))
	}
}

// blockedFixture: branch other changes a.txt and adds u.txt; main has a.txt edited and u.txt untracked.
func blockedFixture(t *testing.T) (string, *GitWriter, func(...string) string) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "other")
	writeIn(t, work, "a.txt", "one\nOTHER\nthree\n")
	writeIn(t, work, "u.txt", "theirs\n")
	git("add", ".")
	git("commit", "-qm", "other")
	git("switch", "-q", "main")
	writeIn(t, work, "a.txt", "one\nMINE\nthree\n")
	writeIn(t, work, "u.txt", "mine\n")
	return work, w, git
}

// Review Focus 1: an untracked file the target also has is listed, not skipped.
func TestSwitchRefusesAndListsBlockedPaths(t *testing.T) {
	_, w, _ := blockedFixture(t)
	r, err := w.Switch(context.Background(), "other", SwitchOptions{})
	if err != nil || r.Switched {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if strings.Join(r.Blocked, ",") != "a.txt,u.txt" || current(t, w) != "main" {
		t.Fatalf("blocked = %v on %s", r.Blocked, current(t, w))
	}
}

func TestSwitchStashThenSwitch(t *testing.T) {
	work, w, git := blockedFixture(t)
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "stash"})
	if err != nil || !r.Switched || r.Stash == "" {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if git("rev-parse", "stash@{0}") != r.Stash || current(t, w) != "other" {
		t.Fatalf("stash %s vs %s on %s", git("rev-parse", "stash@{0}"), r.Stash, current(t, w))
	}
	if b, _ := os.ReadFile(filepath.Join(work, "u.txt")); string(b) != "theirs\n" {
		t.Fatalf("u.txt = %q", b)
	}
}

func TestSwitchBringAlong(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "other")
	writeIn(t, work, "a.txt", "one\nTWO\nthree\n")
	writeIn(t, work, "new.txt", "new\n")
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "bring"})
	if err != nil || !r.Switched || r.Note != "" {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "new.txt")); string(b) != "new\n" || git("stash", "list") != "" {
		t.Fatalf("not brought: %q, stashes %q", b, git("stash", "list"))
	}
}

// Review Focus 3: a clash leaves the tree clean on the new branch and the stash in place.
func TestBringAlongClashLeavesCleanTreeAndStash(t *testing.T) {
	_, w, git := blockedFixture(t)
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "bring"})
	if err != nil || !r.Switched {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if r.Note != "Switched to other; your changes clash with it and are kept in git stash" {
		t.Fatalf("note = %q", r.Note)
	}
	if s := git("status", "--porcelain"); s != "" {
		t.Fatalf("tree not clean:\n%s", s)
	}
	if n := len(strings.Split(git("stash", "list"), "\n")); n != 1 {
		t.Fatalf("stashes = %d", n)
	}
}

func TestCreateExistingNameSwitches(t *testing.T) {
	_, w, git := branchFixture(t)
	git("branch", "fix-login")
	r, err := w.Switch(context.Background(), "fix login", SwitchOptions{Create: true})
	if err != nil || !r.Switched || current(t, w) != "fix-login" {
		t.Fatalf("r = %+v err %v on %s", r, err, current(t, w))
	}
}

func TestCreateFromBaseAndTrackRemote(t *testing.T) {
	work, w, git := branchFixture(t)
	base := git("rev-parse", "HEAD")
	writeIn(t, work, "b.txt", "b\n")
	git("add", "b.txt")
	git("commit", "-qm", "ahead")
	if _, err := w.Switch(context.Background(), "from-base", SwitchOptions{Create: true, From: base}); err != nil {
		t.Fatal(err)
	}
	if git("rev-parse", "HEAD") != base {
		t.Fatal("not created from the base")
	}
	git("push", "-q", "origin", "main:refs/heads/theirs")
	git("fetch", "-q", "origin")
	if _, err := w.Switch(context.Background(), "theirs", SwitchOptions{Create: true, Track: "origin/theirs"}); err != nil {
		t.Fatal(err)
	}
	if git("rev-parse", "--abbrev-ref", "theirs@{upstream}") != "origin/theirs" {
		t.Fatal("not tracking")
	}
}

func TestNamesNormaliseAndRefuse(t *testing.T) {
	if NormaliseBranchName("  fix  the login ") != "fix-the-login" {
		t.Fatalf("got %q", NormaliseBranchName("  fix  the login "))
	}
	_, w, _ := branchFixture(t)
	_, err := w.Switch(context.Background(), "a..b", SwitchOptions{Create: true})
	if err == nil || !strings.Contains(err.Error(), "not a valid branch name") {
		t.Fatalf("err = %v", err)
	}
}

// Review Focus 4.
func TestRenameRefusesExistingNameAndDetached(t *testing.T) {
	_, w, git := branchFixture(t)
	git("branch", "taken")
	if err := w.RenameBranch(context.Background(), "taken"); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("err = %v", err)
	}
	if err := w.RenameBranch(context.Background(), "renamed"); err != nil || current(t, w) != "renamed" {
		t.Fatalf("err = %v on %s", err, current(t, w))
	}
	git("switch", "-q", "--detach")
	if err := w.RenameBranch(context.Background(), "x"); err == nil || err.Error() != "HEAD is detached: there is no branch to rename" {
		t.Fatalf("err = %v", err)
	}
	b, _ := ReadBranches(context.Background(), w.runner())
	if b.Current != "" || b.Detached == "" {
		t.Fatalf("detached read = %+v", b)
	}
}

func TestDeleteUnmergedNeedsForce(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "side")
	writeIn(t, work, "s.txt", "s\n")
	git("add", "s.txt")
	git("commit", "-qm", "s1")
	git("switch", "-q", "main")
	err := w.DeleteBranch(context.Background(), "side", false)
	if err == nil || err.Error() != "side has 1 commit not on main; deleting it loses them" {
		t.Fatalf("err = %v", err)
	}
	if err := w.DeleteBranch(context.Background(), "side", true); err != nil {
		t.Fatal(err)
	}
}

// Review Focus 5.
func TestDeleteBranchInAnotherWorktreeRefusedWhole(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "elsewhere")
	git("worktree", "add", "-q", filepath.Join(filepath.Dir(work), "wt"), "elsewhere")
	err := w.DeleteBranch(context.Background(), "elsewhere", true)
	if err == nil || !strings.Contains(err.Error(), "used by worktree") {
		t.Fatalf("err = %v", err)
	}
}

func TestSwitchRefusesMidMerge(t *testing.T) {
	_, w, git := branchFixture(t)
	git("branch", "other")
	gitDir := git("rev-parse", "--absolute-git-dir")
	writeIn(t, gitDir, "MERGE_HEAD", git("rev-parse", "HEAD")+"\n")
	_, err := w.Switch(context.Background(), "other", SwitchOptions{})
	if err == nil || !strings.HasPrefix(err.Error(), "A merge is in progress in ") || !strings.HasSuffix(err.Error(), "; finish or abort it first") {
		t.Fatalf("err = %v", err)
	}
}

func TestCancelBetweenStashAndPopSaysWhere(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "other")
	writeIn(t, work, "a.txt", "one\nTWO\nthree\n")
	gitDir := git("rev-parse", "--absolute-git-dir")
	os.WriteFile(filepath.Join(gitDir, "hooks", "post-checkout"), []byte("#!/bin/sh\nsleep 1\n"), 0o755)
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	r, err := w.Switch(ctx, "other", SwitchOptions{Carry: "bring"})
	if err != nil || !r.Switched || r.Note != "Your changes are in git stash (stash@{0})" {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if current(t, w) != "other" || git("stash", "list") == "" {
		t.Fatal("the switch was cut short or the stash is gone")
	}
}

// Review C2: a "branch" that is a flag (-Cfeat force-resets feat) is refused, and so are from and
// track; a plain switch names a branch that exists.
func TestSwitchRefusesAFlagForABranch(t *testing.T) {
	_, w, git := branchFixture(t)
	git("branch", "feat")
	feat := git("rev-parse", "feat")
	ctx := context.Background()
	for _, o := range []struct {
		branch string
		opts   SwitchOptions
	}{
		{"-Cfeat", SwitchOptions{}},
		{"--orphan=x", SwitchOptions{}},
		{"--detach", SwitchOptions{}},
		{"ok", SwitchOptions{Create: true, From: "-x"}},
		{"ok", SwitchOptions{Create: true, Track: "--no-track"}},
	} {
		if _, err := w.Switch(ctx, o.branch, o.opts); err == nil {
			t.Errorf("%q %+v: want refusal", o.branch, o.opts)
		}
	}
	if git("rev-parse", "feat") != feat || current(t, w) != "main" {
		t.Fatal("a refused switch moved something")
	}
	if _, err := w.Switch(ctx, "nope", SwitchOptions{}); err == nil || err.Error() != "There is no branch nope" {
		t.Fatalf("err = %v", err)
	}
}

// Review I1: Bring Them Along pops the stash it made, even when another lands on top before the pop.
func TestBringAlongPopsItsOwnStash(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "other")
	writeIn(t, work, "a.txt", "one\nMINE\nthree\n")
	gitDir := git("rev-parse", "--absolute-git-dir")
	// The switch's post-checkout hook stands in for another worktree stashing between push and pop.
	os.WriteFile(filepath.Join(gitDir, "hooks", "post-checkout"), []byte("#!/bin/sh\n"+
		"git -c user.name=t -c user.email=t@x stash push -q -m elsewhere --allow-empty 2>/dev/null || "+
		"(echo e > elsewhere.txt && git stash push -q -u -m elsewhere)\n"), 0o755)
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "bring"})
	if err != nil || !r.Switched {
		t.Fatalf("r = %+v err %v", r, err)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\nMINE\nthree\n" {
		t.Fatalf("a.txt = %q", b)
	}
	if l := git("stash", "list"); !strings.Contains(l, "elsewhere") || strings.Contains(l, "wakil: switch") {
		t.Fatalf("stashes = %q", l)
	}
}

// Review I4: a post-checkout hook that fails after the checkout happened — the switch is reported
// as done, and the stash is not popped back onto the new branch.
func TestAFailingPostCheckoutHookStillSwitched(t *testing.T) {
	work, w, git := branchFixture(t)
	git("branch", "other")
	writeIn(t, work, "a.txt", "one\nMINE\nthree\n")
	gitDir := git("rev-parse", "--absolute-git-dir")
	os.WriteFile(filepath.Join(gitDir, "hooks", "post-checkout"), []byte("#!/bin/sh\necho hook failed >&2\nexit 1\n"), 0o755)
	r, err := w.Switch(context.Background(), "other", SwitchOptions{Carry: "stash"})
	if err != nil || !r.Switched || current(t, w) != "other" {
		t.Fatalf("r = %+v err %v on %s", r, err, current(t, w))
	}
	if !strings.Contains(r.Note, "hook failed") || git("stash", "list") == "" {
		t.Fatalf("note %q, stashes %q", r.Note, git("stash", "list"))
	}
}
