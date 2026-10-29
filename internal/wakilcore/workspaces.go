package wakilcore

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// The workspace record (workspaces, piece 1): ~/.wakil/orgs/<org>/workspaces.json. Each workspace
// is one piece of work in one project and environment; its checkouts are git worktrees under
// ~/.wakil/orgs/<org>/workspaces/<project>/<slug>/<repo folder>. Only worktrees named here are ever
// touched, and confinement admits them (WorkspaceRootsFor). The window writes it, through wakil-git.

const workspacesFileName = "workspaces.json"

// PortBlock is a checkout's ports (piece 2 hands them out; nil until then).
type PortBlock struct {
	First int `json:"first"`
	Count int `json:"count"`
}

// WorkspaceCheckout is one repo of a workspace. Repo is the project root (Main's folder) it is a
// checkout of; Path is the worktree, "" while none is made (archived, brought to Main, or not yet
// re-made after Restore). Snapshot is the ref holding its uncommitted work while it has no folder.
type WorkspaceCheckout struct {
	Repo       string     `json:"repo"`
	Path       string     `json:"path,omitempty"`
	Branch     string     `json:"branch"`
	Base       string     `json:"base,omitempty"`
	Ports      *PortBlock `json:"ports,omitempty"`
	LastHolder string     `json:"lastHolder,omitempty"`
	InMain     bool       `json:"inMain,omitempty"`
	Snapshot   string     `json:"snapshot,omitempty"`
	// SetUp says the recipe's copy, clone and setup ran in this checkout (piece 2): once each.
	SetUp bool `json:"setUp,omitempty"`
}

// Workspace is one piece of work. Conversations are lineage roots; View is the key its canvas is
// filed under; Parent is the workspace a branch-off came from.
type Workspace struct {
	ID            string              `json:"id"`
	Name          string              `json:"name"`
	Slug          string              `json:"slug"`
	Project       string              `json:"project"`
	Environment   string              `json:"environment"`
	Tickets       []string            `json:"tickets"`
	Parent        string              `json:"parent,omitempty"`
	Branch        string              `json:"branch,omitempty"`
	Checkouts     []WorkspaceCheckout `json:"checkouts"`
	Conversations []string            `json:"conversations"`
	View          string              `json:"view,omitempty"`
	Archived      bool                `json:"archived,omitempty"`
	Created       string              `json:"created,omitempty"`
}

// WorkspacesFile is the whole record.
type WorkspacesFile struct {
	Workspaces []Workspace `json:"workspaces"`
}

func workspacesPath(org string) (string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, workspacesFileName), nil
}

// WorkspacesDir is where an organisation's checkouts live.
func WorkspacesDir(org string) (string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "workspaces"), nil
}

func readWorkspaces(path string) (WorkspacesFile, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return WorkspacesFile{}, nil
	}
	if err != nil {
		return WorkspacesFile{}, UserError(path + " is not readable: " + err.Error())
	}
	var f WorkspacesFile
	if err := json.Unmarshal(b, &f); err != nil {
		return WorkspacesFile{}, UserError(path + " is not readable, so it is never written over: " + err.Error())
	}
	return f, nil
}

// LoadWorkspaces reads the record; none is an empty one, an unreadable one an error naming it.
func LoadWorkspaces(org string) (WorkspacesFile, error) {
	path, err := workspacesPath(org)
	if err != nil {
		return WorkspacesFile{}, err
	}
	return readWorkspaces(path)
}

// SaveWorkspaces writes the whole record atomically. It refuses to write over a file it cannot
// read, a duplicate id or slug within a project, and a checkout outside the organisation's
// workspaces folder.
func SaveWorkspaces(org string, f WorkspacesFile) error {
	path, err := workspacesPath(org)
	if err != nil {
		return err
	}
	if _, err := readWorkspaces(path); err != nil {
		return err
	}
	dir, err := WorkspacesDir(org)
	if err != nil {
		return err
	}
	ids := map[string]bool{}
	slugs := map[string]bool{}
	for _, w := range f.Workspaces {
		if w.ID == "" || ids[w.ID] {
			return UserError("workspace id " + w.ID + " is empty or used twice")
		}
		ids[w.ID] = true
		if slugs[w.Project+"/"+w.Slug] {
			return UserError("workspace slug " + w.Slug + " is used twice in " + w.Project)
		}
		slugs[w.Project+"/"+w.Slug] = true
		for _, c := range w.Checkouts {
			if c.Path != "" && !strings.HasPrefix(filepath.Clean(c.Path), dir+string(filepath.Separator)) {
				return UserError("a checkout must be under " + dir + ", not " + c.Path)
			}
		}
	}
	for i := range f.Workspaces {
		if f.Workspaces[i].Tickets == nil {
			f.Workspaces[i].Tickets = []string{}
		}
		if f.Workspaces[i].Checkouts == nil {
			f.Workspaces[i].Checkouts = []WorkspaceCheckout{}
		}
		if f.Workspaces[i].Conversations == nil {
			f.Workspaces[i].Conversations = []string{}
		}
	}
	if f.Workspaces == nil {
		f.Workspaces = []Workspace{}
	}
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(b, '\n'))
}

func pathSegment(what, s string) error {
	if s == "" || s == "." || s == ".." || strings.ContainsAny(s, "/\\\x00") {
		return UserError("unusable " + what + " for a checkout's folder: " + s)
	}
	return nil
}

// WorkspaceCheckoutPath is where a workspace's checkout of a repo lives (Invariant 4: under the
// organisation's own folder).
func WorkspaceCheckoutPath(org, project, slug, repoFolder string) (string, error) {
	for _, s := range [][2]string{{"project", project}, {"workspace", slug}, {"repo folder", repoFolder}} {
		if err := pathSegment(s[0], s[1]); err != nil {
			return "", err
		}
	}
	dir, err := WorkspacesDir(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, project, slug, repoFolder), nil
}

// WorkspaceRootsFor is every made checkout of the project's unarchived workspaces: the roots a
// workspace's agent and the operator's view reach beside Main's. An unreadable record adds none.
func WorkspaceRootsFor(org, project string) []string {
	f, err := LoadWorkspaces(org)
	if err != nil {
		return nil
	}
	var roots []string
	for _, w := range f.Workspaces {
		if w.Archived || w.Project != project {
			continue
		}
		for _, c := range w.Checkouts {
			if c.Path != "" {
				roots = append(roots, c.Path)
			}
		}
	}
	return roots
}

// AllowedRootPaths is the active project's roots, then its workspaces' checkouts: what wakil-git
// and wakil-files confine to.
func AllowedRootPaths(r Resolved) []string {
	roots := ProjectRootPaths(r)
	if r.Org == "" || r.ProjectKey == "" {
		return roots
	}
	return append(roots, WorkspaceRootsFor(r.Org, r.ProjectKey)...)
}
