package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// remoteFixture: a bare remote with one commit on main, and a clone of it as the project root,
// in an organisation whose identity commits merges and rebases.
func remoteFixture(t *testing.T) (bare, work string, g *GitRemote) {
	t.Helper()
	localOrg(t)
	name, email := "Org", "org@e2e.invalid"
	if err := UpdateOrg("initech", OrgPatch{GitName: &name, GitEmail: &email}); err != nil {
		t.Fatal(err)
	}
	base, _ := filepath.EvalSymlinks(t.TempDir())
	bare = filepath.Join(base, "remote.git")
	seed := filepath.Join(base, "seed")
	work = filepath.Join(base, "work")
	run := func(dir string, args ...string) {
		t.Helper()
		c := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=s", "-c", "user.email=s@x"}, args...)...)
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	os.MkdirAll(seed, 0o755)
	run(base, "init", "-q", "--bare", "-b", "main", bare)
	run(base, "init", "-q", "-b", "main", seed)
	os.WriteFile(filepath.Join(seed, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	run(seed, "add", ".")
	run(seed, "commit", "-qm", "seed")
	run(seed, "remote", "add", "origin", "file://"+bare)
	run(seed, "push", "-q", "-u", "origin", "main")
	run(base, "clone", "-q", "file://"+bare, work)
	var err error
	g, err = NewGitRemote("initech", work, []string{work}, GitRemoteOptions{AllowFileProtocol: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = seed })
	return bare, work, g
}

// pushFromElsewhere commits change to a.txt in another clone and pushes it to bare.
func pushFromElsewhere(t *testing.T, bare, content string) {
	t.Helper()
	pushFileFromElsewhere(t, bare, "a.txt", content)
}

// pushFileFromElsewhere commits content as name in another clone and pushes it to bare.
func pushFileFromElsewhere(t *testing.T, bare, name, content string) {
	t.Helper()
	other := filepath.Join(t.TempDir(), "other")
	for _, args := range [][]string{
		{"clone", "-q", "file://" + bare, other},
	} {
		c := exec.Command("git", args...)
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	os.WriteFile(filepath.Join(other, name), []byte(content), 0o644)
	for _, args := range [][]string{{"add", "."}, {"commit", "-qm", "elsewhere"}, {"push", "-q"}} {
		c := exec.Command("git", append([]string{"-C", other, "-c", "user.name=o", "-c", "user.email=o@x"}, args...)...)
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v %s", args, err, out)
		}
	}
}

func commitHere(t *testing.T, work, content string) {
	t.Helper()
	os.WriteFile(filepath.Join(work, "a.txt"), []byte(content), 0o644)
	gitIn(t, work, "-c", "user.name=w", "-c", "user.email=w@x", "commit", "-qam", "here")
}

func porcelain(t *testing.T, dir string) string {
	t.Helper()
	head, _ := exec.Command("git", "-C", dir, "rev-parse", "HEAD").Output()
	status, _ := exec.Command("git", "-C", dir, "status", "--porcelain").Output()
	return string(head) + string(status)
}

func TestFetchPruneAndAheadBehind(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\ntwo\nthree\nfour\n")
	commitHere(t, work, "ONE\ntwo\nthree\n")
	r, err := g.Fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if r.Ahead != 1 || r.Behind != 1 {
		t.Fatalf("ahead %d behind %d", r.Ahead, r.Behind)
	}
}

// Review Focus 1: under either strategy the pull stops with the conflicts in the tree, a name with a
// space listed whole.
func TestPullConflictIsLeftInPlace(t *testing.T) {
	for _, strategy := range []string{"rebase", "merge"} {
		t.Run(strategy, func(t *testing.T) {
			bare, work, g := remoteFixture(t)
			UpdateOrg("initech", OrgPatch{PullStrategy: &strategy})
			pushFileFromElsewhere(t, bare, "a b.txt", "theirs\n")
			pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
			os.WriteFile(filepath.Join(work, "a b.txt"), []byte("mine\n"), 0o644)
			gitIn(t, work, "add", "a b.txt")
			commitHere(t, work, "one\nMINE\nthree\n")
			r, err := g.Pull(context.Background())
			if err == nil || err.Error() != "Pull stopped on conflicts in a b.txt, a.txt; resolve them below" {
				t.Fatalf("err = %v", err)
			}
			if !slices.Equal(r.Conflicts, []string{"a b.txt", "a.txt"}) {
				t.Fatalf("conflicts = %q", r.Conflicts)
			}
			if u, _ := exec.Command("git", "-C", work, "ls-files", "-u").Output(); len(u) == 0 {
				t.Fatal("the conflicts were put back")
			}
			if op, _ := ReadGitOp(context.Background(), &GitRunner{Root: work}); op.Kind != strategy {
				t.Fatalf("in progress = %+v", op)
			}
		})
	}
}

func TestPullMergeAndFastForwardOnly(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\ntwo\nthree\nfour\n")
	commitHere(t, work, "ZERO\none\ntwo\nthree\n")
	s := "ff-only"
	UpdateOrg("initech", OrgPatch{PullStrategy: &s})
	if _, err := g.Pull(context.Background()); err == nil {
		t.Fatal("ff-only pulled a diverged branch")
	}
	s = "merge"
	UpdateOrg("initech", OrgPatch{PullStrategy: &s})
	if _, err := g.Pull(context.Background()); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(work, "a.txt"))
	if string(b) != "ZERO\none\ntwo\nthree\nfour\n" {
		t.Fatalf("merged = %q", b)
	}
}

func TestPushRejectedNonFastForwardMapsItsText(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\ntwo\nthree\nfour\n")
	commitHere(t, work, "ZERO\none\ntwo\nthree\n")
	_, err := g.Push(context.Background())
	if err == nil || !strings.Contains(err.Error(), "Rejected: the remote has newer commits. Pull or Sync first") {
		t.Fatalf("err = %v", err)
	}
}

func TestPushWithoutUpstreamAsksForPublish(t *testing.T) {
	_, work, g := remoteFixture(t)
	gitIn(t, work, "checkout", "-q", "-b", "feature")
	_, err := g.Push(context.Background())
	if err == nil || !strings.Contains(err.Error(), "feature has no upstream — Publish it first") {
		t.Fatalf("err = %v", err)
	}
}

func TestPublishSetsUpstream(t *testing.T) {
	_, work, g := remoteFixture(t)
	gitIn(t, work, "checkout", "-q", "-b", "feature")
	if _, err := g.Publish(context.Background()); err != nil {
		t.Fatal(err)
	}
	out, _ := exec.Command("git", "-C", work, "rev-parse", "--abbrev-ref", "@{u}").Output()
	if strings.TrimSpace(string(out)) != "origin/feature" {
		t.Fatalf("upstream = %q", out)
	}
}

func TestSyncPullsThenPushes(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\ntwo\nthree\nfour\n")
	commitHere(t, work, "ZERO\none\ntwo\nthree\n")
	r, err := g.Sync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if r.Ahead != 0 || r.Behind != 0 {
		t.Fatalf("after sync ahead %d behind %d", r.Ahead, r.Behind)
	}
}

func TestSyncStopsAtTheFirstFailure(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	commitHere(t, work, "one\nMINE\nthree\n")
	var pushed bool
	g.trace = func(args []string) {
		for _, a := range args {
			if a == "push" {
				pushed = true
			}
		}
	}
	if _, err := g.Sync(context.Background()); err == nil {
		t.Fatal("sync with a conflict succeeded")
	}
	if pushed {
		t.Fatal("sync pushed after its pull failed")
	}
}

func TestCloneRefusesAnExistingDestination(t *testing.T) {
	bare, _, _ := remoteFixture(t)
	dest := t.TempDir()
	_, err := GitClone(context.Background(), "initech", "file://"+bare, dest, GitRemoteOptions{AllowFileProtocol: true})
	if err == nil || !strings.Contains(err.Error(), "the destination already exists: "+dest) {
		t.Fatalf("err = %v", err)
	}
}

func TestCloneAndItsCancelledPartialFolder(t *testing.T) {
	bare, _, _ := remoteFixture(t)
	dest := filepath.Join(t.TempDir(), "copy")
	if _, err := GitClone(context.Background(), "initech", "file://"+bare, dest, GitRemoteOptions{AllowFileProtocol: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dest, "a.txt")); err != nil {
		t.Fatal("clone has no a.txt")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	gone := filepath.Join(t.TempDir(), "cancelled")
	if _, err := GitClone(ctx, "initech", "file://"+bare, gone, GitRemoteOptions{AllowFileProtocol: true}); err == nil {
		t.Fatal("a cancelled clone succeeded")
	}
	if _, err := os.Stat(gone); err == nil {
		t.Fatal("the partial folder was left behind")
	}
}

func TestNoAccountRefusesBeforeGitRuns(t *testing.T) {
	_, work, g := remoteFixture(t)
	gitIn(t, work, "remote", "set-url", "origin", "https://git.example.invalid/o/r.git")
	var ran bool
	g.trace = func([]string) { ran = true }
	_, err := g.Fetch(context.Background())
	if err == nil || !strings.Contains(err.Error(), "No git account for git.example.invalid in initech — add one in Settings → Organisation → Git") {
		t.Fatalf("err = %v", err)
	}
	if ran {
		t.Fatal("git ran")
	}
}

func TestFileProtocolOnlyWhenAllowed(t *testing.T) {
	_, work, _ := remoteFixture(t)
	g, _ := NewGitRemote("initech", work, []string{work}, GitRemoteOptions{})
	if _, err := g.Fetch(context.Background()); err == nil || !strings.Contains(err.Error(), "protocol not allowed: file") {
		t.Fatalf("err = %v", err)
	}
}

func TestNeverForce(t *testing.T) {
	bare, work, g := remoteFixture(t)
	var all []string
	g.trace = func(args []string) { all = append(all, args...) }
	commitHere(t, work, "x\n")
	g.Push(context.Background())
	pushFromElsewhere(t, bare, "y\n")
	g.Sync(context.Background())
	g.Publish(context.Background())
	for _, a := range all {
		if strings.Contains(a, "force") || strings.HasPrefix(a, "+") {
			t.Fatalf("forced: %v", all)
		}
	}
}

func TestScrubRemoteText(t *testing.T) {
	in := "fatal: unable to access 'https://dev:s3cret@github.com/o/r/': x\nremote: https://tok123@host/r\npassword=abc\n"
	out := scrubRemoteText(in)
	for _, leak := range []string{"s3cret", "tok123", "abc"} {
		if strings.Contains(out, leak) {
			t.Fatalf("%q leaked: %s", leak, out)
		}
	}
}

func TestRepositoryUploadpackIsRefused(t *testing.T) {
	_, work, g := remoteFixture(t)
	gitIn(t, work, "config", "remote.origin.uploadpack", "/bin/sh -c evil")
	if _, err := g.Fetch(context.Background()); err == nil || !strings.Contains(err.Error(), "uploadpack") {
		t.Fatalf("err = %v", err)
	}
}

func TestCloneIntoRecordsTheOperatorsFolderAndNamesTheCloneAfterTheRepository(t *testing.T) {
	bare, _, _ := remoteFixture(t)
	folder := t.TempDir()
	dest, _, err := CloneInto(context.Background(), "initech", "file://"+bare, folder, true, GitRemoteOptions{AllowFileProtocol: true})
	if err != nil {
		t.Fatal(err)
	}
	if dest != filepath.Join(folder, "remote") {
		t.Fatalf("dest = %s", dest)
	}
	o, _ := LoadOrgFor("initech")
	if o.LastCloneFolder != folder {
		t.Fatalf("last = %q", o.LastCloneFolder)
	}
}

func TestTheAgentClonesOnlyIntoTheLastFolder(t *testing.T) {
	bare, _, _ := remoteFixture(t)
	if _, _, err := CloneInto(context.Background(), "initech", "file://"+bare, "", false, GitRemoteOptions{AllowFileProtocol: true}); err == nil ||
		!strings.Contains(err.Error(), "choose a folder to clone into") {
		t.Fatalf("no last folder: %v", err)
	}
	last := t.TempDir()
	CloneInto(context.Background(), "initech", "file://"+bare, last, true, GitRemoteOptions{AllowFileProtocol: true})
	elsewhere := t.TempDir()
	if _, _, err := CloneInto(context.Background(), "initech", "file://"+bare, elsewhere, false, GitRemoteOptions{AllowFileProtocol: true}); err == nil ||
		!strings.Contains(err.Error(), "the agent clones only into "+last) {
		t.Fatalf("elsewhere: %v", err)
	}
	os.RemoveAll(filepath.Join(last, "remote"))
	dest, _, err := CloneInto(context.Background(), "initech", "file://"+bare, "", false, GitRemoteOptions{AllowFileProtocol: true})
	if err != nil || dest != filepath.Join(last, "remote") {
		t.Fatalf("dest %s err %v", dest, err)
	}
}

func TestRepositoryName(t *testing.T) {
	for raw, want := range map[string]string{
		"git@github.com:o/api.git": "api", "https://github.com/o/portal": "portal", "https://h/o/web/": "web", "file:///x/remote.git": "remote",
	} {
		if got := repositoryName(raw); got != want {
			t.Errorf("%s = %q", raw, got)
		}
	}
}

// Review I2: a merge the operator is resolving is theirs — Pull refuses and leaves it as it is,
// rather than aborting it as if Pull had started it.
func TestPullLeavesTheOperatorsMergeAlone(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	commitHere(t, work, "one\nMINE\nthree\n")
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = work
		cmd.CombinedOutput()
	}
	run("fetch", "origin")
	run("merge", "--no-edit", "@{u}") // conflicts: the operator is mid-merge
	if _, err := os.Stat(filepath.Join(work, ".git", "MERGE_HEAD")); err != nil {
		t.Fatal("fixture: no merge in progress")
	}
	before := porcelain(t, work)
	_, err := g.Pull(context.Background())
	if err == nil || !strings.Contains(err.Error(), "A merge is in progress") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(work, ".git", "MERGE_HEAD")); err != nil {
		t.Fatal("the operator's merge was aborted")
	}
	if after := porcelain(t, work); after != before {
		t.Fatalf("tree changed:\n%s\n%s", before, after)
	}
}

// Review I4: a pull cancelled part-way (an org switch stopping wakil-git) undoes the rebase it
// started, so the tree is back as it was rather than left mid-rebase.
func TestACancelledPullUndoesItsRebase(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\ntwo\nthree\nfour\n")
	commitHere(t, work, "ZERO\none\ntwo\nthree\n")
	// The rebase's checkout runs post-checkout: hold the rebase there until it is cancelled.
	hook := filepath.Join(work, ".git", "hooks", "post-checkout")
	os.WriteFile(hook, []byte("#!/bin/sh\nsleep 30\n"), 0o755)
	before := porcelain(t, work)
	head := func() string {
		out, _ := exec.Command("git", "-C", work, "rev-parse", "HEAD").Output()
		return strings.TrimSpace(string(out))
	}
	was := head()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		for i := 0; i < 200; i++ {
			if _, err := os.Stat(filepath.Join(work, ".git", "rebase-merge")); err == nil {
				break
			}
			time.Sleep(25 * time.Millisecond)
		}
		time.Sleep(100 * time.Millisecond)
		cancel()
	}()
	if _, err := g.Pull(ctx); err == nil {
		t.Fatal("a cancelled pull reported success")
	}
	if _, err := os.Stat(filepath.Join(work, ".git", "rebase-merge")); err == nil {
		t.Fatal("left mid-rebase")
	}
	if head() != was {
		t.Fatalf("HEAD moved: %s → %s", was, head())
	}
	if after := porcelain(t, work); after != before {
		t.Fatalf("tree changed:\n%s\n%s", before, after)
	}
}

// Walk 3a-iii: Pull sets uncommitted changes aside and puts them back (--autostash), under every
// strategy, so work in progress elsewhere in the tree does not stop it.
func TestPullOverUncommittedChanges(t *testing.T) {
	for _, strategy := range []string{"rebase", "merge"} {
		t.Run(strategy, func(t *testing.T) {
			bare, work, g := remoteFixture(t)
			s := strategy
			UpdateOrg("initech", OrgPatch{PullStrategy: &s})
			pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
			os.WriteFile(filepath.Join(work, "b.txt"), []byte("mine\n"), 0o644)
			gitIn(t, work, "add", "b.txt")
			if _, err := g.Pull(context.Background()); err != nil {
				t.Fatal(err)
			}
			if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\nTHEIRS\nthree\n" {
				t.Fatalf("a.txt = %q", b)
			}
			if st, _ := exec.Command("git", "-C", work, "status", "--porcelain").Output(); string(st) != "A  b.txt\n" {
				t.Fatalf("status = %q", st)
			}
		})
	}
}

// When the set-aside changes clash with what came in, git keeps them in its stash; Pull says so.
func TestPullWhoseChangesClashKeepsThemInTheStash(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	os.WriteFile(filepath.Join(work, "a.txt"), []byte("one\nMINE\nthree\n"), 0o644)
	_, err := g.Pull(context.Background())
	if err == nil || !strings.Contains(err.Error(), "kept in git stash") {
		t.Fatalf("err = %v", err)
	}
	if list, _ := exec.Command("git", "-C", work, "stash", "list").Output(); strings.Count(string(list), "\n") != 1 {
		t.Fatalf("stash = %q", list)
	}
}

// A conflicting pull holds the set-aside changes, and Abort hands them back with the tree from before.
func TestAbortAfterAConflictingPullGivesTheUncommittedChangesBack(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	commitHere(t, work, "one\nMINE\nthree\n")
	os.WriteFile(filepath.Join(work, "b.txt"), []byte("wip\n"), 0o644)
	gitIn(t, work, "add", "b.txt")
	before := porcelain(t, work)
	if _, err := g.Pull(context.Background()); err == nil || !strings.Contains(err.Error(), "a.txt") {
		t.Fatalf("err = %v", err)
	}
	w, err := NewGitWriter(work, []string{work}, GitIdentity{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Abort(context.Background()); err != nil {
		t.Fatal(err)
	}
	if after := porcelain(t, work); after != before {
		t.Fatalf("tree changed:\n%s\n%s", before, after)
	}
}

// Fast-forward only on diverged branches says what to do, not git's own text.
func TestFastForwardOnlyRefusalIsPlain(t *testing.T) {
	bare, work, g := remoteFixture(t)
	s := "ff-only"
	UpdateOrg("initech", OrgPatch{PullStrategy: &s})
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	commitHere(t, work, "ZERO\none\ntwo\nthree\n")
	_, err := g.Pull(context.Background())
	if err == nil || err.Error() != "Both sides have new commits, so Fast-forward only cannot pull. Choose Rebase or Merge in Settings → Organisation → Git" {
		t.Fatalf("err = %v", err)
	}
}

// Final review I1: mid-rebase HEAD is detached, and Pull (so Sync) names the rebase, not the detached
// HEAD it would otherwise trip on first.
func TestPullMidRebaseNamesTheRebase(t *testing.T) {
	bare, work, g := remoteFixture(t)
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	commitHere(t, work, "one\nMINE\nthree\n")
	gitIn(t, work, "fetch", "-q", "origin")
	c := exec.Command("git", "-C", work, "-c", "core.editor=true", "rebase", "@{u}")
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	c.CombinedOutput() // conflicts: the operator is mid-rebase
	want := "A rebase is in progress in " + work + "; finish or abort it first"
	for name, run := range map[string]func(context.Context) (GitRemoteResult, error){"pull": g.Pull, "sync": g.Sync} {
		if _, err := run(context.Background()); err == nil || err.Error() != want {
			t.Fatalf("%s: err = %v", name, err)
		}
	}
}

// Final review I3: an autostash that comes back with conflicts leaves them in the tree, and a copy in
// git stash; popping that would apply them twice, so the note says to resolve them, not to pop.
func TestPullRebaseWhoseAutostashClashesSaysResolve(t *testing.T) {
	bare, work, g := remoteFixture(t)
	s := "rebase"
	UpdateOrg("initech", OrgPatch{PullStrategy: &s})
	pushFromElsewhere(t, bare, "one\nTHEIRS\nthree\n")
	os.WriteFile(filepath.Join(work, "a.txt"), []byte("one\nMINE\nthree\n"), 0o644)
	r, err := g.Pull(context.Background())
	if err == nil || err.Error() != "Your uncommitted changes clash in a.txt; resolve them below — a copy is kept in git stash" {
		t.Fatalf("err = %v", err)
	}
	if !slices.Equal(r.Conflicts, []string{"a.txt"}) {
		t.Fatalf("conflicts = %q", r.Conflicts)
	}
}
