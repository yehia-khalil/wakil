package wakilcore

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var ticketNow = time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)

func ticketDir(t *testing.T) string {
	t.Helper()
	dir, err := OrgDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "tickets")
}

func addDecision(t *testing.T, text string) TicketRecord {
	t.Helper()
	r, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "add", Line: TicketLine{Text: text}, By: "operator"}, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestReadAbsentRecordWritesNothing(t *testing.T) {
	localOrg(t)
	r, err := ReadTicketRecord("initech", "INI-142")
	if err != nil || r.Key != "INI-142" {
		t.Fatalf("got %+v, %v", r, err)
	}
	if _, err := os.Stat(ticketDir(t)); !os.IsNotExist(err) {
		t.Fatalf("a read created %s", ticketDir(t))
	}
}

func TestRecordLivesUnderTheOrg(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	org, _ := OrgDirFor("initech")
	if _, err := os.Stat(filepath.Join(org, "tickets", "INI-142.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(org, "tickets", "INI-142.log.jsonl")); err != nil {
		t.Fatal(err)
	}
}

func TestAddAssignsNextId(t *testing.T) {
	localOrg(t)
	addDecision(t, "one")
	r := addDecision(t, "two")
	if r.Decisions[0].ID != "d1" || r.Decisions[1].ID != "d2" {
		t.Fatalf("ids %+v", r.Decisions)
	}
	r, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "remove", ID: "d1", By: "operator"}, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	r = addDecision(t, "three")
	if got := r.Decisions[len(r.Decisions)-1].ID; got != "d3" {
		t.Fatalf("next id %s", got)
	}
	// A removed last line's id is not handed out again either.
	UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "remove", ID: "d3", By: "operator"}, ticketNow)
	r = addDecision(t, "four")
	if got := r.Decisions[len(r.Decisions)-1].ID; got != "d4" {
		t.Fatalf("reused id %s", got)
	}
}

func TestSetNextKeepsBy(t *testing.T) {
	localOrg(t)
	r, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "next", Op: "set", Line: TicketLine{Text: "write the test"}, By: "agent", Conversation: "c1"}, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	if r.Next == nil || r.Next.By != "agent" || r.Next.Conversation != "c1" || r.Next.Text != "write the test" {
		t.Fatalf("%+v", r.Next)
	}
	r, _ = UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "next", Op: "set", Line: TicketLine{Text: "ship it"}, By: "operator"}, ticketNow)
	if r.Next.By != "operator" || r.Next.Edited != "" {
		t.Fatalf("%+v", r.Next)
	}
	// An agent replacing the operator's next keeps the operator as author.
	r, _ = UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "next", Op: "set", Line: TicketLine{Text: "ship it, then tag"}, By: "agent"}, ticketNow)
	if r.Next.By != "operator" || r.Next.Edited != "agent" {
		t.Fatalf("%+v", r.Next)
	}
}

func TestAgentEditOfOperatorLineMarksEdited(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	r, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "edit", ID: "d1", Line: TicketLine{Text: "use JWTs"}, By: "agent", Conversation: "c9"}, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	l := r.Decisions[0]
	if l.By != "operator" || l.Edited != "agent" || l.Text != "use JWTs" {
		t.Fatalf("%+v", l)
	}
}

func TestRemoveLogsTheOldLine(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	r, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "remove", ID: "d1", By: "agent"}, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Decisions) != 0 {
		t.Fatalf("still there: %+v", r.Decisions)
	}
	b, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.log.jsonl"))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	last := lines[len(lines)-1]
	if !strings.Contains(last, `"op":"remove"`) || !strings.Contains(last, "use sessions") || !strings.Contains(last, `"by":"agent"`) {
		t.Fatalf("log %s", last)
	}
	rec, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.json"))
	if strings.Contains(string(rec), "use sessions") {
		t.Fatal("record still has the line")
	}
}

func TestUnknownIdIsAUserErrorNamingIt(t *testing.T) {
	localOrg(t)
	_, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "remove", ID: "d7", By: "agent"}, ticketNow)
	msg, ok := IsUserError(err)
	if !ok || !strings.Contains(msg, "d7") {
		t.Fatalf("%v", err)
	}
}

func TestUnknownSectionRefused(t *testing.T) {
	localOrg(t)
	_, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "ideas", Op: "add", By: "agent"}, ticketNow)
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("%v", err)
	}
	if _, err := os.Stat(ticketDir(t)); !os.IsNotExist(err) {
		t.Fatal("a refused edit wrote files")
	}
}

func TestLogLineIsWrittenBeforeTheRecord(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	before, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.json"))
	renameTicketFile = func(string, string) error { return errors.New("read-only") }
	defer func() { renameTicketFile = os.Rename }()
	_, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "remove", ID: "d1", By: "operator"}, ticketNow)
	if err == nil {
		t.Fatal("rename failure not reported")
	}
	after, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.json"))
	if string(before) != string(after) {
		t.Fatal("record changed")
	}
	b, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.log.jsonl"))
	if !strings.Contains(string(b), `"op":"remove"`) {
		t.Fatalf("log lacks the line: %s", b)
	}
	if m, _ := filepath.Glob(filepath.Join(ticketDir(t), "*.tmp")); len(m) != 0 {
		t.Fatalf("temp left: %v", m)
	}
}

func TestRecordSeenKeepsDeletedBranches(t *testing.T) {
	localOrg(t)
	b1 := TicketBranchRef{Repo: "github.com/initech/api", Branch: "ini-142-login", Source: "branch"}
	p1 := TicketPRRef{Repo: "github.com/initech/api", Number: 212, State: "open"}
	if err := RecordTicketSeen("initech", "INI-142", TicketSeen{Title: "Login", Status: "In Progress"}, []TicketBranchRef{b1}, []TicketPRRef{p1}); err != nil {
		t.Fatal(err)
	}
	b2 := TicketBranchRef{Repo: "github.com/initech/api", Branch: "ini-142-fix", Source: "pr"}
	p1.State = "merged"
	if err := RecordTicketSeen("initech", "INI-142", TicketSeen{}, []TicketBranchRef{b2}, []TicketPRRef{p1}); err != nil {
		t.Fatal(err)
	}
	r, _ := ReadTicketRecord("initech", "INI-142")
	if len(r.Branches) != 2 || len(r.PRs) != 1 || r.PRs[0].State != "merged" || r.Seen.Title != "Login" {
		t.Fatalf("%+v", r)
	}
}

// Two independent writers, each opening the record and the lock for itself with no shared
// memory but the filesystem, as the operator's and an agent's wakil-ticket processes do.
func TestConcurrentWritesKeepBothLines(t *testing.T) {
	localOrg(t)
	var wg sync.WaitGroup
	for _, by := range []string{"operator", "agent"} {
		wg.Add(1)
		go func(by string) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				_, err := UpdateTicketRecord("initech", "INI-142", TicketEdit{Section: "decisions", Op: "add", Line: TicketLine{Text: by}, By: by}, ticketNow)
				if err != nil {
					t.Error(err)
					return
				}
			}
		}(by)
	}
	wg.Wait()
	r, _ := ReadTicketRecord("initech", "INI-142")
	if len(r.Decisions) != 100 {
		t.Fatalf("%d lines, want 100", len(r.Decisions))
	}
	seen := map[string]bool{}
	for _, l := range r.Decisions {
		if seen[l.ID] {
			t.Fatalf("duplicate id %s", l.ID)
		}
		seen[l.ID] = true
	}
}

func TestBadKeyRefused(t *testing.T) {
	localOrg(t)
	if _, err := ReadTicketRecord("initech", "../x"); err == nil {
		t.Fatal("path key accepted")
	}
}

func TestEmptyListsAreWrittenAsArrays(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	b, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.json"))
	if strings.Contains(string(b), "null") {
		t.Fatalf("record has null: %s", b)
	}
	for _, f := range []string{`"branches": []`, `"prs": []`, `"notDone": []`, `"waitingOn": []`, `"verified": []`, `"rulings": []`} {
		if !strings.Contains(string(b), f) {
			t.Fatalf("missing %s in %s", f, b)
		}
	}
}

func TestNullListsOnDiskReadAsEmptySlices(t *testing.T) {
	localOrg(t)
	os.MkdirAll(ticketDir(t), 0o755)
	os.WriteFile(filepath.Join(ticketDir(t), "INI-142.json"), []byte(`{"key":"INI-142","branches":null,"prs":null,"decisions":null,"notDone":null,"waitingOn":null,"verified":null,"rulings":null}`), 0o644)
	r, err := ReadTicketRecord("initech", "INI-142")
	if err != nil {
		t.Fatal(err)
	}
	if r.Branches == nil || r.PRs == nil || r.Decisions == nil || r.NotDone == nil || r.WaitingOn == nil || r.Verified == nil || r.Rulings == nil {
		t.Fatalf("nil list: %+v", r)
	}
	if e, _ := ReadTicketRecord("initech", "INI-143"); e.Decisions == nil {
		t.Fatal("absent record has nil lists")
	}
}
