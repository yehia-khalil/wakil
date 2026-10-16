package driver_test

import (
	"slices"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

const (
	orgPlane = "e2e/checks/unseeded/org-plane.jsonl"
	terminal = "e2e/checks/seeded/terminal.jsonl"
	reopen   = "e2e/checks/seeded/reopen.jsonl"
	closer   = "e2e/checks/agent/close.jsonl"
)

// selectionCorpus is four checks: the org plane, one that clicks a static
// identifier, one that clicks a member of a dynamic family, one that
// dispatches an action.
func selectionCorpus(t *testing.T) map[string]driver.Check {
	t.Helper()
	return map[string]driver.Check{
		orgPlane: parse(t, "org-plane.jsonl", `{"expect":{"tree":"contains","text":"Wakil"}}`)[0],
		terminal: parse(t, "terminal.jsonl", `{"do":{"click":"window.openTerminal"}}`)[0],
		reopen:   parse(t, "reopen.jsonl", `{"do":{"click":"pane.db-1.reopen"}}`)[0],
		closer:   parse(t, "close.jsonl", `{"dispatch":{"action":"term_close","params":{}}}`)[0],
	}
}

func picked(s driver.Selection) []string { return s.Files() }

func TestAnEmptyDiffSelectsOnlyTheOrgPlane(t *testing.T) {
	got := driver.SelectChecks(nil, selectionCorpus(t))
	if want := []string{orgPlane}; !slices.Equal(picked(got), want) {
		t.Fatalf("picked %v, want %v", picked(got), want)
	}
	if got.Mode != driver.SelectModeSelected {
		t.Fatalf("mode %q", got.Mode)
	}
}

func TestAChangedCheckSelectsItself(t *testing.T) {
	got := driver.SelectChecks([]driver.ChangedFile{{Path: reopen, Status: "M"}}, selectionCorpus(t))
	if !got.Has(reopen) || got.Has(terminal) {
		t.Fatalf("picked %v", picked(got))
	}
}

func TestADeletedCheckSelectsNothingAndIsNotUnmapped(t *testing.T) {
	gone := "e2e/checks/seeded/gone.jsonl"
	got := driver.SelectChecks([]driver.ChangedFile{{Path: gone, Status: "D"}}, selectionCorpus(t))
	if got.Has(gone) || len(got.Unmapped) != 0 {
		t.Fatalf("picked %v, unmapped %v", picked(got), got.Unmapped)
	}
}

func TestAStaticIdentifierSelectsTheCheckThatPressesIt(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilApp/Window.swift", Status: "M",
		After: `Button("Open") {}.accessibilityIdentifier("window.openTerminal")`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if !got.Has(terminal) || got.Has(reopen) {
		t.Fatalf("picked %v", picked(got))
	}
	reasons := strings.Join(reasonsFor(got, terminal), "; ")
	if !strings.Contains(reasons, "Window.swift") || !strings.Contains(reasons, "window.openTerminal") {
		t.Fatalf("reason does not name the file and identifier: %q", reasons)
	}
}

func TestADynamicIdentifierSelectsTheCheckThatPressesAMember(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilApp/Pane.swift", Status: "M",
		After: `Button("Reopen") {}.accessibilityIdentifier("pane.\(pane.id).reopen")`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if !got.Has(reopen) {
		t.Fatalf("picked %v", picked(got))
	}
}

func TestAnIdentifierOnlyInTheBaseStillSelects(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilApp/Window.swift", Status: "M",
		Before: `Button("Open") {}.accessibilityIdentifier("window.openTerminal")`,
		After:  `Text("removed")`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if !got.Has(terminal) {
		t.Fatalf("a removed identifier must select the checks it breaks; picked %v", picked(got))
	}
}

func TestAQuotedActionNameSelectsTheCheckThatDispatchesIt(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilKit/TermActions.swift", Status: "M",
		After: `registry.register(name: "term_close") { _ in }`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if !got.Has(closer) {
		t.Fatalf("picked %v", picked(got))
	}
}

func TestAnActionNamedOnlyInACommentSelectsNothing(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilKit/TermActions.swift", Status: "M",
		After: `// see "term_close"
let x = 1`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if got.Has(closer) {
		t.Fatal("a name in a comment is not the action")
	}
	if !slices.Contains(got.Unmapped, change.Path) {
		t.Fatalf("unmapped %v", got.Unmapped)
	}
}

func TestFilesNoCheckReachesAreUnmapped(t *testing.T) {
	changes := []driver.ChangedFile{
		{Path: "app/Sources/WakilKit/Model.swift", Status: "M", After: "struct Model {}"},
		{Path: "internal/wakilcore/core.go", Status: "M", After: "package wakilcore"},
	}
	got := driver.SelectChecks(changes, selectionCorpus(t))
	want := []string{"app/Sources/WakilKit/Model.swift", "internal/wakilcore/core.go"}
	if !slices.Equal(got.Unmapped, want) {
		t.Fatalf("unmapped %v, want %v", got.Unmapped, want)
	}
}

func TestAnIdentifierNoCheckPressesIsMappedButHasNoCheck(t *testing.T) {
	change := driver.ChangedFile{Path: "app/Sources/WakilApp/Window.swift", Status: "M",
		After: `Button("New") {}.accessibilityIdentifier("window.unpressed")`}
	got := driver.SelectChecks([]driver.ChangedFile{change}, selectionCorpus(t))
	if !slices.Equal(got.NoCheck, []string{change.Path}) || len(got.Unmapped) != 0 {
		t.Fatalf("noCheck %v, unmapped %v", got.NoCheck, got.Unmapped)
	}
}

func TestDocsProofsAndTestsAreIgnored(t *testing.T) {
	changes := []driver.ChangedFile{
		{Path: "docs/wakil/north-star.md", Status: "M"},
		{Path: "README.md", Status: "M"},
		{Path: "e2e/checks/proofs/reopen.json", Status: "A"},
		{Path: "app/Tests/WakilKitTests/ModelTests.swift", Status: "M"},
		{Path: "internal/wakilcore/files_test.go", Status: "M"},
	}
	got := driver.SelectChecks(changes, selectionCorpus(t))
	if len(got.Ignored) != 5 || len(got.Unmapped) != 0 {
		t.Fatalf("ignored %v, unmapped %v", got.Ignored, got.Unmapped)
	}
}

func TestPicksComeInLaunchOrder(t *testing.T) {
	changes := []driver.ChangedFile{
		{Path: closer, Status: "M"}, {Path: terminal, Status: "M"}, {Path: reopen, Status: "M"},
	}
	got := driver.SelectChecks(changes, selectionCorpus(t))
	want := []string{orgPlane, reopen, terminal, closer}
	if !slices.Equal(picked(got), want) {
		t.Fatalf("order %v, want %v", picked(got), want)
	}
}

func reasonsFor(s driver.Selection, file string) []string {
	for _, p := range s.Picks {
		if p.Check == file {
			return p.Reasons
		}
	}
	return nil
}
