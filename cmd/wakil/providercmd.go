package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// providerServers names the six MCP servers a client must point at a
// codex or local provider's own launch environment — the same list
// scripts/register-provider.sh registers automatically for claude-code
// (SERVERS in that script). `wakil` itself is excluded there and here:
// it is the operator CLI, not an MCP server.
var providerServers = []string{"wakil-ctx", "wakil-db", "wakil-pm", "wakil-http", "wakil-recall", "wakil-git"}

// runProvider dispatches `wakil provider <verb> ...`. Like runOrg, no
// verb here takes a secretStore: these calls read and write provider
// JSON files, never write to the Keychain. It does take a secretReader,
// used only by "credentials" (providercredentials.go), which reads back
// the OAuth token a provider's account was given under
// wakilcore.ProviderTokenRef; every other verb ignores it. "list" is the
// only other verb that uses the stdout PARAMETER; "config-dir" and
// "home" write to os.Stdout directly (see their own doc comments for
// why), and every other verb ignores the stdout parameter entirely.
func runProvider(args []string, stdout, stderr io.Writer, read secretReader) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing provider command\n\n"+usage)))
		return 2
	}
	switch args[0] {
	case "add":
		return runProviderAdd(args[1:], stderr)
	case "list":
		return runProviderList(args[1:], stdout, stderr)
	case "rm":
		return runProviderRm(args[1:], stderr)
	case "config-dir":
		return runProviderConfigDir(args[1:], stderr)
	case "home":
		return runProviderHome(args[1:], stderr)
	case "credentials":
		return runProviderCredentials(args[1:], stdout, stderr, read)
	case "mint":
		return runProviderMint(args[1:], stdout, stderr)
	default:
		fmt.Fprintln(stderr, message(wakilcore.UserError("unknown provider command "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
}

// runProviderAdd implements `wakil provider add <id> --kind ... [flags]`.
//
// For --kind codex and --kind local it additionally prints, honestly,
// that wakil does not register those clients' MCP servers automatically
// (only claude-code has that automation, in scripts/register-provider.sh
// — see providerServers) and states the exact environment the operator
// must configure by hand: WAKIL_ORG, WAKIL_PROVIDER, and the six server
// binaries.
func runProviderAdd(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]

	var p wakilcore.Provider
	fs := flag.NewFlagSet("provider add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&p.Kind, "kind", "", "claude-code, codex or local")
	fs.StringVar(&p.ConfigDir, "config-dir", "", "the CLAUDE_CONFIG_DIR that account uses (--kind claude-code only)")
	fs.StringVar(&p.Label, "label", "", "a human label for this provider")
	fs.StringVar(&p.ClaudePath, "claude-path", "", "the agent binary this provider launches (--kind claude-code only)")
	fs.StringVar(&p.BaseURL, "base-url", "", "a local endpoint's URL (--kind local only)")
	var serves string
	fs.StringVar(&serves, "serves", "", "ignored since 3b-ix: a local endpoint serves every quick task (kept so old scripts parse)")
	// "--kind claude-code only" is not merely advisory here: AddProvider
	// refuses the combination rather than ignoring it. Flag help that
	// states a restriction nothing enforces is how `--share --kind codex`
	// came to be accepted, stored, and answered with a fabricated message.
	fs.BoolVar(&p.Shared, "share", false,
		"register an account another org already homes (--kind claude-code only)")
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil provider add`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}
	p.ID = id
	if serves != "" {
		p.Serves = strings.Split(serves, ",")
	}

	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	if err := wakilcore.AddProvider(org, p); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "added provider %q (kind %s) to org %q\n", id, p.Kind, org)

	if p.Shared {
		// Reload rather than reuse the local p: AddProvider took p by
		// value and resolved its ConfigDir through EvalSymlinks before
		// storing it (macOS routinely symlinks a temp dir, e.g.
		// /tmp -> /private/tmp), so the caller's copy can name a path
		// ConfigDirHome — which compares against the resolved, stored
		// value — will not recognise.
		//
		// stored.ConfigDir cannot be empty here: AddProvider refuses
		// --share on any kind that has no config dir, and refuses a
		// claude-code provider with no --config-dir, so reaching this line
		// means both were present. Before that refusal existed, `--share
		// --kind codex` stored shared:true with an empty ConfigDir and this
		// block printed a sentence about a directory with no path, naming
		// whichever unrelated record also had an empty ConfigDir as its
		// home. ConfigDirHome now also answers "" for "", so the fabricated
		// sentence has two independent defences rather than one.
		stored, err := wakilcore.LoadProviderFor(org, id)
		if err == nil {
			homeOrg, homeID, err := wakilcore.ConfigDirHome(stored.ConfigDir)
			if err == nil && homeOrg != "" {
				fmt.Fprintf(stderr,
					"\nthis account is shared: %s/%s still pins WAKIL_ORG inside %s, so a plain `claude` session started there runs as %q, not %q.\nInside Wakil it runs as %q, because Wakil passes every session its own org.\n",
					homeOrg, homeID, stored.ConfigDir, homeOrg, org, org)
			}
		}
	}

	if p.Kind == wakilcore.ProviderKindCodex || p.Kind == wakilcore.ProviderKindLocal {
		fmt.Fprintf(stderr, "\nwakil does not register a %s provider's MCP servers for you — that automation exists only for claude-code. Configure your client by hand with:\n", p.Kind)
		fmt.Fprintf(stderr, "  WAKIL_ORG=%s\n", org)
		fmt.Fprintf(stderr, "  WAKIL_PROVIDER=%s\n", id)
		fmt.Fprintf(stderr, "and the built binary path for each of: %s\n", joinNames(providerServers))
	}
	return 0
}

// joinNames renders names as a comma-separated list, e.g. "a, b, c".
func joinNames(names []string) string {
	out := ""
	for i, n := range names {
		if i > 0 {
			out += ", "
		}
		out += n
	}
	return out
}

// runProviderList implements `wakil provider list`.
//
// Each provider's row goes to STDOUT, formatted
// "<id>  kind=<kind> label=<label> configDir=<dir>", one per line and
// nothing else on that stream — register-provider.sh (scripts/) parses
// exactly this format, matching the id against its own first
// whitespace-separated field. Everything else — the usage/argument
// error, a CurrentOrg or ListProvidersFor failure, and the "no providers
// registered" notice for an empty org — is a DIAGNOSTIC rather than a row
// of data, so it stays on stderr.
func runProviderList(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[0])+"\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	providers, err := wakilcore.ListProvidersFor(org)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if len(providers) == 0 {
		fmt.Fprintf(stderr, "no providers registered in org %q\n", org)
		return 0
	}
	for _, p := range providers {
		fmt.Fprintf(stdout, "%s  kind=%s label=%q configDir=%q\n", p.ID, p.Kind, p.Label, p.ConfigDir)
	}
	return 0
}

// runProviderRm implements `wakil provider rm <id>`.
func runProviderRm(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]
	if len(args) > 1 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[1])+"\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if err := wakilcore.RemoveProvider(org, id); err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	fmt.Fprintf(stderr, "removed provider %q from org %q\n", id, org)
	return 0
}

// runProviderConfigDir implements `wakil provider config-dir <id>`.
//
// Alongside `org list`, `provider list` and `provider home`, this is one
// of the four subcommands in the binary that write to stdout. It and
// `provider home` are the two that reach for os.Stdout directly with
// fmt.Println rather than taking a stdout parameter — tests observe both
// with the os.Pipe-based captureStdout helper (orgcmd_test.go) instead of
// a plain buffer. It exists for scripts/register-provider.sh (which replaced
// scripts/register-org.sh), which needs one value in one line of shell
// without depending on `jq` being installed.
// On success it prints ONLY p.ConfigDir, with a trailing newline and
// nothing else — no label, no quotes — and exits 0. A provider whose kind
// has no configDir (codex, local) is not a usage mistake the operator can
// retype their way out of, so it is reported on stderr and exits 1,
// matching this command's "failure while doing the work" code rather
// than the "2" used for a bad invocation.
func runProviderConfigDir(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]
	if len(args) > 1 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[1])+"\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	p, err := wakilcore.LoadProviderFor(org, id)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if p.ConfigDir == "" {
		fmt.Fprintln(stderr, message(wakilcore.UserError("provider "+strconv.Quote(id)+" (kind "+p.Kind+") has no configDir — only a claude-code provider has one")))
		return 1
	}
	fmt.Println(p.ConfigDir)
	return 0
}

// runProviderHome implements `wakil provider home <id>`.
//
// Prints, on stdout, the org that pinned WAKIL_ORG inside this provider's
// config dir — its own org when the record is not shared, the homing org
// when it is. One line, nothing else, exactly as `provider config-dir`
// does, because scripts/register-provider.sh consumes it with command
// substitution.
//
// Exit codes follow runProviderConfigDir's convention: 2 for a bad
// invocation the operator can retype their way out of (missing id, an
// extra argument, an unresolvable org), and 1 for a failure encountered
// while doing the work (a provider with no configDir, or a configDir no
// org currently homes).
func runProviderHome(args []string, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]
	if len(args) > 1 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(args[1])+"\n\n"+usage)))
		return 2
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	p, err := wakilcore.LoadProviderFor(org, id)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if p.ConfigDir == "" {
		fmt.Fprintln(stderr, message(wakilcore.UserError(
			"provider "+strconv.Quote(id)+" (kind "+p.Kind+") has no configDir — only a claude-code provider pins an org inside one")))
		return 1
	}
	homeOrg, _, err := wakilcore.ConfigDirHome(p.ConfigDir)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return regExitCode(err)
	}
	if homeOrg == "" {
		// Every registered claude-code provider was either the first (and
		// so the home) or was added with --share against an existing home,
		// and `wakil provider rm` now refuses to delete a home while
		// sharers remain. So no single `wakil provider` command reaches
		// this state. It stays reachable by deleting the homing record out
		// from under its sharers some other way: `wakil org rm <home-org>
		// --force`, which deletes a whole org directory and says so, or
		// removing the record file by hand. Say that rather than printing
		// an empty line a script would read as success.
		//
		// The instruction below matters as much as the diagnosis. An
		// earlier version said `wakil provider add <id> ... --org <org>`
		// with no --share, which AddProvider REFUSES here: the orphaned
		// sharers still name the dir, so the add hits the "already
		// registered" path and the operator is sent in a circle. The route
		// out is to remove the orphans first — their own org is where the
		// record lives — and then register the dir afresh, which re-homes
		// it; the WAKIL_ORG pinned inside the directory is untouched by any
		// of this and must be re-written by register-provider.sh.
		fmt.Fprintln(stderr, message(wakilcore.UserError(
			"no org pins WAKIL_ORG inside "+p.ConfigDir+" — the record that homed it has been removed,"+
				" and provider "+strconv.Quote(id)+" only shares the directory."+
				" To repair: remove every sharing record for this dir (`wakil provider rm <id> --org <org>`,"+
				" one per org that lists it — `wakil provider list --org <org>` shows the configDir),"+
				" then register it again without --share to re-home it,"+
				" then re-run scripts/register-provider.sh for that org so the pin inside the directory matches the record")))
		return 1
	}
	fmt.Println(homeOrg)
	return 0
}

// runProviderMint implements `wakil provider mint <id> --config-dir <dir>
// [--claude-path <path>]` — the one-shot verb Wakil.app spawns for the
// SECOND browser trip (#204).
//
// # Why a verb and not an MCP action
//
// Three reasons, each independently sufficient, and they are the same
// three MintProviderToken's own doc comment states: every `ctx_*` action
// is a thin proxy on a ten-second reply timeout while a browser trip is
// minutes; `JournalEntry.params` is written verbatim on every dispatch so
// a secret cannot ride in an action's parameters; and a separate process
// survives a `wakil-ctx` restart mid-flight.
//
// It mirrors `wakil provider credentials`, which has shipped all along as
// the credential READ path Swift spawns and reads off a stdout pipe. This
// is its write half — except that nothing comes back on the pipe but an
// outcome, because the token never leaves Go.
//
// # It prints no token, ever
//
// `providerCredentials`'s doc comment calls itself "the only command in
// this binary that prints a secret", and that stays true: this one prints
// a JSON outcome saying whether the credential was stored, whether the
// result is uncertain, and one sentence for the operator. There is no
// field a token could travel in.
//
// # Shell parity
//
// This verb adds no capability the shell lacked. `claude setup-token`
// already exists and is the equal of the mint — the equal is the
// underlying tool, not a mirrored verb. What this collapses is two
// already-possible unrecorded steps (capture, then `wakil secrets set`)
// into one that cannot drop the token between them.
func runProviderMint(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("missing <id>\n\n"+usage)))
		return 2
	}
	id := args[0]
	fs := flag.NewFlagSet("provider mint", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configDir := fs.String("config-dir", "", "the CLAUDE_CONFIG_DIR to mint against")
	claudePath := fs.String("claude-path", "", "the agent binary to run")
	if err := fs.Parse(args[1:]); err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("bad flags for `wakil provider mint`: "+err.Error()+"\n\n"+usage)))
		return 2
	}
	if fs.NArg() > 0 {
		fmt.Fprintln(stderr, message(wakilcore.UserError("unexpected argument "+strconv.Quote(fs.Arg(0))+"\n\n"+usage)))
		return 2
	}

	org, err := wakilcore.CurrentOrg()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}

	// **The config dir is DERIVED when none is given**, rather than
	// defaulted to something: the one-string rule says whatever Wakil
	// hands to CLAUDE_CONFIG_DIR is what it must hash, and the derivation
	// is the one place that string is decided.
	dir := *configDir
	if dir == "" {
		dir, err = wakilcore.EnsureConfigDir(id)
		if err != nil {
			fmt.Fprintln(stderr, message(err))
			return 1
		}
	}

	outcome := wakilcore.MintProviderToken(org, id, dir, *claudePath)
	encoded, err := json.Marshal(outcome)
	if err != nil {
		fmt.Fprintln(stderr, message(wakilcore.UserError("could not encode the mint outcome: "+err.Error())))
		return 1
	}
	fmt.Fprintln(stdout, string(encoded))

	// **An uncertain outcome exits non-zero**, because it is not a
	// success — but it is distinguishable from a clean failure by the
	// JSON, which is what the caller reads. Exit status alone cannot
	// carry three outcomes, and the one that must not be lost is the
	// uncertain one.
	if !outcome.Stored {
		return 1
	}
	return 0
}
