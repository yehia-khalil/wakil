package driver

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// **LaunchdPATH is what a bundled app actually gets, and the harness must not
// improve on it.** `launchctl getenv PATH` is empty on this machine, so an app
// started from Finder inherits the system default; the operator's Wakil, started
// from a terminal, carries their whole interactive PATH. Launching the fixture
// with the harness's own PATH would hand the app a richer environment than the
// shipped one, and 2c-iii's check 1 — the one check in that runbook catching a
// class no test can see — would pass without testing anything.
func TestLaunchdPATHIsTheSystemDefaultAndNotTheOperators(t *testing.T) {
	if LaunchdPATH != "/usr/bin:/bin:/usr/sbin:/sbin" {
		t.Fatalf("got %q", LaunchdPATH)
	}
	if strings.Contains(LaunchdPATH, "homebrew") || strings.Contains(LaunchdPATH, "/Users/") {
		t.Fatalf("a bundled app inherits none of this: %q", LaunchdPATH)
	}
}

// The profile puts a directory on PATH that the app's own environment does
// not have, and a marker binary in it.
//
// **A seeded profile rather than the operator's `brew`.** 2c-iii's runbook
// says to substitute "any two binaries the operator's shell profile puts on
// PATH but a bare `-i` shell would not"; seeding them makes the check
// hermetic, and it tests the same mechanism — Wakil sources the user's
// `.zprofile` by hand, because zsh reads it from WAKIL's ZDOTDIR and not the
// operator's.
func TestSeedProfilePutsAMarkerOnlyTheProfileCanFind(t *testing.T) {
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := SeedProfile(fixture)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if profile.Marker == "" || profile.SecondMarker == "" || profile.Dir == "" {
		t.Fatalf("got %+v", profile)
	}
	// **The marker directory must NOT be on the launch PATH.** If it were,
	// the shell would inherit it from the app and the check would pass
	// whether or not the profile was ever read — which is the failure mode
	// this whole check exists to catch.
	for _, assignment := range fixture.Env(LaunchdPATH, Seeded{}) {
		if strings.HasPrefix(assignment, "PATH=") && strings.Contains(assignment, profile.Dir) {
			t.Fatalf("the marker directory must not reach the app's own PATH: %s", assignment)
		}
	}
	// **Two of them**, because 2c-iii's check 1 walks two binaries and one
	// marker plus a $PATH substring is not the same claim.
	for _, name := range []string{profile.Marker, profile.SecondMarker} {
		if _, err := os.Stat(filepath.Join(profile.Dir, name)); err != nil {
			t.Fatalf("%s must exist: %v", name, err)
		}
	}
}

// **The check is only evidence if the profile is the ONLY way to reach the
// marker.** Run here rather than asserted in prose: a login zsh started with
// the launch PATH and the fixture HOME must find the marker, and the same
// shell started without reading the profile must not.
func TestSeededProfileIsWhatPutsTheMarkerOnTheShellsPATH(t *testing.T) {
	if _, err := os.Stat("/bin/zsh"); err != nil {
		t.Skip("no /bin/zsh")
	}
	fixture, err := NewFixture(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := SeedProfile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	launchPATH := ""
	for _, assignment := range fixture.Env(LaunchdPATH, Seeded{}) {
		if strings.HasPrefix(assignment, "PATH=") {
			launchPATH = strings.TrimPrefix(assignment, "PATH=")
		}
	}

	withProfile := exec.Command("/bin/zsh", "-c",
		"[ -r \"$HOME/.zprofile\" ] && source \"$HOME/.zprofile\"; command -v "+profile.Marker)
	withProfile.Env = []string{"HOME=" + fixture.Home, "PATH=" + launchPATH}
	if out, err := withProfile.Output(); err != nil || !strings.Contains(string(out), profile.Marker) {
		t.Fatalf("a shell that read the profile must find the marker (%v): %s", err, out)
	}

	without := exec.Command("/bin/zsh", "-c", "command -v "+profile.Marker)
	without.Env = []string{"HOME=" + fixture.Home, "PATH=" + launchPATH}
	if out, _ := without.Output(); strings.Contains(string(out), profile.Marker) {
		t.Fatalf("a shell that did NOT read the profile must not find the marker, got: %s", out)
	}
}
