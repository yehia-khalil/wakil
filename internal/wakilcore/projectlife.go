package wakilcore

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ValidName trims a project name and refuses one that cannot be used.
//
// **Empty after trim and "/" are the only refusals here.** A clash is a
// fact about a scope (the org's registry, or one project's environments),
// so the caller that holds the scope names it. "/" is refused because a
// name travels as one path-like segment in places (`project/environment`
// pins), where a slash would split it in two.
func ValidName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", UserError("a name cannot be empty")
	}
	if strings.Contains(name, "/") {
		return "", UserError("the name " + strconv.Quote(name) + " contains \"/\" — a name is one segment, and a slash would split it")
	}
	return name, nil
}

// projectFilePath is where a folder's project file lives.
func projectFilePath(folder string) string {
	return filepath.Join(folder, ".wakil", "project.json")
}

// CreateProject registers a folder as a project of the current org.
//
// **A folder that already holds `.wakil/project.json` is adopted as it
// is.** Only the registry row is added: the file is the operator's, often
// hand-written, and overwriting it to "create" a project would destroy
// the very configuration that makes it one. A fresh folder gets a minimal
// file (name, org, one root) written through SaveProject, like every other
// project.json write.
//
// **The registry entry's path is the project.json path**, matching
// `wakil project add`, so the two registration routes produce the same row.
//
// Every refusal happens before anything is written: a refused create
// leaves neither a file nor a row behind.
func CreateProject(folder, name string) (ProjectEntry, error) {
	if !filepath.IsAbs(folder) {
		return ProjectEntry{}, UserError("the folder " + strconv.Quote(folder) + " must be an absolute path")
	}
	name, err := ValidName(name)
	if err != nil {
		return ProjectEntry{}, err
	}
	org, err := CurrentOrg()
	if err != nil {
		return ProjectEntry{}, err
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return ProjectEntry{}, err
	}
	if _, clash := reg[name]; clash {
		return ProjectEntry{}, UserError("a project named " + strconv.Quote(name) +
			" already exists in org " + strconv.Quote(org))
	}

	path := projectFilePath(folder)
	// Sorted, so the name shown for a doubly registered folder is stable.
	names := make([]string, 0, len(reg))
	for existing := range reg {
		names = append(names, existing)
	}
	sort.Strings(names)
	for _, existing := range names {
		if reg[existing].Path == path {
			return ProjectEntry{}, UserError("this folder is already registered as " +
				strconv.Quote(existing))
		}
	}

	if _, statErr := os.Stat(path); statErr == nil {
		proj, err := LoadProject(path)
		if err != nil {
			return ProjectEntry{}, UserError("could not load project file " + path + ": " + err.Error())
		}
		// **Invariant 4.** A project is registered only under the org its
		// own file declares.
		if proj.Org != org {
			return ProjectEntry{}, UserError("project.json at " + path + " declares org " +
				strconv.Quote(proj.Org) + ", but the current org is " + strconv.Quote(org) +
				" — a project can only be registered under the org it declares (Invariant 4)")
		}
	} else if os.IsNotExist(statErr) {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return ProjectEntry{}, err
		}
		fresh := Project{
			Name:         name,
			Org:          org,
			Roots:        []Root{{Path: folder}},
			Environments: map[string]Environment{},
		}
		if err := SaveProject(path, fresh); err != nil {
			return ProjectEntry{}, err
		}
	} else {
		return ProjectEntry{}, statErr
	}

	entry := ProjectEntry{Path: path}
	reg[name] = entry
	if err := SaveRegistry(org, reg); err != nil {
		return ProjectEntry{}, err
	}
	return entry, nil
}

// RenameProject renames a project in its file and in the registry.
//
// **File first, then registry, and the file is put back if the registry
// write fails.** The two cannot be written atomically together; this order
// means the failure that is possible (a registry that will not save) is
// undone by a write to a file we just proved writable, and a failed rename
// is a no-op rather than a project whose name disagrees with its key.
//
// **The active context needs no change.** It names the project by its
// project.json path, which a rename does not move.
func RenameProject(old, new string) error {
	new, err := ValidName(new)
	if err != nil {
		return err
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return err
	}
	entry, ok := reg[old]
	if !ok {
		return UserError("no project " + strconv.Quote(old) + " in org " + strconv.Quote(org))
	}
	if new == old {
		return nil
	}
	if _, clash := reg[new]; clash {
		return UserError("a project named " + strconv.Quote(new) +
			" already exists in org " + strconv.Quote(org))
	}
	proj, err := LoadProject(entry.Path)
	if err != nil {
		return err
	}
	if proj.Org != org {
		return UserError("project " + strconv.Quote(proj.Name) + " belongs to org " +
			strconv.Quote(proj.Org) + ", not " + strconv.Quote(org) + " (Invariant 4)")
	}

	original := *proj
	renamed := *proj
	renamed.Name = new
	if err := SaveProject(entry.Path, renamed); err != nil {
		return err
	}
	delete(reg, old)
	reg[new] = entry
	if err := SaveRegistry(org, reg); err != nil {
		_ = SaveProject(entry.Path, original)
		return err
	}
	return nil
}

// RemoveProject drops a project's registry row and **keeps its
// project.json**.
//
// The file lives in the operator's repository and carries configuration
// they wrote; a registry row is Wakil's own index and is the only thing
// Wakil has standing to delete. Re-adding the folder adopts the file again.
//
// **If the project was active, the first remaining project (by sorted
// name) becomes active**, so the app is never left pointing at a row that
// no longer exists; with none left, the project is cleared. The
// environment is reset because it belonged to the removed project.
func RemoveProject(name string) error {
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	reg, err := LoadRegistryFor(org)
	if err != nil {
		return err
	}
	entry, ok := reg[name]
	if !ok {
		return UserError("no project " + strconv.Quote(name) + " in org " + strconv.Quote(org))
	}
	delete(reg, name)
	if err := SaveRegistry(org, reg); err != nil {
		return err
	}

	active, err := ReadActiveUnpinned()
	if err != nil {
		return err
	}
	if active.Project != entry.Path {
		return nil
	}
	active.Project, active.Environment = "", ""
	remaining := make([]string, 0, len(reg))
	for existing := range reg {
		remaining = append(remaining, existing)
	}
	sort.Strings(remaining)
	if len(remaining) > 0 {
		active.Project = reg[remaining[0]].Path
	}
	return WriteActive(active)
}
