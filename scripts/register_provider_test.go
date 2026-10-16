// Package scripts holds tests for this repository's non-Go build
// artefacts: register-provider.sh in this directory, and the root
// Makefile (see makefile_test.go). It has no non-test source — the
// artefacts under test are the files themselves, and this package exists
// so `go test ./...` covers them alongside everything else instead of
// leaving them to a reviewer's eye.
//
// SAFETY. Not one test here runs the real `claude` CLI, the real `wakil`
// CLI, or touches a real Claude config dir or ~/.wakil. Each run gets a
// PATH whose first entries are temp directories holding a fake `claude`
// (which only appends its arguments to a log file) and a fake `wakil`
// (which answers `org list`, `provider list` and `provider config-dir`
// from files the test writes, matching the real CLI's exact output shape
// — see fakeWakil's comment for the contract it mirrors and where that
// contract is defined in cmd/wakil).
package scripts

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// providerServers is the list register-provider.sh registers. `wakil`
// is intentionally absent — it is the operator CLI, not an MCP server.
var providerServers = []string{"wakil-ctx", "wakil-db", "wakil-pm", "wakil-http", "wakil-recall", "wakil-git"}

// fakeClaude is unchanged from register-org.sh's test suite: it records
// every `claude mcp add`/`remove` invocation and models the real CLI's
// refusal of a duplicate name, which is what makes the remove-then-add
// idempotency in register-provider.sh observable at all.
const fakeClaude = `#!/bin/sh
# Fake ` + "`claude`" + ` for register-provider.sh's tests. Records the invocation
# and, if FAKE_CLAUDE_FAIL_FOR names one of the arguments, fails the way
# the real CLI would when a registration is refused.
#
# It also models the real CLI's DUPLICATE behaviour: ` + "`claude mcp add`" + `
# refuses a name that already exists, so without a remove-then-add in the
# script every re-registration aborts on the first server. State lives in
# FAKE_CLAUDE_STATE, one file per registered name; ` + "`mcp remove`" + ` deletes
# it and fails when it is absent, exactly as the real CLI does for an
# unknown server.
#
# Only ` + "`mcp add`" + ` is written to FAKE_CLAUDE_LOG / FAKE_CLAUDE_ARGV_LOG.
# The removes go to their own log so that every assertion counting or
# indexing registrations keeps meaning what it meant before.
case "$1 $2" in
"mcp remove")
	printf '%s\n' "$*" >> "${FAKE_CLAUDE_REMOVE_LOG:-/dev/null}"
	if [ -n "${FAKE_CLAUDE_STATE:-}" ] && [ -e "$FAKE_CLAUDE_STATE/$3" ]; then
		rm -f "$FAKE_CLAUDE_STATE/$3"
		exit 0
	fi
	echo "fake claude: no MCP server named $3" >&2
	exit 1
	;;
"mcp add")
	if [ -n "${FAKE_CLAUDE_STATE:-}" ]; then
		if [ -e "$FAKE_CLAUDE_STATE/$3" ]; then
			echo "MCP server $3 already exists in user config" >&2
			exit 1
		fi
		mkdir -p "$FAKE_CLAUDE_STATE"
		: > "$FAKE_CLAUDE_STATE/$3"
	fi
	;;
esac
printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"
# The second log records what "$*" above CANNOT show. Joining the
# arguments with spaces produces the same line whether the script quoted
# its argument array or let the shell split it on whitespace, so a path
# containing a space would silently arrive as two arguments and every
# assertion built on $* would still pass. One line per argument, with the
# count in front, is what makes the split visible. The last line is the
# CLAUDE_CONFIG_DIR this process INHERITED — the real ` + "`claude`" + ` reads
# that variable to decide which configuration it writes into, so the
# script's export of it has to be observable too.
{
	printf 'ARGC %s\n' "$#"
	for a in "$@"; do printf 'ARG %s\n' "$a"; done
	printf 'ENV %s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
} >> "$FAKE_CLAUDE_ARGV_LOG"
if [ -n "${FAKE_CLAUDE_FAIL_FOR:-}" ]; then
	for a in "$@"; do
		if [ "$a" = "$FAKE_CLAUDE_FAIL_FOR" ]; then
			echo "fake claude: refusing to register $a" >&2
			exit 1
		fi
	done
fi
exit 0
`

// fakeWakil answers exactly the four read-only calls register-provider.sh
// makes against the real `wakil` CLI — no more, no less — reproducing
// their real output shape rather than a guessed one:
//
//   - `org list` prints one org id per line, to STDOUT and nothing else on
//     that stream; a diagnostic (a failure, or the "no orgs registered"
//     notice for an empty registry) goes to stderr instead
//     (cmd/wakil/orgcmd.go's runOrgList, fixed in Task 10's review to put
//     rows a caller parses on stdout rather than stderr).
//   - `provider list --org <org>` prints one
//     "<id>  kind=<kind> label=<label> configDir=<dir>" line per provider,
//     to STDOUT; its own diagnostics (failure, or "no providers
//     registered") go to stderr the same way (runProviderList).
//   - `provider config-dir <id> --org <org>` prints ONLY the configDir, on
//     STDOUT, with a trailing newline and nothing else, on success
//     (runProviderConfigDir); for a provider recorded with no configDir it
//     prints a message on stderr and exits 1, mirroring a codex/local
//     provider in the real CLI.
//   - `provider home <id> --org <org>` prints ONLY the org that pinned
//     WAKIL_ORG inside that provider's configDir, on STDOUT, with a
//     trailing newline and nothing else, on success; for a provider
//     recorded with no configDir it prints a message on stderr and exits
//     **1**, mirroring the real `wakil provider home`, which reserves 2
//     for a bad invocation the operator can retype their way out of and
//     uses 1 for a failure met while doing the work (runProviderHome's
//     own doc comment, and runProviderConfigDir's convention before it).
//     This double said 2 here, and exited 2, for both cases — a stated
//     contract that did not match the thing it stands in for is the one
//     defect a double can introduce that the real code cannot.
//
// State comes from two files the test writes fresh before each run:
// FAKE_WAKIL_ORGS_FILE (one org id per line) and FAKE_WAKIL_PROVIDERS_FILE
// (one "id kind configdir home" record per line; configdir is "-" for a
// provider recorded with none, mirroring codex/local; home defaults to
// the fixture's own org).
const fakeWakil = `#!/bin/sh
case "$1 $2" in
"org list")
	found=0
	if [ -n "${FAKE_WAKIL_ORGS_FILE:-}" ] && [ -f "$FAKE_WAKIL_ORGS_FILE" ]; then
		while IFS= read -r o; do
			[ -n "$o" ] || continue
			echo "$o"
			found=1
		done < "$FAKE_WAKIL_ORGS_FILE"
	fi
	[ "$found" = 1 ] || echo "no orgs registered" >&2
	exit 0
	;;
"provider list")
	found=0
	if [ -n "${FAKE_WAKIL_PROVIDERS_FILE:-}" ] && [ -f "$FAKE_WAKIL_PROVIDERS_FILE" ]; then
		while IFS=' ' read -r id kind cfg home; do
			[ -n "$id" ] || continue
			echo "$id  kind=$kind label=\"\" configDir=\"$cfg\""
			found=1
		done < "$FAKE_WAKIL_PROVIDERS_FILE"
	fi
	[ "$found" = 1 ] || echo "no providers registered in org \"x\"" >&2
	exit 0
	;;
"provider config-dir")
	id="$3"
	if [ -n "${FAKE_WAKIL_PROVIDERS_FILE:-}" ] && [ -f "$FAKE_WAKIL_PROVIDERS_FILE" ]; then
		while IFS=' ' read -r pid kind cfg home; do
			if [ "$pid" = "$id" ]; then
				if [ -z "$cfg" ] || [ "$cfg" = "-" ]; then
					echo "provider \"$id\" (kind $kind) has no configDir -- only a claude-code provider has one" >&2
					exit 1
				fi
				printf '%s\n' "$cfg"
				exit 0
			fi
		done < "$FAKE_WAKIL_PROVIDERS_FILE"
	fi
	echo "no provider \"$id\" registered -- register it with: wakil provider add $id" >&2
	exit 2
	;;
"provider home")
	id="$3"
	if [ -n "${FAKE_WAKIL_PROVIDERS_FILE:-}" ] && [ -f "$FAKE_WAKIL_PROVIDERS_FILE" ]; then
		while IFS=' ' read -r pid kind cfg home; do
			if [ "$pid" = "$id" ]; then
				if [ -z "$cfg" ] || [ "$cfg" = "-" ]; then
					echo "provider \"$id\" has no config dir -- only a claude-code provider pins an org inside one" >&2
					exit 1
				fi
				printf '%s\n' "$home"
				exit 0
			fi
		done < "$FAKE_WAKIL_PROVIDERS_FILE"
	fi
	echo "no provider \"$id\" registered -- register it with: wakil provider add $id" >&2
	exit 2
	;;
esac
echo "fake wakil: unhandled invocation: $*" >&2
exit 1
`

// binDirName is deliberately awkward: a space and a single quote. The bin
// dir path flows through `cd`, `pwd -P`, a bash array and a child
// process's argv, and every one of those is a place an unquoted expansion
// works on a tidy path and silently splits a real one. An operator's repo
// checkout can plausibly sit under a path like this.
const binDirName = "bin dir 'quoted'"

// provRecord is one line of the fake provider registry.
//
// home is the org that pinned WAKIL_ORG inside configDir. Empty means
// "this record's own org", which is what every unshared provider is and
// what every fixture predating sharing relies on.
type provRecord struct {
	id, kind, configDir, home string
}

type env struct {
	root       string // t.TempDir(), symlink-resolved
	binDir     string
	configDir  string // the default provider's (fake) CLAUDE_CONFIG_DIR
	org        string
	provider   string
	orgs       []string
	providers  []provRecord
	logPath    string // fake claude: `mcp add` log
	argvPath   string // fake claude: structured argv+env log
	removePath string // fake claude: `mcp remove` log
	statePath  string // fake claude: per-server registration state
	ordersFile string // fake wakil: FAKE_WAKIL_ORGS_FILE
	provsFile  string // fake wakil: FAKE_WAKIL_PROVIDERS_FILE
	pathDirs   []string
	extra      []string
	noClaude   bool
	noWakil    bool
}

// newEnv builds a fully working fixture: one org ("initech") holding one
// claude-code provider ("primary") whose configDir is a real, empty
// directory, a bin dir with all six executables, and fake `claude` and
// `wakil` first on PATH.
func newEnv(t *testing.T) *env {
	t.Helper()
	// The script resolves the bin dir with `pwd -P`, which follows
	// symlinks — and on macOS t.TempDir() hands back a path under /var,
	// itself a symlink to /private/var. Resolving here means the paths
	// the tests assert on are the same strings the script produces.
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temp dir: %v", err)
	}

	configDir := filepath.Join(root, "provider-config-dir")
	mkdir(t, configDir)

	binDir := filepath.Join(root, binDirName)
	mkdir(t, binDir)
	for _, s := range providerServers {
		writeExecutable(t, filepath.Join(binDir, s), "#!/bin/sh\nexit 0\n")
	}

	fakeBin := filepath.Join(root, "fakebin")
	mkdir(t, fakeBin)
	writeExecutable(t, filepath.Join(fakeBin, "claude"), fakeClaude)
	writeExecutable(t, filepath.Join(fakeBin, "wakil"), fakeWakil)

	return &env{
		root:       root,
		binDir:     binDir,
		configDir:  configDir,
		org:        "initech",
		provider:   "primary",
		orgs:       []string{"initech"},
		providers:  []provRecord{{id: "primary", kind: "claude-code", configDir: configDir}},
		logPath:    filepath.Join(root, "claude.log"),
		argvPath:   filepath.Join(root, "claude.argv.log"),
		removePath: filepath.Join(root, "claude.remove.log"),
		statePath:  filepath.Join(root, "claude-state"),
		ordersFile: filepath.Join(root, "wakil-orgs"),
		provsFile:  filepath.Join(root, "wakil-providers"),
		// /usr/bin and /bin are needed for basename, cd and pwd, which
		// the script uses.
		pathDirs: []string{fakeBin, "/usr/bin", "/bin"},
	}
}

type result struct {
	code   int
	stdout string
	stderr string
	// calls holds one entry per fake-claude `mcp add` invocation, each
	// the space-joined argument list.
	calls []string
	// argv holds the same invocations with their arguments kept
	// separate, plus the CLAUDE_CONFIG_DIR each one inherited.
	argv []call
}

// call is one fake-claude invocation, recorded unambiguously.
type call struct {
	args []string
	env  string
}

// run writes the fixture's org/provider registry files, then executes
// register-provider.sh with the fixture's environment and the given
// arguments.
func (e *env) run(t *testing.T, args ...string) result {
	t.Helper()
	script, err := filepath.Abs("register-provider.sh")
	if err != nil {
		t.Fatalf("resolve script path: %v", err)
	}

	// Reading the script here is load-bearing beyond the two assertions
	// below. `go test` caches a package's result and decides whether the
	// cache is still valid from the files the TEST BINARY opened; the
	// script is executed by a child `bash`, whose reads the go command
	// cannot see. Without this os.ReadFile, editing register-provider.sh
	// and re-running `go test ./scripts/` replays a cached PASS — which
	// is exactly how a mutation of the script can look like a green
	// suite. Do not remove it.
	body, err := os.ReadFile(script)
	if err != nil {
		t.Fatalf("read %s: %v", script, err)
	}
	if !strings.HasPrefix(string(body), "#!/usr/bin/env bash\n") {
		t.Fatalf("%s must start with the bash shebang", script)
	}
	info, err := os.Stat(script)
	if err != nil {
		t.Fatalf("stat %s: %v", script, err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("%s is not executable (mode %v) — the operator runs it directly", script, info.Mode().Perm())
	}

	writeLines(t, e.ordersFile, e.orgs)
	var provLines []string
	for _, p := range e.providers {
		cfg := p.configDir
		if cfg == "" {
			cfg = "-"
		}
		home := p.home
		if home == "" {
			home = e.org
		}
		provLines = append(provLines, fmt.Sprintf("%s %s %s %s", p.id, p.kind, cfg, home))
	}
	writeLines(t, e.provsFile, provLines)

	pathDirs := e.pathDirs
	if e.noClaude || e.noWakil {
		// Rebuild fakeBin without the omitted binary rather than just
		// dropping fakeBin from PATH, so the OTHER fake stays available
		// and any failure really is about the one missing tool.
		trimmed := filepath.Join(e.root, "fakebin-trimmed")
		mkdir(t, trimmed)
		if !e.noClaude {
			writeExecutable(t, filepath.Join(trimmed, "claude"), fakeClaude)
		}
		if !e.noWakil {
			writeExecutable(t, filepath.Join(trimmed, "wakil"), fakeWakil)
		}
		pathDirs = append([]string{trimmed}, pathDirs[1:]...)
	}

	cmd := exec.Command("bash", append([]string{script}, args...)...)
	// A closed, empty environment: only what the script is entitled to
	// see. In particular the developer's own PATH, HOME, CLAUDE_CONFIG_DIR
	// and WAKIL_ORG are not inherited, so a passing test cannot depend on
	// them, and no test here can reach the real ~/.wakil or ~/.claude*.
	cmd.Env = append([]string{
		"PATH=" + strings.Join(pathDirs, string(os.PathListSeparator)),
		"HOME=" + e.root,
		"FAKE_CLAUDE_LOG=" + e.logPath,
		"FAKE_CLAUDE_ARGV_LOG=" + e.argvPath,
		"FAKE_CLAUDE_REMOVE_LOG=" + e.removePath,
		"FAKE_CLAUDE_STATE=" + e.statePath,
		"FAKE_WAKIL_ORGS_FILE=" + e.ordersFile,
		"FAKE_WAKIL_PROVIDERS_FILE=" + e.provsFile,
	}, e.extra...)
	cmd.Dir = e.root

	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	res := result{stdout: stdout.String(), stderr: stderr.String()}
	if runErr != nil {
		var exitErr *exec.ExitError
		if !asExitError(runErr, &exitErr) {
			t.Fatalf("run register-provider.sh: %v", runErr)
		}
		res.code = exitErr.ExitCode()
	}

	if body, err := os.ReadFile(e.logPath); err == nil {
		for _, line := range strings.Split(strings.TrimRight(string(body), "\n"), "\n") {
			if line != "" {
				res.calls = append(res.calls, line)
			}
		}
	} else if !os.IsNotExist(err) {
		t.Fatalf("read fake claude log: %v", err)
	}
	res.argv = readArgvLog(t, e.argvPath)
	return res
}

// runDefault runs with the fixture's default org, provider and bin dir —
// the shape almost every test needs.
func (e *env) runDefault(t *testing.T) result {
	t.Helper()
	return e.run(t, e.org, e.provider, e.binDir)
}

// readArgvLog decodes the fake claude's structured log: an "ARGC <n>"
// line, then exactly n "ARG <value>" lines, then one "ENV <value>" line,
// per invocation. The count is what makes an extra argument — the visible
// symptom of an unquoted "${args[@]}" meeting a path with a space —
// impossible to miss.
func readArgvLog(t *testing.T, path string) []call {
	t.Helper()
	body, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatalf("read fake claude argv log: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	var out []call
	for i := 0; i < len(lines); {
		if lines[i] == "" {
			i++
			continue
		}
		if !strings.HasPrefix(lines[i], "ARGC ") {
			t.Fatalf("argv log line %d = %q, want an ARGC record", i, lines[i])
		}
		n, err := strconv.Atoi(strings.TrimPrefix(lines[i], "ARGC "))
		if err != nil {
			t.Fatalf("argv log line %d = %q: %v", i, lines[i], err)
		}
		i++
		var c call
		for j := 0; j < n; j++ {
			if i >= len(lines) || !strings.HasPrefix(lines[i], "ARG ") {
				t.Fatalf("argv log: expected %d ARG lines, ran out at %d", n, j)
			}
			c.args = append(c.args, strings.TrimPrefix(lines[i], "ARG "))
			i++
		}
		if i >= len(lines) || !strings.HasPrefix(lines[i], "ENV ") {
			t.Fatalf("argv log: expected an ENV line after %d args", n)
		}
		c.env = strings.TrimPrefix(lines[i], "ENV ")
		i++
		out = append(out, c)
	}
	return out
}

// argvFor returns the exact argument list recorded for server, or nil.
func (r result) argvFor(server string) *call {
	for i, c := range r.argv {
		if len(c.args) >= 3 && c.args[0] == "mcp" && c.args[1] == "add" && c.args[2] == server {
			return &r.argv[i]
		}
	}
	return nil
}

// callFor returns the recorded invocation that registered server, or "".
func (r result) callFor(server string) string {
	for _, c := range r.calls {
		if strings.Contains(c, "mcp add "+server+" ") {
			return c
		}
	}
	return ""
}

func (r result) String() string {
	return fmt.Sprintf("exit=%d\nstdout:\n%s\nstderr:\n%s\ncalls:\n%s", r.code, r.stdout, r.stderr, strings.Join(r.calls, "\n"))
}

// ---------------------------------------------------------------------

// TestRegisterProviderPassesOrgAndProviderToEveryServer is this task's
// core assertion (spec §8): every one of the six servers is registered
// with both WAKIL_ORG and WAKIL_PROVIDER pinned, and WAKIL_JIRA_BASE never
// appears at all — it lives in org.json now.
func TestRegisterProviderPassesOrgAndProviderToEveryServer(t *testing.T) {
	e := newEnv(t)
	res := e.runDefault(t)

	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	if len(res.calls) != len(providerServers) {
		t.Fatalf("registered %d servers, want %d\n%s", len(res.calls), len(providerServers), res)
	}
	for _, s := range providerServers {
		call := res.callFor(s)
		if call == "" {
			t.Fatalf("no registration recorded for %s\n%s", s, res)
		}
		if !strings.Contains(call, "-e WAKIL_ORG=initech") {
			t.Fatalf("registration for %s = %q, want it to pin WAKIL_ORG", s, call)
		}
		if !strings.Contains(call, "-e WAKIL_PROVIDER=primary") {
			t.Fatalf("registration for %s = %q, want it to pin WAKIL_PROVIDER", s, call)
		}
		if strings.Contains(call, "WAKIL_JIRA_BASE") {
			t.Fatalf("registration for %s = %q, must never carry WAKIL_JIRA_BASE — it lives in org.json now", s, call)
		}
		if !strings.Contains(call, "--scope user") {
			t.Fatalf("registration for %s = %q, want --scope user", s, call)
		}
		if !strings.HasSuffix(call, "-- "+filepath.Join(e.binDir, s)) {
			t.Fatalf("registration for %s = %q, want it to end with the binary path after --", s, call)
		}
	}
	if !strings.Contains(res.stdout, "registered 6 Wakil servers for org: initech, provider: primary") {
		t.Fatalf("stdout = %q, want the success summary\n%s", res.stdout, res)
	}
}

// TestDoesNotRegisterTheWakilCLI pins the deliberate omission: the `wakil`
// operator CLI reads a secret from stdin and is not an MCP server, so it
// must never be handed to Claude.
func TestDoesNotRegisterTheWakilCLI(t *testing.T) {
	e := newEnv(t)
	writeExecutable(t, filepath.Join(e.binDir, "wakil"), "#!/bin/sh\nexit 0\n")
	res := e.runDefault(t)
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	for _, c := range res.calls {
		if strings.Contains(c, "mcp add wakil ") {
			t.Fatalf("the wakil CLI was registered as an MCP server: %q", c)
		}
	}
}

// TestJiraBaseInTheEnvironmentIsNeverForwarded guards the stronger claim
// than "the script has no flag for it": even an ambient WAKIL_JIRA_BASE —
// left over from an old shell, say — must not leak into a registration,
// because this script never reads that variable at all.
func TestJiraBaseInTheEnvironmentIsNeverForwarded(t *testing.T) {
	e := newEnv(t)
	e.extra = append(e.extra, "WAKIL_JIRA_BASE=https://acme.atlassian.net")
	res := e.runDefault(t)
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	for _, c := range res.calls {
		if strings.Contains(c, "JIRA") {
			t.Fatalf("an ambient WAKIL_JIRA_BASE leaked into a registration: %q", c)
		}
	}
}

// TestExportsProviderConfigDirForClaudeMcpAdd pins the mechanism that
// replaces the removed CLAUDE_CONFIG_DIR-must-be-set-by-hand step: the
// script looks the provider's configDir up itself and exports it, so
// `claude mcp add` writes into that account's configuration.
func TestExportsProviderConfigDirForClaudeMcpAdd(t *testing.T) {
	e := newEnv(t)
	res := e.runDefault(t)
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	for _, s := range providerServers {
		c := res.argvFor(s)
		if c == nil {
			t.Fatalf("no argv recorded for %s\n%s", s, res)
		}
		if c.env != e.configDir {
			t.Fatalf("%s: claude inherited CLAUDE_CONFIG_DIR=%q, want %q", s, c.env, e.configDir)
		}
		// CLAUDE_CONFIG_DIR must not be handed to the SERVER via -e: it
		// derives nothing from it any more (org comes from WAKIL_ORG).
		for _, a := range c.args {
			if strings.HasPrefix(a, "CLAUDE_CONFIG_DIR=") {
				t.Fatalf("%s: CLAUDE_CONFIG_DIR was passed via -e, want it exported for `claude mcp add` only: %v", s, c.args)
			}
		}
	}
	if !strings.Contains(res.stdout, "config dir: "+e.configDir) {
		t.Fatalf("stdout = %q, want the config dir announced", res.stdout)
	}
}

// TestProviderIDPrefixDoesNotMatchTheWrongProvider pins a deferred Minor
// from Task 10's review: the provider-list existence check is exact-field
// (`awk '$1 == id'`), not a substring search, so a provider id that is a
// literal prefix of another REGISTERED provider's id must not be treated
// as registered itself.
//
// This has to be checked at the existence-check level specifically, not
// by asserting on the final registration: config-dir resolution
// (`wakil provider config-dir <id>`) is always an exact lookup by itself,
// on both the real CLI (LoadProviderFor matches a filename exactly) and
// this test's fake, so a looser existence check would not route a
// SUCCESSFUL run to the wrong configDir — it would let an UNREGISTERED
// id slip past the early refusal and fail later, at config-dir, with a
// different and less specific message. That is the observable difference
// this test pins: with only "primary-backup" registered (never
// "primary"), asking for "primary" must be refused by THIS script's own
// early check, naming "primary" as unregistered — not by some other
// failure further down.
func TestProviderIDPrefixDoesNotMatchTheWrongProvider(t *testing.T) {
	e := newEnv(t)
	backupConfigDir := filepath.Join(e.root, "backup-config-dir")
	mkdir(t, backupConfigDir)
	// Replace the default "primary" provider entirely: only
	// "primary-backup" is registered in this org.
	e.providers = []provRecord{{id: "primary-backup", kind: "claude-code", configDir: backupConfigDir}}

	res := e.run(t, e.org, "primary", e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero — 'primary' is not registered, only 'primary-backup' is\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for an unregistered provider id that is a prefix of a registered one\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "provider 'primary' is not registered under org 'initech'") {
		t.Fatalf("stderr = %q, want THIS script's own early refusal naming 'primary' as unregistered — a substring match would instead let it through to fail later, with a different message", res.stderr)
	}

	// The registered one still works, proving the fixture itself is
	// sound and this is not just "everything fails".
	res2 := e.run(t, e.org, "primary-backup", e.binDir)
	if res2.code != 0 {
		t.Fatalf("exit code = %d, want 0 for the actually-registered provider\n%s", res2.code, res2)
	}
	c2 := res2.argvFor("wakil-ctx")
	if c2 == nil {
		t.Fatalf("no argv recorded for wakil-ctx\n%s", res2)
	}
	if c2.env != backupConfigDir {
		t.Fatalf("registering 'primary-backup' inherited CLAUDE_CONFIG_DIR=%q, want %q", c2.env, backupConfigDir)
	}
}

func TestRefusesUnregisteredOrg(t *testing.T) {
	e := newEnv(t)
	res := e.run(t, "nonesuch", e.provider, e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for an unregistered org\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "org 'nonesuch' is not registered") {
		t.Fatalf("stderr = %q, want it to refuse the unregistered org", res.stderr)
	}
}

func TestRefusesUnregisteredProvider(t *testing.T) {
	e := newEnv(t)
	res := e.run(t, e.org, "ghost", e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for an unregistered provider\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "provider 'ghost' is not registered under org 'initech'") {
		t.Fatalf("stderr = %q, want it to refuse the unregistered provider", res.stderr)
	}
}

// TestRefusesProviderWithNoConfigDir covers a codex/local provider: it is
// registered under the org (so the provider-list check passes), but
// `wakil provider config-dir` fails for it, and that failure must abort
// registration with the real CLI's own message visible.
func TestRefusesProviderWithNoConfigDir(t *testing.T) {
	e := newEnv(t)
	e.providers = append(e.providers, provRecord{id: "codex1", kind: "codex", configDir: ""})
	res := e.run(t, e.org, "codex1", e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for a provider with no configDir\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "has no configDir") {
		t.Fatalf("stderr = %q, want the real CLI's own message to reach the operator", res.stderr)
	}
}

func TestMissingClaudeFailsLoudly(t *testing.T) {
	e := newEnv(t)
	e.noClaude = true
	res := e.runDefault(t)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if !strings.Contains(res.stderr, "'claude' CLI is not on PATH") {
		t.Fatalf("stderr = %q, want it to say the claude CLI is missing", res.stderr)
	}
	if strings.Contains(res.stdout, "registered") {
		t.Fatalf("stdout = %q, want no success line", res.stdout)
	}
}

func TestMissingWakilFailsLoudly(t *testing.T) {
	e := newEnv(t)
	e.noWakil = true
	res := e.runDefault(t)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if !strings.Contains(res.stderr, "'wakil' CLI is not on PATH") {
		t.Fatalf("stderr = %q, want it to say the wakil CLI is missing", res.stderr)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers with wakil missing\n%s", len(res.calls), res)
	}
}

func TestMissingBinaryFailsBeforeRegisteringAnything(t *testing.T) {
	e := newEnv(t)
	if err := os.Remove(filepath.Join(e.binDir, "wakil-recall")); err != nil {
		t.Fatalf("remove binary: %v", err)
	}
	res := e.runDefault(t)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers despite a missing binary\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "wakil-recall(absent)") {
		t.Fatalf("stderr = %q, want it to name wakil-recall as absent", res.stderr)
	}
}

func TestNonExecutableBinaryFailsBeforeRegisteringAnything(t *testing.T) {
	e := newEnv(t)
	if err := os.Chmod(filepath.Join(e.binDir, "wakil-db"), 0o644); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	res := e.runDefault(t)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers despite a non-executable binary\n%s", len(res.calls), res)
	}
	if !strings.Contains(res.stderr, "wakil-db(not-executable)") {
		t.Fatalf("stderr = %q, want it to name wakil-db as not executable", res.stderr)
	}
}

// TestPartialFailureExitsNonZeroAndNamesTheServer covers the exact
// scenario register-org.sh's own history got wrong: some registrations
// fail, and the script must neither swallow the reason nor claim success.
func TestPartialFailureExitsNonZeroAndNamesTheServer(t *testing.T) {
	e := newEnv(t)
	e.extra = append(e.extra, "FAKE_CLAUDE_FAIL_FOR=wakil-pm")
	res := e.runDefault(t)

	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if !strings.Contains(res.stderr, "failed to register: wakil-pm") {
		t.Fatalf("stderr = %q, want it to name wakil-pm", res.stderr)
	}
	if !strings.Contains(res.stderr, "fake claude: refusing to register wakil-pm") {
		t.Fatalf("stderr = %q, want claude's own message, not a swallowed one", res.stderr)
	}
	if strings.Contains(res.stdout, "registered 6 Wakil servers") {
		t.Fatalf("stdout = %q, want no success line after a failure", res.stdout)
	}
	// The other four are still attempted — one bad server should not
	// abort the run and leave the operator guessing about the rest.
	if len(res.calls) != len(providerServers) {
		t.Fatalf("attempted %d registrations, want %d\n%s", len(res.calls), len(providerServers), res)
	}
}

func TestBinDirMustExist(t *testing.T) {
	e := newEnv(t)
	res := e.run(t, e.org, e.provider, filepath.Join(e.root, "no-such-bin"))
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	if !strings.Contains(res.stderr, "is not a directory") {
		t.Fatalf("stderr = %q, want it to reject the bin dir", res.stderr)
	}
}

// TestRelativeBinDirIsResolvedToAbsolute matters because the registered
// command string is executed by Claude from an unrelated working
// directory; a relative path would simply not be found.
func TestRelativeBinDirIsResolvedToAbsolute(t *testing.T) {
	e := newEnv(t)
	res := e.run(t, e.org, e.provider, binDirName) // cmd.Dir is e.root
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	call := res.callFor("wakil-ctx")
	want := " -- " + filepath.Join(e.binDir, "wakil-ctx")
	if !strings.HasSuffix(call, want) {
		t.Fatalf("registration for wakil-ctx = %q, want it to end with %q", call, want)
	}
}

func TestUsage(t *testing.T) {
	e := newEnv(t)
	for _, args := range [][]string{nil, {e.org}, {e.org, e.provider}, {e.org, e.provider, e.binDir, "extra"}, {"--help"}} {
		res := e.run(t, args...)
		if res.code != 2 {
			t.Fatalf("run(%q) exit code = %d, want 2\n%s", args, res.code, res)
		}
		if !strings.Contains(res.stderr, "usage:") {
			t.Fatalf("run(%q) stderr = %q, want usage", args, res.stderr)
		}
		if len(res.calls) != 0 {
			t.Fatalf("run(%q) registered %d servers\n%s", args, len(res.calls), res)
		}
	}
}

// TestReRegisteringSucceeds pins that running the script twice works, the
// exact defect register-org.sh's history records: `claude mcp add`
// refuses a name that already exists, and re-running is the ordinary way
// to change something (a new bin path after moving the repo, say).
// Without a remove-then-add, the second run would die claiming the
// provider is "only partially registered" while leaving it exactly as it
// was.
//
// MUTATION-VERIFIED: removing the `claude mcp remove` line from
// register-provider.sh makes the second run here exit 1 with all six
// servers in its failed list.
func TestReRegisteringSucceeds(t *testing.T) {
	e := newEnv(t)

	first := e.runDefault(t)
	if first.code != 0 {
		t.Fatalf("first run: exit code = %d, want 0\n%s", first.code, first)
	}

	// The fake claude APPENDS to its logs, so without this the second
	// run's assertions would read the first run's calls.
	for _, f := range []string{e.logPath, e.argvPath, e.removePath} {
		if err := os.Truncate(f, 0); err != nil && !os.IsNotExist(err) {
			t.Fatalf("truncate %s: %v", f, err)
		}
	}

	second := e.runDefault(t)
	if second.code != 0 {
		t.Fatalf("re-registering failed: exit code = %d, want 0\n%s", second.code, second)
	}
	if len(second.calls) != len(providerServers) {
		t.Fatalf("second run registered %d servers, want %d\n%s", len(second.calls), len(providerServers), second)
	}
	if !strings.Contains(second.stdout, "registered 6 Wakil servers for org: initech, provider: primary") {
		t.Fatalf("second run stdout = %q, want the success line", second.stdout)
	}

	// Each server must have been removed before being re-added, or the
	// add would have been refused. Assert the remove FIRED rather than
	// merely that the run succeeded.
	body, err := os.ReadFile(e.removePath)
	if err != nil {
		t.Fatalf("no remove log — the script never called `claude mcp remove`: %v", err)
	}
	for _, s := range providerServers {
		if !strings.Contains(string(body), "mcp remove "+s+" ") {
			t.Fatalf("no `mcp remove %s` recorded; removes were:\n%s", s, body)
		}
	}
}

// ---------------------------------------------------------------------

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func writeExecutable(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// writeLines writes lines to path, one per line, even when lines is
// empty (an empty file, which the fake wakil's readers treat as "none
// registered").
func writeLines(t *testing.T, path string, lines []string) {
	t.Helper()
	content := ""
	if len(lines) > 0 {
		content = strings.Join(lines, "\n") + "\n"
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// asExitError is errors.As specialised to *exec.ExitError, kept local so
// this file's imports stay to what it actually needs.
func asExitError(err error, target **exec.ExitError) bool {
	if e, ok := err.(*exec.ExitError); ok {
		*target = e
		return true
	}
	return false
}

// The script is the only command that writes the pin, so it is the only
// place the one-dir-one-org rule can actually be enforced. AddProvider's
// --share rule is bookkeeping; this is the guard.
func TestRefusesToRegisterAProviderWhoseConfigDirAnotherOrgHomes(t *testing.T) {
	e := newEnv(t)
	e.orgs = append(e.orgs, "personal")
	e.providers = append(e.providers, provRecord{
		id: "shared", kind: "claude-code", configDir: e.configDir, home: "personal",
	})

	res := e.run(t, e.org, "shared", e.binDir)
	if res.code == 0 {
		t.Fatalf("exit code = 0, want non-zero\n%s", res)
	}
	// Nothing registered: the refusal must come before the first
	// `claude mcp add`, because a partial run leaves the other org's pin
	// already overwritten.
	if len(res.calls) != 0 {
		t.Fatalf("registered %d servers for a shared provider\n%s", len(res.calls), res)
	}
	// The operator's next question is "homed by whom?".
	if !strings.Contains(res.stderr, "personal") {
		t.Fatalf("stderr = %q, want it to name the homing org", res.stderr)
	}
	// And the one after that is "so what do I type?". The refusal used to
	// answer with a literal placeholder — `wakil provider rm <id> --org
	// personal` — for an id this script never has, `wakil provider home`
	// printing only the org by design. A refusal whose command cannot be
	// pasted is not an instruction.
	if strings.Contains(res.stderr, "<id>") {
		t.Errorf("stderr still carries a literal <id> placeholder: %q", res.stderr)
	}
	// The repair it does name must be one that works: dropping THIS
	// binding first, because RemoveProvider refuses to delete the homing
	// record while any org still shares the directory.
	if !strings.Contains(res.stderr, "wakil provider rm shared --org "+e.org) {
		t.Errorf("stderr = %q, want it to name dropping this binding first", res.stderr)
	}
	// The doubled apostrophe: "'personal''s WAKIL_ORG pin" rendered
	// straight through to the operator, since the whole message is inside
	// a double-quoted shell string where a single quote is just a
	// character.
	if strings.Contains(res.stderr, "''") {
		t.Errorf("stderr carries a doubled apostrophe: %q", res.stderr)
	}
}

// The control. Without it this suite would pass if the script refused
// everything.
func TestStillRegistersTheProviderThatHomesItsOwnConfigDir(t *testing.T) {
	e := newEnv(t)
	e.providers = append(e.providers, provRecord{
		id: "shared", kind: "claude-code", configDir: e.configDir, home: "personal",
	})

	// e.provider ("primary") homes its own dir, so it is unaffected by the
	// presence of a shared record beside it.
	res := e.runDefault(t)
	if res.code != 0 {
		t.Fatalf("exit code = %d, want 0\n%s", res.code, res)
	}
	if len(res.calls) != len(providerServers) {
		t.Fatalf("registered %d servers, want %d\n%s", len(res.calls), len(providerServers), res)
	}
}
