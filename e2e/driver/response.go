package driver

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// Response is one `orca computer ... --json` reply.
type Response struct {
	OK       bool
	Err      *OrcaError
	Snapshot Snapshot
	// Acted reports whether this reply describes an act. A read carries no
	// action, and must not be mistaken for an unconfirmed one.
	Acted bool
	// Verified reports whether Orca confirmed the act landed.
	Verified bool
	// ActPath is how the act was delivered — "accessibility", "clipboard" or
	// "synthetic".
	ActPath string
	// ActReason is Orca's OWN word for why an act could not be confirmed,
	// when it gave one. Measured: a coordinate click returns
	// `verification: {reason: "synthetic_input", state: "unverified"}`.
	ActReason string
	// ScreenshotPath is where Orca wrote the capture, and ScreenshotState is
	// what it says became of it ("captured", "failed", ...).
	//
	// **Under `--json` the image is a file, not the payload.** Orca's
	// `prepareComputerCliJsonResult` writes a non-empty `screenshot.data` out
	// to a temporary file, replaces `data` with `path`, and sets
	// `dataOmitted`. The file carries a TTL, so anything that wants to keep a
	// capture must copy it rather than reference it.
	ScreenshotPath  string
	ScreenshotState string
	// Frontmost is what the window server believed at the moment of the act,
	// when the act went through the resolver. Nil for a read, for an act
	// Orca delivered, and for a refusal — nothing was done, so there is no
	// moment to describe. See Frontmost.
	Frontmost *Frontmost
}

// OrcaError is the error payload of a failed call.
type OrcaError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *OrcaError) Error() string {
	if e == nil {
		return ""
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// Snapshot is the accessibility state the call observed.
//
// The tree answers *is it present, is it labelled, is it selected*; what a
// pane **contains** is `read_pane`'s question, not this one. A data-surface
// row is one element labelled "id: 1, name: widgets" and its cells are
// deliberately hidden from the tree
// (DataSurface.swift:662, `.accessibilityElement(children: .ignore)`), so a
// check asserting on a particular cell cannot go through here.
type Snapshot struct {
	ElementCount int    `json:"elementCount"`
	TreeText     string `json:"treeText"`
}

// Contains reports whether the tree carries this text.
func (s Snapshot) Contains(text string) bool {
	return strings.Contains(s.TreeText, text)
}

// ParseResponse decodes one --json reply.
//
// **Empty and non-JSON output are errors, never a zero-valued success.** Orca
// prints "Unable to determine Orca.app path from symlink" on stdout and exits
// zero when it cannot resolve its own bundle, so a lenient parse here would
// hand a check an empty tree that every `Contains` assertion then fails
// against — or worse, that a "must not contain" assertion passes against.
func ParseResponse(output []byte) (Response, error) {
	if len(bytes.TrimSpace(output)) == 0 {
		return Response{}, fmt.Errorf("orca produced no output")
	}
	var payload struct {
		OK     bool       `json:"ok"`
		Error  *OrcaError `json:"error"`
		Result struct {
			Snapshot         Snapshot `json:"snapshot"`
			ScreenshotStatus *struct {
				State   string `json:"state"`
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"screenshotStatus"`
			Screenshot *struct {
				Path string `json:"path"`
			} `json:"screenshot"`
			Action *struct {
				Path         string `json:"path"`
				Verification *struct {
					State  string `json:"state"`
					Reason string `json:"reason"`
				} `json:"verification"`
			} `json:"action"`
		} `json:"result"`
	}
	if err := json.Unmarshal(output, &payload); err != nil {
		return Response{}, fmt.Errorf("orca output was not JSON (%w): %s", err, firstLine(output))
	}
	if !payload.OK && payload.Error == nil {
		return Response{}, fmt.Errorf("orca reported failure with no error payload: %s", firstLine(output))
	}
	response := Response{OK: payload.OK, Err: payload.Error, Snapshot: payload.Result.Snapshot}
	if status := payload.Result.ScreenshotStatus; status != nil {
		response.ScreenshotState = status.State
	}
	if shot := payload.Result.Screenshot; shot != nil {
		response.ScreenshotPath = shot.Path
	}
	if action := payload.Result.Action; action != nil {
		response.Acted = true
		response.ActPath = action.Path
		if action.Verification != nil {
			response.Verified = action.Verification.State == VerifiedState
			response.ActReason = action.Verification.Reason
		}
	}
	return response, nil
}

// VerifiedState is the one verification state that means the act was
// confirmed. **Anything else is unverified**, which is Orca's own rule rather
// than a choice made here: its formatter computes
// `result.action?.verification?.state !== 'verified'` and prints "attempted"
// rather than "completed" for every other value, including absent metadata.
const VerifiedState = "verified"

// unverifiedReasons are Orca's own words for why an act could not be
// confirmed, keyed by the path it took. Read from out/cli/computer-format.js
// (UNVERIFIED_ACTION_REASONS), not from documentation.
var unverifiedReasons = map[string]string{
	"accessibility": "accessibility action unasserted",
	"clipboard":     "clipboard paste",
	"synthetic":     "synthetic input",
}

// UnverifiedReason names why an act could not be confirmed.
//
// **Orca's own word wins when it gave one.** Its formatter prints
// `unverified (${verification.reason.replaceAll("_", " ")})` whenever the
// verification block is present, and falls back to a table keyed on the path
// only when it is absent. Mirroring that means a failure message carries the
// tool's actual words rather than this package's paraphrase of them.
func UnverifiedReason(path, reason string) string {
	if reason != "" {
		return strings.ReplaceAll(reason, "_", " ")
	}
	if known, listed := unverifiedReasons[path]; listed {
		return known
	}
	return "verification metadata unavailable"
}

func firstLine(output []byte) string {
	line, _, _ := bytes.Cut(bytes.TrimSpace(output), []byte("\n"))
	const limit = 200
	if len(line) > limit {
		line = line[:limit]
	}
	return string(line)
}

// ResultBody is the JSON a tool result carries.
//
// `structuredContent` is the authoritative field and `read_pane` fills it,
// but it postdates protocol 2024-11-05 — which is why the text block carries
// the answer too, and why every reader needs this fallback rather than its
// own copy of it.
func ResultBody(result ToolResult) []byte {
	if len(result.Structured) > 0 {
		return result.Structured
	}
	return []byte(result.Text)
}

// joinLines, joinCommas and joinSemicolons render a list into one message.
// Separate names rather than a separator argument, because the call sites
// read as prose and a bare ", " at a call site does not.
func joinLines(values []string) string      { return strings.Join(values, "\n  ") }
func joinCommas(values []string) string     { return strings.Join(values, ", ") }
func joinSemicolons(values []string) string { return strings.Join(values, "; ") }

// joinNewlines renders a list one per line, for a file rather than a message.
func joinNewlines(values []string) string { return strings.Join(values, "\n") }
