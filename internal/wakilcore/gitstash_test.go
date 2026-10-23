package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStashModes(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "changed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	if err := w.Stash(ctx, "plain", "default"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "?? u.txt" {
		t.Fatalf("default left %q", s)
	}
	if err := w.Stash(ctx, "with untracked", "untracked"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "" {
		t.Fatalf("untracked left %q", s)
	}
	writeIn(t, work, "a.txt", "staged\n")
	git("add", "a.txt")
	writeIn(t, work, "b.txt", "loose\n")
	if err := w.Stash(ctx, "staged only", "staged"); err != nil {
		t.Fatal(err)
	}
	if s := git("status", "--porcelain"); s != "?? b.txt" {
		t.Fatalf("staged left %q", s)
	}
	if !strings.Contains(git("stash", "list"), "staged only") {
		t.Fatal("no message")
	}
}

func TestNothingToStashSaysSo(t *testing.T) {
	_, w, _ := branchFixture(t)
	if err := w.Stash(context.Background(), "", "default"); err == nil || err.Error() != "No local changes to stash" {
		t.Fatalf("err = %v", err)
	}
}

func TestReadStashesListsFilesWithUntracked(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "a.txt", "changed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	if err := w.Stash(context.Background(), "wip search", "untracked"); err != nil {
		t.Fatal(err)
	}
	s, err := ReadStashes(context.Background(), w.runner())
	if err != nil || len(s) != 1 {
		t.Fatalf("stashes = %+v err %v", s, err)
	}
	if s[0].Index != 0 || s[0].ID != git("rev-parse", "stash@{0}") || s[0].Message != "wip search" || s[0].Branch != "main" {
		t.Fatalf("stash = %+v", s[0])
	}
	if strings.Join(s[0].Files, ",") != "a.txt,u.txt" || strings.Join(s[0].Untracked, ",") != "u.txt" || s[0].Date.IsZero() {
		t.Fatalf("files = %v date %v", s[0].Files, s[0].Date)
	}
}

func TestApplyPopDropByIndexAndID(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\n")
	w.Stash(ctx, "first", "default")
	writeIn(t, work, "b.txt", "two\n")
	git("add", "b.txt")
	w.Stash(ctx, "second", "default")
	s, _ := ReadStashes(ctx, w.runner())
	if len(s) != 2 || s[0].Message != "second" {
		t.Fatalf("stashes = %+v", s)
	}
	if note, err := w.StashApply(ctx, 1, s[1].ID, false); err != nil || note != "" {
		t.Fatalf("apply: %q %v", note, err)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\n" || len(strings.Split(git("stash", "list"), "\n")) != 2 {
		t.Fatal("apply did not keep the stash")
	}
	git("checkout", "--", "a.txt")
	if _, err := w.StashApply(ctx, 0, s[0].ID, true); err != nil {
		t.Fatal(err)
	}
	if git("stash", "list") == "" || strings.Contains(git("stash", "list"), "second") {
		t.Fatalf("pop kept it: %q", git("stash", "list"))
	}
	rest, _ := ReadStashes(ctx, w.runner())
	if err := w.StashDrop(ctx, 0, rest[0].ID); err != nil || git("stash", "list") != "" {
		t.Fatalf("drop: %v %q", err, git("stash", "list"))
	}
}

// Review Focus 2: another worktree or the terminal stashes between Wakil's read and its drop.
func TestAMovedStashListIsRefused(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "mine\n")
	w.Stash(ctx, "mine", "default")
	read, _ := ReadStashes(ctx, w.runner())
	writeIn(t, work, "a.txt", "terminal\n")
	git("stash", "push", "-q", "-m", "from the terminal")
	err := w.StashDrop(ctx, 0, read[0].ID)
	if err == nil || err.Error() != "The stash list changed; look again" {
		t.Fatalf("err = %v", err)
	}
	if n := len(strings.Split(git("stash", "list"), "\n")); n != 2 {
		t.Fatalf("a stash went: %d left", n)
	}
	if err := w.StashDropAll(ctx); err != nil || git("stash", "list") != "" {
		t.Fatalf("drop all: %v", err)
	}
}

// A clash puts back only the files the stash touched; the operator's other changes stay.
func TestPopClashKeepsStashAndCleansTree(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	w.Stash(ctx, "clashing", "default")
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "other.txt", "mine, unrelated\n")
	s, _ := ReadStashes(ctx, w.runner())
	note, err := w.StashApply(ctx, 0, s[0].ID, true)
	if err != nil || note != "Your stash clashes with main; it is kept in git stash" {
		t.Fatalf("note %q err %v", note, err)
	}
	if st := git("status", "--porcelain"); st != "?? other.txt" {
		t.Fatalf("status = %q", st)
	}
	if b, _ := os.ReadFile(filepath.Join(work, "a.txt")); string(b) != "one\nCOMMITTED\nthree\n" {
		t.Fatalf("a.txt = %q", b)
	}
	if git("stash", "list") == "" {
		t.Fatal("the stash went")
	}
}

func TestGitShowReadsAStashFile(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "a.txt", "stashed\n")
	writeIn(t, work, "u.txt", "untracked\n")
	w.Stash(context.Background(), "s", "untracked")
	id := git("rev-parse", "stash@{0}")
	g := w.runner()
	ctx := context.Background()
	if r, err := GitShow(ctx, g, "a.txt", "stash:"+id); err != nil || r.Text != "stashed\n" {
		t.Fatalf("stash side: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "a.txt", "stash-base:"+id); err != nil || r.Text != "one\ntwo\nthree\n" {
		t.Fatalf("base side: %+v %v", r, err)
	}
	if r, err := GitShow(ctx, g, "u.txt", "stash-untracked:"+id); err != nil || r.Text != "untracked\n" {
		t.Fatalf("untracked side: %+v %v", r, err)
	}
	if _, err := GitShow(ctx, g, "a.txt", "stash:HEAD~1"); err == nil {
		t.Fatal("a stash side takes a commit id only")
	}
}

// Review C1: a clash's recovery never deletes a file the apply did not create, and reads names with
// spaces or non-ASCII letters whole.
func TestAClashNeverDeletesTheOperatorsFiles(t *testing.T) {
	work, w, git := branchFixture(t)
	ctx := context.Background()
	writeIn(t, work, "a.txt", "one\nSTASHED\nthree\n")
	writeIn(t, work, "u.txt", "stashed u\n")
	writeIn(t, work, "my notes.txt", "stashed notes\n")
	writeIn(t, work, "café.txt", "stashed café\n")
	if err := w.Stash(ctx, "clashing", "untracked"); err != nil {
		t.Fatal(err)
	}
	writeIn(t, work, "a.txt", "one\nCOMMITTED\nthree\n")
	git("commit", "-qam", "moved on")
	writeIn(t, work, "u.txt", "OPERATOR\n")     // the operator's own, untracked
	writeIn(t, work, "notes.txt", "unrelated\n") // a name a split on spaces would hit
	s, _ := ReadStashes(ctx, w.runner())
	if got := strings.Join(s[0].Files, "|"); got != "a.txt|café.txt|my notes.txt|u.txt" {
		t.Fatalf("files = %q", got)
	}
	note, err := w.StashApply(ctx, 0, s[0].ID, true)
	if err != nil || note != "Your stash clashes with main; it is kept in git stash" {
		t.Fatalf("note %q err %v", note, err)
	}
	for name, want := range map[string]string{"u.txt": "OPERATOR\n", "notes.txt": "unrelated\n", "a.txt": "one\nCOMMITTED\nthree\n"} {
		if b, err := os.ReadFile(filepath.Join(work, name)); err != nil || string(b) != want {
			t.Errorf("%s = %q, %v", name, b, err)
		}
	}
	if git("stash", "list") == "" {
		t.Fatal("the stash went")
	}
}
