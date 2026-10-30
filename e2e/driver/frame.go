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

func rectOfElement(e Element) Rect { return Rect{e.X, e.Y, e.Width, e.Height} }

// drawnRect is the element's frame, refused when it is not drawn: its zeros
// would sit "inside" nothing and "clear" of everything.
func drawnRect(e Element) (Rect, error) {
	if e.Undrawn {
		return Rect{}, fmt.Errorf("%s is in the tree but not drawn on screen, so it has no frame", e.Identifier)
	}
	return rectOfElement(e), nil
}
func rectOfWindow(w WindowFrame) Rect { return Rect{w.X, w.Y, w.Width, w.Height} }

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
