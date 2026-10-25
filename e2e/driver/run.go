package driver

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"
)

// Channel is the agent side: one action over the live MCP socket, exactly as
// a real agent would send it. `*MCP` satisfies it, and a test drives a
// stand-in without a window.
type Channel interface {
	Call(action string, arguments map[string]interface{}) (ToolResult, error)
}

// ProcessTable answers what is still running. `PS` is the live one, and its
// doc comment carries the pattern-specificity rule this depends on.
type ProcessTable interface {
	Matching(pattern string) ([]string, error)
}

// DefaultSettle is how long an assertion waits for the window to reach the
// state it asserts.
//
// **A predicate with a deadline, never a fixed sleep.** A sleep long enough
// to be reliable is a sleep paid on every green run, and one short enough to
// be cheap is a flake. Re-reading until the predicate holds costs nothing
// when the state is already there, which is the usual case.
const DefaultSettle = 3 * time.Second

// AgentSettle is what a launch carrying the scripted agent waits instead.
//
// **An agent turn is not a state change, it is a subprocess.** Everything
// `DefaultSettle` was measured against happens inside the window — a pane
// opens, a block lands, focus moves — and three seconds is generous for all
// of it. A turn spawns a child, hands it a generated `--mcp-config`, waits
// for it to connect back over the window's own socket, answers a `read_pane`
// on it and streams a reply back.
//
// **Measured 2026-09-24, and the healthy case needs no deadline at all**:
// `both-surfaces.jsonl` passes at `--settle -1s`, so the reply is already in
// the tree by the next read. Twice it was not. Once the reply was absent
// three seconds after Send while every step after it passed, and once — in
// the launch that followed a `swift build` — the child had not been spawned
// at all by the time teardown killed the window. Both were load, and load is
// what a gate runs under.
//
// **It is free on a green run**, for the reason in `DefaultSettle`: this is a
// predicate with a deadline and not a sleep, so a state already reached costs
// one read. Six runs at this deadline took the same 12–14 seconds the three
// before it took.
//
// **It is the whole launch's deadline, not just the agent-waiting
// assertions'**, and there is no honest way to narrow it: `two-enter` waits on
// the agent through `expect.tree` AND through `expect.pane`, so nothing in a
// step's syntax says which ones are waiting on a subprocess. The cost is real
// and bounded — a genuinely failing assertion in an agent launch is reported
// twenty seconds later than it would have been.
//
// **It is not a check retried into green, and it cannot become one.** `e2e.md`
// forbids re-running a check until it passes, which destroys it as evidence;
// nothing here re-runs, one predicate is read until it holds, and a reply that
// never arrives is still red. The case it must never cover is a turn that
// never started — waiting longer for that would be exactly the hiding the rule
// is about — so `Session.agentNeverRan` makes that a FATAL fault of the run,
// which no deadline can turn green.
const AgentSettle = 20 * time.Second

// settleInterval is how often a predicate is re-read while it does not hold.
const settleInterval = 100 * time.Millisecond

// Runner executes checks against one instance, across the three channels.
//
// **A fresh read is taken for every attempt.** It is not an optimisation to
// reuse one: Orca refuses an index-based action that is not preceded by a
// snapshot for that app and window, and a read taken before an act says
// nothing about the state after it.
type Runner struct {
	Orca     Orca
	Resolver Resolver
	Channel  Channel
	PID      int

	// FixtureRoot is this run's fixture directory, which `FixtureRootToken`
	// expands to in a dispatch's params. Empty in the unit tests, where no
	// fixture exists and no expansion should happen.
	FixtureRoot string
	// ChatStub is this launch's chat stub origin (StartChatStub), which
	// `ChatStubToken` expands to. Empty without a seed.
	ChatStub string
	// PageStub is this launch's page stub origin (StartPageStub), which
	// `PageStubToken` expands to, in params and in typed text. Empty without a seed.
	PageStub string

	Processes ProcessTable
	// Journal answers what the app recorded about its own actions. Nil means
	// a journal assertion is an infrastructure failure rather than a pass.
	Journal  JournalReader
	Evidence *Evidence

	// Settle bounds how long an assertion waits for its predicate. Zero means
	// one attempt and no waiting, which is what the unit tests want; the
	// command passes DefaultSettle.
	Settle time.Duration

	// Quarantined names checks known to be intermittent. Their failures are
	// reported and do not make the run red. **Nothing is ever retried.** A
	// check retried into green is a check that has stopped being evidence.
	Quarantined []string

	// acts is what this check did and what the window server believed while
	// it did it, one line per act. Written into the evidence on a failure.
	// See Runner.logAct.
	acts []string
	// atLastAct is what the resolver reported about the window server at the
	// most recent act, and atLastActErr why there is no reading when there is
	// none. **Both, because "not asked" and "asked and could not be read" are
	// different facts** — the first is an act delivered by a channel that
	// reports nothing, and the second is a diagnostic that broke.
	atLastAct    *Frontmost
	atLastActErr error
	// beforeLastAct is the same reading taken BEFORE the act, with its own
	// error, and broughtForward whether this run had to activate the window to
	// make it true. The reading afterwards says what an act left behind; only
	// the one before it says what the act was delivered into.
	//
	// **An error each, because they are two reads.** Sharing one field made
	// the before half of a line say "not asked" while the after half carried
	// a reason, which is the exact confusion this pair of fields exists to
	// prevent — caught by `TestAReadingThatCouldNotBeTakenSaysWhy`.
	// interference is this check's acts across which another process took
	// the foreground (#292); see `recordInterference`.
	interference []string
	// Input starts watching the keyboard and pointer events delivered during
	// an act, and its stop reports them (`Resolver.WatchInput`); nil watches
	// nothing (#339).
	Input            func() (stop func() ([]InputEvent, error), err error)
	beforeLastAct    *Frontmost
	beforeLastActErr error
	broughtForward   bool
}

// CheckOutcome is what one check did, on its own.
//
// **The totals cannot answer a per-check question.** `make e2e-new` asks
// whether EACH new check went red against the merge-base build, and a run
// that reports `3 of 7 assertions failed` cannot say whether the three were
// spread across every check or all came from one.
type CheckOutcome struct {
	Name       string
	Assertions int
	Failures   []string
	// Evidence is what this check's evidence directory holds, and
	// EvidenceGaps what could not be gathered. **Names, not paths**: the
	// directory is gitignored, so a document downstream can only say what
	// exists and where to look for it.
	Evidence     []string
	EvidenceGaps []string
}

// Red reports whether this check failed.
func (o CheckOutcome) Red() bool { return len(o.Failures) > 0 }

// Result is what a run amounts to.
type Result struct {
	ChecksRun  int
	Assertions int
	Failures   []string
	// Checks carries what each check did, in the order they ran. A
	// quarantined check is deliberately absent — it did not count towards the
	// run — which is itself a fact a red-required pass has to notice, and
	// Verdict.Add turns into a `missing` row rather than a silent omission.
	Checks []CheckOutcome
	// Quarantined carries what the quarantined checks did, so an intermittent
	// check is reported rather than hidden.
	Quarantined []string
	// Fatal is a fault in the run itself rather than in what it observed — a
	// stale quarantine entry, for instance. It is red regardless of the checks.
	Fatal []string
	// Tools is the action denominator this launch observed, before the first
	// check ran. **Carried out of the run rather than re-asked for**: the
	// actions a build exposes are only knowable from a live window, and every
	// launch already asks `tools/list` to prove the socket is Wakil's. The
	// coverage gate reads what this leaves behind (see Denominator) instead of
	// paying for a launch of its own.
	Tools []Tool
	// Evidence is the directory a failing check left its screenshot, tree and
	// pane snapshot in. **Carried out of the run rather than reconstructed**:
	// the name is a timestamp taken inside the session, so a caller that
	// rebuilt it would be naming a directory that is nearly, but not, the one
	// that was written.
	Evidence string
}

// Err reports whether the run may be called a pass.
//
// **Silence is not success.** `go test` reports a skipped test as ok, which is
// why `make test-live` had to grow an explicit skip check — without it, a live
// target with no engines running "passed" and certified nothing at all. A GUI
// runner has the same failure in a worse form: a check that resolved a stale
// index, found nothing and asserted nothing also exits 0. So a run that
// executed no check, or executed checks that asserted nothing, is red.
//
// **The zero-assertions arm is now live.** #247 had only assertion-shaped
// steps, so it could not fire; `do` and `dispatch` are acts, and a check made
// only of those reaches here with nothing proved.
func (r Result) Err() error {
	if len(r.Fatal) > 0 {
		return fmt.Errorf("the run itself is unsound:\n  %s", joinLines(r.Fatal))
	}
	// **A launch of quarantined checks alone is reported, not silent.** `make
	// e2e-run` launches one file at a time, so a quarantined file is a launch
	// with nothing counted; its outcome is printed as QUARANTINED, which is the
	// whole of what quarantine promises. It proves nothing, and is not red.
	if r.ChecksRun == 0 && len(r.Quarantined) > 0 {
		return nil
	}
	if r.ChecksRun == 0 {
		return fmt.Errorf("no check ran, so nothing was proved")
	}
	if r.Assertions == 0 {
		return fmt.Errorf("%d check(s) ran but asserted nothing, so nothing was proved", r.ChecksRun)
	}
	if len(r.Failures) > 0 {
		// **Failures are counted against steps, not assertions.** A refused
		// act is a failure and is not an assertion, so the old wording could
		// read "12 of 8 assertion(s) failed" — which is the kind of number
		// that makes a reader distrust the whole report.
		return fmt.Errorf("%d failure(s), across %d assertion(s):\n  %s",
			len(r.Failures), r.Assertions, joinLines(r.Failures))
	}
	return nil
}

// For narrows a launch's result to one check, keeping the facts that belong to
// the launch rather than to the check.
//
// **A per-file record must carry that file's own verdict.** `make e2e` runs
// one file per launch, but the program takes a list, and a record claiming a
// launch's total assertion count for each of its files is a number nobody can
// check against anything.
//
// **A check the launch never reported does not narrow to a pass.** It narrows
// to a result that ran nothing, which Err already refuses — the absent row
// Verdict.Add refuses to leave out, in the other record.
func (r Result) For(name string) Result {
	narrowed := Result{
		Quarantined: r.Quarantined,
		Fatal:       r.Fatal,
		Tools:       r.Tools,
		Evidence:    r.Evidence,
	}
	for _, outcome := range r.Checks {
		if outcome.Name != name {
			continue
		}
		narrowed.ChecksRun++
		narrowed.Assertions += outcome.Assertions
		narrowed.Failures = append(narrowed.Failures, outcome.Failures...)
		narrowed.Checks = append(narrowed.Checks, outcome)
	}
	return narrowed
}

// Run executes every check and reports what was proved.
// tokens are the values a check's dispatch and parity params may name.
func (r *Runner) tokens() map[string]string {
	return map[string]string{
		FixtureRootToken: r.FixtureRoot, ChatStubToken: r.ChatStub, PageStubToken: r.PageStub,
	}
}

func (r *Runner) Run(checks []Check) Result {
	result := Result{}
	for _, name := range r.Quarantined {
		if !slices.ContainsFunc(checks, func(check Check) bool { return check.Name == name }) {
			result.Fatal = append(result.Fatal, fmt.Sprintf(
				"quarantine names %q, which is not among the checks being run — a stale "+
					"quarantine entry hides a check nobody runs any more", name))
		}
	}
	for _, check := range checks {
		failures := r.runCheck(check)
		result.Fatal = append(result.Fatal, interferenceFatal(check.Name, r.interference, failures)...)
		if slices.Contains(r.Quarantined, check.Name) {
			result.Quarantined = append(result.Quarantined, quarantineNote(check.Name, failures))
			continue
		}
		assertions := countAssertions(check)
		result.ChecksRun++
		result.Assertions += assertions
		result.Failures = append(result.Failures, failures...)
		result.Checks = append(result.Checks, CheckOutcome{
			Name:         check.Name,
			Assertions:   assertions,
			Failures:     failures,
			Evidence:     r.Evidence.Gathered(check.Name),
			EvidenceGaps: r.Evidence.Missing(check.Name),
		})
	}
	return result
}

// quarantineNote says what a quarantined check did. Both outcomes are
// reported: a quarantined check that passed is still not evidence, because
// nothing has decided it is reliable again.
func quarantineNote(name string, failures []string) string {
	if len(failures) == 0 {
		return fmt.Sprintf("%s: quarantined, and it passed this time — it is still not "+
			"evidence until it is taken out of quarantine deliberately", name)
	}
	return fmt.Sprintf("%s: quarantined, and it failed: %s", name, joinSemicolons(failures))
}

// runCheck executes one check and returns its failures.
//
// **An unverified act must be confirmed by a later read that observed
// something.** Orca reports an act it could not assert as
// `unverified (synthetic input)`, so an act that may not have happened,
// followed by nothing that looks, is a check that passes on an act that never
// landed. Such an act is held pending and cleared only by a **confirming**
// assertion — see Expect.Confirms. One still pending when the check ends is a
// failure.
func (r *Runner) runCheck(check Check) []string {
	var failures []string
	var pending []string
	captured := false
	// **Per check, not per launch.** One launch runs one check file by this
	// target's own rule, but the runner takes a list, and an act log carrying
	// the previous file's acts would put a reader of a red check in another
	// check's window.
	r.acts = nil
	r.interference = nil

	// note records a failure and, the first time, captures what the window
	// looked like AT the failing step rather than at the end of the check.
	note := func(format string, args ...interface{}) {
		failures = append(failures, fmt.Sprintf(format, args...))
		if !captured && r.Evidence != nil {
			captured = true
			r.Evidence.Capture(r.Orca, r.PID, r.Channel, check.Name)
		}
	}

	for index, step := range check.Steps {
		where := fmt.Sprintf("%s step %d", check.Name, index+1)
		switch {
		case step.Do != nil:
			stopWatching := r.watchInput(step.Do)
			unconfirmed, err := r.act(step.Do)
			r.logAct(where, step.Do, err)
			r.recordInterference(where)
			r.recordOutsideInput(where, stopWatching)
			switch {
			case err != nil:
				note("%s: %v", where, err)
			case unconfirmed != "":
				pending = append(pending, fmt.Sprintf("%s: %s", where, unconfirmed))
			}
		case step.Dispatch != nil:
			if err := r.dispatch(step.Dispatch); err != nil {
				note("%s: %v", where, err)
			}
		case step.Expect != nil:
			if err := r.assert(step.Expect); err != nil {
				note("%s: %v", where, err)
			} else if step.Expect.Confirms() {
				pending = nil
			}
		case step.Parity != nil:
			if err := r.parity(step.Parity); err != nil {
				note("%s: %v", where, err)
			} else {
				// Parity reads the window state three times and requires it to
				// have changed, so a parity step that passed is the strongest
				// confirmation available.
				pending = nil
			}
		default:
			note("%s: carries no step kind, which ParseChecks should have refused", where)
		}
	}
	for _, unconfirmed := range pending {
		note("%s, and no confirming state read followed it — an act that may not have "+
			"happened must never pass", unconfirmed)
	}
	if len(failures) > 0 && r.Evidence != nil {
		r.Evidence.Acts(check.Name, r.acts)
		if err := r.Evidence.Record(check.Name, failures); err != nil {
			failures = append(failures,
				fmt.Sprintf("%s: the evidence could not be written: %v", check.Name, err))
		}
	}
	return failures
}

// logAct records one act and the state around it, for the evidence a red
// check leaves.
//
// **Every act, not only the failing one.** The failure this exists for is a
// press that reported success and did nothing (#284), so the act worth reading
// about is by definition one that was not reported as a problem — and which of
// them it was is the question. A log of only the noisy acts would omit it by
// construction.
//
// **Description, never a verdict.** Nothing here decides anything: an act with
// a frontmost reading that looks wrong still passed if the app did what the
// check asked, and a line in this file has never made a run red.
func (r *Runner) logAct(where string, do *Do, err error) {
	outcome := "ok"
	if err != nil {
		outcome = "refused: " + err.Error()
	}
	// **Both readings, and the before one first.** They are usually the same
	// sentence and the line is shorter for saying so once; when they differ,
	// the act itself moved the foreground, and that is the whole finding.
	before := describeReading(r.beforeLastAct, r.beforeLastActErr)
	after := describeReading(r.atLastAct, r.atLastActErr)
	around := before
	if before != after {
		around = before + " | after: " + after
	}
	if r.broughtForward {
		around = "the fixture was not front and was brought forward; " + around
	}
	r.acts = append(r.acts, fmt.Sprintf("%s: %s -> %s; %s",
		where, do.Describe(), outcome, around))
}

// describeReading says what one reading of the window server amounts to.
//
// **"Not asked" and "asked and it failed" are different facts**, and the first
// reads as though the harness chose not to look. An act delivered by a channel
// that reports nothing is the first; a diagnostic that broke is the second.
func describeReading(reading *Frontmost, err error) string {
	if reading == nil && err != nil {
		return err.Error()
	}
	return reading.String()
}

// act drives the GUI and re-reads. It returns a non-empty string when the act
// was made but Orca could not confirm it.
func (r *Runner) act(do *Do) (unconfirmed string, err error) {
	var response Response
	// **Cleared first**, so a reading left by a previous act can never be
	// filed against this one — which is the one way this log could mislead
	// rather than merely fall short.
	r.atLastAct, r.atLastActErr = nil, nil
	r.beforeLastAct, r.beforeLastActErr, r.broughtForward = nil, nil, false
	// **The fixture is brought forward before the act, not after it is
	// refused. #284.**
	//
	// Measured 2026-09-25, under load, on the run this instrument was built
	// for: `com.stablyai.orca` — this harness's OWN actuation tool — was the
	// frontmost application when it delivered `keys "vim"`, and vim never
	// opened. Orca reported `ok`. It always will: a keystroke goes to
	// whatever holds the foreground, and if that is Orca then Orca received
	// it and nothing was refused.
	//
	// **Which is why activate-on-refusal could never have caught this.** That
	// mitigation, three paragraphs down, fires on `window_not_focused` — an
	// act Orca declined to deliver. This is an act Orca delivered, to itself.
	// The two are indistinguishable from the reply and opposite in what they
	// need doing.
	//
	// **And it is a precondition, not a retry.** The forbidden retry re-runs
	// a check until it goes green, which destroys it as evidence. Nothing is
	// re-run here and nothing has been observed yet: this makes true, before
	// the act, the one condition under which delivering it means anything.
	// It is the same thing `Session.Run` does once at launch, for the same
	// reason, applied where the reason actually bites.
	//
	// **A reading that cannot be taken never blocks the act.** This is a
	// diagnostic with a remedy attached; an act that would have worked must
	// not fail because the window server could not be asked.
	r.beforeLastAct, r.beforeLastActErr = r.Resolver.Frontmost(r.PID)
	if r.beforeLastAct != nil && !r.beforeLastAct.IsTarget {
		if activateErr := Activate(r.PID); activateErr == nil {
			r.broughtForward = true
			r.beforeLastAct, _ = r.Resolver.Frontmost(r.PID)
		}
	}
	// **Read afterwards too.** The reading before says what the act was
	// delivered into; the reading after says what it left behind, which is
	// how an act that takes the foreground away from the fixture is caught at
	// the act that did it rather than at the next one.
	defer func() {
		switch {
		case response.Frontmost != nil:
			r.atLastAct = response.Frontmost
		case response.OK:
			r.atLastAct, r.atLastActErr = r.Resolver.Frontmost(r.PID)
		}
	}()
	switch {
	case do.Click != "":
		response, err = r.Resolver.Press(r.PID, do.Click)
	case do.Focus != "":
		return r.focus(do.Focus)
	case do.Drag != nil:
		response, err = r.Resolver.Drag(r.PID, do.Drag.From, do.Drag.To)
	// **The modifier arms are the resolver's, not Orca's.** Orca's hotkey
	// presses and releases a chord in one call, and a hold has to stay down
	// across the steps that assert what it draws. See `Do.Hold`.
	case do.Hold != "":
		response, err = r.Resolver.Modifier(r.PID, do.Hold, true)
	case do.Release != "":
		response, err = r.Resolver.Modifier(r.PID, do.Release, false)
	case do.Resize != nil:
		response, err = r.Resolver.Resize(r.PID, do.Resize.Width, do.Resize.Height)
	case do.Type != nil:
		response, err = r.typeInto(do.Type)
	// **The keystroke arms go through Orca, not the resolver.** They address
	// keyboard focus rather than a named element, which is the only thing
	// that reaches a PTY — a terminal grid is a canvas with no identifier,
	// and `AXPress` and `set-value` both mean nothing to a shell.
	case do.Keys != "":
		response, err = r.Orca.TypeText(r.PID, ExpandText(do.Keys, r.tokens()))
	case do.Press != "":
		response, err = r.Orca.PressKey(r.PID, do.Press)
	case do.Hotkey != "":
		response, err = r.Orca.Hotkey(r.PID, do.Hotkey)
	default:
		// ParseChecks refuses this, but Run takes checks from any source and a
		// panic is the one failure this harness cannot report: it never
		// reaches Result.Err and never writes evidence.
		return "", fmt.Errorf("a do step that drives none of the ten arms reached the runner")
	}
	if err != nil {
		return "", err
	}
	// **A keystroke refused for focus is delivered once more, after
	// activating — and that is not the retry this harness forbids.** The
	// forbidden one re-runs a CHECK until it goes green, which destroys it as
	// evidence. This re-runs an ACT whose refusal says, in Orca's own words,
	// that it was never delivered at all: nothing was observed, so there is
	// no result to launder. An app started with `open -n` does not reliably
	// become frontmost, and a run that lost the race refused four acts in a
	// row while three checks around it passed.
	//
	// **Once.** A second refusal is reported with what actually held the
	// screen, because at that point the cause is outside this run.
	if !response.OK && refusedForFocus(response) {
		if activateErr := Activate(r.PID); activateErr != nil {
			return "", fmt.Errorf("the act was refused for focus and the window could not be "+
				"brought forward: %w", activateErr)
		}
		response, err = r.redo(do)
		if err != nil {
			return "", err
		}
	}
	if !response.OK {
		if refusedForFocus(response) {
			return "", fmt.Errorf("the act was refused: %v (the frontmost application is %s)",
				response.Err, describeFrontmost())
		}
		return "", fmt.Errorf("the act was refused: %v", response.Err)
	}
	// **Every act is followed by a re-read**, so the state a later assertion
	// sees is the state after this act and never the state before it.
	if _, readErr := r.state(); readErr != nil {
		return "", fmt.Errorf("the act was made but the window could not be re-read: %w", readErr)
	}
	if response.Acted && !response.Verified {
		return fmt.Sprintf("the act was made but reported unverified (%s)%s",
			UnverifiedReason(response.ActPath, response.ActReason), r.foregroundLostNote()), nil
	}
	return "", nil
}

// foregroundLostNote says, in the failure itself, that the fixture stopped
// being frontmost across this act.
//
// **Because otherwise the reader has to think of opening `acts.txt`.**
// Measured 2026-09-25 on `2c-iii-6-no-orphan.jsonl`: `hotkey cmd+w` was
// delivered with the fixture front, `com.microsoft.teams2` was front
// immediately after, and the pane did not close — the chord went to Teams.
// The three failures that followed read as the app ignoring cmd+w, and the
// only thing in the run that said otherwise was one line in another file.
//
// **It reports and never retries.** The act was delivered somewhere; unlike a
// refusal, there IS a result, and re-running the act to get a better one is
// exactly the laundering `docs/agents/e2e.md` forbids. This changes no
// verdict — the act was already unconfirmed and the check already red — only
// what the verdict says about itself.
func (r *Runner) foregroundLostNote() string {
	before, after := r.beforeLastAct, r.atLastAct
	if before == nil || after == nil || !before.IsTarget || after.IsTarget {
		return ""
	}
	took := after.BundleID
	if took == "" {
		took = fmt.Sprintf("pid %d", after.PID)
	}
	return fmt.Sprintf(", and %s took the foreground across it — so the act may have been "+
		"delivered there rather than to the fixture", took)
}

// typeInto puts text into a named field, by focusing it and then typing.
//
// **Two acts, because one of them cannot do it. #284, Defect 2.** This arm was
// `set-value` alone, and `set-value` on a SwiftUI `TextField` writes the
// element's accessibility value without the `@State` behind it ever seeing a
// character: the field READS as typed-into, to the tree and so to an
// `expect.tree`, while the binding the app sends holds the empty string it
// started with. `both-surfaces.jsonl` clicked Send after one of these for
// three green runs, and the agent's log says it was never asked anything.
//
// **It was silent, which is what made it worth fixing rather than
// documenting.** `set-value` reads the value back and reported VERIFIED — the
// strongest confirmation this harness has — because the value really was
// there. Nothing a check could assert distinguished that from the text having
// arrived, so the trap was invisible from inside the vocabulary.
//
// **It costs the foreground now**, which the old arm did not, and that is the
// whole of what was lost: real keystrokes go to whatever the system considers
// key. That cost bought nothing while the text never arrived.
//
// **It types, so it appends.** A field with contents keeps them and the text
// lands at the insertion point — the opposite of what `set-value` did. Every
// check that types into a field types into an empty one; one that does not
// wants to say so.
func (r *Runner) typeInto(into *TypeInto) (Response, error) {
	// The resolver refuses in two shapes — an error, and a reply that is not
	// OK — and both mean the same thing here, so both say the same sentence.
	focused, err := r.Resolver.Focus(r.PID, into.Into)
	if err == nil && !focused.OK {
		err = fmt.Errorf("%v", focused.Err)
	}
	if err != nil {
		return Response{}, fmt.Errorf(
			"%s could not be focused, so there is nowhere for the text to go: %w", into.Into, err)
	}
	return r.Orca.TypeText(r.PID, ExpandText(into.Text, r.tokens()))
}

// focus gives a control keyboard focus, through the accessibility API.
//
// **Not a click.** A coordinate click would do it, and Orca refuses one unless
// the target window is the focused topmost recipient — which a fixture window
// launched by `open -n` is not, measured 2026-09-24: "no focused window",
// after activating the app and re-reading. `AXFocused` is settable, is read
// back by the resolver, and costs no foreground.
func (r *Runner) focus(identifier string) (unconfirmed string, err error) {
	response, err := r.Resolver.Focus(r.PID, identifier)
	if err != nil {
		return "", err
	}
	if !response.OK {
		return "", fmt.Errorf("%s could not be focused: %v", identifier, response.Err)
	}
	// **Every act is followed by a re-read**, so a later assertion sees the
	// state after this one and never the state before it.
	if _, readErr := r.state(); readErr != nil {
		return "", fmt.Errorf("%s was focused but the window could not be re-read: %w",
			identifier, readErr)
	}
	// The resolver verifies this act by reading the attribute back, so unlike
	// a press it is never left pending.
	return "", nil
}

// refusedForFocus reports whether Orca declined because the target window was
// not frontmost, which is the one refusal that is about delivery rather than
// about the act.
func refusedForFocus(response Response) bool {
	return response.Err != nil && response.Err.Code == "window_not_focused"
}

// redo re-sends the act after an activation. Only the keyboard arms can be
// refused for focus; a click is the resolver's and takes the foreground itself.
//
// **`type` re-sends only its keystrokes.** Its focus half is the resolver's,
// needs no foreground, and already succeeded — re-focusing a field that is
// already focused would change nothing, and doing it here would hide a focus
// failure behind a keystroke retry.
func (r *Runner) redo(do *Do) (Response, error) {
	switch {
	case do.Keys != "", do.Type != nil:
		return r.Orca.TypeText(r.PID, r.textOf(do))
	case do.Press != "":
		return r.Orca.PressKey(r.PID, do.Press)
	case do.Hotkey != "":
		return r.Orca.Hotkey(r.PID, do.Hotkey)
	default:
		return Response{}, fmt.Errorf("only a keystroke can be refused for focus")
	}
}

// textOf is the literal text a keystroke arm sends. `keys` carries it
// directly; `type` carries it beside the field it was aimed at, and by the
// time a redo runs that field is already focused.
func (r *Runner) textOf(do *Do) string {
	if do.Type != nil {
		return ExpandText(do.Type.Text, r.tokens())
	}
	return ExpandText(do.Keys, r.tokens())
}

// describeFrontmost names what has the screen, so a focus refusal points at
// the cause rather than only at the symptom.
func describeFrontmost() string {
	pid, err := FrontmostPID()
	if err != nil {
		return "unknown"
	}
	return fmt.Sprintf("pid %d", pid)
}

// dispatch sends one action over the agent channel and re-reads.
func (r *Runner) dispatch(step *Dispatch) error {
	if r.Channel == nil {
		return fmt.Errorf("no agent channel is open, so %q cannot be dispatched", step.Action)
	}
	_, err := r.Channel.Call(step.Action, ExpandParams(step.Params, r.tokens()))
	switch {
	case step.Refuses != "" && err == nil:
		return fmt.Errorf("%q was expected to be refused with %q, and it ran", step.Action, step.Refuses)
	case step.Refuses != "" && !strings.Contains(err.Error(), step.Refuses):
		return fmt.Errorf("%q was refused, but not with %q: %v", step.Action, step.Refuses, err)
	case step.Refuses == "" && err != nil:
		return err
	}
	if _, err := r.state(); err != nil {
		return fmt.Errorf("%q was dispatched but the window could not be re-read: %w", step.Action, err)
	}
	return nil
}

// assert proves one fact, waiting on a predicate rather than sleeping.
func (r *Runner) assert(expect *Expect) error {
	switch {
	case expect.Tree != "":
		return r.settle(func() error { return r.assertTree(expect) })
	case expect.Pane != "":
		return r.settle(func() error { return r.assertPane(expect) })
	case expect.Process != nil:
		return r.settle(func() error { return r.assertProcess(expect.Process) })
	case expect.Journal != nil:
		return r.settle(func() error { return r.assertJournal(expect.Journal) })
	case expect.Focus != "":
		return r.settle(func() error { return r.assertFocus(expect.Focus) })
	case expect.Frame != "":
		return r.settle(func() error { return r.assertFrame(expect) })
	default:
		return fmt.Errorf("an expect step with no arm reached the runner")
	}
}

// settle re-reads until the predicate holds or the deadline passes.
//
// **Never a fixed sleep.** attempt is re-run, taking a fresh read each time,
// and the LAST failure is what gets reported — so a timed-out assertion says
// what the window actually held rather than that it timed out.
func (r *Runner) settle(attempt func() error) error {
	err := attempt()
	if err == nil || r.Settle <= 0 {
		return err
	}
	deadline := time.Now().Add(r.Settle)
	for time.Now().Before(deadline) {
		time.Sleep(settleInterval)
		if err = attempt(); err == nil {
			return nil
		}
	}
	return fmt.Errorf("%w (still true after waiting %s)", err, r.Settle)
}

func (r *Runner) assertTree(expect *Expect) error {
	snapshot, err := r.state()
	if err != nil {
		return err
	}
	present := snapshot.Contains(expect.Text)
	if expect.Tree == TreeAbsent {
		if present {
			return fmt.Errorf("the tree contains %q, which was asserted absent", expect.Text)
		}
		return nil
	}
	if !present {
		return fmt.Errorf("the tree does not contain %q (%d elements were visible)",
			expect.Text, snapshot.ElementCount)
	}
	return nil
}

// assertFocus reads the app's own focused element and its ancestors — never
// the system's, so a check is not failed by another app taking the foreground
// (#418). An app with no focused window has no focus to assert on.
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
	where := "an element with no identifier above it"
	if len(front.FocusedWithin) > 0 {
		where = strings.Join(front.FocusedWithin, " › ")
	}
	role := front.FocusedRole
	if role == "" {
		role = "nothing"
	}
	return fmt.Errorf("focus is not on %s: it is on %s, within %s", name, role, where)
}

// assertFrame resolves the step's element — and the one it is held inside or
// clear of — and judges its rectangle. Any element that does not resolve fails
// the step by name.
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

func (r *Runner) assertPane(expect *Expect) error {
	fields, err := r.paneFields(expect.Pane)
	if err != nil {
		return err
	}
	raw, err := PanePath(fields, expect.Field)
	if expect.Present != nil {
		// **An explicit null is not present, and the retrodiction is what
		// proved that.** `PaneSnapshot`'s own rule is that every key of the
		// answered kind is always there, "including when false, empty or
		// null" — so a predicate asking only whether the KEY exists is
		// vacuous against this wire shape. With 2c-iii's live-prompt defect
		// put back, `promptRow` was present and null, and the check written
		// to catch that defect passed.
		//
		// A check that does want "the key is there holding null" says
		// `equals: "null"`, which stays expressible and says what it means.
		holdsSomething := err == nil && raw != nil
		switch {
		case *expect.Present && err != nil:
			return fmt.Errorf("pane %q: %w", expect.Pane, err)
		case *expect.Present && !holdsSomething:
			return fmt.Errorf(
				"pane %q field %q is null — the key is there and holds nothing, which is what "+
					"a field nothing publishes looks like", expect.Pane, expect.Field)
		case *expect.Present:
			return nil
		case holdsSomething:
			return fmt.Errorf("pane %q field %q is there (it holds %s), and it was asserted absent",
				expect.Pane, expect.Field, scalar(raw))
		}
		// **`present: false` asserts a LEAF is absent from a container that
		// EXISTS.** Without that, it is satisfied by any path that fails to
		// resolve — including a misspelled one — so `blcoks[-1].exitCode`
		// passed against every build, having looked at nothing. See
		// PanePathContainer.
		if container, _ := PanePathContainer(expect.Field); container != "" {
			if _, containerErr := PanePath(fields, container); containerErr != nil {
				return fmt.Errorf(
					"pane %q: %w — so nothing was asserted about %q; a path whose container is "+
						"missing is a typo, not an absent field",
					expect.Pane, containerErr, expect.Field)
			}
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("pane %q: %w", expect.Pane, err)
	}
	got := scalar(raw)
	switch {
	case expect.Contains != nil:
		if !strings.Contains(got, *expect.Contains) {
			// **The whole value is shown, not a summary.** A grid that does
			// not contain what a check expected is diagnosed by reading what
			// it DOES contain, and a second live run to find that out costs a
			// launch and the operator's screen.
			return fmt.Errorf("pane %q field %q does not contain %q; it holds %s",
				expect.Pane, expect.Field, *expect.Contains, got)
		}
	case got != *expect.Equals:
		return fmt.Errorf("pane %q field %q is %q, want %q", expect.Pane, expect.Field, got, *expect.Equals)
	}
	return nil
}

func (r *Runner) assertProcess(process *Process) error {
	pattern := process.Pattern()
	if r.Processes == nil {
		return fmt.Errorf("no process table is available, so %q cannot be asserted", pattern)
	}
	matches, err := r.Processes.Matching(pattern)
	if err != nil {
		return fmt.Errorf("the process table could not be read (%w), so nothing about %q is known",
			err, pattern)
	}
	if process.AnyMatching != "" {
		if len(matches) == 0 {
			return fmt.Errorf(
				"no process matches %q, so a later assertion that none survives would prove "+
					"nothing — it would pass whether or not the process was ever started", pattern)
		}
		return nil
	}
	if len(matches) > 0 {
		return fmt.Errorf("%d process(es) matching %q survived: %s",
			len(matches), pattern, joinSemicolons(matches))
	}
	return nil
}

// parity performs one action by clicking and again by dispatching, and
// asserts the state landed identically.
//
// **Two things must hold, and only asserting the first is the trap.**
// Invariant 2 forbids two code paths to the same state, so the channels must
// agree — but two channels that both do NOTHING also agree. A parity step
// that compared only the two outcomes would pass green on a click that
// pressed nothing and an action that silently no-ops, while counting itself
// an assertion. So the baseline is read first and the click must be seen to
// change it.
//
// **The action must be idempotent**, and that is the check author's
// obligation rather than something enforceable here: the two drives happen in
// sequence against one window, so an action that toggles would be compared
// against its own inverse. `pane_maximize` and `pane_focus` qualify;
// `pane_open` does not.
func (r *Runner) parity(parity *Parity) error {
	if r.Channel == nil {
		return fmt.Errorf("no agent channel is open, so the dispatch half of parity cannot run")
	}
	before, err := r.settledParityState(parity)
	if err != nil {
		return fmt.Errorf("the state before the UI half could not be read: %w", err)
	}

	// **The UI half is a click or a drag**, and both are unverified acts, so
	// the rule below is the same for each: the state must be seen to change.
	var clicked Response
	if parity.Drag != nil {
		clicked, err = r.Resolver.Drag(r.PID, parity.Drag.From, parity.Drag.To)
	} else {
		clicked, err = r.Resolver.Press(r.PID, parity.Click)
	}
	if err != nil {
		return fmt.Errorf("the UI half could not be driven: %w", err)
	}
	if !clicked.OK {
		return fmt.Errorf("the UI half was refused: %v", clicked.Err)
	}
	// **A drop lands after the drag returns** (2c-iv, Ruling 9). The drag's
	// last event is a mouse-up, and what it drops is decoded and dispatched
	// by the app afterwards — so the first reads after a drag can still be
	// `before`, and would settle there. Measured live on `api_bind`: the
	// parity said "changed nothing" while the evidence, captured an instant
	// later, already held the binding. So a drag's state is first awaited to
	// DIFFER from `before`, within the same bound every assertion waits,
	// and only then asked to go quiet. The act is never repeated, and a drop
	// that never lands still reaches the refusal below. A click is
	// unchanged: an AX press has finished acting by the time it returns.
	if parity.Drag != nil {
		if err := r.awaitChangeFrom(parity, before); err != nil {
			return fmt.Errorf("the state after the UI half could not be read: %w", err)
		}
	}
	afterClick, err := r.settledParityState(parity)
	if err != nil {
		return fmt.Errorf("the state after the UI half could not be read: %w", err)
	}
	if afterClick == before {
		// This also covers the unverified act: one nothing could assert and
		// which changed nothing is exactly the act that must not pass.
		unverified := ""
		if clicked.Acted && !clicked.Verified {
			unverified = fmt.Sprintf(", and the act was reported unverified (%s)",
				UnverifiedReason(clicked.ActPath, clicked.ActReason))
		}
		return fmt.Errorf(
			"%s changed nothing%s, so the two channels would be compared on a "+
				"state neither of them reached and the step would prove nothing",
			parity.UIHalf(), unverified)
	}

	if _, err := r.Channel.Call(parity.Action, ExpandParams(parity.Params, r.tokens())); err != nil {
		return fmt.Errorf("the dispatch half was refused: %w", err)
	}
	afterDispatch, err := r.settledParityState(parity)
	if err != nil {
		return fmt.Errorf("the state after the dispatch could not be read: %w", err)
	}
	if afterClick != afterDispatch {
		return fmt.Errorf(
			"%q left different state through the two channels, which is Invariant 2 broken:\n"+
				"      %s gave %s\n"+
				"      dispatching gave %s",
			parity.Action, parity.UIHalf(), afterClick, afterDispatch)
	}
	return nil
}

// awaitChangeFrom reads the parity state until it differs from before, for up
// to r.Settle. **Not finding a change is not an error here** — it returns nil,
// and the caller's own comparison then refuses the step as having changed
// nothing, with the message every parity uses. Only a failed read is an error.
func (r *Runner) awaitChangeFrom(parity *Parity, before string) error {
	deadline := time.Now().Add(r.Settle)
	for {
		current, err := r.parityState(parity)
		if err != nil {
			return err
		}
		if current != before || !time.Now().Before(deadline) {
			return nil
		}
		time.Sleep(settleInterval)
	}
}

// settledParityState reads the state a parity step compares through, once it
// has stopped changing.
//
// **Transient state would otherwise fail a parity that holds.** Measured: a
// `pane_focus` parity compared identical `focusedId`s and failed anyway, on
// `busy: true` versus `busy: false` for a terminal whose shell was still
// starting when the first read was taken and had settled by the second. The
// two channels agreed about everything the action governs; the comparison
// disagreed about the weather.
//
// Quiescence is the predicate — two consecutive reads that agree — rather than
// a list of fields to ignore. A denylist would have to be maintained for every
// pane kind, and would be one more place to forget something; and a field that
// never settles is a fact worth reporting rather than hiding.
func (r *Runner) settledParityState(parity *Parity) (string, error) {
	previous, err := r.parityState(parity)
	if err != nil {
		return "", err
	}
	if r.Settle <= 0 {
		return previous, nil
	}
	deadline := time.Now().Add(r.Settle)
	for time.Now().Before(deadline) {
		time.Sleep(settleInterval)
		current, err := r.parityState(parity)
		if err != nil {
			return "", err
		}
		if current == previous {
			return current, nil
		}
		previous = current
	}
	return "", fmt.Errorf(
		"the state never stopped changing within %s, so the two channels cannot be compared "+
			"against it; the last reading was %s", r.Settle, previous)
}

// parityState reads the state a parity step compares through.
func (r *Runner) parityState(parity *Parity) (string, error) {
	switch parity.Assert {
	case ParityTree:
		snapshot, err := r.state()
		if err != nil {
			return "", err
		}
		return snapshot.TreeText, nil
	case ParityReadPane:
		// ParseChecks refuses a read_pane parity that names no pane, so this
		// is the defence for a Check built in Go rather than parsed.
		id := ParityPaneID(parity.Params)
		if id == "" {
			return "", fmt.Errorf(
				"a parity step asserting through read_pane must name the pane as params.id " +
					"or params.pane")
		}
		return r.readJSON("read_pane", map[string]interface{}{"paneId": id})
	default:
		return r.readJSON("read_layout", nil)
	}
}

// state reads the accessibility tree now.
func (r *Runner) state() (Snapshot, error) {
	response, err := r.Orca.GetAppState(r.PID)
	if err != nil {
		return Snapshot{}, fmt.Errorf("could not read the app's state: %w", err)
	}
	if !response.OK {
		return Snapshot{}, fmt.Errorf("orca refused the read: %v", response.Err)
	}
	return response.Snapshot, nil
}

// paneFields reads one pane's snapshot as a flat map.
func (r *Runner) paneFields(paneID string) (map[string]interface{}, error) {
	if r.Channel == nil {
		return nil, fmt.Errorf("no agent channel is open, so pane %q cannot be read", paneID)
	}
	result, err := r.Channel.Call("read_pane", map[string]interface{}{"paneId": paneID})
	if err != nil {
		return nil, fmt.Errorf("pane %q could not be read: %w", paneID, err)
	}
	var fields map[string]interface{}
	if err := json.Unmarshal(ResultBody(result), &fields); err != nil {
		return nil, fmt.Errorf("pane %q answered something that is not an object (%w): %s",
			paneID, err, firstLine(ResultBody(result)))
	}
	return fields, nil
}

// readJSON returns one tool result as canonical text to compare.
//
// **A reply that is not JSON is a failure, not a raw-text comparison.** Two
// unreadable replies compare equal to each other, so a lenient fallback here
// would let a parity step pass on two errors.
func (r *Runner) readJSON(action string, arguments map[string]interface{}) (string, error) {
	result, err := r.Channel.Call(action, arguments)
	if err != nil {
		return "", err
	}
	body := ResultBody(result)
	// Re-marshalled through the decoded value so that key order, which JSON
	// does not fix, cannot make two identical states compare unequal.
	var canonical interface{}
	if err := json.Unmarshal(body, &canonical); err != nil {
		return "", fmt.Errorf("%s answered something that is not JSON (%w): %s",
			action, err, firstLine(body))
	}
	encoded, err := json.Marshal(canonical)
	if err != nil {
		return "", fmt.Errorf("%s answered JSON that could not be re-encoded to compare: %w", action, err)
	}
	return string(encoded), nil
}

// countAssertions counts the steps of a check that prove something.
func countAssertions(check Check) int {
	count := 0
	for _, step := range check.Steps {
		if step.IsAssertion() {
			count++
		}
	}
	return count
}

// scalar renders a JSON value the way a check author wrote it in `equals`.
func scalar(value interface{}) string {
	switch typed := value.(type) {
	case string:
		return typed
	case nil:
		return "null"
	case float64:
		if typed == float64(int64(typed)) {
			return fmt.Sprintf("%d", int64(typed))
		}
		return fmt.Sprintf("%g", typed)
	case bool:
		return fmt.Sprintf("%t", typed)
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprintf("%v", typed)
		}
		return string(encoded)
	}
}

// sortedKeys lists a map's keys, so an error message naming what a pane does
// carry is stable between runs.
func sortedKeys(fields map[string]interface{}) []string {
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}
