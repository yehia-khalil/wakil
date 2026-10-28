package wakilcore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func writeDraft(t *testing.T, thread string, d *TicketDraft) map[string]TicketDraft {
	t.Helper()
	m, err := WriteTicketDraft("initech", thread, d, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestDraftsAbsentWriteNothing(t *testing.T) {
	localOrg(t)
	m, err := ReadTicketDrafts("initech")
	if err != nil || m == nil || len(m) != 0 {
		t.Fatalf("got %#v, %v; want an empty map", m, err)
	}
	if _, err := os.Stat(ticketDir(t)); !os.IsNotExist(err) {
		t.Fatalf("a read created %s", ticketDir(t))
	}
}

func TestAgentDraftKeepsTheOperatorsAsReplaced(t *testing.T) {
	localOrg(t)
	writeDraft(t, "PRRT_1", &TicketDraft{Text: "Thanks, will fix", By: "operator"})
	m := writeDraft(t, "PRRT_1", &TicketDraft{Text: "Fixed in 4f1c", By: "agent", Conversation: "c1", Root: "/r/api", Branch: "ini-142-login"})
	d := m["PRRT_1"]
	if d.Text != "Fixed in 4f1c" || d.By != "agent" || d.Conversation != "c1" || d.Replaced != "Thanks, will fix" {
		t.Fatalf("draft = %+v", d)
	}
	if d.Root != "/r/api" || d.Branch != "ini-142-login" || d.At != ticketNow.Format(time.RFC3339) {
		t.Errorf("place and time = %+v", d)
	}
	// The agent's second draft still keeps the operator's text to restore.
	m = writeDraft(t, "PRRT_1", &TicketDraft{Text: "Fixed in 5a2d", By: "agent", Conversation: "c1"})
	if m["PRRT_1"].Replaced != "Thanks, will fix" {
		t.Errorf("second agent draft replaced = %q", m["PRRT_1"].Replaced)
	}
}

func TestOperatorEditClearsReplacedDraft(t *testing.T) {
	localOrg(t)
	writeDraft(t, "PRRT_1", &TicketDraft{Text: "mine", By: "operator"})
	writeDraft(t, "PRRT_1", &TicketDraft{Text: "theirs", By: "agent", Conversation: "c1"})
	m := writeDraft(t, "PRRT_1", &TicketDraft{Text: "mine again", By: "operator"})
	if d := m["PRRT_1"]; d.Text != "mine again" || d.By != "operator" || d.Replaced != "" {
		t.Fatalf("draft = %+v", d)
	}
	b, _ := os.ReadFile(filepath.Join(ticketDir(t), "drafts.json"))
	var raw map[string]map[string]any
	_ = json.Unmarshal(b, &raw)
	if _, ok := raw["PRRT_1"]["replaced"]; ok {
		t.Errorf("an operator's draft writes replaced: %s", b)
	}
}

func TestDraftRemovedOnEmptyText(t *testing.T) {
	localOrg(t)
	writeDraft(t, "PRRT_1", &TicketDraft{Text: "one", By: "operator"})
	writeDraft(t, "PRRT_2", &TicketDraft{Text: "two", By: "operator"})
	if m := writeDraft(t, "PRRT_1", &TicketDraft{Text: "", By: "operator"}); len(m) != 1 || m["PRRT_2"].Text != "two" {
		t.Fatalf("after an empty text = %+v", m)
	}
	if m := writeDraft(t, "PRRT_2", nil); len(m) != 0 {
		t.Fatalf("after nil = %+v", m)
	}
	m, _ := ReadTicketDrafts("initech")
	if len(m) != 0 {
		t.Errorf("read back = %+v", m)
	}
}

func TestDraftBadWriterRefused(t *testing.T) {
	localOrg(t)
	if _, err := WriteTicketDraft("initech", "PRRT_1", &TicketDraft{Text: "x", By: "someone"}, ticketNow); err == nil {
		t.Error("a draft by someone was written")
	}
	if _, err := WriteTicketDraft("initech", " ", &TicketDraft{Text: "x", By: "operator"}, ticketNow); err == nil {
		t.Error("a draft with no thread was written")
	}
}

func TestConcurrentDraftWritesKeepBoth(t *testing.T) {
	localOrg(t)
	var wg sync.WaitGroup
	for _, by := range []string{"operator", "agent"} {
		wg.Add(1)
		go func(by string) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				if _, err := WriteTicketDraft("initech", fmt.Sprintf("%s-%d", by, i), &TicketDraft{Text: by, By: by}, ticketNow); err != nil {
					t.Error(err)
					return
				}
			}
		}(by)
	}
	wg.Wait()
	m, err := ReadTicketDrafts("initech")
	if err != nil || len(m) != 100 {
		t.Fatalf("%d drafts, %v; want 100", len(m), err)
	}
}

func TestDraftsLiveUnderTheOrg(t *testing.T) {
	localOrg(t)
	writeDraft(t, "PRRT_1", &TicketDraft{Text: "Fixed", By: "agent", Conversation: "c1", Root: "/r/api", Branch: "ini-142-login"})
	org, _ := OrgDirFor("initech")
	b, err := os.ReadFile(filepath.Join(org, "tickets", "drafts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"text", "by", "conversation", "root", "branch", "at"} {
		if _, ok := raw["PRRT_1"][k]; !ok {
			t.Errorf("drafts.json has no %q: %s", k, b)
		}
	}
	if _, err := os.Stat(filepath.Join(org, "tickets", "drafts.json.lock")); err != nil {
		t.Errorf("no lock beside drafts.json: %v", err)
	}
}
