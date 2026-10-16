package main

import (
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// runProject dispatches `wakil project <verb> ...`. Like runOrg and
// runProvider, no verb here takes a secretStore. "list" is the only verb
// that uses stdout — see runProjectList's doc comment — every other verb
// ignores the parameter entirely.
func runProject(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing project command\n\n"+usage)))
		return 2
	}
	switch args[0] {
	case "add":
		return runProjectAdd(args[1:], stderr)
	case "list":
		return runProjectList(args[1:], stdout, stderr)
	case "rm":
		return runProjectRm(args[1:], stderr)
	default:
		fmt.Fprintln(stderr, message(wakilcore.UserError("unknown project command "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
}

// runProjectAdd implements `wakil project add <name> --path P [--provider ID]`.
//
// It refuses a project.json whose declared org does not match the
// current org, naming both. The project's own project.json is
// authoritative for org (see wakilcore.ListProjectsForOrg's doc comment);
// this check catches a misfiled project at the point it is CREATED,
// rather than only reporting it later out of `project list`.
//
// It also refuses to overwrite an existing registry entry under the same
// name — the same duplicate-refusing shape as wakilcore.CreateOrg and
// wakilcore.AddProvider, so a typo'd re-add cannot silently repoint an
// existing project entry at a different path.
func runProjectAdd(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <name>\n\n"+usage)))
		return 2
	}
	name := args[0]

	var path, provider string
	fs := flag.NewFlagSet("project add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&path, "path", "", "absolute path to the project's project.json")
	fs.StringVar(&provider, "provider", "", "the provider that should work on this project (optional)")
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil project add`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}
	if path == "" {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing required flag --path\n\n"+usage)))
		return 2
	}
	if !filepath.IsAbs(path) {
		fmt.Fprintln(stderr, message(wakilcore.UserError("invalid --path "+strconv.Quote(path)+" — it must be absolute, because it is resolved wherever the MCP server happens to start, not relative to this command's working directory")))
		return 2
	}

	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	proj, err := wakilcore.LoadProject(path)
	if err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("could not load project file "+path+": "+err.Error())))
		return 2
	}
	if proj.Org != org {
		fmt.Fprintln(stderr, message(wakilcore.UserError(
			"project.json at "+path+" declares org "+strconv.Quote(proj.Org)+
				", but the current org is "+strconv.Quote(org)+
				" — a project can only be registered under the org it declares")))
		return 2
	}

	// --provider is optional, but when given it must name a provider
	// actually registered under org — the same rule finding 2 of the
	// final review imposes on org.json's defaultProvider, for the same
	// reason: a typo'd --provider used to be accepted silently here and
	// surface only much later as a provider mismatch nobody could act
	// on. LoadProviderFor already raises the right message for both a
	// malformed id and an unregistered one.
	if provider != "" {
		if _, err := wakilcore.LoadProviderFor(org, provider); err != nil {
			fmt.Fprintln(stderr, message(err))
			return regExitCode(err)
		}
	}

	reg, err := wakilcore.LoadRegistryFor(org)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if _, exists := reg[name]; exists {
		fmt.Fprintln(stderr, message(wakilcore.UserError("project "+strconv.Quote(name)+" already exists in org "+strconv.Quote(org))))
		return 2
	}
	reg[name] = wakilcore.ProjectEntry{Path: path, Provider: provider}
	if err := wakilcore.SaveRegistry(org, reg); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "added project %q (%s) to org %q\n", name, path, org)
	return 0
}

// runProjectList implements `wakil project list`.
//
// Each project's row goes to STDOUT, formatted "<name>  path=<path>
// provider=<provider>", one per line and nothing else on that stream —
// the same treatment `org list` and `provider list` already give their
// own rows (I ruled earlier in this branch that list ROWS are data a
// caller can pipe, and only diagnostics belong on stderr; this command
// was the one missed). Misfiled and unreadable entries
// (wakilcore.ProjectListing) are reported as warnings on stderr rather
// than silently dropped — the same reasoning as ListProjectsForOrg's own
// doc comment: a vanished project with no explanation is worse than a
// listed one with a warning attached — and a warning is a diagnostic,
// not a row, so it stays off stdout. The usage/argument error, a
// ListProjectsForOrg failure, and the "no projects registered" notice
// for an empty registry are diagnostics too.
func runProjectList(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
	listing, err := wakilcore.ListProjectsForOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	names := make([]string, 0, len(listing.Projects))
	for name := range listing.Projects {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) == 0 {
		fmt.Fprintln(stderr, "no projects registered")
	}
	for _, name := range names {
		e := listing.Projects[name]
		fmt.Fprintf(stdout, "%s  path=%q provider=%q\n", name, e.Path, e.Provider)
	}
	for _, m := range listing.Misfiled {
		fmt.Fprintf(stderr, "warning: %q is filed under org %q but its project.json declares org %q\n", m.Name, m.FiledUnder, m.DeclaredOrg)
	}
	for _, name := range listing.Unreadable {
		fmt.Fprintf(stderr, "warning: could not read the project.json for %q\n", name)
	}
	return 0
}

// runProjectRm implements `wakil project rm <name>`. It removes only the
// registry entry — the project.json file itself is untouched, since the
// registry is an index over files this command does not own.
func runProjectRm(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <name>\n\n"+usage)))
		return 2
	}
	name := args[0]
	if len(args) > 1 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[1])+"\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	reg, err := wakilcore.LoadRegistryFor(org)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if _, exists := reg[name]; !exists {
		fmt.Fprintln(stderr, message(wakilcore.UserError("no project "+strconv.Quote(name)+" in org "+strconv.Quote(org))))
		return 2
	}
	delete(reg, name)
	if err := wakilcore.SaveRegistry(org, reg); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "removed project %q from org %q\n", name, org)
	return 0
}
