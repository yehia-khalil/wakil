package wakilcore

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// filesRoots makes two roots under one temp dir and an outside dir, symlink-resolved.
// testHeavy is 3b-ii's fixed list, which every listing test before 3b-v part 2 assumed.
var testHeavy = HeavyNames(DefaultHeavyFolders)

func filesRoots(t *testing.T) (a, b, outside string) {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	a, b, outside = filepath.Join(base, "a"), filepath.Join(base, "b"), filepath.Join(base, "out")
	for _, d := range []string{a, b, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestFilesConfineAcceptsAFileInARoot(t *testing.T) {
	a, b, _ := filesRoots(t)
	write(t, filepath.Join(b, "x.go"), "x")
	real, root, err := ConfineFilePath(filepath.Join(b, "x.go"), []string{a, b}, true)
	if err != nil || real != filepath.Join(b, "x.go") || root != b {
		t.Fatalf("got %q %q %v", real, root, err)
	}
}

func TestFilesConfineRefusesDotDotOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "s.txt"), "secret")
	_, _, err := ConfineFilePath(filepath.Join(a, "..", "out", "s.txt"), []string{a}, true)
	if err == nil || !strings.Contains(err.Error(), "is outside the active project's roots") {
		t.Fatalf("want the outside-the-roots refusal, got %v", err)
	}
}

func TestFilesConfineRefusesALinkOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "s.txt"), "secret")
	if err := os.Symlink(filepath.Join(outside, "s.txt"), filepath.Join(a, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ConfineFilePath(filepath.Join(a, "link.txt"), []string{a}, true); err == nil {
		t.Fatal("a link out of the root was accepted")
	}
}

func TestFilesConfineRefusesARelativePath(t *testing.T) {
	a, _, _ := filesRoots(t)
	if _, _, err := ConfineFilePath("x.go", []string{a}, false); err == nil {
		t.Fatal("a relative path was accepted")
	}
}

func TestFilesReadReturnsTextSizeAndMtime(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "m.go"), "line1\r\nline2\r\n")
	r, err := ReadFile(filepath.Join(a, "m.go"), []string{a})
	if err != nil {
		t.Fatal(err)
	}
	if r.Text != "line1\r\nline2\r\n" || r.Size != 14 || r.Mtime == 0 || !r.UTF8 || r.Binary || !r.Exists {
		t.Fatalf("got %+v", r)
	}
}

func TestFilesReadOverTheCapReturnsTheTailFromALineStart(t *testing.T) {
	a, _, _ := filesRoots(t)
	head := strings.Repeat("x", FileCap) // pushed out of the window
	body := "partial line\n[2026-10-18 13:33:20] local.ERROR: boom\nlast\n"
	write(t, filepath.Join(a, "laravel.log"), head+body)
	r, err := ReadFile(filepath.Join(a, "laravel.log"), []string{a})
	if err != nil || !r.Tail || !r.OverCap || r.Size != len(head)+len(body) {
		t.Fatalf("got %+v %v", r, err)
	}
	if strings.HasPrefix(r.Text, "x") || !strings.HasSuffix(r.Text, "local.ERROR: boom\nlast\n") {
		t.Fatalf("tail does not start at a line: %q", r.Text[:min(40, len(r.Text))])
	}
	if r.Start != r.Size-len(r.Text) || r.End != r.Size {
		t.Fatalf("start %d end %d size %d len %d", r.Start, r.End, r.Size, len(r.Text))
	}
}

func TestFilesReadFromReturnsWholeLinesAfterTheOffset(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "one\ntwo\nthr")
	r, err := ReadFileFrom(p, 4, []string{a})
	if err != nil || r.Text != "two\n" || r.End != 8 || r.Size != 11 {
		t.Fatalf("got %+v %v", r, err)
	}
	r, _ = ReadFileFrom(p, 8, []string{a})
	if r.Text != "" || r.End != 8 {
		t.Fatalf("a line still being written must wait: %+v", r)
	}
}

func TestFilesReadFromAShorterFileSaysShrunk(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "new\n")
	r, err := ReadFileFrom(p, 100, []string{a})
	if err != nil || !r.Shrunk || r.Text != "" {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesReadFromTooFarBehindSaysTooFar(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, strings.Repeat("y\n", FileCap)) // 2×FileCap bytes past offset 0
	r, err := ReadFileFrom(p, 0, []string{a})
	if err != nil || !r.TooFar || r.Text != "" {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesReadFromFlagsABinaryChunk(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "laravel.log")
	write(t, p, "ok\n\x00bad\n")
	r, _ := ReadFileFrom(p, 3, []string{a})
	if !r.Binary || r.Text != "" {
		t.Fatalf("got %+v", r)
	}
}

func TestFilesReadBinaryAndNonUTF8(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "b.bin"), "ab\x00cd")
	write(t, filepath.Join(a, "l.txt"), "caf\xe9")
	bin, _ := ReadFile(filepath.Join(a, "b.bin"), []string{a})
	lat, _ := ReadFile(filepath.Join(a, "l.txt"), []string{a})
	if !bin.Binary || bin.Text != "" {
		t.Fatalf("binary: %+v", bin)
	}
	if lat.UTF8 || lat.Text != "" || lat.Binary {
		t.Fatalf("latin-1: %+v", lat)
	}
}

func TestFilesReadOfAMissingFileSaysItDoesNotExist(t *testing.T) {
	a, _, _ := filesRoots(t)
	r, err := ReadFile(filepath.Join(a, "gone.go"), []string{a})
	if err != nil || r.Exists {
		t.Fatalf("got %+v %v", r, err)
	}
}

func TestFilesWriteRoundTripsAndKeepsLineEndings(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "w.go")
	write(t, p, "old")
	w, err := WriteFile(p, "new\r\n", false, []string{a})
	if err != nil || w.Size != 5 || w.Mtime == 0 {
		t.Fatalf("got %+v %v", w, err)
	}
	got, _ := os.ReadFile(p)
	if string(got) != "new\r\n" {
		t.Fatalf("disk has %q", got)
	}
}

func TestFilesWriteWithoutCreateRefusesAMissingFile(t *testing.T) {
	a, _, _ := filesRoots(t)
	if _, err := WriteFile(filepath.Join(a, "nope.go"), "x", false, []string{a}); err == nil {
		t.Fatal("wrote a missing file without create")
	}
}

func TestFilesWriteCreateMakesParentFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "new", "dir", "f.sql")
	if _, err := WriteFile(p, "select 1", true, []string{a}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(p); string(got) != "select 1" {
		t.Fatalf("disk has %q", got)
	}
}

func TestFilesWriteCreateRefusesAParentLinkOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	if err := os.Symlink(outside, filepath.Join(a, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteFile(filepath.Join(a, "escape", "sub", "f.txt"), "x", true, []string{a}); err == nil {
		t.Fatal("created through a link out of the root")
	}
	if _, err := os.Stat(filepath.Join(outside, "sub")); err == nil {
		t.Fatal("a folder was made outside the root")
	}
}

func TestFilesWriteLeavesNoTempFileBehind(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "t.go")
	write(t, p, "x")
	if _, err := WriteFile(p, "y", false, []string{a}); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(a)
	if len(entries) != 1 {
		t.Fatalf("folder holds %d entries, want 1", len(entries))
	}
}

func TestFilesListInARepoRespectsGitignore(t *testing.T) {
	a, _, _ := filesRoots(t)
	run := func(args ...string) {
		c := exec.Command("git", args...)
		c.Dir = a
		c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-b", "main")
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "src", "k.go"), "k")
	write(t, filepath.Join(a, "vendor", "v.go"), "v")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(l.Files, ",") != ".gitignore,src/k.go" || l.Truncated {
		t.Fatalf("got %v", l.Files)
	}
}

func TestFilesListOutsideARepoWalksAndSkipsDotGit(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "one.txt"), "1")
	write(t, filepath.Join(a, "d", "two.txt"), "2")
	write(t, filepath.Join(a, ".git", "HEAD"), "ref")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil || strings.Join(l.Files, ",") != "d/two.txt,one.txt" {
		t.Fatalf("got %v %v", l.Files, err)
	}
}

func TestFilesListRefusesARootThatIsNotTheProjects(t *testing.T) {
	a, b, _ := filesRoots(t)
	if _, err := ListFiles(context.Background(), b, []string{a}, testHeavy); err == nil {
		t.Fatal("listed a root the project does not declare")
	}
}

func TestFilesConfineRefusesADanglingLinkOutOfTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	// A parent that is a link to a folder that does not exist yet.
	if err := os.Symlink(filepath.Join(outside, "newdir"), filepath.Join(a, "d1")); err != nil {
		t.Fatal(err)
	}
	// A final component that is a link to a file that does not exist yet.
	if err := os.Symlink(filepath.Join(outside, "new.txt"), filepath.Join(a, "f.txt")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{filepath.Join(a, "d1", "f.txt"), filepath.Join(a, "f.txt")} {
		if _, _, err := ConfineFilePath(p, []string{a}, false); err == nil || !strings.Contains(err.Error(), "is outside the active project's roots") {
			t.Fatalf("%s: want the outside-the-roots refusal, got %v", p, err)
		}
		if _, err := WriteFile(p, "x", true, []string{a}); err == nil || !strings.Contains(err.Error(), "is outside the active project's roots") {
			t.Fatalf("%s: write want the outside-the-roots refusal, got %v", p, err)
		}
	}
	for _, n := range []string{"newdir", "new.txt"} {
		if _, err := os.Lstat(filepath.Join(outside, n)); err == nil {
			t.Fatalf("%s was created outside the root", n)
		}
	}
}

// gitInit makes dir a repository with an isolated config.
func gitInit(t *testing.T, dir string) {
	t.Helper()
	c := exec.Command("git", "init", "-b", "main")
	c.Dir = dir
	c.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
}

func TestFilesListAFolderOfReposListsEachRepoThroughGit(t *testing.T) {
	a, _, _ := filesRoots(t)
	api := filepath.Join(a, "api")
	if err := os.MkdirAll(api, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, api)
	write(t, filepath.Join(api, ".gitignore"), "build/\n.env\n")
	write(t, filepath.Join(api, "main.go"), "m")
	write(t, filepath.Join(api, ".env"), "SECRET=1")
	write(t, filepath.Join(api, "build", "out.bin"), "b")
	write(t, filepath.Join(a, "notes.md"), "n")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != "api/.gitignore,api/main.go,notes.md" || l.Truncated {
		t.Fatalf("got %v", got)
	}
}

func TestFilesListOutsideARepoSkipsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "web", "index.js"), "i")
	write(t, filepath.Join(a, "web", "node_modules", "left-pad", "index.js"), "l")
	write(t, filepath.Join(a, ".venv", "bin", "python"), "p")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil || strings.Join(l.Files, ",") != "web/index.js" {
		t.Fatalf("got %v %v", l.Files, err)
	}
}

func TestFilesListWalkStopsAtTheCapAndSaysTruncated(t *testing.T) {
	a, _, _ := filesRoots(t)
	d := filepath.Join(a, "many")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < FileListCap+5; i++ {
		f, err := os.Create(filepath.Join(d, "f"+strconv.Itoa(i)))
		if err != nil {
			t.Fatal(err)
		}
		f.Close()
	}
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if !l.Truncated || len(l.Files) != FileListCap {
		t.Fatalf("truncated %v with %d files, want true with %d", l.Truncated, len(l.Files), FileListCap)
	}
}

func TestFilesListHonoursACancelledContext(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "one.txt"), "1")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ListFiles(ctx, a, []string{a}, testHeavy); err == nil {
		t.Fatal("listed with a cancelled context")
	}
}

func TestFilesReadRefusesAFIFO(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "pipe")
	if err := syscall.Mkfifo(p, 0o644); err != nil {
		t.Skip("mkfifo:", err)
	}
	done := make(chan error, 1)
	go func() { _, err := ReadFile(p, []string{a}); done <- err }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("want a refusal naming a non-regular file, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("reading a FIFO blocked")
	}
}

func TestFilesListInARepoReportsIgnoredAndHeavySeparately(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), ".env\nvendor/\nstorage/\nnode_modules/\n")
	write(t, filepath.Join(a, "app.php"), "a")
	write(t, filepath.Join(a, ".env"), "DB=1")
	write(t, filepath.Join(a, "storage", "l.log"), "l")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	write(t, filepath.Join(a, "web", "node_modules", "x", "i.js"), "x")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != ".gitignore,app.php" {
		t.Fatalf("files %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != ".env,storage/l.log" {
		t.Fatalf("ignored %v", got)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,vendor,web/node_modules" {
		t.Fatalf("heavy %v", got)
	}
	if len(l.Repos) != 0 || l.Truncated {
		t.Fatalf("repos %v truncated %v", l.Repos, l.Truncated)
	}
}

func TestFilesListAFolderOfReposReportsReposAndTheirIgnored(t *testing.T) {
	a, _, _ := filesRoots(t)
	api := filepath.Join(a, "api")
	if err := os.MkdirAll(api, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, api)
	write(t, filepath.Join(api, ".gitignore"), ".env\nvendor/\n")
	write(t, filepath.Join(api, "main.go"), "m")
	write(t, filepath.Join(api, ".env"), "S=1")
	write(t, filepath.Join(api, "vendor", "a.php"), "v")
	write(t, filepath.Join(a, "notes.md"), "n")
	write(t, filepath.Join(a, ".venv", "bin", "python"), "p")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != "api/.gitignore,api/main.go,notes.md" {
		t.Fatalf("files %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "api/.env" {
		t.Fatalf("ignored %v", got)
	}
	if got := strings.Join(l.Heavy, ","); got != ".venv,api/.git,api/vendor" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Repos, ","); got != "api" {
		t.Fatalf("repos %v", got)
	}
}

// Review Focus 1: tracked files are taken first; ignored files fill only what is left.
func TestFilesListIgnoredFillsOnlyWhatTrackedLeaves(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "storage/\n")
	for i := 0; i < 10; i++ {
		write(t, filepath.Join(a, fmt.Sprintf("t%02d.go", i)), "t")
	}
	d := filepath.Join(a, "storage")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < FileListCap; i++ {
		if err := os.WriteFile(filepath.Join(d, fmt.Sprintf("%05d.log", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if len(l.Files) != 11 || len(l.Files)+len(l.Ignored) != FileListCap || !l.Truncated {
		t.Fatalf("files %d ignored %d truncated %v", len(l.Files), len(l.Ignored), l.Truncated)
	}
}

// Tracked first, across repositories: in a folder of repositories, an early repository's ignored
// files never stop the walk before a later repository's tracked files are listed.
func TestFilesListAnEarlyReposIgnoredNeverCrowdsOutALaterReposTracked(t *testing.T) {
	a, _, _ := filesRoots(t)
	first, second := filepath.Join(a, "aa"), filepath.Join(a, "bb")
	for _, d := range []string{filepath.Join(first, "storage"), second} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitInit(t, first)
	gitInit(t, second)
	write(t, filepath.Join(first, ".gitignore"), "storage/\n")
	for i := 0; i < FileListCap+1; i++ {
		if err := os.WriteFile(filepath.Join(first, "storage", fmt.Sprintf("%05d.log", i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(t, filepath.Join(second, "main.go"), "m")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(l.Files, "bb/main.go") || len(l.Files)+len(l.Ignored) != FileListCap || !l.Truncated {
		t.Fatalf("files %v ignored %d truncated %v", l.Files, len(l.Ignored), l.Truncated)
	}
}

func TestFilesListDirListsOneFolderSortedFoldersFirst(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "vendor", "b.php"), "b")
	write(t, filepath.Join(a, "vendor", "a.php"), "a")
	write(t, filepath.Join(a, "vendor", "laravel", "x.php"), "x")
	d, err := ListDir(a, "vendor", []string{a})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range d.Entries {
		got = append(got, e.Kind+":"+e.Name)
	}
	if strings.Join(got, ",") != "dir:laravel,file:a.php,file:b.php" {
		t.Fatalf("got %v", got)
	}
}

func TestFilesListDirRefusesAFolderOutsideTheRoot(t *testing.T) {
	a, _, outside := filesRoots(t)
	if err := os.Symlink(outside, filepath.Join(a, "link")); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"../out", "link"} {
		_, err := ListDir(a, dir, []string{a})
		if err == nil || !strings.Contains(err.Error(), "is outside the active project's roots") {
			t.Fatalf("%s: got %v", dir, err)
		}
	}
}

func TestFilesListDirReportsALinkToAFolderAsADir(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "node_modules", ".pnpm", "pkg", "i.js"), "x")
	write(t, filepath.Join(a, "node_modules", "f.txt"), "f")
	if err := os.Symlink(filepath.Join(a, "node_modules", ".pnpm", "pkg"), filepath.Join(a, "node_modules", "pkg")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(a, "nowhere"), filepath.Join(a, "node_modules", "broken")); err != nil {
		t.Fatal(err)
	}
	d, err := ListDir(a, "node_modules", []string{a})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range d.Entries {
		got = append(got, e.Kind+":"+e.Name)
	}
	if strings.Join(got, ",") != "dir:.pnpm,dir:pkg,file:broken,file:f.txt" {
		t.Fatalf("got %v", got)
	}
}

func searchFixture(t *testing.T) (a, b string) {
	t.Helper()
	a, b, _ = filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), ".env\n")
	write(t, filepath.Join(a, "Booking.php"), "class Booking {\n  $bookingId = 1;\n  $BOOKINGID = 2;\n}\n")
	write(t, filepath.Join(a, ".env"), "bookingId=secret\n")
	write(t, filepath.Join(b, "routes.ts"), "const bookingIdx = 3;\n")
	return a, b
}

func TestFilesSearchFindsAcrossRootsAndSkipsIgnored(t *testing.T) {
	a, b := searchFixture(t)
	r, err := SearchFiles(context.Background(), []string{a, b}, testHeavy, nil, SearchQuery{Query: "bookingId"})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, m := range r.Matches {
		got = append(got, fmt.Sprintf("%s:%d:%d", filepath.Base(m.Root)+"/"+m.Path, m.Line, m.Column))
	}
	if strings.Join(got, ",") != "a/Booking.php:2:4,a/Booking.php:3:4,b/routes.ts:1:7" || r.Truncated {
		t.Fatalf("got %v", got)
	}
}

func TestFilesSearchSwitches(t *testing.T) {
	a, b := searchFixture(t)
	cases := []struct {
		q    SearchQuery
		want int
	}{
		{SearchQuery{Query: "bookingId", Case: true}, 2}, // Booking.php line 2, routes.ts
		{SearchQuery{Query: "bookingId", Word: true}, 2}, // not bookingIdx
		{SearchQuery{Query: "book\\w+Id\\b", Regex: true, Case: true}, 1},
		{SearchQuery{Query: "booking(", Regex: false}, 0}, // literal: no error
	}
	for _, c := range cases {
		r, err := SearchFiles(context.Background(), []string{a, b}, testHeavy, nil, c.q)
		if err != nil || len(r.Matches) != c.want {
			t.Fatalf("%+v: %d matches, err %v", c.q, len(r.Matches), err)
		}
	}
}

func TestFilesSearchAnInvalidRegexIsGosOwnError(t *testing.T) {
	a, b := searchFixture(t)
	_, err := SearchFiles(context.Background(), []string{a, b}, testHeavy, nil, SearchQuery{Query: "book(", Regex: true})
	if err == nil || !strings.Contains(err.Error(), "missing closing )") {
		t.Fatalf("got %v", err)
	}
}

func TestFilesSearchStopsAtTheCap(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "many.txt"), strings.Repeat("x\n", SearchCap+5))
	r, err := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "x"})
	if err != nil || len(r.Matches) != SearchCap || !r.Truncated {
		t.Fatalf("%d matches, truncated %v, err %v", len(r.Matches), r.Truncated, err)
	}
}

func TestFilesSearchHonoursACancelledContext(t *testing.T) {
	a, b := searchFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := SearchFiles(ctx, []string{a, b}, testHeavy, nil, SearchQuery{Query: "b"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
}

func TestFilesSearchSkipsBinaryAndOverCapFiles(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "bin.dat"), "needle\x00")
	write(t, filepath.Join(a, "big.txt"), "needle\n"+strings.Repeat("y", FileCap))
	write(t, filepath.Join(a, "ok.txt"), "needle\n")
	r, _ := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "needle"})
	if len(r.Matches) != 1 || r.Matches[0].Path != "ok.txt" {
		t.Fatalf("got %+v", r.Matches)
	}
}

// Review Focus 3: columns are UTF-16 units, as Monaco counts them.
func TestFilesSearchColumnsAreUTF16(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "ar.txt"), "حجز 😀 bookingId\n")
	r, _ := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "bookingId"})
	// "حجز " is 4 UTF-16 units, "😀 " is 3 (a surrogate pair and a space): the match starts at 8.
	if len(r.Matches) != 1 || r.Matches[0].Column != 8 {
		t.Fatalf("got %+v", r.Matches)
	}
}

func TestFilesSearchPreviewIsTrimmedAroundTheMatch(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "long.txt"), strings.Repeat("a", 1000)+"needle"+strings.Repeat("b", 1000)+"\n")
	r, _ := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "needle"})
	if len(r.Matches) != 1 || len([]rune(r.Matches[0].Preview)) > 400 || !strings.Contains(r.Matches[0].Preview, "needle") {
		t.Fatalf("got %q", r.Matches[0].Preview)
	}
}

func TestFilesSearchRefusesARootThatIsNotTheProjects(t *testing.T) {
	a, b := searchFixture(t)
	_, err := SearchFiles(context.Background(), []string{a}, testHeavy, []string{b}, SearchQuery{Query: "x"})
	if err == nil || !strings.Contains(err.Error(), "is outside the active project's roots") {
		t.Fatalf("got %v", err)
	}
}

// A match names its root as the caller passed it, never its real path: Swift's roots, the editor
// watcher and editor_refresh {root} all use the project's path (/tmp/…, not /private/tmp/…), and
// "changed since this search" compares against them.
func TestFilesSearchNamesTheRootAsPassedNotItsRealPath(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "n.txt"), "needle\n")
	link := filepath.Join(filepath.Dir(a), "link-a")
	if err := os.Symlink(a, link); err != nil {
		t.Fatal(err)
	}
	for _, only := range [][]string{nil, {link}} {
		r, err := SearchFiles(context.Background(), []string{link}, testHeavy, only, SearchQuery{Query: "needle"})
		if err != nil || len(r.Matches) != 1 || r.Matches[0].Root != link {
			t.Fatalf("only %v: %+v, err %v", only, r.Matches, err)
		}
	}
}

// Invariant 6: a link to a file outside the roots is not searched, in a repository or a plain folder.
func TestFilesSearchSkipsALinkToAFileOutsideTheRoots(t *testing.T) {
	for _, repo := range []bool{true, false} {
		a, _, outside := filesRoots(t)
		if repo {
			gitInit(t, a)
		}
		write(t, filepath.Join(outside, "secret.txt"), "needle\n")
		if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(a, "link.txt")); err != nil {
			t.Fatal(err)
		}
		write(t, filepath.Join(a, "ok.txt"), "needle\n")
		r, err := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "needle"})
		if err != nil || len(r.Matches) != 1 || r.Matches[0].Path != "ok.txt" {
			t.Fatalf("repo %v: %+v, err %v", repo, r.Matches, err)
		}
	}
}

// A root whose listing hit FileListCap is searched only in part, and the result says so apart
// from the match cap.
func TestFilesSearchSaysWhenAListingWasTruncated(t *testing.T) {
	a, _, _ := filesRoots(t)
	for i := 0; i < FileListCap+5; i++ {
		write(t, filepath.Join(a, "f"+strconv.Itoa(i)+".txt"), "x\n")
	}
	r, err := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "nomatch"})
	if err != nil || !r.FilesTruncated || r.Truncated {
		t.Fatalf("files_truncated %v truncated %v err %v", r.FilesTruncated, r.Truncated, err)
	}
	r, _ = SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "x"})
	if r.FilesTruncated != true {
		t.Fatal("files_truncated lost on a search with matches")
	}
}

// Final review I3: git reports a repository nested inside a repository root as one entry,
// "nested/". It is a child repository: listed through git like a folder-of-repos child, never a
// file row, and its files are searched.
func TestFilesListARepoNestedInARepoRootIsAChildRepo(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "skip/\n")
	write(t, filepath.Join(a, "app.php"), "a")
	deep := filepath.Join(a, "packages", "deep")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, deep)
	write(t, filepath.Join(deep, ".gitignore"), ".env\nvendor/\n")
	write(t, filepath.Join(deep, "x.go"), "needle")
	write(t, filepath.Join(deep, ".env"), "S=1")
	write(t, filepath.Join(deep, "vendor", "v.php"), "v")
	// An ignored nested repository is a heavy folder: shown, loaded on demand, never searched.
	skip := filepath.Join(a, "skip")
	if err := os.MkdirAll(skip, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, skip)
	write(t, filepath.Join(skip, "s.txt"), "needle")
	// git's heavy-folder pathspec does not exclude a collapsed "vendor/pkg/" entry (measured):
	// a repository inside a heavy folder stays inside it, unlisted.
	write(t, filepath.Join(a, ".gitignore"), "skip/\nvendor/\n")
	pkg := filepath.Join(a, "vendor", "pkg")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, pkg)
	write(t, filepath.Join(pkg, "p.php"), "needle")
	l, err := ListFiles(context.Background(), a, []string{a}, testHeavy)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Files, ","); got != ".gitignore,app.php,packages/deep/.gitignore,packages/deep/x.go" {
		t.Fatalf("files %v", got)
	}
	if got := strings.Join(l.Repos, ","); got != "packages/deep" {
		t.Fatalf("repos %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "packages/deep/.env" {
		t.Fatalf("ignored %v", got)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,packages/deep/.git,packages/deep/vendor,skip,vendor" {
		t.Fatalf("heavy %v", got)
	}
	res, err := SearchFiles(context.Background(), []string{a}, testHeavy, nil, SearchQuery{Query: "needle"})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Matches) != 1 || res.Matches[0].Path != "packages/deep/x.go" {
		t.Fatalf("matches %+v", res.Matches)
	}
}

// 3b-v part 2: the project's list decides which ignored folders are heavy; vendor, no longer
// named, is listed as ignored files.
func TestFilesListTakesTheProjectsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "storage/\nvendor/\n")
	write(t, filepath.Join(a, "app.php"), "a")
	write(t, filepath.Join(a, "storage", "l.log"), "l")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"storage"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,storage" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "vendor/autoload.php" {
		t.Fatalf("ignored %v", got)
	}
}

// An empty project list leaves .git heavy.
func TestFilesListWithNoHeavyFoldersKeepsGitHeavy(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "vendor", "autoload.php"), "v")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "vendor/autoload.php" {
		t.Fatalf("ignored %v", got)
	}
}

// Review Focus 2: a name is a folder name, not a pattern — "lib*" is heavy, "library" is not.
func TestAHeavyFolderNameIsMatchedLiterally(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "lib*/\n")
	write(t, filepath.Join(a, "lib*", "x.js"), "x")
	write(t, filepath.Join(a, "library", "y.js"), "y")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"lib*"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != ".git,lib*" {
		t.Fatalf("heavy %v", got)
	}
	if got := strings.Join(l.Ignored, ","); got != "library/y.js" {
		t.Fatalf("ignored %v; library is not lib*", got)
	}
}

// A child repository of a folder of repositories takes the project's list too.
func TestAChildRepositoryTakesTheProjectsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	api := filepath.Join(a, "api")
	if err := os.MkdirAll(api, 0o755); err != nil {
		t.Fatal(err)
	}
	gitInit(t, api)
	write(t, filepath.Join(api, ".gitignore"), "dist/\n")
	write(t, filepath.Join(api, "main.go"), "m")
	write(t, filepath.Join(api, "dist", "out.js"), "o")
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames([]string{"dist"}))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(l.Heavy, ","); got != "api/.git,api/dist" {
		t.Fatalf("heavy %v", got)
	}
}

// Spec: search skips ignored files either way — a folder taken off the list is listed as
// ignored, and still not searched.
func TestSearchSkipsAnIgnoredFolderThatIsNoLongerHeavy(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "vendor/\n")
	write(t, filepath.Join(a, "app.php"), "needle")
	write(t, filepath.Join(a, "vendor", "lib.php"), "needle")
	r, err := SearchFiles(context.Background(), []string{a}, HeavyNames(nil), nil, SearchQuery{Query: "needle"})
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Matches) != 1 || r.Matches[0].Path != "app.php" {
		t.Fatalf("matches %+v", r.Matches)
	}
}

func TestReplaceTextSwitches(t *testing.T) {
	cases := []struct {
		text string
		q    SearchQuery
		with string
		want string
		n    int
	}{
		{"Foo foo FOO", SearchQuery{Query: "foo"}, "x", "x x x", 3},
		{"Foo foo FOO", SearchQuery{Query: "foo", Case: true}, "x", "Foo x FOO", 1},
		{"foo food", SearchQuery{Query: "foo", Word: true}, "x", "x food", 1},
		{"a.b axb", SearchQuery{Query: "a.b"}, "x", "x axb", 1}, // literal: the dot is a dot
		{"nothing here", SearchQuery{Query: "foo"}, "x", "nothing here", 0},
		{"foo bar", SearchQuery{Query: "foo "}, "", "bar", 1}, // an empty replacement deletes
	}
	for _, c := range cases {
		got, n, err := ReplaceText(c.text, c.q, c.with)
		if err != nil || got != c.want || n != c.n {
			t.Fatalf("%+v: got %q, %d, %v", c.q, got, n, err)
		}
	}
}

func TestReplaceTextRegexExpandsGroups(t *testing.T) {
	cases := []struct{ text, query, with, want string }{
		{"id=7 id=8", `id=(\d)`, `n$1`, "n7 n8"},
		{"id=7", `(?P<k>\w+)=(?P<v>\d)`, `${v}:${k}`, "7:id"},
		{"cost 5", `(\d)`, `$$$1`, "cost $5"},
	}
	for _, c := range cases {
		got, _, err := ReplaceText(c.text, SearchQuery{Query: c.query, Regex: true}, c.with)
		if err != nil || got != c.want {
			t.Fatalf("%s → %s: got %q, %v", c.query, c.with, got, err)
		}
	}
}

// Review Focus 2: with .* off, the replacement is text, never a template.
func TestReplaceTextLiteralReplacementIsNotExpanded(t *testing.T) {
	got, n, err := ReplaceText("a b", SearchQuery{Query: "a"}, "$1$$")
	if err != nil || got != "$1$$ b" || n != 1 {
		t.Fatalf("got %q, %d, %v", got, n, err)
	}
}

// Review Focus 3: a pattern means what search found — per line, never across one, empty matches never.
func TestReplaceTextIsLineByLineLikeSearch(t *testing.T) {
	if got, n, _ := ReplaceText("foo\nfoo\n", SearchQuery{Query: `^foo$`, Regex: true}, "x"); got != "x\nx\n" || n != 2 {
		t.Fatalf("anchors: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("ab\n", SearchQuery{Query: `x*`, Regex: true}, "-"); got != "ab\n" || n != 0 {
		t.Fatalf("empty matches: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("fo\nof\n", SearchQuery{Query: `o\no`, Regex: true}, "-"); got != "fo\nof\n" || n != 0 {
		t.Fatalf("across a line: got %q, %d", got, n)
	}
}

func TestReplaceTextLeavingTheTextTheSameCountsNothing(t *testing.T) {
	if got, n, _ := ReplaceText("foo", SearchQuery{Query: "foo"}, "foo"); got != "foo" || n != 0 {
		t.Fatalf("same: got %q, %d", got, n)
	}
	if got, n, _ := ReplaceText("FOO", SearchQuery{Query: "foo"}, "foo"); got != "foo" || n != 1 {
		t.Fatalf("case: got %q, %d", got, n)
	}
}

func TestReplaceEditsAreUTF16Offsets(t *testing.T) {
	// "😀 foo\n" is 2 + 1 units before foo, then foo (3) and "\n": line 2 starts at 7, and "حجز " is 4.
	edits, err := ReplaceEdits("😀 foo\nحجز foo", SearchQuery{Query: "foo"}, "bar")
	want := []ReplaceEdit{{Start: 3, End: 6, Text: "bar"}, {Start: 11, End: 14, Text: "bar"}}
	if err != nil || !slices.Equal(edits, want) {
		t.Fatalf("got %+v, %v", edits, err)
	}
}

func TestReplaceTextAnInvalidRegexIsGosOwnError(t *testing.T) {
	if _, _, err := ReplaceText("x", SearchQuery{Query: "book(", Regex: true}, "y"); err == nil ||
		!strings.Contains(err.Error(), "missing closing )") {
		t.Fatalf("got %v", err)
	}
}

func readText(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestFilesReplaceWritesEveryMatchPastTheSearchCap(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "many.txt")
	write(t, p, strings.Repeat("x\n", SearchCap+5))
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "x"}, "y", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || r.Files[0].Count != SearchCap+5 || r.Next != "" {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, p) != strings.Repeat("y\n", SearchCap+5) {
		t.Fatal("not every match was replaced")
	}
}

func TestFilesReplaceSkipsWhatSearchSkips(t *testing.T) {
	a, b := searchFixture(t)
	write(t, filepath.Join(a, "bin.dat"), "bookingId\x00")
	write(t, filepath.Join(b, "big.txt"), "bookingId\n"+strings.Repeat("y", FileCap))
	r, err := ReplaceFiles(context.Background(), []string{a, b}, HeavyNames(nil), SearchQuery{Query: "bookingId"}, "booking_id", ReplaceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, f := range r.Files {
		got = append(got, fmt.Sprintf("%s:%d", filepath.Base(filepath.Dir(f.Path))+"/"+filepath.Base(f.Path), f.Count))
	}
	if strings.Join(got, ",") != "a/Booking.php:2,b/routes.ts:1" {
		t.Fatalf("got %v", got)
	}
	if readText(t, filepath.Join(a, ".env")) != "bookingId=secret\n" || !strings.HasPrefix(readText(t, filepath.Join(b, "big.txt")), "bookingId") {
		t.Fatal("an ignored or over-cap file was written")
	}
}

func TestFilesReplaceIsConfinedToTheRoots(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "secret.txt"), "needle\n")
	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(a, "link.txt")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(a, "ok.txt"), "needle\n")
	q := SearchQuery{Query: "needle"}
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), q, "pin", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || readText(t, filepath.Join(outside, "secret.txt")) != "needle\n" {
		t.Fatalf("got %+v, %v", r, err)
	}
	for _, o := range []ReplaceOptions{{Only: filepath.Join(a, "link.txt")}, {Roots: []string{outside}}} {
		if _, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), q, "pin", o); err == nil ||
			!strings.Contains(err.Error(), "is outside the active project's roots") {
			t.Fatalf("%+v: got %v", o, err)
		}
	}
}

func TestFilesReplaceLeavesSkippedFilesReportsThemAndOnlyNamesOne(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	two := filepath.Join(a, "2.txt")
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new",
		ReplaceOptions{Skip: []string{two, "/nowhere/x"}})
	if err != nil || len(r.Files) != 2 || !slices.Equal(r.Skipped, []string{two}) || readText(t, two) != "old\n" {
		t.Fatalf("got %+v, %v", r, err)
	}
	r, err = ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{Only: two})
	if err != nil || len(r.Files) != 1 || r.Files[0].Path != two || readText(t, two) != "new\n" {
		t.Fatalf("only: got %+v, %v", r, err)
	}
}

func TestFilesReplaceStopsBetweenFilesWhenCancelled(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	ctx, cancel := context.WithCancel(context.Background())
	replaceAfterWrite = cancel
	t.Cleanup(func() { replaceAfterWrite = nil })
	r, err := ReplaceFiles(ctx, []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	if err != nil || !r.Cancelled || len(r.Files) != 1 || r.Files[0].Path != filepath.Join(a, "1.txt") {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, filepath.Join(a, "2.txt")) != "old\n" {
		t.Fatal("a file after the cancel was written")
	}
}

func TestFilesReplaceListsAFailedWriteAndGoesOn(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	two := filepath.Join(a, "2.txt")
	if err := os.Chmod(two, 0o444); err != nil {
		t.Fatal(err)
	}
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	if err != nil || len(r.Files) != 2 || len(r.Failures) != 1 || r.Failures[0].Path != two ||
		!strings.Contains(r.Failures[0].Error, "is not writable") {
		t.Fatalf("got %+v, %v", r, err)
	}
	if readText(t, two) != "old\n" || readText(t, filepath.Join(a, "3.txt")) != "new\n" {
		t.Fatal("the failed file changed, or the next one was not written")
	}
}

func TestFilesReplaceAnswersTheOriginalAndMtimeAndKeepsTheMode(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "run.sh")
	write(t, p, "echo old\n")
	if err := os.Chmod(p, 0o755); err != nil {
		t.Fatal(err)
	}
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	st, serr := os.Stat(p)
	if err != nil || serr != nil || len(r.Files) != 1 || r.Files[0].Original != "echo old\n" ||
		r.Files[0].Mtime != st.ModTime().UnixNano() || st.Mode().Perm() != 0o755 {
		t.Fatalf("got %+v, %v, mode %v", r, err, st.Mode())
	}
}

// Review Focus 4.
func TestFilesReplaceKeepsCRLF(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "win.txt")
	write(t, p, "old one\r\nold two\r\n")
	if _, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := readText(t, p); got != "new one\r\nnew two\r\n" {
		t.Fatalf("got %q", got)
	}
}

func TestFilesReplaceInBatchesResumesAfterNext(t *testing.T) {
	a, b, _ := filesRoots(t)
	for _, p := range []string{filepath.Join(a, "1.txt"), filepath.Join(a, "2.txt"), filepath.Join(b, "3.txt")} {
		write(t, p, "old\n")
	}
	var got []string
	after, calls := "", 0
	for {
		r, err := ReplaceFiles(context.Background(), []string{a, b}, HeavyNames(nil), SearchQuery{Query: "old"}, "new",
			ReplaceOptions{After: after, MaxFiles: 1})
		if err != nil {
			t.Fatal(err)
		}
		calls++
		for _, f := range r.Files {
			got = append(got, filepath.Base(f.Path))
		}
		if r.Next == "" || calls > 10 {
			break
		}
		after = r.Next
	}
	if strings.Join(got, ",") != "1.txt,2.txt,3.txt" || calls != 3 {
		t.Fatalf("got %v in %d calls", got, calls)
	}
}

// Pre-flight F3: a resumed call re-lists its root, and the listing must not spend the batch's time.
func TestFilesReplaceTheBatchClockExcludesTheListing(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, n := range []string{"1.txt", "2.txt", "3.txt", "4.txt", "5.txt"} {
		write(t, filepath.Join(a, n), "old\n")
	}
	defer func(d time.Duration) { ReplaceBatchTime = d }(ReplaceBatchTime)
	ReplaceBatchTime = 50 * time.Millisecond
	replaceAfterList = func() { time.Sleep(120 * time.Millisecond) } // a slow listing, longer than the budget
	t.Cleanup(func() { replaceAfterList = nil })
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "old"}, "new", ReplaceOptions{MaxFiles: 50})
	if err != nil || len(r.Files) != 5 || r.Next != "" {
		t.Fatalf("got %d files, next %q, %v: the listing spent the budget", len(r.Files), r.Next, err)
	}
}

// A replace covers what a search covers: the project's heavy folders are never written.
func TestReplaceSkipsTheProjectsHeavyFolders(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, ".gitignore"), "storage/\n")
	write(t, filepath.Join(a, "app.php"), "old")
	write(t, filepath.Join(a, "storage", "l.log"), "old")
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames([]string{"storage"}), SearchQuery{Query: "old"}, "new", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || filepath.Base(r.Files[0].Path) != "app.php" {
		t.Fatalf("files %+v, %v", r.Files, err)
	}
	if b, _ := os.ReadFile(filepath.Join(a, "storage", "l.log")); string(b) != "old" {
		t.Fatalf("heavy folder written: %q", b)
	}
}

// Review: a link to a listed file is replaced once, through the target's own listing.
func TestFilesReplaceSkipsALinkToAListedFile(t *testing.T) {
	a, _, _ := filesRoots(t)
	target := filepath.Join(a, "b.txt")
	write(t, target, "foo\n")
	if err := os.Symlink(target, filepath.Join(a, "a.txt")); err != nil {
		t.Fatal(err)
	}
	r, err := ReplaceFiles(context.Background(), []string{a}, HeavyNames(nil), SearchQuery{Query: "foo"}, "foo2", ReplaceOptions{})
	if err != nil || len(r.Files) != 1 || r.Files[0].Path != target || readText(t, target) != "foo2\n" {
		t.Fatalf("got %+v, %v, disk %q", r, err, readText(t, target))
	}
}

// Final review C1: the app names the roots it claimed on every call. A root of the active project
// that is missing on disk is still one of its roots: the call goes through and lists it, as an
// unnamed call does, rather than refusing the whole replace.
func TestFilesReplaceNamingAMissingRootOfTheProjectListsIt(t *testing.T) {
	a, _, _ := filesRoots(t)
	missing := filepath.Join(t.TempDir(), "gone")
	write(t, filepath.Join(a, "1.txt"), "old\n")
	r, err := ReplaceFiles(context.Background(), []string{a, missing}, HeavyNames(nil), SearchQuery{Query: "old"}, "new",
		ReplaceOptions{Roots: []string{a, missing}})
	if err != nil || len(r.Files) != 1 || len(r.Failures) != 1 || r.Failures[0].Path != missing {
		t.Fatalf("got %+v, %v", r, err)
	}
}

func TestListFilesReportsEmptyFoldersOutsideARepository(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "full", "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "hollow", "deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"hollow/deeper"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}

func TestListFilesReportsEmptyFoldersInARepository(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a) // the helper the repo listing tests already use
	write(t, filepath.Join(a, "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "made"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"made"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}

// git collapses an untracked folder to its top ("made/deeper" comes back as "made/"): the listing
// walks it to find the empty folder inside.
func TestListFilesReportsANestedEmptyFolderInARepository(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "made", "deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"made/deeper"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}

func TestListFilesReportsAnEmptyFolderInsideAnUntrackedFolderHoldingAFile(t *testing.T) {
	a, _, _ := filesRoots(t)
	gitInit(t, a)
	write(t, filepath.Join(a, "f.txt"), "x")
	write(t, filepath.Join(a, "src", "newdir", "f.txt"), "x")
	if err := os.MkdirAll(filepath.Join(a, "src", "newdir", "inner"), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := ListFiles(context.Background(), a, []string{a}, HeavyNames(nil))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(l.Empty, []string{"src/newdir/inner"}) {
		t.Fatalf("empty %v", l.Empty)
	}
}

func TestFilesSearchNamesTheLargeFilesItSkipped(t *testing.T) {
	a, b := searchFixture(t)
	write(t, filepath.Join(a, "storage", "laravel.log"), strings.Repeat("bookingId\n", FileCap/9))
	r, err := SearchFiles(context.Background(), []string{a, b}, testHeavy, nil, SearchQuery{Query: "bookingId"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(r.SkippedLarge, ",") != "storage/laravel.log" {
		t.Fatalf("skipped %v", r.SkippedLarge)
	}
}
