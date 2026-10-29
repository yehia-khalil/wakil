package wakilcore

import "strconv"

// ProjectAgentInstructions is a project's agent instructions (3a-iii-b, Decision 45), written in
// its project.json beside its name and environments, and appended after the organisation's.
type ProjectAgentInstructions struct {
	General      string `json:"general,omitempty"`
	Commits      string `json:"commits,omitempty"`
	PullRequests string `json:"pullRequests,omitempty"`
	// Branches (workspaces, decision 10): how a workspace's branch is named.
	Branches string `json:"branches,omitempty"`
}

// ProjectAgentPatch names the texts to change; nil leaves one as it is, "" clears it.
type ProjectAgentPatch struct {
	General, Commits, PullRequests, Branches *string
}

func (p *Project) agentTexts() ProjectAgentInstructions {
	if p == nil || p.Agent == nil {
		return ProjectAgentInstructions{}
	}
	return *p.Agent
}

// UpdateProjectAgentInstructions applies patch to the project file at projectPath, read from disk
// now (read-modify-write, as UpdateProjectEditorSettings). A project of another organisation is
// read-only here.
func UpdateProjectAgentInstructions(projectPath string, patch ProjectAgentPatch) error {
	if patch.General == nil && patch.Commits == nil && patch.PullRequests == nil && patch.Branches == nil {
		return nil
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return err
	}
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " + strconv.Quote(project.Org) +
			", not " + strconv.Quote(org) + " — a project stored in another organisation is read-only here")
	}
	a := project.agentTexts()
	if patch.General != nil {
		a.General = *patch.General
	}
	if patch.Commits != nil {
		a.Commits = *patch.Commits
	}
	if patch.PullRequests != nil {
		a.PullRequests = *patch.PullRequests
	}
	if patch.Branches != nil {
		a.Branches = *patch.Branches
	}
	if a == (ProjectAgentInstructions{}) {
		project.Agent = nil
	} else {
		project.Agent = &a
	}
	return SaveProject(projectPath, *project)
}
