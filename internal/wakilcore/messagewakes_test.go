package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Workspaces piece 4 (decision 16): Agents woken by messages — 8 by default, an organisation
// setting with a project override, 0 never wakes.
func TestMessageWakesDefaultsToEightAndIsSetPerOrganisation(t *testing.T) {
	editorProjectFixture(t, "acme")
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.MessageWakes != DefaultMessageWakes || DefaultMessageWakes != 8 {
		t.Fatalf("default = %d", tree.Org.MessageWakes)
	}
	if err := UpdateOrg("acme", OrgPatch{MessageWakes: intp(0)}); err != nil {
		t.Fatal(err)
	}
	tree, _ = LoadConfigTreeFor("acme")
	if tree.Org.MessageWakes != 0 {
		t.Fatalf("0 is a value, not unset: %d", tree.Org.MessageWakes)
	}
	if err := UpdateOrg("acme", OrgPatch{GitName: strp("Ada")}); err != nil {
		t.Fatal(err)
	}
	tree, _ = LoadConfigTreeFor("acme")
	if tree.Org.MessageWakes != 0 {
		t.Fatalf("another field's save changed it: %d", tree.Org.MessageWakes)
	}
	if err := UpdateOrg("acme", OrgPatch{MessageWakes: intp(-1)}); err != nil {
		t.Fatal(err)
	}
	tree, _ = LoadConfigTreeFor("acme")
	if tree.Org.MessageWakes != 8 {
		t.Fatalf("-1 clears back to the default: %d", tree.Org.MessageWakes)
	}
	err = UpdateOrg("acme", OrgPatch{MessageWakes: intp(100)})
	if err == nil || !strings.Contains(err.Error(), "Agents woken by messages must be a whole number from 0 to 99") {
		t.Fatalf("out of range = %v", err)
	}
}

func TestMessageWakesProjectOverrideSetAndCleared(t *testing.T) {
	editorProjectFixture(t, "acme")
	dir := filepath.Join(t.TempDir(), "widgets")
	os.MkdirAll(dir, 0o755)
	_, entry, err := CreateProject(dir, "widgets")
	if err != nil {
		t.Fatal(err)
	}
	path := entry.Path
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{MessageWakes: intp(3)}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{Commits: strp("Imperative")}); err != nil {
		t.Fatal(err)
	}
	p, _ := LoadProject(path)
	if p.Agent == nil || p.Agent.MessageWakes == nil || *p.Agent.MessageWakes != 3 || p.Agent.Commits != "Imperative" {
		t.Fatalf("agent = %+v", p.Agent)
	}
	tree, _ := LoadConfigTreeFor("acme")
	var found *int
	for _, pr := range tree.Projects {
		if pr.Path == path {
			found = pr.Agent.MessageWakes
		}
	}
	if found == nil || *found != 3 {
		t.Fatalf("tree override = %v", found)
	}
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{MessageWakes: intp(-1)}); err != nil {
		t.Fatal(err)
	}
	p, _ = LoadProject(path)
	if p.Agent == nil || p.Agent.MessageWakes != nil {
		t.Fatalf("cleared override = %+v", p.Agent)
	}
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{Commits: strp("")}); err != nil {
		t.Fatal(err)
	}
	p, _ = LoadProject(path)
	if p.Agent != nil {
		t.Fatalf("an empty block is dropped: %+v", p.Agent)
	}
	err = UpdateProjectAgentInstructions(path, ProjectAgentPatch{MessageWakes: intp(-2)})
	if err == nil || !strings.Contains(err.Error(), "from 0 to 99") {
		t.Fatalf("out of range = %v", err)
	}
}
