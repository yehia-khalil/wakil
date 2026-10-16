# Phase 2b-v — Session Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Picking a session in ⌘P forks it into a new Wakil-minted session that continues the conversation, with its thought thread rebuilt from the transcript.

**Architecture:** Every resume is a *fork* — `--resume <parent> --fork-session --session-id <fresh>` — because two live processes on one session id scramble the transcript and no layer here can prevent that. The capability layer (Go, `wakil-ctx`) reads the transcript and owns the parent→child lineage; the app replaces its harness instance rather than resuming one, and rebuilds `WindowModel.thoughts` from what Go returns. The agent may dispatch a resume like any other `.control` action, and the handler parks the request into a broker and returns *before* the swap, so the agent that asked gets a result before it is replaced.

**Tech Stack:** Go 1.x (`internal/wakilcore`, `cmd/wakil-ctx`, MCP via `github.com/modelcontextprotocol/go-sdk/mcp`), Swift 6 / SwiftUI / Swift Testing (`@Test`, `#expect`), `claude` CLI 2.1.266.

**Spec:** `docs/superpowers/specs/2026-09-10-phase-2b-v-session-resume-design.md`
**Probe:** `docs/wakil/session-resume-probe.md` (twelve scenarios, measured)

## Global Constraints

- **CLI pinned at `claude` 2.1.266.** Every argv claim here was measured against that version. No startup guard is built; the acceptance runbook pins the version instead (spec §13).
- **Exactly two argv shapes, never a third.** Fresh: `--session-id <fresh>`. Fork: `--resume <parent> --fork-session --session-id <fresh>`. `--session-id` alongside `--resume` without `--fork-session` is refused by the CLI at startup (probe §2), so this is a test, not a convention.
- **`thinking` blocks are dropped in the Go capability, never in Swift** (spec §4.1).
- **`user` entries ARE rendered on rebuild.** This is the one deliberate divergence from a live thread, whose `thoughtRow` has no user case (spec §4.1, §9).
- **Every MCP tool's `Out` must be a JSON object, never a bare slice.** `internal/mcpx`'s rule; `cmd/wakil-ctx/schema_test.go` enforces it.
- **A handler returning a tool error returns `toolErr(err)` alongside a `nil` error.** A non-nil error makes the SDK copy the raw string into Content — the leak `toolErr` exists to prevent.
- **Refusals become `status` text, never thrown past a SwiftUI control** (spec §7).
- **Run `make build` before `make app-test`.** `bin/` is per-worktree and 16 Swift tests shell out to `bin/wakil-ctx` (`phase-2b-iv-acceptance.md` H1).
- Test commands: Go `go test ./internal/wakilcore/ -run <name> -v`; Swift `make app-test` (whole suite; there is no per-test target).

---

### Task 1: Resolved project roots, as one named thing

`ListSessions` resolves the project's roots to absolute paths inline. Three more callers now need the same list — `read_session`'s refusal (Task 3), `get_context` for the app (Task 11), and the tests. Extract it before anything depends on a copy.

**Files:**
- Modify: `internal/wakilcore/sessions.go:296-305` (the inline resolution inside `ListSessions`)
- Modify: `internal/wakilcore/resolve.go:8-14` (`Resolved`)
- Test: `internal/wakilcore/sessions_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `func ProjectRootPaths(r Resolved) []string` — absolute, cleaned, in declaration order. `Resolved.RootPaths []string` with json tag `rootPaths`, populated by `Resolve()`.

- [ ] **Step 1: Write the failing test**

In `internal/wakilcore/sessions_test.go`:

```go
func TestProjectRootPaths_ResolvesRelativeAndAbsoluteInOrder(t *testing.T) {
	home, _ := setupHome(t)
	projDir := filepath.Join(home, "proj")
	elsewhere := filepath.Join(home, "elsewhere")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{
		{Path: ".", Role: "api"},
		{Path: "src", Role: "web"},
		{Path: elsewhere, Role: "infra"},
	})
	activateProject(t, "proj", projPath)

	r, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	got := ProjectRootPaths(r)
	want := []string{projDir, filepath.Join(projDir, "src"), elsewhere}
	if !slices.Equal(got, want) {
		t.Errorf("ProjectRootPaths = %v, want %v", got, want)
	}
	if !slices.Equal(r.RootPaths, want) {
		t.Errorf("Resolved.RootPaths = %v, want %v", r.RootPaths, want)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestProjectRootPaths -v`
Expected: FAIL — `undefined: ProjectRootPaths` and `r.RootPaths undefined`.

- [ ] **Step 3: Write the minimal implementation**

In `internal/wakilcore/sessions.go`, add above `ListSessions`:

```go
// ProjectRootPaths resolves the active project's declared roots to
// absolute paths, in declaration order.
//
// Order is meaningful and must be preserved: the app launches a fresh
// agent session in the FIRST root (Phase 2b-v spec §5.1), and that is the
// operator's declaration, not this function's choice.
//
// Extracted from ListSessions, which is still its main caller. It is
// exported because read_session's refusal and get_context's report need
// exactly this list, and a second copy of the projDir derivation is how
// two answers to "which directories are this project" start to disagree.
func ProjectRootPaths(r Resolved) []string {
	// projDir: <projectDir>/.wakil/project.json -> <projectDir>
	projDir := filepath.Dir(filepath.Dir(r.ProjectPath))
	var roots []string
	for _, root := range r.Project.Roots {
		roots = append(roots, resolveRootPath(projDir, root.Path))
	}
	return roots
}
```

Replace the inline block in `ListSessions` (currently `projDir := ...` through the `for _, root := range r.Project.Roots` loop) with:

```go
	roots := ProjectRootPaths(r)
	var prefixes []string
	for _, abs := range roots {
		prefixes = append(prefixes, EncodeRootPath(abs))
	}
```

In `internal/wakilcore/resolve.go`, add the field to `Resolved`:

```go
type Resolved struct {
	Org         string
	Project     *Project
	ProjectPath string
	Environment string
	Provider    ProviderReport
	// RootPaths is Project.Roots resolved to absolute paths, in
	// declaration order — what ProjectRootPaths returns. Reported on the
	// wire so the app does not have to re-derive it: root paths may be
	// relative to the project directory, and resolving them in Swift
	// would be a second implementation of a rule that lives here.
	RootPaths []string `json:"rootPaths,omitempty"`
}
```

At the end of `Resolve()`, immediately before it returns its `Resolved` value, populate the field. Find the return and set `out.RootPaths = ProjectRootPaths(out)` on the value being returned (assign to a local first if `Resolve` currently returns a composite literal directly).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ -run 'TestProjectRootPaths|TestListSessions' -v`
Expected: PASS, including every pre-existing `TestListSessions_*`.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/sessions.go internal/wakilcore/resolve.go internal/wakilcore/sessions_test.go
git commit -m "Name the project's resolved roots once, and report them

ListSessions resolved roots inline. read_session's refusal and the app's
launch directory both need the same list, and a second copy of the
projDir derivation is how two answers to \"which directories are this
project\" start to disagree."
```

---

### Task 2: `SessionMeta` gains `cwd` and `title`

`firstCwd` already reads the cwd on the way to filtering and throws the value away. The app needs it (a resumed session runs in it), and it cannot be recovered from the directory name because `EncodeRootPath` is lossy and one-way. `title` is the transcript's last `ai-title` record — measured present six times in one real session, last one winning.

**Files:**
- Modify: `internal/wakilcore/sessions.go:42-61` (`SessionMeta`), `:352-385` (the append inside `ListSessions`), `:536-579` (`GetSession`)
- Test: `internal/wakilcore/sessions_test.go`

**Interfaces:**
- Consumes: `ProjectRootPaths` (Task 1).
- Produces: `SessionMeta.Cwd string` (json `cwd`), `SessionMeta.Title string` (json `title,omitempty`), `func lastAITitle(path string) string`.

- [ ] **Step 1: Write the failing test**

```go
func TestListSessions_ReportsCwdAndTitle(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hello"}},
		{"type": "ai-title", "aiTitle": "first title", "sessionId": "s1"},
		{"type": "ai-title", "aiTitle": "final title", "sessionId": "s1"},
	})

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("len = %d, want 1: %+v", len(got.Sessions), got)
	}
	if got.Sessions[0].Cwd != projDir {
		t.Errorf("Cwd = %q, want %q", got.Sessions[0].Cwd, projDir)
	}
	// Last one wins: the CLI rewrites the title as the conversation goes on.
	if got.Sessions[0].Title != "final title" {
		t.Errorf("Title = %q, want %q", got.Sessions[0].Title, "final title")
	}
}

func TestListSessions_TitleAbsentIsEmptyNotAnError(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "s1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hello"}},
	})

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("len = %d, want 1", len(got.Sessions))
	}
	if got.Sessions[0].Title != "" {
		t.Errorf("Title = %q, want empty", got.Sessions[0].Title)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/wakilcore/ -run 'TestListSessions_ReportsCwdAndTitle|TestListSessions_TitleAbsent' -v`
Expected: FAIL — `got.Sessions[0].Cwd undefined`.

- [ ] **Step 3: Write the minimal implementation**

Add to `SessionMeta` in `internal/wakilcore/sessions.go`, after `Provider`:

```go
	// Cwd is the working directory the session's first record carries —
	// what firstCwd reads on the way to confirming project membership,
	// reported rather than discarded.
	//
	// It cannot be recovered from Root, which is the ENCODED directory
	// name: EncodeRootPath is many-to-one and documented strictly
	// one-way. Phase 2b-v resumes a session in this directory, so the
	// value has to travel with the session rather than be re-derived.
	//
	// Not omitempty: every session ListSessions returns had a readable
	// cwd, because one that did not was counted in Skipped and dropped.
	Cwd string `json:"cwd"`
	// Title is the transcript's last "ai-title" record — a title the CLI
	// generates and then rewrites as the conversation proceeds. Empty
	// when the transcript carries none, in which case FirstPrompt is the
	// label to fall back to.
	//
	// Undocumented, and so a downgrade rather than a break if it goes
	// away: it is a record type in someone else's file format, not a
	// flag with a contract.
	Title string `json:"title,omitempty"`
```

Change `firstCwd`'s call site inside `ListSessions` so the value is kept, and populate both fields on the appended `SessionMeta`:

```go
				out = append(out, SessionMeta{
					ID:       strings.TrimSuffix(f.Name(), ".jsonl"),
					Root:     name,
					Provider: p.ID,
					ModTime:  info.ModTime(),
					Cwd:      cwd,
					Title:    lastAITitle(path),
				})
```

Add the reader beside `firstPrompt`:

```go
// lastAITitle returns the transcript's final "ai-title" record's title, or
// "" when it holds none.
//
// LAST, not first: the CLI rewrites the title as the conversation goes on
// — six records in one measured session — and the last is the one that
// describes the whole of it.
func lastAITitle(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	title := ""
	for sc.Scan() {
		var rec struct {
			Type    string `json:"type"`
			AITitle string `json:"aiTitle"`
		}
		if json.Unmarshal(sc.Bytes(), &rec) != nil {
			continue
		}
		if rec.Type == "ai-title" && rec.AITitle != "" {
			title = rec.AITitle
		}
	}
	return title
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ -v`
Expected: PASS, whole package.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/sessions.go internal/wakilcore/sessions_test.go
git commit -m "Report each session's cwd and title

firstCwd read the cwd to confirm project membership and threw it away.
A resumed session runs in that directory and it cannot be recovered
from the encoded directory name, so it has to travel with the session.
The title is the transcript's last ai-title record — the CLI rewrites
it as the conversation proceeds — and beats 200 runes of first prompt
as a label."
```

---

### Task 3: `ReadSession` — the transcript reader, and the refusal that names the path

**Files:**
- Create: `internal/wakilcore/transcript.go`
- Create: `internal/wakilcore/transcript_test.go`
- Modify: `internal/wakilcore/sessions.go` (no change if Task 2 landed; `locateSession` goes in the new file)

**Interfaces:**
- Consumes: `ProjectRootPaths` (Task 1), `SessionMeta.Cwd` (Task 2), the existing `UserError`, `CurrentOrg`, `listProvidersFor`, `providerSessionsRoot`, `cwdMatchesAnyRoot`, `firstCwd`.
- Produces:

```go
type ThreadEntry struct {
	Kind     string `json:"kind"`               // "user" | "assistant" | "tool" | "toolResult"
	Text     string `json:"text"`
	ToolName string `json:"toolName,omitempty"`
	IsError  bool   `json:"isError,omitempty"`
}

type SessionThread struct {
	Entries   []ThreadEntry `json:"entries"`
	Truncated bool          `json:"truncated,omitempty"`
	Cwd       string        `json:"cwd"`
	Provider  string        `json:"provider"`
	Parent    string        `json:"parent,omitempty"`
}

func ReadSession(id string, limit int) (SessionThread, error)
```

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/transcript_test.go`:

```go
package wakilcore

import (
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

func TestReadSession_UnknownIDIsAUserError(t *testing.T) {
	home, _ := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	_, err := ReadSession("nope", 100)
	if err == nil {
		t.Fatal("ReadSession succeeded, want a refusal")
	}
	if _, ok := err.(UserError); !ok {
		t.Errorf("error type %T, want UserError", err)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/wakilcore/ -run TestReadSession -v`
Expected: FAIL — `undefined: ReadSession`.

- [ ] **Step 3: Write the minimal implementation**

Create `internal/wakilcore/transcript.go`:

```go
package wakilcore

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// ThreadEntry is one line of a rebuilt thought thread: the transcript
// decomposed into exactly the shapes the app already renders.
//
// Kind is one of "user", "assistant", "tool", "toolResult". "thinking"
// blocks produce NO entry, and they are dropped here rather than in the
// app deliberately: the live thread has never drawn them (Swift's
// thoughtRow has no thinking case), and dropping them at this layer makes
// it structural that no caller can reintroduce them by accident.
type ThreadEntry struct {
	Kind     string `json:"kind"`
	Text     string `json:"text"`
	ToolName string `json:"toolName,omitempty"`
	IsError  bool   `json:"isError,omitempty"`
}

// SessionThread is ReadSession's answer: the entries plus everything the
// caller needs to relaunch the session, since finding the file required
// reading all of it anyway.
type SessionThread struct {
	// Entries are oldest-first — the order they are rendered in.
	Entries []ThreadEntry `json:"entries"`
	// Truncated reports that earlier entries were dropped to honour
	// limit. Same partiality-alongside-data invariant as Rows.Truncated
	// and SessionList.Skipped: a caller must be able to tell a short
	// thread from a trimmed one.
	Truncated bool   `json:"truncated,omitempty"`
	Cwd       string `json:"cwd"`
	Provider  string `json:"provider"`
	// Parent is the session this one was forked from, per the lineage
	// store, or "" for a session that was started fresh.
	Parent string `json:"parent,omitempty"`
}

// locateSession finds one session's transcript by id across every provider
// the active org holds, and returns its path, its provider id and its cwd.
//
// It does NOT filter by the active project, and that is the point.
// GetSession does filter — it selects from ListSessions' output — so a
// session whose cwd is no longer one of the project's roots comes back as
// "not found", and the operator learns nothing about why a session plainly
// on disk cannot be resumed. This locates first and judges second, so the
// refusal can name the offending directory.
func locateSession(id string) (path string, provider string, cwd string, err error) {
	org, err := CurrentOrg()
	if err != nil {
		return "", "", "", err
	}
	providers, _, err := listProvidersFor(org)
	if err != nil {
		return "", "", "", err
	}
	for _, p := range providers {
		base, ok := providerSessionsRoot(p)
		if !ok {
			continue
		}
		dirs, err := os.ReadDir(base)
		if err != nil {
			continue
		}
		for _, d := range dirs {
			if !d.IsDir() {
				continue
			}
			candidate := filepath.Join(base, d.Name(), id+".jsonl")
			if _, err := os.Stat(candidate); err != nil {
				continue
			}
			c, hasCwd := firstCwd(candidate)
			if !hasCwd {
				return "", "", "", UserError(
					"session " + id + " carries no working directory record, so it cannot be resumed")
			}
			return candidate, p.ID, c, nil
		}
	}
	return "", "", "", UserError("session not found in any of this org's providers: " + id)
}

// ReadSession reads one session's transcript into thread entries, keeping
// the last `limit` of them.
//
// It refuses a session whose recorded working directory is not one of the
// active project's roots, naming that directory. Resuming there anyway is
// not a harmless default: the CLI accepts a foreign cwd, keeps the
// transcript in the original project's directory and writes records
// carrying the new one, so the file ends up describing two places at once
// (session-resume-probe.md §9).
func ReadSession(id string, limit int) (SessionThread, error) {
	path, provider, cwd, err := locateSession(id)
	if err != nil {
		return SessionThread{}, err
	}
	r, err := Resolve()
	if err != nil {
		return SessionThread{}, err
	}
	if !cwdMatchesAnyRoot(cwd, ProjectRootPaths(r)) {
		return SessionThread{}, UserError(
			"session " + id + " ran in " + cwd +
				", which is not a root of the active project " + r.Project.Name +
				" — re-declare that root or start a fresh session")
	}
	entries, err := readThreadEntries(path)
	if err != nil {
		return SessionThread{}, err
	}
	out := SessionThread{Cwd: cwd, Provider: provider, Entries: []ThreadEntry{}}
	if limit > 0 && len(entries) > limit {
		out.Entries = entries[len(entries)-limit:]
		out.Truncated = true
	} else if entries != nil {
		out.Entries = entries
	}
	parent, err := SessionParent(id)
	if err == nil {
		out.Parent = parent
	}
	return out, nil
}

// readThreadEntries decomposes a transcript into entries, oldest-first.
//
// Record types deliberately ignored, all measured present in real
// transcripts: attachment, queue-operation, atis-latch, last-prompt,
// ai-title, mode. Only "user" and "assistant" carry conversation.
func readThreadEntries(path string) ([]ThreadEntry, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, UserError("cannot read session transcript: " + err.Error())
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	var out []ThreadEntry
	for sc.Scan() {
		var rec struct {
			Type    string `json:"type"`
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &rec) != nil {
			continue
		}
		if rec.Type != "user" && rec.Type != "assistant" {
			continue
		}
		out = append(out, blockEntries(rec.Type, rec.Message.Content)...)
	}
	return out, nil
}

// blockEntries maps one message's content into entries. Content is either
// a plain string (an older/simpler record shape, as firstPrompt already
// handles) or an array of typed blocks.
func blockEntries(recordType string, content json.RawMessage) []ThreadEntry {
	if len(content) == 0 {
		return nil
	}
	var plain string
	if json.Unmarshal(content, &plain) == nil {
		if strings.TrimSpace(plain) == "" {
			return nil
		}
		return []ThreadEntry{{Kind: recordType, Text: plain}}
	}
	var blocks []struct {
		Type    string          `json:"type"`
		Text    string          `json:"text"`
		Name    string          `json:"name"`
		Input   json.RawMessage `json:"input"`
		Content json.RawMessage `json:"content"`
		IsError bool            `json:"is_error"`
	}
	if json.Unmarshal(content, &blocks) != nil {
		return nil
	}
	var out []ThreadEntry
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if strings.TrimSpace(b.Text) == "" {
				continue
			}
			out = append(out, ThreadEntry{Kind: recordType, Text: b.Text})
		case "tool_use":
			out = append(out, ThreadEntry{
				Kind: "tool", ToolName: b.Name, Text: compactJSON(b.Input)})
		case "tool_result":
			out = append(out, ThreadEntry{
				Kind: "toolResult", Text: compactJSON(b.Content), IsError: b.IsError})
		case "thinking":
			// Dropped. See ThreadEntry's doc comment.
			continue
		}
	}
	return out
}

// compactJSON renders a raw JSON value as a single line of text. A JSON
// string becomes its own contents rather than a quoted literal, so a tool
// result reads as text rather than as JSON about text.
func compactJSON(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}
```

`SessionParent` is Task 4's; until it exists this file will not compile. Write the file now and complete Task 4 before running the full suite — or stub `SessionParent` to `return "", nil` in this step and delete the stub in Task 4. Prefer the stub, so this task's tests can run.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ -run TestReadSession -v`
Expected: PASS, all four.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/transcript.go internal/wakilcore/transcript_test.go
git commit -m "Read a transcript into thread entries

Nothing is replayed on stdout when a session resumes, so the thread has
to be read off disk. thinking blocks are dropped here rather than in
the app, where a caller could reintroduce them: the live thread has
never drawn them.

Locates the transcript by id across the org's providers rather than by
filtering the project-scoped listing, which is what lets a session
whose cwd is no longer a project root be refused by naming that
directory instead of reported as not found."
```

---

### Task 4: The lineage store

The CLI records no link between a fork and its parent — probe §2 looked for `forkedFrom`, `parentSessionId` and `sourceSessionId` and found none. Wakil mints the child id, so it holds both halves.

**Files:**
- Create: `internal/wakilcore/sessions_lineage.go`
- Create: `internal/wakilcore/sessions_lineage_test.go`
- Modify: `internal/wakilcore/sessions.go` (join the parent into `ListSessions`), `internal/wakilcore/transcript.go` (delete Task 3's `SessionParent` stub)

**Interfaces:**
- Consumes: `CurrentOrg`, and whatever helper writes per-org JSON today (`orgDir`/`SaveRegistry`'s pattern — follow the existing file for the exact name).
- Produces: `func RecordSessionParent(child, parent string) error`, `func SessionParent(child string) (string, error)`, `func SessionParents() (map[string]string, error)`, `SessionMeta.Parent string` (json `parent,omitempty`).

- [ ] **Step 1: Write the failing test**

Create `internal/wakilcore/sessions_lineage_test.go`:

```go
package wakilcore

import (
	"path/filepath"
	"testing"
)

func TestSessionParent_RoundTrips(t *testing.T) {
	setupHome(t)
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}
	got, err := SessionParent("child-1")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "parent-1" {
		t.Errorf("SessionParent = %q, want parent-1", got)
	}
}

func TestSessionParent_UnknownChildIsEmptyNotAnError(t *testing.T) {
	setupHome(t)
	got, err := SessionParent("never-recorded")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "" {
		t.Errorf("SessionParent = %q, want empty", got)
	}
}

func TestSessionParents_AbsentStoreIsAnEmptyMap(t *testing.T) {
	setupHome(t)
	got, err := SessionParents()
	if err != nil {
		t.Fatalf("SessionParents: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("SessionParents = %v, want empty", got)
	}
}

func TestRecordSessionParent_IsPerOrg(t *testing.T) {
	home, _ := setupHome(t) // pins WAKIL_ORG=initech
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}
	// A second org must not see it. Invariant 4: the org directory is a
	// boundary cross-org bleed must be structurally unable to cross.
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	t.Setenv("WAKIL_ORG", "other")
	got, err := SessionParent("child-1")
	if err != nil {
		t.Fatalf("SessionParent: %v", err)
	}
	if got != "" {
		t.Errorf("org \"other\" sees %q — the store leaked across orgs", got)
	}
	_ = filepath.Join(home) // keep home referenced if unused above
}

func TestListSessions_ReportsTheParentOfAFork(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "child-1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hi"}},
	})
	if err := RecordSessionParent("child-1", "parent-1"); err != nil {
		t.Fatalf("RecordSessionParent: %v", err)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(got.Sessions) != 1 {
		t.Fatalf("len = %d, want 1", len(got.Sessions))
	}
	if got.Sessions[0].Parent != "parent-1" {
		t.Errorf("Parent = %q, want parent-1", got.Sessions[0].Parent)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/wakilcore/ -run 'TestSessionParent|TestSessionParents|TestRecordSessionParent|TestListSessions_ReportsTheParent' -v`
Expected: FAIL — `undefined: RecordSessionParent`.

- [ ] **Step 3: Write the minimal implementation**

Create `internal/wakilcore/sessions_lineage.go`. Read `internal/wakilcore/orgs.go` (or wherever `SaveRegistry` writes `projects.json`) first and reuse its directory helper and file permissions verbatim rather than re-deriving the path.

```go
package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// sessionLineageFile is where a fork's parent is recorded:
// ~/.wakil/orgs/<org>/sessions.json, beside org.json, active.json,
// projects.json and providers/.
//
// Per-org because Invariant 4 makes the org directory a boundary that
// cross-org bleed must be structurally unable to cross, and a session
// belongs to a provider which belongs to an org.
func sessionLineageFile(org string) string {
	return filepath.Join(orgDir(org), "sessions.json")
}

// SessionParents maps child session id -> parent session id for the active
// org. An absent store is an empty map, not an error: an org that has
// never forked a session has nothing to say, and that is a known answer
// rather than an unknown one.
func SessionParents() (map[string]string, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(sessionLineageFile(org))
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, err
	}
	out := map[string]string{}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, UserError("cannot read " + sessionLineageFile(org) + ": " + err.Error())
	}
	return out, nil
}

// SessionParent returns the session `child` was forked from, or "" when it
// was started fresh.
func SessionParent(child string) (string, error) {
	all, err := SessionParents()
	if err != nil {
		return "", err
	}
	return all[child], nil
}

// RecordSessionParent records that `child` was forked from `parent`.
//
// The CLI records no such link — a forked transcript is a full copy of its
// history with no field naming its origin (session-resume-probe.md §2) —
// and Wakil mints the child id, so this is the only place the
// relationship can live. Without it ⌘P grows a near-identical entry per
// resume with nothing to show they are one conversation.
func RecordSessionParent(child, parent string) error {
	if child == "" || parent == "" {
		return UserError("both child and parent session ids are required")
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	all, err := SessionParents()
	if err != nil {
		return err
	}
	all[child] = parent
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	path := sessionLineageFile(org)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o600)
}
```

Add the field to `SessionMeta` in `sessions.go`, after `Title`:

```go
	// Parent is the session this one was forked from, per the org's
	// lineage store, or "" for one started fresh. ⌘P collapses a chain
	// of forks into a single entry using it.
	Parent string `json:"parent,omitempty"`
```

In `ListSessions`, read the map once before the provider loop and set the field on each appended `SessionMeta`:

```go
	// Read once, outside the loop: lineage is a property of the org, not
	// of the store being searched. A failure to read it must not fail the
	// listing — a session with an unknown parent is still a session.
	parents, err := SessionParents()
	if err != nil {
		parents = map[string]string{}
	}
```

…then `Parent: parents[strings.TrimSuffix(f.Name(), ".jsonl")],` on the append.

Delete the `SessionParent` stub added in Task 3 if you used one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/wakilcore/ -v`
Expected: PASS, whole package.

- [ ] **Step 5: Commit**

```bash
git add internal/wakilcore/sessions_lineage.go internal/wakilcore/sessions_lineage_test.go internal/wakilcore/sessions.go internal/wakilcore/transcript.go
git commit -m "Record which session a fork came from

The CLI records no lineage — a forked transcript is a full copy with no
field naming its origin — and Wakil mints the child id, so this is the
only place the link can live. Per-org, beside the org's other state,
because a session belongs to a provider which belongs to an org."
```

---

### Task 5: Expose both through `wakil-ctx`

**Files:**
- Modify: `cmd/wakil-ctx/main.go:127-141` (register beside `list_sessions`/`get_session`)
- Modify: `cmd/wakil-ctx/schema_test.go:23-25` (the advertised-tool list)

**Interfaces:**
- Consumes: `wakilcore.ReadSession`, `wakilcore.RecordSessionParent` (Tasks 3, 4).
- Produces: MCP tools `read_session` and `record_session_parent`.

- [ ] **Step 1: Write the failing test**

In `cmd/wakil-ctx/schema_test.go`, add both names to the slice:

```go
	mcpxtest.AssertObjectOutputSchemas(t, newServer(), []string{
		"get_context",
		"list_projects",
		"set_project",
		"set_environment",
		"list_environments",
		"list_sessions",
		"get_session",
		"read_session",
		"record_session_parent",
	})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./cmd/wakil-ctx/ -run TestOutputSchemasAreObjects -v`
Expected: FAIL — the server advertises no `read_session`.

- [ ] **Step 3: Write the minimal implementation**

In `cmd/wakil-ctx/main.go`, add the arg types beside `idArg`:

```go
type readSessionArgs struct {
	ID    string `json:"id" jsonschema:"the session id"`
	Limit int    `json:"limit" jsonschema:"keep only the last N thread entries; 0 or absent keeps all"`
}
type sessionParentArgs struct {
	Child  string `json:"child" jsonschema:"the forked session's id"`
	Parent string `json:"parent" jsonschema:"the session it was forked from"`
}
```

Register both after `get_session`:

```go
	mcp.AddTool(s, &mcp.Tool{Name: "read_session", Description: "Read one session's transcript as thought-thread entries, oldest first, together with the working directory it ran in, the provider holding it and the session it was forked from. Keeps the last limit entries and sets truncated when earlier ones were dropped. thinking blocks produce no entry. Refuses, naming the directory, when the session's working directory is not a root of the active project — resuming it elsewhere would leave the transcript describing two places at once."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a readSessionArgs) (*mcp.CallToolResult, wakilcore.SessionThread, error) {
			out, err := wakilcore.ReadSession(a.ID, a.Limit)
			if err != nil {
				return toolErr(err), wakilcore.SessionThread{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "record_session_parent", Description: "Record that one session was forked from another, in the active org's lineage store. The CLI records no such link, so this is the only place it lives; the session list reports it so a chain of resumes can be shown as one conversation."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a sessionParentArgs) (*mcp.CallToolResult, empty, error) {
			if err := wakilcore.RecordSessionParent(a.Child, a.Parent); err != nil {
				return toolErr(err), empty{}, nil
			}
			return nil, empty{}, nil
		})
```

Also extend `list_sessions`'s and `get_session`'s descriptions to mention the new fields — a description that does not name what it returns is how the last one shipped unusable.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./cmd/... ./internal/... && make vet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/wakil-ctx/main.go cmd/wakil-ctx/schema_test.go
git commit -m "Serve read_session and record_session_parent from wakil-ctx

Both carry object-typed Out values, which schema_test.go pins because
list_sessions once shipped a bare array and a validating client
rejected it during the Phase 1 acceptance run."
```

---

### Task 6: `buildLaunch` — two argv shapes, and a working directory

**Files:**
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift:9-13` (`HarnessLaunch`), `:33-37` and `:66-130` (`buildLaunch` and its doc comment)
- Test: `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift:6-11` (the `launch` helper) and new tests

**Interfaces:**
- Consumes: nothing.
- Produces:

```swift
public struct HarnessLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
}

public func buildLaunch(
    claudePath: String, sessionId: String, configDir: String, oauthToken: String,
    mcpConfigJSON: String, allowedTools: [String], workingDirectory: String,
    resumingFrom parentSessionId: String? = nil
) -> HarnessLaunch
```

- [ ] **Step 1: Write the failing test**

In `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`, extend the helper and add tests:

```swift
private func launch(
    allowedTools: [String] = ["mcp__wakil__read_pane", "mcp__wakil-pm"],
    resumingFrom parent: String? = nil,
    workingDirectory: String = "/Users/x/proj"
) -> HarnessLaunch {
    buildLaunch(claudePath: "/opt/homebrew/bin/claude", sessionId: "abc-123",
                configDir: "/Users/x/.claude-personal", oauthToken: "tok",
                mcpConfigJSON: #"{"mcpServers":{}}"#,
                allowedTools: allowedTools,
                workingDirectory: workingDirectory,
                resumingFrom: parent)
}

// MARK: - The two resume shapes

@Test func aFreshLaunchNeverMentionsResume() {
    let a = launch().arguments
    #expect(!a.contains("--resume"))
    #expect(!a.contains("--fork-session"))
    #expect(a.contains("--session-id"))
}

@Test func aForkCarriesResumeForkSessionAndAFreshSessionId() {
    let a = launch(resumingFrom: "parent-9").arguments
    let r = a.firstIndex(of: "--resume")!
    #expect(a[a.index(after: r)] == "parent-9")
    #expect(a.contains("--fork-session"))
    let s = a.firstIndex(of: "--session-id")!
    #expect(a[a.index(after: s)] == "abc-123")
}

// Measured: `--session-id can only be used with --continue or --resume if
// --fork-session is also specified.` (session-resume-probe.md §2). So an
// argv carrying --resume without both of the others is a session that
// never starts, and this is the shape of that refusal as a test.
@Test func resumeNeverAppearsWithoutForkSessionAndASessionId() {
    let a = launch(resumingFrom: "parent-9").arguments
    if a.contains("--resume") {
        #expect(a.contains("--fork-session"))
        #expect(a.contains("--session-id"))
    }
}

@Test func theWorkingDirectoryIsCarriedOnTheLaunch() {
    #expect(launch(workingDirectory: "/Users/x/booking").workingDirectory == "/Users/x/booking")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL to compile — `buildLaunch` has no `workingDirectory:` parameter.

- [ ] **Step 3: Write the minimal implementation**

Add the stored property to `HarnessLaunch`:

```swift
    /// The directory the child runs in.
    ///
    /// Not optional and not defaulted. Until 2b-v nothing set it, so
    /// `claude` inherited Wakil.app's own directory, recorded it in the
    /// transcript, and was filed under its encoded form — while
    /// `ListSessions` filters by the active project's roots, so **no
    /// session Wakil created could appear in ⌘P at all**
    /// (`session-resume-probe.md` §8, measured on three real transcripts).
    /// A default here would let that reappear silently.
    public let workingDirectory: String
```

Extend `buildLaunch`'s signature with `workingDirectory: String` and `resumingFrom parentSessionId: String? = nil`, and replace the fixed `--session-id` fragment with the two shapes:

```swift
    var arguments: [String] = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
    ]

    // Exactly two shapes, and never a third: the CLI refuses
    // `--session-id` alongside `--resume` unless `--fork-session` is also
    // passed, at startup, before any turn
    // (`session-resume-probe.md` §2).
    //
    // Every resume is a fork. Continuing a session in place would need an
    // exclusivity guarantee no layer of this system can make — the CLI
    // enforces none, and a session the operator has open in a terminal is
    // invisible to Wakil — and probe §9 measured what its absence costs:
    // two concurrent resumes interleave into one transcript that stays
    // valid JSON and stops describing a real conversation. Forking is safe
    // by construction, and it keeps Wakil minting every session id it
    // runs, which is what makes the resume list authoritative (charter
    // open question 5).
    if let parentSessionId {
        arguments += ["--resume", parentSessionId, "--fork-session"]
    }
    arguments += ["--session-id", sessionId]

    arguments += [
        "--mcp-config", mcpConfigJSON,
        "--strict-mcp-config",
        "--permission-prompt-tool", "mcp__\(wakilShimServerName)__\(permissionPromptToolName)",
    ]
```

Return `HarnessLaunch(executable: claudePath, arguments: arguments, environment: environment, workingDirectory: workingDirectory)`.

Rewrite the doc-comment paragraph that begins *"`--resume` is deliberately never among the arguments this function builds"* — it is now false. Replace it with the two-shapes rule and cite probe §2 and §9.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS. Every pre-existing `ClaudeCodeCLIHarnessTests` case still passes; the argv order changed but no test asserts absolute positions.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift
git commit -m "buildLaunch: two argv shapes, and a working directory

Fresh is --session-id. A resume is --resume <parent> --fork-session
--session-id <fresh>, because the CLI refuses the third combination at
startup and because two live processes on one session id scramble the
transcript. The working directory is not optional: until now nothing
set it, so claude inherited Wakil.app's own and no session Wakil
created could appear in the resume list at all."
```

---

### Task 7: The protocol, and the process that honours it

**Files:**
- Modify: `app/Sources/WakilKit/Harness/AgentHarness.swift:8-20`
- Modify: `app/Sources/WakilKit/Harness/ClaudeCodeCLIHarness.swift:200-229` (`start`), `:364-410` (`Engine.start`)
- Modify: `app/Tests/WakilKitTests/WindowModelTests.swift:89` (`StubHarness.start`)
- Test: `app/Tests/WakilKitTests/ClaudeCodeCLIHarnessTests.swift`

**Interfaces:**
- Consumes: `buildLaunch(... workingDirectory:resumingFrom:)` (Task 6).
- Produces: `func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws` on `AgentHarness`.

- [ ] **Step 1: Write the failing test**

In `ClaudeCodeCLIHarnessTests.swift`:

```swift
// The defect probe §8 measured: `claude` inherited Wakil.app's own
// directory because nothing set this, so its transcript was filed
// somewhere ListSessions would never look.
@Test func theChildIsSpawnedInTheDirectoryTheLaunchNames() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wakil-cwd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("where.txt")

    // /bin/sh stands in for `claude`: nothing in this repo's tests runs the
    // real binary, and what is under test is that Process is told where to
    // run, not what claude does there.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "pwd > \(out.path)"]
    process.currentDirectoryURL = URL(fileURLWithPath: dir.path)
    try process.run()
    process.waitUntilExit()

    let recorded = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(recorded == (try FileManager.default.destinationOfSymbolicLink(atPath: dir.path)) || recorded.hasSuffix(dir.lastPathComponent))
}

@Test func startPassesTheParentAndDirectoryThroughToTheLaunch() async {
    // buildLaunch is pure and already covered; this pins that `start`'s
    // parameters reach it rather than being dropped on the floor.
    let l = buildLaunch(claudePath: "/opt/homebrew/bin/claude", sessionId: "fresh-1",
                        configDir: "/c", oauthToken: "t", mcpConfigJSON: "{}",
                        allowedTools: [], workingDirectory: "/Users/x/proj",
                        resumingFrom: "parent-1")
    #expect(l.arguments.contains("--fork-session"))
    #expect(l.workingDirectory == "/Users/x/proj")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL to compile — `StubHarness` does not satisfy the new protocol requirement.

- [ ] **Step 3: Write the minimal implementation**

`AgentHarness.swift` — replace `start(sessionId:)`:

```swift
    /// Starts a session under `sessionId`, which the caller always
    /// generates: Wakil mints every agent session id it runs, and that is
    /// what makes the resume list authoritative rather than reconstructed
    /// (charter open question 5).
    ///
    /// `resumingFrom` is the session to continue. `nil` starts fresh.
    /// A non-nil value means a **fork**: the implementation continues that
    /// session's conversation under the new `sessionId`, leaving the
    /// original transcript untouched. Continuing a session in place is not
    /// offered, and the reason is measured rather than stylistic — see
    /// `buildLaunch`.
    ///
    /// `workingDirectory` is the directory the session runs in. It is a
    /// per-session value, not a property of the harness: a fresh session
    /// runs in the project's first declared root and a resumed one in the
    /// directory its own transcript records.
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws
```

`ClaudeCodeCLIHarness.start` — thread the two new parameters into `buildLaunch`. Keep the doc comment's `alreadyStopped` and race paragraphs verbatim; add a sentence that a resumed session is a *new instance*, because `stop` makes an instance spent.

`Engine.start` — after `process.executableURL = ...`:

```swift
        // Where the transcript gets filed, and therefore whether ⌘P can
        // ever see this session: `claude` records its cwd in the
        // transcript and files it under that path's encoded form, while
        // `ListSessions` filters by the active project's roots. Inheriting
        // Wakil.app's directory — which is what happened until 2b-v —
        // hides every session Wakil creates from its own resume list.
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
```

`StubHarness` in `WindowModelTests.swift` — record what it was asked for, since Task 10's tests assert on it:

```swift
    func start(sessionId: String, resumingFrom parentSessionId: String?, workingDirectory: String) async throws {
        await log.add("start:\(sessionId):\(parentSessionId ?? "-"):\(workingDirectory)")
    }
```

Update every existing assertion that expects the literal `"start"` in the log to match the new prefixed form (search `WindowModelTests.swift` for `"start"`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/ app/Tests/WakilKitTests/
git commit -m "The harness starts a session somewhere, and optionally from something

start() gains resumingFrom and workingDirectory. A resume is a fork
into a new session id, so it is a new harness instance rather than a
state change: every single-shot property of ClaudeCodeCLIHarness stays
exactly as it was, and both are load-bearing.

Engine.start now sets currentDirectoryURL, which is the difference
between a session Wakil can list and one it cannot."
```

---

### Task 8: `ResumeBroker` — park a request, return immediately

The write gate's `ConfirmationBroker` blocks its caller until a human decides. Resume needs the opposite: the handler must return *before* the swap, because the swap kills the process the reply is owed to.

**Files:**
- Create: `app/Sources/WakilKit/Harness/ResumeBroker.swift`
- Create: `app/Tests/WakilKitTests/ResumeBrokerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:

```swift
public struct ResumeRequest: Sendable, Equatable {
    public let sessionId: String
    public init(sessionId: String)
}
public actor ResumeBroker {
    public init()
    public func request(_ r: ResumeRequest)
    public func requests() -> AsyncStream<ResumeRequest>
}
```

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import WakilKit

@Test func aParkedRequestReachesTheSubscriber() async {
    let broker = ResumeBroker()
    let stream = await broker.requests()
    await broker.request(ResumeRequest(sessionId: "s-1"))

    var seen: ResumeRequest?
    for await r in stream {
        seen = r
        break
    }
    #expect(seen?.sessionId == "s-1")
}

// The whole reason this is not ConfirmationBroker: `request` must not
// suspend until something happens to the request, because the caller is
// an MCP handler whose process is about to be replaced by the very swap
// it is asking for. It parks and returns.
@Test func requestDoesNotWaitForTheRequestToBeHandled() async {
    let broker = ResumeBroker()
    _ = await broker.requests()          // a subscriber that never drains
    await broker.request(ResumeRequest(sessionId: "s-1"))
    await broker.request(ResumeRequest(sessionId: "s-2"))
    // Reaching here at all is the assertion: neither call blocked.
    #expect(Bool(true))
}

@Test func requestsBeforeAnySubscriberAreNotLost() async {
    let broker = ResumeBroker()
    await broker.request(ResumeRequest(sessionId: "s-early"))
    let stream = await broker.requests()
    var seen: [String] = []
    for await r in stream {
        seen.append(r.sessionId)
        break
    }
    #expect(seen == ["s-early"])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL to compile — no `ResumeBroker`.

- [ ] **Step 3: Write the minimal implementation**

```swift
import Foundation

/// One request to leave the current agent session and fork a past one.
public struct ResumeRequest: Sendable, Equatable {
    /// The session to fork from — the parent. The child's id is minted by
    /// whoever performs the swap, because Wakil mints every session id it
    /// runs.
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// Where a resume request waits for the window to act on it.
///
/// **Deliberately not `ConfirmationBroker`, whose `request` suspends until
/// a human decides.** A resume swaps the agent process, so the MCP handler
/// that asked for it is about to be killed by its own request: a reply
/// sent after the swap can never arrive, because the shim's socket dies
/// with `claude`. So this parks and returns, the handler answers
/// immediately, and the window performs the swap on its own next turn —
/// by which time the agent has its result.
///
/// One buffered request survives a period with no subscriber: the window
/// subscribes in `init`, so in practice there always is one, but an
/// unbuffered stream would make the ordering between subscribing and the
/// first request load-bearing for no reason.
public actor ResumeBroker {
    private var continuations: [UUID: AsyncStream<ResumeRequest>.Continuation] = [:]
    private var buffered: [ResumeRequest] = []

    public init() {}

    public func request(_ r: ResumeRequest) {
        guard !continuations.isEmpty else {
            buffered.append(r)
            return
        }
        for (_, k) in continuations {
            k.yield(r)
        }
    }

    public func requests() -> AsyncStream<ResumeRequest> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            for r in buffered {
                continuation.yield(r)
            }
            buffered.removeAll()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.drop(id) }
            }
        }
    }

    private func drop(_ id: UUID) {
        continuations[id] = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Harness/ResumeBroker.swift app/Tests/WakilKitTests/ResumeBrokerTests.swift
git commit -m "A broker that parks a resume and returns

Not ConfirmationBroker, which suspends its caller until a human
decides. A resume kills the process that asked for it, so a reply sent
after the swap can never arrive — the handler has to answer first and
let the window act on its own next turn."
```

---

### Task 9: The actions — `session_resume` resumes, `session_get` reads

**Files:**
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift:124-129` (signature), `:259-281` (the old `session_resume`), `:283-300` (`session_list`'s description)
- Modify: `app/Sources/WakilKit/App/AppWiring.swift:128-131` (pass the broker), and `WakilWiring`'s stored properties
- Modify: `app/Tests/WakilKitTests/StandardActionsTests.swift:131,302,482`, `app/Tests/WakilKitTests/AppWiringTests.swift:161`, `app/Tests/WakilKitTests/WindowModelTests.swift:626`
- Test: `app/Tests/WakilKitTests/StandardActionsTests.swift`

**Interfaces:**
- Consumes: `ResumeBroker` (Task 8).
- Produces: `registerStandardActions(into:context:panes:db:resumes:)`; actions `session_resume` (`.control`) and `session_get` (`.read`); `WakilWiring.resumes: ResumeBroker`.

- [ ] **Step 1: Write the failing test**

In `StandardActionsTests.swift`:

```swift
@Test func sessionResumeIsControlAndSessionGetIsRead() async throws {
    let (registry, _, broker) = try await standardRegistryWithResumeBroker()
    let byName = Dictionary(uniqueKeysWithValues: await registry.all().map { ($0.name, $0) })
    #expect(byName["session_resume"]?.kind == .control)
    #expect(byName["session_get"]?.kind == .read)
    _ = broker
}

@Test func sessionResumeParksTheRequestAndReturnsWithoutWaiting() async throws {
    let (registry, _, broker) = try await standardRegistryWithResumeBroker()
    let stream = await broker.requests()

    let result = try await registry.dispatch(
        name: "session_resume", params: .object(["id": .string("parent-7")]),
        origin: .agent, environment: "staging", confirmation: nil)

    // The handler answered rather than blocking on the swap.
    #expect("\(result)".contains("parent-7"))

    var seen: String?
    for await r in stream {
        seen = r.sessionId
        break
    }
    #expect(seen == "parent-7")
}

@Test func sessionResumeRefusesAMissingId() async throws {
    let (registry, _, _) = try await standardRegistryWithResumeBroker()
    await #expect(throws: (any Error).self) {
        _ = try await registry.dispatch(
            name: "session_resume", params: .object([:]),
            origin: .ui, environment: "staging", confirmation: nil)
    }
}
```

Write `standardRegistryWithResumeBroker()` beside the file's existing registry helper, returning `(ActionRegistry, PaneStore, ResumeBroker)` and calling `registerStandardActions(into:context:panes:db:resumes:)` with `context: nil, db: nil`.

Update the three name-set assertions to include `session_get` and keep `session_resume`:
- `StandardActionsTests.swift:131` — add `"session_get"` to the expected set.
- `StandardActionsTests.swift:302` — the params map: add `"session_get": .object(["id": .string("abc")])`.
- `StandardActionsTests.swift:482` — change to `#expect(byName["session_get"]?.kind == .read)`.
- `AppWiringTests.swift:161` — add `"session_get"`.
- `WindowModelTests.swift:626` — the `agentAllowedTools` expectation gains `mcp__wakil__session_get`; `mcp__wakil__session_resume` stays, because `.control` is published.

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL — `registerStandardActions` takes no `resumes:`.

- [ ] **Step 3: Write the minimal implementation**

`registerStandardActions` gains `resumes: ResumeBroker`. Replace the old `session_resume` registration with two:

```swift
    // Renamed from `session_resume`, which now does what its name says.
    // This is the metadata read it used to be, unchanged.
    await registry.register(Action(
        name: "session_get",
        description: "Get metadata, title and first prompt for one session.",
        kind: .read,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            guard let context else {
                throw StandardActionError.missingClient(action: "session_get", role: "context")
            }
            let id = try requireStringParam(params, "id", action: "session_get")
            return try await callChecked(
                context, tool: "get_session", arguments: .object(["id": .string(id)]),
                action: "session_get", timeout: MCPClient.readReplyTimeout)
        }
    ))

    // `.control` by the kind's own definition: it changes Wakil's own
    // state and leaves the world outside Wakil untouched, so the
    // environment never blocks it. That makes `agentAllowedTools` publish
    // it — it filters on `.read || .control` and excludes `.mutate` by
    // KIND, never by name — and no name-based exception is added here,
    // which would be the first of its kind.
    //
    // **It parks and returns rather than performing the swap.** The agent
    // that calls this is about to be replaced by the session it asked
    // for, and the shim's socket dies with the `claude` process, so a
    // reply sent after the swap could never arrive. The window does the
    // work on its own next turn — by which time this answer has already
    // been delivered.
    await registry.register(Action(
        name: "session_resume",
        description:
            "Leave the current agent session and continue a past one, forking it under a new "
            + "session id so the original transcript is untouched. Returns as soon as the "
            + "request is accepted; the switch happens immediately afterwards and ends the "
            + "calling session.",
        kind: .control,
        schema: .object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("string")])]),
            "required": .array([.string("id")]),
        ]),
        handler: { params in
            let id = try requireStringParam(params, "id", action: "session_resume")
            await resumes.request(ResumeRequest(sessionId: id))
            return .object([
                "resuming": .string(id),
                "note": .string("this session ends as the fork starts"),
            ])
        }
    ))
```

In `AppWiring.swift`: build `let resumes = ResumeBroker()`, pass it to `registerStandardActions`, and add it to `WakilWiring`'s stored properties and initialiser alongside `confirmations`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/Registry/StandardActions.swift app/Sources/WakilKit/App/AppWiring.swift app/Tests/WakilKitTests/
git commit -m "session_resume resumes; session_get is the read it used to be

The old session_resume read a session's metadata and stopped, so the
name belonged to the action that actually resumes. It is .control by
the kind's own definition, which publishes it to the agent with no
name-based exception, and it parks its request and returns rather than
swapping — the caller is about to be replaced by what it asked for."
```

---

### Task 10: `WindowModel` — a factory, a pump that restarts, a thread that rebuilds

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:201-250` (`ThoughtRow`/`thoughtRow`), `:560-620` (properties), `:676-745` (initialisers), `:1385-1440` (`send`, `startEventPump`), `:1500-1507` (`shutdown`)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `ResumeBroker`/`ResumeRequest` (Task 8), `AgentHarness.start(sessionId:resumingFrom:workingDirectory:)` (Task 7), `read_session` via the registry (Task 5).
- Produces on `WindowModel`: `init(..., harnessFactory: @Sendable () -> AgentHarness?, resumes: ResumeBroker, rootPath: String, providerId: String, ...)`; `public func resume(sessionId: String) async`; `static let rebuiltThreadLimit = 200`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func resumingReplacesTheHarnessAndRestartsTheEventPump() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()          // hands out a fresh StubHarness per call
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")

    await model.send("first")
    let first = harnesses.issued[0]
    #expect(await first.log.entries.contains { $0.hasPrefix("start:") })

    await model.resume(sessionId: "parent-1")

    // The old one was stopped, a new one started as a fork.
    #expect(await first.log.entries.contains("stop"))
    let second = harnesses.issued[1]
    let started = await second.log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.contains(":parent-1:"))

    // And the new stream is being drained: an event on the SECOND harness
    // reaches `thoughts`, which only happens if the pump was replaced.
    second.continuation.yield(.assistantText("from the fork"))
    await waitUntil { await model.thoughts.contains { $0.detail == "from the fork" } }
}

@Test func aResumedSessionRunsInTheDirectoryTheTranscriptRecords() async throws {
    // read_session returns cwd; the launch must use it rather than the
    // project's first root.
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/other-root", entries: [])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")

    await model.resume(sessionId: "parent-1")
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.hasSuffix(":/Users/x/other-root"))
}

@Test func aFreshSessionRunsInTheProjectsFirstRoot() async throws {
    let (registry, panes, layout) = try makeRegistry()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")
    await model.send("hello")
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.hasSuffix(":/Users/x/proj"))
    #expect(started.contains(":-:"))     // resumingFrom nil
}

@Test func theRebuiltThreadCarriesASeamNamingTheParent() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [
        ("user", "run the query", "", false),
        ("assistant", "on it", "", false),
    ])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")

    await model.resume(sessionId: "parent-1")
    let details = await model.thoughts.map(\.detail)
    #expect(details.contains("run the query"))
    #expect(details.contains { $0.contains("parent-1") })
    // The seam is last, so the six-row window shows it (design-language §9).
    #expect(await model.thoughts.last!.detail.contains("parent-1"))
}

@Test func rebuiltRowIdsDoNotCollideWithLiveOnes() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [
        ("assistant", "one", "", false), ("assistant", "two", "", false),
    ])
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")

    await model.resume(sessionId: "parent-1")
    harnesses.issued[0].continuation.yield(.assistantText("live"))
    await waitUntil { await model.thoughts.contains { $0.detail == "live" } }
    let ids = await model.thoughts.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func resumingAcrossProvidersIsRefusedAndNamesBoth() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [], provider: "work")
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: ResumeBroker(),
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")

    await model.resume(sessionId: "parent-1")
    #expect(await model.status.contains("work"))
    #expect(await model.status.contains("main"))
    #expect(harnesses.issued.isEmpty)     // nothing was launched
}

@Test func aParkedResumeRequestIsActedOn() async throws {
    let (registry, panes, layout) = try makeRegistry()
    await registerFakeReadSession(into: registry, cwd: "/Users/x/proj", entries: [])
    let broker = ResumeBroker()
    let harnesses = HarnessBox()
    let model = WindowModel(
        registry: registry, panes: panes, layout: layout, context: nil,
        harnessFactory: { harnesses.next() }, resumes: broker,
        rootPath: "/Users/x/proj", providerId: "main", environment: "staging")
    _ = model

    await broker.request(ResumeRequest(sessionId: "parent-1"))
    await waitUntil { !harnesses.issued.isEmpty }
    let started = await harnesses.issued[0].log.entries.first { $0.hasPrefix("start:") }!
    #expect(started.contains(":parent-1:"))
}
```

Write two helpers in the same file:

```swift
/// Hands out a fresh `StubHarness` per call and keeps every one it issued,
/// so a test can assert on the harness *before* a resume and the one
/// *after* it independently.
private final class HarnessBox: @unchecked Sendable {
    private(set) var issued: [StubHarness] = []
    func next() -> AgentHarness? {
        let h = StubHarness()
        issued.append(h)
        return h
    }
}

/// Registers a `read_session` action returning a fixed thread, so
/// `WindowModel`'s resume path can be tested without `wakil-ctx`.
private func registerFakeReadSession(
    into registry: ActionRegistry, cwd: String,
    entries: [(kind: String, text: String, tool: String, isError: Bool)],
    provider: String = "main", parent: String = ""
) async {
    await registry.register(Action(
        name: "session_read", description: "test double", kind: .read,
        schema: .object(["type": .string("object")]),
        handler: { _ in
            .object(["structuredContent": .object([
                "cwd": .string(cwd),
                "provider": .string(provider),
                "parent": .string(parent),
                "truncated": .bool(false),
                "entries": .array(entries.map { e in
                    .object([
                        "kind": .string(e.kind), "text": .string(e.text),
                        "toolName": .string(e.tool), "isError": .bool(e.isError),
                    ])
                }),
            ])])
        }
    ))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL to compile — `WindowModel` has no `harnessFactory:` parameter and no `resume`.

- [ ] **Step 3: Write the minimal implementation**

Register a `session_read` action in `StandardActions.swift` wrapping `read_session` (same pattern as `session_get`, `.read`, params `id` and `limit`) — the model reads the thread through the registry like everything else, so the read is journaled.

In `WindowModel.swift`:

1. Replace the stored `private let harness: AgentHarness?` with:

```swift
    /// Builds a harness for one session. A factory rather than an
    /// instance, because a resume is a new process: `stop()` makes a
    /// `ClaudeCodeCLIHarness` spent, and `events()` refuses a second
    /// consumer, so the only correct way to continue a conversation is a
    /// new instance. `nil` is the ordinary degraded launch — no provider
    /// environment — and says so rather than appearing to send.
    private let harnessFactory: @Sendable () -> AgentHarness?
    private var harness: AgentHarness?
    private let resumes: ResumeBroker
    private var resumePump: Task<Void, Never>?
    /// The directory a FRESH session runs in: the project's first declared
    /// root. A resumed session runs in its own recorded cwd instead.
    private let rootPath: String
    /// The provider this window's credentials belong to, from
    /// `WAKIL_PROVIDER`. A session found under another provider cannot be
    /// resumed here, and saying which is why is 2b-vi's hook.
    private let providerId: String
    public static let rebuiltThreadLimit = 200
```

2. Both initialisers take `harnessFactory:`, `resumes:`, `rootPath:` and `providerId:` in place of `harness:`. In the designated initialiser, after the confirmation pump, start the resume pump:

```swift
        // Subscribed in `init`, not lazily: a resume can be dispatched by
        // the agent or by `--dispatch` before this window has ever sent
        // anything, and a request parked into a broker nobody is draining
        // is a request that silently never happens.
        resumePump = Task { [weak self] in
            for await request in await resumes.requests() {
                guard let self else { return }
                await self.resume(sessionId: request.sessionId)
            }
        }
```

3. `send` calls the factory on first use:

```swift
    public func send(_ text: String) async {
        if harness == nil, sessionId == nil {
            harness = harnessFactory()
        }
        guard let harness else { ... unchanged refusal ... }
        do {
            if sessionId == nil {
                let id = UUID().uuidString
                try await harness.start(sessionId: id, resumingFrom: nil, workingDirectory: rootPath)
                sessionId = id
                startEventPump(harness)
            }
            ...unchanged...
```

4. `startEventPump` replaces rather than refuses:

```swift
    /// Drains `events()` into `thoughts` for as long as *this* session
    /// lives.
    ///
    /// Cancel-and-replace rather than start-once: 2b-v swaps the harness
    /// on a resume, and a pump still draining the old instance's finished
    /// stream would leave the new one's events unread. Each instance still
    /// has exactly one consumer, which is what `events()`'s
    /// `preconditionFailure` requires.
    private func startEventPump(_ harness: AgentHarness) {
        eventPump?.cancel()
        eventPump = Task { [weak self] in
            for await event in harness.events() {
                guard let self else { return }
                self.append(event)
            }
        }
    }
```

5. The resume path:

```swift
    /// Leaves the current agent session and forks a past one.
    ///
    /// Every resume is a fork — see `buildLaunch` for why continuing in
    /// place is not offered — so this mints a fresh id, records the
    /// lineage, and leaves the parent's transcript untouched.
    ///
    /// Refusals land in `status` rather than throwing: this is reached
    /// from a palette selection and from a parked agent request, neither
    /// of which has anywhere to throw to.
    public func resume(sessionId parent: String) async {
        let thread: SessionThreadSnapshot
        do {
            thread = try await readThread(parent)
        } catch {
            status = "resume \(parent): \(error)"
            return
        }
        guard thread.provider == providerId else {
            status = "resume \(parent): that session belongs to provider "
                + "\(thread.provider), and this window is running \(providerId)"
            return
        }
        guard let next = harnessFactory() else {
            status = "resume \(parent): no agent session available"
            return
        }
        await harness?.stop()
        eventPump?.cancel()
        eventPump = nil

        thoughts = rebuiltThread(thread, parent: parent)
        turnInFlight = false

        let child = UUID().uuidString
        do {
            try await next.start(
                sessionId: child, resumingFrom: parent, workingDirectory: thread.cwd)
        } catch {
            status = "resume \(parent): \(error)"
            harness = nil
            self.sessionId = nil
            return
        }
        harness = next
        self.sessionId = child
        startEventPump(next)
        status = ""
        // Best effort, and after the swap: a lineage record that failed to
        // write costs ⌘P a grouping, while a resume that refused because
        // of it would cost the operator the session.
        _ = try? await registry.dispatch(
            name: "session_record_parent",
            params: .object(["child": .string(child), "parent": .string(parent)]),
            origin: .ui, environment: environment, confirmation: nil)
    }

    /// Maps a read thread into rows, oldest first, with the seam last so
    /// the six-row window shows it.
    private func rebuiltThread(_ thread: SessionThreadSnapshot, parent: String) -> [ThoughtRow] {
        nextThoughtId = 0
        var rows: [ThoughtRow] = []
        for entry in thread.entries.suffix(Self.rebuiltThreadLimit) {
            rows.append(ThoughtRow(
                id: nextThoughtId, label: entry.label, detail: entry.detail, isError: entry.isError))
            nextThoughtId += 1
        }
        var seam = "resumed from \(parent)"
        if thread.truncated { seam += " (earlier turns not shown)" }
        rows.append(ThoughtRow(id: nextThoughtId, label: "resumed", detail: seam, isError: false))
        nextThoughtId += 1
        return rows
    }
```

Write `SessionThreadSnapshot` (a small `Sendable` struct with `entries: [(label:String, detail:String, isError:Bool)]`, `cwd`, `provider`, `parent`, `truncated`) and `readThread(_:)`, which dispatches `session_read` with `limit: Self.rebuiltThreadLimit` and decodes `structuredContent`. Map `kind` to a label with the same words `thoughtRow` uses — `assistant` → `"assistant"`, `tool` → `"tool"`, `toolResult` → `"tool result"` — and `user` → `"you"`, which is the one label a live thread never produces (spec §4.1).

6. `shutdown()` also cancels `resumePump`.

Also register a `session_record_parent` action (`.control`) in `StandardActions.swift` wrapping `record_session_parent`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Sources/WakilKit/Registry/StandardActions.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "Resume: replace the harness, rebuild the thread

A factory rather than an injected instance, because stop() makes a
harness spent and events() refuses a second consumer — so continuing a
conversation is a new process, and the pump has to be replaced with it.
The thread is rebuilt from the transcript with a seam naming the parent
last, so the six-row window shows it. Two refusals land in status: a
session belonging to another provider, which is 2b-vi's hook, and a
read that failed."
```

---

### Task 11: Wire the window, and draw the seam

**Files:**
- Modify: `app/Sources/WakilApp/WindowSession.swift:34-146`
- Modify: `app/Sources/WakilKit/Context/ContextStore.swift:43-53` (`ActiveContext` gains `rootPaths`)
- Modify: `app/Sources/WakilApp/ThoughtThread.swift`
- Test: `app/Tests/WakilKitTests/ContextStoreTests.swift`, `app/Tests/WakilKitTests/AppWiringTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–10.
- Produces: `ActiveContext.rootPaths: [String]`; a `WindowSession` that passes a factory, the first root and `WAKIL_PROVIDER`.

- [ ] **Step 1: Write the failing test**

In `ContextStoreTests.swift`:

```swift
@Test func activeContextCarriesTheResolvedRootPaths() throws {
    // get_context reports rootPaths as absolute, resolved paths — Swift
    // must not re-derive them, because a root may be relative to the
    // project directory and that rule lives in Go.
    let structured = JSONValue.object([
        "Org": .string("acme"),
        "Project": .object(["name": .string("widgets")]),
        "Environment": .string("dev"),
        "rootPaths": .array([.string("/Users/x/widgets"), .string("/Users/x/widgets/src")]),
    ])
    let parsed = try ContextStore.parseActiveContext(structured)
    #expect(parsed.rootPaths == ["/Users/x/widgets", "/Users/x/widgets/src"])
}
```

If `ContextStore` currently parses inline inside `current()`, extract the parsing into an `internal static func parseActiveContext(_:) throws -> ActiveContext` first so it can be tested without a client, and have `current()` call it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL — no `rootPaths` on `ActiveContext`.

- [ ] **Step 3: Write the minimal implementation**

`ActiveContext` gains `public let rootPaths: [String]`, parsed from the top-level `rootPaths` key, defaulting to `[]` when absent (an older `wakil-ctx` binary in `bin/` must not crash the window).

`WindowSession.start()`:

- keep the launch-time `sessionId` for `WakilWiring.build` and the socket path, and say in a comment that a resume does not change it, because the journal is per window;
- build a `harnessFactory` closure capturing `credentials`, `configJSON` and `allowedTools`, returning a **new** `ClaudeCodeCLIHarness` per call;
- read the first root: `let firstRoot = (try? await ContextStore(client: contextClient).current().rootPaths.first) ?? home` — resolve it before constructing the model, and append a note when it falls back, because a window launched with no readable project cannot know where to run;
- pass `resumes: wiring.resumes`, `providerId: environment["WAKIL_PROVIDER"] ?? ""`, `rootPath: firstRoot`.

`ThoughtThread.swift` — give the seam its treatment. `ThoughtRow` has no kind field, so match on the label:

```swift
    /// The resume seam. Dimmer than a completed step and italic: it is not
    /// something the agent did, it is a statement about where the rest of
    /// the rows came from. §9's palette otherwise applies unchanged.
    private func isSeam(_ row: ThoughtRow) -> Bool { row.label == "resumed" }
```

Apply `.italic()` and a lower opacity to a seam row's detail text, reusing the existing `colour(for:)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilApp/ app/Sources/WakilKit/Context/ContextStore.swift app/Tests/WakilKitTests/
git commit -m "Wire the window: a harness per session, the first root, the seam

The window hands WindowModel a factory instead of a harness, learns the
project's first root from get_context rather than re-deriving relative
roots in Swift, and names the provider its credentials belong to. The
seam row reads as a statement about the rows above it rather than as
something the agent did."
```

---

### Task 12: ⌘P shows titles and collapses a chain

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift:1224-1242` (`sessionPaletteItems`)
- Test: `app/Tests/WakilKitTests/WindowModelTests.swift`

**Interfaces:**
- Consumes: `session_list`'s `title`, `cwd`, `parent` (Tasks 2, 4, 5).
- Produces: no new API; behaviour only.

- [ ] **Step 1: Write the failing test**

```swift
@Test func thePaletteShowsATitleWhenTheSessionHasOne() async throws {
    let items = sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "title": .string("booking bug"),
         "firstPrompt": .string("why does the booking")],
    ])
    #expect(items.first?.title == "booking bug")
    #expect(items.first?.payload == "s1")
}

@Test func thePaletteFallsBackToTheFirstPromptThenTheId() async throws {
    let withPrompt = sessionItems(from: [
        ["id": .string("s1"), "provider": .string("main"), "firstPrompt": .string("why does the booking")],
    ])
    #expect(withPrompt.first?.title == "why does the booking")
    let bare = sessionItems(from: [["id": .string("s2"), "provider": .string("main")]])
    #expect(bare.first?.title == "s2")
}

// A chain of forks is one conversation. Newest-first ordering means the
// child arrives before its parent, so the child is what the operator
// picks and the parent is folded into it.
@Test func aChainOfForksCollapsesToItsNewestMember() async throws {
    let items = sessionItems(from: [
        ["id": .string("child"), "provider": .string("main"), "title": .string("booking bug"),
         "parent": .string("parent")],
        ["id": .string("parent"), "provider": .string("main"), "title": .string("booking bug")],
    ])
    #expect(items.count == 1)
    #expect(items.first?.payload == "child")
    #expect(items.first?.subtitle.contains("resumed") == true)
}

@Test func unrelatedSessionsAreNotCollapsed() async throws {
    let items = sessionItems(from: [
        ["id": .string("a"), "provider": .string("main")],
        ["id": .string("b"), "provider": .string("main")],
    ])
    #expect(items.count == 2)
}
```

Write `sessionItems(from:)` beside it: build the `["sessions": .array(...)]` structure and call the extracted pure mapper.

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build && make app-test`
Expected: FAIL — no such mapper, and no collapsing.

- [ ] **Step 3: Write the minimal implementation**

Extract the row-mapping half of `sessionPaletteItems` into an `internal static func sessionItems(from rows: [JSONValue]) -> [PaletteItem]` so it is testable without a registry, and have `sessionPaletteItems` call it. In the mapper:

- title: `title` → `firstPrompt` → `id`;
- subtitle: the provider, plus `"resumed"` and the count when the entry absorbed a chain;
- collapsing: walk rows in order (already newest-first), keep a set of ids that appeared as some other row's `parent`, and drop any row whose id is in that set. A parent whose child is not in this listing is kept — it is a session in its own right, and dropping it would hide it entirely.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make build && make app-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/WakilKit/App/WindowModel.swift app/Tests/WakilKitTests/WindowModelTests.swift
git commit -m "⌘P: titles, and one entry per conversation

A session's title beats 200 runes of its first prompt as a label, and a
chain of forks is one conversation rather than one entry per resume. A
parent whose child is not in the listing is kept — it is a session in
its own right."
```

---

### Task 13: The acceptance runbook, and the documents that claim this is done

**Files:**
- Create: `docs/wakil/phase-2b-v-acceptance.md`
- Modify: `docs/wakil/north-star.md:8` (the 2b sub-phase table's 2b-v row; add open question 5's amendment)
- Modify: `docs/wakil/operator-todo.md`

**Interfaces:**
- Consumes: everything.
- Produces: a runbook whose every check is marked **not yet run**.

- [ ] **Step 1: Write the runbook**

`docs/wakil/phase-2b-v-acceptance.md`, in the shape of `permission-prompt-acceptance.md`: a header pinning the CLI at 2.1.266 and naming the spec and probe, a §1 of prerequisites (`make build`, a project whose first root is real, `WAKIL_PROVIDER` set, at least two past sessions in that root — one made by Wakil and one made by hand in a terminal), then §2's standing checks, each with a result table whose only row reads `| _not yet run_ | | |`:

1. **The list is not empty.** ⌘P shows sessions Wakil itself created. This is the check that would have failed before this sub-phase, and it is the cheapest proof the cwd fix works.
2. **Titles read as titles.** Entries are recognisable without opening them.
3. **One entry per conversation.** Resume the same session twice; ⌘P still shows one entry for it, not three.
4. **Continuity, by asking.** Resume a session and ask it something only that conversation knows. Judge the answer, not the absence of an error.
5. **The thread reads as continued.** Does the rebuilt thread read as the same conversation, and does the seam read as a seam rather than as an error?
6. **The parent is untouched.** After resuming, the original transcript has gained no records. Check on disk, not in the window.
7. **A live agent resumes.** Ask the agent to resume a session by name. It should answer before it disappears, and the new session should be the one that continues.
8. **The provider refusal.** Try to resume a session belonging to another provider. The refusal should name both.
9. **The write gate still gates.** Propose a mutation *in a resumed session*. Probe §4 measured the bridge surviving a resume; this is the same claim judged by eye at the plane.
10. **Nothing scrambles.** Resume a session that is open in a terminal at the same time. Both should proceed, and the two transcripts should be separate files.

Include a §3 of headless checks with exact commands (`go test ./...`, `make app-test` and the expected count, a `--dispatch` invocation of `session_resume`, and a `jq` over `~/.wakil/orgs/<org>/sessions.json`), and a §0 stating plainly that the implementation being complete is not the same claim as the sub-phase being met.

- [ ] **Step 2: Update the phase map honestly**

In `north-star.md` §8, change 2b-v's **Exit** cell to record the shape actually built — *"⌘P lists this org's past sessions and picking one forks it into a new Wakil-minted session that continues it, with its thought thread rebuilt"* — and add, in the paragraphs below the table, that **2b-v is implemented, not met**, naming `docs/wakil/phase-2b-v-acceptance.md` and its ten unwalked checks, in the same words 2b-ii's and 2b-iv's entries use.

Amend open question 5's closed answer with one sentence: resume arrived in 2b-v as a fork, so *"Wakil assigns the id"* still holds — and note that the listing was always a directory scan rather than a record of minted ids, which is what its original wording implied.

- [ ] **Step 3: Update the operator TODO**

Add a section naming what only the operator can do here: walk the runbook, and confirm check 10 on a real terminal session. Note that no credential is needed beyond the provider already registered.

- [ ] **Step 4: Verify the whole suite**

Run: `make build && go test ./... && make app-test`
Expected: PASS. Record the Swift test count in the runbook's §3 as the number to expect.

- [ ] **Step 5: Commit**

```bash
git add docs/
git commit -m "2b-v's acceptance runbook, unwalked, and an honest phase map

Ten checks, every one marked not yet run. 2b-ii's lesson is that a
sub-phase whose value is a human judgement gets marked implemented and
then treated as met; the row says implemented, not met, until someone
walks this."
```

---

## Self-Review

**Spec coverage.** §4.1 `read_session` → Task 3, exposed in Task 5. §4.2 `cwd`/`title` → Task 2. §4.3 lineage → Task 4. §5 the two argv shapes → Task 6. §5.1 the cwd defect and the first-root/own-cwd rule → Tasks 6, 7 (`currentDirectoryURL`), 10 (which directory), 11 (learning the root). §6 the protocol and the factory → Tasks 7, 10. §7's two refusals → Task 10 (provider), Task 3 (cwd). §8's three actions → Task 9, plus `session_read` and `session_record_parent` in Tasks 9–10. §9 the rebuilt thread, seam and cap → Tasks 10, 11. §10's file table → Tasks 1–12. §11 verification → each task's tests, plus Task 13's runbook for what tests cannot cover. §12/§13 need no code.

**Two additions the spec's §10 file table does not list**, both required by the design and worth noting rather than smuggling: `session_read` and `session_record_parent` registry actions (the model reads and writes through the registry like everything else, so both are journaled), and `ContextStore.ActiveContext.rootPaths` (Task 11) with `Resolved.RootPaths` behind it (Task 1) — because Swift must not re-implement Go's relative-root resolution.

**Type consistency.** `SessionThread`/`ThreadEntry` (Go) are consumed as `SessionThreadSnapshot` (Swift, Task 10) — deliberately different names for the wire type and the in-app value, decoded in one place. `ProjectRootPaths(r Resolved)` takes a value, and `Resolve()` populates `RootPaths` with it. `start(sessionId:resumingFrom:workingDirectory:)` is spelled identically in Tasks 6, 7 and 10 and in `StubHarness`. `rebuiltThreadLimit` is the single source of the 200 and is passed as `read_session`'s `limit`, so Go's `truncated` and Swift's seam text cannot disagree.

**Ordering constraint.** Task 3 references `SessionParent`, which Task 4 creates. The step says to stub it and delete the stub in Task 4; a subagent executing Task 3 alone must do that or its package will not build.
