package wakilcore

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// EncodeRootPath mirrors Claude Code's lossy project-directory encoding:
// both "/" and "." become "-". Always encode a known path and look for that
// directory; never decode a directory name back into a path.
//
// The "."->"-" half of this rule was an open risk through Phase 1 and is
// now CONFIRMED BY MEASUREMENT, so do not re-open it. The risk was real:
// of the 73 project directories under this machine's ~/.claude/projects,
// not one contained "--" — the only externally visible tell-tale, left by
// a segment that STARTS with a dot such as "/.claude" — so nothing on
// disk had ever confirmed the dot branch. It was inferred
// from Claude Code's behaviour, not observed. The Phase 1 acceptance run
// observed it: a session started in the deliberately dotted directory
// /Users/operator/wakil.acceptance produced the transcript directory
//
//	~/.claude-personal/projects/-Users-operator-wakil-acceptance
//
// — one hyphen for each "/" AND one for the "." in "wakil.acceptance",
// exactly as encoded here. That is evidence, not a guess.
//
// The encoding remains lossy and strictly one-way regardless (a "-" in
// the output could have come from "/", "." or a literal "-"), which is
// why the constraint is still encode-then-look-up: a wrong encoding for
// some future path shape can only ever yield an empty result, never
// another project's sessions.
func EncodeRootPath(abs string) string {
	r := strings.NewReplacer("/", "-", ".", "-")
	return r.Replace(abs)
}

// SessionMeta describes one discovered Claude Code session transcript.
type SessionMeta struct {
	ID   string `json:"id"`
	Root string `json:"root"`
	// Provider is the id of the org provider whose transcript store this
	// session was found in. One org may hold several providers, and a
	// session belongs to exactly one of them: a Claude Code session is a
	// subprocess bound to one config dir and its transcript lives inside
	// that config dir. So after a rate-limit handoff the work exists as
	// two sessions, one per provider, and this field is what says which
	// is which. It is also what GetSession uses to reopen the right
	// store, so it is not decoration.
	//
	// Not omitempty: every session ListSessions returns was found under
	// some provider, so an absent provider on the wire would mean a bug
	// here rather than a legitimately unknown value, and a caller should
	// be able to see that.
	Provider    string    `json:"provider"`
	ModTime     time.Time `json:"modTime"`
	FirstPrompt string    `json:"firstPrompt,omitempty"`
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
	// Parent is the session this one was forked from, per the org's
	// lineage store (sessions_lineage.go), or "" for one started fresh.
	// ⌘P collapses a chain of forks into a single entry using it.
	Parent string `json:"parent,omitempty"`
	// LineageRoot is the oldest ancestor reachable from this session, or
	// this session's own id when it was started fresh — the identity one
	// conversation keeps across every resume that forked it.
	//
	// Derived from the same lineage store Parent comes from, but resolved
	// against the WHOLE org's map rather than against the sessions in this
	// listing. That matters because this listing is filtered to the active
	// project's roots: a chain whose ancestor ran in another project would
	// resolve to a different root depending on what is listed, which is
	// harmless for a display grouping and fatal for a storage key. Callers
	// that need a stable identity for a conversation — a pane arrangement
	// filed against it, a name given to it — must use this and not walk
	// Parent themselves.
	//
	// Not omitempty: every session has a lineage root, and one started
	// fresh is its own, so an absent value on the wire would mean a bug
	// here rather than a legitimately unknown value. Same reasoning as
	// Provider above.
	LineageRoot string `json:"lineageRoot"`
}

// SessionList is what ListSessions returns: the sessions themselves plus
// how much of the search could not be carried out.
//
// It is a struct rather than a bare []SessionMeta for two independent
// reasons.
//
// First, MCP requires a tool result's structuredContent to be a JSON
// OBJECT. The MCP SDK generates a tool's advertised outputSchema straight
// from the handler's typed Out, so a []SessionMeta Out advertised a
// top-level {"items":…,"type":["null","array"]} and put a bare array on
// the wire — a protocol violation that made wakil-ctx's list_sessions
// fail outright against a validating client in the Phase 1 acceptance
// run. See internal/mcpx's ToolErr doc comment for the full measurement
// and the rule that came out of it.
//
// Second, a bare slice had nowhere to put Skipped. That matters here more
// than it would elsewhere: this listing's whole failure mode is returning
// an empty result with a nil error, which reads to a caller as "this
// project has no sessions" when it may mean "I could not look". Carrying
// the partiality signal alongside the data is the same house invariant as
// Rows.Truncated (dbdriver.go), IssuePage.Truncated/Filtered (jira.go)
// and RecallOutput.Sources (recall.go).
type SessionList struct {
	// Sessions holds the matched transcripts, newest first. It is never
	// nil when built through NewSessionList, so the wire carries [] and
	// not null for an empty listing.
	Sessions []SessionMeta `json:"sessions"`
	// Skipped counts places this listing could not look, NOT sessions it
	// found and rejected. Three things increment it:
	//   - a candidate transcript directory whose contents could not be read;
	//   - an individual transcript file whose metadata could not be stat'ed;
	//   - a transcript whose project membership could not be CONFIRMED,
	//     i.e. one carrying no "cwd" record for cwdMatchesAnyRoot to check
	//     (see ListSessions).
	// The first two are permission problems or races against Claude Code
	// writing/removing files underneath us; the third is the same race seen
	// from inside a file rather than from the directory around it. All three
	// are swallowed so one bad directory or one unreadable transcript cannot
	// abort the whole listing.
	//
	// The line this count draws is "could not confirm", not "confirmed it is
	// not ours". A transcript whose cwd is read and turns out to belong to
	// another project is a confirmed non-match and is NOT counted: nothing
	// about the listing is incomplete because of it. A transcript with no cwd
	// at all is counted, because we genuinely do not know what we just
	// dropped. Keep that distinction when changing either branch — it is the
	// whole meaning of the field.
	//
	// It is deliberately not a count of missing sessions — an unreadable
	// directory may have held any number, including none. A non-zero value
	// means only "this list may be incomplete", which is precisely the
	// thing a caller cannot otherwise tell.
	//
	// Skipped is about individual transcripts and the directories holding
	// them, within a provider whose store WAS opened. A provider whose
	// store could not be opened at all is a different statement and goes in
	// UnreadProviders; do not merge the two.
	Skipped int `json:"skipped,omitempty"`
	// UnreadProviders names the org's providers whose stores this listing
	// could not look inside, sorted. Three things put a provider here:
	//   - it names no store this code can read, which is either of the two
	//     conditions providerSessionsRoot rejects: a kind with no session
	//     adapter (codex or local), or a claude-code record carrying no
	//     configDir. The second is reachable only by hand-editing a record,
	//     since AddProvider refuses to write one, and it is reported rather
	//     than resolved from the environment — see providerSessionsRoot;
	//   - its transcript root exists but could not be read: permissions, or
	//     a "projects" that is not a directory;
	//   - its provider record could not be parsed at all, so nothing is
	//     known about it beyond its id (listProvidersFor's skipped ids).
	// The third is why this is a []string of ids rather than anything
	// richer: an unparsable record never becomes a Provider value, so the
	// id is the only thing there is to report.
	//
	// A FOURTH case is deliberately NOT here: a provider whose transcript
	// root does not exist — an account registered but never run. Its answer
	// is genuinely empty rather than unknown, so naming it would be noise,
	// and a field that cries wolf on the ordinary case of a spare account
	// stops being read at all. The line is the same one Skipped draws one
	// level down: "could not look", never "looked and found nothing".
	//
	// This carries the same signal as Skipped one level up. Without it, an
	// org with a codex provider and a claude-code provider whose store is
	// unreadable returns exactly the same empty listing as an org whose one
	// provider genuinely has no sessions for this project.
	UnreadProviders []string `json:"unreadProviders,omitempty"`
}

// NewSessionList builds a SessionList with a guaranteed non-nil Sessions
// slice, so callers on the error path can hand the MCP layer a value whose
// JSON is {"sessions":[]} rather than {"sessions":null}. Pass nil for
// sessions to get exactly that.
//
// unread gets no such treatment: it is omitempty, so a nil one simply does
// not appear on the wire, which is the correct reading of "every provider
// was searched".
func NewSessionList(sessions []SessionMeta, skipped int, unread []string) SessionList {
	if sessions == nil {
		sessions = []SessionMeta{}
	}
	return SessionList{Sessions: sessions, Skipped: skipped, UnreadProviders: unread}
}

// providerSessionsRoot returns the transcript root for one provider, and
// false when the provider names no store this code can read. There are
// TWO such conditions, and both report as unread rather than being
// silently omitted:
//
//   - the kind has no session adapter (codex or local);
//   - the kind is claude-code but the record carries no configDir, so
//     there is no store to point at. AddProvider refuses to write such a
//     record, so it arrives only by hand-editing providers/<id>.json —
//     but it parses cleanly, so it reaches here and must be answered.
//     TestListSessionsRefusesAClaudeCodeProviderWithNoConfigDir pins it.
//
// Session discovery is inherently per-harness: this reads Claude Code's
// own on-disk layout, which is not a leak of the wrong abstraction but
// the honest shape of the problem. A codex or local provider would need
// its own adapter with its own format.
//
// This deliberately does NOT read CLAUDE_CONFIG_DIR. The old sessionsRoot
// did, and fell back to ~/.claude/projects when it was unset — harmless
// only while CurrentOrg() read the same variable. Once the org comes from
// WAKIL_ORG the two can disagree, and the result is operating as one org
// while listing another account's history.
func providerSessionsRoot(p Provider) (string, bool) {
	if p.Kind != ProviderKindClaudeCode || p.ConfigDir == "" {
		return "", false
	}
	return filepath.Join(p.ConfigDir, "projects"), true
}

// firstPromptSkipMarkers are harness-injected prefixes that disqualify a
// "user" record's text from being used as a human-recognisable session
// label.
var firstPromptSkipMarkers = []string{
	"<system_instruction>",
	"<system-reminder>",
	"<command-name>",
	"<local-command-",
	"Caveat:",
}

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

// sessionRootPaths is roots as a session's transcript can name them: each as
// declared, then — when it differs — as `filepath.EvalSymlinks` resolves it.
//
// **The CLI records its physical working directory.** It takes its cwd from
// getcwd, which resolves every link, and both the transcript's directory
// name and its records' "cwd" come from that. A root declared through a link
// — macOS's own temp dir is one, `/var` -> `/private/var` — therefore holds
// sessions recorded under a path that is not the declared one, and matching
// only the declared spelling dropped them without a word: not skipped, not
// unread, just absent from Continue (conversations-close-asks, step 23). The
// declared spelling stays first and stays matched, for a transcript written
// under it. A root that does not resolve (gone, unreadable) is kept as
// declared only.
func sessionRootPaths(roots []string) []string {
	out := append([]string(nil), roots...)
	for _, root := range roots {
		if physical, err := filepath.EvalSymlinks(root); err == nil && physical != root &&
			!slices.Contains(out, physical) {
			out = append(out, physical)
		}
	}
	return out
}

// ListSessions returns every session transcript belonging to any root of
// the active project, across every provider the active org holds, newest
// first. Each returned session is tagged with the provider whose store it
// came from, and providers whose stores could not be looked inside are
// named in UnreadProviders rather than silently omitted.
//
// "Could not look inside" is a narrower thing than "contributed nothing",
// and the difference is a rule of this function rather than an accident of
// which errno came back. A provider with no session adapter, a root that
// exists but cannot be read, and a record that would not parse are all
// unknowns and are named. A provider whose transcript root simply does not
// exist — a registered account that has never run a session — is a known
// empty and is NOT named: nothing was missed, and a partiality field that
// fires on the ordinary case of a spare account is one nobody reads. That
// also keeps the behaviour this function had before providers existed,
// where a missing root meant an empty listing and no error.
//
// The set of stores to search comes from the org's provider records and
// from nothing ambient. CLAUDE_CONFIG_DIR is not read here or anywhere
// below it — see providerSessionsRoot for what reading it used to cost.
//
// Within one provider's store, worktrees are matched by a two-stage
// process: a cheap, lossy encoded-name prefix filter that is allowed to
// over-match, followed by an exact confirmation against the transcript's
// own recorded cwd.
//
// Stage 2 is MANDATORY, not a tiebreaker: a transcript that offers no cwd
// to confirm against is dropped and counted in Skipped, never included on
// stage 1's word alone. This is the fix for a reproduced cross-project
// leak. The earlier code only ran the cwd check when a cwd was present, so
// a transcript with none — an empty or mid-write file, the exact race
// Skipped exists for — bypassed the confirmation entirely and was
// included; GetSession then read that foreign transcript and returned its
// firstPrompt to the caller. Measured, with the active project rooted at
// <home>/work/app and a sibling project at <home>/work/app-secret, the
// sibling's transcript came back from ListSessions and its first prompt
// came back from GetSession.
//
// The tempting narrower fix — keep a no-cwd transcript when its directory
// matched a root's encoding EXACTLY, and drop it only when it matched via
// the hyphen-extension branch — was considered and MEASURED WRONG. It
// rests on "an exact encoded-name match can only be this project", and
// EncodeRootPath is many-to-one, so that is false. With a root of
// <home>/work/app, ALL THREE of
//
//	<home>/work/app     <home>/work-app     <home>/work.app
//
// encode to the identical directory name, so Claude Code stores three
// different projects' transcripts in ONE directory that matches this
// project's root exactly. A no-cwd transcript sitting there is exactly as
// ambiguous as one in a hyphen-extended directory, and the carve-out
// leaked the sibling's first prompt in a fixture built from those three
// paths. That lossiness is not a new discovery — it is what EncodeRootPath's
// own doc comment means by "a '-' in the output could have come from '/',
// '.' or a literal '-'" — so the encoded name can never be the confirming
// signal, whichever branch matched it.
//
// The cost of dropping is a brand-new session, whose transcript has not
// yet been given a cwd record, being invisible for as long as that is
// true. That is the right trade: Skipped goes non-zero, so the caller is
// told the list may be incomplete rather than being handed another
// project's data, and such a transcript has no first prompt to show
// anyway. (The adversarial review's scan of 394 real transcripts under
// ~/.claude/projects found 0 with no cwd, so the window is narrow in
// practice — it is the consequence, not the frequency, that decides this.)
func ListSessions() (SessionList, error) {
	r, err := Resolve()
	if err != nil {
		return NewSessionList(nil, 0, nil), err
	}
	// r.Org is CurrentOrg()'s value — Resolve has already read it and
	// checked the active project against it — so this searches the same
	// org the project was authorised under, with no second env read that
	// could disagree.
	//
	// listProvidersFor rather than ListProvidersFor: the exported wrapper
	// drops the ids of provider records it could not parse, and a corrupt
	// providers/<id>.json that no caller can name is exactly the kind of
	// silence UnreadProviders exists to break.
	providers, unparsable, err := listProvidersFor(r.Org)
	if err != nil {
		return NewSessionList(nil, 0, nil), err
	}
	unread := append([]string(nil), unparsable...)

	// Computed once, outside the provider loop: the roots and their
	// encodings are a property of the project, not of the store being
	// searched.
	// Each declared root and its physical path (`sessionRootPaths`): the CLI
	// records the second.
	roots := sessionRootPaths(ProjectRootPaths(*r))
	var prefixes []string
	for _, abs := range roots {
		prefixes = append(prefixes, EncodeRootPath(abs))
	}

	// Read once, outside the provider loop: lineage is a property of the
	// org, not of the store being searched. A failed read must not fail
	// the listing — a session whose parent could not be looked up is
	// still a session — so it degrades to empty parents rather than
	// aborting, same as this function's other "could not look" branches.
	parents, err := SessionParentsFor(r.Org)
	if err != nil {
		parents = map[string]string{}
	}

	var out []SessionMeta
	skipped := 0
	for _, p := range providers {
		base, ok := providerSessionsRoot(p)
		if !ok {
			unread = append(unread, p.ID)
			continue
		}
		entries, err := os.ReadDir(base)
		if os.IsNotExist(err) {
			// A provider that has never run a session. Its answer is
			// genuinely empty, not unknown, so it is NOT unread: nothing
			// was missed and there is nothing to warn about. This is also
			// what this function did before providers existed — a missing
			// transcript root returned an empty listing with a nil error —
			// and nothing in the design asked for that to change.
			continue
		}
		if err != nil {
			// Anything else — permissions, or a "projects" that exists but
			// is not a directory — is a store we could not look inside. It
			// does not abort the listing, but it cannot be reported as an
			// empty answer either, so the provider is named. Contrast
			// Skipped, which is only ever reached inside a store this loop
			// did open.
			unread = append(unread, p.ID)
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := e.Name()
			if !matchesAnyEncodedPrefix(name, prefixes) {
				continue
			}
			dir := filepath.Join(base, name)
			files, err := os.ReadDir(dir)
			if err != nil {
				// Permissions or a race against the directory; skip it
				// rather than aborting the whole listing, but count it so
				// the caller can tell an empty answer from an unsearched
				// one.
				skipped++
				continue
			}
			for _, f := range files {
				if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
					continue
				}
				path := filepath.Join(dir, f.Name())
				cwd, hasCwd := firstCwd(path)
				if !hasCwd {
					// Could not confirm, so do not include: stage 1's
					// encoded name matched, but that filter is lossy in
					// both of its branches and cannot stand alone (see this
					// function's doc comment). Counted as skipped, because
					// unlike the branch below we do not know whose
					// transcript this is.
					skipped++
					continue
				}
				if !cwdMatchesAnyRoot(cwd, roots) {
					// A confirmed non-match, not a failure to look: this
					// transcript belongs to another project, so it is not
					// counted as skipped.
					continue
				}
				info, err := f.Info()
				if err != nil {
					skipped++
					continue
				}
				id := strings.TrimSuffix(f.Name(), ".jsonl")
				out = append(out, SessionMeta{
					ID:       id,
					Root:     name,
					Provider: p.ID,
					ModTime:  info.ModTime(),
					Cwd:      cwd,
					Title:    lastAITitle(path),
					// ⌘P's fallback when Title is empty; without it an
					// untitled session is labelled by its id.
					FirstPrompt: firstPrompt(path),
					Parent:      parents[id],
					// Resolved against the whole org's `parents` map,
					// already loaded above for Parent — not against the
					// sessions in this listing, which is filtered to the
					// active project's roots. See the field's own comment.
					LineageRoot: LineageRootIn(parents, id),
				})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	// Sorted so the wire field does not depend on which of the two sources
	// above contributed an id: unparsable records come from one pass over
	// the directory, adapterless and unreadable providers from another.
	sort.Strings(unread)
	return NewSessionList(out, skipped, unread), nil
}

// resolveRootPath turns one configured root into the absolute directory
// whose sessions ListSessions should look for. A relative path is resolved
// against projDir (the directory that holds .wakil/project.json); an
// ABSOLUTE path is taken as-is.
//
// The absolute branch is not redundant with filepath.Join. Join treats
// every argument as a path SEGMENT, not as a path: it does not notice that
// its second element is already absolute, it just concatenates and cleans.
// Measured, with projDir = /Users/operator/wakil.acceptance:
//
//	"/Users/operator/wakil.acceptance"     -> /Users/operator/wakil.acceptance/Users/operator/wakil.acceptance
//	"/Users/operator/wakil.acceptance/src" -> /Users/operator/wakil.acceptance/Users/operator/wakil.acceptance/src
//	"src"                               -> /Users/operator/wakil.acceptance/src
//	"."                                 -> /Users/operator/wakil.acceptance
//
// Only the last two are what the config meant. The first two are why this
// function exists: ListSessions looks up the ENCODING of the resolved
// path, so a doubled prefix matches no real transcript directory and the
// listing comes back EMPTY with a NIL ERROR — indistinguishable from a
// project that genuinely has no sessions, and therefore invisible.
//
// The Phase 1 acceptance run hit exactly that. Its project.json declares
// its roots absolutely ("/Users/operator/wakil.acceptance" and ".../src"),
// following docs/wakil/phase-1-acceptance.md, whose own project.json
// template writes `"roots": [{ "path": "/abs/path/to/repo", … }]` — so an
// operator following the documented setup step by step lands squarely on
// this bug. (The capability-layer plan's example uses relative roots, which
// is why every root in this file's other tests was "." and why nothing here
// had ever exercised the absolute case.) ListSessions returned 0 while three
// real transcripts sat in ~/.claude-personal/projects/-Users-operator-wakil-acceptance.
// The same silence broke GetSession, which filters ListSessions' output:
// asked for a session by ID it reported "session not found for the active
// project" for the very session the caller was running inside.
//
// filepath.Clean is applied on the absolute branch only because Join
// already cleans its result.
func resolveRootPath(projDir, rootPath string) string {
	if filepath.IsAbs(rootPath) {
		return filepath.Clean(rootPath)
	}
	return filepath.Join(projDir, rootPath)
}

// matchesAnyEncodedPrefix reports whether name equals one of prefixes
// exactly, or begins with one of them followed immediately by "-" (the
// encoded path-segment separator). This is only a candidate filter — it is
// allowed to over-match, and BOTH of its branches do: the hyphen-extension
// branch cannot tell an encoded separator from a literal hyphen in a real
// directory name, and even the exact branch over-matches because
// EncodeRootPath is many-to-one (<home>/work/app, <home>/work-app and
// <home>/work.app all encode identically). Callers must confirm membership
// by another signal — cwdMatchesAnyRoot — and must not include a candidate
// they could not confirm.
//
// The `name[len(p)] == '-'` boundary test is what keeps the over-match to
// SIBLINGS rather than to every directory sharing a leading substring:
// without it, an unrelated project at <home>/work/appsecret becomes a
// candidate of a <home>/work/app root, and every transcript in it that
// stage 2 cannot confirm inflates Skipped — telling the caller its
// complete list may be incomplete. It is pinned by
// TestListSessions_PrefixMatchRequiresHyphenBoundary.
func matchesAnyEncodedPrefix(name string, prefixes []string) bool {
	for _, p := range prefixes {
		if name == p {
			return true
		}
		if len(name) > len(p) && strings.HasPrefix(name, p) && name[len(p)] == '-' {
			return true
		}
	}
	return false
}

// cwdMatchesAnyRoot reports whether cwd is exactly one of roots, or a real
// subdirectory of one of them (bounded by an actual path separator).
func cwdMatchesAnyRoot(cwd string, roots []string) bool {
	for _, root := range roots {
		if cwd == root {
			return true
		}
		if strings.HasPrefix(cwd, root+string(os.PathSeparator)) {
			return true
		}
	}
	return false
}

// firstCwd scans a transcript for the first record carrying a non-empty
// "cwd" field and returns it, stopping as soon as one is found. It returns
// ("", false) if no line has a cwd field, including if the file cannot be
// read or is empty.
//
// A false return means "no evidence", never "not ours", and ListSessions
// treats it that way: the transcript is dropped AND counted in Skipped.
// Do not reintroduce a fallback to the stage-1 encoded-name match here —
// that fallback was a reproduced cross-project leak, and stage 1 cannot
// confirm anything on its own in either of its branches (see ListSessions).
func firstCwd(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	for sc.Scan() {
		var rec struct {
			Cwd string `json:"cwd"`
		}
		if json.Unmarshal(sc.Bytes(), &rec) != nil {
			continue
		}
		if rec.Cwd != "" {
			return rec.Cwd, true
		}
	}
	return "", false
}

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

// GetSession looks up a single session by ID among the active project's
// sessions and populates its FirstPrompt.
//
// It has no discovery of its own: it filters ListSessions' output, so
// anything that makes ListSessions come back empty makes GetSession report
// "session not found for the active project" for a session that plainly
// exists. That is not hypothetical — see resolveRootPath, whose absent
// absolute-root handling did exactly this during the Phase 1 acceptance
// run. Any future change here should keep that coupling in mind rather
// than treating a not-found as evidence about the ID alone.
//
// The transcript is then reopened under the store of the provider the
// listing tagged it with, so this reads the same file the listing matched.
// Reading it from any other store would be the provenance failure the
// provider tag exists to prevent — and would usually just fail, since a
// session id exists only in the store of the account that created it.
//
// The org is re-resolved here rather than carried on SessionList: that is
// a wire type, and it must not grow a field for this function's internal
// convenience. The cost is one env read; the alternative is a field every
// MCP client sees and none of them needs.
func GetSession(id string) (SessionMeta, error) {
	all, err := ListSessions()
	if err != nil {
		return SessionMeta{}, err
	}
	var found []SessionMeta
	for _, s := range all.Sessions {
		if s.ID == id {
			found = append(found, s)
		}
	}
	switch len(found) {
	case 0:
		return SessionMeta{}, UserError("session not found for the active project: " + id)
	case 1:
	default:
		// Session ids are uuids minted per session, so two providers
		// holding the same one means something copied a transcript store
		// rather than that the id is ambiguous by design. Refuse rather
		// than pick, and name the providers: picking would silently return
		// one account's history under the other's name.
		var ps []string
		for _, s := range found {
			ps = append(ps, s.Provider)
		}
		return SessionMeta{}, UserError("session id " + id + " exists under more than one provider (" +
			strings.Join(ps, ", ") + ") — this should not happen; report which providers share it")
	}
	s := found[0]
	org, err := CurrentOrg()
	if err != nil {
		return SessionMeta{}, err
	}
	p, err := LoadProviderFor(org, s.Provider)
	if err != nil {
		return SessionMeta{}, err
	}
	base, ok := providerSessionsRoot(*p)
	if !ok {
		return SessionMeta{}, UserError("provider " + s.Provider + " has no session adapter")
	}
	s.FirstPrompt = firstPrompt(filepath.Join(base, s.Root, id+".jsonl"))
	return s, nil
}

// firstPrompt scans a transcript for the first human-typed prompt: a
// "type": "user" record whose message.content yields non-empty text that
// isn't a harness-injected marker (system instructions, reminders, slash
// command echoes, or caveats). The result is truncated to 200 runes.
func firstPrompt(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
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
		if rec.Type != "user" {
			continue
		}
		text := extractUserText(rec.Message.Content)
		if text == "" || hasSkipMarker(text) {
			continue
		}
		return truncateRunes(text, 200)
	}
	return ""
}

// extractUserText pulls human-readable text out of a user record's
// message.content, which is either a plain string or a list of content
// blocks. Only "text" blocks are concatenated; tool_result and any other
// block type are ignored.
func extractUserText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return ""
	}
	var sb strings.Builder
	for _, b := range blocks {
		if b.Type == "text" {
			sb.WriteString(b.Text)
		}
	}
	return sb.String()
}

func hasSkipMarker(text string) bool {
	for _, marker := range firstPromptSkipMarkers {
		if strings.HasPrefix(text, marker) {
			return true
		}
	}
	return false
}

// truncateRunes truncates s to at most n runes, appending "…" when
// truncation occurs. It operates on runes, not bytes, so multi-byte
// characters are never split.
func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "…"
}
