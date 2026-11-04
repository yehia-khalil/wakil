package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// worktreeFixture is a repo (main at a.txt = "one") with a second branch, and a folder under which
// checkouts are made.
func worktreeFixture(t *testing.T) (repo, home string, w *GitWriter) {
	t.Helper()
	repo = gitTestRepo(t)
	gitIn(t, repo, "branch", "feature")
	home, _ = filepath.EvalSymlinks(t.TempDir())
	return repo, home, writerFor(t, repo, GitIdentity{})
}

func TestWorktreeAddMakesANewBranchFromAStartAndListsIt(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "ws", "core")
	r, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "fix-otp", From: "main", Create: true})
	if err != nil {
		t.Fatal(err)
	}
	if r.Path != path || r.Branch != "fix-otp" || r.Head == "" {
		t.Fatalf("result %+v", r)
	}
	if got := gitOut(t, path, "rev-parse", "--abbrev-ref", "HEAD"); got != "fix-otp" {
		t.Fatalf("branch %q", got)
	}
	list, err := w.WorktreeList(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || !list[0].Main || list[0].Path != repo || list[1].Path != path || list[1].Branch != "fix-otp" {
		t.Fatalf("list %+v", list)
	}
}

func TestWorktreeAddChecksOutAnExistingBranch(t *testing.T) {
	_, home, w := worktreeFixture(t)
	path := filepath.Join(home, "core")
	if _, err := w.WorktreeAdd(context.Background(), WorktreeAddOptions{Path: path, Branch: "feature", Create: true}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, path, "rev-parse", "--abbrev-ref", "HEAD"); got != "feature" {
		t.Fatalf("branch %q", got)
	}
}

func TestWorktreeAddOfABranchCheckedOutElsewhereIsRefusedNamingWhere(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	_, err := w.WorktreeAdd(context.Background(), WorktreeAddOptions{Path: filepath.Join(home, "x"), Branch: "main"})
	if err == nil {
		t.Fatal("want refusal: main is checked out in the repo's own folder")
	}
	var held *BranchHeldError
	if !asBranchHeld(err, &held) || held.Branch != "main" || held.Path != repo {
		t.Fatalf("err %v (%T)", err, err)
	}
}

func TestWorktreeAddFromAMissingBaseFallsBackToHEADAndSaysSo(t *testing.T) {
	_, home, w := worktreeFixture(t)
	r, err := w.WorktreeAdd(context.Background(), WorktreeAddOptions{Path: filepath.Join(home, "x"), Branch: "b", From: "origin/staging", Create: true, FromIsBase: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(r.Note, "origin/staging") {
		t.Fatalf("note %q", r.Note)
	}
}

func TestWorktreeAddFailureLeavesNothingAndKeepsGitsWords(t *testing.T) {
	_, home, w := worktreeFixture(t)
	path := filepath.Join(home, "x")
	_, err := w.WorktreeAdd(context.Background(), WorktreeAddOptions{Path: path, Branch: "bad..name", Create: true})
	if err == nil || !strings.Contains(err.Error(), "bad..name") {
		t.Fatalf("err %v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatal("a failed add left its folder")
	}
}

func TestWorktreeRemoveRefusesADirtyCheckoutAndRemovesACleanOne(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "x")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "b", Create: true}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(path, "a.txt"), []byte("dirty\n"), 0o644)
	if err := w.WorktreeRemove(ctx, path); err == nil {
		t.Fatal("want refusal for a dirty checkout")
	}
	gitIn(t, path, "checkout", "--", "a.txt")
	if err := w.WorktreeRemove(ctx, path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("folder left")
	}
	// The branch stays (decision 11).
	gitIn(t, w.Root, "rev-parse", "--verify", "refs/heads/b")
}

func TestWorktreeRemoveRefusesTheMainFolderAndAStranger(t *testing.T) {
	repo, _, w := worktreeFixture(t)
	if err := w.WorktreeRemove(context.Background(), repo); err == nil {
		t.Fatal("want refusal for the main folder")
	}
	if err := w.WorktreeRemove(context.Background(), t.TempDir()); err == nil {
		t.Fatal("want refusal for a folder that is not a worktree of the repo")
	}
}

func TestWorktreePruneForgetsAFolderDeletedOutsideWakil(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "x")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "b", Create: true}); err != nil {
		t.Fatal(err)
	}
	os.RemoveAll(path)
	list, _ := w.WorktreeList(ctx)
	if len(list) != 2 || !list[1].Prunable {
		t.Fatalf("before prune %+v", list)
	}
	if err := w.WorktreePrune(ctx); err != nil {
		t.Fatal(err)
	}
	list, _ = w.WorktreeList(ctx)
	if len(list) != 1 {
		t.Fatalf("after prune %+v", list)
	}
	// The branch is free again: a new checkout of it is allowed.
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "b"}); err != nil {
		t.Fatal(err)
	}
}

func TestSnapshotKeepsTrackedStagedAndUntrackedChangesWithoutTouchingTheStashList(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "x")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "b", Create: true}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(path, "a.txt"), []byte("changed\n"), 0o644)
	os.WriteFile(filepath.Join(path, "staged.txt"), []byte("s\n"), 0o644)
	gitIn(t, path, "add", "staged.txt")
	os.WriteFile(filepath.Join(path, "new.txt"), []byte("n\n"), 0o644)
	cw := writerFor(t, path, GitIdentity{})
	ref := "refs/wakil/snapshots/ws/core"
	sha, err := cw.SnapshotCreate(ctx, ref)
	if err != nil || sha == "" {
		t.Fatalf("sha %q err %v", sha, err)
	}
	if got := gitOut(t, w.Root, "rev-parse", ref); got != sha {
		t.Fatalf("ref %q, sha %q", got, sha)
	}
	if got := gitOut(t, w.Root, "stash", "list"); got != "" {
		t.Fatalf("stash list touched: %q", got)
	}
	// The checkout is untouched by the snapshot itself.
	if b, _ := os.ReadFile(filepath.Join(path, "new.txt")); string(b) != "n\n" {
		t.Fatal("snapshot changed the tree")
	}
	// Removed (forced: the snapshot holds the work), then re-made and the snapshot put back.
	gitIn(t, w.Root, "worktree", "remove", "--force", path)
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "b"}); err != nil {
		t.Fatal(err)
	}
	if err := writerFor(t, path, GitIdentity{}).SnapshotApply(ctx, ref); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"a.txt": "changed\n", "staged.txt": "s\n", "new.txt": "n\n"} {
		if b, _ := os.ReadFile(filepath.Join(path, name)); string(b) != want {
			t.Errorf("%s = %q", name, b)
		}
	}
	if got := gitOut(t, path, "diff", "--cached", "--name-only"); got != "staged.txt" {
		t.Errorf("staged %q", got)
	}
}

func TestSnapshotOfACleanCheckoutIsNothing(t *testing.T) {
	_, home, w := worktreeFixture(t)
	path := filepath.Join(home, "x")
	if _, err := w.WorktreeAdd(context.Background(), WorktreeAddOptions{Path: path, Branch: "b", Create: true}); err != nil {
		t.Fatal(err)
	}
	sha, err := writerFor(t, path, GitIdentity{}).SnapshotCreate(context.Background(), "refs/wakil/snapshots/ws/core")
	if err != nil || sha != "" {
		t.Fatalf("sha %q err %v", sha, err)
	}
}

func TestSnapshotOfOnlyUntrackedFiles(t *testing.T) {
	repo, _, w := worktreeFixture(t)
	os.WriteFile(filepath.Join(repo, "only.txt"), []byte("u\n"), 0o644)
	ctx := context.Background()
	sha, err := w.SnapshotCreate(ctx, "refs/wakil/snapshots/ws/core")
	if err != nil || sha == "" {
		t.Fatalf("sha %q err %v", sha, err)
	}
	os.Remove(filepath.Join(repo, "only.txt"))
	if err := w.SnapshotApply(ctx, "refs/wakil/snapshots/ws/core"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "only.txt")); string(b) != "u\n" {
		t.Fatalf("only.txt %q", b)
	}
}

func TestSnapshotRefusesANameOutsideWakilsRefs(t *testing.T) {
	_, _, w := worktreeFixture(t)
	if _, err := w.SnapshotCreate(context.Background(), "refs/heads/main"); err == nil {
		t.Fatal("want refusal")
	}
}

func TestTakeFromMainSwitchesMainToItsBaseAndCarriesItsChanges(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	ctx := context.Background()
	gitIn(t, repo, "switch", "-q", "feature")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("mine\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "u.txt"), []byte("u\n"), 0o644)
	path := filepath.Join(home, "x")
	r, err := w.TakeFromMain(ctx, TakeFromMainOptions{Branch: "feature", Base: "main", Path: path, Ref: "refs/wakil/carry/ws/core"})
	if err != nil {
		t.Fatal(err)
	}
	if !r.Carried {
		t.Fatalf("result %+v", r)
	}
	if got := gitOut(t, repo, "rev-parse", "--abbrev-ref", "HEAD"); got != "main" {
		t.Fatalf("main's folder on %q", got)
	}
	if got := gitOut(t, repo, "status", "--porcelain"); got != "" {
		t.Fatalf("main's folder not clean: %q", got)
	}
	if got := gitOut(t, path, "rev-parse", "--abbrev-ref", "HEAD"); got != "feature" {
		t.Fatalf("checkout on %q", got)
	}
	for name, want := range map[string]string{"a.txt": "mine\n", "u.txt": "u\n"} {
		if b, _ := os.ReadFile(filepath.Join(path, name)); string(b) != want {
			t.Errorf("%s = %q", name, b)
		}
	}
}

func TestTakeFromMainRefusesWhenMainIsNotOnThatBranch(t *testing.T) {
	_, home, w := worktreeFixture(t)
	_, err := w.TakeFromMain(context.Background(), TakeFromMainOptions{Branch: "feature", Base: "main", Path: filepath.Join(home, "x"), Ref: "refs/wakil/carry/ws/core"})
	if err == nil {
		t.Fatal("want refusal: main's folder is on main, not feature")
	}
}

func TestBranchHeldIsShownWhole(t *testing.T) {
	msg, ok := IsUserError(&BranchHeldError{Branch: "main", Path: "/p/core"})
	if !ok || msg != "main is checked out in /p/core" {
		t.Fatalf("%q %v", msg, ok)
	}
}

func TestTakeFromMainWithNoBaseGoesBackToTheDefaultBranch(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	gitIn(t, repo, "switch", "-q", "feature")
	if _, err := w.TakeFromMain(context.Background(), TakeFromMainOptions{Branch: "feature", Path: filepath.Join(home, "x"), Ref: "refs/wakil/carry/ws/core"}); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, repo, "rev-parse", "--abbrev-ref", "HEAD"); got != "main" {
		t.Fatalf("on %q", got)
	}
}

func TestDetachFreesTheBranchAndKeepsTheFiles(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "x")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "feature"}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(path, "a.txt"), []byte("kept\n"), 0o644)
	if err := writerFor(t, path, GitIdentity{}).Detach(ctx); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(path, "a.txt")); string(b) != "kept\n" {
		t.Fatalf("a.txt %q", b)
	}
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "y"), Branch: "feature"}); err != nil {
		t.Fatal(err)
	}
}

func TestReleaseBranchSendsMainBackToItsDefaultBranchWithItsChanges(t *testing.T) {
	repo, _, w := worktreeFixture(t)
	gitIn(t, repo, "switch", "-q", "feature")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("mine\n"), 0o644)
	if _, err := w.ReleaseBranch(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := gitOut(t, repo, "rev-parse", "--abbrev-ref", "HEAD"); got != "main" {
		t.Fatalf("on %q", got)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "a.txt")); string(b) != "mine\n" {
		t.Fatalf("a.txt %q", b)
	}
}

// A name to mint (step 0, a branch-off) never fails on a name: a branch the repo has, one another
// worktree has checked out, or one the record names, gives way to the next free -2, -3 (the walk's
// second conversation with the same title).
func TestWorktreeAddOfANewBranchTakesTheNextFreeName(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "a"), Branch: "fix-otp", Create: true}); err != nil {
		t.Fatal(err)
	}
	gitIn(t, w.Root, "branch", "fix-otp-2")
	r, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "b"), Branch: "fix-otp", Create: true,
		NewBranch: true, TakenBranches: []string{"fix-otp-3"}})
	if err != nil {
		t.Fatal(err)
	}
	if r.Branch != "fix-otp-4" || !r.Created {
		t.Fatalf("result %+v", r)
	}
	if got := gitOut(t, filepath.Join(home, "b"), "rev-parse", "--abbrev-ref", "HEAD"); got != "fix-otp-4" {
		t.Fatalf("branch %q", got)
	}
	// "feature" exists but nobody holds it: a fresh name still steps past it.
	r, err = w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "c"), Branch: "feature", Create: true, NewBranch: true})
	if err != nil || r.Branch != "feature-2" {
		t.Fatalf("%+v %v", r, err)
	}
}

// A lazily made checkout on the workspace's branch checks out a branch the repo has as it is, and
// steps past it only when another folder holds it.
func TestWorktreeAddOfAFreeBranchStepsPastOnlyAHeldOne(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	r, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "a"), Branch: "feature", Create: true, FreeBranch: true})
	if err != nil || r.Branch != "feature" || r.Created {
		t.Fatalf("%+v %v", r, err)
	}
	r, err = w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "b"), Branch: "feature", Create: true, FreeBranch: true})
	if err != nil || r.Branch != "feature-2" || !r.Created {
		t.Fatalf("%+v %v", r, err)
	}
}

// A checkout made for a record that could not be saved is taken back whole: the folder, and the
// branch it made. Nothing was written there yet; anything that was is refused in git's words.
func TestWorktreeDiscardRemovesTheCheckoutAndTheBranchItMade(t *testing.T) {
	_, home, w := worktreeFixture(t)
	ctx := context.Background()
	path := filepath.Join(home, "slug", "core")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "fix-otp", Create: true}); err != nil {
		t.Fatal(err)
	}
	if err := w.WorktreeDiscard(ctx, path, "fix-otp"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("folder left")
	}
	if _, err := os.Stat(filepath.Join(home, "slug")); !os.IsNotExist(err) {
		t.Fatal("the workspace's empty folder was left")
	}
	if w.localBranchExists(ctx, "fix-otp") {
		t.Fatal("the branch it made was left")
	}
	// Without a branch, an existing one stays.
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "feature"}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(path, "a.txt"), []byte("written\n"), 0o644)
	if err := w.WorktreeDiscard(ctx, path, ""); err == nil {
		t.Fatal("a checkout with work in it was discarded")
	}
	gitIn(t, path, "checkout", "--", "a.txt")
	if err := w.WorktreeDiscard(ctx, path, ""); err != nil {
		t.Fatal(err)
	}
	if !w.localBranchExists(ctx, "feature") {
		t.Fatal("a branch it did not make was deleted")
	}
	if err := w.WorktreeDiscard(ctx, w.Root, ""); err == nil {
		t.Fatal("the repository's own folder was discarded")
	}
}

// A Try's copy whose only extra files are ignored ones its prepare wrote — .env, vendor/ with a
// nested clone, node_modules/ — shows nothing in git status, and is taken back like a clean one
// (the walk: the leftover sweep must not keep such a copy as changed).
func TestWorktreeDiscardRemovesACheckoutWhoseOnlyExtraFilesAreIgnored(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	ctx := context.Background()
	os.WriteFile(filepath.Join(repo, ".gitignore"), []byte(".env\nvendor/\nnode_modules/\n"), 0o644)
	gitIn(t, repo, "add", ".gitignore")
	gitIn(t, repo, "commit", "-qm", "ignore")
	path := filepath.Join(home, "try-web", "core")
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "wakil-try/try-web", Create: true}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(path, ".env"), []byte("APP_PORT=41210\n"), 0o644)
	os.MkdirAll(filepath.Join(path, "node_modules", "m"), 0o755)
	os.WriteFile(filepath.Join(path, "node_modules", "m", "i.js"), []byte("x\n"), 0o644)
	clone := filepath.Join(path, "vendor", "pkg")
	os.MkdirAll(clone, 0o755)
	gitIn(t, clone, "init", "-q")
	os.WriteFile(filepath.Join(clone, "f"), []byte("x\n"), 0o644)
	gitIn(t, clone, "add", "f")
	gitIn(t, clone, "commit", "-qm", "clone")
	if got := gitOut(t, path, "status", "--porcelain"); got != "" {
		t.Fatalf("the copy shows changes: %q", got)
	}
	if err := w.WorktreeDiscard(ctx, path, "wakil-try/try-web"); err != nil {
		t.Fatalf("a copy with only ignored files was refused: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("folder left")
	}
	if w.localBranchExists(ctx, "wakil-try/try-web") {
		t.Fatal("the Try's branch was left")
	}
}

// A base the agent chose (workspace_start): the new branch starts from the remote's copy of it when
// there is one, else the local branch; a base that is neither is refused and nothing is made. The
// branch is still a name to mint, so a taken one steps to -2.
func TestWorktreeAddFromAChosenBase(t *testing.T) {
	repo, home, w := worktreeFixture(t)
	ctx := context.Background()
	// production exists locally at main's commit; the remote's production is a commit ahead.
	gitIn(t, repo, "branch", "production")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("two\n"), 0o644)
	gitIn(t, repo, "commit", "-q", "-am", "ahead")
	ahead := gitOut(t, repo, "rev-parse", "HEAD")
	gitIn(t, repo, "reset", "-q", "--hard", "HEAD~1")
	gitIn(t, repo, "update-ref", "refs/remotes/origin/production", ahead)

	r, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "a"), Branch: "hotfix", Base: "production"})
	if err != nil {
		t.Fatal(err)
	}
	if r.Branch != "hotfix" || !r.Created || r.Head != ahead || r.Base != "origin/production" {
		t.Fatalf("from the remote's production: %+v, want head %s", r, ahead)
	}
	// A base only the repo has (no remote copy) is the local branch; a taken name steps to -2.
	r, err = w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "b"), Branch: "hotfix", Base: "feature"})
	if err != nil {
		t.Fatal(err)
	}
	if r.Branch != "hotfix-2" || r.Base != "feature" || r.Head != gitOut(t, repo, "rev-parse", "feature") {
		t.Fatalf("from the local feature: %+v", r)
	}
	// A base that is nowhere: refused whole, naming it, and nothing at the path nor a branch made.
	path := filepath.Join(home, "c")
	_, err = w.WorktreeAdd(ctx, WorktreeAddOptions{Path: path, Branch: "fresh", Base: "staging"})
	if err == nil || !strings.Contains(err.Error(), "staging") || !strings.Contains(err.Error(), "origin/staging") {
		t.Fatalf("err %v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatal("a refused base left a folder")
	}
	if w.localBranchExists(ctx, "fresh") {
		t.Fatal("a refused base made a branch")
	}
	// A base that reads as a flag is refused like a branch that does.
	if _, err := w.WorktreeAdd(ctx, WorktreeAddOptions{Path: filepath.Join(home, "d"), Branch: "x", Base: "-q"}); err == nil {
		t.Fatal("a flag for a base was accepted")
	}
}
