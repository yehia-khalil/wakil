package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Control is one actionable control in the app's source.
type Control struct {
	Kind string // "Button", "TextField", ".onTapGesture", …
	File string
	Line int
	// Identifier is the name the chain applies, when it applies a literal
	// one. It is empty when the chain names the control through a variable —
	// `OrgPlane.button(_:id:)` applies `.accessibilityIdentifier(id)` and its
	// callers supply the literal — which is named, and not named HERE.
	Identifier string
	// Excused names why the gate does not require a name here, or is empty.
	Excused string
	// Problem is why this control fails the gate, or is empty.
	Problem string
}

// Named reports whether the control's modifier chain applies an identifier at
// all, whatever the name turned out to be.
func (c Control) Named() bool { return c.Problem == "" && c.Excused == "" }

// controlKinds are the constructors that put an actionable element in the
// accessibility tree.
//
// `.onTapGesture` is in the list and is not a constructor: a tappable `VStack`
// is a control to a mouse and to nothing else, which is exactly the defect the
// landing rows carried — two loose `Text`s, no trait, no activation, no name.
// A gate that only looked at `Button` would have declared that surface covered.
var controlKinds = []*regexp.Regexp{
	regexp.MustCompile(`\bButton\s*[({]`),
	regexp.MustCompile(`\bTextField\s*\(`),
	regexp.MustCompile(`\bSecureField\s*\(`),
	regexp.MustCompile(`\bToggle\s*\(`),
	regexp.MustCompile(`\bPicker\s*\(`),
	regexp.MustCompile(`\bStepper\s*\(`),
	regexp.MustCompile(`\bSlider\s*\(`),
	regexp.MustCompile(`\bDatePicker\s*\(`),
	regexp.MustCompile(`\bColorPicker\s*\(`),
	regexp.MustCompile(`\bMenu\s*[({]`),
	regexp.MustCompile(`\.onTapGesture\b`),
}

// AuditControls returns every actionable control in the audited sources, each
// marked named, excused, or neither.
//
// The third case is the gate: an actionable control that is neither named nor
// excused fails it, and `UnnamedControls` names the file and line.
func AuditControls(root string) ([]Control, error) {
	var controls []Control
	for _, name := range AuditedSources {
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			return nil, fmt.Errorf("auditing controls: %w", err)
		}
		controls = append(controls, ControlsIn(name, string(data))...)
		// Not a control, and reported through the same channel on purpose:
		// it is a hole in what "all named" is allowed to mean, and it fails
		// the same gate.
		controls = append(controls, LeakyHelpers(name, string(data))...)
	}
	return controls, nil
}

// GateFailures is the gate's verdict: the controls that fail it, each
// carrying the reason in Problem.
func GateFailures(controls []Control) []Control {
	var failures []Control
	for _, control := range controls {
		if control.Problem != "" && control.Excused == "" {
			failures = append(failures, control)
		}
	}
	return failures
}

// ControlsIn finds one file's controls and reads each one's modifier chain.
func ControlsIn(file, source string) []Control {
	lines := strings.Split(source, "\n")
	menuDepth := contextMenuRegions(lines)
	var controls []Control
	for index, line := range lines {
		kind := controlKind(line)
		if kind == "" {
			continue
		}
		control := Control{Kind: kind, File: file, Line: index + 1}
		if menuDepth[index] {
			// A menu's buttons do not exist in the accessibility tree until
			// the menu is open, and a check cannot address one that is not
			// there. `ProposalRow`'s Accept/Discard are the specimen: the
			// pointer path to two calls whose real path is `⏎` and `⌫`,
			// which is what a check drives.
			control.Excused = "inside a menu"
			controls = append(controls, control)
			continue
		}
		chain := modifierChain(lines, index)
		if strings.Contains(strings.Join(chain, "\n"), ".accessibilityHidden(true)") {
			// Deliberately not in the tree. `OrgPlane`'s zero-size Escape
			// button is the specimen — rendered rather than `.hidden()` so it
			// stays in the window's key-equivalent search, and hidden from
			// accessibility because it draws nothing.
			control.Excused = "accessibilityHidden(true)"
			controls = append(controls, control)
			continue
		}
		control.Identifier, control.Problem = chainIdentifier(chain)
		controls = append(controls, control)
	}
	return controls
}

// applied finds a `.accessibilityIdentifier(` and returns what follows it on
// the same line.
var applied = regexp.MustCompile(`\.accessibilityIdentifier\(\s*(.*)$`)

// chainIdentifier reads the name a chain applies, and says what is wrong when
// it cannot be used.
//
// **Three outcomes, and the third is the one worth having.**
//
// A chain that applies no identifier fails, for the obvious reason.
//
// A chain that applies a LITERAL must apply one the harvester will also find —
// the same grammar, the same registered surfaces. A name the gate accepts and
// the denominator does not is worse than no name at all: the control reads as
// covered and is absent from the count, so the coverage figure is wrong in the
// flattering direction and nothing says so.
//
// A chain that applies a VARIABLE passes. `OrgPlane.button(_:id:)` and
// `ActionRow(identifier:)` take the name as a REQUIRED argument, so a call
// that omits one does not compile — a stronger guarantee than reading source
// can give — and the literal each caller passes is harvested at the call site,
// which is also where it belongs, because one helper draws four different
// "Cancel" buttons.
func chainIdentifier(chain []string) (identifier, problem string) {
	for _, line := range chain {
		match := applied.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		rest := strings.TrimSpace(match[1])
		if !strings.HasPrefix(rest, `"`) {
			return "", ""
		}
		quoted := identifierLiteral.FindString(rest)
		if quoted == "" {
			return "", "the identifier argument is not a readable string literal"
		}
		name, ok := identifierName(quoted)
		if !ok {
			return "", fmt.Sprintf(
				"%s is not in a registered surface (%s), so the harvester will not count it",
				quoted, strings.Join(Surfaces, ", "))
		}
		return name, ""
	}
	return "", "no accessibility identifier"
}

func controlKind(line string) string {
	trimmed := strings.TrimSpace(line)
	if strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "///") {
		return ""
	}
	for _, pattern := range controlKinds {
		if match := pattern.FindString(line); match != "" {
			return strings.TrimRight(strings.TrimSpace(match), "({")
		}
	}
	return ""
}

// modifierChain returns the lines belonging to the control opened at start.
//
// **Indentation, because SwiftUI writes chains two different ways.** A modifier
// after a one-line control is indented deeper than it:
//
//	Button("Rerun") { send(…) }
//	    .accessibilityIdentifier("pane.…")
//
// while a modifier after a trailing-closure control sits at the SAME depth,
// below the brace that closed it:
//
//	Button {
//	    …
//	} label: {
//	    …
//	}
//	.accessibilityIdentifier("pane.…")
//
// So the chain runs while a line is deeper than the control, and continues
// across lines at the control's own depth for as long as they are closers or
// modifiers. The first line at the control's depth that is neither ends it —
// that is the next sibling view.
func modifierChain(lines []string, start int) []string {
	base := indentOf(lines[start])
	chain := []string{lines[start]}
	for i := start + 1; i < len(lines); i++ {
		line := lines[i]
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			chain = append(chain, line)
			continue
		}
		depth := indentOf(line)
		if depth > base {
			chain = append(chain, line)
			continue
		}
		if depth == base && (strings.HasPrefix(trimmed, ".") ||
			strings.HasPrefix(trimmed, "}") || strings.HasPrefix(trimmed, ")") ||
			strings.HasPrefix(trimmed, "//")) {
			chain = append(chain, line)
			continue
		}
		break
	}
	return chain
}

func indentOf(line string) int {
	return len(line) - len(strings.TrimLeft(line, " \t"))
}

// contextMenuRegions marks the lines inside a `.contextMenu {` or `Menu {`
// body, by brace depth from the opening line.
func contextMenuRegions(lines []string) map[int]bool {
	inside := map[int]bool{}
	openers := regexp.MustCompile(`\.contextMenu\s*\{|\.menu\s*\{|\bMenu\s*\{`)
	for index, line := range lines {
		if !openers.MatchString(line) {
			continue
		}
		depth := 0
		for i := index; i < len(lines); i++ {
			for _, r := range lines[i] {
				if r == '{' {
					depth++
				} else if r == '}' {
					depth--
				}
			}
			if i > index {
				inside[i] = true
			}
			if depth <= 0 {
				break
			}
		}
	}
	return inside
}

// identifierApplied finds `.accessibilityIdentifier(name)` where the argument
// is a bare parameter rather than a literal — the shape a wrapper helper uses.
var identifierApplied = regexp.MustCompile(
	`\.accessibilityIdentifier\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)`)

// defaultedParameter matches a parameter declared with a default value.
var defaultedParameter = regexp.MustCompile(
	`\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\s*=`)

// isComment reports whether a line is Swift comment text.
//
// **Every line-scanning gate needs this and this one shipped without it.**
// Found by the 2c-iv session in ITS gate, on the same day: a widened pattern
// matched the doc comments that QUOTE the shape it forbids, so the gate went
// red on prose. Here the failure would be the same — a comment explaining
// `identifier: String = ""` would fail the build on an explanation of the
// rule, which is the most discouraging possible false positive.
//
// Line-level only, and deliberately: a `/* */` block spanning lines is not
// used in these sources, and a scanner that tried to track block state would
// be a parser pretending to be a grep.
func isComment(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "*")
}

// LeakyHelpers finds helpers that name a control through a parameter which has
// a DEFAULT — the one shape this gate is structurally blind to.
//
// **The gate scans for control constructors, so a helper is named once and its
// call sites are invisible.** `confirmButton` and `plainField` each apply
// `.accessibilityIdentifier(identifier)` to a real `Button`/`TextField`, so
// both satisfy every rule above at their definition. Their CALL SITES are not
// controls by any pattern here and are never examined. While the parameter had
// `= ""`, four of them took the default and shipped as
// `.accessibilityIdentifier("")` — unnamed — and `make controls` reported "54
// actionable control(s), all named" the whole time. That is worse than a
// silent gap: it is a positive claim about surface that is not there.
//
// **The rule is the default, not the parameter.** A helper that names a
// control through a parameter is good design and half this codebase does it;
// `OrgPlane.button(_:id:)` is the specimen. What cannot be checked from here
// is a call site that DECLINED to pass one, and that is possible only when the
// parameter has a default. Remove the default and the compiler enforces what
// this gate cannot see — which is the actual fix, and why this reports rather
// than tries to follow call sites.
func LeakyHelpers(file, source string) []Control {
	lines := strings.Split(source, "\n")
	named := map[string]bool{}
	for _, line := range lines {
		if isComment(line) {
			continue
		}
		if match := identifierApplied.FindStringSubmatch(line); match != nil {
			named[match[1]] = true
		}
	}
	if len(named) == 0 {
		return nil
	}
	var leaks []Control
	for index, line := range lines {
		if isComment(line) {
			continue
		}
		match := defaultedParameter.FindStringSubmatch(line)
		if match == nil || !named[match[1]] {
			continue
		}
		leaks = append(leaks, Control{
			Kind: "helper naming a control through a defaulted parameter",
			File: file, Line: index + 1,
			Problem: fmt.Sprintf(
				"%q has a default, so a call site may omit it and ship an unnamed control that "+
					"this gate cannot see — it audits control constructors, and a call site of a "+
					"helper is not one. Drop the default so the compiler requires a name",
				match[1]),
		})
	}
	return leaks
}
