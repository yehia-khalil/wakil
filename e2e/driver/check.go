package driver

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Check is one flow: a named file of steps.
type Check struct {
	Name  string
	Steps []Step
}

// Step is one line of a check file, and carries exactly one of the four kinds.
//
// `do` drives the GUI, `dispatch` drives the agent channel, `expect` asserts,
// and `parity` does both drives and asserts they landed identically. The
// format is declarative so the auditor can write checks without editing Go —
// the same reasoning that produced `scripts/checks/layout-dual-drive.jsonl`.
//
// **Exactly one kind, enforced at parse.** A line carrying two would run one
// and drop the other, and which one ran would depend on field order in a
// struct the check author never sees.
//
// **Focus and layout are arms, not kinds** (2026-10-15-e2e-walk-gaps-layout-
// focus-design.md): `expect.focus` asserts which control holds the keyboard,
// `expect.frame` holds a control's rectangle inside the window or another
// control, clear of one, or within size bounds, and `do.resize` makes the
// window narrow first. The walks found these defects more than any other kind.
type Step struct {
	Do       *Do       `json:"do,omitempty"`
	Dispatch *Dispatch `json:"dispatch,omitempty"`
	Expect   *Expect   `json:"expect,omitempty"`
	Parity   *Parity   `json:"parity,omitempty"`
}

// Do drives the GUI: the channel an operator's hands are on.
//
// **Exactly one arm per step**, for the same reason a line carries exactly
// one step kind: a `do` with two would run one and drop the other, and which
// one ran would depend on field order in a struct the check author never sees.
type Do struct {
	// Click presses a control by identifier. **It takes the foreground.**
	// Measured: AXPress activates the app — Arc frontmost, click, Wakil
	// frontmost, reproduced on a second control, with a failed click leaving
	// Arc frontmost as the control.
	Click string `json:"click,omitempty"`
	// Type puts text in a field, by focusing it and typing at it for real.
	//
	// **It was `set-value` alone until #284, and that could not put text into
	// this app at all.** The value landed in the element's accessibility
	// value, was read back, and reported verified — while the SwiftUI binding
	// behind the field never saw a character, so the send that followed sent
	// the empty string. A check could assert nothing that told the two apart.
	// The measurement and what replaced it are in `Runner.typeInto`.
	//
	// It therefore takes the foreground, as every real keystroke does, and it
	// APPENDS at the insertion point rather than replacing what is there.
	Type *TypeInto `json:"type,omitempty"`

	// The three keyboard arms, added by #253.
	//
	// **A shell cannot be driven any other way.** `click` presses a named
	// control and `type` addresses a named field; a terminal pane has
	// neither. What it has is a PTY, and the only thing a PTY reads is
	// keystrokes — so six of 2c-iii's seven mechanizable checks are
	// unwritable without these.
	//
	// **They are aimed at whatever holds keyboard focus, not at a named
	// element**, which is the one place this vocabulary addresses something
	// by position rather than by name. It is unavoidable: the terminal grid
	// is a canvas, it carries no identifier, and there is no field on it to
	// address. The mitigation is that a check must FOCUS the pane it
	// means first — by clicking its rail row, or by dispatching `pane_focus`
	// — and then assert what it typed actually arrived.

	// Keys types literal text.
	Keys string `json:"keys,omitempty"`
	// Press sends one named key: Return, Escape, Tab, Left, PageUp.
	Press string `json:"press,omitempty"`
	// Hotkey sends a modifier chord — `ctrl+c` is the one 2c-iii's check 5
	// needs, and it is a chord rather than a key precisely because the PTY
	// has to receive an interrupt and not the letter c.
	Hotkey string `json:"hotkey,omitempty"`

	// Focus gives a control keyboard focus, by setting `AXFocused` on it.
	//
	// **A text field cannot be focused any other way.** Measured 2026-09-24
	// against the agent composer: `AXPress` returns AXError -25206, action
	// unsupported, and `set-value` puts the text in the field's accessibility
	// value without moving focus or, in SwiftUI's case, without the binding
	// behind it ever seeing it — a send that followed sent nothing. The
	// composer has no `@FocusState` of its own (`ConfirmationPlane` and
	// `TerminalPane` are the only two in `WakilApp`), so nothing in the app
	// can be asked to focus it either.
	//
	// **It costs no foreground, and unlike a press it is verified**: the
	// attribute is read back, because focus is state. What the keystroke arms
	// then send does need the foreground, which is where that cost is paid —
	// see `Resolver.Focus`, where the coordinate click this once was and why
	// Orca refused it are recorded.
	Focus string `json:"focus,omitempty"`

	// Drag presses the mouse down on one control and lets it go on another,
	// through synthetic mouse events rather than the accessibility API.
	//
	// **There is no accessibility action for a drag**, so this is the one arm
	// that posts real pointer events: `leftMouseDown` at the source's centre,
	// at least twenty `leftMouseDragged` 10 ms apart along the line (one per
	// 50pt when that is more), a rest at the target, then `leftMouseUp` there
	// — the sequence Task 1 of 2c-iv measured dropping nine of nine (ten steps
	// dropped eleven of fifteen), with Ruling 12's rest added. A failed synthetic drag does
	// not drop, and nothing reports that it did not, so the act comes back
	// unverified, like a press, and a later positive read is what establishes
	// it landed. See `Resolver.Drag`.
	Drag *DragStep `json:"drag,omitempty"`

	// Hold presses a modifier key DOWN and leaves it down; Release lets it go.
	// Two arms rather than one timed act, added by 2d-ii's push-to-talk.
	//
	// **A timed hold could not be asserted during.** What a held ⌥ shows —
	// the words being heard, "Hearing nothing from <device>" — exists only
	// while the key is down and is gone the moment it comes up, so a single
	// act that pressed, waited and released would leave nothing to read.
	// Split, every step between the two runs while the key is held: an
	// `expect` waits on what the hold draws, a `press` of Escape lands
	// mid-hold. How long the key is held is how long those steps take, and
	// each waits on a predicate rather than on a clock.
	//
	// **Posted as a real `flagsChanged` through the HID event tap**, the
	// path a keyboard's own ⌥ takes, so the app's event monitor sees it as
	// it would a hand's — after the fixture is brought forward, because a
	// key event goes to the frontmost application's key window. See
	// `Resolver.Modifier`. Unverified, like a press: the window says nothing
	// about a modifier, so a later positive read is what establishes it.
	//
	// **Paired at parse, so a check cannot leave a key down.** A key posted
	// down through the HID tap is down for the whole session until something
	// posts it up — the operator's next click would arrive ⌥-clicked. A
	// check whose holds are not each released later in the same file is
	// refused by `ParseChecks`, and because a check's steps all run even
	// after one fails, the release always runs once the hold did.
	Hold    string `json:"hold,omitempty"`
	Release string `json:"release,omitempty"`

	// Resize sets the window's size, so a check can assert a narrow layout
	// (spec 2026-10-15-e2e-walk-gaps-layout-focus §3.3). Verified by reading
	// the size back: a window with a minimum size clamps without an error.
	Resize *ResizeStep `json:"resize,omitempty"`
}

// ResizeStep is the window size a do.resize asks for, in points.
type ResizeStep struct {
	Width  int `json:"width"`
	Height int `json:"height"`
}

// ModifierKeys are the keys a `hold` or `release` may name, with the virtual
// key code and the event flag each posts. A modifier, unlike a key Orca
// presses, is posted by this repo's resolver, so the set is this repo's to
// know — a misspelling is refused here, at parse, rather than by a live run.
var ModifierKeys = []string{"option", "shift", "control", "command"}

func validModifier(key string) error {
	if !slices.Contains(ModifierKeys, key) {
		return fmt.Errorf("%q is not a modifier a hold can press — expected one of %s",
			key, strings.Join(ModifierKeys, ", "))
	}
	return nil
}

// DragStep is a control to pick up and a control to drop it on, both by
// identifier. The drop lands at the target's centre.
type DragStep struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// Describe names the drag for a log a person reads.
func (d *DragStep) Describe() string { return "drag " + d.From + " onto " + d.To }

func validateDrag(drag *DragStep) error {
	if drag.From == "" || drag.To == "" {
		return fmt.Errorf(
			"a drag names both the control it picks up (from) and the one it drops on (to); "+
				"this one names from %q and to %q", drag.From, drag.To)
	}
	if err := validIdentifier(drag.From); err != nil {
		return err
	}
	return validIdentifier(drag.To)
}

// Describe names one act, for a log a person reads.
//
// **The text a `type` carried is included**, because the act this exists to
// describe is a send whose composer turned out to be empty, and a line saying
// only "type" would leave the reader to guess what was in it.
func (d *Do) Describe() string {
	switch {
	case d.Click != "":
		return "click " + d.Click
	case d.Focus != "":
		return "focus " + d.Focus
	case d.Drag != nil:
		return d.Drag.Describe()
	case d.Type != nil:
		return fmt.Sprintf("type %q into %s", d.Type.Text, d.Type.Into)
	case d.Keys != "":
		return fmt.Sprintf("keys %q", d.Keys)
	case d.Press != "":
		return "press " + d.Press
	case d.Hotkey != "":
		return "hotkey " + d.Hotkey
	case d.Hold != "":
		return "hold " + d.Hold
	case d.Release != "":
		return "release " + d.Release
	case d.Resize != nil:
		return fmt.Sprintf("resize the window to %d×%d", d.Resize.Width, d.Resize.Height)
	default:
		return "an act driving none of the ten arms"
	}
}

// TypeInto is a field and what to put in it.
type TypeInto struct {
	Into string `json:"into"`
	Text string `json:"text"`
}

// Dispatch drives the agent channel: one action over the live MCP socket,
// exactly as a real agent would send it.
type Dispatch struct {
	Action string                 `json:"action"`
	Params map[string]interface{} `json:"params,omitempty"`
	// Refuses makes the step pass only when the action is REFUSED, with a refusal carrying
	// this text — and fail when it runs. A refusal is the outcome some checks exist to see
	// (Decision 27's one-author rule, a second send in flight), and without this a refused
	// dispatch could only ever fail its step. A field on dispatch, not a fifth step kind.
	Refuses string `json:"refuses,omitempty"`
}

// Expect asserts, against one of three sources.
//
// The division of labour was settled by the probe. The accessibility tree
// answers *is it present, is it labelled, is it selected*; `read_pane` answers
// *what does it contain*; the process table answers *what did this leave
// running*. A data-surface row is ONE tree element and its cells are
// deliberately hidden (`DataSurface.swift`,
// `.accessibilityElement(children: .ignore)`), so a check asserting on a
// particular cell must come through `pane` and cannot go through `tree`.
type Expect struct {
	// Tree is "contains" or "absent", asserted against Text.
	Tree string `json:"tree,omitempty"`
	Text string `json:"text,omitempty"`
	// Pane names a pane to read and Field a path into its snapshot — a key,
	// or a dotted path with list indexes: `blocks[-1].exitCode`. PanePath
	// carries the grammar and the reasoning for it.
	//
	// **Exactly one of Equals and Contains.** Both is ambiguous; neither
	// passes on the mere existence of the field, which is the vacuous
	// assertion this harness exists to refuse. Both are pointers so that
	// asserting the empty string is expressible and distinguishable from
	// omitting it.
	Pane  string `json:"pane,omitempty"`
	Field string `json:"field,omitempty"`
	// Equals is the exact value the path must hold.
	Equals *string `json:"equals,omitempty"`
	// Contains is text the path's value must carry. **It exists because the
	// interesting values are lists**: `grid` is twenty rows of padded text
	// and a block's `output` is one string per line, so nothing a check cares
	// about there is ever equal to a literal an author could write down.
	Contains *string `json:"contains,omitempty"`
	// Present asserts only that the path resolves, or that it does not.
	// **For a live measurement whose value is not the claim**: 2c-iii's
	// check 2 is "a block carrying its exit code and duration", and the
	// duration is six milliseconds today and nine tomorrow. It is not a
	// vacuous assertion — against a pane with no blocks, `blocks[-1].durationMs`
	// does not resolve and it fails.
	Present *bool `json:"present,omitempty"`
	// Process asserts against the process table.
	Process *Process `json:"process,omitempty"`
	// Journal asserts against what the app recorded about its own actions —
	// the fourth source, and the only one that can see a defect the window
	// hides by construction. JournalReader carries the reasoning.
	Journal *JournalExpectation `json:"journal,omitempty"`

	// Focus names the control that must hold keyboard focus, or contain the
	// element that does — SwiftUI puts the identifier on a wrapper and the
	// focus on the field inside it. Read from the app, not the system, so
	// another app taking the foreground does not fail it (#418).
	Focus string `json:"focus,omitempty"`

	// Frame names a control whose rectangle is held to the predicates below:
	// Inside (FrameWindow or another identifier), Clear (an identifier it
	// must not overlap) and size bounds in points. A frame that does not
	// resolve fails; a predicate over a missing element is never true.
	Frame     string   `json:"frame,omitempty"`
	Inside    string   `json:"inside,omitempty"`
	Clear     string   `json:"clear,omitempty"`
	MinWidth  *float64 `json:"minWidth,omitempty"`
	MinHeight *float64 `json:"minHeight,omitempty"`
	MaxWidth  *float64 `json:"maxWidth,omitempty"`
	MaxHeight *float64 `json:"maxHeight,omitempty"`

	// Label names a control whose accessibility label must hold Equals or
	// Contains. Orca's tree text prints a button's title or value, never its
	// label, so a row that names itself with `accessibilityLabel` — a palette
	// row, a Landing row, a rail tick — is read here or not at all.
	Label string `json:"label,omitempty"`
}

// FrameWindow is the Inside value that means the window itself.
const FrameWindow = "window"

// JournalExpectation asserts that the app recorded something.
type JournalExpectation struct {
	Contains string `json:"contains,omitempty"`
}

// Process asserts what is, or is no longer, in the process table. `PS`
// carries the rule a pattern here has to satisfy.
//
// **Two predicates, and the second is what makes the first mean anything.**
// 2c-iii's check 6 is "`tail -f` something, close the pane, then `ps` — no
// orphan"; written with `none-matching` alone it passes just as cleanly when
// the `tail` never started, which is the silent success this harness exists to
// refuse. So a check asserts the process IS there before it asserts it is not.
type Process struct {
	NoneMatching string `json:"none-matching,omitempty"`
	AnyMatching  string `json:"any-matching,omitempty"`
}

// Pattern is whichever of the two this step names.
func (p *Process) Pattern() string {
	if p.AnyMatching != "" {
		return p.AnyMatching
	}
	return p.NoneMatching
}

// Parity performs one action twice — once by clicking, once by dispatching —
// and asserts the state landed identically.
//
// **This is the centre of the vocabulary.** Invariant 2: *"UI controls and
// the agent dispatch the same actions. Two code paths to the same state is
// forbidden."* It is the one thing no fake-injecting unit test can ever see,
// and it is why the harness drives two channels instead of one.
type Parity struct {
	Action string                 `json:"action"`
	Params map[string]interface{} `json:"params,omitempty"`
	// Click and Drag are the UI half, and a parity carries exactly one. Drag
	// exists for an action the operator performs by dropping one thing on
	// another — `api_bind`, a row dropped on a pane — which no press reaches.
	Click  string    `json:"click,omitempty"`
	Drag   *DragStep `json:"drag,omitempty"`
	Assert string    `json:"assert"`
}

// UIHalf names the UI half of a parity, for a failure a person reads.
func (p *Parity) UIHalf() string {
	if p.Drag != nil {
		return "dragging " + p.Drag.From + " onto " + p.Drag.To
	}
	return "clicking " + p.Click
}

// The state reads a parity step may compare through.
//
// Named rather than spelled as literals at each use, because a literal in the
// runner and a literal in the validation list are two answers to one question
// and only one of them gets updated.
const (
	ParityReadPane   = "read_pane"
	ParityReadLayout = "read_layout"
	ParityTree       = "tree"
)

// ParityAsserts is what `assert` may name.
var ParityAsserts = []string{ParityReadPane, ParityReadLayout, ParityTree}

// The tree predicates `expect` understands.
const (
	TreeContains = "contains"
	TreeAbsent   = "absent"
)

// TreeAssertions is what `tree` may name.
var TreeAssertions = []string{TreeContains, TreeAbsent}

// IsAssertion reports whether this step proves something.
//
// **Acts are not assertions, and the difference is load-bearing.** Result.Err
// refuses a run whose checks asserted nothing; if an act counted, a check made
// only of `do` and `dispatch` would satisfy that guard while proving nothing
// at all. A parity step counts, because comparing the two channels IS its
// assertion. So does a dispatch that `refuses`: it passes only when the action
// is refused in those words, which an unrefused action cannot satisfy.
func (s Step) IsAssertion() bool {
	return s.Expect != nil || s.Parity != nil || (s.Dispatch != nil && s.Dispatch.Refuses != "")
}

// Confirms reports whether this assertion, having passed, is evidence that a
// preceding unverified act actually landed.
//
// **Only a POSITIVE read counts.** An act Orca could not assert is cleared by
// seeing the state the act was supposed to produce; an assertion that passes
// when nothing happened can never certify that something did. So:
//
//   - `tree: contains`, `pane` with `equals` or `contains`, `journal` and
//     `process: any-matching` all say a thing IS there. They confirm.
//   - `frame` does too: it fails unless the identifier resolves to exactly
//     one element, so it passing says the control is drawn. An identifier
//     never reaches the tree's text (axresolve's header), so for a control
//     with no text of its own — a rail tick — it is the only positive read.
//   - `label` with `equals` or `contains` says the control is drawn AND
//     names what it should.
//   - `tree: absent` passes when the text is not there, which is also what it
//     does when the act never happened, when the window never drew, and when
//     the identifier was a typo. It is the assertion most likely to pass
//     vacuously, so it is the last thing that should certify an act.
//   - `pane` with `present: false` is the same negative shape, and used to
//     confirm because this switch asked only whether a pane was named. Found
//     in review; latent, because no check uses it yet, but it is this file's
//     own thesis.
//   - `process: none-matching` looks at the process table, which is not the
//     window at all, and finding nothing says nothing about whether a click
//     landed.
func (e *Expect) Confirms() bool {
	switch {
	case e.Tree == TreeContains:
		return true
	case e.Pane != "":
		// A pane read confirms unless it is the negative predicate.
		return e.Present == nil || *e.Present
	case e.Journal != nil:
		return true
	case e.Process != nil && e.Process.AnyMatching != "":
		return true
	case e.Frame != "":
		return true
	case e.Label != "":
		return true
	default:
		return false
	}
}

// ParseChecks reads one check file.
//
// Blank lines are skipped and produce no step, so step N is the Nth non-empty
// line — the contract `--dispatch` gives its own scripts. Lines are split on
// any Unicode newline rather than on "\n" alone, because a CRLF-saved file
// would otherwise arrive as one enormous line and produce a single parse error
// for the whole thing; `runDispatchFile`'s doc comment records that trap.
//
// **A file with no steps is an error.** A check that asserts nothing and
// passes is the failure this harness exists to prevent, and an empty file is
// the cheapest way to write one.
func ParseChecks(name string, data []byte) (Check, error) {
	check := Check{Name: name}
	for index, line := range splitLines(string(data)) {
		number := index + 1
		text := strings.TrimSpace(line)
		if text == "" {
			continue
		}
		var step Step
		if err := json.Unmarshal([]byte(text), &step); err != nil {
			return Check{}, fmt.Errorf("check %q line %d: %w", name, number, err)
		}
		if err := validate(step); err != nil {
			return Check{}, fmt.Errorf("check %q line %d: %w", name, number, err)
		}
		check.Steps = append(check.Steps, step)
	}
	if len(check.Steps) == 0 {
		return Check{}, fmt.Errorf("check %q has no steps, so it would assert nothing and pass", name)
	}
	if err := validateHolds(check); err != nil {
		return Check{}, fmt.Errorf("check %q: %w", name, err)
	}
	return check, nil
}

// validateHolds refuses a check that could leave a modifier down, or that
// releases one it never held.
//
// **A whole-file rule, so it is the one validation that is not per line.** A
// hold with no release later in the same file would leave the key down
// through the HID tap after the check ended — on the operator's machine, for
// whatever they touch next. A release with no hold before it posts a key-up
// for a key nobody pressed, which changes nothing and reads as though it did.
func validateHolds(check Check) error {
	held := map[string]int{}
	for index, step := range check.Steps {
		if step.Do == nil {
			continue
		}
		number := index + 1
		switch {
		case step.Do.Hold != "":
			if _, already := held[step.Do.Hold]; already {
				return fmt.Errorf("step %d holds %s, which step %d already holds",
					number, step.Do.Hold, held[step.Do.Hold])
			}
			held[step.Do.Hold] = number
		case step.Do.Release != "":
			if _, down := held[step.Do.Release]; !down {
				return fmt.Errorf("step %d releases %s, which no earlier step holds",
					number, step.Do.Release)
			}
			delete(held, step.Do.Release)
		}
	}
	if len(held) > 0 {
		keys := slices.Sorted(maps.Keys(held))
		return fmt.Errorf("step %d holds %s and no later step releases it — the key would "+
			"stay down after the check, for whatever the operator touches next",
			held[keys[0]], keys[0])
	}
	return nil
}

// validate holds one step to the format.
//
// **Every rule here is one a live run would otherwise discover against a real
// window**, minutes in and with a fixture instance on the operator's screen.
// A malformed identifier is a typo; finding it at parse time names the typo
// instead of reporting that a control could not be resolved.
func validate(step Step) error {
	kinds := countTrue(step.Do != nil, step.Dispatch != nil, step.Expect != nil, step.Parity != nil)
	switch {
	case kinds == 0:
		return fmt.Errorf("no known step kind — expected one of do, dispatch, expect, parity")
	case kinds > 1:
		return fmt.Errorf("carries %d step kinds, and a line must carry exactly one step kind", kinds)
	}
	switch {
	case step.Do != nil:
		return validateDo(step.Do)
	case step.Dispatch != nil:
		return validateDispatch(step.Dispatch)
	case step.Expect != nil:
		return validateExpect(step.Expect)
	default:
		return validateParity(step.Parity)
	}
}

// countTrue counts how many of a step's arms are filled. Three validators
// asked the same question three different ways before it existed.
func countTrue(flags ...bool) int {
	count := 0
	for _, flag := range flags {
		if flag {
			count++
		}
	}
	return count
}

func validateDo(do *Do) error {
	arms := countTrue(do.Click != "", do.Type != nil, do.Keys != "", do.Press != "", do.Hotkey != "",
		do.Focus != "", do.Drag != nil, do.Hold != "", do.Release != "", do.Resize != nil)
	// **An empty arm is refused here rather than sent.** `{"do":{"keys":""}}`
	// reaches the window, changes nothing, and reads in a check file as
	// though something was sent — so it is counted as no arm at all and
	// caught by the zero case below, which names the whole set.
	switch {
	case arms == 0:
		return fmt.Errorf(
			"a do drives exactly one of click, focus, drag, type, keys, press, hotkey, hold, " +
				"release or resize, and this one drives none")
	case arms > 1:
		return fmt.Errorf(
			"a do carries %d of click, focus, drag, type, keys, press, hotkey, hold, release "+
				"and resize, and it must carry exactly one", arms)
	}
	switch {
	case do.Click != "":
		return validIdentifier(do.Click)
	case do.Focus != "":
		return validIdentifier(do.Focus)
	case do.Drag != nil:
		return validateDrag(do.Drag)
	case do.Hold != "":
		return validModifier(do.Hold)
	case do.Release != "":
		return validModifier(do.Release)
	case do.Resize != nil:
		if do.Resize.Width <= 0 || do.Resize.Height <= 0 {
			return fmt.Errorf("a do.resize needs a positive width and height, and %d×%d is not",
				do.Resize.Width, do.Resize.Height)
		}
		return nil
	case do.Type != nil:
		if do.Type.Into == "" {
			return fmt.Errorf("a do.type names no field to type into")
		}
		return validIdentifier(do.Type.Into)
	default:
		// A keystroke arm is aimed at keyboard focus rather than at a named
		// control, so there is no identifier to validate. Whether the right
		// thing had focus is a question only the window can answer, and the
		// check answers it by asserting what it typed arrived.
		//
		// **A key NAME is not validated here either, deliberately.** The set
		// Orca accepts is Orca's, and a copy of it in this file would be a
		// second answer that goes stale the first time Orca adds a key. A
		// misspelled key is refused by Orca, arrives as `the act was refused`,
		// and fails the check loudly — which is the outcome a local list would
		// have bought, one release later and wrong.
		return nil
	}
}

func validateDispatch(dispatch *Dispatch) error {
	if dispatch.Action == "" {
		return fmt.Errorf("a dispatch names no action")
	}
	return nil
}

func validateExpect(expect *Expect) error {
	arms := countTrue(expect.Tree != "", expect.Pane != "", expect.Process != nil,
		expect.Journal != nil, expect.Focus != "", expect.Frame != "", expect.Label != "")
	switch {
	case arms == 0:
		return fmt.Errorf("an expect asserts against a tree, a pane, a process, the journal, " +
			"focus, a frame or a label, and this one names none")
	case arms > 1:
		return fmt.Errorf("an expect asserts against exactly one of tree, pane, process, " +
			"journal, focus, frame or label")
	}
	switch {
	case expect.Tree != "":
		if !slices.Contains(TreeAssertions, expect.Tree) {
			return fmt.Errorf("unknown tree assertion %q — expected one of %s",
				expect.Tree, strings.Join(TreeAssertions, ", "))
		}
		if expect.Text == "" {
			return fmt.Errorf("an expect.tree with no text asserts nothing")
		}
	case expect.Pane != "":
		if expect.Field == "" {
			return fmt.Errorf("an expect.pane names no field")
		}
		// The path's GRAMMAR, which is knowable without a window. It does
		// not catch a misspelled key — `blcoks[-1].exitCode` parses fine —
		// and the rule that does is in assertPane: `present: false` requires
		// the path's container to resolve.
		if err := ValidPanePath(expect.Field); err != nil {
			return fmt.Errorf("an expect.pane names field %q: %w", expect.Field, err)
		}
		predicates := countTrue(expect.Equals != nil, expect.Contains != nil, expect.Present != nil)
		switch {
		case predicates == 0:
			return fmt.Errorf(
				"an expect.pane names field %q but no predicate — equals, contains or "+
					"present — so it would assert nothing at all", expect.Field)
		case predicates > 1:
			return fmt.Errorf(
				"an expect.pane names %d of equals, contains and present for field %q, and it "+
					"must name exactly one", predicates, expect.Field)
		}
	case expect.Process != nil:
		switch {
		case expect.Process.NoneMatching == "" && expect.Process.AnyMatching == "":
			return fmt.Errorf("an expect.process names no pattern")
		case expect.Process.NoneMatching != "" && expect.Process.AnyMatching != "":
			return fmt.Errorf(
				"an expect.process names exactly one of none-matching and any-matching")
		}
	case expect.Journal != nil:
		if expect.Journal.Contains == "" {
			return fmt.Errorf("an expect.journal names no text, so it asserts nothing")
		}
	case expect.Focus != "":
		return validIdentifier(expect.Focus)
	case expect.Frame != "":
		return validateFrame(expect)
	case expect.Label != "":
		if err := validIdentifier(expect.Label); err != nil {
			return err
		}
		if countTrue(expect.Equals != nil, expect.Contains != nil) != 1 || expect.Present != nil {
			return fmt.Errorf("an expect.label on %s names exactly one of equals and contains", expect.Label)
		}
	}
	return nil
}

// validateFrame refuses a frame step that could not fail.
func validateFrame(expect *Expect) error {
	if err := validIdentifier(expect.Frame); err != nil {
		return err
	}
	bounds := []struct {
		name  string
		value *float64
	}{{"minWidth", expect.MinWidth}, {"minHeight", expect.MinHeight},
		{"maxWidth", expect.MaxWidth}, {"maxHeight", expect.MaxHeight}}
	predicates := countTrue(expect.Inside != "", expect.Clear != "")
	for _, bound := range bounds {
		if bound.value == nil {
			continue
		}
		predicates++
		if *bound.value <= 0 {
			return fmt.Errorf("an expect.frame's %s must be positive, and %v is not", bound.name, *bound.value)
		}
	}
	if predicates == 0 {
		return fmt.Errorf("an expect.frame on %s names no predicate — inside, clear or a size "+
			"bound — so it would assert nothing", expect.Frame)
	}
	if expect.Inside == expect.Frame || expect.Clear == expect.Frame {
		return fmt.Errorf("an expect.frame compares %s with itself", expect.Frame)
	}
	if expect.Inside != "" && expect.Inside != FrameWindow {
		if err := validIdentifier(expect.Inside); err != nil {
			return err
		}
	}
	if expect.Clear != "" {
		if err := validIdentifier(expect.Clear); err != nil {
			return err
		}
	}
	for _, pair := range [][2]*float64{{expect.MinWidth, expect.MaxWidth}, {expect.MinHeight, expect.MaxHeight}} {
		if pair[0] != nil && pair[1] != nil && *pair[0] > *pair[1] {
			return fmt.Errorf("an expect.frame's minimum %v exceeds its maximum %v", *pair[0], *pair[1])
		}
	}
	return nil
}

func validateParity(parity *Parity) error {
	if parity.Action == "" {
		return fmt.Errorf("a parity step names no action")
	}
	switch countTrue(parity.Click != "", parity.Drag != nil) {
	case 0:
		return fmt.Errorf("a parity step names no click or drag, so it can only drive one " +
			"channel and would assert Invariant 2 holds without ever testing the UI path")
	case 2:
		return fmt.Errorf("a parity step names both a click and a drag, and its UI half must " +
			"be exactly one of them — the runner would drive one and drop the other")
	}
	if parity.Drag != nil {
		if err := validateDrag(parity.Drag); err != nil {
			return err
		}
	} else if err := validIdentifier(parity.Click); err != nil {
		return err
	}
	if !slices.Contains(ParityAsserts, parity.Assert) {
		return fmt.Errorf("unknown parity assertion %q — expected one of %s",
			parity.Assert, strings.Join(ParityAsserts, ", "))
	}
	// **read_pane must be told which pane, at parse time.** The design's own
	// example line omits it, so this is not a hypothetical typo: without the
	// check it parses cleanly and dies against a live window, minutes into a
	// run, with a fixture instance on the operator's screen.
	if parity.Assert == ParityReadPane {
		if ParityPaneID(parity.Params) == "" {
			return fmt.Errorf(
				"a parity step asserting through read_pane must name the pane to compare, as "+
					"params.id or params.pane; %q names neither", parity.Action)
		}
	}
	return nil
}

// ParityPaneID is the pane a read_pane parity compares, out of the
// action's own params.
//
// **Two spellings, because the registry has two.** `pane_focus` and the
// layout actions name a pane `id`; `db_run_query` and every `api_*`
// action name it `pane`. This read used to accept only `id`, which made a
// parity step impossible for half the registry — and the half it excluded
// is the half that writes into panes, which is exactly what Invariant 2's
// parity exists to compare.
//
// It reads the ACTION's params rather than taking a separate field, so a
// parity step cannot name one pane to the action and another to the
// comparison.
func ParityPaneID(params map[string]interface{}) string {
	if id, named := params["id"].(string); named && id != "" {
		return id
	}
	if pane, named := params["pane"].(string); named && pane != "" {
		return pane
	}
	return ""
}

// validIdentifier refuses an identifier no resolver could ever resolve.
func validIdentifier(identifier string) error {
	if !isSurface(firstSegment(identifier)) {
		return fmt.Errorf(
			"%q is not in a registered surface (%s), so no control can carry it",
			identifier, strings.Join(Surfaces, ", "))
	}
	return nil
}

// splitLines splits on any Unicode newline and KEEPS empty lines, so a
// reported line number is the line in the file. A splitter that dropped
// blanks would send an operator to the wrong line of a file they are already
// debugging. A CRLF pair counts once, not twice.
func splitLines(text string) []string {
	var lines []string
	var current strings.Builder
	runes := []rune(text)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if !isNewline(r) {
			current.WriteRune(r)
			continue
		}
		if r == '\r' && i+1 < len(runes) && runes[i+1] == '\n' {
			i++
		}
		lines = append(lines, current.String())
		current.Reset()
	}
	if current.Len() > 0 {
		lines = append(lines, current.String())
	}
	return lines
}

// isNewline covers the same set Swift's Character.isNewline does, which is
// the set `--dispatch` splits its scripts on.
func isNewline(r rune) bool {
	switch r {
	case '\n', '\r', '\u0085', '\u2028', '\u2029':
		return true
	}
	return false
}

// LoadChecks reads the named check files, in the order they are named.
//
// **A run that names no files is refused**: a run that loads nothing executes
// nothing and exits 0, which is the silence this harness exists to refuse. A
// path that is not there is refused for the same reason one level down — a
// glob that matched nothing expands to itself, so a typo in a Makefile would
// otherwise become a clean pass.
//
// A check is named after its file's base name, which is what `--quarantine`
// and the failability record both address it by.
func LoadChecks(paths []string) ([]Check, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("no check files named, so nothing would be proved")
	}
	var checks []Check
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		check, err := ParseChecks(filepath.Base(path), data)
		if err != nil {
			return nil, err
		}
		checks = append(checks, check)
	}
	return checks, nil
}
