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

// NewErrSessionThread builds the SessionThread an error path hands back
// alongside a non-nil error, with a guaranteed non-nil Entries so its JSON
// is {"entries":[],...} rather than {"entries":null,...}.
//
// This is not cosmetic. Measured against this module's actual go-sdk
// v1.7.0: when a tool handler returns (errorResult, zeroOut, nil), the
// SDK's toolForErr wrapper marshals out and sets res.StructuredContent
// regardless of IsError — the error message and the zero-value payload
// both travel to the client. Entries has no omitempty (it is the
// substance of a successful read, not an optional extra), so the ordinary
// zero value SessionThread{} marshals its nil slice as null, against a
// tool whose own advertised output schema types entries as a non-nullable
// array. Same guarantee, same reason, as NewSessionList's Sessions.
func NewErrSessionThread() SessionThread {
	return SessionThread{Entries: []ThreadEntry{}}
}

// locatedSession is one match locateSession found for a given id under one
// provider's store.
type locatedSession struct {
	path     string
	provider string
	cwd      string
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
//
// It agrees with GetSession (sessions.go) on what to do when an id exists
// under more than one provider: collect every match and refuse rather than
// return the first one found. That matters more here than it does there.
// GetSession's Provider is a display field; this one's Provider is what a
// later task compares against the running provider to decide whether a
// resume is even allowed, so picking the wrong one silently would either
// resume the wrong account's conversation or refuse for a reason that
// names the wrong account.
func locateSession(id string) (path string, provider string, cwd string, err error) {
	org, err := CurrentOrg()
	if err != nil {
		return "", "", "", err
	}
	providers, _, err := listProvidersFor(org)
	if err != nil {
		return "", "", "", err
	}
	var found []locatedSession
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
			found = append(found, locatedSession{path: candidate, provider: p.ID, cwd: c})
			break
		}
	}
	switch len(found) {
	case 0:
		return "", "", "", UserError("session not found in any of this org's providers: " + id)
	case 1:
		return found[0].path, found[0].provider, found[0].cwd, nil
	default:
		// Session ids are uuids minted per session, so two providers
		// holding the same one means something copied a transcript store
		// rather than that the id is ambiguous by design. Refuse rather
		// than pick, and name the providers: picking would silently return
		// one account's history under the other's name. Mirrors
		// GetSession's switch len(found) block.
		var ps []string
		for _, f := range found {
			ps = append(ps, f.provider)
		}
		return "", "", "", UserError("session id " + id + " exists under more than one provider (" +
			strings.Join(ps, ", ") + ") — this should not happen; report which providers share it")
	}
}

// ReadSession reads one session's transcript into thread entries, keeping
// the last `limit` of them.
//
// It refuses a session whose recorded working directory is not one of the
// active project's roots, naming that directory. Resuming there anyway is
// not a harmless default: the CLI accepts a foreign cwd, keeps the
// transcript in the original project's directory and writes records
// carrying the new one, so the file ends up describing two places at once
// (session-resume-probe.md §8).
func ReadSession(id string, limit int) (SessionThread, error) {
	path, provider, cwd, err := locateSession(id)
	if err != nil {
		return NewErrSessionThread(), err
	}
	r, err := Resolve()
	if err != nil {
		return NewErrSessionThread(), err
	}
	// A root's physical path is that root too (`sessionRootPaths`): the CLI records it.
	if !cwdMatchesAnyRoot(cwd, sessionRootPaths(ProjectRootPaths(*r))) {
		return NewErrSessionThread(), UserError(
			"session " + id + " ran in " + cwd +
				", which is not a root of the active project " + r.Project.Name +
				" — re-declare that root or start a fresh session")
	}
	entries, err := readThreadEntries(path)
	if err != nil {
		return NewErrSessionThread(), err
	}
	out := SessionThread{Cwd: cwd, Provider: provider, Entries: []ThreadEntry{}}
	if limit > 0 && len(entries) > limit {
		out.Entries = entries[len(entries)-limit:]
		out.Truncated = true
	} else if entries != nil {
		out.Entries = entries
	}
	// Deliberately swallowed: the parent is used only for the thought
	// thread's seam label and for grouping in the command palette, so a
	// failed lineage read costs a label, never the session. Failing an
	// otherwise-valid resume over that would make ReadSession less
	// reliable than the lineage store it is merely decorating with.
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
//
// sc.Err() is checked after the loop and turned into a real error rather
// than left silent. bufio.Scanner stops iterating — without panicking or
// otherwise announcing itself — the moment it hits a token above its 8 MB
// cap or a mid-read I/O error, and without this check the entries decoded
// from whatever came BEFORE that point would travel back as a complete,
// untruncated SessionThread: ReadSession sets Truncated only from the
// `limit` comparison, which never runs for this reason, so the caller
// would see `{"entries":[...first half...],"truncated":false}` — a thread
// that claims completeness while quietly missing everything after the
// oversized line. That crosses the same "could not look" vs "looked and
// found nothing" line SessionList.Skipped and SessionThread.Truncated's
// own doc comments draw, just from the opposite direction: those exist so
// an incomplete answer is never mistaken for an empty one; this is so an
// incomplete answer is never mistaken for a COMPLETE one.
//
// An error, not a widened Truncated, because the two failures do not mean
// the same thing to a caller. Truncated today promises "every entry
// returned is genuine, some earlier ones were dropped to honour `limit`"
// — a caller can render that thread as-is and say so in the UI. A scan
// that gave up mid-file offers no such promise: there is no way to tell
// whether the abandoned tail held a `user`/`assistant` record that would
// change what the operator sees, or none at all, and ReadSession's own
// existing error path (NewErrSessionThread paired with a non-nil error)
// already exists for exactly "something about this session made it
// unreadable" — reusing it costs nothing new, where overloading
// Truncated's meaning would require every existing caller to relearn what
// the field can mean. firstCwd (sessions.go) takes the same
// fail-differently-from-empty shape for the same reason: it converts an
// identical scan failure into `("", false)`, and `false` is what its
// caller, locateSession, already reads as "could not find a cwd record"
// and refuses on — the failure was never silently folded into "found
// nothing to report".
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
	if err := sc.Err(); err != nil {
		return nil, UserError("session transcript ended early while reading it: " + err.Error())
	}
	return out, nil
}

// blockEntries maps one message's content into entries. Content is either
// a plain string (an older/simpler record shape, as firstPrompt already
// handles via extractUserText) or an array of typed blocks — the same
// ambiguity, resolved the same way: try the plain string first, and fall
// back to the typed-block array.
func blockEntries(recordType string, content json.RawMessage) []ThreadEntry {
	if len(content) == 0 {
		return nil
	}
	// An operator's row is what the operator typed: the blocks the window appends after the
	// words (the workspace map) are left out, as firstPrompt leaves them out of the label.
	words := func(text string) string {
		if recordType == "user" {
			return withoutWakilBlocks(text)
		}
		return text
	}
	var plain string
	if json.Unmarshal(content, &plain) == nil {
		plain = words(plain)
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
			text := words(b.Text)
			if strings.TrimSpace(text) == "" {
				continue
			}
			out = append(out, ThreadEntry{Kind: recordType, Text: text})
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
