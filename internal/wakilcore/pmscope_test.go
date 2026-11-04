package wakilcore

import (
	"strings"
	"testing"
)

// A project's Jira project (scopes.pm.projectKey) is set from Settings: the Ticket tab of a
// project scopes its tickets by it, and a project with none says so with a way to set it.
func TestSetProjectPMKeySetsClearsAndRefuses(t *testing.T) {
	path := editorProjectFixture(t, "acme")
	if err := SetProjectPMKey(path, " ini "); err != nil {
		t.Fatal(err)
	}
	p, err := LoadProject(path)
	if err != nil {
		t.Fatal(err)
	}
	if p.Scopes.PM == nil || p.Scopes.PM.ProjectKey != "INI" || p.Scopes.PM.Provider != "jira" {
		t.Fatalf("scopes = %+v", p.Scopes.PM)
	}
	if len(p.Roots) != 1 {
		t.Errorf("roots lost: %+v", p.Roots)
	}
	if err := SetProjectPMKey(path, "1NI"); err == nil || !strings.Contains(err.Error(), "is not a Jira project key") {
		t.Errorf("a malformed key: %v", err)
	}
	if err := SetProjectPMKey(path, ""); err != nil {
		t.Fatal(err)
	}
	if p, _ := LoadProject(path); p.Scopes.PM != nil {
		t.Errorf("an empty key clears the scope: %+v", p.Scopes.PM)
	}
}

func TestSetProjectPMKeyRefusesAnotherOrganisationsProject(t *testing.T) {
	path := editorProjectFixture(t, "umbrella")
	if err := SetProjectPMKey(path, "INI"); err == nil || !strings.Contains(err.Error(), "read-only here") {
		t.Errorf("got %v", err)
	}
}
