package wakilcore

import (
	"context"
	"strings"
	"testing"
)

func TestFileHistoryNewestFirstWithAuthorAndSubject(t *testing.T) {
	work, w, git := branchFixture(t)
	for _, s := range []string{"first", "second", "third"} {
		writeIn(t, work, "h.txt", s+"\n")
		git("add", "h.txt")
		git("commit", "-qm", "edit "+s)
	}
	h, err := ReadFileHistory(context.Background(), w.runner(), "h.txt", 0, 0)
	if err != nil || len(h) != 3 {
		t.Fatalf("history = %+v err %v", h, err)
	}
	for i, want := range []string{"edit third", "edit second", "edit first"} {
		if h[i].Subject != want || h[i].Author != "w" || h[i].Email != "w@x" || h[i].Path != "h.txt" || h[i].Date.IsZero() {
			t.Errorf("row %d = %+v", i, h[i])
		}
	}
	if h[0].ID != git("rev-parse", "HEAD") || len(h[0].Parents) != 1 || h[0].Parents[0] != h[1].ID {
		t.Fatalf("ids = %+v", h[0])
	}
}

// Review Focus 1 and 4: a rename is followed, and names with spaces or non-ASCII letters read whole.
func TestFileHistoryFollowsARename(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "old name.txt", "a\nb\nc\nd\n")
	git("add", "old name.txt")
	git("commit", "-qm", "add it")
	git("mv", "old name.txt", "café.txt")
	git("commit", "-qm", "rename it")
	writeIn(t, work, "café.txt", "a\nb\nc\nd\ne\n")
	git("commit", "-qam", "edit it")
	h, err := ReadFileHistory(context.Background(), w.runner(), "café.txt", 0, 0)
	if err != nil || len(h) != 3 {
		t.Fatalf("history = %+v err %v", h, err)
	}
	if h[0].Path != "café.txt" || h[1].Path != "café.txt" || h[2].Path != "old name.txt" {
		t.Fatalf("paths = %q %q %q", h[0].Path, h[1].Path, h[2].Path)
	}
}

func TestFileHistoryPages(t *testing.T) {
	work, w, git := branchFixture(t)
	for _, s := range []string{"1", "2", "3"} {
		writeIn(t, work, "p.txt", s+"\n")
		git("add", "p.txt")
		git("commit", "-qm", "page "+s)
	}
	h, err := ReadFileHistory(context.Background(), w.runner(), "p.txt", 1, 1)
	if err != nil || len(h) != 1 || h[0].Subject != "page 2" {
		t.Fatalf("history = %+v err %v", h, err)
	}
}

func TestFileHistoryOfAnUntrackedFileIsEmpty(t *testing.T) {
	work, w, _ := branchFixture(t)
	writeIn(t, work, "loose.txt", "x\n")
	h, err := ReadFileHistory(context.Background(), w.runner(), "loose.txt", 0, 0)
	if err != nil || len(h) != 0 {
		t.Fatalf("history = %+v err %v", h, err)
	}
}

func TestFileHistoryKeepsAMessageBody(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "b.txt", "x\n")
	git("add", "b.txt")
	git("commit", "-qm", "subject line", "-m", "body one\nbody two")
	h, _ := ReadFileHistory(context.Background(), w.runner(), "b.txt", 0, 0)
	if len(h) != 1 || h[0].Subject != "subject line" || h[0].Body != "body one\nbody two" {
		t.Fatalf("history = %+v", h)
	}
}

// Review Focus 3: the commit that added the file has no before side.
func TestGitShowCommitSides(t *testing.T) {
	work, w, git := branchFixture(t)
	g := w.runner()
	ctx := context.Background()
	writeIn(t, work, "old name.txt", "before\n")
	git("add", "old name.txt")
	git("commit", "-qm", "add")
	added := git("rev-parse", "HEAD")
	git("mv", "old name.txt", "new.txt")
	writeIn(t, work, "new.txt", "after\n")
	git("add", "new.txt")
	git("commit", "-qm", "rename and edit")
	moved := git("rev-parse", "HEAD")
	if r, err := GitShow(ctx, g, "new.txt", "commit:"+moved); err != nil || r.Text != "after\n" {
		t.Fatalf("commit side: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "new.txt", "commit-parent:"+moved+":old name.txt"); err != nil || r.Text != "before\n" {
		t.Fatalf("parent side under the old name: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "new.txt", "commit-parent:"+moved); err != nil || !r.Absent {
		t.Fatalf("parent side under the new name: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "old name.txt", "commit-parent:"+added); err != nil || !r.Absent {
		t.Fatalf("the adding commit's parent: %+v %v", r, err)
	}
	for _, bad := range []string{"commit:HEAD", "commit-parent:HEAD~1", "commit:" + moved + ":x"} {
		if _, err := GitShow(ctx, g, "new.txt", bad); err == nil {
			t.Errorf("%s was not refused", bad)
		}
	}
}

// The adding commit at the root of history has no parent at all.
func TestGitShowParentOfTheRootCommitIsAbsent(t *testing.T) {
	_, w, git := branchFixture(t)
	root := git("rev-list", "--max-parents=0", "HEAD")
	if r, err := GitShow(context.Background(), w.runner(), "a.txt", "commit-parent:"+root); err != nil || !r.Absent {
		t.Fatalf("root parent: %+v %v", r, err)
	}
}

func TestLogFlagsStayFenced(t *testing.T) {
	_, w, _ := branchFixture(t)
	g := w.runner()
	if _, err := g.Run(context.Background(), "log", "--output=x"); err == nil || !strings.Contains(err.Error(), "--output") {
		t.Fatalf("--output: %v", err)
	}
	if _, err := g.Run(context.Background(), "log", "--follow", "--max-count=1", "--format=%H", "--", "a.txt"); err != nil {
		t.Fatalf("--follow: %v", err)
	}
}
