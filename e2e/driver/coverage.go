package driver

import (
	"maps"
	"regexp"
	"slices"
	"strings"
)

// Coverage is what the whole check corpus reaches: the actions it drives, the
// actions it drives down BOTH channels, and the controls it presses.
//
// **It is read off the checks and never off a run.** A check that ran and a
// check that exists are different claims, and this is deliberately the second
// one: the gate asks whether the surface a branch added is *accompanied by a
// check*, and `make e2e` asks whether that check passes. Measuring coverage
// from a run instead would make the gate green exactly when the suite was red
// and the checks never got as far as the step that touches the new surface.
type Coverage struct {
	// dispatched holds every action name a check sends over the socket.
	dispatched map[string]bool
	// parity holds the actions a check drives by clicking AND by dispatching,
	// asserting the two landed identically. It is always a subset of
	// dispatched.
	parity map[string]bool
	// exercised holds every identifier a check presses or types into. The
	// names here are always CONCRETE — a check cannot address a family — and
	// the denominator's may not be, which is what Exercises resolves.
	exercised map[string]bool
}

// CoverageOf reads the corpus.
func CoverageOf(checks []Check) Coverage {
	cover := Coverage{
		dispatched: map[string]bool{},
		parity:     map[string]bool{},
		exercised:  map[string]bool{},
	}
	for _, check := range checks {
		for _, step := range check.Steps {
			cover.add(step)
		}
	}
	return cover
}

func (c Coverage) add(step Step) {
	switch {
	case step.Do != nil:
		// The keystroke arms are aimed at whatever holds keyboard focus
		// rather than at a named control, so they exercise no identifier —
		// which is exactly why a check that uses them has to focus a pane by
		// clicking its rail row first, and that click is what lands here.
		if step.Do.Click != "" {
			c.exercised[step.Do.Click] = true
		}
		// **A focus click is a click.** It lands on that element, with a real
		// mouse event, so a gate that ignored it would ask for a second check
		// covering a control a check already presses.
		if step.Do.Focus != "" {
			c.exercised[step.Do.Focus] = true
		}
		if step.Do.Type != nil {
			c.exercised[step.Do.Type.Into] = true
		}
		// **A drag exercises both ends** (2c-iv, Ruling 10): the control it
		// picks up and the one it drops on. The drop target is resolved by
		// its identifier and receives a real drop — a check that drags onto
		// it has reached it exactly as a click reaches a button. Leaving it
		// out made every drop target a control no check could ever count.
		if step.Do.Drag != nil {
			c.exercised[step.Do.Drag.From] = true
			c.exercised[step.Do.Drag.To] = true
		}
	case step.Dispatch != nil:
		c.dispatched[step.Dispatch.Action] = true
	case step.Parity != nil:
		c.dispatched[step.Parity.Action] = true
		c.parity[step.Parity.Action] = true
		if step.Parity.Drag != nil {
			c.exercised[step.Parity.Drag.From] = true
			c.exercised[step.Parity.Drag.To] = true
		} else {
			c.exercised[step.Parity.Click] = true
		}
		// **The state read a parity step compares through is itself a
		// dispatch.** It goes over the same socket, as the same kind of call
		// an agent makes, and a report that did not say so would list
		// `read_pane` and `read_layout` — the two most-exercised tools in the
		// harness — as touched by nothing at all.
		if step.Parity.Assert == ParityReadPane || step.Parity.Assert == ParityReadLayout {
			c.dispatched[step.Parity.Assert] = true
		}
	case step.Expect != nil:
		// `expect.pane` reads through `read_pane`, for the same reason.
		// `expect.tree`, `expect.process` and `expect.journal` do not touch
		// the socket at all: they read the accessibility tree, the process
		// table and the app's own journal file.
		// ParityReadPane rather than a literal: check.go already names the
		// tool a state read goes through, and a second spelling here would be
		// a second answer to one question.
		if step.Expect.Pane != "" {
			c.dispatched[ParityReadPane] = true
		}
	}
}

// Dispatches reports whether any check drives this action over the socket.
func (c Coverage) Dispatches(action string) bool { return c.dispatched[action] }

// HasParity reports whether any check drives this action down both channels
// and asserts they landed identically.
func (c Coverage) HasParity(action string) bool { return c.parity[action] }

// Exercises reports whether any check presses or types into this identifier.
//
// **The argument may be a family and the corpus never is.** The harvester can
// only report `pane.<…>.reopen` for an identifier the source builds by
// interpolation; no check can address that, and every check addresses a
// concrete id — `pane.db-1.reopen` — that the driver resolves against the live
// tree. Compared as strings the two never meet, so every dynamic control would
// read as uncovered forever, and a gate that can never be satisfied is a gate
// that gets switched off.
func (c Coverage) Exercises(identifier string) bool {
	if c.exercised[identifier] {
		return true
	}
	if !strings.Contains(identifier, dynamicSegment) {
		return false
	}
	pattern := familyPattern(identifier)
	for name := range c.exercised {
		if pattern.MatchString(name) {
			return true
		}
	}
	return false
}

// Dispatched lists the actions the corpus drives, sorted. For the report.
func (c Coverage) Dispatched() []string { return slices.Sorted(maps.Keys(c.dispatched)) }

// Exercised lists the identifiers the corpus presses, sorted. For the report.
func (c Coverage) Exercised() []string { return slices.Sorted(maps.Keys(c.exercised)) }

// dynamicSegment is what HarvestIdentifiers leaves where a `\(...)` was.
const dynamicSegment = "<…>"

// familyPattern turns a dynamic identifier into the set of concrete names it
// stands for.
//
// **A placeholder matches within one segment and never across a dot.** It
// replaced a Swift interpolation — a pane id, a rail row's id — and those are
// one segment's worth of name by construction. Letting it cross a dot would
// make `pane.<…>` match `pane.db-1.reopen`, crediting a family with every
// control underneath it, and one check clicking one button would retire a
// whole surface from the gate.
//
// **And it matches at least one character.** `[^.]*` would let
// `rail.<…>-row` be satisfied by `rail.-row`, a name nothing renders, and
// more usefully it would let a family whose interpolation is the WHOLE
// segment match a name that simply omits it.
func familyPattern(family string) *regexp.Regexp {
	parts := strings.Split(family, dynamicSegment)
	for index, part := range parts {
		parts[index] = regexp.QuoteMeta(part)
	}
	// The pattern is built from the harvested name, whose every other
	// character is quoted, so this cannot fail to compile.
	return regexp.MustCompile("^" + strings.Join(parts, "[^.]+") + "$")
}
