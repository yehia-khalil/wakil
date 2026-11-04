package wakilcore

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// assistantRecord builds one transcript "assistant" record carrying the
// given content blocks.
func assistantRecord(blocks ...map[string]any) map[string]any {
	return map[string]any{
		"type":    "assistant",
		"message": map[string]any{"role": "assistant", "content": blocks},
	}
}

func TestReadSession_MapsEveryBlockKindAndDropsThinking(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "run the query"}}}},
		assistantRecord(
			map[string]any{"type": "thinking", "thinking": "let me think"},
			map[string]any{"type": "text", "text": "on it"},
			map[string]any{"type": "tool_use", "name": "db_run_query", "input": map[string]any{"query": "select 1"}},
		),
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{
				{"type": "tool_result", "content": "1 row", "is_error": false}}}},
	})

	got, err := ReadSession("s1", 100)
	if err != nil {
		t.Fatalf("ReadSession: %v", err)
	}
	var kinds []string
	for _, e := range got.Entries {
		kinds = append(kinds, e.Kind)
	}
	want := []string{"user", "assistant", "tool", "toolResult"}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Fatalf("kinds = %v, want %v (thinking must be dropped)", kinds, want)
	}
	if got.Entries[0].Text != "run the query" {
		t.Errorf("user text = %q", got.Entries[0].Text)
	}
	if got.Entries[2].ToolName != "db_run_query" {
		t.Errorf("tool name = %q, want db_run_query", got.Entries[2].ToolName)
	}
	if got.Cwd != projDir {
		t.Errorf("Cwd = %q, want %q", got.Cwd, projDir)
	}
	if got.Provider != "primary" {
		t.Errorf("Provider = %q, want primary", got.Provider)
	}
	if got.Truncated {
		t.Errorf("Truncated = true, want false")
	}
}

// Workspaces, piece 1: the window appends the workspace map to the operator's words on a
// session's first turn and whenever it changed. A resumed thread's "you" rows are the words
// only — in a plain-string record and in a text block alike — while an assistant's text that
// happens to quote the marker is left as it was.
func TestReadSession_UserRowsLeaveOutTheWorkspaceMap(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	mapBlock := "\n\n[Wakil: where you work. This map replaces any earlier one.]\nYou are in Main of project proj"
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s-map", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": "where do you work" + mapBlock}},
		assistantRecord(map[string]any{"type": "text", "text": "I quote it" + mapBlock}),
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "and now" + mapBlock}}}},
	})

	got, err := ReadSession("s-map", 100)
	if err != nil {
		t.Fatalf("ReadSession: %v", err)
	}
	if len(got.Entries) != 3 {
		t.Fatalf("entries = %+v, want 3", got.Entries)
	}
	if got.Entries[0].Text != "where do you work" {
		t.Errorf("first user row = %q, want the operator's words only", got.Entries[0].Text)
	}
	if got.Entries[2].Text != "and now" {
		t.Errorf("later user row = %q, want the operator's words only", got.Entries[2].Text)
	}
	if got.Entries[1].Text != "I quote it"+mapBlock {
		t.Errorf("assistant row = %q, want it untouched", got.Entries[1].Text)
	}
}

func TestReadSession_LimitKeepsTheLastEntriesAndReportsTruncation(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	records := []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "first"}}}},
	}
	for _, text := range []string{"a", "b", "c"} {
		records = append(records, assistantRecord(map[string]any{"type": "text", "text": text}))
	}
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", records)

	got, err := ReadSession("s1", 2)
	if err != nil {
		t.Fatalf("ReadSession: %v", err)
	}
	if len(got.Entries) != 2 {
		t.Fatalf("len(Entries) = %d, want 2", len(got.Entries))
	}
	if got.Entries[0].Text != "b" || got.Entries[1].Text != "c" {
		t.Errorf("kept %q,%q — want the LAST two, b,c", got.Entries[0].Text, got.Entries[1].Text)
	}
	if !got.Truncated {
		t.Errorf("Truncated = false, want true")
	}
}

func TestReadSession_LimitBoundary(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// Four entries total: "first", "a", "b", "c".
	records := []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "first"}}}},
	}
	for _, text := range []string{"a", "b", "c"} {
		records = append(records, assistantRecord(map[string]any{"type": "text", "text": text}))
	}
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", records)

	cases := []struct {
		name      string
		limit     int
		wantTexts []string
		wantTrunc bool
	}{
		// limit == len(entries): every entry is kept, and nothing was
		// dropped to get there — Truncated must be false. This is the
		// off-by-one boundary: a `>=` where the code means `>` would
		// falsely mark this one truncated.
		{"limit equals len", 4, []string{"first", "a", "b", "c"}, false},
		// limit == len(entries)-1: exactly one entry — the oldest — is
		// dropped, and that must be reported.
		{"limit equals len-1", 3, []string{"a", "b", "c"}, true},
		// limit == 0 means "keep all", not "keep none".
		{"limit zero keeps all", 0, []string{"first", "a", "b", "c"}, false},
		// A negative limit also means "keep all".
		{"negative limit keeps all", -1, []string{"first", "a", "b", "c"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ReadSession("s1", tc.limit)
			if err != nil {
				t.Fatalf("ReadSession: %v", err)
			}
			var texts []string
			for _, e := range got.Entries {
				texts = append(texts, e.Text)
			}
			if strings.Join(texts, ",") != strings.Join(tc.wantTexts, ",") {
				t.Errorf("texts = %v, want %v", texts, tc.wantTexts)
			}
			if got.Truncated != tc.wantTrunc {
				t.Errorf("Truncated = %v, want %v", got.Truncated, tc.wantTrunc)
			}
		})
	}
}

func TestReadSession_RefusesACwdThatIsNoLongerAProjectRootAndNamesIt(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	strayDir := filepath.Join(home, "stray")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// Filed under the project's encoded directory, but its cwd is elsewhere
	// — the shape a project reconfigured after the session ran leaves behind.
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": strayDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "hi"}}}},
	})

	_, err := ReadSession("s1", 100)
	if err == nil {
		t.Fatal("ReadSession succeeded, want a refusal")
	}
	if !strings.Contains(err.Error(), strayDir) {
		t.Errorf("error %q does not name the offending path %q", err, strayDir)
	}
}

// TestReadSession_ErrorPathMarshalsEntriesAsEmptyArrayNotNull pins the
// shape of what travels beside a refusal, not just the refusal itself.
// The MCP SDK (go-sdk v1.7.0) marshals a handler's Out and sets
// StructuredContent even when the call errors, so a zero-value
// SessionThread{} — whose Entries carries no omitempty — would put
// "entries":null on the wire next to the error message, against a tool
// whose output schema types entries as a non-nullable array. ReadSession
// must return NewErrSessionThread() on every error path instead.
func TestReadSession_ErrorPathMarshalsEntriesAsEmptyArrayNotNull(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	strayDir := filepath.Join(home, "stray")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": strayDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "hi"}}}},
	})

	got, err := ReadSession("s1", 100)
	if err == nil {
		t.Fatal("ReadSession succeeded, want a refusal")
	}

	b, marshalErr := json.Marshal(got)
	if marshalErr != nil {
		t.Fatalf("json.Marshal: %v", marshalErr)
	}
	payload := string(b)
	if strings.Contains(payload, `"entries":null`) {
		t.Errorf("payload carries entries:null: %s", payload)
	}
	if !strings.Contains(payload, `"entries":[]`) {
		t.Errorf("payload does not carry entries:[]: %s", payload)
	}
}

func TestReadSession_UnknownIDIsAUserError(t *testing.T) {
	home, _ := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	_, err := ReadSession("nope", 100)
	if err == nil {
		t.Fatal("ReadSession succeeded, want a refusal")
	}
	// UserError is a constructor (func(string) error) over an unexported
	// concrete type, not a type name itself — errors.As via IsUserError is
	// the house pattern for checking membership (see dbresolve_test.go,
	// driver_mongo_test.go), not a direct type assertion.
	if _, ok := IsUserError(err); !ok {
		t.Errorf("error type %T, want a UserError", err)
	}
}

// TestReadSession_OversizedLineIsReportedNotSilentlyTruncated pins the FIX
// for readThreadEntries ignoring sc.Err(): bufio.Scanner stops scanning —
// silently, with no panic and no error surfaced by Scan() itself — the
// moment one line exceeds its configured 8 MB token cap, so before this fix
// whatever entries were decoded from lines BEFORE the oversized one
// travelled back as a complete, untruncated SessionThread
// ({"entries":[...],"truncated":false}) rather than as a signal that the
// read did not finish. The first line here carries the cwd record
// locateSession needs to find the session at all; the second is the one
// that blows the cap, so this exercises exactly the "readable up to a
// point, then not" shape the fix targets rather than an unreadable file
// from the start (that is TestReadSession_UnknownIDIsAUserError).
func TestReadSession_OversizedLineIsReportedNotSilentlyTruncated(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	huge := strings.Repeat("x", 9*1024*1024) // above readThreadEntries' 8 MB scanner cap
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "first"}}}},
		{"type": "user", "cwd": projDir, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": huge}}}},
	})

	got, err := ReadSession("s1", 100)
	if err == nil {
		t.Fatalf("ReadSession succeeded with entries %v, want a refusal — the scan never reached the end of the file", got.Entries)
	}
	if _, ok := IsUserError(err); !ok {
		t.Errorf("error type %T, want a UserError", err)
	}
	if len(got.Entries) != 0 {
		t.Errorf("entries = %v, want NewErrSessionThread's empty slice on the error path", got.Entries)
	}
}
