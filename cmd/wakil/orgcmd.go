package main

import (
	"flag"
	"fmt"
	"io"
	"strconv"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// runOrg dispatches `wakil org <verb> ...`. None of its verbs take a
// secretStore: every one of them reads or writes org.json, never the
// Keychain. Only "list" uses stdout; every other verb ignores it.
func runOrg(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing org command\n\n"+usage)))
		return 2
	}
	switch args[0] {
	case "create":
		return runOrgCreate(args[1:], stderr)
	case "set":
		return runOrgSet(args[1:], stderr)
	case "list":
		return runOrgList(args[1:], stdout, stderr)
	case "rm":
		return runOrgRm(args[1:], stderr)
	default:
		fmt.Fprintln(stderr, message(wakilcore.UserError("unknown org command "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
}

// orgFieldFlags builds the --display/--jira-base/--default-provider flag
// set shared by `org create` and `org set`, given the arguments AFTER the
// org name. verb names the flag set for its error messages ("create" or
// "set"). The caller parses it and, for "set", consults fs.Visit to see
// which flags were actually given — see runOrgSet's doc comment for why
// that matters there and not in runOrgCreate.
func orgFieldFlags(verb string, o *wakilcore.Org) *flag.FlagSet {
	fs := flag.NewFlagSet("org "+verb, flag.ContinueOnError)
	// See parseSecretsSetDB's fs.SetOutput(io.Discard): the flag package's
	// own error text and this function's returned error would otherwise
	// both reach the operator, printed twice.
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.DisplayName, "display", "", "human-readable display name")
	fs.StringVar(&o.JiraBase, "jira-base", "", "the org's Jira site, e.g. https://acme.atlassian.net")
	fs.StringVar(&o.DefaultProvider, "default-provider", "", "provider id used for projects naming none of their own")
	return fs
}

// parseOrgFields parses args (the arguments after the org name) against
// orgFieldFlags for verb, rejecting a bad flag or a trailing positional
// argument.
func parseOrgFields(verb string, args []string) (wakilcore.Org, error) {
	var o wakilcore.Org
	fs := orgFieldFlags(verb, &o)
	if err := fs.Parse(args); err != nil {
		return wakilcore.Org{}, wakilcore.UserError("bad flags for `wakil org " + verb + "`: " + err.Error() + "\n\n" + usage)
	}
	if fs.NArg() > 0 {
		return wakilcore.Org{}, wakilcore.UserError("unexpected argument " + strconv.Quote(fs.Arg(0)) + "\n\n" + usage)
	}
	return o, nil
}

// runOrgCreate implements `wakil org create <org> [flags]`.
func runOrgCreate(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <org>\n\n"+usage)))
		return 2
	}
	org := args[0]
	fields, err := parseOrgFields("create", args[1:])
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if err := wakilcore.CreateOrg(org, fields); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "created org %q\n", org)
	return 0
}

// runOrgSet implements `wakil org set <org> [flags]`.
//
// It MERGES rather than replaces: it loads the org's existing record and
// overwrites only the fields whose flags were actually given (fs.Visit),
// so `wakil org set initech --jira-base https://x` cannot silently blank out
// a defaultProvider set by an earlier `org create` or `org set` call. A
// bare struct default — what runOrgCreate uses, correctly, since there is
// no existing record to merge into — would do exactly that here, because
// DisplayName/JiraBase/DefaultProvider all default to the empty string an
// unset flag also produces.
func runOrgSet(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <org>\n\n"+usage)))
		return 2
	}
	org := args[0]

	var given wakilcore.Org
	fs := orgFieldFlags("set", &given)
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil org set`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}

	existing, err := wakilcore.LoadOrgFor(org)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	merged := *existing
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "display":
			merged.DisplayName = given.DisplayName
		case "jira-base":
			merged.JiraBase = given.JiraBase
		case "default-provider":
			merged.DefaultProvider = given.DefaultProvider
		}
	})

	if err := wakilcore.SaveOrg(org, merged); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "updated org %q\n", org)
	return 0
}

// runOrgList implements `wakil org list`.
//
// The org ids themselves go to STDOUT, one per line and nothing else on
// that stream, so `wakil org list` is pipeable — register-provider.sh
// (scripts/) is exactly such a consumer, checking whether a given org
// appears in this output. Everything else — the usage/argument error, a
// ListOrgs failure, and the "no orgs registered" notice for an empty
// registry — is a DIAGNOSTIC about the command itself rather than a row
// of data, so it stays on stderr, matching every other subcommand in this
// binary.
func runOrgList(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
	orgs, err := wakilcore.ListOrgs()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if len(orgs) == 0 {
		fmt.Fprintln(stderr, "no orgs registered")
		return 0
	}
	for _, org := range orgs {
		fmt.Fprintln(stdout, org)
	}
	return 0
}

// runOrgRm implements `wakil org rm <org> [--force]`.
func runOrgRm(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <org>\n\n"+usage)))
		return 2
	}
	org := args[0]

	fs := flag.NewFlagSet("org rm", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	force := fs.Bool("force", false, "delete even if the org still holds providers or projects")
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil org rm`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}

	// Read before the directory goes: the id is the only handle on the org's browser store.
	store := wakilcore.BrowserStoreID(org)
	// Saved browser passwords live in the Keychain, outside the directory. Attributes only: nothing
	// is read and nothing prompts. A failed check never blocks the removal.
	logins, loginsErr := wakilcore.BrowserLoginsPresent(org)
	if err := wakilcore.RemoveOrg(org, *force); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "removed org %q\n", org)
	if store != "" {
		// 3c-i (final review I6): WebKit keeps the org's site logins outside its directory.
		fmt.Fprintf(stderr, "its browser data stays in WebKit's store %s under ~/Library/WebKit, and Wakil no longer has its id to clear it — next time, clear it first in Wakil (Settings → Browser → Clear this organisation's browsing data…)\n", store)
	}
	if loginsErr != nil {
		fmt.Fprintf(stderr, "could not check the Keychain for its saved browser passwords: %v\n", loginsErr)
	} else if logins {
		fmt.Fprintf(stderr, "its saved browser passwords stay in the Keychain under wakil:%s:browser-login:default — next time, delete them first in Wakil (Settings → Browser → Passwords)\n", org)
	}
	return 0
}
