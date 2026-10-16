package driver_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func TestParseResolutionRefusesWhatItCannotUse(t *testing.T) {
	for name, output := range map[string]string{
		// A resolver that could not run at all and a window with no named
		// controls are different facts. Returning the second for the first
		// would make every assertion of absence pass.
		"no output":       "",
		"not JSON":        "dyld: Library not loaded: @rpath/libswiftCore.dylib",
		"no error detail": `{"ok":false}`,
		"no window":       `{"ok":true,"elements":[]}`,
	} {
		if _, err := driver.ParseResolution([]byte(output)); err == nil {
			t.Errorf("%s: parsed cleanly, want an error", name)
		}
	}
}

func TestParseResolutionCarriesTheRefusalsCode(t *testing.T) {
	_, err := driver.ParseResolution([]byte(
		`{"ok":false,"error":{"code":"accessibility_denied","message":"not trusted"}}`))
	if err == nil {
		t.Fatal("a refusal parsed as a success")
	}
	// A stale Accessibility grant must not read as "the identifier is not
	// there" — those send a reader to opposite places, and one of them is a
	// System Settings toggle no amount of debugging substitutes for.
	if !strings.Contains(err.Error(), "accessibility_denied") {
		t.Errorf("the refusal lost its code: %v", err)
	}
}

// AX really does report a laid-out column as 206.99999999998795 wide. The
// point is that a fractional frame produces a whole-pixel click at all.
// Clicking a disabled control does nothing, and an act that never happened
// followed by an assertion that nothing changed is a check that passes while
// proving the opposite of what it claims.
// OrgPlane's Escape button is a rendered zero-size view: it stays in the
// window's key-equivalent search and draws nothing. It has no pointer target,
// and saying so beats clicking (0, 0).
func TestResolveRefusesAnIdentifierThisRepoDoesNotOwn(t *testing.T) {
	resolver := driver.Resolver{Exe: fakeResolver(t, `{"ok":true,"window":{},"elements":[]}`)}
	// SwiftUI emits `ListColumn` and `SwiftUI.WindowGroup<…>` of its own, and
	// the system menu bar carries `_shutDownRequested:` among forty siblings.
	// None is ours, and driving one is not a thing a check may do by accident.
	if _, _, err := resolver.Resolve(1, "ListColumn"); err == nil {
		t.Error("resolved an identifier outside every registered surface")
	}
}

func TestResolveRefusesZeroAndSeveral(t *testing.T) {
	element := `{"identifier":"rail.db-1","role":"AXButton","enabled":true,` +
		`"x":10,"y":20,"width":30,"height":40}`
	window := `"window":{"x":0,"y":50,"width":1710,"height":1050}`

	none := driver.Resolver{Exe: fakeResolver(t,
		fmt.Sprintf(`{"ok":true,%s,"elements":[]}`, window))}
	_, _, err := none.Resolve(1, "rail.db-1")
	if err == nil {
		t.Error("an identifier matching nothing resolved cleanly")
	}

	several := driver.Resolver{Exe: fakeResolver(t,
		fmt.Sprintf(`{"ok":true,%s,"elements":[%s,%s]}`, window, element, element))}
	_, _, err = several.Resolve(1, "rail.db-1")
	if err == nil {
		t.Fatal("an identifier matching twice resolved cleanly")
	}
	if !strings.Contains(err.Error(), "2 elements") {
		t.Errorf("the refusal does not say how many matched: %v", err)
	}

	one := driver.Resolver{Exe: fakeResolver(t,
		fmt.Sprintf(`{"ok":true,%s,"elements":[%s]}`, window, element))}
	got, _, err := one.Resolve(1, "rail.db-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Identifier != "rail.db-1" {
		t.Errorf("resolved %q", got.Identifier)
	}
}

// The frameworks' own identifiers are not part of the denominator and must not
// appear in a listing that is compared against the harvest.
func TestReadKeepsOnlyTheRegisteredSurfaces(t *testing.T) {
	resolver := driver.Resolver{Exe: fakeResolver(t, `{"ok":true,
	  "window":{"x":0,"y":50,"width":1710,"height":1050},
	  "elements":[
	    {"identifier":"SwiftUI.WindowGroup<X>-1-AppWindow-1","role":"AXWindow","enabled":true,"x":0,"y":50,"width":1710,"height":1050},
	    {"identifier":"ListColumn","role":"AXColumn","enabled":true,"x":1,"y":2,"width":3,"height":4},
	    {"identifier":"window.send","role":"AXButton","enabled":true,"x":5,"y":6,"width":7,"height":8}
	  ]}`)}
	resolution, err := resolver.Read(1)
	if err != nil {
		t.Fatal(err)
	}
	if len(resolution.Elements) != 1 || resolution.Elements[0].Identifier != "window.send" {
		t.Errorf("got %v, want only window.send", resolution.Elements)
	}
}

// fakeResolver writes a stand-in that prints one fixed reply, so the 0/1/many
// rules are exercised without a window.
func fakeResolver(t *testing.T, reply string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "axresolve")
	script := fmt.Sprintf("#!/bin/sh\ncat <<'REPLY'\n%s\nREPLY\n", reply)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// --- #251: the resolver as the write channel ------------------------------

func actingResolver(t *testing.T, body string, exitCode int) string {
	t.Helper()
	dir := t.TempDir()
	exe := filepath.Join(dir, "axresolve")
	script := "#!/bin/sh\ncat <<'PAYLOAD'\n" + body + "\nPAYLOAD\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

const pressedJSON = `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[],
  "acted":{"action":"press","identifier":"rail.db-1","verified":false,
           "reason":"accessibility_action_unasserted"}}`

const setJSON = `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[],
  "acted":{"action":"set-value","identifier":"window.composer","verified":true}}`

// A press cannot be verified — AX reports no outcome for one — and saying so
// is what hands the act to the runner's confirmation rule instead of letting
// it pass unexamined.
func TestPressReportsAnUnverifiedAct(t *testing.T) {
	got, err := (driver.Resolver{Exe: actingResolver(t, pressedJSON, 0)}).Press(44187, "rail.db-1")
	if err != nil {
		t.Fatalf("Press: %v", err)
	}
	if !got.OK || !got.Acted {
		t.Fatalf("got %+v", got)
	}
	if got.Verified {
		t.Fatal("a press must never report itself verified")
	}
	if driver.UnverifiedReason(got.ActPath, got.ActReason) != "accessibility action unasserted" {
		t.Fatalf("reason = %q", driver.UnverifiedReason(got.ActPath, got.ActReason))
	}
}

// **The one act that comes back genuinely verified**, because the resolver
// reads the value back before reporting success. Neither channel could do
// this before: Orca's set-value needs an element index #250 ruled out.
func TestSetValueReportsAVerifiedAct(t *testing.T) {
	got, err := (driver.Resolver{Exe: actingResolver(t, setJSON, 0)}).SetValue(44187, "window.composer", "hello")
	if err != nil {
		t.Fatalf("SetValue: %v", err)
	}
	if !got.Verified {
		t.Fatal("a set-value that was read back must report verified")
	}
}

// A refusal is an error carrying what was refused, never a silent success.
func TestPressSurfacesARefusal(t *testing.T) {
	body := `{"ok":false,"error":{"code":"disabled","message":"the control is disabled"}}`
	_, err := (driver.Resolver{Exe: actingResolver(t, body, 1)}).Press(44187, "rail.db-1")
	if err == nil {
		t.Fatal("want an error when the act was refused")
	}
	if !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("error must carry the refusal, got %q", err)
	}
}

// **A reply that describes no act is an error.** The resolver reporting
// success while saying nothing about what it did would let a check pass on an
// act nothing knows happened.
func TestPressRefusesAReplyThatDescribesNoAct(t *testing.T) {
	body := `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[]}`
	_, err := (driver.Resolver{Exe: actingResolver(t, body, 0)}).Press(44187, "rail.db-1")
	if err == nil {
		t.Fatal("want an error when the reply describes no act")
	}
}

// An identifier outside the registered surfaces cannot be acted on, and is
// refused before a process is even started.
func TestPressRefusesAnUnregisteredSurface(t *testing.T) {
	_, err := (driver.Resolver{Exe: actingResolver(t, pressedJSON, 0)}).Press(44187, "teleporter.mars")
	if err == nil {
		t.Fatal("want an error for an identifier in no registered surface")
	}
}

// --- #284: what the window server believed at the act ----------------------

const pressedWhileFinderWasFrontJSON = `{"ok":true,
  "window":{"x":0,"y":0,"width":100,"height":100},"elements":[],
  "acted":{"action":"press","identifier":"window.send","verified":false,
           "reason":"accessibility_action_unasserted"},
  "frontmost":{"pid":99,"bundleId":"com.apple.finder","isTarget":false,
               "targetHasFocusedWindow":false,"focusedIdentifier":""}}`

// A press reports success whatever happened, so the reading beside it is the
// only thing that separates a press that ran from one that did not (#284). It
// has to survive the wire to be worth taking.
func TestAPressCarriesWhatTheWindowServerBelieved(t *testing.T) {
	got, err := (driver.Resolver{Exe: actingResolver(t, pressedWhileFinderWasFrontJSON, 0)}).
		Press(44187, "window.send")
	if err != nil {
		t.Fatalf("Press: %v", err)
	}
	if got.Frontmost == nil {
		t.Fatal("the press carried no reading, so a silent one would be indistinguishable")
	}
	if got.Frontmost.IsTarget || got.Frontmost.BundleID != "com.apple.finder" {
		t.Errorf("got %+v, want Finder frontmost and not the target", got.Frontmost)
	}
	if got.Frontmost.TargetHasFocusedWindow {
		t.Error("the reply said the target had no focused window and the parse lost it")
	}
}

// A reply with no reading must leave a nil rather than a zero value: a
// `Frontmost{}` would read as "pid 0 was front, and it was not the fixture",
// which is a claim nothing measured.
func TestAnActWithNoReadingCarriesNoneRatherThanAZeroOne(t *testing.T) {
	got, err := (driver.Resolver{Exe: actingResolver(t, pressedJSON, 0)}).Press(44187, "rail.db-1")
	if err != nil {
		t.Fatalf("Press: %v", err)
	}
	if got.Frontmost != nil {
		t.Errorf("a reply carrying no reading produced %+v", got.Frontmost)
	}
}

// --- Task 7: the drag ---------------------------------------------------------

const draggedJSON = `{"ok":true,"window":{"x":0,"y":0,"width":100,"height":100},"elements":[],
  "acted":{"action":"drag","identifier":"pane.db-1.grip","verified":false,
           "reason":"synthetic_input"}}`

// argRecordingResolver replies with body and writes the arguments it was
// given to a file, so a test can see what the driver asked for.
func argRecordingResolver(t *testing.T, body string) (exe, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	exe = filepath.Join(dir, "axresolve")
	argsFile = filepath.Join(dir, "args")
	script := "#!/bin/sh\necho \"$@\" > '" + argsFile + "'\ncat <<'PAYLOAD'\n" + body + "\nPAYLOAD\n"
	if err := os.WriteFile(exe, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe, argsFile
}

// A synthetic drag reports no outcome — a failed one simply does not drop —
// so it is unverified, and the runner's confirmation rule takes it from there.
func TestDragReportsAnUnverifiedSyntheticAct(t *testing.T) {
	exe, argsFile := argRecordingResolver(t, draggedJSON)
	got, err := (driver.Resolver{Exe: exe}).Drag(44187, "pane.db-1.grip", "api.pane")
	if err != nil {
		t.Fatalf("Drag: %v", err)
	}
	if !got.OK || !got.Acted || got.Verified {
		t.Fatalf("got %+v, want an act reported unverified", got)
	}
	if reason := driver.UnverifiedReason(got.ActPath, got.ActReason); reason != "synthetic input" {
		t.Fatalf("reason = %q", reason)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	if want := "--pid 44187 --identifier pane.db-1.grip --drag-to api.pane"; strings.TrimSpace(string(args)) != want {
		t.Fatalf("args = %q, want %q", args, want)
	}
}

func TestDragRefusesAnUnregisteredTarget(t *testing.T) {
	exe, _ := argRecordingResolver(t, draggedJSON)
	_, err := (driver.Resolver{Exe: exe}).Drag(44187, "pane.db-1.grip", "teleporter.mars")
	if err == nil || !strings.Contains(err.Error(), "teleporter") {
		t.Fatalf("err = %v", err)
	}
}
