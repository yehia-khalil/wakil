# e2e walk gaps, layout and focus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Checks for the walk findings no check caught, three new step arms (`expect.focus`, `expect.frame`, `do.resize`) for the layout and focus findings, two fixture additions, and testing guidelines that require focus and frame checks from now on.

**Architecture:** The new arms are arms of the existing `do`/`expect` kinds, parsed in `check.go`, run in `run.go`, and read through `axresolve`, which already returns element frames and the focused element without taking the foreground. `axresolve` gains `--resize WxH` and a `focusedWithin` list. The fixture gains a rootless project (always) and a spare credentialed account (agent launch only), both never active. Checks are JSONL; their red proofs run against each defect's pre-fix commit.

**Tech Stack:** Go (`e2e/driver`, `e2e/cmd`), Swift (`e2e/axresolve/main.swift`, built by `make axresolve`), JSONL checks.

**Spec:** `docs/superpowers/specs/2026-10-15-e2e-walk-gaps-layout-focus-design.md`

## Global Constraints

- Never a fifth step kind; `ParseChecks` refuses anything else.
- Identifiers in checks are concrete (`pane.db-1.reopen`), never a family.
- New fixture state is never active: existing checks open exactly as written.
- `expect.focus` / `expect.frame` do not count toward the coverage gate's exercised set.
- Tasks 1–7 take no screen. Task 8 (GUI proofs) runs only after asking the operator, and only by the controller.
- A check that will not go red against its pre-fix commit is residue, reported, never forced.
- Commits: no `Co-Authored-By`, no "Generated with" line. Subject style `e2e: …` / `Docs: …`.
- zsh does not word-split `$flags`; in ad-hoc loops pass `--agent on` as two words.

## Review Focus

1. **A frame step naming an element that resolves twice or not at all** must fail naming it, never pass vacuously. Pinned in Task 4 (`TestAFrameStepOverAMissingElementFails`).
2. **Rectangles that touch but do not overlap** must pass `clear`; sub-point rounding must not fail `inside`. Pinned in Task 2 (`TestTouchingIsNotOverlap`, `TestInsideAllowsHalfAPointOfRounding`).
3. **A resize the window clamps** (minimum size) must fail with the size it reached, not pass. Pinned in Task 3 (Swift read-back) and Task 4 (`TestAResizeTheWindowRefusedFailsTheStep`).
4. **Focus on a text field inside a named wrapper** must match the wrapper's name. Pinned in Task 4 (`TestFocusMatchesAnAncestorOfTheFocusedElement`).
5. **Adding the rootless project or the spare account changes what an existing check sees** (a project list, an account row). Not unit-testable; Task 8 runs the full suite because `seed.go` changed.

---

### Task 1: Parse the three arms

**Files:** Modify `e2e/driver/check.go` (types `Do`, `Expect`; `validateDo`, `validateExpect`, `Do.Describe`). Test: create `e2e/driver/layoutfocus_test.go` (package `driver`).

**Interfaces — Produces:**
- `type ResizeStep struct { Width, Height int }` (json `width`, `height`); `Do.Resize *ResizeStep` (json `resize`).
- `Expect.Focus string` (json `focus`); `Expect.Frame string` (json `frame`), `Expect.Inside string` (`inside`), `Expect.Clear string` (`clear`), `Expect.MinWidth, MinHeight, MaxWidth, MaxHeight *float64` (`minWidth` …).
- `const FrameWindow = "window"`.

- [ ] **Step 1: failing tests** — `layoutfocus_test.go`:

```go
package driver

import (
	"strings"
	"testing"
)

func parseOne(t *testing.T, line string) (Check, error) {
	t.Helper()
	return ParseChecks("lf.jsonl", []byte(line))
}

func TestTheThreeArmsParse(t *testing.T) {
	for _, line := range []string{
		`{"expect":{"focus":"editor.pane"}}`,
		`{"expect":{"frame":"api.recent","inside":"window"}}`,
		`{"expect":{"frame":"api.recent","inside":"window.composer","clear":"window.send"}}`,
		`{"expect":{"frame":"api.recent","minWidth":40,"maxHeight":28.5}}`,
		`{"do":{"resize":{"width":900,"height":700}}}`,
	} {
		if _, err := parseOne(t, line); err != nil {
			t.Errorf("%s: %v", line, err)
		}
	}
}

func TestTheThreeArmsRefuseWhatAssertsNothing(t *testing.T) {
	for line, want := range map[string]string{
		`{"expect":{"focus":""}}`:                                 "names none",
		`{"expect":{"frame":"api.recent"}}`:                       "no predicate",
		`{"expect":{"frame":"api.recent","inside":"nowhere.x"}}`:  "registered surface",
		`{"expect":{"frame":"api.recent","minWidth":0}}`:          "positive",
		`{"expect":{"frame":"api.recent","minWidth":50,"maxWidth":40}}`: "exceeds",
		`{"expect":{"frame":"api.recent","inside":"api.recent"}}`: "itself",
		`{"do":{"resize":{"width":0,"height":700}}}`:              "positive",
		`{"expect":{"focus":"editor.pane","tree":"contains","text":"x"}}`: "exactly one",
	} {
		_, err := parseOne(t, line)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: err = %v, want it to mention %q", line, err, want)
		}
	}
}

func TestAResizeDescribesItself(t *testing.T) {
	check, err := parseOne(t, `{"do":{"resize":{"width":900,"height":700}}}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := check.Steps[0].Do.Describe(); got != "resize the window to 900×700" {
		t.Fatalf("Describe = %q", got)
	}
}

func TestFocusAndFrameReadsExerciseNothing(t *testing.T) {
	check, err := parseOne(t, `{"expect":{"focus":"editor.pane"}}`+"\n"+`{"expect":{"frame":"api.recent","inside":"window"}}`)
	if err != nil {
		t.Fatal(err)
	}
	cover := CoverageOf([]Check{check})
	if cover.Exercises("editor.pane") || cover.Exercises("api.recent") {
		t.Fatal("a read is not a press")
	}
}
```

Before writing, confirm `editor`, `api`, `window` are in `Surfaces` (`grep -n "Surfaces = " e2e/driver/identifiers.go`); use registered surfaces only.

- [ ] **Step 2: run** `go test ./e2e/driver/ -run 'TheThreeArms|AResizeDescribes|FocusAndFrameReads'` — Expected: build failure (`unknown field Focus`… / `Resize`).

- [ ] **Step 3: implement** in `check.go`:
  - Add the fields above to `Do` and `Expect`, each with a one-line comment in the file's voice.
  - `validateDo`: add `do.Resize != nil` to the `countTrue` list and to both messages (now "ten"); a case `do.Resize != nil`: both dimensions `> 0`, else `fmt.Errorf("a do.resize needs a positive width and height, and %d×%d is not", w, h)`.
  - `Do.Describe`: `case d.Resize != nil: return fmt.Sprintf("resize the window to %d×%d", d.Resize.Width, d.Resize.Height)`; default text "ten arms" (and in `run.go`'s matching default error).
  - `validateExpect`: add `expect.Focus != ""`, `expect.Frame != ""` to the arm count; zero-arm message lists "tree, pane, process, journal, focus or frame" and keeps the words "names none"; the `>1` message keeps "exactly one". Note: `{"expect":{"focus":""}}` has zero arms → "names none".
  - `case expect.Focus != "": return validIdentifier(expect.Focus)`.
  - `case expect.Frame != ""`: `validIdentifier(expect.Frame)`; count predicates (`Inside != ""`, `Clear != ""`, each bound non-nil); zero → `"an expect.frame on %s names no predicate — inside, clear or a size bound — so it would assert nothing"`; `Inside` not `FrameWindow` → `validIdentifier`; `Inside == Frame` or `Clear == Frame` → `"an expect.frame compares %s with itself"`; each bound `> 0` else `"an expect.frame's %s must be positive"`; `MinWidth > MaxWidth` (both set) → `"minWidth %v exceeds maxWidth %v"`, same for height.
  - Leave `coverage.go` untouched (reads are not presses).

- [ ] **Step 4: run** `go test ./e2e/driver/` — Expected: `ok` (fix any existing test asserting the old "nine" wording by updating its expected text).

- [ ] **Step 5: commit** `git add e2e/driver/check.go e2e/driver/run.go e2e/driver/layoutfocus_test.go e2e/driver/*_test.go && git commit -m "e2e: expect.focus, expect.frame and do.resize parse, and refuse what asserts nothing"`

---

### Task 2: The frame predicates, pure

**Files:** Create `e2e/driver/frame.go`; test in `layoutfocus_test.go`.

**Interfaces — Produces:** `type Rect struct{ X, Y, W, H float64 }`; `func rectOfElement(Element) Rect`; `func rectOfWindow(WindowFrame) Rect`; `func (r Rect) Contains(o Rect) bool`; `func (r Rect) Overlaps(o Rect) bool`; `func judgeFrame(expect *Expect, element Rect, inside, clear *Rect) error`.

- [ ] **Step 1: failing tests** (append):

```go
func TestInsideAllowsHalfAPointOfRounding(t *testing.T) {
	outer := Rect{0, 0, 100, 100}
	if !outer.Contains(Rect{-0.4, 10, 100.3, 20}) {
		t.Fatal("sub-point rounding must not fail inside")
	}
	if outer.Contains(Rect{0, 90, 10, 20}) {
		t.Fatal("ten points past the bottom edge is outside")
	}
}

func TestTouchingIsNotOverlap(t *testing.T) {
	a := Rect{0, 0, 10, 10}
	if a.Overlaps(Rect{10, 0, 10, 10}) {
		t.Fatal("touching edges are not overlap")
	}
	if !a.Overlaps(Rect{9, 9, 10, 10}) {
		t.Fatal("a one-point corner is overlap")
	}
}

func TestJudgeFrameNamesEachFault(t *testing.T) {
	min, max := 40.0, 28.0
	expect := &Expect{Frame: "x.y", Inside: FrameWindow, Clear: "x.z", MinWidth: &min, MaxHeight: &max}
	window, other := Rect{0, 0, 100, 100}, Rect{0, 0, 20, 20}
	err := judgeFrame(expect, Rect{10, 10, 12, 60}, &window, &other)
	for _, want := range []string{"12 wide", "60 tall", "overlaps x.z"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("err = %v, want %q", err, want)
		}
	}
	if err := judgeFrame(expect, Rect{30, 30, 50, 20}, &window, &other); err != nil {
		t.Fatalf("a frame meeting every predicate: %v", err)
	}
}
```

- [ ] **Step 2: run** `go test ./e2e/driver/ -run 'InsideAllows|TouchingIs|JudgeFrame'` — Expected: build failure (`undefined: Rect`).

- [ ] **Step 3: implement** `frame.go`:

```go
package driver

import (
	"fmt"
	"strings"
)

// frameSlack absorbs the sub-point rounding AX frames carry: SwiftUI lays out
// in fractional points and a control flush with its container can read half a
// point past it.
const frameSlack = 0.5

// Rect is a frame in screen points, top-left origin — the space axresolve
// reports elements and windows in.
type Rect struct{ X, Y, W, H float64 }

func rectOfElement(e Element) Rect     { return Rect{e.X, e.Y, e.Width, e.Height} }
func rectOfWindow(w WindowFrame) Rect  { return Rect{w.X, w.Y, w.Width, w.Height} }

// Contains reports whether o lies wholly within r, to within frameSlack.
func (r Rect) Contains(o Rect) bool {
	return o.X >= r.X-frameSlack && o.Y >= r.Y-frameSlack &&
		o.X+o.W <= r.X+r.W+frameSlack && o.Y+o.H <= r.Y+r.H+frameSlack
}

// Overlaps reports whether the two share any area. Touching edges do not.
func (r Rect) Overlaps(o Rect) bool {
	return r.X < o.X+o.W && o.X < r.X+r.W && r.Y < o.Y+o.H && o.Y < r.Y+r.H
}

func (r Rect) String() string { return fmt.Sprintf("(%g, %g) %g×%g", r.X, r.Y, r.W, r.H) }

// judgeFrame holds an element's frame to every predicate its step names and
// reports each one that fails, so a red step says all that is wrong at once.
func judgeFrame(expect *Expect, element Rect, inside, clear *Rect) error {
	var faults []string
	if inside != nil && !inside.Contains(element) {
		faults = append(faults, fmt.Sprintf("%s at %s is not inside %s at %s",
			expect.Frame, element, expect.Inside, *inside))
	}
	if clear != nil && element.Overlaps(*clear) {
		faults = append(faults, fmt.Sprintf("%s at %s overlaps %s at %s",
			expect.Frame, element, expect.Clear, *clear))
	}
	bound := func(limit *float64, got float64, unit string, below bool) {
		if limit == nil || (below && got >= *limit) || (!below && got <= *limit) {
			return
		}
		word := "at most"
		if below {
			word = "at least"
		}
		faults = append(faults, fmt.Sprintf("%s is %g %s, and must be %s %g", expect.Frame, got, unit, word, *limit))
	}
	bound(expect.MinWidth, element.W, "wide", true)
	bound(expect.MaxWidth, element.W, "wide", false)
	bound(expect.MinHeight, element.H, "tall", true)
	bound(expect.MaxHeight, element.H, "tall", false)
	if len(faults) == 0 {
		return nil
	}
	return fmt.Errorf("%s", strings.Join(faults, "; "))
}
```

- [ ] **Step 4: run** the Step 2 command — Expected: PASS. Then `go test ./e2e/driver/` — `ok`.
- [ ] **Step 5: commit** `git add e2e/driver/frame.go e2e/driver/layoutfocus_test.go && git commit -m "e2e: frame predicates — inside, clear and size bounds, over rectangles"`

---

### Task 3: axresolve — `--resize` and `focusedWithin`

**Files:** Modify `e2e/axresolve/main.swift`, `e2e/driver/axresolve.go`. Test: `layoutfocus_test.go` (fake resolver).

**Interfaces — Produces:** `func (r Resolver) Resize(pid, width, height int) (Response, error)`; `Frontmost.FocusedWithin []string` (json `focusedWithin`).

- [ ] **Step 1: failing Go test** (append; reuse the package-internal `actLogResolver(t, body)` from `actlog_test.go`, which writes a script that prints `body`):

```go
func TestResizeAsksTheResolverAndReportsAVerifiedAct(t *testing.T) {
	exe := actLogResolver(t, `{"ok":true,"window":{"x":0,"y":0,"width":900,"height":700},"elements":[],"acted":{"action":"resize","identifier":"window","verified":true}}`)
	response, err := (Resolver{Exe: exe}).Resize(7, 900, 700)
	if err != nil || !response.OK {
		t.Fatalf("response %+v err %v", response, err)
	}
}

func TestFrontmostCarriesTheFocusedChain(t *testing.T) {
	exe := actLogResolver(t, `{"ok":true,"frontmost":{"pid":7,"isTarget":true,"targetHasFocusedWindow":true,"focusedRole":"AXTextField","focusedWithin":["window.composer"]}}`)
	got, err := (Resolver{Exe: exe}).Frontmost(7)
	if err != nil || len(got.FocusedWithin) != 1 || got.FocusedWithin[0] != "window.composer" {
		t.Fatalf("got %+v err %v", got, err)
	}
}
```

Check `actLogResolver`'s signature and `Response` fields first (`grep -n "func actLogResolver" -A12 e2e/driver/actlog_test.go`; `grep -n "type Response struct" -A15 e2e/driver/*.go`) and adapt the assertions to the real field names.

- [ ] **Step 2: run** `go test ./e2e/driver/ -run 'ResizeAsks|FrontmostCarries'` — Expected: build failure.

- [ ] **Step 3: implement Go** — in `axresolve.go`: add `FocusedWithin []string \`json:"focusedWithin"\`` to `Frontmost` with a comment (SwiftUI puts the identifier on a wrapper; this is the focused element's own identifier, then each ancestor's, nearest first); add

```go
// Resize sets the fixture window's size, and reports it verified only when
// the window reads back at that size — a window with a minimum size clamps
// silently, and a check that asked for a narrow window and got a wide one
// would assert the wide layout.
func (r Resolver) Resize(pid, width, height int) (Response, error) {
	return r.run("the window", "--pid", strconv.Itoa(pid), "--resize", fmt.Sprintf("%dx%d", width, height))
}
```

- [ ] **Step 4: implement Swift** in `main.swift`:
  - `Frontmost` gains `let focusedWithin: [String]`; in `readFrontmost`, walk from the focused element up `kAXParentAttribute` (at most 64 steps, stop at a nil parent or role `AXWindow`), appending each non-empty `kAXIdentifierAttribute`, nearest first.
  - A `var resize: CGSize?` parsed from `--resize WxH` (`fail("bad_arguments", "--resize needs WIDTHxHEIGHT")` on a bad value); add it to the one-request-at-a-time check and the usage line; it needs no `--identifier`.
  - Right after `let window` is found (before `collect`):

```swift
if var size = resize {
    guard let value = AXValueCreate(.cgSize, &size) else {
        fail("resize_failed", "a size value could not be created")
    }
    let status = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    guard status == .success else {
        fail("resize_failed", "resizing the window returned AXError \(status.rawValue)")
    }
    // **Read back**: a window with a minimum size clamps without an error.
    guard let after = frame(of: window),
        abs(after.width - size.width) < 1, abs(after.height - size.height) < 1
    else {
        let got = frame(of: window).map { "\(Int($0.width))×\(Int($0.height))" } ?? "no size"
        fail("resize_not_applied",
             "asked for \(Int(size.width))×\(Int(size.height)) and the window is \(got) — "
                 + "it has a minimum or maximum size; ask for one inside it")
    }
    acted = Acted(action: "resize", identifier: "window", verified: true, reason: nil)
}
```

  Move `var acted: Acted?` above this block if it is declared later.

- [ ] **Step 5: build and test** `make axresolve && go test ./e2e/driver/` — Expected: build succeeds, `ok`. Then a no-screen smoke: `e2e/bin/axresolve --pid 1 --resize 10` — Expected: `bad_arguments` JSON.
- [ ] **Step 6: commit** `git add e2e/axresolve/main.swift e2e/driver/axresolve.go e2e/driver/layoutfocus_test.go && git commit -m "e2e: axresolve resizes the window, verified by read-back, and reports the focused element's identifier chain"`

---

### Task 4: The runner runs the arms

**Files:** Modify `e2e/driver/run.go` (`act`, `assert`); test `layoutfocus_test.go`.

**Interfaces — Consumes:** Tasks 1–3. **Produces:** `(*Runner).assertFocus(name string) error`, `(*Runner).assertFrame(*Expect) error`.

- [ ] **Step 1: failing tests** — build each runner with `newRunner(t, "", nil)` (runner_test.go) and replace `Resolver` with `Resolver{Exe: actLogResolver(t, reply)}`; set `Settle` to `-1` so a failure returns at once:

```go
func runnerAnswering(t *testing.T, reply string) *Runner {
	t.Helper()
	r, _ := newRunner(t, "", nil)
	r.Resolver = Resolver{Exe: actLogResolver(t, reply)}
	r.Settle = -1
	return r
}

func TestFocusMatchesAnAncestorOfTheFocusedElement(t *testing.T) {
	r := runnerAnswering(t, `{"ok":true,"frontmost":{"pid":1,"isTarget":false,"targetHasFocusedWindow":true,"focusedRole":"AXTextField","focusedWithin":["window.composer","window.bar"]}}`)
	if err := r.assert(&Expect{Focus: "window.bar"}); err != nil {
		t.Fatalf("an ancestor holds focus: %v", err)
	}
	err := r.assert(&Expect{Focus: "editor.pane"})
	if err == nil || !strings.Contains(err.Error(), "window.composer") {
		t.Fatalf("err = %v, want it to say where focus is", err)
	}
}

func TestFocusFailsWithNoFocusedWindow(t *testing.T) {
	r := runnerAnswering(t, `{"ok":true,"frontmost":{"pid":1,"targetHasFocusedWindow":false}}`)
	if err := r.assert(&Expect{Focus: "window.composer"}); err == nil || !strings.Contains(err.Error(), "no focused window") {
		t.Fatalf("err = %v", err)
	}
}

func TestAFrameStepOverAMissingElementFails(t *testing.T) {
	r := runnerAnswering(t, `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[]}`)
	if err := r.assert(&Expect{Frame: "api.recent", Inside: FrameWindow}); err == nil || !strings.Contains(err.Error(), "api.recent") {
		t.Fatalf("err = %v", err)
	}
}

func TestAFrameStepInsideTheWindowPasses(t *testing.T) {
	r := runnerAnswering(t, `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[{"identifier":"api.recent","role":"AXButton","enabled":true,"x":10,"y":10,"width":20,"height":10}]}`)
	if err := r.assert(&Expect{Frame: "api.recent", Inside: FrameWindow}); err != nil {
		t.Fatal(err)
	}
}

func TestAResizeTheWindowRefusedFailsTheStep(t *testing.T) {
	r := runnerAnswering(t, `{"ok":false,"error":{"code":"resize_not_applied","message":"asked for 300×200 and the window is 640×480"}}`)
	if _, err := r.act(&Do{Resize: &ResizeStep{Width: 300, Height: 200}}); err == nil || !strings.Contains(err.Error(), "640×480") {
		t.Fatalf("err = %v", err)
	}
}
```

Note `act` reads `Frontmost` before acting via the same fake; with this reply it fails to parse a frontmost reading, which `act` tolerates ("a reading that cannot be taken never blocks the act"). If `act` needs other fields, adapt.

- [ ] **Step 2: run** `go test ./e2e/driver/ -run 'FocusMatches|FocusFails|AFrameStep|AResizeThe'` — Expected: FAIL (no arm in `assert`/`act`).

- [ ] **Step 3: implement** in `run.go`:
  - `act`: `case do.Resize != nil: response, err = r.Resolver.Resize(r.PID, do.Resize.Width, do.Resize.Height)` (before the keystroke arms).
  - `assert`: `case expect.Focus != "": return r.settle(func() error { return r.assertFocus(expect.Focus) })`; `case expect.Frame != "": return r.settle(func() error { return r.assertFrame(expect) })`.
  - ```go
    // assertFocus reads the app's own focused element — never the system's, so
    // a check is not failed by another app taking the foreground (#418).
    func (r *Runner) assertFocus(name string) error {
    	front, err := r.Resolver.Frontmost(r.PID)
    	if err != nil {
    		return fmt.Errorf("focus could not be read: %w", err)
    	}
    	if !front.TargetHasFocusedWindow {
    		return fmt.Errorf("focus is not on %s: the app has no focused window", name)
    	}
    	if slices.Contains(front.FocusedWithin, name) {
    		return nil
    	}
    	return fmt.Errorf("focus is not on %s: it is on %s", name, front.String())
    }

    func (r *Runner) assertFrame(expect *Expect) error {
    	element, window, err := r.Resolver.Resolve(r.PID, expect.Frame)
    	if err != nil {
    		return err
    	}
    	var inside, clear *Rect
    	if expect.Inside == FrameWindow {
    		w := rectOfWindow(window)
    		inside = &w
    	} else if expect.Inside != "" {
    		other, _, err := r.Resolver.Resolve(r.PID, expect.Inside)
    		if err != nil {
    			return err
    		}
    		o := rectOfElement(other)
    		inside = &o
    	}
    	if expect.Clear != "" {
    		other, _, err := r.Resolver.Resolve(r.PID, expect.Clear)
    		if err != nil {
    			return err
    		}
    		o := rectOfElement(other)
    		clear = &o
    	}
    	return judgeFrame(expect, rectOfElement(element), inside, clear)
    }
    ```
  - If `Frontmost.String()` does not mention `FocusedWithin`, append `" (within " + strings.Join(front.FocusedWithin, " › ") + ")"` in the error so the reader sees the chain.

- [ ] **Step 4: run** `go test ./e2e/driver/` — Expected: `ok`.
- [ ] **Step 5: commit** `git add e2e/driver/run.go e2e/driver/layoutfocus_test.go && git commit -m "e2e: the runner asserts focus and frames, and resizes the window"`

---

### Task 5: The fixture — a rootless project and a spare account

**Files:** Modify `e2e/driver/seed.go`, `e2e/driver/launch.go` (`storeProviderCredential`), `e2e/driver/session.go` if it builds the spec. Test: `e2e/driver/seed_test.go`.

**Interfaces — Produces:** `SeedSpec.RootlessProject string` (default `"e2e-rootless"` in `DefaultSeed`); `SeedSpec.SpareProvider string` (set only when `AgentBinary != ""`, value `"e2e-provider-spare"`); `Seeded.SpareProvider string`.

- [ ] **Step 1: failing tests** — read `seed_test.go` first for how it seeds a temp fixture (`grep -n "func Test" e2e/driver/seed_test.go | head`), then add, in its style:
  - `TestTheRootlessProjectIsRegisteredAndNotActive`: after `Seed`, the registry for `e2e-fixture` lists `e2e-rootless`; its `project.json` loads with `LoadProject` and has zero roots; `ReadActive().Project` is still `e2e-project`'s path.
  - `TestTheSpareAccountExistsOnlyWithTheAgent`: with `AgentBinary` empty, `LoadProviderFor(org, "e2e-provider-spare")` fails; with it set, it loads, carries the same `ClaudePath`, and `Seeded.SpareProvider == "e2e-provider-spare"`; the org's `DefaultProvider` is still `e2e-provider`.

- [ ] **Step 2: run** `go test ./e2e/driver/ -run 'Rootless|SpareAccount'` — Expected: FAIL.

- [ ] **Step 3: implement**:
  - `seedOrgState`: after the main project, when `spec.RootlessProject != ""`, write `<root>/<RootlessProject>/.wakil/project.json` with `Roots: nil` (check `LoadProject` accepts it — `configtree.go:250` treats nil roots; if `LoadProject` refuses, use `Roots: []wakilcore.Root{}` and say so in a comment), the same `Environment` with no databases and no api entries; add it to `registry` with `Provider: spec.Provider`. Comment: why (80c97d7, the note derived from the live context), and that it is never active.
  - When `spec.SpareProvider != ""`: `AddProvider` a second `ProviderKindClaudeCode` with its own config dir `claude-<SpareProvider>`, same `ClaudePath`, label `"E2E spare account"`; copy the agent script into its config dir too. Comment: #331 and 2c-iv W1 need a second account USE can switch to.
  - `DefaultSeed` sets `RootlessProject: "e2e-rootless"`; wherever the agent launch sets `AgentBinary` (grep `AgentBinary:` in `session.go`), also set `SpareProvider: "e2e-provider-spare"`. `second()` copies neither.
  - `storeProviderCredential`: also store `provider:<SpareProvider>` with the same token when `l.Seeded.SpareProvider != ""` (loop over the two ids; one error message per id).

- [ ] **Step 4: run** `go test ./e2e/driver/` — Expected: `ok`.
- [ ] **Step 5: commit** `git add e2e/driver/seed.go e2e/driver/launch.go e2e/driver/session.go e2e/driver/seed_test.go && git commit -m "e2e: the fixture gains a rootless project, and the agent launch a spare credentialed account"`

---

### Task 6: The checks

**Files:** Create the check files below; modify `e2e/checks/seeded/api-paste-curl-hotkey.jsonl`, `e2e/checks/seeded/2e-settings-doors.jsonl` (lines 17–18), `e2e/checks/seeded/3b-v-click-focuses-pane.jsonl`, `e2e/checks/uncoverable.tsv`.

Every identifier and text must be confirmed with `grep -rn '<id>' app/Sources` before use. Parse-check every file without the screen: `go run ./e2e/cmd/wakil-e2e-select --evidence .scratch/lf/ev --only <file>` refuses an unparsable file only at run time, so instead run `go test ./e2e/driver/ -run TestEveryCheckParses` if it exists (`grep -n "func TestEvery.*Pars\|CheckCorpus()" e2e/driver/*_test.go`), else `go run ./e2e/cmd/wakil-e2e-cover` (it loads the whole corpus and fails on a parse error).

- [ ] **Step 1: the six writable checks**, contents exactly as below (verified identifiers, from the mapping in the spec):

`e2e/checks/seeded/2e-settings-unlink-indicator.jsonl`
```jsonl
{"expect":{"tree":"contains","text":"e2e-provider"}}
{"expect":{"tree":"absent","text":"unset"}}
{"do":{"hotkey":"cmd+,"}}
{"do":{"click":"settings.tree.providers"}}
{"do":{"click":"settings.row.e2e-provider.unlink"}}
{"do":{"click":"settings.unlink.confirm"}}
{"expect":{"tree":"contains","text":"no accounts registered in this organisation"}}
{"expect":{"tree":"contains","text":"unset"}}
```

`e2e/checks/seeded/365-terminal-option-word.jsonl`
```jsonl
{"do":{"click":"landing.row.open:terminal"}}
{"expect":{"pane":"terminal-1","field":"promptRow","present":true}}
{"do":{"keys":"echo aa bb cc"}}
{"expect":{"pane":"terminal-1","field":"grid","contains":"% echo aa bb cc"}}
{"do":{"hotkey":"option+Backspace"}}
{"do":{"hotkey":"option+Left"}}
{"do":{"keys":"X"}}
{"do":{"hotkey":"option+Right"}}
{"do":{"keys":"Y"}}
{"do":{"press":"Return"}}
{"expect":{"pane":"terminal-1","field":"blocks[-1].command","contains":"echo aa XbbY"}}
```

`e2e/checks/agent/api-draft-survives-first-turn.jsonl`
```jsonl
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_set_request","params":{"pane":"api-1","path":[{"literal":"/kept"}]}}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/kept"}}
{"do":{"type":{"into":"window.composer","text":"tell me a short joke"}}}
{"do":{"press":"Return"}}
{"expect":{"tree":"contains","text":"the joke turn arrived with no note"}}
{"expect":{"pane":"api-1","field":"entry","equals":"catalog"}}
{"expect":{"pane":"api-1","field":"request.path[0].literal","equals":"/kept"}}
```

`e2e/checks/seeded/api-recent-root.jsonl`
```jsonl
{"dispatch":{"action":"api_open","params":{"entry":"catalog"}}}
{"dispatch":{"action":"api_request","params":{"pane":"api-1"}}}
{"expect":{"pane":"api-1","field":"recent[0].method","equals":"GET"}}
{"do":{"click":"api.recent"}}
{"expect":{"tree":"contains","text":"GET / · no reply"}}
```

`e2e/checks/seeded/3b-ii-search-file-headers.jsonl` — lines 1–17 of `e2e/checks/seeded/3b-ii-search.jsonl` as they stand (copy with `sed -n 1,17p`), then:
```jsonl
{"expect":{"pane":"editor-1","field":"search.results[1]","present":true}}
{"do":{"click":"editor.search.group:e2e-portal/needle"}}
{"expect":{"tree":"absent","text":"needle in portal"}}
{"expect":{"tree":"contains","text":"needle in api"}}
{"do":{"click":"editor.search.group:e2e-api/needle"}}
{"expect":{"tree":"absent","text":"needle in api"}}
{"expect":{"pane":"editor-1","field":"search.results","contains":"needle in api"}}
```

`api-paste-curl-hotkey.jsonl`: append a `www.` case mirroring `api-paste-curl.jsonl:24-27`, but through the hotkey paste route the file already uses (read both files; copy the paste mechanism, change the host to `www.catalog.e2e-fixture.invalid`, and assert the same "matches its bare entry" line those lines assert).

- [ ] **Step 2: the three fixture-unlocked checks.** Write each from the defect's fix commit (`git show <sha> --stat` and the diff) and existing checks of the same surface:
  - `e2e/checks/seeded/project-root-note.jsonl` (80c97d7e): from `e2e-project`, assert the note text absent (find it: `git show 80c97d7e | grep '^+.*"' | grep -i root`), `dispatch ctx_set_project {"project":"e2e-rootless"}` (confirm param name in `StandardActions.swift`), expect the note present, switch back, expect it absent.
  - `e2e/checks/agent/2e-settings-use-keeps-pane.jsonl` (50f91022 / c431902d / bbb107b4): open Settings → providers (`cmd+,`, `settings.tree.providers`), click the spare row's USE (`settings.row.e2e-provider-spare.use` — confirm the id pattern in `SettingsPane.swift`), expect the settings pane still present (`expect.pane settings-1` field present) and the ACCOUNT indicator naming `e2e-provider-spare`.
  - `e2e/checks/agent/api-origin-after-account-switch.jsonl` (2c-iv W1): `api_open catalog`, expect its origin field (`grep -n origin` in an existing api check for the field name), USE the spare account, expect the origin unchanged, not empty.
  - Remove `2e-settings-doors.jsonl` lines 17–18 (they pass either way) and say so in the commit.

- [ ] **Step 3: the layout and focus checks.** For each, find the identifiers in the fix commit's diff, write the smallest check that drives the surface and asserts the frame or focus:
  - `e2e/checks/seeded/2e-settings-narrow-rows.jsonl` (64afbf8f, #326): `do.resize` to the narrowest width the fix names (read the commit), open Settings → providers, `expect.frame` on a row verb (e.g. `settings.row.e2e-provider.unlink`) with `minWidth` of a whole word (measure: the verb's text width at the app font; use the smallest bound that a one-letter-per-line column, about 10 pt, fails) and `maxHeight` of one line (≈ 24).
  - Add to `e2e/checks/seeded/3b-v-click-focuses-pane.jsonl` (236a6b31): after its click on the pane body, `{"expect":{"focus":"<the pane's identifier>"}}` (the identifier the check already clicks, or the pane container's — confirm which one `focusedWithin` will carry by reading the pane's view).
  - Palette rows centred in an empty plane (ea340628): no predicate in spec §3.2 says "sits directly under"; record it as residue (it needs an offset predicate), never a check that cannot fail.
  - `e2e/checks/seeded/api-recent-reachable.jsonl` (44d0305b): `api_open catalog` at the default pane size, send twice, `expect.frame` on `api.recent` `inside` the api pane's container (find its identifier) — before the fix the control was pushed out of the pane.
  - DB ⓘ (0e087c5e) is not in this branch's base; record it as residue until the stack is rebased on main.

- [ ] **Step 4: `uncoverable.tsv`**: re-reason the #325 / `settings.login.start` / `settings.login.dismiss` entries: "#254 is closed; driving Sign in with a made-up claude path still risks a real browser trip if the override were ever ignored, so it stays out of every launch."

- [ ] **Step 5: parse and gate, no screen**: the parse command from the top of this task, then `go run ./e2e/cmd/wakil-e2e-cover` (stale-denominator refusal is expected and fine; a parse error is not). Expected: no parse errors.

- [ ] **Step 6: commit** `git add e2e/checks && git commit -m "e2e: checks for the walk findings no check caught, and the first layout and focus checks"`

---

### Task 7: The guidelines

**Files:** Modify `docs/agents/e2e.md` (step 3), `CONTRIBUTING.md` (the tests-each-change-needs section — find it with `grep -n "e2e\|check" CONTRIBUTING.md`), `e2e/driver/check.go` (the step-vocabulary comment at the top of `Step`/`Do`/`Expect`).

- [ ] **Step 1:** In `docs/agents/e2e.md` step 3, after "Cover the interaction rules as well as the actions", add:

```markdown
   **Cover focus and layout, which the walks found most often.** A change
   that moves keyboard focus — a click that should take it, a pane that
   should give it up, a field that should keep it — owes an
   `{"expect":{"focus":"<id>"}}` check. A change to a surface's layout owes an
   `{"expect":{"frame":"<id>", …}}` check at a narrow window
   (`{"do":{"resize":{"width":…,"height":…}}}`): `inside` for a control that
   must stay reachable, `clear` for two that must not overlap, `minWidth` /
   `maxHeight` for a row that must not wrap into a column. The walk findings
   these catch — rows stacking one letter per line, controls pushed out of
   their pane, overlaps, focus not taken or not given back — are the list to
   check a UI change against. Twitch, colour and speed are not expressible
   yet; they stay walk-only and are named in the residue.
```

- [ ] **Step 2:** Mirror one paragraph in `CONTRIBUTING.md`'s tests section: "A UI change owes an e2e check for each focus change (`expect.focus`) and each layout change (`expect.frame` at a narrow `do.resize`) — see `docs/agents/e2e.md` step 3."
- [ ] **Step 3:** Document the three arms in `check.go`'s step comments (one sentence each, pointing at the spec).
- [ ] **Step 4:** `make docs-check && go test ./e2e/driver/` — Expected: both pass.
- [ ] **Step 5: commit** `git add docs/agents/e2e.md CONTRIBUTING.md e2e/driver/check.go && git commit -m "Docs: a focus change owes expect.focus, a layout change expect.frame at a narrow window"`

---

### Task 8: GUI proofs — controller only, after asking the operator

Bundle builds for the bases take no screen; run them first, in the background: for each base below, `make e2e-new E2E_NEW_ARGS="--base <sha>^ <check>"` builds `.context/e2e/bundles/<sha>` then launches (screen). To build without launching, run them only once the operator has said yes.

| Check | Base (`--base`) |
|---|---|
| `2e-settings-unlink-indicator` | `4e1492a2^` |
| `365-terminal-option-word` | `fa5e3e16^` |
| `api-draft-survives-first-turn` | `e51e847b^` |
| `api-recent-root` | `d7549158^` |
| `3b-ii-search-file-headers` | `948aeac8^` |
| `api-paste-curl-hotkey` (www case) | `19d493a3^` |
| `project-root-note` | `80c97d7e^` |
| `2e-settings-use-keeps-pane` | `50f91022^` |
| `api-origin-after-account-switch` | `57c7aeda^` (if green there, residue: the account half's fix commit is not identifiable) |
| `2e-settings-narrow-rows` | `64afbf8f^` |
| `3b-v-click-focuses-pane` | `236a6b31^` |
| `api-recent-reachable` | `44d0305b^` |

- [ ] **Step 1:** Ask the operator for the screen (one block of about 15 launches plus one full run). Check `ListAgents` for peers first.
- [ ] **Step 2:** For each row: `make e2e-new E2E_NEW_ARGS="--base <sha>^ e2e/checks/<dir>/<check>.jsonl"`. **Read each red's reason**: it must fail on the check's own assertion, not on an identifier the base lacks (that is red against anything). A base that will not build, or a check red only for a missing identifier, is residue.
- [ ] **Step 3:** Commit the proofs: `git add e2e/checks/proofs && git commit -m "e2e: red proofs for the walk-gap, layout and focus checks"`.
- [ ] **Step 4:** `make e2e` (selected) — Expected: the new checks green.
- [ ] **Step 5:** `make e2e-full` — `seed.go` changed, so every launch's fixture did. Expected green except a known #418 voice flake; any other red is read and fixed or reported.
- [ ] **Step 6:** Report the residue: every finding not covered and why.
