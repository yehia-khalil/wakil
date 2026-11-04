package wakilcore

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// loadOwnProject loads a project for writing and refuses one of another org.
func loadOwnProject(projectPath string) (*Project, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return nil, err
	}
	if project.Org != org {
		return nil, UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + " — a row stored in another organisation is read-only here")
	}
	if project.Environments == nil {
		project.Environments = map[string]Environment{}
	}
	return project, nil
}

// CreateEnvironment adds an empty environment under the first free name of
// `new-environment`, `new-environment-2`, … and returns that name.
func CreateEnvironment(projectPath string) (string, error) {
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return "", err
	}
	name := "new-environment"
	for n := 2; ; n++ {
		if _, taken := project.Environments[name]; !taken {
			break
		}
		name = "new-environment-" + strconv.Itoa(n)
	}
	project.Environments[name] = Environment{Databases: []Database{}}
	if err := SaveProject(projectPath, *project); err != nil {
		return "", err
	}
	return name, nil
}

// SetEnvironmentProduction declares whether an environment is production, or
// with nil clears the declaration so its name decides again (Rule 9: the name
// suggests, the operator decides). What counts as production sets the agent's
// price, so only the operator reaches this (`ctx_set_environment_production`).
func SetEnvironmentProduction(projectPath, name string, production *bool) error {
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return err
	}
	env, ok := project.Environments[name]
	if !ok {
		return UserError("no environment " + strconv.Quote(name) + " in project " + strconv.Quote(project.Name))
	}
	env.Production = production
	project.Environments[name] = env
	return SaveProject(projectPath, *project)
}

// RenameEnvironment moves an environment's whole value to a new key. The
// active environment follows when the active project is this one.
func RenameEnvironment(projectPath, old, new string) error {
	new, err := ValidName(new)
	if err != nil {
		return err
	}
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return err
	}
	env, ok := project.Environments[old]
	if !ok {
		return UserError("no environment " + strconv.Quote(old) + " in project " + strconv.Quote(project.Name))
	}
	if new == old {
		return nil
	}
	if _, clash := project.Environments[new]; clash {
		return UserError("an environment named " + strconv.Quote(new) +
			" already exists in project " + strconv.Quote(project.Name))
	}
	delete(project.Environments, old)
	project.Environments[new] = env
	if err := SaveProject(projectPath, *project); err != nil {
		return err
	}
	active, err := ReadActiveUnpinned()
	if err != nil {
		return err
	}
	if active.Project == projectPath && active.Environment == old {
		active.Environment = new
		return WriteActive(active)
	}
	return nil
}

// RemoveEnvironment removes an environment after putting a copy of
// project.json in the Trash; if the Trash fails nothing is removed. The copy
// is written beside project.json and trashed from there, so Finder's Put Back
// returns it beside the file (3a-ii's discard pattern). It returns the copy's
// file name.
func RemoveEnvironment(projectPath, name string, now time.Time) (string, error) {
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return "", err
	}
	if _, ok := project.Environments[name]; !ok {
		return "", UserError("no environment " + strconv.Quote(name) + " in project " + strconv.Quote(project.Name))
	}
	raw, err := os.ReadFile(projectPath)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(trashBin); err != nil {
		return "", UserError("Move to Trash needs macOS 15: " + trashBin + " is missing")
	}
	base := "project.json (before removing " + name + " " + now.Local().Format("15:04") + ")"
	dir := filepath.Dir(projectPath)
	copyPath := filepath.Join(dir, base)
	for n := 2; ; n++ {
		if _, err := os.Lstat(copyPath); os.IsNotExist(err) {
			break
		}
		copyPath = filepath.Join(dir, base+" "+strconv.Itoa(n))
	}
	if err := os.WriteFile(copyPath, raw, 0o600); err != nil {
		return "", err
	}
	if out, err := exec.Command(trashBin, "-s", copyPath).CombinedOutput(); err != nil {
		os.Remove(copyPath)
		return "", UserError("could not move a copy of project.json to the Trash, so nothing was removed: " +
			strings.TrimSpace(string(out)) + " (" + err.Error() + ")")
	}
	trashed := filepath.Base(copyPath)

	delete(project.Environments, name)
	if err := SaveProject(projectPath, *project); err != nil {
		return "", err
	}
	active, err := ReadActiveUnpinned()
	if err != nil {
		return "", err
	}
	if active.Project == projectPath && active.Environment == name {
		active.Environment = ""
		remaining := make([]string, 0, len(project.Environments))
		for k := range project.Environments {
			remaining = append(remaining, k)
		}
		sort.Strings(remaining)
		if len(remaining) > 0 {
			active.Environment = remaining[0]
		}
		if err := WriteActive(active); err != nil {
			return "", err
		}
	}
	return trashed, nil
}
