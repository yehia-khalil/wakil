package driver

import (
	"fmt"
	"maps"
	"slices"
	"sort"
	"strings"
)

// ExemptionFile lists surface the gate may not demand a check for, and why.
const ExemptionFile = "e2e/checks/uncoverable.tsv"

// The two denominators, as a gap's kind.
const (
	GapAction  = "action"
	GapControl = "control"
)

// The three rules of design §2, as the sentence a failing gate prints.
//
// Named rather than spelled at each use, because the rule a gap failed is
// matched on in tests and printed in a report, and two spellings of one rule
// is one spelling that goes stale.
const (
	RuleDispatched = "no check dispatches it"
	RuleParity     = "it writes, and no check drives it down both channels to prove they agree"
	RuleExercised  = "no check presses it"
)

// Surface is a denominator: what the app can be asked to do, and what it can
// be pressed by.
//
// The two halves come from different places on purpose — the actions from
// `tools/list` on a live window, the controls from the Swift the window is
// drawn by — because those are the only two places that know, and neither can
// answer the other's question.
type Surface struct {
	Actions     []Tool
	Identifiers []Identifier
}

// Gap is one piece of surface no check reaches, and the rule it fails.
type Gap struct {
	Kind string
	Name string
	Rule string
	// Where is the file and line a control is drawn at, or empty for an
	// action — whose "where" is the registry, which is not a place a reader
	// can be sent.
	Where string
	// Reason is filled only on an excused gap: where the obligation went, in
	// the words of whoever excused it.
	Reason string
}

func (g Gap) String() string {
	text := fmt.Sprintf("%s %s: %s", g.Kind, g.Name, g.Rule)
	if g.Where != "" {
		text += fmt.Sprintf(" (%s)", g.Where)
	}
	if g.Reason != "" {
		text += " — excused: " + g.Reason
	}
	return text
}

// Gaps is the whole computation: which of this surface no check reaches.
//
// **It judges whatever surface it is handed**, which is what makes one
// function serve both the standing gate and the discovery audit. Handed the
// surface a branch ADDED it is the gate of design §2; handed the whole
// denominator it is the backlog of §9.3. Two functions here would be two
// answers to *what does covered mean*, and the day they disagreed the backlog
// would be quietly wrong about the thing the gate was enforcing.
func Gaps(surface Surface, cover Coverage) []Gap {
	var gaps []Gap
	for _, action := range surface.Actions {
		switch {
		case !cover.Dispatches(action.Name):
			// **One gap, not two.** An action nothing drives also has no
			// parity check, and saying both would report one missing check
			// twice — which reads as twice the work and, in a backlog, as
			// twice the debt.
			gaps = append(gaps, Gap{Kind: GapAction, Name: action.Name, Rule: RuleDispatched})
		case !action.ReadOnly && !cover.HasParity(action.Name):
			gaps = append(gaps, Gap{Kind: GapAction, Name: action.Name, Rule: RuleParity})
		}
	}
	seen := map[string]bool{}
	for _, identifier := range surface.Identifiers {
		if seen[identifier.Name] || cover.Exercises(identifier.Name) {
			continue
		}
		seen[identifier.Name] = true
		gaps = append(gaps, Gap{
			Kind:  GapControl,
			Name:  identifier.Name,
			Rule:  RuleExercised,
			Where: fmt.Sprintf("%s:%d", identifier.File, identifier.Line),
		})
	}
	return gaps
}

// Excuse splits gaps by the exemption list: the ones still owed, and the ones
// redirected with a reason.
//
// **An entry is a redirect, never an exemption** — the words `LoadBackfill`
// uses of its own list, and the same discipline: the excused gaps come back to
// the caller to be printed on every run, because a list nobody is reminded of
// is a list that grows.
func Excuse(gaps []Gap, exemptions map[string]string) (remaining, excused []Gap) {
	for _, gap := range gaps {
		if reason, ok := exemptions[gap.Name]; ok {
			gap.Reason = reason
			excused = append(excused, gap)
			continue
		}
		remaining = append(remaining, gap)
	}
	return remaining, excused
}

// LoadExemptions reads the uncoverable list: a name, a tab, and why no check
// can reach it.
//
// **The same file shape as the backfill list, read by the same loader.** Both
// are redirects with reasons, both are refused without one, and both are
// printed every run; two readers of one format would be one reader that goes
// stale.
//
// **A bare name is enough to say which piece of surface is meant.** An action
// name is snake_case and carries no dot; an identifier always carries one and
// must open with a registered surface, so no name can mean both. What keeps
// the file honest is not a type column but the rule above it: an entry that
// excuses nothing fails the gate.
func LoadExemptions(path string) (map[string]string, error) {
	return loadRedirects(path,
		"an entry here says why no check can reach a piece of surface, and one without a "+
			"reason is a hole nobody has to justify")
}

// CoverageReport is what a run says about coverage: the verdict on the new
// surface, and the state of the whole.
type CoverageReport struct {
	// Surface is the whole denominator, both halves.
	Surface Surface
	// New is the part of it this branch added. Only this part can fail.
	New Surface
	// Gaps are the new surface's unexcused gaps: the gate's verdict.
	Gaps []Gap
	// Excused are the gaps the uncoverable list redirects — over the WHOLE
	// surface, not only the new part, so an entry written for surface that has
	// since stopped being new is still reported rather than silently kept.
	Excused []Gap
	// Stale names the entries that excuse nothing at all. They fail the gate.
	Stale []string

	backlog []Gap
	cover   Coverage
}

// Judge computes a run's coverage verdict.
//
// **Only newly added surface fails** (design §2). Surface that predates the
// branch is the discovery audit's backlog, and a gate that demanded the whole
// registry on day one would be switched off within a week — which is how the
// north-star's first word limit failed.
func Judge(all, fresh Surface, cover Coverage, exemptions map[string]string) CoverageReport {
	// The exemptions are applied to the WHOLE surface's gaps first, and what
	// that buys is the staleness check below: an entry is valid exactly while
	// the thing it excuses is still uncovered somewhere, which is a question
	// the new surface alone cannot answer.
	backlog, excused := Excuse(Gaps(all, cover), exemptions)
	gaps, _ := Excuse(Gaps(fresh, cover), exemptions)

	live := map[string]bool{}
	for _, gap := range excused {
		live[gap.Name] = true
	}
	var stale []string
	for name := range exemptions {
		if !live[name] {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)

	return CoverageReport{
		Surface: all, New: fresh, Gaps: gaps, Excused: excused, Stale: stale,
		backlog: backlog, cover: cover,
	}
}

// Backlog is every remaining gap in the WHOLE denominator, new or not: the
// discovery audit's output (design §9.3). It is a list of work, never a gate,
// and what is excused with a reason is not work — it is reported as excused
// instead, which is where a reviewer reads the reason.
func (r CoverageReport) Backlog() []Gap { return r.backlog }

// Counts renders the two coverage sets as the numbers a run prints.
//
// **Both denominators, every run**, including the one that passes: a gate that
// only spoke when it failed would let coverage of the whole registry fall
// without anything ever saying so.
func (r CoverageReport) Counts() []string {
	actionsCovered, writes, parity := 0, 0, 0
	for _, action := range r.Surface.Actions {
		if r.cover.Dispatches(action.Name) {
			actionsCovered++
		}
		if action.ReadOnly {
			continue
		}
		writes++
		if r.cover.HasParity(action.Name) {
			parity++
		}
	}
	controls := uniqueNames(r.Surface.Identifiers)
	controlsCovered := 0
	for _, name := range controls {
		if r.cover.Exercises(name) {
			controlsCovered++
		}
	}
	return []string{
		fmt.Sprintf("actions:  %d of %d dispatched by a check", actionsCovered, len(r.Surface.Actions)),
		fmt.Sprintf("writes:   %d of %d carry a parity check", parity, writes),
		fmt.Sprintf("controls: %d of %d exercised by a check", controlsCovered, len(controls)),
	}
}

// NewSurfaceCount describes what this branch added, for the line a passing run
// prints. A gate that passed silently would be indistinguishable from a gate
// that never looked.
func (r CoverageReport) NewSurfaceCount() string {
	return fmt.Sprintf("%d action(s) and %d control(s) are new on this branch",
		len(r.New.Actions), len(uniqueNames(r.New.Identifiers)))
}

// Err is the gate's verdict.
//
// **A dead exemption fails it, exactly as an uncovered new control does.** An
// entry outlives the gap it was written for, nothing ever prompts anyone to
// delete it, and a file of redirects that no longer redirect anything is how a
// list of things nobody checks gets built one honest line at a time. This is
// the rule a stale quarantine entry is already held to.
func (r CoverageReport) Err() error {
	if len(r.Stale) > 0 {
		return fmt.Errorf(
			"%s excuses surface that is not uncovered: %s — a check now reaches it, or it "+
				"is gone. Delete the line.",
			ExemptionFile, strings.Join(r.Stale, ", "))
	}
	if len(r.Gaps) == 0 {
		return nil
	}
	lines := make([]string, 0, len(r.Gaps))
	for _, gap := range r.Gaps {
		lines = append(lines, gap.String())
	}
	return fmt.Errorf(
		"%d piece(s) of newly added surface have no check:\n  %s\n"+
			"Write the checks, or — if none can reach it — add a line to %s saying why.",
		len(r.Gaps), joinLines(lines), ExemptionFile)
}

func uniqueNames(identifiers []Identifier) []string {
	seen := map[string]bool{}
	for _, identifier := range identifiers {
		seen[identifier.Name] = true
	}
	return slices.Sorted(maps.Keys(seen))
}
