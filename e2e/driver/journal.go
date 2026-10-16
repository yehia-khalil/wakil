package driver

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// JournalReader answers what the app recorded about its own actions.
//
// **The fourth observation source, and it is the filesystem.** The tree says
// what is on screen, `read_pane` says what a pane contains, the process table
// says what is still running — and none of them can answer 2c-iii's check 9,
// *"the new run still appears in the journal"*. That defect was invisible on
// screen by construction: an organisation switch silently stopped every later
// command being journalled, and the window looked exactly the same.
type JournalReader interface {
	Entries() ([]string, error)
}

// FileJournal reads an instance's journal off disk.
//
// **`$HOME/.wakil/journal/<session>.jsonl`**, which is what
// `WindowSession.start` computes from the same `HOME` the fixture sets. The
// harness already owns that directory: it is the fixture's own home, so this
// can never read the operator's journal.
type FileJournal struct {
	Home string
}

// Entries returns every line of every session file.
//
// **Every file, not the newest.** An organisation switch is the case this
// exists for, and a reader that opened one file would have to guess which;
// guessing wrong looks exactly like the defect being retrodicted.
//
// A journal directory that is not there yields no entries and no error — the
// app writes it lazily, so its absence is an ordinary early state. What that
// must never do is make an assertion pass, and `Contains` cannot be satisfied
// by an empty list.
func (j FileJournal) Entries() ([]string, error) {
	dir := filepath.Join(j.Home, ".wakil", "journal")
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, fmt.Errorf("reading the journal at %s: %w", dir, err)
	}
	var entries []string
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", file, err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			if trimmed := strings.TrimSpace(line); trimmed != "" {
				entries = append(entries, trimmed)
			}
		}
	}
	return entries, nil
}

// assertJournal proves the app recorded something.
func (r *Runner) assertJournal(expect *JournalExpectation) error {
	if r.Journal == nil {
		return fmt.Errorf("no journal is available, so nothing about %q is known", expect.Contains)
	}
	entries, err := r.Journal.Entries()
	if err != nil {
		return fmt.Errorf("the journal could not be read (%w), so nothing about %q is known",
			err, expect.Contains)
	}
	for _, entry := range entries {
		if strings.Contains(entry, expect.Contains) {
			return nil
		}
	}
	// **The count is the diagnosis.** `0 entries` is the signature of the
	// defect this arm retrodicts — the journal stopped being written at all —
	// and it is a different fault from "twelve entries, none of them this
	// one", which means the action was never dispatched.
	return fmt.Errorf("no journal entry carries %q (%d entr%s read)",
		expect.Contains, len(entries), plural(len(entries), "y", "ies"))
}

// plural picks a word for a count, so a failure reads as a sentence rather
// than as "1 entries".
func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
