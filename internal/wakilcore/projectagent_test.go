package wakilcore

import (
	"os"
	"path/filepath"
	"testing"
)

func TestUpdateOrgSetsTheAgentTexts(t *testing.T) {
	localOrg(t)
	if err := UpdateOrg("initech", OrgPatch{AgentGeneral: strp("Ask before migrations"),
		GitCommitInstructions: strp("Imperative subject"), GitPRInstructions: strp("What / How")}); err != nil {
		t.Fatal(err)
	}
	o, _ := LoadOrgFor("initech")
	if o.AgentGeneral != "Ask before migrations" || o.GitCommitInstructions != "Imperative subject" || o.GitPRInstructions != "What / How" {
		t.Fatalf("org = %+v", o)
	}
	if err := UpdateOrg("initech", OrgPatch{AgentGeneral: strp("")}); err != nil {
		t.Fatal(err)
	}
	o, _ = LoadOrgFor("initech")
	if o.AgentGeneral != "" || o.GitCommitInstructions != "Imperative subject" {
		t.Fatalf("clearing one changed another: %+v", o)
	}
}

func TestProjectAgentInstructionsRoundTrip(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{Commits: strp("Reference the ticket key")}); err != nil {
		t.Fatal(err)
	}
	if err := UpdateProjectAgentInstructions(path, ProjectAgentPatch{General: strp("Never run migrations on staging")}); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if p.Agent == nil || p.Agent.Commits != "Reference the ticket key" || p.Agent.General != "Never run migrations on staging" {
		t.Fatalf("agent = %+v", p.Agent)
	}
	if len(p.Roots) != 1 {
		t.Fatal("a field the patch did not name was lost")
	}
}

func TestConfigTreeCarriesTheTexts(t *testing.T) {
	editorProjectFixture(t, "acme")
	dir := filepath.Join(t.TempDir(), "widgets")
	os.MkdirAll(dir, 0o755)
	_, entry, err := CreateProject(dir, "widgets")
	if err != nil {
		t.Fatal(err)
	}
	if err := UpdateProjectAgentInstructions(entry.Path, ProjectAgentPatch{PullRequests: strp("Short summary first")}); err != nil {
		t.Fatal(err)
	}
	UpdateOrg("acme", OrgPatch{GitCommitInstructions: strp("Imperative subject")})
	tree, err := LoadConfigTreeFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.GitCommitInstructions != "Imperative subject" {
		t.Fatalf("org texts = %+v", tree.Org)
	}
	found := false
	for _, p := range tree.Projects {
		if p.Agent.PullRequests == "Short summary first" {
			found = true
		}
	}
	if !found {
		t.Fatalf("project texts missing: %+v", tree.Projects)
	}
}
