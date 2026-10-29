package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func handoff(conversation string) TicketHandoff {
	return TicketHandoff{Conversation: conversation, Title: "INI-142 · src/auth/token.go:41 — keep the org", Thread: "PRRT_1",
		Harness: "claude-code", Provider: "anthropic", Place: Place{Organization: "initech", Project: "api", Environment: "local"}}
}

func addHandoff(t *testing.T, key, conversation string, mayPush bool) TicketRecord {
	t.Helper()
	r, err := AddTicketHandoff("initech", key, handoff(conversation), mayPush, ticketNow)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestHandoffAddedLoggedAndDefaultsWritten(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", false)
	r := addHandoff(t, "ini-142", "c2", true)
	if len(r.Handoffs) != 2 || r.Handoffs[0].ID != "h1" || r.Handoffs[1].ID != "h2" {
		t.Fatalf("handoffs = %+v", r.Handoffs)
	}
	h := r.Handoffs[1]
	if h.Conversation != "c2" || !h.MayPush || h.Ended != nil || h.At != ticketNow.Format(time.RFC3339) || h.Place.Project != "api" {
		t.Errorf("hand-off = %+v", h)
	}
	dir := ticketDir(t)
	b, _ := os.ReadFile(filepath.Join(dir, "INI-142.json"))
	var raw map[string]any
	_ = json.Unmarshal(b, &raw)
	first := raw["handoffs"].([]any)[0].(map[string]any)
	for _, k := range []string{"id", "conversation", "title", "thread", "harness", "provider", "place", "at", "ended", "mayPush"} {
		if _, ok := first[k]; !ok {
			t.Errorf("record's hand-off has no %q: %s", k, b)
		}
	}
	if first["ended"] != nil {
		t.Errorf("ended = %v, want null", first["ended"])
	}
	if p := first["place"].(map[string]any); p["organization"] != "initech" || p["environment"] != "local" {
		t.Errorf("place = %v", p)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "INI-142.log.jsonl"))
	if n := strings.Count(string(log), `"section":"handoffs"`); n != 2 || !strings.Contains(string(log), `"op":"add"`) {
		t.Errorf("log = %s", log)
	}
	d, found, err := ReadHandoffDefaults("initech")
	if err != nil || !found || d.Harness != "claude-code" || d.Provider != "anthropic" || !d.MayPush || d.At != ticketNow.Format(time.RFC3339) {
		t.Errorf("defaults = %+v found %v err %v", d, found, err)
	}
	b, _ = os.ReadFile(filepath.Join(dir, "handoff.json"))
	var def map[string]any
	_ = json.Unmarshal(b, &def)
	for _, k := range []string{"harness", "provider", "mayPush", "at"} {
		if _, ok := def[k]; !ok {
			t.Errorf("handoff.json has no %q: %s", k, b)
		}
	}
}

func TestHandoffDefaultsAbsent(t *testing.T) {
	localOrg(t)
	if d, found, err := ReadHandoffDefaults("initech"); err != nil || found || d != (HandoffDefaults{}) {
		t.Errorf("defaults = %+v found %v err %v", d, found, err)
	}
	if _, err := os.Stat(ticketDir(t)); !os.IsNotExist(err) {
		t.Fatalf("a read created %s", ticketDir(t))
	}
}

func TestHandoffWithoutAConversationRefused(t *testing.T) {
	localOrg(t)
	if _, err := AddTicketHandoff("initech", "INI-142", TicketHandoff{Harness: "claude-code"}, false, ticketNow); err == nil {
		t.Error("a hand-off with no conversation was written")
	}
	if _, err := AddTicketHandoff("initech", "pr:nonsense", handoff("c1"), false, ticketNow); err == nil {
		t.Error("a hand-off keyed by no PR was written")
	}
}

// A hand-off from a PR with no ticket key is kept by its PR and writes no ticket record.
func TestPRHandoffWritesNoTicketRecord(t *testing.T) {
	localOrg(t)
	key := PRHandoffKey("github.com/initech/api", 215)
	if key != "pr:github.com/initech/api#215" {
		t.Fatalf("key = %q", key)
	}
	r := addHandoff(t, key, "c1", true)
	if r.Key != key || len(r.Handoffs) != 1 || r.Handoffs[0].ID != "h1" {
		t.Fatalf("record = %+v", r)
	}
	entries, _ := os.ReadDir(ticketDir(t))
	for _, e := range entries {
		if ticketKeyRE.MatchString(strings.TrimSuffix(e.Name(), ".json")) {
			t.Errorf("a ticket record was written: %s", e.Name())
		}
	}
	got, err := ReadPRHandoffs("initech", key)
	if err != nil || len(got) != 1 || got[0].Conversation != "c1" {
		t.Errorf("read back %+v, %v", got, err)
	}
	if !TicketHandoffMayPush("initech", "c1") {
		t.Error("May push of a PR's hand-off reads off")
	}
}

func TestEndStaleKeepsLiveConversations(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", false)
	addHandoff(t, "INI-142", "c2", false)
	addHandoff(t, "INI-150", "c3", false)
	pr := PRHandoffKey("github.com/initech/api", 215)
	addHandoff(t, pr, "c4", false)
	later := ticketNow.Add(time.Hour)
	if err := EndTicketHandoffs("initech", []string{"c2"}, true, later); err != nil {
		t.Fatal(err)
	}
	open, err := OpenTicketHandoffs("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(open) != 1 || len(open["INI-142"]) != 1 || open["INI-142"][0].Conversation != "c2" {
		t.Fatalf("open = %+v", open)
	}
	r, _ := ReadTicketRecord("initech", "INI-142")
	if e := r.Handoffs[0].Ended; e == nil || *e != later.Format(time.RFC3339) {
		t.Errorf("c1 ended = %v", e)
	}
	if prs, _ := ReadPRHandoffs("initech", pr); len(prs) != 1 || prs[0].Ended == nil {
		t.Errorf("PR hand-off = %+v", prs)
	}
	log, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.log.jsonl"))
	if !strings.Contains(string(log), `"op":"end"`) {
		t.Errorf("log = %s", log)
	}
	// The named conversation ends when the list is the ended ones.
	if err := EndTicketHandoffs("initech", []string{"c2"}, false, later); err != nil {
		t.Fatal(err)
	}
	if open, _ := OpenTicketHandoffs("initech"); len(open) != 0 {
		t.Errorf("open = %+v", open)
	}
}

// May push is the stored hand-off's, and survives the conversation's end (a resume or fork reads
// it); with no readable hand-off it is off.
func TestHandoffMayPushSurvivesTheEndAndFailsClosed(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	addHandoff(t, "INI-150", "c2", false)
	if err := EndTicketHandoffs("initech", nil, true, ticketNow); err != nil {
		t.Fatal(err)
	}
	if !TicketHandoffMayPush("initech", "c1") {
		t.Error("an ended hand-off's May push reads off")
	}
	if TicketHandoffMayPush("initech", "c2") {
		t.Error("May push off reads on")
	}
	if TicketHandoffMayPush("initech", "c-unknown") || TicketHandoffMayPush("initech", "") {
		t.Error("a conversation with no hand-off reads May push on")
	}
	if err := os.WriteFile(filepath.Join(ticketDir(t), "INI-142.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if TicketHandoffMayPush("initech", "c1") {
		t.Error("an unreadable hand-off reads May push on")
	}
}

func TestHandoffEmptyRecordWritesEmptyList(t *testing.T) {
	localOrg(t)
	addDecision(t, "use sessions")
	b, _ := os.ReadFile(filepath.Join(ticketDir(t), "INI-142.json"))
	if !strings.Contains(string(b), `"handoffs": []`) {
		t.Errorf("record = %s", b)
	}
}

// One live hand-off per conversation: a second Start on the same conversation is refused.
func TestHandoffAddRefusesALiveConversation(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if _, err := AddTicketHandoff("initech", PRHandoffKey("github.com/initech/api", 215), handoff("c1"), true, ticketNow); err == nil {
		t.Error("a conversation with a live hand-off was handed again")
	}
	if r, _ := ReadTicketRecord("initech", "INI-142"); len(r.Handoffs) != 1 {
		t.Errorf("handoffs = %+v", r.Handoffs)
	}
}

// May push reads on only from exactly one hand-off that says so: a conversation handed twice
// (the first ended) reads off, whatever either said.
func TestMayPushHandedTwiceOnThenOffReadsOff(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if err := EndTicketHandoffs("initech", []string{"c1"}, false, ticketNow); err != nil {
		t.Fatal(err)
	}
	addHandoff(t, "INI-142", "c1", false)
	if TicketHandoffMayPush("initech", "c1") {
		t.Error("a conversation handed on then off reads May push on")
	}
}

func TestMayPushTwoMatchesAcrossTicketAndPRReadOff(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if err := EndTicketHandoffs("initech", []string{"c1"}, false, ticketNow); err != nil {
		t.Fatal(err)
	}
	addHandoff(t, PRHandoffKey("github.com/initech/api", 215), "c1", true)
	for i := 0; i < 20; i++ {
		if TicketHandoffMayPush("initech", "c1") {
			t.Fatal("two hand-offs of one conversation read May push on")
		}
	}
}

// Any unreadable file the lookup reads makes May push off, even when another file holds the one
// matching hand-off with May push on.
func TestMayPushAnyUnreadableFileReadsOff(t *testing.T) {
	for _, bad := range []string{"INI-150.json", "pr-handoffs.json"} {
		t.Run(bad, func(t *testing.T) {
			localOrg(t)
			addHandoff(t, "INI-142", "c1", true)
			if !TicketHandoffMayPush("initech", "c1") {
				t.Fatal("one hand-off with May push on reads off")
			}
			if err := os.WriteFile(filepath.Join(ticketDir(t), bad), []byte("{not json"), 0o644); err != nil {
				t.Fatal(err)
			}
			if TicketHandoffMayPush("initech", "c1") {
				t.Errorf("May push reads on beside an unreadable %s", bad)
			}
		})
	}
}

// A handed conversation resumed into a new conversation carries its hand-off: the new id reads
// the operator's May push, the original keeps its own, and the defaults are not touched.
func TestCarryHandoffToANewConversation(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if err := EndTicketHandoffs("initech", nil, true, ticketNow); err != nil {
		t.Fatal(err)
	}
	if err := writeHandoffDefaults("initech", HandoffDefaults{Harness: "claude-code", Provider: "other", MayPush: false}); err != nil {
		t.Fatal(err)
	}
	key, h, err := CarryTicketHandoff("initech", "c1", "c2", ticketNow)
	if err != nil || h == nil {
		t.Fatalf("carry = %q %+v %v", key, h, err)
	}
	if key != "INI-142" || h.Conversation != "c2" || h.ID != "h2" || !h.MayPush || h.Ended != nil || h.Thread != "PRRT_1" {
		t.Errorf("carried = %q %+v", key, h)
	}
	if !TicketHandoffMayPush("initech", "c2") || !TicketHandoffMayPush("initech", "c1") {
		t.Error("carried May push reads off")
	}
	if d, _, _ := ReadHandoffDefaults("initech"); d.Provider != "other" {
		t.Errorf("a carry wrote the defaults: %+v", d)
	}
}

// Nothing to carry from a conversation never handed: no hand-off, no error.
func TestCarryFromAConversationNeverHanded(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	key, h, err := CarryTicketHandoff("initech", "c-other", "c2", ticketNow)
	if err != nil || h != nil || key != "" {
		t.Errorf("carry = %q %+v %v", key, h, err)
	}
	if TicketHandoffMayPush("initech", "c2") {
		t.Error("an uncarried conversation reads May push on")
	}
}

// A conversation handed twice carries May push off (its own reads off); a PR hand-off carries
// under its PR key.
func TestCarryFailsClosedAndKeepsPRKeys(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if err := EndTicketHandoffs("initech", []string{"c1"}, false, ticketNow); err != nil {
		t.Fatal(err)
	}
	addHandoff(t, "INI-142", "c1", true)
	if _, h, err := CarryTicketHandoff("initech", "c1", "c2", ticketNow); err != nil || h == nil || h.MayPush {
		t.Errorf("carried from a twice-handed conversation = %+v %v", h, err)
	}
	if TicketHandoffMayPush("initech", "c2") {
		t.Error("carried from a twice-handed conversation reads May push on")
	}
	pr := PRHandoffKey("github.com/initech/api", 215)
	addHandoff(t, pr, "c3", true)
	key, h, err := CarryTicketHandoff("initech", "c3", "c4", ticketNow)
	if err != nil || key != pr || h == nil || !h.MayPush {
		t.Errorf("PR carry = %q %+v %v", key, h, err)
	}
	if hs, _ := ReadPRHandoffs("initech", pr); len(hs) != 2 {
		t.Errorf("PR hand-offs = %+v", hs)
	}
}

// An unreadable file refuses the carry: the new conversation has no hand-off, so it reads off.
func TestCarryRefusedOverAnUnreadableFile(t *testing.T) {
	localOrg(t)
	addHandoff(t, "INI-142", "c1", true)
	if err := os.WriteFile(filepath.Join(ticketDir(t), "INI-150.json"), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := CarryTicketHandoff("initech", "c1", "c2", ticketNow); err == nil {
		t.Error("a carry over an unreadable record succeeded")
	}
	if TicketHandoffMayPush("initech", "c2") {
		t.Error("a failed carry reads May push on")
	}
}
