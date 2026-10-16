package driver_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// **The id must not be the app's own**, and this test is the guard on a
// constant that looks like a detail and is not. Orca refuses every click on a
// second instance of a bundle id another running instance also claims, so a
// run under `dev.wakil.app` can read the window and never drive it.
func TestE2EBundleIdentifierIsNotTheAppsOwn(t *testing.T) {
	if driver.E2EBundleIdentifier == "dev.wakil.app" {
		t.Fatal("the fixture would claim the operator's bundle id and could not be clicked")
	}
	if driver.E2EBundleIdentifier == "" {
		t.Fatal("an empty bundle id is not an isolation boundary")
	}
}

func TestStageBundleGivesTheCopyItsOwnIdentity(t *testing.T) {
	source := fakeBundle(t, "dev.wakil.app")
	fixture, err := driver.NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	staged, err := driver.StageBundle(source, fixture)
	if err != nil {
		t.Fatal(err)
	}

	id, err := driver.StagedBundleIdentifier(staged)
	if err != nil {
		t.Fatal(err)
	}
	if id != driver.E2EBundleIdentifier {
		t.Errorf("the copy claims %q, want %q", id, driver.E2EBundleIdentifier)
	}

	// **The original is untouched.** It is the operator's build, often the one
	// they are about to run themselves, and a harness that edited it in place
	// would change what `make app-bundle` produced behind their back.
	original, err := driver.StagedBundleIdentifier(source)
	if err != nil {
		t.Fatal(err)
	}
	if original != "dev.wakil.app" {
		t.Errorf("the source bundle was modified: it now claims %q", original)
	}

	// The copy lives in the fixture, so teardown takes it with everything else
	// and two runs can never share one.
	if !strings.HasPrefix(staged, fixture.Root) {
		t.Errorf("staged at %q, which is outside the fixture root %q", staged, fixture.Root)
	}

	// The executable travelled. A copy that lost it would fail much later, at
	// a launch that produced no new process.
	if _, err := os.Stat(filepath.Join(staged, "Contents", "MacOS", "Wakil")); err != nil {
		t.Errorf("the staged bundle has no executable: %v", err)
	}
}

func TestStageBundleRefusesASourceThatIsNotThere(t *testing.T) {
	fixture, err := driver.NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := driver.StageBundle(filepath.Join(t.TempDir(), "Missing.app"), fixture); err == nil {
		t.Error("staged a bundle that does not exist")
	}
}

// fakeBundle writes the minimum .app shape StageBundle touches.
func fakeBundle(t *testing.T, identifier string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Wakil.app")
	if err := os.MkdirAll(filepath.Join(root, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wakil</string>
<key>CFBundleIdentifier</key><string>` + identifier + `</string>
</dict></plist>
`
	if err := os.WriteFile(filepath.Join(root, "Contents", "Info.plist"), []byte(plist), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Contents", "MacOS", "Wakil"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

// **The stub runs from the fixture, never from the checkout.** A checkout
// under ~/Desktop (or ~/Documents) is a TCC-protected folder, and the staged
// app is ad hoc signed, so every rebuild is a new identity that macOS asks
// about again: "WakilE2E would like to access files in your Desktop folder".
// Until someone answers, the window's spawn of the stub never runs, and the
// run reads as #284 (the agent was never run).
func TestStageAgentStubCopiesTheStubIntoTheFixture(t *testing.T) {
	source := filepath.Join(t.TempDir(), "wakil-e2e-agent")
	if err := os.WriteFile(source, []byte("#!/bin/sh\necho stub\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := driver.NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	staged, err := driver.StageAgentStub(source, fixture)
	if err != nil {
		t.Fatal(err)
	}

	if !strings.HasPrefix(staged, fixture.Root+string(filepath.Separator)) {
		t.Fatalf("staged stub %s is outside the fixture %s", staged, fixture.Root)
	}
	if staged == source {
		t.Fatal("the stub was not copied")
	}
	info, err := os.Stat(staged)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&0o111 == 0 {
		t.Fatalf("staged stub is not executable: %v", info.Mode())
	}
	got, _ := os.ReadFile(staged)
	if string(got) != "#!/bin/sh\necho stub\n" {
		t.Fatalf("staged stub content differs: %q", got)
	}
}

func TestStageAgentStubOfNoStubIsNoStub(t *testing.T) {
	fixture, err := driver.NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	staged, err := driver.StageAgentStub("", fixture)
	if err != nil || staged != "" {
		t.Fatalf("no stub should stage to nothing, got %q, %v", staged, err)
	}
}
