package wakilcore

import (
	"context"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestStatusPartlyStagedFileIsInBothGroups(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	want := []GitFile{{Path: "a.txt", Group: "staged", Status: "M"}, {Path: "a.txt", Group: "changed", Status: "M"}}
	if len(st.Files) != 2 || st.Files[0] != want[0] || st.Files[1] != want[1] {
		t.Fatalf("files = %+v", st.Files)
	}
	if st.Branch != "main" {
		t.Errorf("branch = %q", st.Branch)
	}
}

func TestStatusUntrackedRenameSpacesAndUnicode(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "new file é.txt"), []byte("x\n"), 0o644)
	gitIn(t, repo, "mv", "a.txt", "b c.txt")
	g, _ := NewGitRunner(repo, []string{repo})
	st, _ := ReadGitStatus(context.Background(), g)
	var sawRename, sawUntracked bool
	for _, f := range st.Files {
		if f.Group == "staged" && f.Status == "R" && f.Path == "b c.txt" && f.OrigPath == "a.txt" {
			sawRename = true
		}
		if f.Group == "untracked" && f.Path == "new file é.txt" {
			sawUntracked = true
		}
	}
	if !sawRename || !sawUntracked {
		t.Fatalf("files = %+v", st.Files)
	}
}

func TestStatusDetachedHead(t *testing.T) {
	repo := gitTestRepo(t)
	gitIn(t, repo, "checkout", "-q", "--detach")
	g, _ := NewGitRunner(repo, []string{repo})
	st, _ := ReadGitStatus(context.Background(), g)
	if st.Branch != "" || len(st.Detached) < 7 {
		t.Fatalf("branch=%q detached=%q", st.Branch, st.Detached)
	}
}

// Item 8 (2026-10-30): a branch-off names the commit it started from, so status says the head's
// short SHA on a branch too; an unborn branch has none.
func TestStatusNamesTheHeadsShortCommit(t *testing.T) {
	st := ParseGitStatus("/r", []byte("# branch.oid 2d1ac2e9f00ba4\x00# branch.head work\x00"))
	if st.Head != "2d1ac2e" || st.Branch != "work" {
		t.Fatalf("%+v", st)
	}
	if st := ParseGitStatus("/r", []byte("# branch.oid (initial)\x00# branch.head main\x00")); st.Head != "" {
		t.Fatalf("unborn head = %q", st.Head)
	}
}

func TestParseAheadBehind(t *testing.T) {
	in := "# branch.oid abc\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00"
	st := ParseGitStatus("/r", []byte(in))
	if st.Upstream != "origin/main" || st.Ahead != 2 || st.Behind != 1 {
		t.Fatalf("%+v", st)
	}
}

// 3a-v-b: each unmerged path is one row in the conflicts group, keeping its XY; the operation is
// the status's state; a staged file still holding a whole marker block is flagged (spec call 4).
func TestStatusKeepsEachConflictKind(t *testing.T) {
	repo := gitTestRepo(t)
	put := func(name, text string) { os.WriteFile(filepath.Join(repo, name), []byte(text), 0o644) }
	put("du.txt", "base\n")
	put("ud.txt", "base\n")
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "base")
	gitIn(t, repo, "checkout", "-q", "-b", "side")
	put("a.txt", "side\n")
	put("aa.txt", "side\n")
	put("du.txt", "side\n")
	gitIn(t, repo, "rm", "-q", "ud.txt")
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "side")
	gitIn(t, repo, "checkout", "-q", "main")
	put("a.txt", "main\n")
	put("aa.txt", "main\n")
	put("ud.txt", "main\n")
	gitIn(t, repo, "rm", "-q", "du.txt")
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "main")
	cmd := exec.Command("git", "-C", repo, "merge", "-q", "side")
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if err := cmd.Run(); err == nil {
		t.Fatal("want a conflicted merge")
	}
	block := "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> side\n"
	put("m.txt", "top\n"+block)
	put("half.txt", "<<<<<<< HEAD\nonly an opener\n")
	big := make([]byte, 1<<20+1)
	for i := range big {
		big[i] = 'x'
	}
	put("big.txt", block+string(big))
	gitIn(t, repo, "add", "m.txt", "half.txt", "big.txt")
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	if st.State == nil || st.State.Kind != "merge" || st.State.Incoming != "side" {
		t.Fatalf("state = %+v", st.State)
	}
	want := map[string]GitFile{
		"a.txt":    {Path: "a.txt", Group: "conflicts", Status: "U", Kind: "UU"},
		"aa.txt":   {Path: "aa.txt", Group: "conflicts", Status: "U", Kind: "AA"},
		"du.txt":   {Path: "du.txt", Group: "conflicts", Status: "U", Kind: "DU"},
		"ud.txt":   {Path: "ud.txt", Group: "conflicts", Status: "U", Kind: "UD"},
		"m.txt":    {Path: "m.txt", Group: "staged", Status: "A", Markers: true},
		"half.txt": {Path: "half.txt", Group: "staged", Status: "A"},
		"big.txt":  {Path: "big.txt", Group: "staged", Status: "A"},
	}
	if len(st.Files) != len(want) {
		t.Fatalf("files = %+v", st.Files)
	}
	for _, f := range st.Files {
		if f != want[f.Path] {
			t.Errorf("%s = %+v, want %+v", f.Path, f, want[f.Path])
		}
	}
}

func TestStatusHasNoStateOnACleanTree(t *testing.T) {
	repo := gitTestRepo(t)
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil || st.State != nil {
		t.Fatalf("state = %+v, err %v", st.State, err)
	}
}

// Final review I2: the staged copies are read in one batch, so each is matched to its own path (a
// name with a space or a non-ASCII letter whole), and a staged blob over the limit is not read even
// when the work-tree copy is small.
func TestStatusReadsEachStagedCopyForMarkers(t *testing.T) {
	repo := gitTestRepo(t)
	put := func(name, text string) { os.WriteFile(filepath.Join(repo, name), []byte(text), 0o644) }
	block := "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> side\n"
	put("plain.txt", "no markers\n")
	put("my notes é.txt", "top\n"+block)
	put("z.txt", block)
	put("big.txt", block+strings.Repeat("x", 1<<20))
	gitIn(t, repo, "add", ".")
	put("big.txt", "small now\n")
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, f := range st.Files {
		if f.Group == "staged" {
			got[f.Path] = f.Markers
		}
	}
	want := map[string]bool{"plain.txt": false, "my notes é.txt": true, "z.txt": true, "big.txt": false}
	if !maps.Equal(got, want) {
		t.Fatalf("markers = %v", got)
	}
}
