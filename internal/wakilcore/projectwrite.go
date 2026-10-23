package wakilcore

import (
	"encoding/json"
	"strconv"
)

// SaveProject writes a project file back to disk.
//
// **The product's first `project.json` writer** (#207). Until now the
// runbooks hand-authored that file in full and nothing in Wakil ever wrote
// one, which is why this phase's single owed Go test is about this
// function.
//
// **Read-modify-write from disk at dispatch, never a flush of cached pane
// state.** The pane holds no configuration of its own; a caller loads,
// changes one thing, and saves. So a file hand-edited while the pane was
// open keeps the hand edit everywhere the caller did not touch — editing
// config by hand is the product, not a workaround.
//
// **Unknown keys drop, and that is stated rather than discovered.** The
// charter permits it (§1), every other reader in this package behaves the
// same way, and the alternative — round-tripping arbitrary JSON — would
// mean this writer could never be certain what it was preserving. What it
// costs is named in the owed test: a key this build does not know about
// does not survive a write.
func SaveProject(path string, p Project) error {
	if p.Name == "" || p.Org == "" {
		return UserError("refusing to write a project file with no name or org: " +
			strconv.Quote(path))
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, b)
}

// SetDatabaseDSN stores a database's connection string and records the
// database, reading the project file from disk at the moment of the write.
//
// # The DSN never reaches the project file
//
// It goes to the Keychain, under the ref the record names. What lands in
// `project.json` is the database's name, driver and REF — which is a
// Keychain entry name and not a secret. That split is not incidental: it
// is the reason a config file can be read, copied and hand-edited at all.
//
// # The ref is derived, not typed
//
// `db:<project>:<environment>:<name>`, so an operator cannot be asked to
// invent one, two databases cannot collide on a hand-typed name, and
// parity reaches the Keychain over the PATH rather than the bytes.
//
// # Granting write access is a separate, deliberate control
//
// `writeRef` is what makes a database mutable, and it names a SECOND
// credential the server itself granted — write authority proven to the
// server rather than asserted by Wakil to itself. So it is a distinct
// parameter and a distinct gesture, never a side effect of setting a DSN.
func SetDatabaseDSN(request DatabaseDSNRequest) error {
	if request.Environment == "" {
		return UserError("an environment must be named: a database belongs to one, " +
			"and a project has no databases of its own")
	}
	if request.Name == "" {
		return UserError("a database must be named")
	}
	if request.DSN == "" {
		return UserError("refusing to store an empty connection string for " +
			strconv.Quote(request.Name))
	}

	org, err := CurrentOrg()
	if err != nil {
		return err
	}

	// **Read at the moment of the write.** Not from a cache, not from the
	// pane — from disk, now.
	project, err := LoadProject(request.ProjectPath)
	if err != nil {
		return err
	}
	// **A project filed under another organisation is not this one's to
	// edit.** The same rule `ListProjectsForOrg` applies to reads: the
	// project's own file is authoritative, and this pane never writes
	// across the boundary that defines an organisation.
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + ", not " + strconv.Quote(org) +
			" — a row stored in another organisation is read-only here")
	}

	environment, ok := project.Environments[request.Environment]
	if !ok {
		return UserError("no environment " + strconv.Quote(request.Environment) +
			" in project " + strconv.Quote(project.Name))
	}

	// **Every refusal happens BEFORE anything is stored.** A write that
	// stored the read credential and then refused the grant would leave a
	// secret in the Keychain under a ref no record names — the
	// credential-without-a-record shape `CommitMintedProvider` spends a
	// whole check making unreachable for providers, and no better here.
	// It also breaks this package's standing rule that a refused write
	// writes nothing (`UpdateOrg`).
	if request.GrantWrite && request.WriteDSN == "" {
		return UserError("granting write access needs its own connection string: " +
			"write authority is a SECOND credential the database server granted, " +
			"not the read credential with a flag set")
	}

	// **A derived ref another row already names is not this row's to
	// overwrite.** A rename keeps its refs (`UpdateDatabase`), so after
	// `core` → `reports` a new `core` would derive `reports`'s ref and
	// silently replace the credential `reports` sends to its server. The
	// row's own refs do not count as taken; anyone else's do, anywhere in
	// the project.
	taken := refsNamedByOthers(project, request.Environment, "database", request.Name)
	ref := freshRef(DatabaseRef(project.Name, request.Environment, request.Name), taken)
	writeRef := ""
	if request.GrantWrite {
		taken[ref] = true
		writeRef = freshRef(ref+":rw", taken)
	}

	// **The Keychain first.** A record naming a ref with nothing behind it
	// is the shape #204 spent a whole ticket making unreachable for
	// providers, and it is no better here: the row would draw "present:
	// false" for a DSN the operator just typed.
	if err := SecretSetFor(org, ref, request.DSN); err != nil {
		return err
	}
	if request.GrantWrite {
		if err := SecretSetFor(org, writeRef, request.WriteDSN); err != nil {
			return err
		}
	}

	replaced := false
	for i, existing := range environment.Databases {
		if existing.Name != request.Name {
			continue
		}
		environment.Databases[i].Driver = request.Driver
		environment.Databases[i].Ref = ref
		// **An existing writeRef is KEPT when this call does not grant
		// one.** Setting a DSN is not a request to revoke write access,
		// and silently dropping it would make an edit to the read
		// credential un-grant a permission the operator granted
		// deliberately.
		if request.GrantWrite {
			environment.Databases[i].WriteRef = writeRef
		}
		replaced = true
		break
	}
	if !replaced {
		environment.Databases = append(environment.Databases, Database{
			Name: request.Name, Driver: request.Driver, Ref: ref, WriteRef: writeRef,
		})
	}
	project.Environments[request.Environment] = environment

	return SaveProject(request.ProjectPath, *project)
}

// DatabaseDSNRequest is one typed connection string, on its way to the
// Keychain.
//
// **The DSN is here and travels no further.** `SetDatabaseDSN` stores it
// and the caller above — the action — marks the parameter secret-bearing
// so the journal records its NAME and `[redacted]` for its value (#197).
// This is that rule's first caller.
type DatabaseDSNRequest struct {
	ProjectPath string
	Environment string
	Name        string
	Driver      string
	DSN         string
	// GrantWrite makes the database mutable, and it is a DELIBERATE
	// control rather than a flag on the row: `writeRef` names a second
	// credential the server itself granted.
	GrantWrite bool
	WriteDSN   string
}

// DatabaseRef is the Keychain ref a database's credential lives under.
//
// **Derived, never typed.** An operator asked to invent a ref invents two
// that collide; a derived one cannot, and it makes shell parity reach the
// Keychain over the PATH rather than over the bytes — the same property
// `ProviderTokenRef` has.
func DatabaseRef(project, environment, name string) string {
	return "db:" + project + ":" + environment + ":" + name
}

// refsNamedByOthers is every Keychain ref the project's API entries and
// databases name — in every environment — except the row being written,
// which is the `kind` ("api" or "database") called `name` in `environment`.
func refsNamedByOthers(project *Project, environment, kind, name string) map[string]bool {
	taken := map[string]bool{}
	for envName, env := range project.Environments {
		for _, entry := range env.API {
			if kind == "api" && envName == environment && entry.Name == name {
				continue
			}
			if entry.AuthRef != "" {
				taken[entry.AuthRef] = true
			}
		}
		for _, database := range env.Databases {
			if kind == "database" && envName == environment && database.Name == name {
				continue
			}
			if database.Ref != "" {
				taken[database.Ref] = true
			}
			if database.WriteRef != "" {
				taken[database.WriteRef] = true
			}
		}
	}
	return taken
}

// freshRef is `derived`, or — when another row already names it — the
// first of `derived:2`, `derived:3`, … that none does.
func freshRef(derived string, taken map[string]bool) string {
	if !taken[derived] {
		return derived
	}
	for n := 2; ; n++ {
		candidate := derived + ":" + strconv.Itoa(n)
		if !taken[candidate] {
			return candidate
		}
	}
}

// RemoveDatabase drops a database from an environment **and keeps its
// Keychain entry**.
//
// **"Unreferenced" is a claim the registry has no standing to make.** The
// same credential may be named by another project, by a hand-written
// script, or by a colleague's checkout of the same tree; the registry sees
// one file and cannot see any of that. So the row goes and the secret
// stays, which is recoverable, where the reverse is not.
func RemoveDatabase(projectPath, environment, name string) error {
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	project, err := LoadProject(projectPath)
	if err != nil {
		return err
	}
	if project.Org != org {
		return UserError("project " + strconv.Quote(project.Name) + " belongs to org " +
			strconv.Quote(project.Org) + " — a row stored in another organisation is read-only here")
	}
	env, ok := project.Environments[environment]
	if !ok {
		return UserError("no environment " + strconv.Quote(environment) +
			" in project " + strconv.Quote(project.Name))
	}

	kept := env.Databases[:0]
	found := false
	for _, database := range env.Databases {
		if database.Name == name {
			found = true
			continue
		}
		kept = append(kept, database)
	}
	if !found {
		return UserError("no database " + strconv.Quote(name) + " in environment " +
			strconv.Quote(environment))
	}
	env.Databases = kept
	project.Environments[environment] = env
	return SaveProject(projectPath, *project)
}

// DatabaseEdit is what an edit changes; a nil NewName leaves the name as it
// is. RevokeWrite drops the `writeRef` and nothing else.
type DatabaseEdit struct {
	NewName     *string
	RevokeWrite bool
}

// UpdateDatabase renames a database or revokes its write access in place.
//
// **Both edits keep the Keychain.** A rename leaves `ref` and `writeRef`
// alone — they are entry names, not labels — and a revoke forgets the
// `writeRef` without deleting the credential, for the reason `RemoveDatabase`
// keeps a removed database's. A rename onto another database's name is
// refused naming it.
func UpdateDatabase(projectPath, environment, name string, edit DatabaseEdit) error {
	newName := name
	if edit.NewName != nil {
		valid, err := ValidName(*edit.NewName)
		if err != nil {
			return err
		}
		newName = valid
	}
	project, err := loadOwnProject(projectPath)
	if err != nil {
		return err
	}
	env, ok := project.Environments[environment]
	if !ok {
		return UserError("no environment " + strconv.Quote(environment) +
			" in project " + strconv.Quote(project.Name))
	}
	index := -1
	for i, database := range env.Databases {
		if database.Name == name {
			index = i
		} else if database.Name == newName {
			return UserError("environment " + strconv.Quote(environment) +
				" already has a database named " + strconv.Quote(newName))
		}
	}
	if index < 0 {
		return UserError("no database " + strconv.Quote(name) + " in environment " +
			strconv.Quote(environment))
	}
	env.Databases[index].Name = newName
	if edit.RevokeWrite {
		env.Databases[index].WriteRef = ""
	}
	project.Environments[environment] = env
	return SaveProject(projectPath, *project)
}
