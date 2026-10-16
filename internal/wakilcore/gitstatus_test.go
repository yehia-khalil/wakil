package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
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

func TestParseAheadBehind(t *testing.T) {
	in := "# branch.oid abc\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +2 -1\x00"
	st := ParseGitStatus("/r", []byte(in))
	if st.Upstream != "origin/main" || st.Ahead != 2 || st.Behind != 1 {
		t.Fatalf("%+v", st)
	}
}

// R13: a file mid-merge with a conflict is one Changes row with status U — not a staged
// row and a changed row, and not dropped.
func TestStatusConflictIsOneChangedRow(t *testing.T) {
	repo := gitTestRepo(t)
	gitIn(t, repo, "checkout", "-q", "-b", "side")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("side\n"), 0o644)
	gitIn(t, repo, "commit", "-q", "-am", "side")
	gitIn(t, repo, "checkout", "-q", "main")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("main\n"), 0o644)
	gitIn(t, repo, "commit", "-q", "-am", "main")
	cmd := exec.Command("git", "-C", repo, "merge", "-q", "side")
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if err := cmd.Run(); err == nil {
		t.Fatal("want a conflicted merge")
	}
	g, _ := NewGitRunner(repo, []string{repo})
	st, err := ReadGitStatus(context.Background(), g)
	if err != nil {
		t.Fatal(err)
	}
	want := GitFile{Path: "a.txt", Group: "changed", Status: "U"}
	if len(st.Files) != 1 || st.Files[0] != want {
		t.Fatalf("files = %+v", st.Files)
	}
}
