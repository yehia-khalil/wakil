package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// sidesFixture stops a merge of side into main on two conflicts: a.txt both modified (UU), and d.txt
// modified on main and deleted on side (UD, no stage 3).
func sidesFixture(t *testing.T) (work string, w *GitWriter, git func(args ...string) string) {
	t.Helper()
	work, w, git = branchFixture(t)
	writeIn(t, work, "d.txt", "dee\n")
	git("add", "d.txt")
	git("commit", "-qm", "d")
	git("switch", "-q", "-c", "side")
	writeIn(t, work, "a.txt", "one\nSIDE\nthree\n")
	git("rm", "-q", "d.txt")
	git("commit", "-qam", "side")
	git("switch", "-q", "main")
	writeIn(t, work, "a.txt", "one\nMAIN\nthree\n")
	writeIn(t, work, "d.txt", "DEE\n")
	git("commit", "-qam", "main")
	r, err := w.Merge(context.Background(), "side")
	if err != nil || !slices.Equal(r.Conflicts, []string{"a.txt", "d.txt"}) {
		t.Fatalf("fixture: %+v %v", r, err)
	}
	return work, w, git
}

func TestResolveEachTake(t *testing.T) {
	ctx := context.Background()
	work, w, git := sidesFixture(t)
	if err := w.Resolve(ctx, "a.txt", "current"); err != nil {
		t.Fatal(err)
	}
	if err := w.Resolve(ctx, "d.txt", "keep"); err != nil {
		t.Fatal(err)
	}
	if readIn(t, work, "a.txt") != "one\nMAIN\nthree\n" || readIn(t, work, "d.txt") != "DEE\n" {
		t.Fatalf("current/keep: %q %q", readIn(t, work, "a.txt"), readIn(t, work, "d.txt"))
	}
	if u := git("ls-files", "-u"); u != "" {
		t.Fatalf("still unmerged: %s", u)
	}

	work, w, git = sidesFixture(t)
	if err := w.Resolve(ctx, "a.txt", "incoming"); err != nil {
		t.Fatal(err)
	}
	if err := w.Resolve(ctx, "d.txt", "delete"); err != nil {
		t.Fatal(err)
	}
	if readIn(t, work, "a.txt") != "one\nSIDE\nthree\n" {
		t.Fatalf("incoming: %q", readIn(t, work, "a.txt"))
	}
	if _, err := os.Stat(filepath.Join(work, "d.txt")); !os.IsNotExist(err) {
		t.Fatal("delete left d.txt")
	}
	if u := git("ls-files", "-u"); u != "" || git("ls-files", "d.txt") != "" {
		t.Fatalf("unmerged %q, d.txt in the index %q", u, git("ls-files", "d.txt"))
	}
	if err := w.Resolve(ctx, "a.txt", "theirs"); err == nil || err.Error() != "take must be current, incoming, keep or delete, got theirs" {
		t.Fatalf("err = %v", err)
	}
}

func TestResolveRefusesAResolvedFile(t *testing.T) {
	ctx := context.Background()
	_, w, _ := sidesFixture(t)
	if err := w.Resolve(ctx, "a.txt", "current"); err != nil {
		t.Fatal(err)
	}
	if err := w.Resolve(ctx, "a.txt", "incoming"); err == nil || err.Error() != "a.txt has no conflict" {
		t.Fatalf("err = %v", err)
	}
}

// A directory is not one conflicted file: it would take or stage every conflict under it.
func TestResolveRefusesADirectory(t *testing.T) {
	ctx := context.Background()
	work, w, git := sidesFixture(t)
	before := readIn(t, work, "d.txt")
	for _, p := range []string{".", "./"} {
		for _, take := range []string{"current", "keep"} {
			if err := w.Resolve(ctx, p, take); err == nil || err.Error() != ". has no conflict" {
				t.Fatalf("%s %s: err = %v", p, take, err)
			}
		}
	}
	if u := git("ls-files", "-u"); strings.Count(u, "\n") != 4 || readIn(t, work, "d.txt") != before ||
		!strings.Contains(readIn(t, work, "a.txt"), "<<<<<<<") {
		t.Fatalf("a refusal resolved something:\n%s", u)
	}
}

// Review Focus 3: the side that deleted the file is absent, not an error.
func TestShowOursAndTheirs(t *testing.T) {
	ctx := context.Background()
	_, w, _ := sidesFixture(t)
	g := w.runner()
	for _, c := range []struct{ path, rev, want string }{
		{"a.txt", "ours", "one\nMAIN\nthree\n"},
		{"a.txt", "theirs", "one\nSIDE\nthree\n"},
		{"d.txt", "ours", "DEE\n"},
	} {
		if r, err := GitShow(ctx, g, c.path, c.rev); err != nil || r.Text != c.want || r.Absent {
			t.Errorf("%s %s: %+v %v", c.path, c.rev, r, err)
		}
	}
	if r, err := GitShow(ctx, g, "d.txt", "theirs"); err != nil || !r.Absent {
		t.Fatalf("d.txt theirs: %+v %v", r, err)
	}
}
