# e2e selected run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make e2e` runs only the checks the branch's diff reaches (minutes, not 22), `make e2e-full` runs everything once before merge, and the runbook says which of the two happened.

**Architecture:** A pure `driver.SelectChecks(changes, corpus)` maps changed files to checks through what the harness already reads — check files, harvested identifiers (`IdentifiersIn` + `Coverage.Exercises`) and quoted action names (`Sources.Mentions` + `Coverage.Dispatches`). A small command `wakil-e2e-select` reads git, writes `.context/e2e/select/latest.json` and prints the files; one Makefile loop runs them. `MachineWalk` reads the selection record and renders unselected, unrun checks as *owed to `make e2e-full`*, which is not a fault.

**Tech Stack:** Go (`e2e/driver`, `e2e/cmd`), GNU make, git.

**Spec:** `docs/superpowers/specs/2026-10-15-e2e-selected-run-design.md`

## Global Constraints

- The diff is `base...HEAD` with `base = driver.MergeBase(repo, E2E_TRUNK)`, `E2E_TRUNK` default `origin/main`. Never `origin/main`'s tip.
- `e2e/checks/unseeded/org-plane.jsonl` is selected on every selected run, reason *always*.
- Ignored paths: anything under `docs/` or `e2e/checks/proofs/`, and any `*.md`.
- Launch order: unseeded, seeded, agent (`launchDirs` order); within a directory, by path.
- Record path: `<evidence root>/select/latest.json`, evidence root `driver.DefaultEvidenceRoot` (`.context/e2e`).
- Modes: `selected`, `named` (`E2E_ONLY`), `full` (`make e2e-full`).
- `e2e/driver` stays in `make test` and needs no GUI. Unit tests only there.
- Commits: no `Co-Authored-By` trailer, no "Generated with" line (user rule). Subject style: `e2e: …`.
- GUI runs (`make e2e`, `make e2e-full`) are the controller's, never a subagent's, and only after asking the operator (shared screen).

## Review Focus

1. **A Swift file that changed only in comments** still has its identifiers harvested (`IdentifiersIn` skips commented identifiers), so a comment edit can select checks — acceptable; but a quoted action name *only in a comment* must not select. Pinned in Task 1 (`TestAnActionNamedOnlyInACommentSelectsNothing`).
2. **An identifier the branch removed** must still select the checks that press it, or a deletion that breaks them reads as "nothing to run". Pinned in Task 1 (`TestAnIdentifierOnlyInTheBaseStillSelects`).
3. **A renamed Swift file** (`R100 old new`) must read both sides, or its identifiers vanish from the diff. Pinned in Task 2 (`TestChangedFilesReadsBothSidesOfARename`).
4. **A selection record left from an earlier head** must not let unrun checks read as *owed*. Pinned in Task 4 (`TestASelectionForAnotherHeadOwesNothing`).
5. **`E2E_ONLY` naming a file outside the three launch directories, or a glob that matched nothing,** must refuse, not run an empty set. Pinned in Task 2 (`TestNamedSelectionRefusesAFileInNoLaunchDirectory`, `TestNamedSelectionRefusesAMissingFile`).

---

## File Structure

- Create `e2e/driver/select.go` — `ChangedFile`, `Selection`, `Pick`, `SelectChecks`, `NamedSelection`, `Selection.Has`, `Selection.Files`. Pure; no git, no disk.
- Create `e2e/driver/select_test.go` — `package driver_test`, the selection cases.
- Create `e2e/driver/selectio.go` — `ChangedFiles` (git), `LoadCorpus`, `WriteSelection`, `ReadSelection`.
- Create `e2e/driver/selectio_test.go` — temp git repo + record round trip.
- Create `e2e/cmd/wakil-e2e-select/main.go` — the command the Makefile calls.
- Modify `Makefile:215-357` — `e2e`, new `e2e-full`, new `e2e-run`; `.PHONY` at line 59.
- Modify `e2e/driver/runbook.go` — `Selection` field, `owedToFull` state, headline, row.
- Modify `e2e/driver/runbook_test.go` — owed cases.
- Modify `e2e/cmd/wakil-e2e-runbook/main.go` — read the selection record.
- Modify `docs/agents/e2e.md`, `docs/agents/workflow.md`.

---

### Task 1: SelectChecks — the pure mapping

**Files:**
- Create: `e2e/driver/select.go`
- Test: `e2e/driver/select_test.go`

**Interfaces:**
- Consumes: `IdentifiersIn(file, source string) []Identifier`, `CoverageOf([]Check) Coverage`, `Coverage.Exercises(string) bool`, `Coverage.Dispatches(string) bool`, `Coverage.Dispatched() []string`, `Sources{text}` + `Sources.Mentions(string) bool`, `withoutCommentLines(string) string`, `LaunchFor(string) (LaunchKind, bool)`, `LaunchDirs() []string`, `sameCheckFile(a, b string) bool`, `CheckRoot`.
- Produces:
  - `type ChangedFile struct { Path, Status, Before, After string }`
  - `type Pick struct { Check string; Reasons []string }` (json `check`, `reasons`)
  - `type Selection struct { Mode, BaseCommit, HeadCommit string; Dirty bool; SelectedAt time.Time; Picks []Pick; Unmapped, NoCheck, Ignored []string }`
  - consts `SelectModeSelected = "selected"`, `SelectModeNamed = "named"`, `SelectModeFull = "full"`, `AlwaysSelected = CheckRoot + "unseeded/org-plane.jsonl"`
  - `func SelectChecks(changes []ChangedFile, corpus map[string]Check) Selection` (Mode = selected; commits filled by caller)
  - `func (s Selection) Has(file string) bool`
  - `func (s Selection) Files() []string` — picks in launch order

- [ ] **Step 1: Write the failing tests**

`e2e/driver/select_test.go`:

```go
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

func TestDocsAndProofsAreIgnored(t *testing.T) {
	changes := []driver.ChangedFile{
		{Path: "docs/wakil/north-star.md", Status: "M"},
		{Path: "README.md", Status: "M"},
		{Path: "e2e/checks/proofs/reopen.json", Status: "A"},
	}
	got := driver.SelectChecks(changes, selectionCorpus(t))
	if len(got.Ignored) != 3 || len(got.Unmapped) != 0 {
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./e2e/driver/ -run 'Select|Selects|Unmapped|NoCheck|Ignored|LaunchOrder|OrgPlane' 2>&1 | head -20`
Expected: build failure — `undefined: driver.SelectChecks`.

- [ ] **Step 3: Implement**

`e2e/driver/select.go`:

```go
package driver

import (
	"fmt"
	"path"
	"slices"
	"sort"
	"strings"
	"time"
)

// The three ways a run's file list is chosen. The runbook reads the mode to
// tell "owed to the full run" from "never run".
const (
	SelectModeSelected = "selected"
	SelectModeNamed    = "named"
	SelectModeFull     = "full"
)

// AlwaysSelected runs on every selected run: the cheapest launch, it proves
// the bundle starts and refreshes the action denominator `e2e-cover` refuses
// to read stale.
const AlwaysSelected = CheckRoot + "unseeded/org-plane.jsonl"

// ChangedFile is one path the branch changed, with its text on both sides.
// Before is empty for an addition, After for a deletion.
type ChangedFile struct {
	Path   string
	Status string
	Before string
	After  string
}

// Pick is one selected check and every reason it was selected.
type Pick struct {
	Check   string   `json:"check"`
	Reasons []string `json:"reasons"`
}

// Selection is which checks a run took, and why — and, as loudly, which
// changed files no check reaches.
type Selection struct {
	Mode       string    `json:"mode"`
	BaseCommit string    `json:"baseCommit,omitempty"`
	HeadCommit string    `json:"headCommit"`
	Dirty      bool      `json:"dirty,omitempty"`
	SelectedAt time.Time `json:"selectedAt"`
	Picks      []Pick    `json:"picks"`
	// Unmapped files reach no check and are owed to the full run.
	Unmapped []string `json:"unmapped,omitempty"`
	// NoCheck files declare identifiers no check presses: the coverage
	// gate's question, listed apart so it is not mistaken for unmapped.
	NoCheck []string `json:"mappedNoCheck,omitempty"`
	// Ignored files cannot change what a check sees.
	Ignored []string `json:"ignored,omitempty"`
}

// SelectChecks maps a branch's changed files to the checks they reach.
//
// **Through what the harness already reads, and nothing else**: a check file
// selects itself, an identifier selects the checks that press it, a quoted
// action name selects the checks that dispatch it. A file none of those reach
// is listed as unmapped and left to `make e2e-full`, never escalated to it —
// shared code reaches every check, and escalating would put the whole suite
// back on most branches.
func SelectChecks(changes []ChangedFile, corpus map[string]Check) Selection {
	sel := Selection{Mode: SelectModeSelected}
	reasons := map[string][]string{}
	pick := func(file, reason string) {
		if !slices.Contains(reasons[file], reason) {
			reasons[file] = append(reasons[file], reason)
		}
	}
	if _, ok := corpus[AlwaysSelected]; ok {
		pick(AlwaysSelected, "always: proves the bundle starts and records the actions e2e-cover reads")
	}

	covers := make(map[string]Coverage, len(corpus))
	actions := map[string]bool{}
	for file, check := range corpus {
		covers[file] = CoverageOf([]Check{check})
		for _, action := range covers[file].Dispatched() {
			actions[action] = true
		}
	}
	checkFiles := keysOf(covers)
	actionNames := keysOf(actions)

	for _, change := range changes {
		switch {
		case ignoredPath(change.Path):
			sel.Ignored = append(sel.Ignored, change.Path)
		case isCheckFile(change.Path):
			// A deleted check is not in the corpus: nothing to run, nothing owed.
			if _, ok := corpus[change.Path]; ok {
				pick(change.Path, "the check changed")
			}
		case path.Ext(change.Path) == ".swift":
			base := path.Base(change.Path)
			hit := false
			identifiers := append(IdentifiersIn(base, change.Before), IdentifiersIn(base, change.After)...)
			for _, identifier := range identifiers {
				for _, file := range checkFiles {
					if covers[file].Exercises(identifier.Name) {
						pick(file, fmt.Sprintf("%s declares %s", base, identifier.Name))
						hit = true
					}
				}
			}
			code := Sources{text: withoutCommentLines(change.Before) + "\n" + withoutCommentLines(change.After)}
			for _, action := range actionNames {
				if !code.Mentions(action) {
					continue
				}
				for _, file := range checkFiles {
					if covers[file].Dispatches(action) {
						pick(file, fmt.Sprintf("%s spells action %s", base, action))
						hit = true
					}
				}
			}
			switch {
			case hit:
			case len(identifiers) > 0:
				sel.NoCheck = append(sel.NoCheck, change.Path)
			default:
				sel.Unmapped = append(sel.Unmapped, change.Path)
			}
		default:
			sel.Unmapped = append(sel.Unmapped, change.Path)
		}
	}

	for file, why := range reasons {
		sel.Picks = append(sel.Picks, Pick{Check: file, Reasons: why})
	}
	sortPicks(sel.Picks)
	sort.Strings(sel.Unmapped)
	sort.Strings(sel.NoCheck)
	sort.Strings(sel.Ignored)
	return sel
}

// Has reports whether this selection picked the file.
func (s Selection) Has(file string) bool {
	for _, p := range s.Picks {
		if sameCheckFile(p.Check, file) {
			return true
		}
	}
	return false
}

// Files lists the picks in launch order, which is the order they run in.
func (s Selection) Files() []string {
	files := make([]string, 0, len(s.Picks))
	for _, p := range s.Picks {
		files = append(files, p.Check)
	}
	return files
}

func isCheckFile(file string) bool {
	return strings.HasPrefix(file, CheckRoot) && path.Ext(file) == ".jsonl"
}

func ignoredPath(file string) bool {
	return strings.HasPrefix(file, "docs/") ||
		strings.HasPrefix(file, CheckRoot+"proofs/") ||
		path.Ext(file) == ".md"
}

// launchRank orders files unseeded, seeded, agent — `launchDirs`' order — and
// anything else last.
func launchRank(file string) int {
	for rank, dir := range LaunchDirs() {
		if strings.HasPrefix(file, dir) {
			return rank
		}
	}
	return len(LaunchDirs())
}

func sortPicks(picks []Pick) {
	sort.Slice(picks, func(i, j int) bool {
		ri, rj := launchRank(picks[i].Check), launchRank(picks[j].Check)
		if ri != rj {
			return ri < rj
		}
		return picks[i].Check < picks[j].Check
	})
}

func keysOf[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
```

`keysOf` is generic because `run.go` already has a non-generic `sortedKeys(map[string]interface{})`; do not reuse that name.

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./e2e/driver/ -run 'Select|Selects|Unmapped|NoCheck|Ignored|LaunchOrder|OrgPlane' -v 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add e2e/driver/select.go e2e/driver/select_test.go
git commit -m "e2e: SelectChecks — map a branch's changed files to the checks they reach"
```

---

### Task 2: Reading git, the corpus, and the record; named and full selections

**Files:**
- Create: `e2e/driver/selectio.go`
- Test: `e2e/driver/selectio_test.go`
- Modify: `e2e/driver/select.go` (add `NamedSelection`)

**Interfaces:**
- Consumes: Task 1's `ChangedFile`, `Selection`, `Pick`, modes; `GitTree{Repo, Commit}.Read`, `ParseChecks(name string, data []byte) (Check, error)`, `LaunchFor`, `sortPicks`.
- Produces:
  - `func ChangedFiles(repo, base string) ([]ChangedFile, error)`
  - `func LoadCorpus(paths []string) (map[string]Check, error)`
  - `func NamedSelection(mode string, files []string) (Selection, error)`
  - `const SelectionDir = "select"`
  - `func WriteSelection(root string, s Selection) (string, error)` → `<root>/select/latest.json`
  - `func ReadSelection(root string) (Selection, bool, error)` — `false, nil` when none exists

- [ ] **Step 1: Write the failing tests**

`e2e/driver/selectio_test.go`:

```go
package driver_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func write(t *testing.T, dir, file, body string) {
	t.Helper()
	full := filepath.Join(dir, file)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestChangedFilesReadsBothSidesOfARename(t *testing.T) {
	repo := t.TempDir()
	git(t, repo, "init", "-q", "-b", "main")
	write(t, repo, "app/Old.swift", `x.accessibilityIdentifier("window.kept")`+"\n")
	write(t, repo, "app/Gone.swift", "struct Gone {}\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-qm", "base")
	base := git(t, repo, "rev-parse", "HEAD")
	git(t, repo, "mv", "app/Old.swift", "app/New.swift")
	git(t, repo, "rm", "-q", "app/Gone.swift")
	write(t, repo, "app/Added.swift", "struct Added {}\n")
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-qm", "head")

	changes, err := driver.ChangedFiles(repo, base)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]driver.ChangedFile{}
	for _, c := range changes {
		byPath[c.Path] = c
	}
	renamed := byPath["app/New.swift"]
	if renamed.Status != "R" || !strings.Contains(renamed.Before, "window.kept") || !strings.Contains(renamed.After, "window.kept") {
		t.Fatalf("rename: %+v", renamed)
	}
	if gone := byPath["app/Gone.swift"]; gone.Status != "D" || gone.Before == "" || gone.After != "" {
		t.Fatalf("deletion: %+v", gone)
	}
	if added := byPath["app/Added.swift"]; added.Status != "A" || added.Before != "" || added.After == "" {
		t.Fatalf("addition: %+v", added)
	}
}

func TestNamedSelectionKeepsLaunchOrderAndSaysWhy(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	for _, f := range []string{"e2e/checks/agent/a.jsonl", "e2e/checks/seeded/s.jsonl"} {
		write(t, dir, f, "{}\n")
	}
	sel, err := driver.NamedSelection(driver.SelectModeNamed,
		[]string{"e2e/checks/agent/a.jsonl", "e2e/checks/seeded/s.jsonl"})
	if err != nil {
		t.Fatal(err)
	}
	if got := sel.Files(); got[0] != "e2e/checks/seeded/s.jsonl" {
		t.Fatalf("order %v", got)
	}
	if sel.Mode != driver.SelectModeNamed || sel.Picks[0].Reasons[0] != "named by E2E_ONLY" {
		t.Fatalf("%+v", sel)
	}
}

func TestNamedSelectionRefusesAFileInNoLaunchDirectory(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	write(t, dir, "e2e/checks/stray.jsonl", "{}\n")
	if _, err := driver.NamedSelection(driver.SelectModeNamed, []string{"e2e/checks/stray.jsonl"}); err == nil {
		t.Fatal("a check in no launch directory must be refused")
	}
}

func TestNamedSelectionRefusesAMissingFile(t *testing.T) {
	t.Chdir(t.TempDir())
	// A glob that matched nothing reaches here as itself.
	if _, err := driver.NamedSelection(driver.SelectModeNamed, []string{"e2e/checks/seeded/nope-*.jsonl"}); err == nil {
		t.Fatal("a file that is not there must be refused")
	}
	if _, err := driver.NamedSelection(driver.SelectModeNamed, nil); err == nil {
		t.Fatal("naming nothing must be refused")
	}
}

func TestTheSelectionRecordRoundTrips(t *testing.T) {
	root := t.TempDir()
	if _, ok, err := driver.ReadSelection(root); ok || err != nil {
		t.Fatalf("no record yet: ok=%v err=%v", ok, err)
	}
	want := driver.Selection{Mode: driver.SelectModeSelected, HeadCommit: "abc",
		Picks: []driver.Pick{{Check: "e2e/checks/seeded/x.jsonl", Reasons: []string{"the check changed"}}},
		Unmapped: []string{"internal/x.go"}}
	path, err := driver.WriteSelection(root, want)
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(root, "select", "latest.json") {
		t.Fatalf("path %s", path)
	}
	got, ok, err := driver.ReadSelection(root)
	if err != nil || !ok || got.HeadCommit != "abc" || !got.Has("e2e/checks/seeded/x.jsonl") || got.Unmapped[0] != "internal/x.go" {
		t.Fatalf("got %+v ok=%v err=%v", got, ok, err)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./e2e/driver/ -run 'ChangedFiles|NamedSelection|SelectionRecord' 2>&1 | head`
Expected: build failure — `undefined: driver.ChangedFiles`.

- [ ] **Step 3: Implement**

Append to `e2e/driver/select.go`:

```go
// NamedSelection is a run whose files were chosen by hand (`E2E_ONLY`) or are
// the whole corpus (`make e2e-full`). Every file must exist and sit in a
// launch directory: a glob that matched nothing arrives as itself, and running
// an empty or misplaced set would pass having proved nothing.
func NamedSelection(mode string, files []string) (Selection, error) {
	if len(files) == 0 {
		return Selection{}, fmt.Errorf("no check files named, so nothing would run")
	}
	reason := "named by E2E_ONLY"
	if mode == SelectModeFull {
		reason = "full run"
	}
	sel := Selection{Mode: mode}
	for _, file := range files {
		if _, err := os.Stat(file); err != nil {
			return Selection{}, fmt.Errorf("%s: %w", file, err)
		}
		if _, ok := LaunchFor(file); !ok {
			return Selection{}, fmt.Errorf("%s is in none of %s, so there is no way to know which launch it wants",
				file, strings.Join(LaunchDirs(), ", "))
		}
		sel.Picks = append(sel.Picks, Pick{Check: file, Reasons: []string{reason}})
	}
	sortPicks(sel.Picks)
	return sel, nil
}
```

(add `"os"` to select.go's imports).

`e2e/driver/selectio.go`:

```go
package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// SelectionDir holds the selection record, under the evidence root, beside
// the run records the runbook reads it with.
const SelectionDir = "select"

// ChangedFiles reads what the branch changed since base, with each file's text
// at the base and at HEAD.
//
// **Both sides, always.** An identifier the branch removed lives only in the
// base text, and the checks that press it are exactly the ones the change
// breaks.
func ChangedFiles(repo, base string) ([]ChangedFile, error) {
	out, err := exec.Command("git", "-C", repo, "diff", "--name-status", base+"...HEAD").Output()
	if err != nil {
		return nil, fmt.Errorf("listing what changed since %s: %w", ShortCommit(base), err)
	}
	before := GitTree{Repo: repo, Commit: base}
	after := GitTree{Repo: repo, Commit: "HEAD"}
	read := func(tree GitTree, file string) (string, error) {
		data, err := tree.Read(file)
		return string(data), err
	}
	var changes []ChangedFile
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) < 2 {
			continue
		}
		change := ChangedFile{Status: fields[0][:1], Path: fields[len(fields)-1]}
		oldPath := fields[1]
		var err error
		if change.Status != "A" {
			if change.Before, err = read(before, oldPath); err != nil {
				return nil, err
			}
		}
		if change.Status != "D" {
			if change.After, err = read(after, change.Path); err != nil {
				return nil, err
			}
		}
		changes = append(changes, change)
	}
	return changes, nil
}

// LoadCorpus parses every check file, keyed by its path.
func LoadCorpus(paths []string) (map[string]Check, error) {
	corpus := make(map[string]Check, len(paths))
	for _, file := range paths {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		check, err := ParseChecks(filepath.Base(file), data)
		if err != nil {
			return nil, err
		}
		corpus[file] = check
	}
	return corpus, nil
}

// WriteSelection records which checks this run took.
func WriteSelection(root string, s Selection) (string, error) {
	if s.SelectedAt.IsZero() {
		s.SelectedAt = time.Now().UTC()
	}
	encoded, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the selection: %w", err)
	}
	dir := filepath.Join(root, SelectionDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("making %s: %w", dir, err)
	}
	path := filepath.Join(dir, "latest.json")
	if err := os.WriteFile(path, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("writing the selection: %w", err)
	}
	return path, nil
}

// ReadSelection reads the record; false with no error when none was written.
func ReadSelection(root string) (Selection, bool, error) {
	path := filepath.Join(root, SelectionDir, "latest.json")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return Selection{}, false, nil
	}
	if err != nil {
		return Selection{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	var s Selection
	if err := json.Unmarshal(data, &s); err != nil {
		return Selection{}, false, fmt.Errorf("reading %s: %w", path, err)
	}
	return s, true, nil
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./e2e/driver/ -run 'ChangedFiles|NamedSelection|SelectionRecord|Select' -v 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add e2e/driver/select.go e2e/driver/selectio.go e2e/driver/selectio_test.go
git commit -m "e2e: read the branch's changed files, the corpus and the selection record"
```

---

### Task 3: The `wakil-e2e-select` command and the Makefile targets

**Files:**
- Create: `e2e/cmd/wakil-e2e-select/main.go`
- Modify: `Makefile` — `.PHONY` (line 59), the `e2e:` target (lines 332-357), add `e2e-full` and `e2e-run`; rewrite the comment block above `e2e:` where it says the target runs every check.

**Interfaces:**
- Consumes: `MergeBase`, `HeadCommit`, `TreeIsDirty`, `ChangedFiles`, `CheckCorpus`, `LoadCorpus`, `SelectChecks`, `NamedSelection`, `WriteSelection`, `ShortCommit`, `DefaultEvidenceRoot`.
- Produces: `go run ./e2e/cmd/wakil-e2e-select [--trunk T] [--only|--full] [files…]` — files on stdout one per line in launch order; the report on stderr; exit 1 on any error.

- [ ] **Step 1: Write the command**

`e2e/cmd/wakil-e2e-select/main.go`:

```go
// wakil-e2e-select chooses which check files a run takes and records why.
//
// Stdout is the file list, one per line, in launch order — the Makefile runs
// exactly that. Everything a reader needs is on stderr.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func main() {
	repo := flag.String("repo", ".", "the repository whose branch is selected for")
	trunk := flag.String("trunk", "origin/main", "what this branch forked from")
	evidence := flag.String("evidence", driver.DefaultEvidenceRoot, "where the selection record goes")
	only := flag.Bool("only", false, "run exactly the files named (E2E_ONLY)")
	full := flag.Bool("full", false, "run exactly the files named, as the whole suite (make e2e-full)")
	flag.Parse()

	sel, err := choose(*repo, *trunk, *only, *full, flag.Args())
	if err == nil {
		err = record(*evidence, sel)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "wakil-e2e-select:", err)
		os.Exit(1)
	}
	for _, file := range sel.Files() {
		fmt.Println(file)
	}
}

func choose(repo, trunk string, only, full bool, named []string) (driver.Selection, error) {
	var sel driver.Selection
	var err error
	switch {
	case only && full:
		return sel, fmt.Errorf("--only and --full are two different runs; pass one")
	case only:
		sel, err = driver.NamedSelection(driver.SelectModeNamed, named)
	case full:
		sel, err = driver.NamedSelection(driver.SelectModeFull, named)
	default:
		sel, err = selectForBranch(repo, trunk)
	}
	if err != nil {
		return sel, err
	}
	if sel.HeadCommit, err = driver.HeadCommit(repo); err != nil {
		return sel, err
	}
	sel.Dirty, err = driver.TreeIsDirty(repo)
	return sel, err
}

func selectForBranch(repo, trunk string) (driver.Selection, error) {
	base, err := driver.MergeBase(repo, trunk)
	if err != nil {
		return driver.Selection{}, err
	}
	changes, err := driver.ChangedFiles(repo, base)
	if err != nil {
		return driver.Selection{}, err
	}
	corpus, err := driver.LoadCorpus(driver.CheckCorpus())
	if err != nil {
		return driver.Selection{}, err
	}
	sel := driver.SelectChecks(changes, corpus)
	sel.BaseCommit = base
	return sel, nil
}

func record(root string, sel driver.Selection) error {
	path, err := driver.WriteSelection(root, sel)
	if err != nil {
		return err
	}
	say := func(format string, args ...any) { fmt.Fprintf(os.Stderr, "wakil-e2e-select: "+format+"\n", args...) }
	switch sel.Mode {
	case driver.SelectModeSelected:
		say("%d check(s) reached by the diff since %s", len(sel.Picks), driver.ShortCommit(sel.BaseCommit))
	default:
		say("%d check(s), %s", len(sel.Picks), sel.Mode)
	}
	for _, p := range sel.Picks {
		reasons := p.Reasons
		more := ""
		if len(reasons) > 3 {
			more = fmt.Sprintf(" (and %d more)", len(reasons)-3)
			reasons = reasons[:3]
		}
		say("  %s — %s%s", p.Check, strings.Join(reasons, "; "), more)
	}
	if len(sel.Unmapped) > 0 {
		say("UNMAPPED — no check reaches these; only `make e2e-full` covers them:")
		for _, file := range sel.Unmapped {
			say("  %s", file)
		}
	}
	if len(sel.NoCheck) > 0 {
		say("declare controls no check presses (the coverage gate's question): %s", strings.Join(sel.NoCheck, ", "))
	}
	if len(sel.Ignored) > 0 {
		say("%d file(s) ignored: docs, proofs and Markdown cannot change what a check sees", len(sel.Ignored))
	}
	if sel.Mode == driver.SelectModeSelected && len(sel.Picks) == 1 {
		say("nothing beyond the org-plane check is reached, so this run proves only that the bundle starts")
	}
	if sel.Dirty {
		say("the tree has uncommitted changes; selection read the committed diff only")
	}
	say("recorded in %s", path)
	return nil
}
```

- [ ] **Step 2: Check it on this branch**

Run: `go run ./e2e/cmd/wakil-e2e-select`
Expected: stdout is `e2e/checks/unseeded/org-plane.jsonl` (plus nothing else unless this branch touched checks); stderr lists the `e2e/driver/*.go` and `e2e/cmd/...` files as UNMAPPED and `docs/...` as ignored. Then:
Run: `go run ./e2e/cmd/wakil-e2e-select --only 'e2e/checks/seeded/nope-*.jsonl'; echo rc=$?`
Expected: an error naming the file, `rc=1`.

- [ ] **Step 3: Replace the `e2e:` recipe and add `e2e-full` and `e2e-run`**

In `Makefile`, replace the whole `e2e:` target (from `e2e: app-bundle axresolve e2e-agent` through its `exit $$status` line) with:

```make
# E2E_ONLY runs exactly the named checks instead of the selection, e.g.
# `make e2e E2E_ONLY='e2e/checks/seeded/git-*.jsonl'`.
E2E_ONLY ?=

e2e: app-bundle axresolve e2e-agent
	@files=$$(go run ./e2e/cmd/wakil-e2e-select --trunk "$(E2E_TRUNK)" \
	    $(if $(E2E_ONLY),--only $(E2E_ONLY),) | tr '\n' ' ') || exit 1; \
	$(MAKE) --no-print-directory e2e-run E2E_FILES="$$files"

# e2e-full — every check, once per branch, on the head that merges. Unattended:
# it holds the screen for the whole suite (~22 min at 127 files).
e2e-full: app-bundle axresolve e2e-agent
	@files=$$(go run ./e2e/cmd/wakil-e2e-select --full \
	    $(E2E_UNSEEDED) $(E2E_SEEDED) $(E2E_AGENT) | tr '\n' ' ') || exit 1; \
	$(MAKE) --no-print-directory e2e-run E2E_FILES="$$files"

# e2e-run — the one loop both targets share. The launch comes from the
# directory, as it always has.
e2e-run:
	@test -d "$(E2E_BUNDLE)" || { \
	    echo "make e2e: no bundle at $(E2E_BUNDLE) — run \`make app-bundle\`"; exit 1; }
	@status=0; \
	for check in $(E2E_FILES); do \
	    case $$check in \
	        e2e/checks/unseeded/*) flags="--no-seed"; label="organisation plane";; \
	        e2e/checks/agent/*) flags="--agent on"; label="seeded, scripted agent";; \
	        *) flags=""; label="seeded";; \
	    esac; \
	    echo "== $$check ($$label)"; \
	    go run ./e2e/cmd/wakil-e2e --bundle "$(E2E_BUNDLE)" $$flags $(E2E_SETTLE_ARG) "$$check" \
	        || { status=1; break; }; \
	done; \
	echo "== coverage"; \
	$(MAKE) --no-print-directory e2e-cover || status=1; \
	exit $$status
```

Add `e2e-full e2e-run` to the `.PHONY` line (59). In the comment block above, change any sentence saying `make e2e` runs every check to say it runs the selected checks and that `make e2e-full` runs every check.

- [ ] **Step 4: Verify the recipes expand as intended (no GUI)**

Run: `make -n e2e-run E2E_FILES="e2e/checks/unseeded/org-plane.jsonl e2e/checks/agent/x.jsonl" | grep -c "wakil-e2e"`
Expected: the loop text prints (dry run shows the recipe); then
Run: `make -n e2e-full 2>&1 | grep -- "--full"`
Expected: one line with `wakil-e2e-select --full e2e/checks/unseeded/*.jsonl …` (globs expand at run time).
Run: `go vet ./e2e/... && go test ./e2e/driver/ 2>&1 | tail -3`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add e2e/cmd/wakil-e2e-select/main.go Makefile
git commit -m "e2e: make e2e runs the selected checks; make e2e-full runs them all"
```

---

### Task 4: The runbook — *owed to the full run*

**Files:**
- Modify: `e2e/driver/runbook.go` (struct `MachineWalk`, `walkState` consts, `stateOf`, `row`, `Markdown`)
- Modify: `e2e/driver/runbook_test.go`
- Modify: `e2e/cmd/wakil-e2e-runbook/main.go` (`run`)

**Interfaces:**
- Consumes: Task 1/2's `Selection`, `Selection.Has`, `SelectModeFull`, `ReadSelection`.
- Produces: `MachineWalk.Selection *Selection`; `func (w MachineWalk) Owed() []string`.

- [ ] **Step 1: Write the failing tests**

Append to `e2e/driver/runbook_test.go` (package `driver`):

```go
// selectedWalk is provenWalk with a third check that the selection did not
// pick and nothing ran.
func selectedWalk(selection Selection) MachineWalk {
	walk := provenWalk()
	walk.Corpus = append(walk.Corpus, "e2e/checks/seeded/unpicked.jsonl")
	walk.Selection = &selection
	return walk
}

func pickedBoth(head, mode string) Selection {
	return Selection{Mode: mode, HeadCommit: head, Picks: []Pick{
		{Check: "e2e/checks/seeded/landing.jsonl"}, {Check: "e2e/checks/unseeded/org-plane.jsonl"}}}
}

func TestAnUnpickedCheckIsOwedToTheFullRunAndIsNotAFault(t *testing.T) {
	walk := selectedWalk(pickedBoth("63c7793aaaa", SelectModeSelected))
	if err := walk.Err(); err != nil {
		t.Fatalf("an owed check is not a fault: %v", err)
	}
	if got := walk.Owed(); len(got) != 1 || got[0] != "e2e/checks/seeded/unpicked.jsonl" {
		t.Fatalf("owed %v", got)
	}
	section := walk.Markdown()
	for _, want := range []string{"owed to `make e2e-full`", "1 check(s) are owed"} {
		if !strings.Contains(section, want) {
			t.Fatalf("missing %q:\n%s", want, section)
		}
	}
	if strings.Contains(section, "every check ran against this build") {
		t.Fatalf("a selected walk must not claim the whole corpus ran:\n%s", section)
	}
}

func TestASelectionForAnotherHeadOwesNothing(t *testing.T) {
	walk := selectedWalk(pickedBoth("someotherhead", SelectModeSelected))
	if len(walk.Owed()) != 0 {
		t.Fatalf("owed %v", walk.Owed())
	}
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("an unrun check under a stale selection is a fault: %v", err)
	}
}

func TestAFullRunOwesNothing(t *testing.T) {
	walk := selectedWalk(pickedBoth("63c7793aaaa", SelectModeFull))
	if err := walk.Err(); err == nil || !strings.Contains(err.Error(), "never run") {
		t.Fatalf("a full run that never reached a check leaves it never run: %v", err)
	}
}

func TestAPickedCheckThatDidNotRunIsStillAFault(t *testing.T) {
	selection := pickedBoth("63c7793aaaa", SelectModeSelected)
	selection.Picks = append(selection.Picks, Pick{Check: "e2e/checks/seeded/unpicked.jsonl"})
	walk := selectedWalk(selection)
	if err := walk.Err(); err == nil {
		t.Fatal("a picked check with no record is never run, not owed")
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./e2e/driver/ -run 'Owed|OwesNothing|PickedCheck' 2>&1 | head`
Expected: build failure — `walk.Selection undefined`.

- [ ] **Step 3: Implement**

In `e2e/driver/runbook.go`:

Add to `MachineWalk`, after `Blobs`:

```go
	// Selection is what `make e2e` chose to run. A check it did not pick and
	// nothing ran on this build is owed to `make e2e-full`, not a fault —
	// but only when the record names this head and is not itself a full run.
	Selection *Selection
```

Add to the `walkState` consts, after `anotherBuild`:

```go
	// owedToFull: not run on this build, and this build's selection did not
	// pick it — `make e2e-full` owes it.
	owedToFull
```

Replace `stateOf` with:

```go
func (w MachineWalk) stateOf(file string) (RunRecord, walkState) {
	record, ran := w.recordFor(file)
	onThisBuild := ran && record.Err(w.HeadCommit) == nil
	switch {
	case !onThisBuild && w.owes(file):
		return record, owedToFull
	case !ran:
		return record, neverRun
	case !onThisBuild:
		return record, anotherBuild
	case !record.Green():
		return record, redWalk
	default:
		return record, greenWalk
	}
}

// owes reports whether this build's selection left the file to the full run.
func (w MachineWalk) owes(file string) bool {
	s := w.Selection
	return s != nil && s.HeadCommit == w.HeadCommit && s.Mode != SelectModeFull && !s.Has(file)
}

// Owed lists the corpus files left to `make e2e-full`.
func (w MachineWalk) Owed() []string {
	var owed []string
	for _, file := range w.Corpus {
		if _, state := w.stateOf(file); state == owedToFull {
			owed = append(owed, file)
		}
	}
	return owed
}
```

In `row`, add before `case anotherBuild:`:

```go
	case owedToFull:
		return fmt.Sprintf("| `%s` | owed to `make e2e-full` | — | — | — |\n", filepath.Base(file))
```

In `Markdown`, replace the green branch's `fmt.Fprintf(&out, "**The machine walk is green:** …` call with:

```go
		if owed := w.Owed(); len(owed) > 0 {
			fmt.Fprintf(&out, "**The machine walk is green for the checks this branch reaches:** "+
				"the %d `make e2e` selected ran green against this build, %s, and the surface it "+
				"added carries checks. **%d check(s) are owed to `make e2e-full`**, which runs once, "+
				"on the head that merges.\n\n", len(w.Corpus)-len(owed), proved, len(owed))
			if len(w.Selection.Unmapped) > 0 {
				out.WriteString("Changed files no check maps to, which only the full run covers:\n\n")
				for _, file := range w.Selection.Unmapped {
					fmt.Fprintf(&out, "- `%s`\n", file)
				}
				out.WriteString("\n")
			}
		} else {
			fmt.Fprintf(&out, "**The machine walk is green:** every check ran against this build, "+
				"%s, and the surface it added carries checks.\n\n", proved)
		}
```

In `e2e/cmd/wakil-e2e-runbook/main.go` `run`, after `walk := driver.MachineWalk{…}` and the `if proved` block, add:

```go
	selection, selected, err := driver.ReadSelection(opts.Evidence)
	if err != nil {
		return err
	}
	if selected {
		if selection.HeadCommit != head {
			fmt.Fprintf(os.Stderr, "wakil-e2e-runbook: the selection record names %s, not %s, so it is ignored\n",
				driver.ShortCommit(selection.HeadCommit), driver.ShortCommit(head))
		}
		walk.Selection = &selection
	}
```

- [ ] **Step 4: Run to verify they pass, and the old runbook tests still pass**

Run: `go test ./e2e/driver/ 2>&1 | tail -3 && go vet ./e2e/...`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add e2e/driver/runbook.go e2e/driver/runbook_test.go e2e/cmd/wakil-e2e-runbook/main.go
git commit -m "e2e: the runbook names checks owed to make e2e-full, and goes fully green only after it"
```

---

### Task 5: Docs, then the live proof

**Files:**
- Modify: `docs/agents/e2e.md` (the "Before anything else" table, steps 6–7, a new step before merge)
- Modify: `docs/agents/workflow.md:39` (the Cover row) and the merge step

- [ ] **Step 1: Edit `docs/agents/e2e.md`**

Add a table row: `| Which checks does this branch reach? | `go run ./e2e/cmd/wakil-e2e-select`, `.context/e2e/select/latest.json` |`.

Replace step 6 with:

```markdown
6. **Prove them green**: `make e2e`. It runs the checks the diff reaches — the
   changed check files, the checks that press an identifier a changed file
   declares, the checks that dispatch an action a changed file spells — plus
   the org-plane check, then the coverage gate. **Read the UNMAPPED list it
   prints**: files no check reaches, which only the full run covers. To run a
   hand-picked set instead: `make e2e E2E_ONLY='e2e/checks/seeded/git-*.jsonl'`.
```

After step 8 add:

```markdown
9. **Before merge, `make e2e-full`** on the head that merges, unattended — it
   holds the screen for the whole suite (~22 minutes). Re-render the runbook
   after it: only a full run turns *owed to `make e2e-full`* into green.
```

- [ ] **Step 2: Edit `docs/agents/workflow.md`**

In the Cover row (line 39), change `` `make e2e` green `` to `` `make e2e` green (the checks the diff reaches) ``. Where the workflow describes merging, add: `` `make e2e-full` green on the merging head, runbook re-rendered ``. Check with `grep -n "merge" docs/agents/workflow.md` for the right place.

- [ ] **Step 3: Docs check and commit**

Run: `make docs-check 2>&1 | tail -3`
Expected: passes.

```bash
git add docs/agents/e2e.md docs/agents/workflow.md
git commit -m "Docs: the Cover rung runs the selected checks; make e2e-full before merge"
```

- [ ] **Step 4: Live proof — controller only, after asking the operator for the screen**

Run: `time make e2e`
Expected: only the org-plane check launches (this branch changes no app code), coverage step runs, total well under 2 minutes. Report the time and the selection record.

Then, at a time the operator picks: `time make e2e-full`
Expected: every check runs, as before; `make e2e-runbook` (stdout) headlines **The machine walk is green** with no *owed* rows.
