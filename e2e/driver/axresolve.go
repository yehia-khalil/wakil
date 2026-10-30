package driver

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// Resolver runs the axresolve helper: the harness's read AND write path for
// named controls.
//
// **It exists because `get-app-state` cannot answer this question.** Orca's
// snapshot never emits an identifier — for a button its formatter prints
// `AXTitle` or `AXValue` and nothing else, under any flag
// (docs/wakil/agent-e2e-probe.md §4b). So the identifier is resolved here.
//
// **And it acts, since 2026-09-23.** The probe kept actuation in Orca; Orca
// then refused to click the fixture at all, under four different remedies,
// while the system reported the window frontmost and focused. The reversal is
// argued where its measurements are, in e2e/axresolve/main.swift.
type Resolver struct {
	Exe string
}

// Element is one identified element, in SCREEN coordinates with a top-left
// origin — the space `AXPosition` reports.
type Element struct {
	Identifier string  `json:"identifier"`
	Role       string  `json:"role"`
	Enabled    bool    `json:"enabled"`
	// Label is AXDescription, else AXTitle: the element's name aloud, which
	// orca's tree text never prints for a button (axresolve's header).
	Label string `json:"label"`
	X          float64 `json:"x"`
	Y          float64 `json:"y"`
	Width      float64 `json:"width"`
	Height     float64 `json:"height"`
}

// WindowFrame is the window's own rectangle, in the same screen space.
//
// **Measured identical to Orca's.** With one Wakil open, AX reported
// `(0, 50, 1710, 1050)` and Orca's snapshot reported
// `{x:0, y:50, width:1710, height:1050}` for the same window. That is what
// makes the conversion below a subtraction rather than a calibration.
type WindowFrame struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// Resolution is one read of an instance's named elements.
type Resolution struct {
	Window    WindowFrame `json:"window"`
	Elements  []Element   `json:"elements"`
	Acted     *Acted      `json:"acted"`
	Frontmost *Frontmost  `json:"frontmost"`
}

// Frontmost is what the window server believed at the moment of an act.
//
// **It exists because a press cannot describe itself.** AX reports no outcome
// for `AXPress`, so a press that ran and a press that silently did nothing are
// the same `.success`, and #284 is that shape exactly: `window.send` pressed
// ok, the button enabled, and no turn started. No assertion separates them.
// The state around the act can be recorded, and is.
//
// Nil on a read, which drives nothing and so has no moment to describe.
type Frontmost struct {
	PID      int    `json:"pid"`
	BundleID string `json:"bundleId"`
	// IsTarget says whether the process the window server considers frontmost
	// is the one being driven.
	IsTarget bool `json:"isTarget"`
	// TargetHasFocusedWindow says whether the driven app has a focused window
	// at all. An app can be frontmost with none — behind a locked screen it
	// has no window whatever (#284) — and a press into that is a press into
	// nothing.
	TargetHasFocusedWindow bool `json:"targetHasFocusedWindow"`
	// FocusedIdentifier names whatever holds keyboard focus system-wide.
	// `do.type` focuses a field and types into it, so a press that followed
	// one should still find that field here.
	FocusedIdentifier string `json:"focusedIdentifier"`
	// FocusedRole is what there is to say when the focused element carries no
	// identifier, which is usual: SwiftUI puts the identifier on a wrapper and
	// the focus on the `AXTextField` inside it. `AXTextField` and `AXWindow`
	// are different answers to where the keystrokes went.
	FocusedRole string `json:"focusedRole"`
	// FocusedWithin is the focused element's own identifier, then each
	// ancestor's, nearest first. SwiftUI puts the identifier on a wrapper and
	// the focus on the field inside it, so `expect.focus` looks for the name
	// here rather than in FocusedIdentifier.
	FocusedWithin []string `json:"focusedWithin,omitempty"`
}

// String describes one reading as a line of a run's act log.
func (f *Frontmost) String() string {
	if f == nil {
		return "the window server was not asked"
	}
	who := fmt.Sprintf("pid %d", f.PID)
	if f.BundleID != "" {
		who = f.BundleID + " (" + who + ")"
	}
	if !f.IsTarget {
		who = "NOT the fixture: " + who
	}
	focused := f.FocusedIdentifier
	if focused == "" {
		focused = "an unnamed " + f.FocusedRole
		if f.FocusedRole == "" {
			focused = "nothing at all"
		}
	}
	window := "the fixture has a focused window"
	if !f.TargetHasFocusedWindow {
		window = "THE FIXTURE HAS NO FOCUSED WINDOW"
	}
	return fmt.Sprintf("frontmost %s; %s; keyboard focus on %s", who, window, focused)
}

// Acted is what an act did, as the resolver reports it.
type Acted struct {
	Action     string `json:"action"`
	Identifier string `json:"identifier"`
	Verified   bool   `json:"verified"`
	Reason     string `json:"reason"`
}

type resolverReply struct {
	OK        bool         `json:"ok"`
	Window    *WindowFrame `json:"window"`
	Elements  []Element    `json:"elements"`
	Acted     *Acted       `json:"acted"`
	Frontmost *Frontmost   `json:"frontmost"`
	Error     *OrcaError   `json:"error"`
}

// Read returns every element of pid's window that carries an identifier this
// repo owns.
//
// **Filtered to the registered surfaces, and that is not tidiness.** SwiftUI
// emits identifiers of its own — a window carries
// `SwiftUI.WindowGroup<…>-1-AppWindow-1` and a list carries `ListColumn` — and
// the system menu bar carries forty more, `_shutDownRequested:` among them.
// The surface list is what separates the ones the app declares from the ones
// the frameworks happen to leave lying around.
func (r Resolver) Read(pid int) (Resolution, error) {
	resolution, err := r.read(pid, "")
	if err != nil {
		return Resolution{}, err
	}
	ours := resolution.Elements[:0]
	for _, element := range resolution.Elements {
		if isSurface(firstSegment(element.Identifier)) {
			ours = append(ours, element)
		}
	}
	resolution.Elements = ours
	return resolution, nil
}

// Resolve returns the one element named by identifier.
//
// **Zero and several are both failures, never a retry.** #250 says so and the
// reason is the same in both directions: an identifier that matches nothing
// may be a control that was renamed, a screen that never opened, or a
// permission that went stale, and an identifier that matches twice means the
// harness cannot tell which control it is about to drive. Guessing at either
// is how a check comes to assert nothing and pass.
func (r Resolver) Resolve(pid int, identifier string) (Element, WindowFrame, error) {
	if !isSurface(firstSegment(identifier)) {
		return Element{}, WindowFrame{}, fmt.Errorf(
			"%q is not in a registered surface (%s), so it is not an identifier this repo owns",
			identifier, strings.Join(Surfaces, ", "))
	}
	resolution, err := r.read(pid, identifier)
	if err != nil {
		return Element{}, WindowFrame{}, err
	}
	switch len(resolution.Elements) {
	case 1:
		return resolution.Elements[0], resolution.Window, nil
	case 0:
		present, readErr := r.Read(pid)
		if readErr != nil {
			return Element{}, WindowFrame{}, fmt.Errorf(
				"%q matched no element, and the window could not be listed either: %w",
				identifier, readErr)
		}
		return Element{}, WindowFrame{}, fmt.Errorf(
			"%q matched no element. The window carries %d named element(s): %s",
			identifier, len(present.Elements), strings.Join(names(present.Elements), ", "))
	default:
		return Element{}, WindowFrame{}, fmt.Errorf(
			"%q matched %d elements, so the check cannot say which one it means; "+
				"give the control a name that includes what distinguishes it",
			identifier, len(resolution.Elements))
	}
}

func (r Resolver) read(pid int, identifier string) (Resolution, error) {
	args := []string{"--pid", strconv.Itoa(pid)}
	if identifier != "" {
		args = append(args, "--identifier", identifier)
	}
	command := exec.Command(r.Exe, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	_ = command.Run() // a refusal is a well-formed reply, not an error

	return ParseResolution(stdout.Bytes())
}

// ParseResolution decodes one axresolve reply.
//
// **Empty output is an error, never an empty window.** A resolver that could
// not run at all and a window with no named controls are different facts, and
// a lenient parse would hand a check the second when the first is true — so
// every `expect` that asserts absence would pass.
func ParseResolution(output []byte) (Resolution, error) {
	if len(bytes.TrimSpace(output)) == 0 {
		return Resolution{}, fmt.Errorf("axresolve produced no output")
	}
	var reply resolverReply
	if err := json.Unmarshal(output, &reply); err != nil {
		return Resolution{}, fmt.Errorf(
			"axresolve output was not JSON (%w): %s", err, firstLine(output))
	}
	if !reply.OK {
		if reply.Error == nil {
			return Resolution{}, fmt.Errorf(
				"axresolve reported failure with no error payload: %s", firstLine(output))
		}
		return Resolution{}, fmt.Errorf("axresolve: %w", reply.Error)
	}
	if reply.Window == nil {
		return Resolution{}, fmt.Errorf("axresolve reported success with no window")
	}
	return Resolution{
		Window: *reply.Window, Elements: reply.Elements,
		Acted: reply.Acted, Frontmost: reply.Frontmost,
	}, nil
}

// Press presses the element named by identifier.
//
// **This is the harness's write channel, and it is ours on purpose.** Orca
// refuses to click the fixture at all — `window_not_focused: ... (current: no
// focused window)` while the system reports that pid frontmost with a focused
// window — and four remedies, including Orca's own, were each refused. The
// reversal of the probe's "all actuation stays in Orca" is argued in
// e2e/axresolve/main.swift's header, where the measurements are.
//
// A press is reported UNVERIFIED, because AX reports no outcome for one. That
// is not a weakness of this path: Orca's coordinate click is unverified too,
// and what actually establishes an act landed is the runner's rule that an
// unverified act must be confirmed by a positive read of the window.
func (r Resolver) Press(pid int, identifier string) (Response, error) {
	return r.act(pid, identifier, "--press")
}

// Focus gives a control keyboard focus through the accessibility API.
//
// **Not a press and not a click.** A text field refuses `AXPress` (AXError
// -25206) and takes no focus from `set-value`; a coordinate click would focus
// it, and Orca refuses one unless the target window is the focused topmost
// recipient, which a fixture window launched by `open -n` never is. Setting
// `AXFocused` needs neither, and unlike a press it is verified — the attribute
// is read back, because focus is state.
func (r Resolver) Focus(pid int, identifier string) (Response, error) {
	return r.act(pid, identifier, "--focus")
}

// SetValue writes the accessibility value of the element named by identifier.
//
// **No step kind takes this path any more, and the reason is #284's Defect
// 2.** It came back verified — the resolver reads the value back — and did
// not take the foreground, which is why `do.type` was built on it. Neither
// property was worth anything: on a SwiftUI `TextField` the write lands on
// the element and never on the `@State` behind it, so the app sends the empty
// string while the tree, and any `expect.tree`, reads as though the text
// arrived. `Runner.typeInto` focuses and types instead.
//
// It stays because `--set-value` is a real capability of the resolver and
// this is its wrapper — reading a field back after writing it is a diagnostic
// worth having — but a check that wants text IN THE APP wants `do.type`.
func (r Resolver) SetValue(pid int, identifier, text string) (Response, error) {
	return r.act(pid, identifier, "--set-value", text)
}

// Drag picks up the element named from and drops it on the element named to.
//
// **Synthetic mouse events, not an accessibility action**, because there is no
// AX action for a drag. The resolver posts the sequence 2c-iv's Task 1
// measured — at least twenty `leftMouseDragged` 10 ms apart between the two
// centres, one per 50pt when that is more, no hold after mouse-down — which
// dropped nine of nine where ten steps dropped eleven of fifteen; then, since
// Ruling 12, a rest at the target before the mouse-up.
//
// **Reported unverified, and never retried.** A failed synthetic drag is a
// session that never reached the target: nothing drops and nothing says so.
// As with a press, what establishes it landed is the runner's rule that an
// unverified act must be confirmed by a later positive read.
func (r Resolver) Drag(pid int, from, to string) (Response, error) {
	if !isSurface(firstSegment(to)) {
		return Response{}, fmt.Errorf(
			"%q is not in a registered surface (%s), so it is not an identifier this repo owns",
			to, strings.Join(Surfaces, ", "))
	}
	return r.act(pid, from, "--drag-to", to)
}

// Modifier posts one modifier key going down, or coming up, to the fixture.
//
// **A real `flagsChanged`, through the HID event tap**, which is the path a
// keyboard's own modifier takes and therefore the one the app's
// `NSEvent` monitor reads ⌥ from (2d-ii's push-to-talk). Not posted to the
// pid: an event delivered that way bypasses the window server's routing, so
// it reaches the app with no key window attached, and the composer bar
// ignores any event whose window is not its own key window. The resolver
// brings the fixture forward first, as it does for a drag, because a key
// event goes to whatever is frontmost.
//
// **Reported unverified, and never retried.** Nothing on screen says a
// modifier is down; what the hold draws — the words heard, a notice — is the
// positive read that confirms it, as for a press.
func (r Resolver) Modifier(pid int, key string, down bool) (Response, error) {
	if err := validModifier(key); err != nil {
		return Response{}, err
	}
	flag := "--key-up"
	if down {
		flag = "--key-down"
	}
	return r.run(key, "--pid", strconv.Itoa(pid), flag, key)
}

// Resize sets the fixture window's size, and the resolver reports it verified
// only when the window reads back at that size — a window with a minimum size
// clamps silently, and a check that asked for a narrow window and got a wide
// one would assert the wide layout.
func (r Resolver) Resize(pid, width, height int) (Response, error) {
	return r.run("the window", "--pid", strconv.Itoa(pid), "--resize", fmt.Sprintf("%dx%d", width, height))
}

// Frontmost reads what the window server believes, without acting.
//
// **For the acts this channel does not deliver.** The keystroke arms go
// through Orca, which reports nothing of the kind, and `do.type` ends in one
// of them — so without this, the arm #284's second defect lived in would be
// the one arm whose act log said nothing. It is a diagnostic: a failure to
// read is reported as no reading, never as a failed act.
//
// **It answers for an app with no window**, which the resolver's other modes
// refuse. That state is the reading worth having: behind a locked screen the
// fixture runs, is frontmost, and presents nothing (#284).
func (r Resolver) Frontmost(pid int) (*Frontmost, error) {
	var stdout, stderr bytes.Buffer
	command := exec.Command(r.Exe, "--pid", strconv.Itoa(pid), "--frontmost")
	command.Stdout, command.Stderr = &stdout, &stderr
	_ = command.Run() // a refusal is a well-formed reply, not an error

	// **Parsed here rather than through ParseResolution**, which requires a
	// window and is right to: every other mode reports one, and a reply
	// without it means the tree was never read. This mode deliberately
	// answers before any window is required, so it needs its own reader —
	// and routing it through the strict one is how this came back empty on
	// its first live run, with nothing said about why.
	var reply resolverReply
	if err := json.Unmarshal(stdout.Bytes(), &reply); err != nil {
		return nil, fmt.Errorf("the window server could not be read (%w): %s",
			err, firstLine(stdout.Bytes()))
	}
	if !reply.OK {
		return nil, fmt.Errorf("the window server could not be read: %v", reply.Error)
	}
	if reply.Frontmost == nil {
		return nil, fmt.Errorf("axresolve answered ok and described no reading")
	}
	return reply.Frontmost, nil
}

func (r Resolver) act(pid int, identifier string, action ...string) (Response, error) {
	if !isSurface(firstSegment(identifier)) {
		return Response{}, fmt.Errorf(
			"%q is not in a registered surface (%s), so it is not an identifier this repo owns",
			identifier, strings.Join(Surfaces, ", "))
	}
	args := append([]string{"--pid", strconv.Itoa(pid), "--identifier", identifier}, action...)
	return r.run(identifier, args...)
}

// run invokes the resolver for one act and reads its reply. `about` names what
// the act was aimed at, for a reply that describes no act.
func (r Resolver) run(about string, args ...string) (Response, error) {
	command := exec.Command(r.Exe, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	_ = command.Run() // a refusal is a well-formed reply, not an error

	resolution, err := ParseResolution(stdout.Bytes())
	if err != nil {
		return Response{}, err
	}
	if resolution.Acted == nil {
		return Response{}, fmt.Errorf(
			"the resolver reported success but described no act on %q, so nothing is known "+
				"about whether it happened", about)
	}
	// A drag and a modifier are posted as events, which is the path Orca
	// calls "synthetic"; every other act goes through the accessibility API.
	path := "accessibility"
	switch resolution.Acted.Action {
	case "drag", "key-down", "key-up":
		path = "synthetic"
	}
	return Response{
		OK:        true,
		Acted:     true,
		Verified:  resolution.Acted.Verified,
		ActPath:   path,
		ActReason: resolution.Acted.Reason,
		Frontmost: resolution.Frontmost,
	}, nil
}

func firstSegment(identifier string) string {
	segment, _, _ := strings.Cut(identifier, ".")
	return segment
}

func names(elements []Element) []string {
	var out []string
	for _, element := range elements {
		out = append(out, element.Identifier)
	}
	sort.Strings(out)
	return out
}

// WatchInput starts `axresolve --watch-input`, a listen-only event tap, and
// returns once the tap is installed. Its stop closes the tap and reports every
// keyboard and pointer event delivered meanwhile, with who posted it (#339).
//
// **A process per act, not one per run.** It costs a launch per keyboard act,
// and buys a reply that can only be about that act.
func (r Resolver) WatchInput() (func() ([]InputEvent, error), error) {
	command := exec.Command(r.Exe, "--watch-input")
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := command.Start(); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(stdout)
	ready, err := reader.ReadBytes('\n')
	if err != nil || strings.TrimSpace(string(ready)) != "ready" {
		_ = stdin.Close()
		_ = command.Wait()
		if _, refused := parseInputReply(ready); refused != nil {
			return nil, refused
		}
		return nil, fmt.Errorf("the input watcher did not start: %s", firstLine(ready))
	}
	return func() ([]InputEvent, error) {
		_ = stdin.Close()
		out, _ := io.ReadAll(reader)
		_ = command.Wait()
		return parseInputReply(bytes.TrimSpace(out))
	}, nil
}
