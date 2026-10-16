package driver

import "testing"

// Real `ps -Ewww -p <pid>` output, trimmed. The environment follows the
// command, which is why a naive "first match wins" is wrong: a bundle
// launched through `env HOME=… ` carries the assignment in the command line
// too, and it is the environment copy that says what the process actually got.
const psSample = `  PID STAT      TIME COMM
49915 S      0:03.21 /Users/operator/orca/workspaces/wakil/provider-settings/app/Wakil.app/Contents/MacOS/Wakil HOME=/fixture/home4 PATH=/fixture/bin:/usr/bin:/bin TMPDIR=/fixture/tmp4 LANG=en_US.UTF-8`

func TestEnvFromPSExtractsRequestedKeys(t *testing.T) {
	got := EnvFromPS(psSample, "HOME", "PATH")
	if got["HOME"] != "/fixture/home4" {
		t.Fatalf("HOME = %q", got["HOME"])
	}
	if got["PATH"] != "/fixture/bin:/usr/bin:/bin" {
		t.Fatalf("PATH = %q", got["PATH"])
	}
}

func TestEnvFromPSReturnsOnlyWhatWasAsked(t *testing.T) {
	got := EnvFromPS(psSample, "HOME")
	if _, present := got["TMPDIR"]; present {
		t.Fatal("TMPDIR was not requested and must not be returned")
	}
	if len(got) != 1 {
		t.Fatalf("got %d entries, want 1: %v", len(got), got)
	}
}

// Absent must be distinguishable from empty: TMPDIR is not propagated to the
// app's Go children (probe §6b), and "not set" is a different fact from
// "set to the empty string".
func TestEnvFromPSOmitsKeysThatAreNotSet(t *testing.T) {
	got := EnvFromPS(psSample, "WAKIL_ORG")
	if _, present := got["WAKIL_ORG"]; present {
		t.Fatal("a key that is not in the environment must be absent, not empty")
	}
}

// The environment copy is authoritative over an identical-looking token in
// the command line, so the last occurrence wins.
func TestEnvFromPSPrefersTheEnvironmentOverTheCommandLine(t *testing.T) {
	line := `  PID STAT TIME COMM
1 S 0:00 /usr/bin/env HOME=/from/command /bin/app HOME=/from/environment`
	if got := EnvFromPS(line, "HOME"); got["HOME"] != "/from/environment" {
		t.Fatalf("HOME = %q, want the environment copy", got["HOME"])
	}
}

func TestEnvFromPSHandlesEmptyOutput(t *testing.T) {
	if got := EnvFromPS("", "HOME"); len(got) != 0 {
		t.Fatalf("want no entries for empty output, got %v", got)
	}
}
