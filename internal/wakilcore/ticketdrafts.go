package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Reply drafts are kept per organisation in tickets/drafts.json, keyed by review thread id
// (spec: "Drafts the agent writes"), so a handed agent's draft outlives the window. By comes
// from the window's dispatch origin, never from the caller's words.

// TicketDraft is one thread's draft reply. Replaced is the operator's text an agent's draft
// replaced, kept so the operator can restore it; an operator's write clears it.
type TicketDraft struct {
	Text         string `json:"text"`
	By           string `json:"by"`
	Conversation string `json:"conversation"`
	Root         string `json:"root"`
	Branch       string `json:"branch"`
	At           string `json:"at"`
	Replaced     string `json:"replaced,omitempty"`
}

func draftsPaths(org string) (file, lock string, err error) {
	d, err := OrgDirFor(org)
	if err != nil {
		return "", "", err
	}
	d = filepath.Join(d, "tickets")
	return filepath.Join(d, "drafts.json"), filepath.Join(d, "drafts.json.lock"), nil
}

// ReadTicketDrafts returns the organisation's drafts by thread id; empty, and nothing written,
// when there are none. The file is replaced by rename, so a read needs no lock.
func ReadTicketDrafts(org string) (map[string]TicketDraft, error) {
	path, _, err := draftsPaths(org)
	if err != nil {
		return nil, err
	}
	return readDraftsFile(path)
}

func readDraftsFile(path string) (map[string]TicketDraft, error) {
	m := map[string]TicketDraft{}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return m, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("drafts %s are not readable: %w", path, err)
	}
	if m == nil {
		m = map[string]TicketDraft{}
	}
	return m, nil
}

// WriteTicketDraft sets thread's draft, or removes it when d is nil or its text is empty, and
// returns every draft after the write. An agent's draft over the operator's keeps the operator's
// text in Replaced (and an agent's later draft keeps it still); an operator's draft clears it.
func WriteTicketDraft(org, thread string, d *TicketDraft, now time.Time) (map[string]TicketDraft, error) {
	thread = strings.TrimSpace(thread)
	if thread == "" {
		return nil, UserError("a draft needs its review thread")
	}
	if d != nil && d.Text != "" && d.By != "operator" && d.By != "agent" {
		return nil, UserError("a draft's by is operator or agent, not " + strconv.Quote(d.By))
	}
	path, lockPath, err := draftsPaths(org)
	if err != nil {
		return nil, err
	}
	var out map[string]TicketDraft
	err = withTicketLock(lockPath, func() error {
		m, err := readDraftsFile(path)
		if err != nil {
			return err
		}
		if d == nil || d.Text == "" {
			if _, ok := m[thread]; !ok {
				out = m
				return nil
			}
			delete(m, thread)
		} else {
			nd := *d
			nd.At = now.UTC().Format(time.RFC3339)
			nd.Replaced = ""
			if old, ok := m[thread]; ok && nd.By == "agent" {
				nd.Replaced = old.Replaced
				if old.By == "operator" {
					nd.Replaced = old.Text
				}
			}
			m[thread] = nd
		}
		if err := writeTicketJSON(path, m); err != nil {
			return err
		}
		out = m
		return nil
	})
	return out, err
}
