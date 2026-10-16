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
		`{"expect":{"focus":""}}`:                                         "names none",
		`{"expect":{"frame":"api.recent"}}`:                               "no predicate",
		`{"expect":{"frame":"api.recent","inside":"nowhere.x"}}`:          "registered surface",
		`{"expect":{"frame":"api.recent","minWidth":0}}`:                  "positive",
		`{"expect":{"frame":"api.recent","minWidth":50,"maxWidth":40}}`:   "exceeds",
		`{"expect":{"frame":"api.recent","inside":"api.recent"}}`:         "itself",
		`{"do":{"resize":{"width":0,"height":700}}}`:                      "positive",
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
