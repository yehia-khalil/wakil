package driver_test

import (
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// A modifier after a one-line control is indented deeper than it; a modifier
// after a trailing-closure control sits at the control's own depth, below the
// brace that closed it. Both are the app's own house style and the chain
// reader has to follow both.
func TestControlsInReadsBothChainShapes(t *testing.T) {
	source := `
            Button("Rerun") { send(block) }
                .accessibilityIdentifier("pane.\(paneId).block.\(block.id).rerun")
            Button {
                searchOpen.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search this pane")
            .accessibilityIdentifier("pane.\(pane.id).searchToggle")
            .buttonStyle(.plain)
`
	controls := driver.ControlsIn("X.swift", source)
	if len(controls) != 2 {
		t.Fatalf("found %d controls, want 2", len(controls))
	}
	for _, control := range controls {
		if !control.Named() {
			t.Errorf("line %d (%s): %s", control.Line, control.Kind, control.Problem)
		}
	}
}

// The next sibling's name must not be mistaken for this control's. Without
// that boundary every control in a stack would read as named as long as the
// last one was.
func TestControlsInStopsAtTheNextSibling(t *testing.T) {
	source := `
            Button("Open pane") { }
            Button("Open terminal") { }
                .accessibilityIdentifier("window.openTerminal")
`
	controls := driver.ControlsIn("X.swift", source)
	if len(controls) != 2 {
		t.Fatalf("found %d controls, want 2", len(controls))
	}
	if controls[0].Named() {
		t.Error("the first Button borrowed the second's identifier")
	}
	if !controls[1].Named() {
		t.Errorf("the second Button is named and did not read as named: %s", controls[1].Problem)
	}
}

// A helper that takes the name as a required argument — `OrgPlane`'s
// `button(_:id:)`, `ActionRow(identifier:)` — applies the modifier with a
// VARIABLE. The control is the Button inside the helper, and it is named:
// a caller that omits the argument does not compile.
//
// The call sites themselves are not controls at all. `quietButton(` does not
// match `\bButton\s*[({]`, because the character before "Button" is a word
// character. An earlier version of this test asserted over those call sites
// and passed by iterating an empty slice — which is the exact shape of failure
// this whole harness exists to prevent, found in its own test.
func TestControlsInAcceptsANameSuppliedByTheCaller(t *testing.T) {
	helper := `
        Button(title, action: action)
            .accessibilityIdentifier(id)
            .buttonStyle(.plain)
`
	controls := driver.ControlsIn("OrgPlane.swift", helper)
	if len(controls) != 1 {
		t.Fatalf("found %d controls, want 1", len(controls))
	}
	if !controls[0].Named() {
		t.Errorf("a control named by its caller failed the gate: %s", controls[0].Problem)
	}
	if controls[0].Identifier != "" {
		t.Errorf("got identifier %q; the name is the caller's, not this line's",
			controls[0].Identifier)
	}

	callSite := `                    quietButton("Cancel", id: "org.create.cancel") { phase = .choosing }`
	if found := driver.ControlsIn("OrgPlane.swift", callSite); len(found) != 0 {
		t.Errorf("a helper call site read as %d control(s), want 0", len(found))
	}
}

// **A name the gate accepts and the harvester does not is worse than no name.**
// The control would read as covered and be missing from the denominator, so the
// coverage figure would be wrong in the flattering direction with nothing
// saying so. Both sides share one grammar for exactly this reason.
func TestControlsInRejectsANameTheHarvesterWouldNotCount(t *testing.T) {
	source := `
            Button("Collapse") { }
                .accessibilityIdentifier("sidebar.collapse")
`
	controls := driver.ControlsIn("X.swift", source)
	if len(controls) != 1 {
		t.Fatalf("found %d controls, want 1", len(controls))
	}
	if controls[0].Named() {
		t.Fatal("an unregistered surface passed the gate")
	}
	if !strings.Contains(controls[0].Problem, "registered surface") {
		t.Errorf("the refusal does not say why: %q", controls[0].Problem)
	}
	if len(driver.IdentifiersIn("X.swift", source)) != 0 {
		t.Error("the harvester counted what the gate refused")
	}
}

func TestControlsInExcusesWhatCannotBeAddressed(t *testing.T) {
	hidden := `
            Button("") { model.showOrgPlane = false }
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
`
	if excuse := driver.ControlsIn("X.swift", hidden)[0].Excused; excuse == "" {
		t.Error("a control hidden from accessibility still demanded a name")
	}

	menu := `
        .contextMenu {
            Button("Accept (⏎)", action: accept)
            Button("Discard (⌫)", action: discard)
        }
`
	controls := driver.ControlsIn("X.swift", menu)
	if len(controls) != 2 {
		t.Fatalf("found %d controls, want 2", len(controls))
	}
	for _, control := range controls {
		if control.Excused == "" {
			t.Errorf("line %d: a menu's buttons are not in the tree until it opens", control.Line)
		}
	}
}

// A tappable VStack is a control to a mouse and to nothing else — which is
// what the landing rows were. A gate that only looked at `Button` would have
// called that surface covered.
func TestControlsInCountsATapGesture(t *testing.T) {
	source := "            .contentShape(Rectangle())\n            .onTapGesture(perform: action)\n"
	controls := driver.ControlsIn("X.swift", source)
	if len(controls) != 1 || controls[0].Kind != ".onTapGesture" {
		t.Fatalf("got %+v, want one .onTapGesture", controls)
	}
	if controls[0].Named() {
		t.Error("an unnamed tap gesture read as named")
	}
}

// **A gate over zero controls passes and proves nothing.** This is the
// `test-live` failure in the gate's own shape: `go test` reports a skip as ok,
// and a scope list that no longer resolves would make every run green while
// auditing nothing at all.
func TestAuditControlsActuallyFindsControls(t *testing.T) {
	controls, err := driver.AuditControls(appSources)
	if err != nil {
		t.Fatal(err)
	}
	if len(controls) == 0 {
		t.Fatal("audited no controls at all, so the gate would pass on an empty set")
	}
	if len(driver.AuditedSources) == 0 {
		t.Fatal("no sources are audited")
	}
}

// The gate's verdict on the tree as it stands. It is not a tautology: removing
// `rail.<…>` from Rail.swift makes it name `.onTapGesture Rail.swift:218`.
func TestEveryAuditedControlIsNamed(t *testing.T) {
	controls, err := driver.AuditControls(appSources)
	if err != nil {
		t.Fatal(err)
	}
	for _, control := range driver.GateFailures(controls) {
		t.Errorf("%s:%d: %s: %s", control.File, control.Line, control.Kind, control.Problem)
	}
}

// TestLeakyHelpersFindsTheHoleThisGateCannotSee is the defect verbatim, from
// SettingsPane.swift. The helper's DEFINITION satisfies every other rule here
// — it is a real `Button` and it applies an identifier — so the gate called it
// named. Four call sites took the empty default and shipped
// `.accessibilityIdentifier("")`, and `make controls` reported "54 actionable
// control(s), all named" throughout.
func TestLeakyHelpersFindsTheHoleThisGateCannotSee(t *testing.T) {
	source := `
    private func confirmButton(
        _ title: String, tone: Color, filled: Bool = false, identifier: String = "",
        _ act: @escaping () -> Void
    ) -> some View {
        Button(title, action: act)
            .accessibilityIdentifier(identifier)
    }
`
	leaks := driver.LeakyHelpers("SettingsPane.swift", source)

	if len(leaks) != 1 {
		t.Fatalf("leaks = %+v; want the one defaulted identifier parameter", leaks)
	}
	if !strings.Contains(leaks[0].Problem, "identifier") {
		t.Errorf("the failure must name the parameter: %q", leaks[0].Problem)
	}
	// It has to fail the gate, not merely be listed.
	if len(driver.GateFailures(leaks)) != 1 {
		t.Error("a leaky helper must fail the gate")
	}
}

// TestLeakyHelpersAllowsAHelperThatRequiresAName. Naming a control through a
// parameter is good design and half this codebase does it — `door` and
// `rowAction` both do. The rule is the DEFAULT, not the parameter: without one
// the compiler already enforces what this gate cannot see, which is the actual
// fix rather than a workaround for it.
func TestLeakyHelpersAllowsAHelperThatRequiresAName(t *testing.T) {
	source := `
    private func door(
        _ title: String, note: String, open: Bool, identifier: String,
        _ act: @escaping () -> Void
    ) -> some View {
        Button(title, action: act)
            .accessibilityIdentifier(identifier)
    }
`
	if leaks := driver.LeakyHelpers("SettingsPane.swift", source); len(leaks) != 0 {
		t.Errorf("a helper with a required identifier is not a leak: %+v", leaks)
	}
}

// TestLeakyHelpersIgnoresADefaultOnSomethingThatIsNotAnIdentifier. A defaulted
// `String` is ordinary; only one that the file goes on to apply as an
// accessibility identifier can leave a control unnamed.
func TestLeakyHelpersIgnoresADefaultOnSomethingThatIsNotAnIdentifier(t *testing.T) {
	source := `
    private func note(_ text: String, tone: Color, prefix: String = "") -> some View {
        Button(text) { }
            .accessibilityIdentifier(identifier)
    }
`
	if leaks := driver.LeakyHelpers("SettingsPane.swift", source); len(leaks) != 0 {
		t.Errorf("a defaulted String that is never applied as an identifier is not a leak: %+v", leaks)
	}
}

// TestLeakyHelpersSaysNothingAboutAFileThatNamesNothingThroughAParameter —
// most sources apply string literals, and the rule must be silent there.
func TestLeakyHelpersSaysNothingAboutAFileThatNamesNothingThroughAParameter(t *testing.T) {
	source := `
        Button("Reload") { reload() }
            .accessibilityIdentifier("settings.reload")
        func helper(label: String = "") -> String { label }
`
	if leaks := driver.LeakyHelpers("Landing.swift", source); len(leaks) != 0 {
		t.Errorf("no parameter is applied as an identifier here: %+v", leaks)
	}
}

// TestLeakyHelpersIgnoresACommentThatQuotesTheShapeItForbids. Found by the
// 2c-iv session in its own line-scanning gate on the same day: a widened
// pattern matched the doc comments that QUOTE the forbidden shape, so the gate
// went red on prose. This gate shipped with the same hole. The false positive
// it produces is the most discouraging kind — the build fails on the paragraph
// explaining the rule.
func TestLeakyHelpersIgnoresACommentThatQuotesTheShapeItForbids(t *testing.T) {
	source := `
    /// The hole this guards. ` + "`confirmButton`" + ` once declared
    /// identifier: String = "" and four call sites took the default, so they
    /// shipped .accessibilityIdentifier(identifier) with nothing in it.
    private func confirmButton(_ title: String, identifier: String) -> some View {
        Button(title) { }
            .accessibilityIdentifier(identifier)
    }
`
	if leaks := driver.LeakyHelpers("SettingsPane.swift", source); len(leaks) != 0 {
		t.Errorf("a comment quoting the forbidden shape is not a leak: %+v", leaks)
	}
}
