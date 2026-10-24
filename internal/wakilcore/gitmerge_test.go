package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// conflictFixture has feature/search and main each change a.txt's second line, main checked out.
func conflictFixture(t *testing.T) (work string, w *GitWriter, git func(args ...string) string) {
	t.Helper()
	work, w, git = branchFixture(t)
	git("switch", "-q", "-c", "feature/search")
	commitA(t, work, git, "one\nSEARCH\nthree\n", "Seed search")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	return work, w, git
}

func readIn(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// stageA writes text as a.txt and stages it: a conflict resolved.
func stageA(t *testing.T, work string, git func(args ...string) string, text string) {
	t.Helper()
	writeIn(t, work, "a.txt", text)
	git("add", "a.txt")
}

func TestMergeCleanCommitsWithGitsMessage(t *testing.T) {
	work, w, git := branchFixture(t)
	git("switch", "-q", "-c", "feature/search")
	writeIn(t, work, "b.txt", "b\n")
	git("add", "b.txt")
	git("commit", "-qm", "b")
	git("switch", "-q", "main")
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	r, err := w.Merge(context.Background(), "feature/search")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Done || len(r.Conflicts) != 0 || r.Summary == "" {
		t.Fatalf("r = %+v", r)
	}
	if s := git("log", "-1", "--format=%s"); s != "Merge branch 'feature/search'" {
		t.Fatalf("subject = %q", s)
	}
}

func TestMergeConflictStopsAndLists(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "a b.txt", "one\n")
	git("add", "a b.txt")
	git("commit", "-qm", "space")
	git("switch", "-q", "-c", "feature/search")
	writeIn(t, work, "a b.txt", "SEARCH\n")
	git("commit", "-qam", "Seed search")
	git("switch", "-q", "main")
	writeIn(t, work, "a b.txt", "MAIN\n")
	git("commit", "-qam", "main")
	r, err := w.Merge(context.Background(), "feature/search")
	if err != nil {
		t.Fatal(err)
	}
	if r.Done || !slices.Equal(r.Conflicts, []string{"a b.txt"}) ||
		r.Summary != "Merge stopped on conflicts in a b.txt; resolve them below" {
		t.Fatalf("r = %+v", r)
	}
	git("rev-parse", "-q", "--verify", "MERGE_HEAD")
}

func TestMergeCarriesADirtyTree(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	git("switch", "-q", "-c", "feature/search")
	commitA(t, work, git, "one\nSEARCH\nthree\n", "Seed search")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	head := git("rev-parse", "HEAD")
	writeIn(t, work, "c.txt", "c dirty\n")
	ctx := context.Background()
	r, err := w.Merge(ctx, "feature/search")
	if err != nil {
		t.Fatal(err)
	}
	if r.Done || !slices.Equal(r.Conflicts, []string{"a.txt"}) {
		t.Fatalf("r = %+v", r)
	}
	if r, err = w.Abort(ctx); err != nil || !r.Done {
		t.Fatalf("abort = %+v, %v", r, err)
	}
	if got := readIn(t, work, "c.txt"); got != "c dirty\n" {
		t.Fatalf("c.txt = %q, want the dirty change back", got)
	}
	if git("rev-parse", "HEAD") != head || readIn(t, work, "a.txt") != "one\nMAIN\nthree\n" {
		t.Fatal("the tree is not back to before the merge")
	}
}

// otherFixture leaves main one unpushed commit ahead of origin/main, and other one commit off
// origin/main beside it, main checked out.
func otherFixture(t *testing.T) (work string, w *GitWriter, git func(args ...string) string) {
	t.Helper()
	work, w, git = branchFixture(t)
	git("switch", "-q", "-c", "other")
	writeIn(t, work, "d.txt", "d\n")
	git("add", "d.txt")
	git("commit", "-qm", "other")
	git("switch", "-q", "main")
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "mine")
	return work, w, git
}

func TestRebaseCleanFinishes(t *testing.T) {
	_, w, git := otherFixture(t)
	r, err := w.Rebase(context.Background(), "other")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Done || len(r.Conflicts) != 0 || r.Summary == "" || strings.Contains(r.Summary, "pushed") {
		t.Fatalf("r = %+v (nothing rebased was pushed)", r)
	}
	if git("rev-parse", "HEAD~1") != git("rev-parse", "other") || git("log", "-1", "--format=%s") != "mine" {
		t.Fatal("main is not its commit on top of other")
	}
}

func TestRebaseConflictStops(t *testing.T) {
	_, w, git := conflictFixture(t)
	git("switch", "-q", "feature/search")
	r, err := w.Rebase(context.Background(), "main")
	if err != nil {
		t.Fatal(err)
	}
	if r.Done || !slices.Equal(r.Conflicts, []string{"a.txt"}) ||
		r.Summary != "Rebase stopped on conflicts in a.txt (step 1 of 1); resolve them below" {
		t.Fatalf("r = %+v", r)
	}
	if readOp(t, w).Kind != "rebase" {
		t.Fatal("the rebase is not kept")
	}
}

func TestContinueRefusedWhileAConflictIsUnstaged(t *testing.T) {
	work, w, git := conflictFixture(t)
	ctx := context.Background()
	if _, err := w.Merge(ctx, "feature/search"); err != nil {
		t.Fatal(err)
	}
	writeIn(t, work, "a.txt", "one\nBOTH\nthree\n") // resolved on disk, not yet staged
	_, err := w.Continue(ctx, "")
	if err == nil || err.Error() != "Resolve the conflicts in a.txt first" {
		t.Fatalf("err = %v", err)
	}
	git("add", "a.txt")
	r, err := w.Continue(ctx, "")
	if err != nil || !r.Done {
		t.Fatalf("r = %+v, %v", r, err)
	}
	if readOp(t, w).Kind != "" {
		t.Fatal("the merge is still in progress")
	}
}

// Review Focus 4: the repository names an editor that never returns; Continue must not wait on it.
func TestContinueRebaseNeedsNoEditor(t *testing.T) {
	work, w, git := branchFixture(t)
	git("config", "core.editor", "sleep 60")
	git("config", "sequence.editor", "sleep 60")
	git("switch", "-q", "-c", "topic")
	commitA(t, work, git, "TOPIC\ntwo\nthree\n", "first")
	commitA(t, work, git, "TOPIC\ntwo\nTOPIC\n", "second")
	git("switch", "-q", "main")
	commitA(t, work, git, "MAIN\ntwo\nMAIN\n", "main")
	git("switch", "-q", "topic")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, err := w.Rebase(ctx, "main")
	if err != nil || r.Done || r.Summary != "Rebase stopped on conflicts in a.txt (step 1 of 2); resolve them below" {
		t.Fatalf("rebase = %+v, %v", r, err)
	}
	stageA(t, work, git, "BOTH\ntwo\nMAIN\n")
	r, err = w.Continue(ctx, "")
	if err != nil || r.Done || r.Summary != "Rebase stopped on conflicts in a.txt (step 2 of 2); resolve them below" {
		t.Fatalf("first continue = %+v, %v", r, err)
	}
	stageA(t, work, git, "BOTH\ntwo\nBOTH\n")
	r, err = w.Continue(ctx, "")
	if err != nil || !r.Done {
		t.Fatalf("second continue = %+v, %v", r, err)
	}
	if got := git("log", "--format=%s", "main..HEAD"); got != "second\nfirst" {
		t.Fatalf("messages = %q", got)
	}
}

func TestContinueMergeUsesTheBoxOrGitsMessage(t *testing.T) {
	for _, tc := range []struct{ box, want string }{
		{"Ada's merge", "Ada's merge"},
		{"", "Merge branch 'feature/search'"},
	} {
		work, w, git := conflictFixture(t)
		ctx := context.Background()
		if _, err := w.Merge(ctx, "feature/search"); err != nil {
			t.Fatal(err)
		}
		stageA(t, work, git, "one\nBOTH\nthree\n")
		r, err := w.Continue(ctx, tc.box)
		if err != nil || !r.Done {
			t.Fatalf("box %q: r = %+v, %v", tc.box, r, err)
		}
		if s := git("log", "-1", "--format=%s"); s != tc.want {
			t.Fatalf("box %q: subject = %q, want %q", tc.box, s, tc.want)
		}
		if len(strings.Fields(git("log", "-1", "--format=%P"))) != 2 {
			t.Fatalf("box %q: HEAD is not a merge commit", tc.box)
		}
	}
}

func TestSkipDropsTheCommit(t *testing.T) {
	work, w, git := conflictFixture(t)
	ctx := context.Background()
	if _, err := w.Skip(ctx); err == nil || err.Error() != "Skip is for a rebase" {
		t.Fatalf("skip with nothing = %v", err)
	}
	git("switch", "-q", "feature/search")
	writeIn(t, work, "b.txt", "b\n")
	git("add", "b.txt")
	git("commit", "-qm", "clean")
	if r, err := w.Rebase(ctx, "main"); err != nil || r.Done {
		t.Fatalf("rebase = %+v, %v", r, err)
	}
	r, err := w.Skip(ctx)
	if err != nil || !r.Done {
		t.Fatalf("skip = %+v, %v", r, err)
	}
	if got := git("log", "--format=%s", "main..HEAD"); got != "clean" {
		t.Fatalf("commits = %q, want Seed search left out", got)
	}
}

func TestRebaseOfPushedCommitsSaysSo(t *testing.T) {
	_, w, git := otherFixture(t)
	git("push", "-q", "origin", "main")
	r, err := w.Rebase(context.Background(), "other")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Done || !strings.HasSuffix(r.Summary, "; commits already pushed were rewritten, so Push is refused as behind") {
		t.Fatalf("r = %+v", r)
	}
}

func TestAbortEachKindRestoresTheTree(t *testing.T) {
	ctx := context.Background()
	for _, kind := range []string{"merge", "rebase", "cherry-pick", "revert"} {
		work, w, git := conflictFixture(t)
		switch kind {
		case "merge":
			if r, err := w.Merge(ctx, "feature/search"); err != nil || r.Done {
				t.Fatalf("merge = %+v, %v", r, err)
			}
		case "rebase":
			git("switch", "-q", "feature/search")
			if r, err := w.Rebase(ctx, "main"); err != nil || r.Done {
				t.Fatalf("rebase = %+v, %v", r, err)
			}
		case "cherry-pick":
			tryGit(work, "cherry-pick", "feature/search")
		case "revert":
			commitA(t, work, git, "one\nAGAIN\nthree\n", "again")
			tryGit(work, "revert", "--no-edit", "HEAD~1")
		}
		if readOp(t, w).Kind != kind {
			t.Fatalf("%s: not stopped part-way", kind)
		}
		before := readIn(t, work, "a.txt")
		r, err := w.Abort(ctx)
		if err != nil || !r.Done {
			t.Fatalf("%s: abort = %+v, %v", kind, r, err)
		}
		if readOp(t, w).Kind != "" || git("status", "--porcelain") != "" {
			t.Fatalf("%s: still in progress or dirty", kind)
		}
		if after := readIn(t, work, "a.txt"); after == before || strings.Contains(after, "<<<<<<<") {
			t.Fatalf("%s: a.txt = %q", kind, after)
		}
	}
	_, w, _ := branchFixture(t)
	if _, err := w.Abort(ctx); err == nil || err.Error() != "Nothing to abort" {
		t.Fatalf("abort with nothing = %v", err)
	}
}

func TestContinueSaysWhereAKeptAutostashIs(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "c.txt", "c\n")
	git("add", "c.txt")
	git("commit", "-qm", "c")
	git("switch", "-q", "-c", "feature/search")
	commitA(t, work, git, "one\nSEARCH\nthree\n", "Seed search")
	writeIn(t, work, "c.txt", "c theirs\n")
	git("commit", "-qam", "theirs")
	git("switch", "-q", "main")
	commitA(t, work, git, "one\nMAIN\nthree\n", "main")
	writeIn(t, work, "c.txt", "c dirty\n") // clashes with feature/search's c.txt once the merge lands
	ctx := context.Background()
	if r, err := w.Merge(ctx, "feature/search"); err != nil || r.Done {
		t.Fatalf("merge = %+v, %v", r, err)
	}
	stageA(t, work, git, "one\nBOTH\nthree\n")
	r, err := w.Continue(ctx, "")
	if err != nil || !r.Done || !strings.HasSuffix(r.Summary, "; your uncommitted changes are in git stash") {
		t.Fatalf("r = %+v, %v", r, err)
	}
	if !strings.Contains(git("stash", "list"), "autostash") {
		t.Fatal("the autostash is not in the stash list")
	}
}

func TestMergeRefusesADashBranch(t *testing.T) {
	_, w, _ := branchFixture(t)
	ctx := context.Background()
	if _, err := w.Merge(ctx, "-x"); err == nil || err.Error() != `"-x" is not a branch` {
		t.Fatalf("merge = %v", err)
	}
	if _, err := w.Rebase(ctx, "--root"); err == nil || err.Error() != `"--root" is not a branch` {
		t.Fatalf("rebase = %v", err)
	}
	if readOp(t, w).Kind != "" {
		t.Fatal("something started")
	}
}

func TestMergeRefusedMidRebase(t *testing.T) {
	_, w, git := conflictFixture(t)
	git("switch", "-q", "feature/search")
	ctx := context.Background()
	if r, err := w.Rebase(ctx, "main"); err != nil || r.Done {
		t.Fatalf("rebase = %+v, %v", r, err)
	}
	want := "A rebase is in progress in " + w.Root + "; finish or abort it first"
	if _, err := w.Merge(ctx, "main"); err == nil || err.Error() != want {
		t.Fatalf("merge = %v", err)
	}
	if _, err := w.Rebase(ctx, "main"); err == nil || err.Error() != want {
		t.Fatalf("rebase = %v", err)
	}
}
