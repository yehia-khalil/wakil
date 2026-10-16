package driver_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// fakeTree stands in for a commit: a path-to-content map, read the way
// GitTree reads a real one.
type fakeTree map[string]string

func (f fakeTree) Files(dir string) ([]string, error) {
	var paths []string
	for path := range f {
		if strings.HasPrefix(path, dir) {
			paths = append(paths, path)
		}
	}
	return paths, nil
}

func (f fakeTree) Read(path string) ([]byte, error) {
	content, ok := f[path]
	if !ok {
		return nil, fmt.Errorf("no %s in this tree", path)
	}
	return []byte(content), nil
}

// **Newness is a question only git can answer, and this is the whole of how
// it is asked.** An action is new when the commit this branch forked from had
// never heard of its name.
func TestNewActionsAreTheOnesTheBaseTreeNeverNamed(t *testing.T) {
	base, err := driver.TreeSources(fakeTree{
		"app/Sources/WakilKit/Registry/StandardActions.swift": `
			Action(name: "term_open", description: "open a shell", kind: .control)
		`,
	}, "app/Sources")
	if err != nil {
		t.Fatal(err)
	}
	fresh := driver.NewActions([]driver.Tool{
		{Name: "term_open", ReadOnly: false},
		{Name: "term_close", ReadOnly: false},
	}, base)
	if len(fresh) != 1 || fresh[0].Name != "term_close" {
		t.Fatalf("new actions are %+v, want term_close alone", fresh)
	}
}

// A name that occurs in the base tree as something OTHER than a string
// literal is not the action being registered. `termOpen` the symbol and
// `"term_open"` the name are different things, and only the second says the
// action was there.
func TestAnActionNameIsMatchedAsALiteralAndNotAsAWord(t *testing.T) {
	base, err := driver.TreeSources(fakeTree{
		"app/Sources/WakilKit/App/WindowModel.swift": `
			// term_close is coming in a later task.
			func term_close() {}
		`,
	}, "app/Sources")
	if err != nil {
		t.Fatal(err)
	}
	fresh := driver.NewActions([]driver.Tool{{Name: "term_close"}}, base)
	if len(fresh) != 1 {
		t.Fatalf("a mention in a comment retired an action from the gate: %+v", fresh)
	}
}

// **A base tree that reads as empty is a fault, not a branch that invented
// the whole app.** Every action and every identifier would count as new, the
// gate would name forty of them, and a gate that fires forty times on its
// first run is a gate somebody switches off that afternoon.
func TestAnEmptyBaseTreeIsRefusedRatherThanTreatedAsNothingHavingExisted(t *testing.T) {
	if _, err := driver.TreeSources(fakeTree{}, "app/Sources"); err == nil {
		t.Fatal("a tree with no sources under the directory was accepted as a base")
	}
	if _, err := driver.TreeIdentifiers(fakeTree{}, "app/Sources/WakilApp"); err == nil {
		t.Fatal("a tree with no sources was accepted as an identifier baseline")
	}
}

// Only Swift sources are read. A tree carries `.metallib` and whatever else
// sits beside the code, and `git show` on a binary is neither useful nor
// cheap.
func TestOnlySwiftSourcesAreRead(t *testing.T) {
	sources, err := driver.TreeSources(fakeTree{
		"app/Sources/WakilApp/Rail.swift":       `Action(name: "pane_move")`,
		"app/Sources/WakilApp/default.metallib": "\x00\x01binary",
		"app/Sources/WakilApp/notes.md":         `"pane_close"`,
	}, "app/Sources")
	if err != nil {
		t.Fatal(err)
	}
	if !sources.Mentions("pane_move") {
		t.Error("a Swift source was not read")
	}
	if sources.Mentions("pane_close") {
		t.Error("a name was taken from a file that is not Swift source")
	}
}

func TestNewIdentifiersAreTheOnesTheBaseDidNotCarry(t *testing.T) {
	base := []driver.Identifier{
		{Name: "rail.terminal", File: "Rail.swift", Line: 10},
		{Name: "pane.<…>.close", File: "WakilWindow.swift", Line: 20},
	}
	head := append([]driver.Identifier{
		{Name: "landing.open", File: "Landing.swift", Line: 4},
		{Name: "pane.<…>.reopen", File: "WakilWindow.swift", Line: 30},
	}, base...)

	fresh := driver.NewIdentifiers(head, base)
	got := names(fresh)
	assertSameSet(t, got, []string{"landing.open", "pane.<…>.reopen"})
}

// The same identifier appearing at two call sites is one name and one gate
// entry — `OrgPlane.button(_:id:)` draws four Cancel buttons and each carries
// its own — so a branch that moves a control between files owes one check,
// not two failures.
func TestANewIdentifierIsReportedOncePerName(t *testing.T) {
	fresh := driver.NewIdentifiers([]driver.Identifier{
		{Name: "org.create.cancel", File: "OrgPlane.swift", Line: 10},
		{Name: "org.create.cancel", File: "OrgPlane.swift", Line: 90},
	}, []driver.Identifier{{Name: "rail.terminal"}})
	if len(fresh) != 1 {
		t.Fatalf("one name was reported %d times: %v", len(fresh), names(fresh))
	}
}

// GitTree against this very repository: the base of `HEAD` is `HEAD`, and the
// sources it reads are the ones on disk. It is the one test that proves the
// two git invocations are spelled correctly, and it is skipped where git is
// not.
func TestGitTreeReadsThisRepository(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	tree := driver.GitTree{Repo: "../..", Commit: "HEAD"}
	files, err := tree.Files(driver.AppSourceRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatalf("%s holds no files at HEAD", driver.AppSourceRoot)
	}
	identifiers, err := driver.TreeIdentifiers(tree, driver.AppSourceRoot)
	if err != nil {
		t.Fatal(err)
	}
	if len(identifiers) == 0 {
		t.Fatal("HEAD carries no identifiers at all, which the gate reads as a zero denominator")
	}
}

// **A name quoted inside a comment is not the action having existed.** The
// likeliest shape is a comment planning the work — "`term_close` is coming in a
// later task" with the name in quotes — and reading it as the action being
// already there marks a genuinely new action old and drops it from the gate
// silently, which is the flattering direction this whole file is written
// against.
func TestABaseTreeMentionInACommentDoesNotRetireAnActionFromTheGate(t *testing.T) {
	base, err := driver.TreeSources(fakeTree{
		"app/Sources/WakilKit/Registry/StandardActions.swift": `
			/// A later task adds "term_close" beside it.
			// and "term_scroll" after that
			Action(name: "term_open", description: "open a shell", kind: .control)
		`,
	}, "app/Sources")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"term_close", "term_scroll"} {
		if base.Mentions(name) {
			t.Errorf("%s was read as already registered, out of a comment", name)
		}
	}
	if !base.Mentions("term_open") {
		t.Error("the registered action was lost with the comments")
	}
}

// **The head harvest and the base harvest must read the same file set.**
// `git ls-tree -r` descends, and the head harvester used to stop at the top
// level of the directory: the first subdirectory under WakilApp would make
// head miss controls the base carries, so a new control there would never read
// as new and the gate would pass by being blind.
func TestBothHarvestsDescendIntoSubdirectories(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "Panes"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Rail.swift"),
		[]byte(`.accessibilityIdentifier("rail.terminal")`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Panes", "Deep.swift"),
		[]byte(`.accessibilityIdentifier("pane.deep.close")`), 0o644); err != nil {
		t.Fatal(err)
	}
	found, err := driver.HarvestIdentifiers(root)
	if err != nil {
		t.Fatal(err)
	}
	assertSameSet(t, names(found), []string{"rail.terminal", "pane.deep.close"})

	fromTree, err := driver.TreeIdentifiers(fakeTree{
		"app/Sources/WakilApp/Rail.swift":       `.accessibilityIdentifier("rail.terminal")`,
		"app/Sources/WakilApp/Panes/Deep.swift": `.accessibilityIdentifier("pane.deep.close")`,
	}, "app/Sources/WakilApp")
	if err != nil {
		t.Fatal(err)
	}
	assertSameSet(t, names(fromTree), []string{"rail.terminal", "pane.deep.close"})
}
