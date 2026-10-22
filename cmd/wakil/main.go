// Command wakil is the operator-facing CLI. It has four subcommand
// families:
//
//   - `wakil secrets set` / `secrets set-db` / `secrets set-api` put a
//     credential into the macOS login Keychain under the ref that a
//     project.json (Database.Ref / ApiConfig.AuthRef) names, so that the
//     MCP servers can read it back with wakilcore.SecretGet. The two
//     composing aids differ from bare `set` only in that they build the
//     stored string — a DSN, an Authorization header value — out of a
//     secret read from stdin and non-secret parts read from argv.
//   - `wakil org create|set|list|rm` manage the per-org record under
//     ~/.wakil/orgs/<org>/org.json.
//   - `wakil provider add|list|rm|config-dir|home` manage the provider
//     records under an org's providers/ directory.
//   - `wakil project add|list|rm` manage an org's project registry.
//
// Only the `secrets` family ever touches the Keychain. `org`, `provider`
// and `project` read and write plain JSON files under ~/.wakil and never
// call the secretStore seam at all — see orgcmd.go, providercmd.go and
// projectcmd.go.
//
// A stored credential belongs to ONE org. The Keychain item's name is
// "wakil:<org>:<ref>" (see wakilcore.keychainService), and the org comes
// from WAKIL_ORG (or the global --org flag, which sets it) at the moment
// this command runs — so `wakil secrets set` must be run with the same
// org the MCP servers were registered with, or it stores a perfectly good
// credential at an address nothing will ever read. There is no way for
// this command to detect that on its own, so instead it prints the org it
// resolved both in the paste prompt and in the confirmation line: once
// early enough to abort, once as a durable record.
//
// Every secret VALUE this command handles arrives on stdin and never on
// the command line. That is deliberate and non-negotiable: an argv token
// lands in the operator's shell history and is readable by any local
// process via `ps -ww` for the lifetime of the command. wakilcore.SecretSet
// is already forced to put the value in `security add-generic-password`'s
// own argv (see its doc comment — the `security` CLI offers no stdin or
// file input, and CGO is off so a Keychain binding is not an option), and
// that exposure window is as small as it can be made. Widening it back out
// to the operator's own shell would be pure loss, so no subcommand in this
// binary has a flag that takes a secret value, and none may ever grow one.
//
// Human-facing output — confirmations, prompts, errors, and any diagnostic
// about WHY a list is empty — goes to stderr, for every subcommand. Four
// subcommands additionally write machine-consumable data to stdout, and
// only that data: `provider config-dir` and `provider home` (exactly one
// value each, see their doc comments for why — both are read by
// scripts/register-provider.sh with command substitution), `org list` and
// `provider list` (one row per registered org or provider — see their doc
// comments in orgcmd.go and providercmd.go). Every other subcommand
// leaves stdout empty.
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/go-sql-driver/mysql"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

const usage = `usage:
  wakil secrets set <ref>
      Store a credential under <ref>. The value is read from stdin — at
      most one trailing newline is stripped — and is never accepted as a
      command-line argument.

  wakil secrets set-db <ref> --driver <mysql|mongo|sqlite> [flags]
      Compose a database DSN and store it under <ref>. The password is
      read from stdin, exactly as above.
        mysql, mongo:  --host H --port P --db D --user U
        mongo also:    [--auth-source S]  the database the user is defined
                       in; MongoDB defaults it to --db, which fails for a
                       user created in "admin"
        sqlite:        --db /absolute/path/to/file.db   (no password)

  wakil secrets set-api <ref> --auth <bearer|basic> [--user U]
      Compose an Authorization header VALUE and store it under <ref>,
      where an api entry's authRef points. The credential is read from
      stdin, exactly as above; --user is argv, because a user name is
      not a secret.
        bearer:  "Bearer " + the token        (no --user)
        basic:   "Basic " + base64(U + ":" + the password)
      --auth is required: a default that composed silently would be this
      command's own failure mode. A token that already carries its own
      scheme word, or that contains a space or tab, is refused rather
      than double-prefixed — store such a value with plain "secrets set",
      which stores exactly what it is given.

  wakil org create <org> [--display NAME] [--jira-base URL] [--default-provider ID]
      Register a new org under ~/.wakil/orgs/<org>. Refuses a duplicate.

  wakil org set <org> [--display NAME] [--jira-base URL] [--default-provider ID]
      Update fields on an existing org. A flag that is not given leaves
      that field unchanged.

  wakil org list
      List every registered org, one per line.

  wakil org rm <org> [--force]
      Delete an org's whole directory. Refused while the org still holds
      providers or projects unless --force is given. Never touches the
      Keychain: a credential outliving its org is recoverable, a deleted
      one is not.

  wakil provider add <id> --kind <claude-code|codex|local> [--config-dir DIR] [--label LABEL] [--share]
      Register a provider under the current org (--org, or WAKIL_ORG).
      --config-dir is required for --kind claude-code and rejected for
      --kind codex and --kind local, which Wakil does not register for
      you — see the command's own output for what to configure by hand.
      --share registers an account another org already homes, and applies
      to --kind claude-code only. Wakil can then run it under this org
      too; a plain claude session in that directory still runs as the
      homing org. A shared binding needs its OWN copy of the account's
      OAuth token under this org: wakil secrets set provider:<id> --org
      <org>, because the Keychain service name carries the org.

  wakil provider list
      List the current org's providers.

  wakil provider rm <id>
      Remove a provider record from the current org. Refused while this
      record homes a config dir other orgs still share, naming them:
      remove those bindings first.

  wakil provider config-dir <id>
      Print ONLY the provider's resolved configDir, with a trailing
      newline and nothing else, and exit 0. Exits 1 with a message on
      stderr for a provider whose kind has no configDir. For scripting
      (scripts/register-provider.sh), not for interactive use.

  wakil provider home <id>
      Print the org that pinned WAKIL_ORG inside this provider's config
      dir, one line on stdout and nothing else, and exit 0. Exits 1 with
      a message on stderr for a provider whose kind has no configDir, or
      whose configDir no org currently homes.

  wakil provider mint <id> [--config-dir DIR] [--claude-path PATH]
      Create a long-lived credential for this account and store it, both
      in one step. Opens a browser: you approve, and the credential is
      captured and written to the Keychain without ever being printed —
      not to a terminal, not to a transcript, not to Wakil. The config
      dir is derived from <id> when none is given.

      Prints one JSON line saying whether it was stored. Exits 0 only
      when it was; read the JSON rather than the exit status, because
      there is a third outcome — a credential that WAS created and could
      not be kept, which is printed once and recoverable never, and must
      be revoked in your Anthropic account rather than retried.

      This adds no capability the shell lacked: claude setup-token is
      the equal of the mint. What it collapses is the capture and the
      store into one step that cannot drop the token between them.

  wakil project add <name> --path /abs/path/to/project.json [--provider ID]
      Register a project in the current org's registry. Refuses a
      project.json whose declared org does not match the current org.

  wakil project list
      List the current org's projects.

  wakil project rm <name>
      Remove a project from the current org's registry. Does not touch
      the project.json file itself.

  Every subcommand above also accepts a global "--org <org>" (or
  "--org=<org>") anywhere in argv; it sets WAKIL_ORG for the rest of the
  command. "org create", "org set" and "org rm" take the org as their
  positional argument instead — the org being created, changed or removed
  is the subject of the command, and --org is for "provider" and
  "project", which act on the CURRENT org.`

// secretStore is the seam that keeps the test suite away from the real
// login Keychain. main passes wakilcore.SecretSet; every test passes a
// recorder. wakilcore.SecretSet shells out to `security
// add-generic-password` against the developer's own keychain, which can
// raise a GUI prompt and leaves a real item behind, so a test reaching it
// is a defect and not merely slow.
type secretStore func(ref, value string) error

// secretReader is the read-side seam, mirroring secretStore. It exists
// so `provider credentials` can be tested without a Keychain: the real
// binary passes wakilcore.SecretGet, and every test passes a fake or
// failingReader. Reads are seamed separately from writes because most
// subcommands need neither, and a subcommand that reads a secret when it
// should not is a leak rather than a mistake.
type secretReader func(ref string) (string, error)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, wakilcore.SecretSet, wakilcore.SecretGet))
}

// run is main's whole body with everything environmental — argv, stdin,
// stdout, stderr, and the Keychain writer — passed in, so the entire
// command is exercisable from a test without touching any of them.
//
// It first extracts a global "--org" flag from anywhere in argv (see
// applyOrgFlag) and then dispatches on the first remaining argument to one
// of four subcommand families: `secrets` (runSecrets, byte-for-byte the
// Phase 1 body of this function), `org` (orgcmd.go), `provider`
// (providercmd.go) and `project` (projectcmd.go). `org` and `project` never
// receive store or read: nothing about an org or project record touches
// the Keychain. `provider` receives read (but not store) because a later
// verb reads a stored credential back; see providercmd.go.
//
// stdout is threaded all the way down to `org list`, `provider list` and
// `project list` (runOrgList, runProviderList, runProjectList) — every
// subcommand whose whole job is printing rows a caller might parse;
// register-provider.sh is exactly such a caller for the first two.
// `runSecrets` does not take it: it prints no machine-consumable row.
//
// Exit codes: 2 for anything the operator can fix by retyping the command
// (bad subcommand, missing or malformed flag, unusable value), 1 for a
// failure that happened while doing the work (stdin read error, Keychain
// write error, a filesystem error while writing an org/provider/project
// record), 0 on success. Every subcommand in this package follows this
// contract.
func run(args []string, stdin io.Reader, stdout, stderr io.Writer, store secretStore, read secretReader) int {
	// 3a-iii: ssh calls `wakil` as its askpass with the prompt as the only argument; the host the
	// passphrase is for comes in WAKIL_ASKPASS_HOST. A subcommand by name still runs as itself.
	if host := os.Getenv("WAKIL_ASKPASS_HOST"); host != "" && len(args) == 1 && !isSubcommand(args[0]) {
		return runGitAskpass([]string{"--host", host}, stdout, stderr, read)
	}
	args, err := applyOrgFlag(args)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	switch args[0] {
	case "secrets":
		return runSecrets(args, stdin, stderr, store)
	case "org":
		return runOrg(args[1:], stdout, stderr)
	case "provider":
		return runProvider(args[1:], stdout, stderr, read)
	case "project":
		return runProject(args[1:], stdout, stderr)
	case "git-credential":
		return runGitCredential(args[1:], stdin, stdout, stderr, read, func(host string) (wakilcore.GitAccount, bool) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return wakilcore.GitAccount{}, false
			}
			return wakilcore.GitAccountFor(org, host)
		})
	case "git-askpass":
		return runGitAskpass(args[1:], stdout, stderr, read)
	default:
		fmt.Fprintln(stderr, message(wakilcore.UserError("unknown command\n\n"+usage)))
		return 2
	}
}

func isSubcommand(name string) bool {
	switch name {
	case "secrets", "org", "provider", "project", "git-credential", "git-askpass":
		return true
	}
	return false
}

// applyOrgFlag consumes a global "--org <name>" from anywhere in argv and
// puts it in the environment, so every downstream wakilcore call resolves
// the same way a registered server would.
//
// Setting the variable rather than threading a parameter keeps ONE org
// resolution path. A flag is safe here where a config file would not be:
// a human typing it IS the launcher, which is exactly what the security
// model requires the org to come from (design doc §3.3).
func applyOrgFlag(args []string) ([]string, error) {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--org":
			if i+1 >= len(args) {
				return nil, wakilcore.UserError("--org needs a value")
			}
			if err := os.Setenv("WAKIL_ORG", args[i+1]); err != nil {
				return nil, err
			}
			i++
		case strings.HasPrefix(args[i], "--org="):
			if err := os.Setenv("WAKIL_ORG", strings.TrimPrefix(args[i], "--org=")); err != nil {
				return nil, err
			}
		default:
			out = append(out, args[i])
		}
	}
	return out, nil
}

// runSecrets implements `wakil secrets set` and `wakil secrets set-db`. It
// is exactly run's Phase 1 body, moved here unchanged so that adding the
// org/provider/project dispatch above did not require touching a single
// line of the Keychain-writing path.
func runSecrets(args []string, stdin io.Reader, stderr io.Writer, store secretStore) int {
	// set-db is dispatched before parseSecretsSet is consulted, because
	// "secrets set-db" and "secrets set" differ only in args[1] and the
	// two take completely different argument shapes. parseSecretsSet
	// still rejects "set-db" on its own (it compares args[1] to "set"
	// exactly), so neither function depends on this ordering for
	// correctness — see TestParseSecretsSetRejectsSetDB.
	if len(args) >= 2 && args[0] == "secrets" && args[1] == "set-db" {
		return runSetDB(args, stdin, stderr, store)
	}
	// set-api is dispatched on exactly the same terms as set-db, one line
	// above: its argument shape is its own, and parseSecretsSet compares
	// args[1] to "set" exactly, so neither depends on this ordering.
	if len(args) >= 2 && args[0] == "secrets" && args[1] == "set-api" {
		return runSetAPI(args, stdin, stderr, store)
	}

	ref, err := parseSecretsSet(args)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	org, err := wakilcore.CurrentOrgChecked()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	fmt.Fprintf(stderr, "Paste the secret for %q in org %q, then press Ctrl-D:\n", ref, org)
	value, err := readSecretValue(stdin)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}
	if err := store(ref, value); err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}
	fmt.Fprintf(stderr, "stored %q in the keychain for org %q.\n", ref, org)
	return 0
}

// runSetDB implements `wakil secrets set-db`: it composes a DSN from
// non-secret connection parameters plus a password read from stdin, and
// stores the whole DSN under ref. The composed DSN is never printed — it
// contains the password.
func runSetDB(args []string, stdin io.Reader, stderr io.Writer, store secretStore) int {
	ref, target, err := parseSecretsSetDB(args)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	org, err := wakilcore.CurrentOrgChecked()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	// sqlite reads no password at all. A SQLite "connection" is a
	// filesystem path — the engine has no user or password concept, and
	// wakilcore's sqlite driver passes the stored string straight to
	// sqliteReadOnlyDSN as a path. Prompting for a password here would
	// either force the operator to invent one or, worse, make the
	// empty-value rejection in readSecretValue fire on a perfectly
	// well-formed sqlite registration.
	var password string
	if target.Driver != driverSQLite {
		fmt.Fprintf(stderr, "Paste the %s password for user %q in org %q, then press Ctrl-D:\n", target.Driver, target.User, org)
		password, err = readSecretValue(stdin)
		if err != nil {
			fmt.Fprintln(stderr, message(err))
			return 1
		}
	}

	dsn, err := composeDBDSN(target, password)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if err := store(ref, dsn); err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}
	fmt.Fprintf(stderr, "stored a %s DSN for database %q under %q in the keychain for org %q.\n", target.Driver, target.DB, ref, org)
	return 0
}

// message renders err for a human.
//
// A wakilcore.UserError is a message someone in this codebase wrote for an
// operator to read, and everything this command produces today is one:
// every rejection here is a UserError, readSecretValue wraps its io error
// in one, and wakilcore.SecretSet's failure is one too. So the first
// branch is the only one that runs in practice.
//
// The second branch is not a fallback that prints the same thing — it
// LABELS the message as unclassified. That distinction is the reason this
// function exists at all: an unclassified error reaching an operator's
// terminal from this command is a bug worth seeing, because the errors
// this command must never print verbatim live exactly there.
// mysql.ParseDSN's messages, for instance, quote whichever fragment of
// the DSN they choked on (see composeMySQLDSN), and any future code path
// that returns a driver's raw error instead of a curated one would
// otherwise blend in with the curated ones. The prefix is what makes it stand out; the
// underlying text is still shown, because withholding it would leave a
// real failure undiagnosable.
//
// TestMessageLabelsUnclassifiedErrors pins both branches. Deleting the
// first one is not a no-op: every curated message would gain the prefix.
func message(err error) string {
	if msg, ok := wakilcore.IsUserError(err); ok {
		return msg
	}
	return "unexpected error (not an operator-facing message, so it may quote internals): " + err.Error()
}

// regExitCode maps an error from an org/provider/project registry call
// (orgcmd.go, providercmd.go, projectcmd.go) to this command's exit-code
// contract. Every rejection wakilcore's org/provider/project functions
// raise on purpose — an unregistered org, a duplicate id, a bad kind, a
// bad Jira base — is a wakilcore.UserError, and every one of those is
// something the operator can fix by retyping the command, so it gets 2.
// Anything else reaching this function is a filesystem failure that
// happened while doing the work (a MkdirAll or file write that failed),
// which is 1 by the same contract run's doc comment states.
func regExitCode(err error) int {
	if _, ok := wakilcore.IsUserError(err); ok {
		return 2
	}
	return 1
}

// ---------------------------------------------------------------------
// ref validation
// ---------------------------------------------------------------------

// refPattern is the accepted syntax for a Keychain ref. Nothing else in
// the codebase validates a ref: config.go's Database.Ref and
// ApiConfig.AuthRef are plain strings read straight out of project.json,
// and wakilcore.SecretGet takes whatever it is handed. This is therefore
// the first and currently only gate, and it deliberately covers only the
// WRITE side — a ref that arrives from a project.json is still unchecked,
// which is a real gap but one that belongs to wakilcore, not to this
// command.
//
// On why a leading "-" is not an option-confusion hole today: secrets.go's
// keychainService prefixes EVERY ref with "wakil:<org>:" before it reaches
// `security`, so the string that becomes the `-s` argument can never begin
// with "-" no matter what the ref is. That was verified against
// secrets.go, not assumed. The org sitting between the two is validated
// there too, so it cannot reintroduce a leading "-" either. Two further layers sit under it: the ref is
// always the VALUE of `-s` (getopt consumes the next argv element even if
// it starts with "-"), and exec.Command runs `security` directly with no
// shell, so shell metacharacters have nothing to interpret them. This
// pattern is the outermost of the three. If the "wakil:" prefix is ever
// removed as a "simplification", option confusion becomes live again and
// this pattern is what keeps it closed — do not delete both.
//
// This pattern also permits ":" inside a ref, which is what makes
// keychainService's ban on ":" inside an ORG load-bearing: if both halves
// of "wakil:<org>:<ref>" could contain a colon, two different org/ref
// pairs could name one credential. See keychainService's doc comment.
var refPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]*$`)

const refRule = "a ref must match ^[A-Za-z0-9][A-Za-z0-9._:-]*$ — it starts with a letter or digit, then contains only letters, digits, dots, underscores, colons and hyphens"

func validateRef(ref string) error {
	if ref == "" {
		return wakilcore.UserError("ref must not be empty — " + refRule)
	}
	if !refPattern.MatchString(ref) {
		return wakilcore.UserError("invalid ref " + strconv.Quote(ref) + " — " + refRule)
	}
	return nil
}

// ---------------------------------------------------------------------
// `secrets set`
// ---------------------------------------------------------------------

// parseSecretsSet extracts the ref from `wakil secrets set <ref>`, given
// os.Args[1:].
//
// Trailing arguments are REJECTED rather than ignored. `wakil secrets set
// myref hunter2` is overwhelmingly likely to be an operator trying to pass
// the value on the command line; silently ignoring the extra word would
// read the value from stdin instead (blocking on a terminal, or reading
// whatever the surrounding script happened to pipe in) while the operator
// believes the argument was used. Both outcomes are worse than an error.
func parseSecretsSet(args []string) (string, error) {
	if len(args) < 2 || args[0] != "secrets" || args[1] != "set" {
		return "", wakilcore.UserError("unknown command\n\n" + usage)
	}
	if len(args) < 3 {
		return "", wakilcore.UserError("missing <ref>\n\n" + usage)
	}
	if len(args) > 3 {
		return "", wakilcore.UserError("too many arguments — the secret value is read from stdin, never from the command line (an argv token lands in your shell history and is readable by any local process via `ps -ww`)\n\n" + usage)
	}
	if err := validateRef(args[2]); err != nil {
		return "", err
	}
	return args[2], nil
}

// ---------------------------------------------------------------------
// reading the secret value
// ---------------------------------------------------------------------

// readSecretValue reads a whole secret value from r.
//
// The read error is CHECKED. That is the entire point of this function
// existing rather than the obvious two-liner: a discarded read error
// yields an empty string, and an empty string that is not itself rejected
// gets written to the Keychain as a real, empty credential while the
// command prints "stored". The operator then believes the credential is
// in place and finds out otherwise at the far end of an MCP call, with no
// hint that the write, not the read, is what failed.
//
// Exactly ONE trailing line terminator is stripped ("\r\n" or "\n"), never
// more. `printf 'pw\n' | wakil secrets set x` must store "pw", but a value
// that legitimately ends in a newline — pipe it with a second one — must
// keep it. strings.TrimRight(s, "\r\n") would eat every trailing newline
// and silently corrupt such a value.
//
// Interior newlines are preserved: a multi-line credential (a PEM private
// key, for instance) is a legitimate thing to store here.
//
// Nothing else is trimmed. Leading and trailing spaces and tabs are part
// of the value, because they can be part of a real password. Whitespace is
// only ever used to DECIDE emptiness, never to rewrite the value.
func readSecretValue(r io.Reader) (string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return "", wakilcore.UserError("could not read the secret value from stdin: " + err.Error())
	}
	s := string(data)
	// EVERY trailing line ending is removed, not one.
	//
	// This used to strip exactly one, to let a secret whose own last byte is
	// a newline (a PEM key, per this command's help text) survive the round
	// trip. Measured on 2026-09-11, that intention does not survive contact
	// with the Keychain: `security find-generic-password -w` prints a value
	// ending in a newline as lowercase HEX rather than as its bytes, with no
	// marker, so such a secret was never actually round-tripping — it was
	// coming back as 224 characters of hex and failing at first use with a
	// 401 that pointed nowhere near the paste that caused it.
	//
	// The realistic input is the reason this is not a corner case. An
	// operator pastes a token copied from `claude setup-token`, whose output
	// already ends in a newline, then presses Enter, then Ctrl-D. That is two
	// newlines; stripping one left one, and one was enough. Nothing about
	// that sequence is a mistake, so the tool absorbs it.
	//
	// What this costs: a secret that genuinely must end in a newline can no
	// longer be stored through this command. Nothing does — a PEM parser
	// accepts a key with or without its terminator — and the alternative is
	// a value that stores cleanly, reads back cleanly, and is silently wrong.
	// `SecretGet`'s decodeKeychainHex repairs items already written the old
	// way, so this change fixes new writes and that one fixes old ones.
	s = strings.TrimRight(s, "\r\n")

	// An all-whitespace value is treated as empty. The realistic way to
	// reach it is an operator pressing Enter twice at the prompt, which
	// leaves "\n" after the single-newline strip above — non-empty by
	// string comparison, and worthless as a credential. Rejecting it
	// costs the ability to store a credential made entirely of spaces,
	// which no real system issues, and buys the guarantee that "stored"
	// is never printed over a blank secret.
	if strings.TrimSpace(s) == "" {
		return "", wakilcore.UserError("no secret value on stdin — nothing was stored; pipe the value in, e.g. printf %s 'the-value' | wakil secrets set <ref>")
	}

	// A NUL cannot survive the trip to the Keychain: wakilcore.SecretSet
	// hands the value to `security` as an argv token, and argv is
	// NUL-terminated, so exec.Command rejects the argument outright.
	// Saying so here turns an opaque "invalid argument" from os/exec
	// into an instruction the operator can act on.
	if strings.ContainsRune(s, 0) {
		return "", wakilcore.UserError("the secret value contains a NUL byte, which cannot be passed through the `security` command's argument list — nothing was stored")
	}
	return s, nil
}

// ---------------------------------------------------------------------
// `secrets set-db`
// ---------------------------------------------------------------------

const (
	driverMySQL  = "mysql"
	driverMongo  = "mongo"
	driverSQLite = "sqlite"
)

// dbTarget holds the NON-SECRET half of a database connection: everything
// the operator can safely type on the command line. The password is kept
// out of this struct on purpose so that a future `%+v` on it cannot leak
// one.
type dbTarget struct {
	Driver string
	Host   string
	Port   string
	DB     string
	User   string
	// AuthSource is mongo-only and optional: the database the user is
	// DEFINED in, which is not always the database being read. See
	// composeMongoDSN for why leaving it empty is a live failure mode.
	AuthSource string
}

// parseSecretsSetDB parses `wakil secrets set-db <ref> --driver ... [flags]`
// from os.Args[1:]. It checks only the SHAPE of the invocation — which
// flags are present, and whether they apply to the chosen driver. The
// content of each value is validated by composeDBDSN, so that the composer
// is safe to call on its own and is fully covered by its own tests.
func parseSecretsSetDB(args []string) (string, dbTarget, error) {
	if len(args) < 2 || args[0] != "secrets" || args[1] != "set-db" {
		return "", dbTarget{}, wakilcore.UserError("unknown command\n\n" + usage)
	}
	if len(args) < 3 {
		return "", dbTarget{}, wakilcore.UserError("missing <ref>\n\n" + usage)
	}
	ref := args[2]
	if err := validateRef(ref); err != nil {
		return "", dbTarget{}, err
	}

	var t dbTarget
	fs := flag.NewFlagSet("secrets set-db", flag.ContinueOnError)
	// The flag package writes its own message to output and then the
	// caller writes the returned error too, which double-prints. Discard
	// its output and surface the error ourselves so there is exactly one
	// error path in this command.
	fs.SetOutput(io.Discard)
	fs.StringVar(&t.Driver, "driver", "", "mysql, mongo or sqlite")
	fs.StringVar(&t.Host, "host", "", "database host")
	fs.StringVar(&t.Port, "port", "", "database port")
	fs.StringVar(&t.DB, "db", "", "database name, or the absolute file path for sqlite")
	fs.StringVar(&t.User, "user", "", "database user")
	fs.StringVar(&t.AuthSource, "auth-source", "", "mongo only: the database --user is defined in (default: --db)")
	if err := fs.Parse(args[3:]); err != nil {
		return "", dbTarget{}, wakilcore.UserError("bad flags for `wakil secrets set-db`: " + err.Error() + "\n\n" + usage)
	}
	if fs.NArg() > 0 {
		return "", dbTarget{}, wakilcore.UserError("unexpected argument " + strconv.Quote(fs.Arg(0)) + " — the password is read from stdin, never from the command line\n\n" + usage)
	}

	switch t.Driver {
	case "":
		return "", dbTarget{}, wakilcore.UserError("missing required flag --driver (mysql, mongo or sqlite)\n\n" + usage)
	case driverMySQL, driverMongo:
		for _, req := range []struct{ name, value string }{
			{"--host", t.Host},
			{"--port", t.Port},
			{"--db", t.DB},
			{"--user", t.User},
		} {
			if req.value == "" {
				return "", dbTarget{}, wakilcore.UserError("missing required flag " + req.name + " for --driver " + t.Driver + "\n\n" + usage)
			}
		}
		// --auth-source is a mongodb:// URI option with no equivalent in
		// a go-sql-driver DSN: MySQL has no notion of a database a user
		// is "defined in". Accepting it for mysql and dropping it would
		// let an operator believe they had scoped authentication.
		if t.Driver == driverMySQL && t.AuthSource != "" {
			return "", dbTarget{}, wakilcore.UserError("flag --auth-source does not apply to --driver mysql — it is a mongodb URI option, and MySQL has no separate authentication database\n\n" + usage)
		}
	case driverSQLite:
		// See runSetDB: a SQLite connection is a file path, so these
		// flags have nothing to bind to. Accepting and ignoring them
		// would let an operator believe they had configured a
		// networked, authenticated sqlite connection.
		for _, na := range []struct{ name, value string }{
			{"--host", t.Host},
			{"--port", t.Port},
			{"--user", t.User},
			{"--auth-source", t.AuthSource},
		} {
			if na.value != "" {
				return "", dbTarget{}, wakilcore.UserError("flag " + na.name + " does not apply to --driver sqlite — a sqlite connection is a file path, with no host, port, user, password or authentication database\n\n" + usage)
			}
		}
		if t.DB == "" {
			return "", dbTarget{}, wakilcore.UserError("missing required flag --db for --driver sqlite (the absolute path to the database file)\n\n" + usage)
		}
	default:
		return "", dbTarget{}, wakilcore.UserError("unknown --driver " + strconv.Quote(t.Driver) + " — supported drivers are mysql, mongo and sqlite")
	}
	return ref, t, nil
}

// hostNamePattern accepts a hostname or IPv4 literal (letters, digits,
// dots, dashes, underscores). The set is deliberately narrow: a composed
// DSN's structure is delimited by exactly the characters excluded here.
// go-sql-driver/mysql's DSN puts the address inside "tcp(...)", so a ")"
// in the host would truncate it; "@" and "/" are the user/address and
// address/dbname separators in the same format; and in a mongodb:// URI
// the host is the URL authority, so "/", "?", "#" and "@" all terminate
// it. Square brackets are excluded because net.JoinHostPort adds them for
// an IPv6 literal itself.
//
// It does NOT cover IPv6 — see checkHost.
var hostNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// dbNamePattern is the accepted database (not file) name. MySQL and Mongo
// both permit more than this, but every extra character is one that has to
// survive a DSN round trip — and Mongo additionally forbids "/", "\", ".",
// '"', "$", "*", "<", ">", ":", "|" and "?" in a database name outright.
// One conservative rule shared by both drivers is easier to be sure of
// than two permissive ones.
var dbNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// composeDBDSN builds the DSN that gets stored in the Keychain. It is pure
// (no environment, no filesystem, no network) so the composition itself
// can be pinned by unit tests rather than inferred from a live connection.
//
// It is safe to call on its own: it validates every field it is given
// rather than assuming parseSecretsSetDB has been there first, and each
// driver's round-trip backstop catches what the field checks cannot state
// in advance — including a dbTarget with an empty User, which both the
// mysql and the mongo formats turn into a credential-less DSN rather than
// an error (see each composer for the measurement).
//
// No error returned from here — or from anything it calls — may contain
// the password or the composed DSN. Callers print these messages straight
// to the operator's terminal, and driver_mysql.go already had to strip an
// error path for the same reason: mysql.ParseDSN's messages quote
// fragments of the DSN they choked on, and which fragment that is, is the
// driver's choice rather than ours.
func composeDBDSN(t dbTarget, password string) (string, error) {
	switch t.Driver {
	case driverMySQL:
		return composeMySQLDSN(t, password)
	case driverMongo:
		return composeMongoDSN(t, password)
	case driverSQLite:
		return composeSQLiteDSN(t)
	default:
		// Unreachable through parseSecretsSetDB, which rejects an
		// unknown driver first. Kept because this function is also
		// called directly by its own tests and is the piece another
		// command would reuse.
		return "", wakilcore.UserError("unknown driver " + strconv.Quote(t.Driver) + " — supported drivers are mysql, mongo and sqlite")
	}
}

// composeMySQLDSN builds a go-sql-driver/mysql DSN.
//
// The password is written VERBATIM, not percent-encoded, because that
// format is not a URL. mysql.ParseDSN (dsn.go, v1.10.1) takes the password
// as the raw bytes between the first ":" and the last "@" before the last
// "/", with no unescaping of any kind; only the dbname is url-unescaped.
// Percent-encoding the password here would therefore make the driver
// authenticate with the literal text "p%40ss" instead of "p@ss". All six
// of "@ / : ? # %" round-trip exactly as literals — see
// TestComposeMySQLDSNPasswordRoundTrip, which re-measures that against the
// real parser on every run rather than trusting this paragraph.
//
// The username is a different story and is checked below: ParseDSN splits
// on the FIRST ":" in the userinfo, so a username containing one is not
// representable in this format at all.
//
// Read-only marker: transaction_read_only=1 is set here, matching what
// wakilcore's mysql driver does. That driver re-applies it on every
// Connect regardless of what the stored DSN says (driver_mysql.go sets
// cfg.Params["transaction_read_only"] after parsing, so it survives a DSN
// that omits it), so this copy is not the enforcement — it makes the
// stored credential state its own read-only intent for anyone who later
// inspects the Keychain item.
func composeMySQLDSN(t dbTarget, password string) (string, error) {
	if err := checkHostPort(t); err != nil {
		return "", err
	}
	if !dbNamePattern.MatchString(t.DB) {
		return "", wakilcore.UserError("invalid --db " + strconv.Quote(t.DB) + " — a database name may contain only letters, digits, underscores and hyphens")
	}
	if err := checkPrintable("--user", t.User); err != nil {
		return "", err
	}
	if strings.Contains(t.User, ":") {
		return "", wakilcore.UserError("invalid --user: a mysql username containing \":\" cannot be expressed in a go-sql-driver DSN — the driver splits the username from the password at the first colon, so the credential would be silently mangled")
	}
	if err := checkPrintable("password", password); err != nil {
		return "", err
	}

	cfg := mysql.NewConfig()
	cfg.User = t.User
	cfg.Passwd = password
	cfg.Net = "tcp"
	cfg.Addr = net.JoinHostPort(t.Host, t.Port)
	cfg.DBName = t.DB
	cfg.Params = map[string]string{"transaction_read_only": "1"}
	dsn := cfg.FormatDSN()

	// Round-trip backstop. FormatDSN is not injective over arbitrary
	// input (the username case above is a live example), and the checks
	// above are a denylist, which is the weaker kind of guard. Parsing
	// the result back with the driver's own parser and comparing every
	// field turns "I believe these characters are safe" into "this
	// specific DSN demonstrably reads back as what I put in". A failure
	// here means the value would have been stored wrong, so it must be
	// an error and not a warning.
	//
	// The live case today is an EMPTY username. FormatDSN writes the
	// password only inside the "user[:password]@" group and omits the
	// whole group when User is "" (dsn.go, v1.10.1), so a target with no
	// user silently drops the password and produces a
	// credential-less DSN — "stored", and then a permission error at the
	// far end of an MCP call. parseSecretsSetDB requires --user, so this
	// is unreachable from the CLI; composeDBDSN is documented as safe to
	// call on its own, and this is what makes that true.
	// TestComposeMySQLDSNBackstopCatchesEmptyUser measures the drop
	// against the real FormatDSN rather than trusting this paragraph.
	if !mysqlDSNRoundTrips(dsn, cfg) {
		// The underlying parse error is deliberately dropped rather
		// than reported. mysql.ParseDSN quotes fragments of the DSN it
		// choked on — "invalid dbname %q", "invalid bool value:
		// <value>" — and although no error in v1.10.1 can carry the
		// userinfo (checked against the module source), which fragment
		// surfaces is the driver's choice and this string holds a
		// password. Nothing is lost by dropping it: the composer built
		// the DSN, so the fault is in the field values, and those are
		// what the message names.
		return "", wakilcore.UserError("could not compose a mysql DSN that reads back unchanged — the composed DSN does not parse back to the values given (an empty --user, or a character this DSN format cannot carry); nothing was stored")
	}
	return dsn, nil
}

// mysqlDSNRoundTrips reports whether dsn parses back, with the driver's
// own parser, to exactly the connection cfg describes.
//
// It is a separate function so that every field it compares can be
// exercised directly. With the denylist in composeMySQLDSN in force, the
// only input that reaches this check and fails it is an empty username —
// and that shows up in Passwd (see composeMySQLDSN) — so a test driven
// only through the composer could not tell a missing Addr or DBName
// comparison from a present one. The comparison is not there for today's
// reachable inputs: it is there for a DSN format that changes under us
// and for the next field someone sets on cfg.
//
// The read-only marker is compared against cfg rather than against the
// literal "1", so this stays a round-trip predicate and nothing else;
// that the marker is set at all is pinned by
// TestComposeMySQLDSNCarriesReadOnlyMarker.
func mysqlDSNRoundTrips(dsn string, cfg *mysql.Config) bool {
	back, err := mysql.ParseDSN(dsn)
	return err == nil &&
		back.User == cfg.User &&
		back.Passwd == cfg.Passwd &&
		back.Net == cfg.Net &&
		back.Addr == cfg.Addr &&
		back.DBName == cfg.DBName &&
		back.Params["transaction_read_only"] == cfg.Params["transaction_read_only"]
}

// composeMongoDSN builds a mongodb:// URI.
//
// Here percent-encoding IS required and is the whole job: a mongodb URI is
// a URL, its userinfo is parsed as URL userinfo, and an unescaped "@", "/",
// ":", "?", "#" or "%" in the username or password would either terminate
// the userinfo early or be misread. url.UserPassword plus url.URL.String()
// escape all six (Go escapes "@", "/", "?" and ":" as reserved characters
// in userinfo, and "#" and "%" fall through to its escape-everything-else
// branch), and both net/url and the Mongo driver's own connection-string
// parser decode them back — TestComposeMongoDSNPasswordRoundTrip measures
// that rather than asserting it.
//
// Read-only marker: there is none, and that is not an oversight. MongoDB
// has no connection-level read-only mode — no URI option, session flag or
// client setting makes a *mongo.Client refuse a write. driver_mongo.go's
// Connect says the same thing at length. The only real guarantee is
// operational: the user named in --user must hold just the built-in "read"
// (or "readAnyDatabase") role on this database. That requirement is
// recorded for the operator in docs/wakil/operator-todo.md §2; keep the
// two in step.
//
// authSource: when the URI carries a path (the database) and no
// authSource option, the driver authenticates against THAT database —
// measured, options.Client().ApplyURI("mongodb://u:p@h:1/app").Auth
// .AuthSource == "app". A least-privilege reader is usually created in
// "admin" and granted read on the target database, and for that user the
// default is simply wrong: authentication fails against a database the
// user is not defined in. --auth-source is how the operator says where
// the user lives; it is stored as an explicit authSource option, so the
// stored credential does not depend on that default at all.
func composeMongoDSN(t dbTarget, password string) (string, error) {
	if err := checkHostPort(t); err != nil {
		return "", err
	}
	if !dbNamePattern.MatchString(t.DB) {
		return "", wakilcore.UserError("invalid --db " + strconv.Quote(t.DB) + " — a database name may contain only letters, digits, underscores and hyphens")
	}
	// The same rule as --db, because an authSource IS a database name.
	// It excludes MongoDB's "$external" (X.509/LDAP/Kerberos auth), which
	// this composer does not support: it always writes a username and
	// password into the URI, and an $external user does not authenticate
	// with one. Such a connection has to be pasted whole with
	// `wakil secrets set`.
	if t.AuthSource != "" && !dbNamePattern.MatchString(t.AuthSource) {
		return "", wakilcore.UserError("invalid --auth-source " + strconv.Quote(t.AuthSource) + " — an authentication database name may contain only letters, digits, underscores and hyphens")
	}
	if err := checkPrintable("--user", t.User); err != nil {
		return "", err
	}
	if err := checkPrintable("password", password); err != nil {
		return "", err
	}

	u := url.URL{
		Scheme: "mongodb",
		User:   url.UserPassword(t.User, password),
		Host:   net.JoinHostPort(t.Host, t.Port),
		Path:   "/" + t.DB,
	}
	// authSource is the only option written here, so the query is built
	// from url.Values rather than concatenated: an "&" or "=" arriving in
	// a future option would otherwise re-delimit the query silently.
	wantAuthSource := t.DB
	if t.AuthSource != "" {
		u.RawQuery = url.Values{"authSource": {t.AuthSource}}.Encode()
		wantAuthSource = t.AuthSource
	}
	dsn := u.String()

	// Same round-trip backstop as mysql, and for the same reason. The
	// path check mirrors wakilcore's databaseFromURI, which is what
	// actually extracts the database name at connect time.
	//
	if !mongoURIRoundTrips(dsn, u.Host, t, password) {
		return "", wakilcore.UserError("could not compose a mongodb URI that reads back unchanged — one of the host, port, database, user, password or auth source contains a character this URI cannot carry; nothing was stored")
	}

	// net/url is not the consumer. The Mongo driver is, and it reads this
	// URI with its own connection-string parser, which does not agree
	// with net/url about what counts as a credential: for an empty
	// username, "mongodb://:hunter2@m.internal:27017/app" round-trips
	// through net/url perfectly (username "", password "hunter2") while
	// ApplyURI(...).Auth comes back NIL — no credentials at all. Stored,
	// "stored" printed, and the connection then fails as unauthenticated
	// with nothing in the configuration to point at. So the backstop asks
	// the parser that will actually read this string.
	//
	// ApplyURI parses only; it opens no connection and does no DNS, so
	// this keeps composeDBDSN pure. AuthSource is checked here rather
	// than above because it is the driver, not the URI text, that applies
	// the "defaults to the path database" rule this flag exists to pin.
	if !mongoDriverReadsBack(dsn, t.User, password, wantAuthSource) {
		return "", wakilcore.UserError("could not compose a mongodb URI the mongo driver reads back unchanged — an empty --user, or a character the driver's connection-string parser does not carry the way net/url does; nothing was stored")
	}
	return dsn, nil
}

// mongoURIRoundTrips reports whether dsn parses back through net/url to
// exactly the authority, credentials, database and authSource it was
// built from. wantHost is the composed authority (host plus port, IPv6
// bracketed by net.JoinHostPort).
//
// Split out for the same reason as mysqlDSNRoundTrips: with
// composeMongoDSN's field checks in force there is no input that reaches
// this and fails it, so driving it through the composer could not tell
// any one of these comparisons from a missing one. See
// TestMongoURIRoundTripsComparesEveryField.
//
// back.User is not nil-checked. url.Userinfo's Username and Password are
// both nil-safe (they return "" and "", false), so a URI with no
// userinfo at all fails these comparisons anyway: either the username
// differs, or — for an empty user — hasPassword is false. A nil check
// would be a branch no input can distinguish.
func mongoURIRoundTrips(dsn, wantHost string, t dbTarget, password string) bool {
	back, err := url.Parse(dsn)
	if err != nil {
		return false
	}
	gotPassword, hasPassword := back.User.Password()
	return back.User.Username() == t.User &&
		hasPassword && gotPassword == password &&
		back.Host == wantHost &&
		strings.TrimPrefix(back.Path, "/") == t.DB &&
		back.Query().Get("authSource") == t.AuthSource
}

// mongoDriverReadsBack asks the parser that will actually open this
// connection — the Mongo driver's own connection-string handling — what
// credentials the URI carries. ApplyURI parses only: it opens no
// connection and does no DNS, so composeDBDSN stays pure.
//
// This is not a duplicate of mongoURIRoundTrips. The two parsers disagree
// about what counts as a credential, and the disagreement is reachable:
// see composeMongoDSN's comment and
// TestComposeMongoDSNBackstopCatchesEmptyUser.
func mongoDriverReadsBack(dsn, user, password, authSource string) bool {
	auth := options.Client().ApplyURI(dsn).Auth
	return auth != nil &&
		auth.Username == user &&
		auth.Password == password &&
		auth.AuthSource == authSource
}

// composeSQLiteDSN builds a "file:" URI for a local SQLite database.
//
// The path must be ABSOLUTE. A relative path stored in the Keychain is
// resolved against whatever working directory the MCP server process
// happened to be started in, which is not something the operator controls
// or can predict — Claude launches these servers, not the operator's
// shell. The resulting "unable to open database file" would point at a
// path that does not appear anywhere in the configuration.
//
// Read-only marker: mode=ro, the SQLite-native form
// wakilcore.sqliteReadOnlyDSN uses. As with mysql, that function applies
// mode=ro unconditionally on every Connect (overriding any mode already
// present), so this copy is documentation of intent on the stored item
// rather than the thing that enforces read-only.
func composeSQLiteDSN(t dbTarget) (string, error) {
	if err := checkPrintable("--db", t.DB); err != nil {
		return "", err
	}
	if !filepath.IsAbs(t.DB) {
		return "", wakilcore.UserError("invalid --db " + strconv.Quote(t.DB) + " — the sqlite database path must be absolute, because it is resolved in whichever working directory the MCP server happens to start in")
	}

	// url.URL percent-encodes everything in the path that is meaningful
	// in a URI, including "?" and "#", so appending the query below can
	// never be swallowed by a character inside the path. OmitHost keeps
	// this a "file:/abs/path" URI rather than "file:///abs/path" or, for
	// a path that is not rooted, an accidental authority.
	u := url.URL{Scheme: "file", OmitHost: true, Path: t.DB}
	dsn := u.String() + "?mode=ro"

	// Structural backstop, deliberately conservative and deliberately
	// NOT the consumer's parser. modernc.org/sqlite splits a DSN at the
	// first "?" and has no concept of a fragment (driver_sqlite.go
	// explains why at length), so net/url and the engine do not agree on
	// every string. Rather than guess which way they diverge, this
	// refuses to store any DSN whose path does not come back out of
	// net/url intact — a path this composer cannot reason about is not
	// one it should be writing into the Keychain. It is reachable:
	// "//a/b.db" is absolute, so it passes the check above, but
	// url.URL.String() renders a double-slashed path as the opaque
	// "file:%2F/a/b.db" to stop it reading as an authority, and that has
	// no Path at all when parsed back.
	//
	// That the DSNs it ACCEPTS open the intended file is proved
	// separately, against the real driver, by
	// TestComposeSQLiteDSNOpensTheIntendedFile.
	back, err := url.Parse(dsn)
	if err != nil || back.Path != t.DB || back.Query().Get("mode") != "ro" {
		return "", wakilcore.UserError("could not compose a sqlite DSN that reads back unchanged; nothing was stored")
	}
	return dsn, nil
}

// checkHostPort validates the two fields shared by the networked drivers.
func checkHostPort(t dbTarget) error {
	if err := checkHost(t.Host); err != nil {
		return err
	}
	// The port is validated as a NUMBER but composed as the STRING the
	// operator typed (net.JoinHostPort below takes t.Port untouched), so
	// the two forms have to be the same text or the guard is being
	// applied to something other than what gets stored. strconv.Atoi
	// alone is not that guard: it accepts a leading "+" and leading
	// zeros, so "+3306" and "0065" both pass a range check and then
	// compose "tcp(h:+3306)" and "h:0065" — stored, and rejected only at
	// dial time with an opaque error, long after the operator has left.
	// Round-tripping through strconv.Itoa is the whole check: it passes
	// exactly the canonical decimal forms.
	port, err := strconv.Atoi(t.Port)
	if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != t.Port {
		return wakilcore.UserError("invalid --port " + strconv.Quote(t.Port) + " — expected a plain decimal number between 1 and 65535, with no sign and no leading zeros")
	}
	return nil
}

// checkHost accepts a hostname, an IPv4 literal, or a bare IPv6 literal.
//
// IPv6 is checked with net.ParseIP rather than a character-class regex.
// The character-class form this replaced was `[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*`,
// with a "*" on BOTH sides of the colon, so it matched ":", "..:.." and
// ":::::" — none of which is an address. Those are not harmless: for
// mysql, net.JoinHostPort brackets anything containing a colon and
// mysql.ParseDSN happily round-trips the result, so `--host :::::` was
// composed, backstopped and STORED as "tcp([:::::]:3306)", to fail at
// dial time with an opaque error. Writing a correct IPv6 grammar as a
// regex (compressed "::", embedded IPv4 tails, the 8-group limit) is a
// job for a parser, and the standard library already has the one every
// consumer of this DSN will use.
//
// net.ParseIP also accepts IPv4, which hostNamePattern already covers;
// the overlap is harmless. It rejects a zone suffix ("fe80::1%en0"),
// which is the right answer here — the "%" would have to be
// percent-escaped in a mongodb:// URI and is not carried by the mysql
// address format at all.
func checkHost(host string) error {
	if hostNamePattern.MatchString(host) {
		return nil
	}
	if net.ParseIP(host) != nil {
		return nil
	}
	return wakilcore.UserError("invalid --host " + strconv.Quote(host) + " — expected a hostname, an IPv4 address, or a bare IPv6 address (no brackets)")
}

// checkPrintable rejects control characters, which includes NUL and any
// newline. readSecretValue already rejects a NUL in a value read from
// stdin, but composeDBDSN is a pure function callable on its own, and a
// control character anywhere in a DSN is a corruption either way: a
// newline would split the stored credential across lines, and a NUL cannot
// pass through exec's argv at all. `name` is the flag as the operator
// typed it, or the word "password" — never the value, which for the
// password case must not be echoed.
func checkPrintable(name, value string) error {
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return wakilcore.UserError("the " + name + " value contains a control character (" + strconv.QuoteRune(r) + "), which cannot be carried in a connection string; nothing was stored")
		}
	}
	return nil
}
