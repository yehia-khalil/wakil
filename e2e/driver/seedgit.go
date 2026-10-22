package driver

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// The git project's roots, as directory names under the fixture root. The
// editor's Changes view (3b-iii, 3a-i's Git pane folded in) lists every root of
// the active project, so these are what its checks address:
// `editor.changes.row:e2e-api/notes:untracked` and the like.
const (
	// GitProjectRootPlain is the project's own directory, holding its
	// project.json and nothing else. **Not a repository, on purpose**: it is
	// the root Interaction Rule 8's check reads as `not a git repository`,
	// whole, while the two below list.
	GitProjectRootPlain = "e2e-git"
	// GitRootAPI is partly staged (app.txt under Staged AND Changes) and has
	// two untracked files — every group, and the one-file-twice case.
	GitRootAPI = "e2e-api"
	// GitRootPortal has exactly one changed file, so a check that reverts it
	// empties the root — Rule 6's "the list unfolds with that root in view".
	GitRootPortal = "e2e-portal"
)

// seedGitProject writes the git project: a non-repository project directory
// and two repositories beside it, and returns its project.json's path.
//
// **Two repositories and a plain directory, in that order**, because the
// claims 3a-i's spec asks the Cover rung for are differences between roots:
// ↑↓ stepping ACROSS roots, an error on one root while the others list. One
// repository can show neither.
//
// **Its own project, never the active one.** Every seeded check before 3a-i
// opens onto `e2e-project` with a single non-repository root, and two of them
// (2d-i's code hint) `git init` that root themselves. Putting repositories
// there would change what CodeSource reads for every one of them; a project
// a git check switches to with `ctx_set_project` changes nothing for any
// other check.
func seedGitProject(root string, spec SeedSpec) (string, error) {
	projectDir := filepath.Join(root, GitProjectRootPlain)
	api := filepath.Join(root, GitRootAPI)
	portal := filepath.Join(root, GitRootPortal)
	// Cleared first, for `Seed`'s reason: a second run against one
	// `--fixture` directory must start from nothing, and `git init` over a
	// previous run's repository would keep its commits and its edits.
	for _, dir := range []string{projectDir, api, portal} {
		if err := os.RemoveAll(dir); err != nil {
			return "", fmt.Errorf("seed: clearing %s: %w", dir, err)
		}
	}
	for _, dir := range []string{filepath.Join(projectDir, ".wakil"), api, portal} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", fmt.Errorf("seed: making %s: %w", dir, err)
		}
	}

	// 3b-ii: `.env` and `vendor/` are gitignored, so the tree and ⌘P show them dimmed and no
	// `git status` ever lists them; `vendor` is also a heavy folder, loaded on opening.
	first := map[string]string{
		"README.md": "api\n", "app.txt": "line one\nline two\n",
		".gitignore": ".env\nvendor/\n", ".env": "DB_PASSWORD=e2e\n", "vendor/autoload.php": "<?php\n",
	}
	if spec.SearchHaystack {
		for name, body := range searchBulk() {
			first[name] = body
		}
	}
	if err := seedRepo(root, api, []gitSeedStep{
		{write: first},
		{git: []string{"add", "-A"}},
		{git: []string{"commit", "-qm", "seed"}},
		// Staged: line two changed. Then Changes: line three added on top,
		// so app.txt is in both groups with a different diff in each.
		{write: map[string]string{"app.txt": "line one\nline two, staged\n"}},
		{git: []string{"add", "app.txt"}},
		{write: map[string]string{"app.txt": "line one\nline two, staged\nline three, unstaged\n"}},
		// Two untracked files. `notes` has no extension on purpose: the
		// coverage gate matches `editor.changes.row:<…>/<…>:<…>` one dot-free segment
		// per placeholder, so only a row whose path holds no dot can credit
		// the family. `BookingController.php` is the compound name 3a-i's
		// GitSource offers the voice resolver ("booking controller").
		{write: map[string]string{"notes": "untracked\n", "BookingController.php": "<?php\n"}},
	}); err != nil {
		return "", err
	}
	if err := seedRepo(root, portal, []gitSeedStep{
		{write: map[string]string{"index.txt": "portal\n"}},
		{git: []string{"add", "-A"}},
		{git: []string{"commit", "-qm", "seed"}},
		{write: map[string]string{"index.txt": "portal, edited\n"}},
	}); err != nil {
		return "", err
	}
	if spec.GitHook {
		// Written after the seed's own commit, so the seed never runs it; reads never run hooks.
		hook := filepath.Join(portal, ".git", "hooks", "pre-commit")
		if err := os.WriteFile(hook, []byte(gitHookScript), 0o755); err != nil {
			return "", fmt.Errorf("seed: writing %s: %w", hook, err)
		}
	}

	project := wakilcore.Project{
		Name:  spec.GitProject,
		Org:   spec.Org,
		Roots: []wakilcore.Root{{Path: projectDir}, {Path: api}, {Path: portal}},
		Environments: map[string]wakilcore.Environment{
			spec.Environment: {Databases: []wakilcore.Database{}, API: []wakilcore.ApiConfig{}},
		},
	}
	encoded, err := json.MarshalIndent(project, "", "  ")
	if err != nil {
		return "", fmt.Errorf("seed: encoding the git project's project.json: %w", err)
	}
	projectFile := filepath.Join(projectDir, ".wakil", "project.json")
	if err := os.WriteFile(projectFile, append(encoded, '\n'), 0o644); err != nil {
		return "", fmt.Errorf("seed: writing the git project's project.json: %w", err)
	}
	if _, err := wakilcore.LoadProject(projectFile); err != nil {
		return "", fmt.Errorf("seed: the git project's project.json is not loadable: %w", err)
	}
	return projectFile, nil
}

// searchBulk is 3b-ii-search-cancel's haystack: enough text that a regex search over the git
// project is still running when a press on Cancel lands. Seeded only when SeedSpec.SearchHaystack
// asks; committed with the first seed, so no git-status check sees it, and no other check's query
// matches a line of it. `bulk/zz-marker.txt` is 3b-ii-b-replace-cancel's one match (Replace All is
// pressable only over results), sorted after every `bulk/NNN.txt`, so the replace walks all 200 MiB
// before it reaches anything to write; `\w+zq\d` (3b-ii-search-cancel) does not match it.
const searchBulkFiles, searchBulkBytes = 200, 1 << 20

func searchBulk() map[string]string {
	line := "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor\n"
	body := strings.Repeat(line, searchBulkBytes/len(line))
	m := make(map[string]string, searchBulkFiles+1)
	for i := 0; i < searchBulkFiles; i++ {
		m[fmt.Sprintf("bulk/%03d.txt", i)] = body
	}
	m["bulk/zz-marker.txt"] = "replace-marker-qz7\n"
	return m
}

// searchHaystackChecks are the checks whose launch seeds `bulk/` (SeedSpec.SearchHaystack).
var searchHaystackChecks = map[string]bool{
	"3b-ii-search-cancel.jsonl":    true,
	"3b-ii-b-replace-cancel.jsonl": true,
}

// WantsSearchHaystack reports whether a launch running these checks seeds the search haystack.
func WantsSearchHaystack(checks []Check) bool {
	for _, check := range checks {
		if searchHaystackChecks[check.Name] {
			return true
		}
	}
	return false
}

// gitHookScript is the pre-commit hook SeedSpec.GitHook writes into e2e-portal: it refuses every
// commit, and while a file named `slow` is in the root it first sleeps, long enough for a check to
// see the commit in flight and press Cancel. `sleep 90.32` is the process a check looks for.
const gitHookScript = "#!/bin/sh\nif [ -e slow ]; then sleep 90.32; fi\necho 'e2e hook says no' >&2\nexit 1\n"

// gitHookChecks are the checks whose launch seeds the failing hook (SeedSpec.GitHook).
var gitHookChecks = map[string]bool{"3a-ii-hook-fails.jsonl": true}

// WantsGitHook reports whether a launch running these checks seeds the failing pre-commit hook.
func WantsGitHook(checks []Check) bool {
	for _, check := range checks {
		if gitHookChecks[check.Name] {
			return true
		}
	}
	return false
}

// CloneFolderName is the folder under the fixture root SeedSpec.CloneFolder records as the
// organisation's last clone folder.
const CloneFolderName = "e2e-clones"

// cloneFolderChecks are the checks whose launch records a last clone folder (SeedSpec.CloneFolder).
var cloneFolderChecks = map[string]bool{"3a-iii-add-project-clone.jsonl": true}

// WantsCloneFolder reports whether a launch running these checks records a last clone folder.
func WantsCloneFolder(checks []Check) bool {
	for _, check := range checks {
		if cloneFolderChecks[check.Name] {
			return true
		}
	}
	return false
}

// gitSeedStep is one thing done to a seeded repository: files written, or one
// git command run. Exactly one of the two.
type gitSeedStep struct {
	write map[string]string
	git   []string
}

// seedRepo makes `dir` a repository on `main` and applies the steps.
//
// **Git's identity and configuration are the fixture's, never the operator's.**
// The global and system config are switched off (GIT_CONFIG_GLOBAL=/dev/null,
// GIT_CONFIG_NOSYSTEM), so a signing key, a hook path or an fsmonitor in the
// operator's ~/.gitconfig cannot run during a seed, and the author and dates
// are fixed so the same seed makes the same commits.
func seedRepo(root, dir string, steps []gitSeedStep) error {
	run := func(args ...string) error {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = seedGitEnv(root)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("seed: git %s in %s: %w: %s", strings.Join(args, " "), dir, err,
				strings.TrimSpace(string(out)))
		}
		return nil
	}
	if err := run("init", "-q", "-b", "main"); err != nil {
		return err
	}
	for _, step := range steps {
		for name, content := range step.write {
			path := filepath.Join(dir, name)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return fmt.Errorf("seed: making the folder for %s in %s: %w", name, dir, err)
			}
			if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
				return fmt.Errorf("seed: writing %s in %s: %w", name, dir, err)
			}
		}
		if len(step.git) > 0 {
			if err := run(step.git...); err != nil {
				return err
			}
		}
	}
	return nil
}

// seedGitEnv is the whole environment a seed's git runs in — built, not
// inherited, so nothing of the operator's git setup reaches it.
func seedGitEnv(root string) []string {
	const who, mail, when = "Wakil E2E", "e2e@e2e-fixture.invalid", "2026-01-01T00:00:00Z"
	return []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + root,
		"LC_ALL=C",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_AUTHOR_NAME=" + who, "GIT_AUTHOR_EMAIL=" + mail, "GIT_AUTHOR_DATE=" + when,
		"GIT_COMMITTER_NAME=" + who, "GIT_COMMITTER_EMAIL=" + mail, "GIT_COMMITTER_DATE=" + when,
	}
}
