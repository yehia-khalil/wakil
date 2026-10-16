package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func journalHome(t *testing.T, sessions map[string]string) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".wakil", "journal")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range sessions {
		if err := os.WriteFile(filepath.Join(dir, name+".jsonl"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

// **Every session file, not the newest one.** An organisation switch is the
// case this arm exists for, and the defect it retrodicts is precisely that
// the entries stopped arriving; a reader that opened one file would have to
// guess which, and guessing wrong looks identical to the defect.
func TestFileJournalReadsEverySessionFile(t *testing.T) {
	home := journalHome(t, map[string]string{
		"before": `{"action":"pane_open"}` + "\n",
		"after":  `{"action":"term_open"}` + "\n",
	})
	entries, err := (FileJournal{Home: home}).Entries()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("want both files' entries, got %v", entries)
	}
}

// A journal directory that is not there is an ordinary state — the app writes
// it lazily — and yields no entries rather than an error. What it must NOT do
// is make an assertion pass.
func TestFileJournalIsEmptyWhenNothingHasBeenWrittenYet(t *testing.T) {
	entries, err := (FileJournal{Home: t.TempDir()}).Entries()
	if err != nil {
		t.Fatalf("an unwritten journal is not an error: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("got %v", entries)
	}
}

func TestExpectJournalPassesWhenTheEntryIsThere(t *testing.T) {
	home := journalHome(t, map[string]string{"s": `{"action":"pane_open","paneId":"terminal-2"}` + "\n"})
	runner := &Runner{Journal: FileJournal{Home: home}}
	if err := runner.assertJournal(&JournalExpectation{Contains: "terminal-2"}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

// **A journal with nothing in it must not read as "not found among many".**
// The 2c-iii defect was that an organisation switch silently stopped every
// later command being journalled, so "0 entries" IS the defect's signature
// and the failure has to say it in those words.
func TestExpectJournalSaysHowManyEntriesItRead(t *testing.T) {
	runner := &Runner{Journal: FileJournal{Home: t.TempDir()}}
	err := runner.assertJournal(&JournalExpectation{Contains: "pane_open"})
	if err == nil {
		t.Fatal("want a failure: nothing was journalled at all")
	}
	if !strings.Contains(err.Error(), "0 entr") {
		t.Fatalf("the failure must say how many entries it read, got %q", err)
	}
}

// No journal reader wired is an infrastructure failure, not a quiet pass —
// the same rule `assertProcess` already holds for the process table.
func TestExpectJournalRefusesToAssertWithNoReader(t *testing.T) {
	runner := &Runner{}
	if err := runner.assertJournal(&JournalExpectation{Contains: "x"}); err == nil {
		t.Fatal("want an error: there is no journal to read")
	}
}

func TestParseChecksReadsAJournalExpectation(t *testing.T) {
	check, err := ParseChecks("switch", []byte(`{"expect":{"journal":{"contains":"pane_open"}}}`+"\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if check.Steps[0].Expect.Journal == nil || check.Steps[0].Expect.Journal.Contains != "pane_open" {
		t.Fatalf("got %+v", check.Steps[0].Expect)
	}
}

func TestParseChecksRefusesAJournalExpectationWithNoText(t *testing.T) {
	if _, err := ParseChecks("switch", []byte(`{"expect":{"journal":{}}}`+"\n")); err == nil {
		t.Fatal("want a refusal: a journal expectation with no text asserts nothing")
	}
}

// A journal read is a positive read of what the app recorded, so it clears a
// pending unverified act — unlike `tree: absent`, which passes just as well
// when nothing ever happened.
func TestJournalExpectationConfirmsAPendingAct(t *testing.T) {
	if !(&Expect{Journal: &JournalExpectation{Contains: "pane_open"}}).Confirms() {
		t.Fatal("a journal entry found is evidence the act landed")
	}
}

// **`any-matching` exists so that `none-matching` cannot pass vacuously.**
// 2c-iii's check 6 is "`tail -f` something, close the pane, then `ps` — no
// orphan". Asserted with `none-matching` alone, that check passes just as
// cleanly when the `tail` never started at all, which is the exact shape of
// silent success this harness was built to refuse.
func TestExpectProcessAnyMatchingProvesThePatternWasThere(t *testing.T) {
	runner := &Runner{Processes: fakeProcesses{matches: map[string][]string{
		"tail -f marker": {"4242 tail -f marker"},
	}}}
	if err := runner.assertProcess(&Process{AnyMatching: "tail -f marker"}); err != nil {
		t.Fatalf("unexpected failure: %v", err)
	}
}

func TestExpectProcessAnyMatchingFailsWhenNothingIsRunning(t *testing.T) {
	runner := &Runner{Processes: fakeProcesses{}}
	err := runner.assertProcess(&Process{AnyMatching: "tail -f marker"})
	if err == nil {
		t.Fatal("want a failure: nothing matched, so the later none-matching would prove nothing")
	}
	if !strings.Contains(err.Error(), "tail -f marker") {
		t.Fatalf("got %q", err)
	}
}

// A process step names exactly one of the two, for the same reason every
// other step kind does.
func TestParseChecksRefusesAProcessStepWithBothPredicates(t *testing.T) {
	_, err := ParseChecks("orphan", []byte(
		`{"expect":{"process":{"none-matching":"x","any-matching":"x"}}}`+"\n"))
	if err == nil {
		t.Fatal("want a refusal")
	}
}

// Finding the process is a positive read of what the act produced, so it
// clears a pending unverified act. `none-matching` does not: it passes when
// the act never happened.
func TestAnyMatchingConfirmsAndNoneMatchingDoesNot(t *testing.T) {
	if !(&Expect{Process: &Process{AnyMatching: "tail -f marker"}}).Confirms() {
		t.Fatal("a process found is evidence something ran")
	}
	if (&Expect{Process: &Process{NoneMatching: "tail -f marker"}}).Confirms() {
		t.Fatal("finding nothing is never evidence an act landed")
	}
}
