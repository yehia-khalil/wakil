package driver

import (
	"fmt"
	"strings"
)

// assertLabel reads one control's accessibility label through axresolve.
func (r *Runner) assertLabel(expect *Expect) error {
	element, _, err := r.Resolver.Resolve(r.PID, expect.Label)
	if err != nil {
		return err
	}
	return judgeLabel(expect, element.Label)
}

func judgeLabel(expect *Expect, label string) error {
	switch {
	case expect.Equals != nil && label != *expect.Equals:
		return fmt.Errorf("%s is labelled %q, want %q", expect.Label, label, *expect.Equals)
	case expect.Contains != nil && !strings.Contains(label, *expect.Contains):
		return fmt.Errorf("%s is labelled %q, which does not contain %q", expect.Label, label, *expect.Contains)
	}
	return nil
}
