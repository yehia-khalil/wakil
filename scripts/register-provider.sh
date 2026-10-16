#!/usr/bin/env bash
#
# Register the Wakil MCP servers for one org's provider into that
# provider's own Claude config dir.
#
#   scripts/register-provider.sh <org> <provider-id> /abs/path/to/bin
#
# Run it once per (org, provider) pair: every claude-code account that
# should run Wakil for a given org gets its own invocation. It mutates the
# Claude configuration under the provider's recorded configDir, so it is
# an operator step, not something an agent should run.
#
# ---------------------------------------------------------------------
# Why every `claude mcp add` below carries -e WAKIL_ORG and -e WAKIL_PROVIDER
# ---------------------------------------------------------------------
# Org identity is now DECLARED, not derived: wakilcore.CurrentOrg()
# (internal/wakilcore/paths.go) reads WAKIL_ORG and nothing else. Left
# ambient, an unset or stale WAKIL_ORG in whatever environment eventually
# launches a registered server would resolve to a DIFFERENT org than the
# one this script just wired up — and because the org id selects the Jira
# Keychain ref ("jira:<org>", see NewJiraFromEnv), the failure mode is a
# cross-org credential lookup with no error anywhere. Pinning WAKIL_ORG at
# registration time, on every one of the six servers, is what stops a
# server launched by Claude from ever inheriting a stale value.
#
# WAKIL_PROVIDER is pinned for a different, lower-stakes reason.
# wakilcore.CurrentProvider() (internal/wakilcore/provider.go) reads
# WAKIL_PROVIDER — treating unset as legitimate, unlike CurrentOrg() — and
# when it IS set, also calls CurrentOrg() and LoadProviderFor(org, id) to
# confirm the id names a provider actually registered under the current
# org, so it depends on WAKIL_ORG and on the provider's JSON record on
# disk, not on an env read alone. Its only caller today is Resolve()'s
# providerReport (internal/wakilcore/resolve.go), which compares this
# "running" provider against the project's "selected" one for
# get_context's report and is explicitly non-blocking on every path a
# broken or missing value can take. So an unset or stale WAKIL_PROVIDER
# does not cause a credential mismatch the way a stale WAKIL_ORG does —
# it makes that report wrong or silently unable to say who is running.
# Pinning it here is what makes that report describe the account
# `claude mcp add` actually wired up, rather than whatever WAKIL_PROVIDER
# happened to be lying around in the launching environment.
#
# ---------------------------------------------------------------------
# Why CLAUDE_CONFIG_DIR is exported here but never passed with -e
# ---------------------------------------------------------------------
# `claude mcp add` itself reads CLAUDE_CONFIG_DIR to decide which
# account's configuration it writes the registration INTO. This script
# exports it, read from `wakil provider config-dir <id>`, so the six
# registrations land in the provider's own config rather than whichever
# account happens to be ambient in the operator's shell. That is a
# different job from handing the same variable to the SERVER processes
# with -e, which the previous version of this script (register-org.sh)
# did because a server derived its org from that directory's name. A
# server derives nothing from CLAUDE_CONFIG_DIR any more — its org comes
# from -e WAKIL_ORG above — so it is not passed to the servers at all.
#
# ---------------------------------------------------------------------
# The symlink note
# ---------------------------------------------------------------------
# register-org.sh resolved CLAUDE_CONFIG_DIR's symlinks itself, because
# the org id it registered under was derived from that directory's
# basename, and a symlink pointing at a differently-named directory would
# silently register a different org than the one typed. Org identity no
# longer depends on any directory name — it is <org>, the first argument
# — so that derivation, and its warning, do not apply here.
#
# The configDir this script exports and announces is still worth getting
# right, though, and it already is: wakilcore.AddProvider (internal/
# wakilcore/provider.go) resolves a claude-code provider's --config-dir
# through filepath.EvalSymlinks at `wakil provider add` time and stores
# the RESOLVED path in the provider record. `wakil provider config-dir`
# hands back exactly that stored value, so what this script exports and
# prints below is already the real directory, not a symlink an operator
# typed once and later moved — with no resolution work left for this
# script to do.
#
# ---------------------------------------------------------------------
# Why WAKIL_JIRA_BASE is not passed here
# ---------------------------------------------------------------------
# WAKIL_JIRA_BASE lives in the org's own record now (wakilcore.Org.
# JiraBase, in org.json), and NewJiraFromEnv (internal/wakilcore/jira.go)
# loads it from the CURRENT org's org.json for every server that needs a
# Jira base. NewJiraFromEnv still ALSO reads a WAKIL_JIRA_BASE environment
# variable, but only as a manual override for when org.json is wrong and
# a Jira call is needed to diagnose that — it is not the normal path, and
# this script does not use it. Baking a copy of the org.json value into a
# per-provider `claude mcp add` invocation would give one org as many
# independent copies of its Jira site as it has providers — each editable
# only by re-running this script for that one provider — which is N
# chances for two providers of the same org to quietly disagree about
# which Jira site they point at. So this flag is never passed here, to
# any server, for any provider.
#
# ---------------------------------------------------------------------
# Why --scope user
# ---------------------------------------------------------------------
# `claude mcp add`'s default scope is "local", which binds the
# registration to the project directory the command was run from. A
# provider's servers belong to that PROVIDER's account (the config dir),
# not to whatever directory this script happened to be invoked in, so the
# scope has to be stated.
#
# ---------------------------------------------------------------------
# Why the binary comes after "--"
# ---------------------------------------------------------------------
# `claude mcp add`'s -e/--env is a VARIADIC option ("-e, --env <env...>"),
# so it keeps consuming following arguments. "--" terminates it, which is
# exactly the form the CLI's own help documents:
#   claude mcp add my-server -e API_KEY=xxx -- npx my-mcp-server
#
set -euo pipefail

# The six MCP servers. `wakil` itself is deliberately absent: it is the
# operator CLI for writing Keychain entries, not an MCP server, and
# registering it would hand Claude a command that reads a secret from
# stdin.
SERVERS="wakil-ctx wakil-db wakil-pm wakil-http wakil-recall wakil-git"

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
usage:
  scripts/register-provider.sh <org> <provider-id> <bin-dir>

  <org>          an org already registered with `wakil org create <org>`
  <provider-id>  a claude-code provider already registered under that org
                 with `wakil provider add <provider-id> --kind claude-code
                 --config-dir DIR --org <org>`
  <bin-dir>      directory holding the built Wakil binaries (`make build`
                 writes bin/)
EOF
	exit 2
}

case "${1-}" in
-h | --help) usage ;;
esac
if [ "$#" -ne 3 ]; then
	usage
fi

org="$1"
provider="$2"
BIN="$3"

# ---------------------------------------------------------------------
# Validate everything BEFORE registering anything. A partial registration
# is worse than none: it leaves the provider half-wired with no single
# command to undo it.
# ---------------------------------------------------------------------

# `claude` must exist. Sending this failure to /dev/null and carrying on
# would print six "register it manually" notes and then claim success.
command -v claude >/dev/null 2>&1 ||
	die "the 'claude' CLI is not on PATH — install Claude Code, or add it to PATH, then re-run"

# `wakil` must exist too: every check below, and the config-dir lookup
# that follows them, shells out to it.
command -v wakil >/dev/null 2>&1 ||
	die "the 'wakil' CLI is not on PATH — build it with 'make build' and add its directory to PATH, then re-run"

[ -d "$BIN" ] || die "bin dir ($BIN) is not a directory — run 'make build' first"
BIN="$(cd "$BIN" && pwd -P)"

missing=""
for s in $SERVERS; do
	if [ ! -f "$BIN/$s" ]; then
		missing="$missing $s(absent)"
	elif [ ! -x "$BIN/$s" ]; then
		missing="$missing $s(not-executable)"
	fi
done
[ -z "$missing" ] || die "missing or non-executable binaries in $BIN:$missing — run 'make build'"

# The org must already be registered. `wakil org list` prints one org id
# per line to STDOUT and nothing else on that stream; a diagnostic — a
# failure, or the "no orgs registered" notice for an empty registry —
# goes to stderr instead (runOrgList in cmd/wakil/orgcmd.go). Only stdout
# is captured here, so a failure's own stderr message is left to flow
# straight through to the operator rather than being swallowed and
# re-quoted.
org_list="$(wakil org list)" ||
	die "'wakil org list' failed — see its message above"
if ! printf '%s\n' "$org_list" | grep -qxF "$org"; then
	die "org '$org' is not registered — create it first with: wakil org create $org"
fi

# The provider must already be registered under that org. `wakil provider
# list` prints one line per provider to STDOUT, formatted
# "<id>  kind=<kind> label=<label> configDir=<dir>" (runProviderList in
# cmd/wakil/providercmd.go); a diagnostic — a failure, or the "no
# providers registered" notice for an empty org — goes to stderr instead,
# exactly like `org list` above. The provider id is the first
# whitespace-separated field, so it is matched on that field alone rather
# than as a substring of the whole line — a provider id that is a prefix
# of another's (e.g. "primary" and "primary-backup") must not match the
# wrong one.
provider_list="$(wakil provider list --org "$org")" ||
	die "'wakil provider list --org $org' failed — see its message above"
if ! printf '%s\n' "$provider_list" | awk -v id="$provider" '$1 == id { found = 1 } END { exit !found }'; then
	die "provider '$provider' is not registered under org '$org' — add it first with: wakil provider add $provider --kind claude-code --config-dir <dir> --org $org"
fi

# The provider's configDir — see the symlink note above for why this
# script trusts it without resolving anything itself. `wakil provider
# config-dir` prints exactly one value, on stdout, with a trailing
# newline and nothing else, and nothing on stderr, on success (its own
# doc comment). Command substitution strips the trailing newline, so CFG
# is exactly that one line.
CFG="$(wakil provider config-dir "$provider" --org "$org")" ||
	die "'wakil provider config-dir $provider --org $org' failed — see its message above"
[ -n "$CFG" ] || die "'wakil provider config-dir $provider --org $org' printed nothing"
[ -d "$CFG" ] || die "the configDir recorded for provider '$provider' ($CFG) is not a directory — it may have been moved or deleted since 'wakil provider add' ran"

# Refuse to steal another org's pin.
#
# `claude mcp add -e WAKIL_ORG=$org` below writes the org INTO this
# directory, and a plain `claude` session started there reads it with no
# way to override. So exactly one org may pin a given directory, and this
# is the only command that writes it — AddProvider's --share rule is
# bookkeeping, this is enforcement.
#
# Registering a shared provider here would repoint the homing org's
# headless sessions at this org, silently, and the failure would surface
# far away as a credential lookup in the wrong org. Wakil itself needs no
# registration for a shared account: it passes every session its own org
# and launches with --strict-mcp-config, so it never reads this pin.
HOME_ORG="$(wakil provider home "$provider" --org "$org")" ||
	die "'wakil provider home $provider --org $org' failed — see its message above"
[ -n "$HOME_ORG" ] || die "'wakil provider home $provider --org $org' printed nothing"
if [ "$HOME_ORG" != "$org" ]; then
	# The instruction names commands this script can actually spell out.
	# It used to end "release it first: wakil provider rm <id> --org
	# $HOME_ORG", with the literal <id>: `wakil provider home` prints only
	# the org, by design (one line, nothing else, so command substitution
	# reads it), so the id was never in this script's hands. Worse, that
	# command is now REFUSED while this binding exists — RemoveProvider
	# will not delete a record that homes a dir another org still shares —
	# so the one step it named could not be the first one. Re-homing is
	# three steps and the order is the whole point.
	die "provider '$provider' in org '$org' shares a config dir that org '$HOME_ORG' homes ($CFG). Registering it here would overwrite '$HOME_ORG's WAKIL_ORG pin and silently repoint that org's plain \`claude\` sessions. Wakil already runs this account under '$org' without any registration, so if you only wanted it usable from Wakil there is nothing left to do. If you meant to MOVE the pin to '$org' instead, that is a re-homing, in this order: (1) drop this sharing binding — wakil provider rm $provider --org $org; (2) remove the record that homes the directory in '$HOME_ORG' — 'wakil provider list --org $HOME_ORG' names it as the row whose configDir is $CFG, and that removal is refused until step 1 has run; (3) re-add the directory under '$org' without --share, then re-run this script to move the pin."
fi

export CLAUDE_CONFIG_DIR="$CFG"

# ---------------------------------------------------------------------
# Register. stderr is NOT redirected: when `claude mcp add` fails, its own
# message is the only thing that explains why.
# ---------------------------------------------------------------------
echo "org:        $org"
echo "provider:   $provider"
echo "config dir: $CFG"
echo "bin dir:    $BIN"
echo

failed=""
total=0
for s in $SERVERS; do
	total=$((total + 1))
	args=("$s" --scope user -e "WAKIL_ORG=$org" -e "WAKIL_PROVIDER=$provider")
	# Re-registering must WORK, not fail. `claude mcp add` refuses a name
	# that already exists ("MCP server <name> already exists in user
	# config"), and re-running this script is the normal way to change
	# something — a new bin path after moving the repo, for instance.
	# Without the remove, the very first server aborts and the run dies
	# AFTER printing "registering" for all six, leaving the provider
	# exactly as it was while claiming it is "only partially registered".
	#
	# The remove is best-effort: it fails when the server is not there
	# yet, which is the ordinary first-run case, so its exit status is
	# discarded and its output suppressed. `add` is what is checked. The
	# pair is not atomic — a failure between them leaves the server
	# unregistered rather than stale — which is the safer of the two
	# outcomes, and the summary below still reports it as failed.
	claude mcp remove "$s" --scope user >/dev/null 2>&1 || true
	echo "registering $s"
	if ! claude mcp add "${args[@]}" -- "$BIN/$s"; then
		failed="$failed $s"
	fi
done

echo
if [ -n "$failed" ]; then
	die "failed to register:$failed — provider '$provider' is only partially registered; fix the errors above and re-run"
fi
echo "registered $total Wakil servers for org: $org, provider: $provider"
