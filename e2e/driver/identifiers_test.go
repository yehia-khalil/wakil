package driver_test

import (
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

func TestIdentifiersInReadsAllThreeShapes(t *testing.T) {
	source := `
            Button("Open terminal") { }
                .accessibilityIdentifier("window.openTerminal")
            Button("Reopen") { }
                .accessibilityIdentifier("pane.\(pane.id).reopen")
            quietButton("Cancel", id: "org.create.cancel") { phase = .choosing }
`
	got := names(driver.IdentifiersIn("X.swift", source))
	want := []string{"org.create.cancel", "pane.<…>.reopen", "window.openTerminal"}
	assertSameSet(t, got, want)
}

// The harvester reads literals rather than call structure, so the grammar is
// the only thing keeping ordinary strings out of the denominator. These are
// the ones that actually sit in app/Sources/WakilApp.
func TestIdentifiersInRejectsWhatIsNotAnIdentifier(t *testing.T) {
	for _, source := range []string{
		`Image(systemName: "xmark.circle")`,
		`Image(systemName: "exclamationmark.triangle")`,
		`Image(systemName: "magnifyingglass")`,
		`TextField("https://your-site.atlassian.net/browse", text: $base)`,
		`row(id: "project:\(project.name)", title: name) { }`,
		`ForEach(Pane.kinds.sorted(), id: \.self) { kind in`,
		`// .accessibilityIdentifier("window.commented")`,
		`Text("Wakil holds one organisation at a time.")`,
		// 3a-i: JavaScript built in a Swift literal, beginning with a surface.
		`source: "window.wakilProbe = true;", injectionTime: .atDocumentStart`,
		`run("window.wakilCaptureKeys = \(on)")`,
	} {
		if found := driver.IdentifiersIn("X.swift", source); len(found) != 0 {
			t.Errorf("%s\n  harvested %v, want none", source, names(found))
		}
	}
}

// An identifier whose first segment is not a registered surface is not an
// identifier. That is what makes the grammar narrow enough to read literals at
// all, and it is also how a new surface is forced to be declared deliberately.
func TestIdentifiersInRequiresARegisteredSurface(t *testing.T) {
	source := `.accessibilityIdentifier("sidebar.collapse")`
	if found := driver.IdentifiersIn("X.swift", source); len(found) != 0 {
		t.Fatalf("harvested %v from an unregistered surface, want none", names(found))
	}
	if !strings.Contains(strings.Join(driver.Surfaces, " "), "window") {
		t.Fatal("window is not a registered surface")
	}
}

func TestIdentifiersInMarksDynamicOnes(t *testing.T) {
	found := driver.IdentifiersIn("X.swift", `.accessibilityIdentifier("rail.\(pane.id)")`)
	if len(found) != 1 {
		t.Fatalf("harvested %v, want one", names(found))
	}
	if !found[0].Dynamic {
		t.Error("rail.<…> is a family, not an address, and must be marked dynamic")
	}
	if driver.IdentifiersIn("X.swift", `.accessibilityIdentifier("window.send")`)[0].Dynamic {
		t.Error("window.send carries no placeholder and must not be marked dynamic")
	}
}

func TestIdentifiersInReportsWhereItFoundOne(t *testing.T) {
	source := "one\ntwo\n.accessibilityIdentifier(\"window.send\")\n"
	found := driver.IdentifiersIn("WakilWindow.swift", source)
	if len(found) != 1 || found[0].Line != 3 || found[0].File != "WakilWindow.swift" {
		t.Fatalf("got %+v, want WakilWindow.swift:3", found)
	}
}

// **The denominator must not be zero.** Design §2: control coverage is measured
// against this set, and a harvest that returns nothing makes every later
// coverage claim vacuous rather than met — which is the whole reason the set
// exists. A refactor that moved the sources, or a grammar change that stopped
// matching, would present as a green suite and a meaningless denominator.
func TestHarvestIdentifiersFindsTheRealTree(t *testing.T) {
	found, err := driver.HarvestIdentifiers(appSources)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) == 0 {
		t.Fatal("harvested no identifiers from the app, so the control denominator is zero")
	}
	for _, want := range []string{"palette.query", "rail.<…>", "org.plane.create"} {
		if !contains(names(found), want) {
			t.Errorf("the app no longer carries %q", want)
		}
	}
}

const appSources = "../../app/Sources/WakilApp"

func names(found []driver.Identifier) []string {
	var out []string
	for _, identifier := range found {
		out = append(out, identifier.Name)
	}
	return out
}

func contains(haystack []string, needle string) bool {
	for _, value := range haystack {
		if value == needle {
			return true
		}
	}
	return false
}

func assertSameSet(t *testing.T, got, want []string) {
	t.Helper()
	for _, value := range want {
		if !contains(got, value) {
			t.Errorf("missing %q; got %v", value, got)
		}
	}
	if len(got) != len(want) {
		t.Errorf("got %v, want exactly %v", got, want)
	}
}
