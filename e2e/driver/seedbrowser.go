package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// LiveProjectName is the project BrowserSites registers: never active, one `live` environment
// declared production, one `site` entry on `localhost`.
const (
	LiveProjectName     = "e2e-live"
	LiveEnvironmentName = "live"
	LiveSiteEntry       = "site"
	// PagesEntry is the staging entry naming the page stub's own origin.
	PagesEntry = "pages"
)

// browserSitesChecks are the checks whose launch seeds the browser sites (SeedSpec.BrowserSites).
// Named as check.Name spells them, with the extension (ruling R10).
var browserSitesChecks = map[string]bool{
	"3c-ii-tags.jsonl":       true,
	"3c-ii-production.jsonl": true,
}

// WantsBrowserSites reports whether a launch running these checks seeds the browser sites.
func WantsBrowserSites(checks []Check) bool {
	for _, check := range checks {
		if browserSitesChecks[check.Name] {
			return true
		}
	}
	return false
}

// browserSiteEntries adds the staging `pages` entry — the page stub's origin — when the spec asks.
func browserSiteEntries(entries []wakilcore.ApiConfig, spec SeedSpec) []wakilcore.ApiConfig {
	if !spec.BrowserSites || spec.PageStub == "" {
		return entries
	}
	return append(entries, wakilcore.ApiConfig{Name: PagesEntry, BaseURL: spec.PageStub})
}

// seedLiveProject writes the production project and returns its project.json's path. Its site is
// the stub under the name `localhost`, so the host differs from the staging entry's loopback
// address and the two need separate consent.
func seedLiveProject(root string, spec SeedSpec) (string, error) {
	live := PageStubLive(spec.PageStub)
	if live == "" {
		return "", fmt.Errorf("seed: BrowserSites needs the page stub's origin, got %q", spec.PageStub)
	}
	dir := filepath.Join(root, LiveProjectName)
	if err := os.MkdirAll(filepath.Join(dir, ".wakil"), 0o755); err != nil {
		return "", fmt.Errorf("seed: making the live project: %w", err)
	}
	production := true
	project := wakilcore.Project{
		Name:  LiveProjectName,
		Org:   spec.Org,
		Roots: []wakilcore.Root{{Path: dir}},
		Environments: map[string]wakilcore.Environment{
			LiveEnvironmentName: {
				Databases:  []wakilcore.Database{},
				API:        []wakilcore.ApiConfig{{Name: LiveSiteEntry, BaseURL: live}},
				Production: &production,
			},
		},
	}
	encoded, err := json.MarshalIndent(project, "", "  ")
	if err != nil {
		return "", fmt.Errorf("seed: encoding the live project: %w", err)
	}
	file := filepath.Join(dir, ".wakil", "project.json")
	if err := os.WriteFile(file, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("seed: writing the live project: %w", err)
	}
	if _, err := wakilcore.LoadProject(file); err != nil {
		return "", fmt.Errorf("seed: the live project is not loadable: %w", err)
	}
	return file, nil
}
