package scripts

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/yehia-khalil/wakil/e2e/driver"
)

// make-app-bundle.sh is the third non-Go artefact this package covers (see
// the package doc, and makefile_test.go for the second).
//
// WHAT IS ACTUALLY AT STAKE. WakilWiring.binaryURL, in the Swift app,
// resolves a bundled Go binary at <executable dir>/../Resources/<name> and
// has no fallback when it is running from a bundle — its checkout-marker
// walk stops at the first ancestor holding a go.mod or an app/Package.swift,
// and an installed Wakil.app has neither. So the layout this script produces
// is not a convention; it is the whole of the app's ability to find
// wakil-ctx and wakil-db once it is out of a checkout. AppWiringTests pins
// the resolution side in Swift. These tests pin this side.
//
// SAFETY AND SPEED. Not one test here runs the real `swift` toolchain or
// touches the real checkout. Each run gets a temp directory holding a
// skeleton of the repository (the script, a stand-in SwiftPM product, seven
// stand-in Go binaries) and a PATH whose first entry holds a fake `swift`
// that exits 0 without building anything. The script cd's to its own
// parent's parent, so a copy of it placed in <temp>/scripts operates
// entirely inside <temp>.

// bundledServers is the list the script copies into Contents/Resources.
// `wakil` is intentionally absent — it is the operator CLI, not an MCP
// server, and nothing in the app spawns it (the same line
// register-provider.sh draws; see providerServers).
var bundledServers = []string{"wakil-ctx", "wakil-db", "wakil-git", "wakil-http", "wakil-pm", "wakil-recall", "wakil-files", "wakil-connect"}

// bundledBinaries is everything Contents/Resources must hold: the MCP servers,
// and the operator CLI the window runs `provider credentials` through.
var bundledBinaries = append(append([]string{}, bundledServers...), "wakil")

// bundleTree builds the temp skeleton and returns its root.
func bundleTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	source, err := os.ReadFile(filepath.Join(repoRoot(t), "scripts", "make-app-bundle.sh"))
	if err != nil {
		t.Fatalf("read make-app-bundle.sh: %v", err)
	}
	mkdir(t, filepath.Join(root, "scripts"))
	writeExecutable(t, filepath.Join(root, "scripts", "make-app-bundle.sh"), string(source))

	// The SwiftPM product the script copies to Contents/MacOS/Wakil. In the
	// real checkout app/.build/debug is a symlink to
	// app/.build/arm64-apple-macosx/debug; it is reproduced here as a
	// symlink too, because `cp` following it is exactly the property the
	// script relies on to name a path with no architecture in it.
	mkdir(t, filepath.Join(root, "app", ".build", "arm64-apple-macosx", "debug"))
	writeExecutable(t,
		filepath.Join(root, "app", ".build", "arm64-apple-macosx", "debug", "WakilApp"),
		"#!/bin/sh\necho fake-WakilApp\n")
	if err := os.Symlink("arm64-apple-macosx/debug", filepath.Join(root, "app", ".build", "debug")); err != nil {
		t.Fatalf("symlink .build/debug: %v", err)
	}

	// The SwiftPM-generated resource bundle carrying default.metallib
	// (2b-ii Task 2). Stands in for the real Wakil_WakilApp.bundle SwiftPM
	// produces next to the WakilApp product; a single file inside it is
	// enough to exercise the copy.
	mkdir(t, filepath.Join(root, "app", ".build", "arm64-apple-macosx", "debug", "Wakil_WakilApp.bundle"))
	if err := os.WriteFile(
		filepath.Join(root, "app", ".build", "arm64-apple-macosx", "debug", "Wakil_WakilApp.bundle", "default.metallib"),
		[]byte("fake-metallib"), 0o644,
	); err != nil {
		t.Fatalf("write fake default.metallib: %v", err)
	}

	mkdir(t, filepath.Join(root, "bin"))
	for _, name := range append(bundledServers, "wakil") {
		writeExecutable(t, filepath.Join(root, "bin", name), "#!/bin/sh\necho "+name+"\n")
	}
	return root
}

// runBundleScript runs the copied script inside root with a fake `swift`
// first on PATH, and returns its combined output and error.
func runBundleScript(t *testing.T, root string, args ...string) (string, error) {
	t.Helper()
	fakeBin := t.TempDir()
	// Records that it was called, so a test can tell "the script built the
	// product" from "the product happened to be there".
	writeExecutable(t, filepath.Join(fakeBin, "swift"),
		"#!/bin/sh\nprintf '%s\\n' \"$*\" >> \""+filepath.Join(fakeBin, "swift.log")+"\"\nexit 0\n")

	cmd := exec.Command("bash", append([]string{filepath.Join(root, "scripts", "make-app-bundle.sh")}, args...)...)
	cmd.Env = append(os.Environ(), "PATH="+fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestBundlePutsEveryGoBinaryInContentsResources(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}

	entries, err := os.ReadDir(filepath.Join(root, "app", "Wakil.app", "Contents", "Resources"))
	if err != nil {
		t.Fatalf("read Contents/Resources: %v", err)
	}
	var got []string
	for _, entry := range entries {
		got = append(got, entry.Name())
	}
	sort.Strings(got)
	want := append([]string(nil), bundledBinaries...)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("Contents/Resources holds %v, want %v — WakilWiring.binaryURL looks nowhere else once the app is bundled", got, want)
	}
}

// The operator CLI IS spawned by the app, and this test used to pin the
// opposite.
//
// `WindowSession` resolves `wakil` through `WakilWiring.binaryURL` and runs
// `wakil provider credentials` for every harness it builds. Without it in
// Contents/Resources a bundle outside this checkout opens every window with
// "no agent session: wakil binary not found" — which is what the e2e harness
// saw the first time a check drove the agent against a staged bundle, and
// what a checkout's own `app/Wakil.app` hides by resolving bin/wakil through
// the fallback below Resources.
func TestBundleShipsTheOperatorCLIBecauseTheWindowRunsIt(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(root, "app", "Wakil.app", "Contents", "Resources", "wakil")); err != nil {
		t.Fatalf("Contents/Resources has no `wakil` (%v) — the window runs it for every "+
			"provider credentials lookup, and binaryURL looks nowhere else once the app is "+
			"out of a checkout", err)
	}
}

// Contents/MacOS/Wakil is what --mcp-shim is spawned as, per the design's
// §2.2 and the --mcp-config the window writes, so both the directory and the
// executable's NAME are part of the contract — not just "some binary is in
// the bundle".
func TestBundleInstallsTheProductAsContentsMacOSWakil(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}

	executable := filepath.Join(root, "app", "Wakil.app", "Contents", "MacOS", "Wakil")
	info, err := os.Stat(executable)
	if err != nil {
		t.Fatalf("stat Contents/MacOS/Wakil: %v", err)
	}
	if info.Mode()&0o111 == 0 {
		t.Fatalf("Contents/MacOS/Wakil is not executable (mode %v)", info.Mode())
	}
	body, err := os.ReadFile(executable)
	if err != nil {
		t.Fatalf("read Contents/MacOS/Wakil: %v", err)
	}
	// The copy came through app/.build/debug, which is a symlink: this is
	// the assertion that `cp` resolved it rather than copying the link.
	if !strings.Contains(string(body), "fake-WakilApp") {
		t.Fatalf("Contents/MacOS/Wakil is not the SwiftPM product: %q", body)
	}
}

// CFBundleExecutable must name the file that is actually in Contents/MacOS,
// or macOS refuses to launch the bundle at all.
func TestBundleInfoPlistNamesTheExecutableThatIsThere(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}

	plutil, err := exec.LookPath("plutil")
	if err != nil {
		t.Skipf("plutil is not on PATH, so the Info.plist cannot be parsed: %v", err)
	}
	plist := filepath.Join(root, "app", "Wakil.app", "Contents", "Info.plist")
	out, err := exec.Command(plutil, "-extract", "CFBundleExecutable", "raw", "-o", "-", plist).Output()
	if err != nil {
		t.Fatalf("plutil -extract CFBundleExecutable: %v", err)
	}
	name := strings.TrimSpace(string(out))
	if _, err := os.Stat(filepath.Join(root, "app", "Wakil.app", "Contents", "MacOS", name)); err != nil {
		t.Fatalf("CFBundleExecutable is %q, but Contents/MacOS/%s does not exist: %v", name, name, err)
	}
}

// A missing Go binary must fail the build rather than produce a bundle that
// looks complete. `binaryURL` has no fallback out of a bundle, so the
// alternative is an app that silently cannot reach wakil-ctx.
func TestBundleFailsWhenAGoBinaryIsMissing(t *testing.T) {
	root := bundleTree(t)
	if err := os.Remove(filepath.Join(root, "bin", "wakil-recall")); err != nil {
		t.Fatalf("remove bin/wakil-recall: %v", err)
	}

	out, err := runBundleScript(t, root)
	if err == nil {
		t.Fatalf("make-app-bundle.sh succeeded with bin/wakil-recall missing\n%s", out)
	}
}

// Bundle.module's generated accessor looks for Wakil_WakilApp.bundle at
// Bundle.main.bundleURL — the .app directory itself, not
// Contents/Resources, which is Bundle.main.resourceURL instead. Placing it
// in Contents/Resources with the Go binaries produces a bundle that looks
// complete but crashes VoidView with `Fatal error: could not load resource
// bundle` the moment it is run somewhere the SwiftPM build directory isn't
// also sitting at its original absolute path (see the script's header
// comment for how that was confirmed).
func TestBundlePutsTheResourceBundleAtTheTopLevelNotContentsResources(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}

	metallib := filepath.Join(root, "app", "Wakil.app", "Wakil_WakilApp.bundle", "default.metallib")
	if _, err := os.Stat(metallib); err != nil {
		t.Fatalf("stat %s: %v — Bundle.module looks for the resource bundle beside Contents, not inside Contents/Resources", metallib, err)
	}

	wrongPlace := filepath.Join(root, "app", "Wakil.app", "Contents", "Resources", "Wakil_WakilApp.bundle")
	if _, err := os.Stat(wrongPlace); err == nil {
		t.Fatalf("Wakil_WakilApp.bundle also (or instead) landed at %s, which Bundle.module does not look at", wrongPlace)
	}
}

// A missing resource bundle must fail the build rather than produce a
// bundle that looks complete, the same way a missing Go binary already
// does above: Bundle.module has no fallback out of a checkout, and the
// alternative is an app whose window opens with VoidView fatal-erroring
// the instant it draws.
func TestBundleFailsWhenTheResourceBundleIsMissing(t *testing.T) {
	root := bundleTree(t)
	if err := os.RemoveAll(filepath.Join(root, "app", ".build", "arm64-apple-macosx", "debug", "Wakil_WakilApp.bundle")); err != nil {
		t.Fatalf("remove Wakil_WakilApp.bundle: %v", err)
	}

	out, err := runBundleScript(t, root)
	if err == nil {
		t.Fatalf("make-app-bundle.sh succeeded with Wakil_WakilApp.bundle missing\n%s", out)
	}
}

// Re-running must replace the bundle rather than merge into it, or a binary
// deleted from the list would live on in every bundle built afterwards.
func TestBundleIsRebuiltFromScratchEachRun(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("first run: %v\n%s", err, out)
	}
	stale := filepath.Join(root, "app", "Wakil.app", "Contents", "Resources", "wakil-obsolete")
	writeExecutable(t, stale, "#!/bin/sh\n")

	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("second run: %v\n%s", err, out)
	}
	if _, err := os.Stat(stale); err == nil {
		t.Fatal("a file left by a previous build survived the rebuild")
	}
}

// The bundle this script ships is never the e2e fixture: the app opens its e2e operator channel
// (an operator-only route beside every agent socket) only under the fixture's bundle id, so a
// shipped Info.plist naming it would open that channel in the operator's own Wakil.
func TestTheShippedBundleIsNotTheE2EFixture(t *testing.T) {
	root := bundleTree(t)
	if out, err := runBundleScript(t, root); err != nil {
		t.Fatalf("make-app-bundle.sh: %v\n%s", err, out)
	}
	plutil, err := exec.LookPath("plutil")
	if err != nil {
		t.Skipf("plutil is not on PATH, so the Info.plist cannot be parsed: %v", err)
	}
	plist := filepath.Join(root, "app", "Wakil.app", "Contents", "Info.plist")
	out, err := exec.Command(plutil, "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist).Output()
	if err != nil {
		t.Fatalf("plutil -extract CFBundleIdentifier: %v", err)
	}
	id := strings.TrimSpace(string(out))
	if id == driver.E2EBundleIdentifier {
		t.Fatalf("the shipped bundle is %q, the e2e fixture's id: it would open the harness channel", id)
	}
	if id != "dev.wakil.app" {
		t.Errorf("the shipped bundle id is %q, want dev.wakil.app", id)
	}
}
