package wakilcore

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateEntryMakesAFileAndItsParents(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "x", "y", "n.go")
	e, err := CreateEntry(p, "file", []string{a})
	if err != nil || e.Kind != "file" || e.Root != a {
		t.Fatalf("got %+v %v", e, err)
	}
	if got, _ := os.ReadFile(p); len(got) != 0 {
		t.Fatalf("not empty: %q", got)
	}
}

func TestCreateEntryMakesAFolder(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "d")
	if _, err := CreateEntry(p, "dir", []string{a}); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(p); err != nil || !fi.IsDir() {
		t.Fatalf("no folder: %v", err)
	}
}

func TestCreateEntryRefusesAnExistingName(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "keep")
	if _, err := CreateEntry(p, "file", []string{a}); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("err %v", err)
	}
	if got, _ := os.ReadFile(p); string(got) != "keep" {
		t.Fatal("overwrote")
	}
}

func TestCreateEntryRefusesOutsideTheRootsAndThroughALink(t *testing.T) {
	a, _, outside := filesRoots(t)
	if _, err := CreateEntry(filepath.Join(outside, "f"), "file", []string{a}); err == nil {
		t.Fatal("created outside")
	}
	if err := os.Symlink(outside, filepath.Join(a, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateEntry(filepath.Join(a, "escape", "f"), "file", []string{a}); err == nil {
		t.Fatal("created through a link")
	}
	if _, err := os.Stat(filepath.Join(outside, "f")); err == nil {
		t.Fatal("a file landed outside")
	}
}

func TestCreateEntryRefusesDotNamesAndABadKind(t *testing.T) {
	a, _, _ := filesRoots(t)
	for _, p := range []string{a + "/..", a + "/."} {
		if _, err := CreateEntry(p, "dir", []string{a}); err == nil {
			t.Fatalf("made %s", p)
		}
	}
	if _, err := CreateEntry(filepath.Join(a, "k"), "link", []string{a}); err == nil {
		t.Fatal("kind link accepted")
	}
}

func TestMoveEntryRenamesAndCreatesParents(t *testing.T) {
	a, _, _ := filesRoots(t)
	from := filepath.Join(a, "a.go")
	write(t, from, "x")
	to := filepath.Join(a, "sub", "b.go")
	m, err := MoveEntry(from, to, []string{a})
	if err != nil || m.Kind != "file" {
		t.Fatalf("got %+v %v", m, err)
	}
	if got, _ := os.ReadFile(to); string(got) != "x" {
		t.Fatal("not moved")
	}
}

func TestMoveEntryAcrossRootsAndAFolder(t *testing.T) {
	a, b, _ := filesRoots(t)
	write(t, filepath.Join(a, "d", "f.txt"), "x")
	if _, err := MoveEntry(filepath.Join(a, "d"), filepath.Join(b, "d2"), []string{a, b}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(b, "d2", "f.txt")); string(got) != "x" {
		t.Fatal("folder not moved")
	}
}

func TestMoveEntryCaseOnlyRenameWorks(t *testing.T) {
	a, _, _ := filesRoots(t)
	write(t, filepath.Join(a, "user.php"), "x")
	if _, err := MoveEntry(filepath.Join(a, "user.php"), filepath.Join(a, "User.php"), []string{a}); err != nil {
		t.Fatal(err)
	}
	names, _ := os.ReadDir(a)
	if len(names) != 1 || names[0].Name() != "User.php" {
		t.Fatalf("names %v", names)
	}
}

func TestMoveEntrySameNameIsIgnored(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	if _, err := MoveEntry(p, p, []string{a}); err != nil {
		t.Fatal(err)
	}
}

func TestMoveEntryRefusesAnExistingTargetIntoItselfARootAndOutside(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(a, "f"), "1")
	write(t, filepath.Join(a, "g"), "2")
	write(t, filepath.Join(a, "d", "x"), "3")
	cases := [][2]string{
		{filepath.Join(a, "f"), filepath.Join(a, "g")},
		{filepath.Join(a, "d"), filepath.Join(a, "d", "e", "d")},
		{a, filepath.Join(a, "r")},
		{filepath.Join(a, "f"), filepath.Join(outside, "f")},
		{filepath.Join(a, "nope"), filepath.Join(a, "n2")},
	}
	for _, c := range cases {
		if _, err := MoveEntry(c[0], c[1], []string{a}); err == nil {
			t.Fatalf("moved %s -> %s", c[0], c[1])
		}
	}
	if got, _ := os.ReadFile(filepath.Join(a, "g")); string(got) != "2" {
		t.Fatal("overwrote g")
	}
}

func TestMoveEntryMovesALinkAsItself(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "t"), "out")
	if err := os.Symlink(filepath.Join(outside, "t"), filepath.Join(a, "l")); err != nil {
		t.Fatal(err)
	}
	if _, err := MoveEntry(filepath.Join(a, "l"), filepath.Join(a, "l2"), []string{a}); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Lstat(filepath.Join(a, "l2")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("link not moved as a link")
	}
	if _, err := os.Stat(filepath.Join(outside, "t")); err != nil {
		t.Fatal("target touched")
	}
}

// fakeTrash points trashBin at a script that records its arguments and removes the path.
func fakeTrash(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "trash")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" + bin + ".args\"\nrm -rf \"$2\"\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	old := trashBin
	trashBin = bin
	t.Cleanup(func() { trashBin = old })
	return bin + ".args"
}

func TestTrashEntryRunsTheTrashOnTheConfinedPath(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	args := fakeTrash(t)
	if _, err := TrashEntry(context.Background(), p, []string{a}); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(args)
	if string(got) != "-s\n"+p+"\n" {
		t.Fatalf("args %q", got)
	}
}

func TestTrashEntryTrashesALinkNotItsTarget(t *testing.T) {
	a, _, outside := filesRoots(t)
	write(t, filepath.Join(outside, "t"), "out")
	l := filepath.Join(a, "l")
	if err := os.Symlink(filepath.Join(outside, "t"), l); err != nil {
		t.Fatal(err)
	}
	args := fakeTrash(t)
	if _, err := TrashEntry(context.Background(), l, []string{a}); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(args); string(got) != "-s\n"+l+"\n" {
		t.Fatalf("args %q", got)
	}
}

func TestTrashEntryRefusesARootOutsideAndAMissingPath(t *testing.T) {
	a, _, outside := filesRoots(t)
	fakeTrash(t)
	write(t, filepath.Join(outside, "f"), "x")
	for _, p := range []string{a, filepath.Join(outside, "f"), filepath.Join(a, "nope")} {
		if _, err := TrashEntry(context.Background(), p, []string{a}); err == nil {
			t.Fatalf("trashed %s", p)
		}
	}
}

func TestTrashEntryWithoutTheBinarySaysMacOS15(t *testing.T) {
	a, _, _ := filesRoots(t)
	p := filepath.Join(a, "f")
	write(t, p, "x")
	old := trashBin
	trashBin = filepath.Join(t.TempDir(), "missing")
	t.Cleanup(func() { trashBin = old })
	_, err := TrashEntry(context.Background(), p, []string{a})
	if err == nil || err.Error() != "Move to Trash needs macOS 15: "+trashBin+" is missing" {
		t.Fatalf("err %v", err)
	}
}
