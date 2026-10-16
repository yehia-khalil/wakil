package scripts

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The architecture docs are the map of the code (docs/architecture/), so a folder
// or binary missing from them is a hole in the map. Each WakilKit folder needs a
// "### <Folder>/" heading in wakilkit.md; each cmd/ binary a "### <name>" and each
// internal/ package a "### internal/<name>" heading in go.md.

// headingWords returns the first word of every "### " heading in doc.
func headingWords(doc string) map[string]bool {
	words := map[string]bool{}
	for _, line := range strings.Split(doc, "\n") {
		if rest, ok := strings.CutPrefix(line, "### "); ok {
			if fields := strings.Fields(rest); len(fields) > 0 {
				words[fields[0]] = true
			}
		}
	}
	return words
}

// subdirs returns the names of the directories directly under dir.
func subdirs(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("reading %s: %v", dir, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// undocumentedIn returns the "want" headings that doc does not have.
func undocumentedIn(doc string, want []string) []string {
	have := headingWords(doc)
	var missing []string
	for _, w := range want {
		if !have[w] {
			missing = append(missing, w)
		}
	}
	return missing
}

// architectureGaps lists every folder, binary and package under root that the
// docs under root/docs/architecture do not give a heading.
func architectureGaps(t *testing.T, root string) []string {
	t.Helper()
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(root, "docs", "architecture", name))
		if err != nil {
			t.Fatalf("the architecture reference is missing %s: %v", name, err)
		}
		return string(b)
	}
	var folders, goWant []string
	for _, f := range subdirs(t, filepath.Join(root, "app", "Sources", "WakilKit")) {
		folders = append(folders, f+"/")
	}
	goWant = append(goWant, subdirs(t, filepath.Join(root, "cmd"))...)
	for _, p := range subdirs(t, filepath.Join(root, "internal")) {
		goWant = append(goWant, "internal/"+p)
	}
	gaps := undocumentedIn(read("wakilkit.md"), folders)
	for _, g := range undocumentedIn(read("go.md"), goWant) {
		gaps = append(gaps, g)
	}
	return gaps
}

func TestArchitectureDocsCatchAnUndocumentedFolder(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{
		"app/Sources/WakilKit/Core", "app/Sources/WakilKit/Panes",
		"cmd/wakil-a", "internal/base", "docs/architecture",
	} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(root, "docs", "architecture", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("wakilkit.md", "# WakilKit\n\n### Core/ — shared vocabulary\n")
	write("go.md", "# Go\n\n### wakil-a\n\n### internal/base\n")
	got := architectureGaps(t, root)
	if len(got) != 1 || got[0] != "Panes/" {
		t.Fatalf("gaps = %v, want [Panes/]", got)
	}
}

func TestArchitectureDocsCoverEveryFolderAndBinary(t *testing.T) {
	if gaps := architectureGaps(t, repoRoot(t)); len(gaps) > 0 {
		t.Fatalf("docs/architecture has no heading for: %s\n"+
			"Add a \"### <name>\" section (wakilkit.md for a WakilKit folder, go.md for a binary or "+
			"internal package) saying what it is for, its key types, and what it may use.",
			strings.Join(gaps, ", "))
	}
}
