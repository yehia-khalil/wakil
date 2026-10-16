package wakilcore

import (
	"os"
	"path/filepath"
	"testing"
)

func newTestOrgWithProject(t *testing.T, org, declaredOrg string) (home, projPath string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", org)
	if err := CreateOrg(org, Org{}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), ".wakil")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	projPath = filepath.Join(dir, "project.json")
	body := `{"name":"booking","org":"` + declaredOrg + `","roots":[{"path":"/x"}]}`
	if err := os.WriteFile(projPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry(org, map[string]ProjectEntry{"booking": {Path: projPath}}); err != nil {
		t.Fatal(err)
	}
	return home, projPath
}

func TestListProjectsReportsMisfiledEntryInsteadOfDroppingIt(t *testing.T) {
	_, projPath := newTestOrgWithProject(t, "initech", "umbrella")

	got, err := ListProjectsForOrg()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Projects) != 0 {
		t.Errorf("a project whose file declares another org must not be listed as this org's: %+v", got.Projects)
	}
	if len(got.Misfiled) != 1 {
		t.Fatalf("Misfiled = %+v; want exactly one entry — silently dropping it is the behaviour being replaced", got.Misfiled)
	}
	m := got.Misfiled[0]
	if m.Name != "booking" || m.FiledUnder != "initech" || m.DeclaredOrg != "umbrella" || m.Path != projPath {
		t.Errorf("Misfiled[0] = %+v; want every field populated so the operator knows which side to fix", m)
	}
}

func TestListProjectsReturnsMatchingProjects(t *testing.T) {
	_, projPath := newTestOrgWithProject(t, "initech", "initech")

	got, err := ListProjectsForOrg()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Misfiled) != 0 {
		t.Errorf("Misfiled = %+v; want none", got.Misfiled)
	}
	if e, ok := got.Projects["booking"]; !ok || e.Path != projPath {
		t.Errorf("Projects = %+v; want booking -> %q", got.Projects, projPath)
	}
}

func TestRegistryIsPerOrgAndDoesNotReadOtherOrgs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("umbrella", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("umbrella", map[string]ProjectEntry{"other": {Path: "/nope/project.json"}}); err != nil {
		t.Fatal(err)
	}
	reg, err := LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	if _, found := reg["other"]; found {
		t.Error("the initech registry returned a umbrella project — registries must not be shared")
	}
	if _, err := os.Stat(filepath.Join(home, ".wakil", "projects.json")); !os.IsNotExist(err) {
		t.Error("no global projects.json may be written any more")
	}
}

func TestProjectEntryCarriesProviderPreference(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", "initech")
	if err := CreateOrg("initech", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistry("initech", map[string]ProjectEntry{"booking": {Path: "/p/project.json", Provider: "backup"}}); err != nil {
		t.Fatal(err)
	}
	reg, err := LoadRegistry()
	if err != nil {
		t.Fatal(err)
	}
	if reg["booking"].Provider != "backup" {
		t.Errorf("Provider = %q; want backup", reg["booking"].Provider)
	}
}
