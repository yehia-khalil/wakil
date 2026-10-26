package wakilcore

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// A ticket's record is Wakil's own store (spec: "The ticket record"): one JSON file per
// ticket under the organisation folder, with an append-only log beside it that holds the old
// line before every change. The operator's and an agent's writes run in separate
// wakil-ticket processes, so every write holds a file lock per ticket key.

// TicketLine is one line of the record. Only ID, By and At are always written.
type TicketLine struct {
	ID           string `json:"id"`
	Text         string `json:"text,omitempty"`
	Why          string `json:"why,omitempty"`
	How          string `json:"how,omitempty"`
	Who          string `json:"who,omitempty"`
	What         string `json:"what,omitempty"`
	State        string `json:"state,omitempty"`
	By           string `json:"by"`
	Conversation string `json:"conversation,omitempty"`
	At           string `json:"at"`
	Edited       string `json:"edited,omitempty"`
}

// TicketSeen is the cache of the last read of the ticket in the PM tool.
type TicketSeen struct {
	Title    string `json:"title,omitempty"`
	Status   string `json:"status,omitempty"`
	Assignee string `json:"assignee,omitempty"`
	URL      string `json:"url,omitempty"`
	At       string `json:"at,omitempty"`
}

type TicketBranchRef struct {
	Repo   string `json:"repo"`
	Branch string `json:"branch"`
	Source string `json:"source"`
}

type TicketPRRef struct {
	Repo   string `json:"repo"`
	Number int    `json:"number"`
	State  string `json:"state"`
}

type TicketRecord struct {
	Key       string            `json:"key"`
	Seen      TicketSeen        `json:"seen"`
	Branches  []TicketBranchRef `json:"branches"`
	PRs       []TicketPRRef     `json:"prs"`
	Next      *TicketLine       `json:"next,omitempty"`
	Decisions []TicketLine      `json:"decisions"`
	NotDone   []TicketLine      `json:"notDone"`
	WaitingOn []TicketLine      `json:"waitingOn"`
	Verified  []TicketLine      `json:"verified"`
	Rulings   []TicketLine      `json:"rulings"`
}

// TicketEdit is one change to the record. Line carries the text fields only; By and
// Conversation come from the caller's dispatch origin, never from the line.
type TicketEdit struct {
	Section      string // "next" | "decisions" | "notDone" | "waitingOn" | "verified" | "rulings"
	Op           string // "set" (next only) | "add" | "edit" | "remove"
	ID           string // edit, remove
	Line         TicketLine
	By           string
	Conversation string
}

var ticketKeyRE = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*-[0-9]+$`)

// ticketSectionLetter maps each list section to the first letter of its line ids.
var ticketSectionLetter = map[string]string{
	"decisions": "d", "notDone": "n", "waitingOn": "w", "verified": "v", "rulings": "r",
}

// renameTicketFile is the publish step of a write; tests replace it to fail the rename.
var renameTicketFile = os.Rename

func ticketPaths(org, key string) (record, log, lock, normKey string, err error) {
	if !ticketKeyRE.MatchString(key) {
		return "", "", "", "", UserError("ticket key " + strconv.Quote(key) + " is not a key like INI-142")
	}
	key = strings.ToUpper(key)
	orgDir, err := OrgDirFor(org)
	if err != nil {
		return "", "", "", "", err
	}
	dir := filepath.Join(orgDir, "tickets")
	return filepath.Join(dir, key+".json"), filepath.Join(dir, key+".log.jsonl"), filepath.Join(dir, key+".json.lock"), key, nil
}

// ReadTicketRecord returns the record, or an empty one for the key when none exists. It
// writes nothing: the file is replaced by rename, so a read needs no lock.
func ReadTicketRecord(org, key string) (TicketRecord, error) {
	path, _, _, key, err := ticketPaths(org, key)
	if err != nil {
		return TicketRecord{}, err
	}
	return readTicketFile(path, key)
}

func readTicketFile(path, key string) (TicketRecord, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return TicketRecord{Key: key}, nil
	}
	if err != nil {
		return TicketRecord{}, err
	}
	var r TicketRecord
	if err := json.Unmarshal(b, &r); err != nil {
		return TicketRecord{}, fmt.Errorf("ticket record %s is not readable: %w", path, err)
	}
	r.Key = key
	return r, nil
}

// withTicketLock runs fn holding the ticket's file lock.
func withTicketLock(lockPath string, fn func() error) error {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

func appendTicketLog(logPath string, entry map[string]any) error {
	b, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func writeTicketRecord(path string, r TicketRecord) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return renameTicketFile(tmp.Name(), path)
}

func ticketSection(r *TicketRecord, section string) *[]TicketLine {
	switch section {
	case "decisions":
		return &r.Decisions
	case "notDone":
		return &r.NotDone
	case "waitingOn":
		return &r.WaitingOn
	case "verified":
		return &r.Verified
	case "rulings":
		return &r.Rulings
	}
	return nil
}

// nextTicketID is the section letter plus one more than the highest number ever used in
// the section, counting the log, so a removed line's id is never handed out again.
func nextTicketID(r *TicketRecord, logPath, section string) string {
	letter := ticketSectionLetter[section]
	max := 0
	note := func(id string) {
		if strings.HasPrefix(id, letter) {
			if n, err := strconv.Atoi(id[len(letter):]); err == nil && n > max {
				max = n
			}
		}
	}
	for _, l := range *ticketSection(r, section) {
		note(l.ID)
	}
	if f, err := os.Open(logPath); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
		for sc.Scan() {
			var e struct {
				Section string `json:"section"`
				ID      string `json:"id"`
			}
			if json.Unmarshal(sc.Bytes(), &e) == nil && e.Section == section {
				note(e.ID)
			}
		}
	}
	return letter + strconv.Itoa(max+1)
}

// replaceTicketLine builds the line an edit leaves: the caller's text fields over the old
// line's identity. An agent editing an operator's line keeps By: operator and says it edited.
func replaceTicketLine(old TicketLine, e TicketEdit, now string) TicketLine {
	l := e.Line
	l.ID = old.ID
	l.At = now
	l.By, l.Conversation, l.Edited = e.By, e.Conversation, ""
	if e.By == "agent" && old.By == "operator" {
		l.By, l.Conversation, l.Edited = "operator", old.Conversation, "agent"
		l.At = old.At
	}
	return l
}

// UpdateTicketRecord applies one edit. The old line is written to the log before the record
// changes, so a failed publish leaves the log ahead of the record, never behind it.
func UpdateTicketRecord(org, key string, e TicketEdit, now time.Time) (TicketRecord, error) {
	path, logPath, lockPath, key, err := ticketPaths(org, key)
	if err != nil {
		return TicketRecord{}, err
	}
	if e.Section != "next" && ticketSection(&TicketRecord{}, e.Section) == nil {
		return TicketRecord{}, UserError("unknown ticket section " + strconv.Quote(e.Section))
	}
	switch {
	case e.Section == "next" && e.Op != "set":
		return TicketRecord{}, UserError("the next line is set, not " + strconv.Quote(e.Op))
	case e.Section != "next" && e.Op != "add" && e.Op != "edit" && e.Op != "remove":
		return TicketRecord{}, UserError("unknown ticket operation " + strconv.Quote(e.Op))
	}
	at := now.UTC().Format(time.RFC3339)
	var out TicketRecord
	err = withTicketLock(lockPath, func() error {
		r, err := readTicketFile(path, key)
		if err != nil {
			return err
		}
		var old *TicketLine
		id := e.ID
		if e.Section == "next" {
			old = r.Next
			if old != nil {
				id = old.ID
			}
			l := e.Line
			l.ID, l.At, l.By, l.Conversation = "next", at, e.By, e.Conversation
			if old != nil {
				l = replaceTicketLine(*old, e, at)
				l.ID = "next"
			}
			if err := logTicketChange(logPath, at, e, "next", old); err != nil {
				return err
			}
			r.Next = &l
		} else {
			lines := ticketSection(&r, e.Section)
			idx := -1
			if e.Op != "add" {
				for i, l := range *lines {
					if l.ID == e.ID {
						idx = i
					}
				}
				if idx < 0 {
					return UserError("no line " + strconv.Quote(e.ID) + " in " + e.Section)
				}
				o := (*lines)[idx]
				old = &o
			}
			switch e.Op {
			case "add":
				id = nextTicketID(&r, logPath, e.Section)
				l := e.Line
				l.ID, l.At, l.By, l.Conversation, l.Edited = id, at, e.By, e.Conversation, ""
				if err := logTicketChange(logPath, at, e, id, nil); err != nil {
					return err
				}
				*lines = append(*lines, l)
			case "edit":
				if err := logTicketChange(logPath, at, e, id, old); err != nil {
					return err
				}
				(*lines)[idx] = replaceTicketLine(*old, e, at)
			case "remove":
				if err := logTicketChange(logPath, at, e, id, old); err != nil {
					return err
				}
				*lines = append((*lines)[:idx:idx], (*lines)[idx+1:]...)
			}
		}
		if err := writeTicketRecord(path, r); err != nil {
			return err
		}
		out = r
		return nil
	})
	return out, err
}

func logTicketChange(logPath, at string, e TicketEdit, id string, old *TicketLine) error {
	var o any
	if old != nil {
		o = old
	}
	return appendTicketLog(logPath, map[string]any{
		"at": at, "by": e.By, "section": e.Section, "op": e.Op, "id": id, "old": o,
	})
}

// RecordTicketSeen merges what a read found into the record: seen is replaced when given,
// branches and PRs are added or updated and never dropped, so the record outlives a deleted
// branch. It is a cache of reads and is not logged.
func RecordTicketSeen(org, key string, seen TicketSeen, b []TicketBranchRef, prs []TicketPRRef) error {
	path, _, lockPath, key, err := ticketPaths(org, key)
	if err != nil {
		return err
	}
	return withTicketLock(lockPath, func() error {
		r, err := readTicketFile(path, key)
		if err != nil {
			return err
		}
		if seen != (TicketSeen{}) {
			r.Seen = seen
		}
	branches:
		for _, nb := range b {
			for i, ob := range r.Branches {
				if ob.Repo == nb.Repo && ob.Branch == nb.Branch {
					r.Branches[i] = nb
					continue branches
				}
			}
			r.Branches = append(r.Branches, nb)
		}
	pulls:
		for _, np := range prs {
			for i, op := range r.PRs {
				if op.Repo == np.Repo && op.Number == np.Number {
					r.PRs[i] = np
					continue pulls
				}
			}
			r.PRs = append(r.PRs, np)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		return writeTicketRecord(path, r)
	})
}
