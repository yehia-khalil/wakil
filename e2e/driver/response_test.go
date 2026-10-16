package driver

import (
	"strings"
	"testing"
)

// A real get-app-state payload, shortened. Shape taken from an executed call
// on 2026-09-23, not from documentation.
const stateJSON = `{
  "id": "20cbed73",
  "ok": true,
  "result": {
    "snapshot": {
      "elementCount": 9,
      "treeText": "App=dev.wakil.app (pid 44187)\nWindow: \"Wakil\", App: Wakil.\n\n0 standard window Wakil\n\t1 text ORGANISATION\n\t4 button\n\t5 text NO ORGANISATION IS OPEN · NOTHING BEHIND THIS PLANE\n"
    }
  }
}`

// The refusal the tool raises when an index action is not preceded by a fresh
// snapshot for that app and window. Measured; it is what makes
// "resolve immediately before each act" a constraint rather than advice.
const staleIndexJSON = `{
  "id": "4343d5b0",
  "ok": false,
  "error": {
    "code": "element_not_found",
    "message": "element indexes require a fresh get-app-state snapshot for this app/window"
  }
}`

func TestParseResponseReadsTheSnapshot(t *testing.T) {
	got, err := ParseResponse([]byte(stateJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if !got.OK {
		t.Fatal("want OK")
	}
	if got.Snapshot.ElementCount != 9 {
		t.Fatalf("ElementCount = %d, want 9", got.Snapshot.ElementCount)
	}
	if !strings.Contains(got.Snapshot.TreeText, "NOTHING BEHIND THIS PLANE") {
		t.Fatal("tree text did not survive parsing")
	}
}

// An unsuccessful call must never be mistaken for an empty-but-fine one: that
// is how a check asserts nothing and still exits 0.
func TestParseResponseSurfacesTheError(t *testing.T) {
	got, err := ParseResponse([]byte(staleIndexJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if got.OK {
		t.Fatal("want OK false")
	}
	if got.Err == nil {
		t.Fatal("want an error payload")
	}
	if got.Err.Code != "element_not_found" {
		t.Fatalf("Code = %q", got.Err.Code)
	}
	if !strings.Contains(got.Err.Error(), "fresh get-app-state") {
		t.Fatalf("Error() must carry the message, got %q", got.Err.Error())
	}
}

func TestParseResponseRejectsNonJSON(t *testing.T) {
	if _, err := ParseResponse([]byte("Unable to determine Orca.app path from symlink")); err == nil {
		t.Fatal("want an error for non-JSON output, got nil")
	}
}

// Orca prints that symlink failure on stdout with a zero exit, so an empty
// payload must be an error rather than a zero-valued success.
func TestParseResponseRejectsEmptyOutput(t *testing.T) {
	if _, err := ParseResponse(nil); err == nil {
		t.Fatal("want an error for empty output, got nil")
	}
}

func TestSnapshotContains(t *testing.T) {
	got, err := ParseResponse([]byte(stateJSON))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Snapshot.Contains("NO ORGANISATION IS OPEN") {
		t.Fatal("want the org-plane label to be found")
	}
	if got.Snapshot.Contains("Landing") {
		t.Fatal("must not find text that is not in the tree")
	}
}

// --- #251: act verification ----------------------------------------------

// The shape is read off the shipped CLI rather than documentation:
// out/cli/computer-format.js computes `result.action?.verification?.state !==
// 'verified'` and names the reason from `action.path` through
// UNVERIFIED_ACTION_REASONS { accessibility, clipboard, synthetic }.
const verifiedClickJSON = `{
  "ok": true,
  "result": {
    "action": {"path": "accessibility", "verification": {"state": "verified"}},
    "snapshot": {"elementCount": 51, "treeText": "0 standard window Wakil\n"}
  }
}`

const syntheticClickJSON = `{
  "ok": true,
  "result": {
    "action": {"path": "synthetic", "verification": {"state": "unverified", "reason": "synthetic_input"}},
    "snapshot": {"elementCount": 51, "treeText": "0 standard window Wakil\n"}
  }
}`

// Verification metadata absent altogether is the other unverified shape the
// formatter handles — `, unverified (verification metadata unavailable)`.
const noVerificationJSON = `{
  "ok": true,
  "result": {
    "action": {"path": "synthetic"},
    "snapshot": {"elementCount": 51, "treeText": "0 standard window Wakil\n"}
  }
}`

func TestParseResponseReadsAVerifiedAct(t *testing.T) {
	got, err := ParseResponse([]byte(verifiedClickJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if !got.Acted {
		t.Fatal("want Acted for a reply carrying an action")
	}
	if !got.Verified {
		t.Fatal("want Verified when the state is \"verified\"")
	}
}

func TestParseResponseReadsAnUnverifiedSyntheticAct(t *testing.T) {
	got, err := ParseResponse([]byte(syntheticClickJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if !got.Acted {
		t.Fatal("want Acted")
	}
	if got.Verified {
		t.Fatal("want Verified false for state \"unverified\"")
	}
	if got.ActPath != "synthetic" {
		t.Fatalf("ActPath = %q, want \"synthetic\"", got.ActPath)
	}
}

// Absent metadata must never read as verified. Orca's own formatter treats
// anything that is not exactly "verified" as unverified, and a lenient parse
// here would let an act that Orca declined to confirm pass as confirmed.
func TestParseResponseTreatsAbsentVerificationAsUnverified(t *testing.T) {
	got, err := ParseResponse([]byte(noVerificationJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if got.Verified {
		t.Fatal("absent verification metadata must not read as verified")
	}
}

// A read carries no action, and must not be mistaken for an unverified act —
// otherwise every observation would look like a failed click.
func TestParseResponseMarksAReadAsNoAct(t *testing.T) {
	got, err := ParseResponse([]byte(stateJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if got.Acted {
		t.Fatal("a get-app-state reply carries no action and must not read as one")
	}
}

func TestUnverifiedReasonPrefersOrcasOwnWord(t *testing.T) {
	// Measured from a live coordinate click: the verification block carries
	// reason "synthetic_input", which Orca itself prints with the underscore
	// replaced by a space.
	if got := UnverifiedReason("synthetic", "synthetic_input"); got != "synthetic input" {
		t.Fatalf("got %q, want Orca's own word", got)
	}
}

func TestUnverifiedReasonFallsBackToThePathTable(t *testing.T) {
	if got := UnverifiedReason("synthetic", ""); got != "synthetic input" {
		t.Fatalf("got %q", got)
	}
	if got := UnverifiedReason("", ""); got == "" {
		t.Fatal("an unnamed path must still produce a reason")
	}
}

// A reply carrying the verification block must surface its reason, or the
// fallback table silently stands in for words the tool actually gave.
func TestParseResponseCarriesOrcasVerificationReason(t *testing.T) {
	got, err := ParseResponse([]byte(syntheticClickJSON))
	if err != nil {
		t.Fatalf("ParseResponse: %v", err)
	}
	if got.ActReason != "synthetic_input" {
		t.Fatalf("ActReason = %q", got.ActReason)
	}
}
