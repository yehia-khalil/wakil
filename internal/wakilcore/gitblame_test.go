package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBlameNamesEachLinesCommit(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "b.txt", "one\ntwo\n")
	git("add", "b.txt")
	git("commit", "-qm", "seed b")
	first := git("rev-parse", "HEAD")
	writeIn(t, work, "b.txt", "one\nTWO\n")
	git("-c", "user.name=Ada Lovelace", "commit", "-qam", "shout two")
	second := git("rev-parse", "HEAD")
	b, err := ReadBlame(context.Background(), w.runner(), "b.txt", nil)
	if err != nil || len(b) != 2 {
		t.Fatalf("blame = %+v err %v", b, err)
	}
	if b[0].Line != 1 || b[0].ID != first || b[0].Author != "w" || b[0].Subject != "seed b" || b[0].Date.IsZero() {
		t.Errorf("line 1 = %+v", b[0])
	}
	if b[1].Line != 2 || b[1].ID != second || b[1].Author != "Ada Lovelace" || b[1].Subject != "shout two" {
		t.Errorf("line 2 = %+v", b[1])
	}
}

// Review Focus 2: the tab's unsaved text is blamed, so a line inserted above shifts the rest.
func TestBlameOfUnsavedTextShiftsLines(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "b.txt", "one\ntwo\n")
	git("add", "b.txt")
	git("commit", "-qm", "seed b")
	id := git("rev-parse", "HEAD")
	text := "new top\none\ntwo\n"
	b, err := ReadBlame(context.Background(), w.runner(), "b.txt", &text)
	if err != nil || len(b) != 3 {
		t.Fatalf("blame = %+v err %v", b, err)
	}
	if b[0].ID != strings.Repeat("0", 40) || b[1].ID != id || b[2].ID != id || b[1].Line != 2 {
		t.Fatalf("blame = %+v", b)
	}
}

func TestBlameOfAnUntrackedFileFails(t *testing.T) {
	work, w, _ := branchFixture(t)
	writeIn(t, work, "loose.txt", "x\n")
	if _, err := ReadBlame(context.Background(), w.runner(), "loose.txt", nil); err == nil {
		t.Fatal("an untracked file was blamed")
	}
}

func TestBlameFlagsStayFenced(t *testing.T) {
	_, w, _ := branchFixture(t)
	g := w.runner()
	ctx := context.Background()
	for _, args := range [][]string{{"--output=x"}, {"-s"}, {"--contents=/etc/passwd"}} {
		if _, err := g.Run(ctx, "blame", args...); err == nil {
			t.Errorf("blame %v was not refused", args)
		}
		if _, err := g.RunInput(ctx, []byte("x"), "blame", args...); err == nil {
			t.Errorf("RunInput blame %v was not refused", args)
		}
	}
}

// Final review C1: blame turns textconv on by default, so a repository's diff driver must never run.
func TestBlameRunsNoTextconvProgram(t *testing.T) {
	work, w, git := branchFixture(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := filepath.Join(t.TempDir(), "evil.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch "+marker+"\ncat \"$1\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeIn(t, work, ".gitattributes", "*.txt diff=x\n")
	writeIn(t, work, "f.txt", "one\n")
	git("add", ".")
	git("commit", "-qm", "seed f")
	git("config", "diff.x.textconv", script)
	text := "zero\none\n"
	for _, in := range []*string{nil, &text} {
		if _, err := ReadBlame(context.Background(), w.runner(), "f.txt", in); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("textconv ran (unsaved text: %v)", in != nil)
		}
	}
}

// Final review 9: a path with a space and a non-ASCII letter is blamed whole.
func TestBlameReadsANameWithASpaceAndAccent(t *testing.T) {
	work, w, git := branchFixture(t)
	writeIn(t, work, "my café.txt", "x\n")
	git("add", ".")
	git("commit", "-qm", "accent")
	b, err := ReadBlame(context.Background(), w.runner(), "my café.txt", nil)
	if err != nil || len(b) != 1 || b[0].Subject != "accent" {
		t.Fatalf("blame = %+v err %v", b, err)
	}
}
