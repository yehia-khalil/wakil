package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestEncodeRootPath(t *testing.T) {
	cases := map[string]string{
		"/Users/operator/conductor/workspaces/wakil/amsterdam": "-Users-operator-conductor-workspaces-wakil-amsterdam",
		"/Users/operator/Desktop/scripts/wakil":                "-Users-operator-Desktop-scripts-wakil",
		"/Users/operator/.claude":                              "-Users-operator--claude",
		// Measured, not assumed. The Phase 1 acceptance run started a real
		// Claude Code session in /Users/operator/wakil.acceptance and Claude
		// Code created exactly this directory under its projects dir, which
		// is what closed the long-open question of whether a MID-SEGMENT dot
		// really collapses to "-". The other dotted case above ("/.claude")
		// only ever demonstrated a LEADING dot. See EncodeRootPath's doc
		// comment.
		"/Users/operator/wakil.acceptance": "-Users-operator-wakil-acceptance",
	}
	for in, want := range cases {
		if got := EncodeRootPath(in); got != want {
			t.Errorf("EncodeRootPath(%q)=%q want %q", in, got, want)
		}
	}
}

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
	got := ProjectRootPaths(*r)
	want := []string{projDir, filepath.Join(projDir, "src"), elsewhere}
	if !slices.Equal(got, want) {
		t.Errorf("ProjectRootPaths = %v, want %v", got, want)
	}
	if !slices.Equal(r.RootPaths, want) {
		t.Errorf("Resolved.RootPaths = %v, want %v", r.RootPaths, want)
	}
}

// --- fixture helpers -------------------------------------------------------

// writeProjectWithRoots writes a project.json under <dir>/.wakil/project.json
// with the given roots, and returns that path.
func writeProjectWithRoots(t *testing.T, dir, name, org string, roots []Root) string {
	t.Helper()
	wakilSub := filepath.Join(dir, ".wakil")
	if err := os.MkdirAll(wakilSub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	p := Project{Name: name, Org: org, Roots: roots, Environments: map[string]Environment{}}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal project: %v", err)
	}
	path := filepath.Join(wakilSub, "project.json")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatalf("write project.json: %v", err)
	}
	return path
}

// activateProject registers projectPath under name in the current org's
// registry and makes it the active project via SetProjectChecked.
func activateProject(t *testing.T, name, projectPath string) {
	t.Helper()
	org, err := CurrentOrg()
	if err != nil {
		t.Fatalf("CurrentOrg: %v", err)
	}
	if err := SaveRegistry(org, map[string]ProjectEntry{name: {Path: projectPath}}); err != nil {
		t.Fatalf("SaveRegistry: %v", err)
	}
	if err := SetProjectChecked(name); err != nil {
		t.Fatalf("SetProjectChecked(%s): %v", name, err)
	}
}

// writeSessionFile writes a fake Claude Code session transcript at
// <claudeConfigDir>/projects/<dirName>/<sessionID>.jsonl containing one JSON
// line per record.
func writeSessionFile(t *testing.T, claudeConfigDir, dirName, sessionID string, records []map[string]any) string {
	t.Helper()
	dir := filepath.Join(claudeConfigDir, "projects", dirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir session dir: %v", err)
	}
	var sb strings.Builder
	for _, rec := range records {
		b, err := json.Marshal(rec)
		if err != nil {
			t.Fatalf("marshal record: %v", err)
		}
		sb.Write(b)
		sb.WriteByte('\n')
	}
	path := filepath.Join(dir, sessionID+".jsonl")
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		t.Fatalf("write session file: %v", err)
	}
	return path
}

// setupHome sets HOME to a fresh temp location, pins WAKIL_ORG (session
// discovery's activateProject helper needs a valid org to set the active
// project), registers a single claude-code provider "primary" and returns
// (home, that provider's config dir).
//
// It deliberately does NOT set CLAUDE_CONFIG_DIR, which every test here
// used to rely on. Session discovery now enumerates the org's provider
// records and reads nothing ambient, so the store a test writes into has
// to be a REGISTERED one; setting the variable too would be dead
// configuration that reads as if it still selected the store.
//
// The returned path is the pre-EvalSymlinks one (on macOS t.TempDir is
// under /var, a symlink to /private/var, and AddProvider records the
// resolved path). Both name the same directory, so writing through this
// one lands in the store the provider record points at; a test that
// compares the two as strings must resolve first.
func setupHome(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatalf("CreateOrg: %v", err)
	}
	claudeConfigDir := filepath.Join(home, ".claude-initech")
	// AddProvider requires the config dir to exist, so create it here.
	// Its projects/ subdirectory is left absent: writeSessionFile makes it
	// on demand, and TestListSessions_NoProjectsDirReturnsNoError depends
	// on it staying absent.
	if err := os.MkdirAll(claudeConfigDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := AddProvider("initech", Provider{ID: "primary", Kind: ProviderKindClaudeCode, ConfigDir: claudeConfigDir}); err != nil {
		t.Fatalf("AddProvider: %v", err)
	}
	return home, claudeConfigDir
}

// --- ListSessions ------------------------------------------------------

func TestListSessions_ExactMatch(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	dirName := EncodeRootPath(projDir)
	writeSessionFile(t, claudeConfigDir, dirName, "session1", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hello"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want 1: %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "session1" {
		t.Errorf("ID = %q, want %q", sessions.Sessions[0].ID, "session1")
	}
	if sessions.Sessions[0].Root != dirName {
		t.Errorf("Root = %q, want %q", sessions.Sessions[0].Root, dirName)
	}
}

// TestListSessions_CarriesFirstPrompt pins the label ⌘P falls back to when
// the CLI wrote no ai-title: title → firstPrompt → id. Before this, only
// GetSession filled FirstPrompt, so an untitled session showed its id
// (found on the 2d-i walk, 2026-10-07).
func TestListSessions_CarriesFirstPrompt(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "untitled", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "what kinds does customer id have"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want 1: %+v", len(sessions.Sessions), sessions)
	}
	if got, want := sessions.Sessions[0].FirstPrompt, "what kinds does customer id have"; got != want {
		t.Errorf("FirstPrompt = %q, want %q", got, want)
	}
}

// TestListSessions_SiblingWorktreeSubdirectory verifies that a session
// started in a real subdirectory of a registered root — the shape a sibling
// Conductor worktree nested under a shared parent root takes — is matched:
// its on-disk directory name only shares the root's encoded prefix (not an
// exact match), and its cwd is a genuine path-separator-bounded child of the
// root.
func TestListSessions_SiblingWorktreeSubdirectory(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	parentDir := filepath.Join(home, "workspaces", "wakil")
	projPath := writeProjectWithRoots(t, parentDir, "wakil", "initech", []Root{{Path: "."}})
	activateProject(t, "wakil", projPath)

	worktreeDir := filepath.Join(parentDir, "amsterdam")
	dirName := EncodeRootPath(worktreeDir)
	writeSessionFile(t, claudeConfigDir, dirName, "wt-session", []map[string]any{
		{"type": "user", "cwd": worktreeDir, "message": map[string]any{"content": "hello from amsterdam"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want 1: %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "wt-session" {
		t.Errorf("ID = %q, want %q", sessions.Sessions[0].ID, "wt-session")
	}
}

// TestListSessions_RejectsCwdMismatchDespitePrefixMatch is the corrected
// resolution-2 test: a root "proj" and an unrelated sibling directory
// literally named "proj-legacy" both pass the cheap, lossy stage-1 encoded
// prefix filter (their encoded names differ only by "-legacy", which looks
// identical to a real path-separator boundary once encoded). Only the exact
// cwd confirmation in stage 2 can tell them apart. This test fails against
// a filter-only (stage-1-only) implementation.
func TestListSessions_RejectsCwdMismatchDespitePrefixMatch(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// Legitimate session: cwd matches the root exactly.
	goodDirName := EncodeRootPath(projDir)
	writeSessionFile(t, claudeConfigDir, goodDirName, "good-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "real session"}},
	})

	// Unrelated sibling project whose directory name happens to extend the
	// root's encoded prefix by a literal hyphen, not a real path separator.
	legacyDir := filepath.Join(home, "proj-legacy")
	legacyDirName := EncodeRootPath(legacyDir)
	if !strings.HasPrefix(legacyDirName, goodDirName+"-") {
		t.Fatalf("fixture invariant broken: %q is not a prefix-match candidate of %q", legacyDirName, goodDirName)
	}
	writeSessionFile(t, claudeConfigDir, legacyDirName, "legacy-session", []map[string]any{
		{"type": "user", "cwd": legacyDir, "message": map[string]any{"content": "unrelated session"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want 1 (legacy session must be excluded): %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "good-session" {
		t.Errorf("ID = %q, want %q", sessions.Sessions[0].ID, "good-session")
	}
}

// TestListSessions_NoCwdInSiblingDirectoryIsNotLeaked replaces an earlier
// TestListSessions_NoCwdFallsBackToStage1Match, which asserted the OPPOSITE
// — that a transcript with no cwd is accepted on the strength of the
// stage-1 encoded-name match alone. That fallback was the cross-project
// leak this test now pins shut, so the assertion is inverted deliberately
// rather than deleted.
//
// The fixture is the reviewer's, reproduced before the fix: an active
// project at <home>/work/app and an unrelated sibling at
// <home>/work/app-secret, whose encoded directory name extends the root's
// by what is indistinguishable from an encoded separator. The sibling's
// transcript carries no cwd, so stage 2 has nothing to confirm against.
//
// The guard has something to fire on (standing lesson 3): against the
// pre-fix code this fixture returned the sibling's transcript from
// ListSessions and its firstPrompt ("the sibling project's secret prompt")
// from GetSession. Both are asserted here, because GetSession is where the
// listing turns into content on the wire.
func TestListSessions_NoCwdInSiblingDirectoryIsNotLeaked(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	rootDir := filepath.Join(home, "work", "app")
	projPath := writeProjectWithRoots(t, rootDir, "app", "initech", []Root{{Path: "."}})
	activateProject(t, "app", projPath)

	sibDir := filepath.Join(home, "work", "app-secret")
	if !strings.HasPrefix(EncodeRootPath(sibDir), EncodeRootPath(rootDir)+"-") {
		t.Fatalf("fixture invariant broken: %q does not extend %q", EncodeRootPath(sibDir), EncodeRootPath(rootDir))
	}
	const secret = "the sibling project's secret prompt"
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(sibDir), "other", []map[string]any{
		{"type": "user", "message": map[string]any{"content": secret}},
	})
	// A confirmable session of our own, so the listing is not trivially
	// empty and an over-broad fix that dropped everything would show up.
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(rootDir), "mine", []map[string]any{
		{"type": "user", "cwd": rootDir, "message": map[string]any{"content": "mine"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	for _, s := range sessions.Sessions {
		if s.ID == "other" {
			t.Fatalf("sibling project's transcript was listed: %+v", sessions)
		}
	}
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].ID != "mine" {
		t.Fatalf("want exactly the confirmable own session, got %+v", sessions)
	}
	// Dropped for lack of evidence, not confirmed foreign, so Skipped must
	// say the listing may be incomplete — see SessionList.Skipped.
	if sessions.Skipped != 1 {
		t.Errorf("Skipped = %d, want 1 (an unconfirmable transcript is a place we could not look)", sessions.Skipped)
	}

	got, err := GetSession("other")
	if err == nil {
		t.Fatalf("GetSession(other) returned another project's session: %+v", got)
	}
	if strings.Contains(got.FirstPrompt, secret) {
		t.Errorf("GetSession(other) leaked the sibling's first prompt: %q", got.FirstPrompt)
	}
}

// TestListSessions_NoCwdInExactlyMatchingDirectoryIsNotLeaked is the case
// that decided the shape of the fix above, and it is why there is no
// "keep it when the directory matched EXACTLY" carve-out.
//
// EncodeRootPath is many-to-one: "/", "." and a literal "-" all encode to
// "-". So <home>/work/app, <home>/work-app and <home>/work.app produce the
// SAME projects directory, and Claude Code files three different projects'
// transcripts into the one directory that matches this project's root
// EXACTLY. A no-cwd transcript there is therefore exactly as ambiguous as
// one in a hyphen-extended directory — the exact branch is not a safe
// place to skip stage 2 either.
//
// The fixture asserts the collision it depends on before relying on it, so
// it cannot quietly stop being the case it claims to be.
func TestListSessions_NoCwdInExactlyMatchingDirectoryIsNotLeaked(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	rootDir := filepath.Join(home, "work", "app")
	projPath := writeProjectWithRoots(t, rootDir, "app", "initech", []Root{{Path: "."}})
	activateProject(t, "app", projPath)

	for _, sib := range []string{filepath.Join(home, "work-app"), filepath.Join(home, "work.app")} {
		if EncodeRootPath(sib) != EncodeRootPath(rootDir) {
			t.Fatalf("fixture invariant broken: %q encodes to %q, not to the root's %q",
				sib, EncodeRootPath(sib), EncodeRootPath(rootDir))
		}
	}

	enc := EncodeRootPath(rootDir)
	const secret = "secret prompt from the colliding sibling"
	writeSessionFile(t, claudeConfigDir, enc, "foreign", []map[string]any{
		{"type": "user", "message": map[string]any{"content": secret}},
	})
	writeSessionFile(t, claudeConfigDir, enc, "mine", []map[string]any{
		{"type": "user", "cwd": rootDir, "message": map[string]any{"content": "mine"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].ID != "mine" {
		t.Fatalf("an exactly-matching directory name is not proof of ownership; want only 'mine', got %+v", sessions)
	}
	if sessions.Skipped != 1 {
		t.Errorf("Skipped = %d, want 1", sessions.Skipped)
	}
	if got, err := GetSession("foreign"); err == nil {
		t.Errorf("GetSession(foreign) leaked a colliding project's session: %+v", got)
	}
}

// TestListSessions_PrefixMatchRequiresHyphenBoundary pins the
// `name[len(p)] == '-'` test in matchesAnyEncodedPrefix, which nothing
// reached before: <home>/work/appsecret shares the root's encoded prefix
// but continues with "s", not with the encoded separator, so it is not a
// sibling of <home>/work/app and must not even become a candidate.
//
// Skipped is the observable, and that is the point rather than a weakness.
// Both directories' transcripts are correctly ABSENT from Sessions either
// way — stage 2 sees to that — so the only thing the boundary test changes
// is whether an unrelated project's directory gets searched and counted.
// Counting it breaks SessionList.Skipped's documented contract in the
// direction that matters: a caller holding a complete list would be told
// it may be incomplete, and a real permission problem would be hidden in
// the noise. Removing the `name[len(p)] == '-'` conjunct makes this fail.
func TestListSessions_PrefixMatchRequiresHyphenBoundary(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	rootDir := filepath.Join(home, "work", "app")
	projPath := writeProjectWithRoots(t, rootDir, "app", "initech", []Root{{Path: "."}})
	activateProject(t, "app", projPath)

	// Not a sibling: its encoded name extends the root's without a
	// separator, so no path under the root can ever encode to it.
	otherDir := filepath.Join(home, "work", "appsecret")
	otherEnc := EncodeRootPath(otherDir)
	rootEnc := EncodeRootPath(rootDir)
	if !strings.HasPrefix(otherEnc, rootEnc) || strings.HasPrefix(otherEnc, rootEnc+"-") {
		t.Fatalf("fixture invariant broken: %q must extend %q WITHOUT a hyphen boundary", otherEnc, rootEnc)
	}
	// No cwd, so if the boundary test lets this directory through, stage 2
	// cannot dismiss the file and it lands in Skipped.
	writeSessionFile(t, claudeConfigDir, otherEnc, "unrelated", []map[string]any{
		{"type": "user", "message": map[string]any{"content": "not ours"}},
	})
	writeSessionFile(t, claudeConfigDir, rootEnc, "mine", []map[string]any{
		{"type": "user", "cwd": rootDir, "message": map[string]any{"content": "mine"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].ID != "mine" {
		t.Fatalf("want only 'mine', got %+v", sessions)
	}
	if sessions.Skipped != 0 {
		t.Errorf("Skipped = %d, want 0: %q is not a candidate of %q, so it must never be searched",
			sessions.Skipped, otherEnc, rootEnc)
	}
}

func TestListSessions_OrderedNewestFirst(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	dirName := EncodeRootPath(projDir)
	oldPath := writeSessionFile(t, claudeConfigDir, dirName, "old-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "old"}},
	})
	newPath := writeSessionFile(t, claudeConfigDir, dirName, "new-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "new"}},
	})

	oldTime := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	newTime := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	if err := os.Chtimes(oldPath, oldTime, oldTime); err != nil {
		t.Fatalf("Chtimes old: %v", err)
	}
	if err := os.Chtimes(newPath, newTime, newTime); err != nil {
		t.Fatalf("Chtimes new: %v", err)
	}

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 2 {
		t.Fatalf("len(sessions.Sessions) = %d, want 2: %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "new-session" || sessions.Sessions[1].ID != "old-session" {
		t.Errorf("order = [%s, %s], want [new-session, old-session]", sessions.Sessions[0].ID, sessions.Sessions[1].ID)
	}
}

func TestListSessions_NoProjectsDirReturnsNoError(t *testing.T) {
	home, _ := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// Deliberately do not create <claudeConfigDir>/projects.
	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 0 {
		t.Errorf("len(sessions.Sessions) = %d, want 0", len(sessions.Sessions))
	}
	// A transcript root that does not exist means the account has never run
	// a session. That is a known empty, not an unknown, so it must NOT be
	// reported as unread — see SessionList.UnreadProviders for why the
	// field would be worthless if it fired here.
	if slices.Contains(sessions.UnreadProviders, "primary") {
		t.Errorf("UnreadProviders = %v, want primary ABSENT — a never-run provider contributes nothing and misses nothing",
			sessions.UnreadProviders)
	}
}

// --- GetSession ----------------------------------------------------------

func TestGetSession_UnknownIDReturnsUserError(t *testing.T) {
	home, _ := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	_, err := GetSession("does-not-exist")
	if err == nil {
		t.Fatal("GetSession(unknown id) must return an error")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected UserError, got %v", err)
	}
	want := "session not found for the active project: does-not-exist"
	if msg != want {
		t.Errorf("message = %q, want %q", msg, want)
	}
}

// --- firstPrompt (via GetSession) ----------------------------------------

func TestGetSession_FirstPromptSkipsSystemAndToolResultBlocks(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	dirName := EncodeRootPath(projDir)
	records := []map[string]any{
		// cwd on the first record only: real transcripts carry one on every
		// record, and ListSessions now requires one somewhere in the file
		// before it will claim the session (see its doc comment).
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "<system_instruction>Some framework text</system_instruction>"}},
		{"type": "user", "message": map[string]any{"content": []map[string]any{
			{"type": "tool_result", "content": []map[string]any{{"type": "text", "text": "some tool output"}}},
		}}},
		{"type": "user", "message": map[string]any{"content": []map[string]any{
			{"type": "text", "text": "Please implement the login page"},
		}}},
	}
	writeSessionFile(t, claudeConfigDir, dirName, "prompt-session", records)

	sess, err := GetSession("prompt-session")
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	want := "Please implement the login page"
	if sess.FirstPrompt != want {
		t.Errorf("FirstPrompt = %q, want %q", sess.FirstPrompt, want)
	}
}

func TestGetSession_FirstPromptPlainStringContent(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	dirName := EncodeRootPath(projDir)
	records := []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "Fix the bug in the encoder"}},
	}
	writeSessionFile(t, claudeConfigDir, dirName, "plain-session", records)

	sess, err := GetSession("plain-session")
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	want := "Fix the bug in the encoder"
	if sess.FirstPrompt != want {
		t.Errorf("FirstPrompt = %q, want %q", sess.FirstPrompt, want)
	}
}

func TestGetSession_FirstPromptTruncatesByRunes(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// Use a multi-byte rune throughout so a byte-based truncation would
	// split a character and this test would catch it.
	long := strings.Repeat("é", 250)
	dirName := EncodeRootPath(projDir)
	records := []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": long}},
	}
	writeSessionFile(t, claudeConfigDir, dirName, "long-session", records)

	sess, err := GetSession("long-session")
	if err != nil {
		t.Fatalf("GetSession: %v", err)
	}
	wantRunes := []rune(long)[:200]
	want := string(wantRunes) + "…"
	if sess.FirstPrompt != want {
		t.Errorf("FirstPrompt = %q (rune len %d), want %q (rune len %d)",
			sess.FirstPrompt, len([]rune(sess.FirstPrompt)), want, len([]rune(want)))
	}
	if got := len([]rune(sess.FirstPrompt)); got != 201 {
		t.Errorf("rune length = %d, want 201 (200 + ellipsis)", got)
	}
}

// --- absolute root paths (Phase 1 acceptance regressions) ----------------

// TestListSessions_AbsoluteRootIsNotMangled is the Bug B regression. Every
// other ListSessions test in this file declares its root as ".", so nothing
// here had ever exercised an absolute root — which is the shape
// docs/wakil/phase-1-acceptance.md's project.json template writes
// ("/abs/path/to/repo") and the shape the real acceptance project.json
// uses.
//
// The old code resolved a root with filepath.Join(projDir, root.Path).
// filepath.Join does not treat an absolute second element as absolute; it
// concatenates, producing <projDir><projDir>. ListSessions then looked up
// the ENCODING of that doubled path, matched no directory, and returned
// zero sessions with a NIL ERROR — indistinguishable from a project that
// has none, which is why it survived to a live session.
//
// The fixture also uses a dotted directory name so this test additionally
// covers the encoded-name path the acceptance run exercised.
func TestListSessions_AbsoluteRootIsNotMangled(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "wakil.acceptance")
	projPath := writeProjectWithRoots(t, projDir, "acc", "initech", []Root{{Path: projDir}})
	activateProject(t, "acc", projPath)

	// Fixture invariant: without this, an implementation that still joined
	// blindly could coincidentally produce the right directory and the
	// assertion below would prove nothing.
	if mangled := filepath.Join(projDir, projDir); mangled == projDir {
		t.Fatalf("fixture invariant broken: joining %q onto itself did not change it", projDir)
	}

	dirName := EncodeRootPath(projDir)
	writeSessionFile(t, claudeConfigDir, dirName, "abs-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "hello from an absolute root"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want 1 — an absolute root.path must be used as-is, not joined onto the project dir: %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "abs-session" {
		t.Errorf("ID = %q, want %q", sessions.Sessions[0].ID, "abs-session")
	}
	if sessions.Skipped != 0 {
		t.Errorf("Skipped = %d, want 0 — nothing in this fixture is unreadable", sessions.Skipped)
	}
}

// TestListSessions_AbsoluteSubdirectoryRootExcludesParent covers the second
// root shape the acceptance project.json uses: an absolute path BELOW the
// project directory (".../wakil.acceptance/src"). Joining that onto projDir
// mangles it just as badly as the exact-match case, but the two failures
// are not the same code path once fixed, so both are pinned.
//
// The parent-directory session is a decoy: with "<projDir>/src" as the only
// root, a session whose cwd is <projDir> is genuinely out of scope and must
// stay excluded. Without it this test would still pass against an
// implementation that resolved every root to the project directory.
func TestListSessions_AbsoluteSubdirectoryRootExcludesParent(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "wakil.acceptance")
	srcDir := filepath.Join(projDir, "src")
	projPath := writeProjectWithRoots(t, projDir, "acc", "initech", []Root{{Path: srcDir}})
	activateProject(t, "acc", projPath)

	writeSessionFile(t, claudeConfigDir, EncodeRootPath(srcDir), "src-session", []map[string]any{
		{"type": "user", "cwd": srcDir, "message": map[string]any{"content": "in src"}},
	})
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "parent-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "in the parent"}},
	})

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 {
		t.Fatalf("len(sessions.Sessions) = %d, want exactly 1 (src-session only): %+v", len(sessions.Sessions), sessions)
	}
	if sessions.Sessions[0].ID != "src-session" {
		t.Errorf("ID = %q, want %q", sessions.Sessions[0].ID, "src-session")
	}
}

// TestGetSession_FindsSessionUnderAbsoluteRoot is the Bug C regression, and
// it is deliberately independent of the ListSessions tests above even
// though the two bugs share one root cause.
//
// GetSession has no discovery of its own: it filters ListSessions. When an
// absolute root was mangled, ListSessions returned nothing and GetSession
// answered "session not found for the active project" — for the very
// session the caller was running inside, during the Phase 1 acceptance run.
// A future change that reintroduced the empty listing by some other route
// would produce the same misleading not-found, so this asserts the
// user-visible symptom rather than trusting the ListSessions tests to cover
// it.
func TestGetSession_FindsSessionUnderAbsoluteRoot(t *testing.T) {
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "wakil.acceptance")
	projPath := writeProjectWithRoots(t, projDir, "acc", "initech", []Root{{Path: projDir}})
	activateProject(t, "acc", projPath)

	const id = "28a20e7b-fced-4c8f-a7bd-77371ddefd33"
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), id, []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "run the phase 1 acceptance"}},
	})

	sess, err := GetSession(id)
	if err != nil {
		t.Fatalf("GetSession(%s) = %v, want the session — a mangled absolute root makes this report \"not found\" for a session that exists", id, err)
	}
	if sess.ID != id {
		t.Errorf("ID = %q, want %q", sess.ID, id)
	}
	if sess.FirstPrompt != "run the phase 1 acceptance" {
		t.Errorf("FirstPrompt = %q, want %q", sess.FirstPrompt, "run the phase 1 acceptance")
	}
}

// --- SessionList shape and partiality ------------------------------------

// TestListSessions_EmptyListingHasNonNilSlice pins the wire shape of an
// empty result. A nil Sessions marshals to {"sessions":null}; a client
// iterating the array then has to special-case null. This is the same
// non-nil discipline RecallOutput needs (see EmptyRecallOutput), applied
// here at the point where the value is built rather than at every caller.
func TestListSessions_EmptyListingHasNonNilSlice(t *testing.T) {
	home, _ := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if sessions.Sessions == nil {
		t.Fatal("Sessions must be non-nil even when empty, so the wire carries [] and not null")
	}
	b, err := json.Marshal(sessions)
	if err != nil {
		t.Fatalf("marshal SessionList: %v", err)
	}
	// skipped and unreadProviders are both omitempty, so a clean empty
	// listing must carry none of a null array, a skipped key or an
	// unreadProviders key.
	if got, want := string(b), `{"sessions":[]}`; got != want {
		t.Errorf("marshaled SessionList = %s, want %s", got, want)
	}
}

// TestListSessions_UnreadableDirectoryCountsAsSkipped asserts the guard
// actually fires: a candidate transcript directory that cannot be read is
// swallowed (one bad directory must not abort the whole listing) but is
// COUNTED, so a caller can tell "this project has no sessions" from "I
// could not look". Before SessionList.Skipped existed there was no way to
// tell those apart — the same silent-empty failure mode as Bug B, one layer
// down.
func TestListSessions_UnreadableDirectoryCountsAsSkipped(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: mode 0000 does not deny access, so the guard cannot be made to fire")
	}
	home, claudeConfigDir := setupHome(t)

	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)

	// A readable session under the same root, so the test also proves the
	// unreadable directory does not abort the listing.
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), "good-session", []map[string]any{
		{"type": "user", "cwd": projDir, "message": map[string]any{"content": "fine"}},
	})

	// A second candidate directory (a real subdirectory of the root, so it
	// passes the stage-1 prefix filter) that we then make unreadable.
	hiddenDir := filepath.Join(projDir, "hidden")
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(hiddenDir), "hidden-session", []map[string]any{
		{"type": "user", "cwd": hiddenDir, "message": map[string]any{"content": "unreachable"}},
	})
	onDisk := filepath.Join(claudeConfigDir, "projects", EncodeRootPath(hiddenDir))
	if err := os.Chmod(onDisk, 0o000); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	// Registered AFTER t.TempDir's own cleanup, so it runs BEFORE it
	// (cleanups are LIFO) and the temp tree stays removable.
	t.Cleanup(func() { os.Chmod(onDisk, 0o755) })

	// Fixture invariant: the directory really is unreadable now. Without
	// this the assertions below could pass for the wrong reason on a
	// filesystem that ignores the mode.
	if _, err := os.ReadDir(onDisk); err == nil {
		t.Skip("filesystem does not enforce directory permissions here; cannot make the guard fire")
	}

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions must not fail because one directory is unreadable: %v", err)
	}
	if sessions.Skipped != 1 {
		t.Errorf("Skipped = %d, want 1 — an unreadable candidate directory must be counted, not silently dropped", sessions.Skipped)
	}
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].ID != "good-session" {
		t.Errorf("Sessions = %+v, want just good-session — one unreadable directory must not abort the listing", sessions.Sessions)
	}
}

// --- provider-aware discovery --------------------------------------------

// twoProviderFixture builds an org with two claude-code providers whose
// transcript stores each hold one session for the active project.
func twoProviderFixture(t *testing.T) (projPath string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	wakilDir := filepath.Join(root, ".wakil")
	if err := os.MkdirAll(wakilDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projPath = filepath.Join(wakilDir, "project.json")
	body := `{"name":"booking","org":"initech","roots":[{"path":"` + root + `"}]}`
	if err := os.WriteFile(projPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	if err := WriteActive(ActiveContext{Project: projPath}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []struct{ id, session string }{{"primary", "aaaaaaaa-0000-0000-0000-000000000001"}, {"backup", "bbbbbbbb-0000-0000-0000-000000000002"}} {
		cfg := filepath.Join(home, ".claude-"+p.id)
		dir := filepath.Join(cfg, "projects", EncodeRootPath(root))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		line := `{"type":"user","cwd":"` + root + `","message":{"content":"hello from ` + p.id + `"}}` + "\n"
		if err := os.WriteFile(filepath.Join(dir, p.session+".jsonl"), []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := AddProvider("initech", Provider{ID: p.id, Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
			t.Fatal(err)
		}
	}
	return projPath
}

func TestListSessionsSpansEveryProviderAndTagsEachSession(t *testing.T) {
	twoProviderFixture(t)
	t.Setenv("CLAUDE_CONFIG_DIR", "") // must be irrelevant now

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 2 {
		t.Fatalf("Sessions = %+v; want one from each provider", got.Sessions)
	}
	seen := map[string]bool{}
	for _, s := range got.Sessions {
		if s.Provider == "" {
			t.Errorf("session %s has no Provider tag", s.ID)
		}
		seen[s.Provider] = true
	}
	if !seen["primary"] || !seen["backup"] {
		t.Errorf("providers seen = %v; want both primary and backup", seen)
	}
}

func TestListSessionsIgnoresAmbientClaudeConfigDir(t *testing.T) {
	twoProviderFixture(t)
	// A config dir that is NOT a registered provider. Before this change
	// sessionsRoot() read exactly this variable.
	stray := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", stray)

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want the two provider-backed sessions, unaffected by CLAUDE_CONFIG_DIR", got.Sessions)
	}
}

func TestListSessionsNamesProvidersItCannotRead(t *testing.T) {
	twoProviderFixture(t)
	if err := AddProvider("initech", Provider{ID: "ollama", Kind: ProviderKindLocal}); err != nil {
		t.Fatal(err)
	}
	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(got.UnreadProviders, "ollama") {
		t.Errorf("UnreadProviders = %v; want it to name the local provider — an empty answer must be distinguishable from an unsearched one", got.UnreadProviders)
	}
}

func TestGetSessionReadsFromTheOwningProvider(t *testing.T) {
	twoProviderFixture(t)
	got, err := GetSession("bbbbbbbb-0000-0000-0000-000000000002")
	if err != nil {
		t.Fatal(err)
	}
	if got.Provider != "backup" {
		t.Errorf("Provider = %q; want backup", got.Provider)
	}
	if !strings.Contains(got.FirstPrompt, "backup") {
		t.Errorf("FirstPrompt = %q; want the transcript read from backup's own store", got.FirstPrompt)
	}
}

// TestListSessionsNamesAProviderRecordItCannotParse covers the third thing
// UnreadProviders is for, and it is the reason ListSessions calls the
// unexported listProvidersFor rather than ListProvidersFor.
//
// A corrupt providers/<id>.json never becomes a Provider value, so the
// exported wrapper — which drops the ids it skipped — leaves nothing
// downstream able to name it. The listing would then be missing that
// account's sessions while reporting a complete answer, which is the exact
// silence this field exists to break. Switching the call back to
// ListProvidersFor makes this test fail; the assertion trips on "broken"
// being absent from UnreadProviders, and the second assertion is there so
// a fix that simply failed the whole listing would not pass either.
func TestListSessionsNamesAProviderRecordItCannotParse(t *testing.T) {
	twoProviderFixture(t)

	dir, err := providersDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "broken.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Fixture invariant: the record really is unparsable, so the guard has
	// something to fire on rather than the id being missing for some
	// unrelated reason.
	if _, err := LoadProviderFor("initech", "broken"); err == nil {
		t.Fatal("fixture invariant broken: providers/broken.json parsed fine, so nothing can be reported as unreadable")
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("one corrupt provider record must not fail the whole listing: %v", err)
	}
	if !slices.Contains(got.UnreadProviders, "broken") {
		t.Errorf("UnreadProviders = %v; want it to name broken — a provider record nobody can parse is still a provider nobody searched", got.UnreadProviders)
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want the two readable providers' sessions — one corrupt record must not hide them", got.Sessions)
	}
}

// TestListSessionsRefusesAClaudeCodeProviderWithNoConfigDir pins the
// `p.ConfigDir == ""` half of providerSessionsRoot's guard, which nothing
// else here reaches.
//
// It exists because the obvious test does not do the job.
// TestListSessionsIgnoresAmbientClaudeConfigDir proves the ambient variable
// is not consulted for a provider that HAS a config dir, and that is what
// the deleted sessionsRoot got wrong — but it says nothing about the one
// case where a fallback could still be written in. Reintroducing
// `if p.ConfigDir == "" { cfg = os.Getenv("CLAUDE_CONFIG_DIR") }` was
// measured to leave the entire package green, because AddProvider refuses
// a claude-code provider without a config dir so no fixture ever produced
// one.
//
// A hand-edited record does. `{"kind":"claude-code"}` unmarshals cleanly
// into a Provider whose ConfigDir is "", so this is the reachable shape of
// the empty case, and it is the only shape in which the fallback would
// fire. The assertions trip on: the stray transcript appearing in the
// listing, and "noconfig" being absent from UnreadProviders. Delete the
// ConfigDir check and add the env fallback and all three fire; the store
// the ambient variable names is searched and its transcript is returned
// under an org that never registered it.
func TestListSessionsRefusesAClaudeCodeProviderWithNoConfigDir(t *testing.T) {
	projPath := twoProviderFixture(t)
	root := filepath.Dir(filepath.Dir(projPath))

	// An unregistered store holding a transcript that WOULD match the
	// active project's roots, named by the ambient variable and by nothing
	// else.
	stray := t.TempDir()
	strayDir := filepath.Join(stray, "projects", EncodeRootPath(root))
	if err := os.MkdirAll(strayDir, 0o755); err != nil {
		t.Fatal(err)
	}
	line := `{"type":"user","cwd":"` + root + `","message":{"content":"hello from the stray store"}}` + "\n"
	if err := os.WriteFile(filepath.Join(strayDir, "stray-session.jsonl"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", stray)

	dir, err := providersDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "noconfig.json"), []byte(`{"kind":"claude-code"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	// Fixture invariants: the record parses (so it reaches
	// providerSessionsRoot at all) and its ConfigDir really is empty (so
	// the branch under test is the one taken).
	p, err := LoadProviderFor("initech", "noconfig")
	if err != nil {
		t.Fatalf("fixture invariant broken: the record must parse to reach providerSessionsRoot: %v", err)
	}
	if p.Kind != ProviderKindClaudeCode || p.ConfigDir != "" {
		t.Fatalf("fixture invariant broken: want a claude-code provider with an empty ConfigDir, got %+v", *p)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range got.Sessions {
		if s.ID == "stray-session" {
			t.Errorf("the store named by CLAUDE_CONFIG_DIR was searched for a provider that declares no config dir: %+v", got.Sessions)
		}
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want only the two registered providers' sessions", got.Sessions)
	}
	if !slices.Contains(got.UnreadProviders, "noconfig") {
		t.Errorf("UnreadProviders = %v; want it to name noconfig — a claude-code record with no config dir points at no store, so nothing was searched for it",
			got.UnreadProviders)
	}
}

// TestListSessionsDoesNotFlagANeverRunProvider is the first half of the
// "never used" versus "could not look" rule, and it is the half a caller
// feels every day: an org keeps a spare account for rate-limit headroom,
// that account has not run a session yet, and every list_sessions call must
// not warn about it. A partiality field that fires on the ordinary case is
// one the reader learns to skip, which costs the cases it exists for.
//
// The assertion trips on "spare" appearing in UnreadProviders. Deleting the
// os.IsNotExist branch — letting a missing root fall through into the
// generic read-error append — makes it fire; that mutation is recorded in
// the task report. The second assertion is not decoration: it holds the
// other direction of the same branch, so a "fix" that skipped the provider
// early and lost the two real providers' sessions would not pass either.
func TestListSessionsDoesNotFlagANeverRunProvider(t *testing.T) {
	twoProviderFixture(t)

	// A registered claude-code account with a config dir but no transcript
	// store: exactly what `wakil provider add` leaves behind before the
	// account has ever been launched.
	spare := t.TempDir()
	if err := AddProvider("initech", Provider{ID: "spare", Kind: ProviderKindClaudeCode, ConfigDir: spare}); err != nil {
		t.Fatal(err)
	}
	// Fixture invariant: the root really is absent, so the branch under
	// test is the one taken and not some other error.
	if _, err := os.Stat(filepath.Join(spare, "projects")); !os.IsNotExist(err) {
		t.Fatalf("fixture invariant broken: want %s/projects to be absent, Stat gave %v", spare, err)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(got.UnreadProviders, "spare") {
		t.Errorf("UnreadProviders = %v; want spare ABSENT — a provider that has never run a session has a genuinely empty answer, so nothing was missed",
			got.UnreadProviders)
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want the two provider-backed sessions — a never-run provider must not disturb the listing", got.Sessions)
	}
}

// TestListSessionsNamesAProviderWhoseRootCannotBeRead is the other half:
// a transcript root that EXISTS but cannot be read is an unknown, and the
// provider must be named.
//
// The root is made unreadable by creating it as a regular FILE named
// "projects" rather than by chmod 0000 on a directory. That choice is
// deliberate: mode 0000 does not deny a process running as root, so a
// chmod-based fixture passes vacuously in a root container — the existing
// TestListSessions_UnreadableDirectoryCountsAsSkipped has to t.Skip for
// exactly that reason. os.ReadDir on a regular file fails with ENOTDIR for
// every uid there is, so this cannot pass for the wrong reason, and the
// fixture invariant below asserts the failure is real and is NOT an
// IsNotExist (which would send it down the never-run branch instead).
func TestListSessionsNamesAProviderWhoseRootCannotBeRead(t *testing.T) {
	twoProviderFixture(t)

	cfg := t.TempDir()
	if err := os.WriteFile(filepath.Join(cfg, "projects"), []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("initech", Provider{ID: "blocked", Kind: ProviderKindClaudeCode, ConfigDir: cfg}); err != nil {
		t.Fatal(err)
	}
	// Fixture invariants: the read really fails, and it fails for a reason
	// that is not "does not exist" — otherwise this would be testing the
	// never-run branch under a misleading name.
	_, err := os.ReadDir(filepath.Join(cfg, "projects"))
	if err == nil {
		t.Fatal("fixture invariant broken: reading a regular file as a directory succeeded, so the guard cannot fire")
	}
	if os.IsNotExist(err) {
		t.Fatalf("fixture invariant broken: want a non-IsNotExist read failure, got %v", err)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("one unreadable transcript root must not fail the whole listing: %v", err)
	}
	if !slices.Contains(got.UnreadProviders, "blocked") {
		t.Errorf("UnreadProviders = %v; want it to name blocked — its store exists and could not be read, so its emptiness is unknown rather than known",
			got.UnreadProviders)
	}
	if len(got.Sessions) != 2 {
		t.Errorf("Sessions = %+v; want the two readable providers' sessions — one unreadable store must not hide them", got.Sessions)
	}
}

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

// A handed session is titled as its hand-off's chip — `INI-142 · <the first line>` — over the
// CLI's own title, and so is a session resumed from it (its lineage root's hand-off).
func TestListSessions_HandedSessionTakesItsHandoffTitle(t *testing.T) {
	home, claudeConfigDir := setupHome(t)
	projDir := filepath.Join(home, "proj")
	projPath := writeProjectWithRoots(t, projDir, "proj", "initech", []Root{{Path: "."}})
	activateProject(t, "proj", projPath)
	for _, id := range []string{"s1", "s2", "s3"} {
		writeSessionFile(t, claudeConfigDir, EncodeRootPath(projDir), id, []map[string]any{
			{"type": "user", "cwd": projDir, "message": map[string]any{"content": "Work toward Next"}},
			{"type": "ai-title", "aiTitle": "cli title", "sessionId": id},
		})
	}
	if _, err := AddTicketHandoff("initech", "INI-142", handoff("s1"), false, ticketNow); err != nil {
		t.Fatal(err)
	}
	if err := RecordSessionParent("s2", "s1"); err != nil {
		t.Fatal(err)
	}

	got, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	titles := map[string]string{}
	for _, s := range got.Sessions {
		titles[s.ID] = s.Title
	}
	want := handoff("s1").Title
	if titles["s1"] != want || titles["s2"] != want || titles["s3"] != "cli title" {
		t.Errorf("titles = %v, want s1 and s2 %q, s3 %q", titles, want, "cli title")
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

// symlinkedRootFixture declares the project's root through a symlink and writes one session
// transcript the way `claude` does: under the encoding of the PHYSICAL working directory, with
// that physical path as its cwd — the CLI records what getcwd answers, which resolves every link.
// macOS's own temp dir is one (`/var` -> `/private/var`), so a project registered under
// `/var/folders/...` records its sessions under `/private/var/folders/...`; the explicit link
// here makes the fixture the same on every platform.
func symlinkedRootFixture(t *testing.T, sessionID string) {
	t.Helper()
	home, claudeConfigDir := setupHome(t)
	real := filepath.Join(home, "real")
	if err := os.MkdirAll(filepath.Join(real, "proj"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	link := filepath.Join(home, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	declared := filepath.Join(link, "proj")
	projPath := writeProjectWithRoots(t, declared, "proj", "initech", []Root{{Path: declared}})
	activateProject(t, "proj", projPath)

	physical, err := filepath.EvalSymlinks(declared)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}
	if physical == declared {
		t.Fatalf("fixture invariant broken: %q resolved to itself, so nothing here is a link", declared)
	}
	writeSessionFile(t, claudeConfigDir, EncodeRootPath(physical), sessionID, []map[string]any{
		{"type": "user", "cwd": physical, "message": map[string]any{"content": "hold a turn open here"}},
	})
}

// TestListSessions_FindsASessionRecordedUnderTheRootsPhysicalPath is the Continue column that
// stayed empty after a close (conversations-close-asks step 23): the e2e project's root is
// declared as `/var/folders/...`, and the session's transcript sat under `-private-var-...`, so
// neither the directory prefix nor the recorded cwd matched the declared root, and the session
// was dropped without a word — not skipped, not unread.
func TestListSessions_FindsASessionRecordedUnderTheRootsPhysicalPath(t *testing.T) {
	symlinkedRootFixture(t, "linked-session")

	sessions, err := ListSessions()
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].ID != "linked-session" {
		t.Fatalf("sessions = %+v, want linked-session: a root declared through a link holds the sessions "+
			"recorded under its physical path", sessions.Sessions)
	}
	if sessions.Sessions[0].FirstPrompt != "hold a turn open here" {
		t.Errorf("FirstPrompt = %q, want the prompt", sessions.Sessions[0].FirstPrompt)
	}
}

// TestReadSession_ResumesASessionRecordedUnderTheRootsPhysicalPath: the Continue row that
// lists it can also be resumed — its cwd is that root, not a foreign directory.
func TestReadSession_ResumesASessionRecordedUnderTheRootsPhysicalPath(t *testing.T) {
	symlinkedRootFixture(t, "linked-session")

	if _, err := ReadSession("linked-session", 0); err != nil {
		t.Fatalf("ReadSession: %v — its cwd is the declared root's physical path", err)
	}
}
