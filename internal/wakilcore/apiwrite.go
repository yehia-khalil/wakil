package wakilcore

import "strconv"

// ApiRef is the Keychain ref an API entry's token lives under.
//
// Derived, never typed, for the reason `DatabaseRef` is.
func ApiRef(project, environment, name string) string {
	return "api:" + project + ":" + environment + ":" + name
}

// ApiEntryRequest is one API entry on its way to an environment. The token,
// when there is one, goes to the Keychain and travels no further.
type ApiEntryRequest struct {
	ProjectPath string
	Environment string
	Name        string
	BaseURL     string
	AuthHeader  string
	Token       string
}

// SetApiEntry adds an API entry to an environment, or replaces the one of
// that name, reading the project file from disk at the moment of the write.
//
// **The token never reaches the project file.** It goes to the Keychain under
// `ApiRef`, before the file is written, and the file keeps the ref. An empty
// token keeps whatever `authRef` an existing entry already has: editing the
// base URL is not a request to drop its credential. A token is stored under
// the derived `ApiRef`, suffixed `:2`, `:3`, … when another row of the
// project already names it (a renamed entry keeps its old name's ref).
//
// Every refusal happens before the Keychain is touched, so a refused write
// writes nothing.
func SetApiEntry(r ApiEntryRequest) error {
	name, err := ValidName(r.Name)
	if err != nil {
		return err
	}
	base, err := NormalizeHTTPBase(r.BaseURL)
	if err != nil {
		return err
	}
	if err := ValidateAuthHeader(r.AuthHeader); err != nil {
		return err
	}
	project, err := loadOwnProject(r.ProjectPath)
	if err != nil {
		return err
	}
	env, ok := project.Environments[r.Environment]
	if !ok {
		return UserError("no environment " + strconv.Quote(r.Environment) +
			" in project " + strconv.Quote(project.Name))
	}

	ref := ""
	if r.Token != "" {
		// **A derived ref another row already names gets `:2`, `:3`, ….**
		// A rename keeps its `authRef`, so a new entry under the old name
		// would otherwise overwrite the renamed one's credential, which goes
		// to the renamed one's host. The entry's own ref is not taken: one
		// replacing its own token keeps the derived ref it has.
		ref = freshRef(ApiRef(project.Name, r.Environment, name),
			refsNamedByOthers(project, r.Environment, "api", name))
		org, err := CurrentOrg()
		if err != nil {
			return err
		}
		if err := SecretSetFor(org, ref, r.Token); err != nil {
			return err
		}
	}

	replaced := false
	for i := range env.API {
		if env.API[i].Name != name {
			continue
		}
		env.API[i].BaseURL = base
		env.API[i].AuthHeader = r.AuthHeader
		if ref != "" {
			env.API[i].AuthRef = ref
		}
		replaced = true
		break
	}
	if !replaced {
		env.API = append(env.API, ApiConfig{
			Name: name, BaseURL: base, AuthRef: ref, AuthHeader: r.AuthHeader,
		})
	}
	project.Environments[r.Environment] = env
	return SaveProject(r.ProjectPath, *project)
}

// ApiEntryEdit is what an edit changes; a nil field is left as it is.
// ClearToken drops the entry's `authRef` and nothing else.
type ApiEntryEdit struct {
	NewName, BaseURL, AuthHeader *string
	ClearToken                   bool
}

// UpdateApiEntry edits one API entry in place. A rename that lands on another
// entry's name is refused naming it; renaming to its own name changes nothing.
// The Keychain is never touched: `ClearToken` forgets the ref, not the item.
func UpdateApiEntry(projectPath, environment, name string, edit ApiEntryEdit) error {
	newName := name
	if edit.NewName != nil {
		valid, err := ValidName(*edit.NewName)
		if err != nil {
			return err
		}
		newName = valid
	}
	base := ""
	if edit.BaseURL != nil {
		normalized, err := NormalizeHTTPBase(*edit.BaseURL)
		if err != nil {
			return err
		}
		base = normalized
	}
	if edit.AuthHeader != nil {
		if err := ValidateAuthHeader(*edit.AuthHeader); err != nil {
			return err
		}
	}

	project, env, err := loadApiEnvironment(projectPath, environment)
	if err != nil {
		return err
	}
	index := apiIndex(env, name)
	if index < 0 {
		return noApiEntry(name, environment)
	}
	if newName != name && apiIndex(env, newName) >= 0 {
		return UserError("environment " + strconv.Quote(environment) +
			" already has an API entry named " + strconv.Quote(newName))
	}

	entry := &env.API[index]
	entry.Name = newName
	if edit.BaseURL != nil {
		entry.BaseURL = base
	}
	if edit.AuthHeader != nil {
		entry.AuthHeader = *edit.AuthHeader
	}
	if edit.ClearToken {
		entry.AuthRef = ""
	}
	project.Environments[environment] = env
	return SaveProject(projectPath, *project)
}

// RemoveApiEntry drops an API entry from an environment **and keeps its
// Keychain item**, for the reason `RemoveDatabase` keeps a database's.
func RemoveApiEntry(projectPath, environment, name string) error {
	project, env, err := loadApiEnvironment(projectPath, environment)
	if err != nil {
		return err
	}
	index := apiIndex(env, name)
	if index < 0 {
		return noApiEntry(name, environment)
	}
	env.API = append(env.API[:index], env.API[index+1:]...)
	project.Environments[environment] = env
	return SaveProject(projectPath, *project)
}

func loadApiEnvironment(projectPath, environment string) (*Project, Environment, error) {
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return nil, Environment{}, err
	}
	env, ok := project.Environments[environment]
	if !ok {
		return nil, Environment{}, UserError("no environment " + strconv.Quote(environment) +
			" in project " + strconv.Quote(project.Name))
	}
	return project, env, nil
}

func apiIndex(env Environment, name string) int {
	for i, entry := range env.API {
		if entry.Name == name {
			return i
		}
	}
	return -1
}

func noApiEntry(name, environment string) error {
	return UserError("no API entry " + strconv.Quote(name) + " in environment " +
		strconv.Quote(environment))
}
