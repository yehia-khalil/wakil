package wakilcore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// A hand-off is a ticket the operator handed to an agent (spec: "The hand-off in the record"):
// written by Wakil only, into the ticket's record, with the organisation's last harness,
// provider and May push kept in tickets/handoff.json. A hand-off from a PR with no ticket key is
// kept by its PR ("pr:<repo>#<n>") in tickets/pr-handoffs.json and writes no ticket record.
// Its live state is the conversation's; only Ended is set here, when the conversation is gone.

// Place is where a handed conversation runs.
type Place struct {
	Organization string `json:"organization"`
	Project      string `json:"project"`
	Environment  string `json:"environment"`
}

// TicketHandoff is one hand-off. MayPush is what the operator's switch said at Start: the stored
// value decides May push for the conversation, a resumed or forked one included.
type TicketHandoff struct {
	ID           string  `json:"id"`
	Conversation string  `json:"conversation"`
	Title        string  `json:"title"`
	Thread       string  `json:"thread"`
	Harness      string  `json:"harness"`
	Provider     string  `json:"provider"`
	Place        Place   `json:"place"`
	MayPush      bool    `json:"mayPush"`
	At           string  `json:"at"`
	Ended        *string `json:"ended"`
}

// HandoffRef is an open hand-off as an In flight row carries it.
type HandoffRef struct {
	ID           string `json:"id"`
	Conversation string `json:"conversation"`
	Thread       string `json:"thread"`
}

func (h TicketHandoff) Ref() HandoffRef {
	return HandoffRef{ID: h.ID, Conversation: h.Conversation, Thread: h.Thread}
}

// HandoffDefaults are the last harness, provider and May push Start used in the organisation.
type HandoffDefaults struct {
	Harness  string `json:"harness"`
	Provider string `json:"provider"`
	MayPush  bool   `json:"mayPush"`
	At       string `json:"at"`
}

const prHandoffPrefix = "pr:"

// PRHandoffKey is how a hand-off from a PR with no ticket key is kept: its repository key
// (<host>/<owner>/<repo>) and number.
func PRHandoffKey(repo string, number int) string {
	return prHandoffPrefix + repo + "#" + strconv.Itoa(number)
}

// IsPRHandoffKey says whether key names a PR rather than a ticket.
func IsPRHandoffKey(key string) bool { return strings.HasPrefix(key, prHandoffPrefix) }

// ParsePRHandoffKey is PRHandoffKey's inverse.
func ParsePRHandoffKey(key string) (repo string, number int, ok bool) {
	rest, found := strings.CutPrefix(key, prHandoffPrefix)
	if !found {
		return "", 0, false
	}
	i := strings.LastIndex(rest, "#")
	if i <= 0 {
		return "", 0, false
	}
	n, err := strconv.Atoi(rest[i+1:])
	if err != nil || n <= 0 {
		return "", 0, false
	}
	return rest[:i], n, true
}

func ticketsDir(org string) (string, error) {
	d, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "tickets"), nil
}

func prHandoffPaths(org string) (file, log, lock string, err error) {
	d, err := ticketsDir(org)
	if err != nil {
		return "", "", "", err
	}
	return filepath.Join(d, "pr-handoffs.json"), filepath.Join(d, "pr-handoffs.log.jsonl"), filepath.Join(d, "pr-handoffs.json.lock"), nil
}

func readPRHandoffsFile(path string) (map[string][]TicketHandoff, error) {
	m := map[string][]TicketHandoff{}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("hand-offs %s are not readable: %w", path, err)
	}
	if m == nil {
		m = map[string][]TicketHandoff{}
	}
	return m, nil
}

// ReadPRHandoffs returns the hand-offs kept by a PR key, empty when there are none.
func ReadPRHandoffs(org, key string) ([]TicketHandoff, error) {
	path, _, _, err := prHandoffPaths(org)
	if err != nil {
		return nil, err
	}
	m, err := readPRHandoffsFile(path)
	if err != nil {
		return nil, err
	}
	if m[key] == nil {
		return []TicketHandoff{}, nil
	}
	return m[key], nil
}

func handoffIDs(hs []TicketHandoff) []string {
	ids := make([]string, len(hs))
	for i, h := range hs {
		ids[i] = h.ID
	}
	return ids
}

// AddTicketHandoff keeps h under key (a ticket key, or a PRHandoffKey) with id h<n>, Wakil's
// time and mayPush, the log line first, then writes the organisation's handoff.json. It returns
// the ticket's record; for a PR key, a record that is never written, carrying the key and its
// hand-offs.
func AddTicketHandoff(org, key string, h TicketHandoff, mayPush bool, now time.Time) (TicketRecord, error) {
	r, err := addTicketHandoff(org, key, h, mayPush, now)
	if err != nil {
		return TicketRecord{}, err
	}
	return r, writeHandoffDefaults(org, HandoffDefaults{Harness: h.Harness, Provider: h.Provider, MayPush: mayPush, At: now.UTC().Format(time.RFC3339)})
}

// addTicketHandoff is AddTicketHandoff without the defaults: a carry keeps what the operator's
// last Start left there.
func addTicketHandoff(org, key string, h TicketHandoff, mayPush bool, now time.Time) (TicketRecord, error) {
	if strings.TrimSpace(h.Conversation) == "" {
		return TicketRecord{}, UserError("a hand-off needs its conversation")
	}
	// One live hand-off per conversation (a fork carries its own under its new id). The check
	// spans files, so it holds no one lock; a duplicate that slips past still reads May push off.
	if hs, err := conversationHandoffs(org, h.Conversation); err == nil {
		for _, o := range hs {
			if o.Ended == nil {
				return TicketRecord{}, UserError("conversation " + strconv.Quote(h.Conversation) + " is already handed to an agent (" + o.ID + ")")
			}
		}
	}
	at := now.UTC().Format(time.RFC3339)
	h.At, h.Ended, h.MayPush = at, nil, mayPush
	var out TicketRecord
	if IsPRHandoffKey(key) {
		if _, _, ok := ParsePRHandoffKey(key); !ok {
			return TicketRecord{}, UserError("hand-off key " + strconv.Quote(key) + " is not a pull request like pr:github.com/initech/api#215")
		}
		path, logPath, lockPath, err := prHandoffPaths(org)
		if err != nil {
			return TicketRecord{}, err
		}
		err = withTicketLock(lockPath, func() error {
			m, err := readPRHandoffsFile(path)
			if err != nil {
				return err
			}
			h.ID = nextLoggedID("h", handoffIDs(m[key]), logPath, "handoffs:"+key)
			if err := appendTicketLog(logPath, map[string]any{
				"at": at, "by": "wakil", "section": "handoffs:" + key, "op": "add", "id": h.ID, "old": nil,
			}); err != nil {
				return err
			}
			m[key] = append(m[key], h)
			if err := writeTicketJSON(path, m); err != nil {
				return err
			}
			out = TicketRecord{Key: key, Handoffs: m[key]}
			out.normalize()
			return nil
		})
		if err != nil {
			return TicketRecord{}, err
		}
	} else {
		path, logPath, lockPath, normKey, err := ticketPaths(org, key)
		if err != nil {
			return TicketRecord{}, err
		}
		err = withTicketLock(lockPath, func() error {
			r, err := readTicketFile(path, normKey)
			if err != nil {
				return err
			}
			h.ID = nextLoggedID("h", handoffIDs(r.Handoffs), logPath, "handoffs")
			if err := appendTicketLog(logPath, map[string]any{
				"at": at, "by": "wakil", "section": "handoffs", "op": "add", "id": h.ID, "old": nil,
			}); err != nil {
				return err
			}
			r.Handoffs = append(r.Handoffs, h)
			if err := writeTicketRecord(path, r); err != nil {
				return err
			}
			out = r
			return nil
		})
		if err != nil {
			return TicketRecord{}, err
		}
	}
	return out, nil
}

// CarryTicketHandoff gives conversation to the hand-off of conversation from — a handed
// conversation resumed into a new conversation — so the new one is priced as handed: a copy under
// the same key (ticket or PR), with its own id, live, logged, and May push as from reads it
// (TicketHandoffMayPush: off unless from has exactly one hand-off and it says on). The newest of
// from's hand-offs is the one copied. No hand-off of from is no carry: an empty key and no error.
// Any file that cannot be read refuses it, so to has no hand-off and reads May push off. The
// organisation's defaults are not touched.
func CarryTicketHandoff(org, from, to string, now time.Time) (string, *TicketHandoff, error) {
	if strings.TrimSpace(from) == "" || strings.TrimSpace(to) == "" {
		return "", nil, UserError("a carry needs the conversation it is from and the one it is to")
	}
	found, err := conversationHandoffsByKey(org, from)
	if err != nil {
		return "", nil, err
	}
	if len(found) == 0 {
		return "", nil, nil
	}
	newest := found[0]
	for _, f := range found[1:] {
		if f.handoff.At > newest.handoff.At {
			newest = f
		}
	}
	h := newest.handoff
	h.Conversation, h.ID = to, ""
	r, err := addTicketHandoff(org, newest.key, h, len(found) == 1 && h.MayPush, now)
	if err != nil {
		return "", nil, err
	}
	added := r.Handoffs[len(r.Handoffs)-1]
	return newest.key, &added, nil
}

func handoffDefaultsPaths(org string) (file, lock string, err error) {
	d, err := ticketsDir(org)
	if err != nil {
		return "", "", err
	}
	return filepath.Join(d, "handoff.json"), filepath.Join(d, "handoff.json.lock"), nil
}

func writeHandoffDefaults(org string, d HandoffDefaults) error {
	path, lockPath, err := handoffDefaultsPaths(org)
	if err != nil {
		return err
	}
	return withTicketLock(lockPath, func() error { return writeTicketJSON(path, d) })
}

// ReadHandoffDefaults returns the organisation's last Start, and whether there was one.
func ReadHandoffDefaults(org string) (HandoffDefaults, bool, error) {
	path, _, err := handoffDefaultsPaths(org)
	if err != nil {
		return HandoffDefaults{}, false, err
	}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return HandoffDefaults{}, false, nil
	}
	if err != nil {
		return HandoffDefaults{}, false, err
	}
	var d HandoffDefaults
	if err := json.Unmarshal(b, &d); err != nil {
		return HandoffDefaults{}, false, fmt.Errorf("hand-off defaults %s are not readable: %w", path, err)
	}
	return d, true, nil
}

// ticketRecordKeys are the keys of the organisation's ticket records on disk.
func ticketRecordKeys(org string) ([]string, error) {
	d, err := ticketsDir(org)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(d)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var keys []string
	for _, e := range entries {
		if k, ok := strings.CutSuffix(e.Name(), ".json"); ok && ticketKeyRE.MatchString(k) {
			keys = append(keys, k)
		}
	}
	return keys, nil
}

// EndTicketHandoffs sets Ended on open hand-offs, across the organisation's records and PRs:
// those whose conversation is in conversations, or with keepLive, every one whose conversation is
// not (the live ones), as after a quit or an organisation switch. Each end is logged with the
// hand-off it ended. A record that cannot be read is passed over and named in the error.
func EndTicketHandoffs(org string, conversations []string, keepLive bool, now time.Time) error {
	listed := map[string]bool{}
	for _, c := range conversations {
		listed[c] = true
	}
	ends := func(h TicketHandoff) bool { return h.Ended == nil && listed[h.Conversation] != keepLive }
	at := now.UTC().Format(time.RFC3339)
	// endIn ends hs's matching hand-offs in place, logging each, and says whether any ended.
	endIn := func(hs []TicketHandoff, logPath, section string) (bool, error) {
		changed := false
		for i, h := range hs {
			if !ends(h) {
				continue
			}
			if err := appendTicketLog(logPath, map[string]any{
				"at": at, "by": "wakil", "section": section, "op": "end", "id": h.ID, "old": h,
			}); err != nil {
				return changed, err
			}
			e := at
			hs[i].Ended = &e
			changed = true
		}
		return changed, nil
	}
	var errs []error
	keys, err := ticketRecordKeys(org)
	if err != nil {
		return err
	}
	for _, key := range keys {
		path, logPath, lockPath, normKey, err := ticketPaths(org, key)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		// A read without the lock first: most records have nothing to end.
		r, err := readTicketFile(path, normKey)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		due := false
		for _, h := range r.Handoffs {
			due = due || ends(h)
		}
		if !due {
			continue
		}
		errs = append(errs, withTicketLock(lockPath, func() error {
			r, err := readTicketFile(path, normKey)
			if err != nil {
				return err
			}
			changed, err := endIn(r.Handoffs, logPath, "handoffs")
			if err != nil || !changed {
				return err
			}
			return writeTicketRecord(path, r)
		}))
	}
	path, logPath, lockPath, err := prHandoffPaths(org)
	if err != nil {
		return errors.Join(append(errs, err)...)
	}
	if _, err := os.Stat(path); err == nil {
		errs = append(errs, withTicketLock(lockPath, func() error {
			m, err := readPRHandoffsFile(path)
			if err != nil {
				return err
			}
			changed := false
			for key, hs := range m {
				c, err := endIn(hs, logPath, "handoffs:"+key)
				if err != nil {
					return err
				}
				changed = changed || c
			}
			if !changed {
				return nil
			}
			return writeTicketJSON(path, m)
		}))
	}
	return errors.Join(errs...)
}

// OpenTicketHandoffs returns every key (ticket or PR) with an open hand-off, and those hand-offs.
// Records that cannot be read are passed over.
func OpenTicketHandoffs(org string) (map[string][]TicketHandoff, error) {
	out := map[string][]TicketHandoff{}
	add := func(key string, hs []TicketHandoff) {
		for _, h := range hs {
			if h.Ended == nil {
				out[key] = append(out[key], h)
			}
		}
	}
	keys, err := ticketRecordKeys(org)
	if err != nil {
		return nil, err
	}
	for _, key := range keys {
		if r, err := ReadTicketRecord(org, key); err == nil {
			add(r.Key, r.Handoffs)
		}
	}
	path, _, _, err := prHandoffPaths(org)
	if err != nil {
		return nil, err
	}
	m, err := readPRHandoffsFile(path)
	if err != nil {
		return out, err
	}
	prKeys := make([]string, 0, len(m))
	for k := range m {
		prKeys = append(prKeys, k)
	}
	sort.Strings(prKeys)
	for _, k := range prKeys {
		add(k, m[k])
	}
	return out, nil
}

// conversationHandoffs are every hand-off of conversation, ended or not, across the
// organisation's records and PRs. Any file it cannot read is an error: a hand-off in it may be
// the conversation's.
func conversationHandoffs(org, conversation string) ([]TicketHandoff, error) {
	found, err := conversationHandoffsByKey(org, conversation)
	if err != nil {
		return nil, err
	}
	out := make([]TicketHandoff, len(found))
	for i, f := range found {
		out[i] = f.handoff
	}
	return out, nil
}

type keyedHandoff struct {
	key     string
	handoff TicketHandoff
}

// conversationHandoffsByKey is conversationHandoffs with the key (ticket or PR) each is kept by.
func conversationHandoffsByKey(org, conversation string) ([]keyedHandoff, error) {
	keys, err := ticketRecordKeys(org)
	if err != nil {
		return nil, err
	}
	var out []keyedHandoff
	for _, key := range keys {
		r, err := ReadTicketRecord(org, key)
		if err != nil {
			return nil, err
		}
		for _, h := range r.Handoffs {
			if h.Conversation == conversation {
				out = append(out, keyedHandoff{r.Key, h})
			}
		}
	}
	path, _, _, err := prHandoffPaths(org)
	if err != nil {
		return nil, err
	}
	m, err := readPRHandoffsFile(path)
	if err != nil {
		return nil, err
	}
	for key, hs := range m {
		for _, h := range hs {
			if h.Conversation == conversation {
				out = append(out, keyedHandoff{key, h})
			}
		}
	}
	return out, nil
}

// TicketHandoffMayPush is May push for a conversation: its stored hand-off's, ended or not, so a
// resumed or forked conversation keeps what the operator chose. It reads on only when exactly one
// hand-off names the conversation and it says on; none, several, or any file that cannot be read
// is off, whatever order the files are read in.
func TicketHandoffMayPush(org, conversation string) bool {
	if conversation == "" {
		return false
	}
	hs, err := conversationHandoffs(org, conversation)
	return err == nil && len(hs) == 1 && hs[0].MayPush
}
