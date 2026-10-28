package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSecurityRecording installs a fake `security` that appends its argv to a file and exits with
// the given status. The real /usr/bin/security is never run.
func fakeSecurityRecording(t *testing.T, status string) string {
	t.Helper()
	log := filepath.Join(t.TempDir(), "argv")
	useFakeSecurity(t, "echo \"$@\" >> '"+log+"'\nexit "+status+"\n")
	return log
}

// TestBrowserLoginsPresentReadsAttributesOnly: the check names the default identity's service and
// never asks for a value (no -w, no -g), so it raises no prompt.
func TestBrowserLoginsPresentReadsAttributesOnly(t *testing.T) {
	log := fakeSecurityRecording(t, "0")
	got, err := BrowserLoginsPresent("initech")
	if err != nil || !got {
		t.Fatalf("BrowserLoginsPresent = %v, %v; want true, nil", got, err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	argv := strings.Fields(string(data))
	for _, a := range argv {
		if a == "-w" || a == "-g" {
			t.Fatalf("argv %q holds %s, which would read a value", argv, a)
		}
	}
	joined := " " + strings.Join(argv, " ") + " "
	if !strings.Contains(joined, " find-generic-password ") || !strings.Contains(joined, " -s wakil:initech:browser-login:default ") {
		t.Fatalf("argv = %q, want find-generic-password -s wakil:initech:browser-login:default", argv)
	}
}

// TestBrowserLoginsAbsentIsNotAnError: exit 44 is the ordinary answer for no items.
func TestBrowserLoginsAbsentIsNotAnError(t *testing.T) {
	fakeSecurityRecording(t, "44")
	got, err := BrowserLoginsPresent("initech")
	if err != nil || got {
		t.Fatalf("BrowserLoginsPresent = %v, %v; want false, nil", got, err)
	}
}

// TestBrowserLoginsFailureIsAUserError: any other failure is reported, not read as absent.
func TestBrowserLoginsFailureIsAUserError(t *testing.T) {
	fakeSecurityRecording(t, "36")
	if _, err := BrowserLoginsPresent("initech"); err == nil {
		t.Fatal("exit 36 gave no error")
	}
}
