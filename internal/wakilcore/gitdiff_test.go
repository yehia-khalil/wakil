package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"
)

func TestDiffSidesDiffer(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	staged, _ := GitDiff(context.Background(), g, "a.txt", "staged")
	changed, _ := GitDiff(context.Background(), g, "a.txt", "changed")
	if !strings.Contains(staged.Text, "+two") || strings.Contains(staged.Text, "+three") {
		t.Errorf("staged = %q", staged.Text)
	}
	if !strings.Contains(changed.Text, "+three") || strings.Contains(changed.Text, "+two") {
		t.Errorf("changed = %q", changed.Text)
	}
}

func TestShowEachSide(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("staged\n"), 0o644)
	gitIn(t, repo, "add", "a.txt")
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte("disk\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	for rev, want := range map[string]string{"HEAD": "one\n", "index": "staged\n", "worktree": "disk\n"} {
		r, err := GitShow(context.Background(), g, "a.txt", rev)
		if err != nil || r.Text != want {
			t.Errorf("%s: %q, %v", rev, r.Text, err)
		}
	}
}

func TestDiffOverTheLineCapAdmitsIt(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "a.txt"), []byte(strings.Repeat("x\n", 6000)), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, _ := GitDiff(context.Background(), g, "a.txt", "changed")
	if !r.Truncated || r.Lines <= GitDiffLineCap || strings.Count(r.Text, "\n") > GitDiffLineCap {
		t.Fatalf("truncated=%v lines=%d shown=%d", r.Truncated, r.Lines, strings.Count(r.Text, "\n"))
	}
}

func TestBinaryFile(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "b.bin"), []byte{0, 1, 2, 0, 255}, 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, _ := GitShow(context.Background(), g, "b.bin", "worktree")
	if !r.Binary || r.Text != "" || r.Bytes != 5 {
		t.Fatalf("%+v", r)
	}
}

func TestShowRefusesAnEscapingPath(t *testing.T) {
	repo := gitTestRepo(t)
	g, _ := NewGitRunner(repo, []string{repo})
	if _, err := GitShow(context.Background(), g, "../../etc/passwd", "worktree"); err == nil {
		t.Fatal("want refusal")
	}
}

func TestShowAddedFileAtHEAD(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "new.txt"), []byte("new\n"), 0o644)
	gitIn(t, repo, "add", "new.txt")
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "new.txt", "HEAD")
	if err != nil || r.Text != "" {
		t.Errorf("added file at HEAD: text=%q, err=%v", r.Text, err)
	}
}

func TestShowUntrackedFileAtIndex(t *testing.T) {
	repo := gitTestRepo(t)
	os.WriteFile(filepath.Join(repo, "u.txt"), []byte("untracked\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "u.txt", "index")
	if err != nil || r.Text != "" {
		t.Errorf("untracked file at index: text=%q, err=%v", r.Text, err)
	}
}

func TestShowAndDiffWithSpacesAndUnicode(t *testing.T) {
	repo := gitTestRepo(t)
	filename := "a b é.txt"
	content := []byte("original\n")
	os.WriteFile(filepath.Join(repo, filename), content, 0o644)
	gitIn(t, repo, "add", filename)
	gitIn(t, repo, "commit", "-q", "-m", "add unicode file")

	os.WriteFile(filepath.Join(repo, filename), []byte("original\nmodified\n"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})

	// GitShow HEAD
	r, err := GitShow(context.Background(), g, filename, "HEAD")
	if err != nil || r.Text != "original\n" {
		t.Errorf("HEAD: %q, %v", r.Text, err)
	}

	// GitShow index
	r, err = GitShow(context.Background(), g, filename, "index")
	if err != nil || r.Text != "original\n" {
		t.Errorf("index: %q, %v", r.Text, err)
	}

	// GitShow worktree
	r, err = GitShow(context.Background(), g, filename, "worktree")
	if err != nil || r.Text != "original\nmodified\n" {
		t.Errorf("worktree: %q, %v", r.Text, err)
	}

	// GitDiff changed
	dr, err := GitDiff(context.Background(), g, filename, "changed")
	if err != nil || !strings.Contains(dr.Text, "+modified") {
		t.Errorf("diff changed: %q, %v", dr.Text, err)
	}
}

func TestShowStagedDeletion(t *testing.T) {
	repo := gitTestRepo(t)
	gitIn(t, repo, "rm", "a.txt")
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "a.txt", "index")
	if err != nil || r.Text != "" {
		t.Errorf("staged deletion at index: text=%q, err=%v", r.Text, err)
	}
}

func TestShowLargeTextFileWithUTF8Boundary(t *testing.T) {
	repo := gitTestRepo(t)
	// Create a text file larger than 2 MB
	largecontent := strings.Repeat("x", GitFileByteCap+1000)
	os.WriteFile(filepath.Join(repo, "large.txt"), []byte(largecontent), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "large.txt", "worktree")
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !r.Truncated || r.Bytes <= GitFileByteCap || len(r.Text) > GitFileByteCap {
		t.Errorf("truncation: truncated=%v bytes=%d shown=%d", r.Truncated, r.Bytes, len(r.Text))
	}
	if !utf8.ValidString(r.Text) {
		t.Errorf("not valid UTF-8")
	}
}

func TestShowLargeFileWithMidRuneTruncation(t *testing.T) {
	repo := gitTestRepo(t)
	// Create a file of "é" (2-byte UTF-8) repeated past 2 MB.
	// This will likely land mid-rune at the cap boundary.
	eChar := "é" // 2 bytes in UTF-8
	largecontent := strings.Repeat(eChar, (GitFileByteCap+1000)/2)
	os.WriteFile(filepath.Join(repo, "large_utf8.txt"), []byte(largecontent), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "large_utf8.txt", "worktree")
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !r.Truncated {
		t.Errorf("should be truncated")
	}
	if r.Bytes <= GitFileByteCap {
		t.Errorf("bytes should be > cap: %d", r.Bytes)
	}
	if !utf8.ValidString(r.Text) {
		t.Errorf("not valid UTF-8")
	}
	// len(Text) should be within 4 bytes of the cap (could vary depending on rune boundary).
	if len(r.Text) < GitFileByteCap-4 || len(r.Text) > GitFileByteCap {
		t.Errorf("text length should be near cap: %d (cap=%d)", len(r.Text), GitFileByteCap)
	}
}

func TestShowLargeFileWithInvalidByteEarly(t *testing.T) {
	repo := gitTestRepo(t)
	// Create a file with an invalid byte (0xE9) early, then >2 MB of ASCII.
	// The invalid byte should not cause truncation to be cut back before it.
	content := []byte("start ")
	content = append(content, 0xE9)
	content = append(content, []byte(" middle ")...)
	content = append(content, []byte(strings.Repeat("x", GitFileByteCap))...)
	os.WriteFile(filepath.Join(repo, "invalid.txt"), content, 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "invalid.txt", "worktree")
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if !r.Truncated {
		t.Errorf("should be truncated")
	}
	// Should return up to the cap, not cut back to before the invalid byte.
	if len(r.Text) != GitFileByteCap {
		t.Errorf("text length should be cap: got %d, want %d", len(r.Text), GitFileByteCap)
	}
	if r.Bytes <= GitFileByteCap {
		t.Errorf("bytes should be > cap: %d", r.Bytes)
	}
}

// A FIFO in the work tree is not a file to read: opening it would block until a writer
// came. It is refused by its mode, before anything opens it.
func TestShowWorktreeRefusesAFIFO(t *testing.T) {
	repo := gitTestRepo(t)
	if err := syscall.Mkfifo(filepath.Join(repo, "pipe"), 0o644); err != nil {
		t.Skip(err)
	}
	g, _ := NewGitRunner(repo, []string{repo})
	done := make(chan error, 1)
	go func() {
		_, err := GitShow(context.Background(), g, "pipe", "worktree")
		done <- err
	}()
	select {
	case err := <-done:
		if _, ok := IsUserError(err); !ok {
			t.Fatalf("want a UserError, got %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("reading a FIFO blocked")
	}
}

// Nothing under a `.git` directory is a worktree file, in any letter case (APFS folds it).
func TestShowWorktreeRefusesGitDirPaths(t *testing.T) {
	repo := gitTestRepo(t)
	os.MkdirAll(filepath.Join(repo, "sub", ".git"), 0o755)
	os.WriteFile(filepath.Join(repo, "sub", ".git", "x"), []byte("x"), 0o644)
	g, _ := NewGitRunner(repo, []string{repo})
	for _, p := range []string{".git/config", ".GIT/config", "sub/.git/x", ".git"} {
		if _, err := GitShow(context.Background(), g, p, "worktree"); err == nil {
			t.Errorf("%s: want refusal", p)
		}
	}
	if _, err := GitShow(context.Background(), g, "a.git.txt", "worktree"); err != nil {
		t.Errorf("a.git.txt is an ordinary name: %v", err)
	}
}

// A directory symlink into `.git` is `.git` too: the refusal is on the resolved path, not
// only the name asked for. Names that merely start or end with ".git" still read.
func TestShowWorktreeRefusesASymlinkedDirIntoGit(t *testing.T) {
	repo := gitTestRepo(t)
	os.Symlink(".git", filepath.Join(repo, "sub"))
	os.MkdirAll(filepath.Join(repo, "d"), 0o755)
	os.Symlink("../.git/refs", filepath.Join(repo, "d", "r"))
	g, _ := NewGitRunner(repo, []string{repo})
	for _, p := range []string{"sub/config", "sub/HEAD", "d/r/heads/main"} {
		r, err := GitShow(context.Background(), g, p, "worktree")
		if err == nil {
			t.Errorf("%s: want refusal, got %q", p, r.Text)
		}
	}
	for _, p := range []string{".github/w.yml", "foo.git/x", ".gitignore", ".gitx/y"} {
		os.MkdirAll(filepath.Dir(filepath.Join(repo, p)), 0o755)
		os.WriteFile(filepath.Join(repo, p), []byte("hi\n"), 0o644)
		r, err := GitShow(context.Background(), g, p, "worktree")
		if err != nil || r.Text != "hi\n" {
			t.Errorf("%s is an ordinary name: text=%q err=%v", p, r.Text, err)
		}
	}
}

// A symlink's worktree side is its target text, as git diffs it — never the file it names,
// which could be `.git/config`.
func TestShowWorktreeSymlinkIsItsTarget(t *testing.T) {
	repo := gitTestRepo(t)
	os.Symlink(".git/config", filepath.Join(repo, "c"))
	g, _ := NewGitRunner(repo, []string{repo})
	r, err := GitShow(context.Background(), g, "c", "worktree")
	if err != nil || r.Text != ".git/config" {
		t.Fatalf("text=%q err=%v", r.Text, err)
	}
}

// A worktree read takes at most the cap and one byte: a huge file costs 2 MB, not its size.
// The file is sparse, so it costs no disk.
func TestShowWorktreeReadsAtMostTheCap(t *testing.T) {
	repo := gitTestRepo(t)
	f, _ := os.Create(filepath.Join(repo, "huge.txt"))
	f.Truncate(256 << 20)
	f.Close()
	g, _ := NewGitRunner(repo, []string{repo})
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	r, err := GitShow(context.Background(), g, "huge.txt", "worktree")
	runtime.ReadMemStats(&after)
	if err != nil {
		t.Fatal(err)
	}
	if r.Bytes != 256<<20 {
		t.Errorf("bytes = %d, want the true size", r.Bytes)
	}
	if got := after.TotalAlloc - before.TotalAlloc; got > 32<<20 {
		t.Errorf("allocated %d MB reading a file capped at 2 MB", got>>20)
	}
}
