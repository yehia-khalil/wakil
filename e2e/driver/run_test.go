package driver

import (
	"strings"
	"testing"
)

func check(t *testing.T, name string, texts ...string) Check {
	t.Helper()
	var lines strings.Builder
	for _, text := range texts {
		lines.WriteString(`{"expect":{"tree":"contains","text":"` + text + `"}}` + "\n")
	}
	got, err := ParseChecks(name, []byte(lines.String()))
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestRunChecksCountsEveryAssertion(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{check(t, "org-plane", "ORGANISATION", "NOTHING BEHIND THIS PLANE")})

	if got.ChecksRun != 1 {
		t.Fatalf("ChecksRun = %d", got.ChecksRun)
	}
	if got.Assertions != 2 {
		t.Fatalf("Assertions = %d, want 2", got.Assertions)
	}
	if err := got.Err(); err != nil {
		t.Fatalf("want a pass, got %v", err)
	}
}

func TestRunChecksRecordsAMissingLabel(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)

	got := runner.Run([]Check{check(t, "landing", "THE LANDING")})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure when the label is absent")
	} else if !strings.Contains(err.Error(), "THE LANDING") || !strings.Contains(err.Error(), "landing") {
		t.Fatalf("failure must name the check and the text, got %q", err)
	}
}

// A call that could not be made is a failure, never a skipped assertion. This
// is the shape `make test-live` had to defend against: something that did not
// happen must not read as something that passed.
func TestRunChecksTreatsAnUnusableReplyAsAFailure(t *testing.T) {
	runner, _ := newRunner(t, "Unable to determine Orca.app path from symlink", nil)

	got := runner.Run([]Check{check(t, "org-plane", "ORGANISATION")})

	if err := got.Err(); err == nil {
		t.Fatal("want a failure when the reply was unusable")
	}
	if got.Assertions == 0 {
		t.Fatal("an attempted assertion still counts as attempted, or the zero-assertions guard masks the real error")
	}
}

// Orca's own refusal must surface as a named failure, not as an absent label.
func TestRunChecksSurfacesAnOrcaRefusal(t *testing.T) {
	runner, _ := newRunner(t, `{"ok":false,"error":{"code":"app_not_found","message":"app 'pid:44187' not found"}}`, nil)

	got := runner.Run([]Check{check(t, "org-plane", "ORGANISATION")})

	err := got.Err()
	if err == nil {
		t.Fatal("want a failure")
	}
	if !strings.Contains(err.Error(), "app_not_found") {
		t.Fatalf("failure must carry Orca's code, got %q", err)
	}
}

func TestRunChecksWithNoChecksIsRed(t *testing.T) {
	runner, _ := newRunner(t, stateJSON, nil)
	if err := runner.Run(nil).Err(); err == nil {
		t.Fatal("want an error when there is nothing to run")
	}
}
