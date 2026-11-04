package wakilcore

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// SetDir records the folder project.json's relative root paths are read from, given the
// project.json path (<project>/.wakil/project.json). LoadProject sets it.
func (p *Project) SetDir(projectPath string) {
	p.dir = filepath.Dir(filepath.Dir(projectPath))
}

// repoName is a root's repo name: the last element of its path, read from the project's folder
// when the path is relative (a root of "." is the project folder's own name).
func (p Project) repoName(r Root) string {
	if !filepath.IsAbs(r.Path) && p.dir != "" {
		return filepath.Base(resolveRootPath(p.dir, r.Path))
	}
	return RepoName(r)
}

// RepoNameIn is a root's repo name for the project at projectPath.
func RepoNameIn(projectPath string, r Root) string {
	return filepath.Base(resolveRootPath(filepath.Dir(filepath.Dir(projectPath)), r.Path))
}

// RepoDirs maps each repo name of a project to its folder (Main's folder).
func RepoDirs(projectPath string, p Project) map[string]string {
	projDir := filepath.Dir(filepath.Dir(projectPath))
	out := map[string]string{}
	for _, r := range p.Roots {
		dir := resolveRootPath(projDir, r.Path)
		out[filepath.Base(dir)] = dir
	}
	return out
}

// MachineManagers lists the runtime version managers this machine has: mise and asdf on PATH,
// nvm by its folder (it is a shell function, never on PATH).
func MachineManagers() []string {
	var out []string
	for _, m := range []string{"mise", "asdf"} {
		if _, err := exec.LookPath(m); err == nil {
			out = append(out, m)
		}
	}
	nvmDir := os.Getenv("NVM_DIR")
	if nvmDir == "" {
		if home, err := os.UserHomeDir(); err == nil {
			nvmDir = filepath.Join(home, ".nvm")
		}
	}
	if st, err := os.Stat(filepath.Join(nvmDir, "nvm.sh")); err == nil && !st.IsDir() {
		out = append(out, "nvm")
	}
	return out
}

// ConfineRunDir refuses a folder outside the project's repos and the organisation's workspaces
// (~/.wakil/orgs/<org>/workspaces), after resolving links: a run reads only those (Invariant 6).
func ConfineRunDir(dir, org string, repoDirs map[string]string) error {
	if dir == "" || !filepath.IsAbs(dir) {
		return UserError(fmt.Sprintf("folder %q must be an absolute path", dir))
	}
	real := evalOrClean(dir)
	var allowed []string
	for _, d := range repoDirs {
		allowed = append(allowed, evalOrClean(d))
	}
	if orgDir, err := OrgDirFor(org); err == nil {
		allowed = append(allowed, evalOrClean(filepath.Join(orgDir, "workspaces")))
	}
	for _, a := range allowed {
		if real == a || strings.HasPrefix(real, a+string(filepath.Separator)) {
			return nil
		}
	}
	return UserError(fmt.Sprintf("folder %s is neither a repo of this project nor inside its organisation's workspaces, so Wakil does not read it (Invariant 6)", dir))
}

// evalOrClean resolves links in the longest part of p that exists, keeping the rest as written.
func evalOrClean(p string) string {
	p = filepath.Clean(p)
	rest := ""
	for {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(p)
		if parent == p {
			return filepath.Join(p, rest)
		}
		rest = filepath.Join(filepath.Base(p), rest)
		p = parent
	}
}

// ComposeOverrideForDir reads dir's compose file and builds its override; a folder with no
// compose file answers an empty override.
func ComposeOverrideForDir(dir, workspace, repo string, base int, reserved []int) (ComposeOverrideResult, error) {
	file := FindComposeFile(dir)
	if file == "" {
		return ComposeOverride(ComposeFacts{}, workspace, repo, base, reserved)
	}
	b, err := os.ReadFile(filepath.Join(dir, file))
	if err != nil {
		return ComposeOverrideResult{}, UserError(fmt.Sprintf("cannot read %s: %v", filepath.Join(dir, file), err))
	}
	facts, err := ParseCompose(b, file)
	if err != nil {
		return ComposeOverrideResult{}, err
	}
	return ComposeOverride(facts, workspace, repo, base, reserved)
}
