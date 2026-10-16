# Rename to Wakil Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the product from Rafiq to Wakil everywhere in the tree, and ship a one-time
script that moves this Mac's existing Rafiq state (Keychain, `~/.rafiq`, project files,
preferences) to the new names.

**Architecture:** The migration script is written and tested first, while the tree still uses
the old name, against a throwaway keychain and a temporary `HOME`. The rename then runs in two
commits: `git mv` for every path, then a case-preserving content rewrite. The Go suite, the Swift
suite, the bundle build and a rename check prove it. The operator runs the migration on this Mac
after the PR merges.

**Tech Stack:** bash and perl (script, rewrite), Go `testing` in package `scripts` (the script's
tests, following `scripts/register_provider_test.go`), `/usr/bin/security`, `defaults`, Swift
Package Manager.

**Spec:** `docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md`

## Global Constraints

- Case is kept: `Rafiq` → `Wakil`, `rafiq` → `wakil`, `RAFIQ` → `WAKIL`. The Go module path
  `github.com/yehia/rafiq` → `github.com/yehia-khalil/wakil` (this one first, before the generic rule).
- No aliases, no compatibility shims, and no migration code in the product.
- Keychain: service `wakil:<org>:<ref>`, account `wakil`. State dir `~/.wakil`. Per-project file
  `<project>/.wakil/project.json`. Bundle ids `dev.wakil.app`, `dev.wakil.e2e`. Env vars `WAKIL_*`.
- **The old name may remain only in these files** (the rename check allows exactly these):
  - `scripts/migrate-from-rafiq.sh` and `scripts/migrate_from_rafiq_test.go`, which exist to find
    the old state;
  - `docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md`, this plan, and the two
    public-split docs (`…-public-repo-split-design.md`, `…-public-repo-split.md`), which are about
    the rename and are edited by hand (Task 2, Step 5);
  - the speech-recognition recordings `scripts/probe/stt-2026-10-06-apple.tsv` and
    `scripts/probe/stt-set2/{apple-2026-10-06.tsv,utterances.tsv,vocab-snapshot-2026-10-06.txt}`,
    and the `setOneTruth` list in `IdentifierCorpusTests.swift`. These are measured recordings of
    the old name being spoken; renaming them would falsify the measurement. **This widens the
    spec's "exactly two files"**, for that reason.
- Monaco (`app/Resources/monaco/`) is third-party and is not touched.
- Throwaway output and helper scripts go in `.scratch/rename/`, which is excluded locally.
- The migration never prints a secret, never touches the login keychain in tests, and deletes an
  original Keychain item only after every copy has read back identical.
- Commits carry no `Co-Authored-By` trailer. Nothing is pushed or run against real data without
  the operator's yes.

## Review Focus

1. **A secret that is not plain text** (a trailing newline, non-ASCII). `security -w` would hand
   back a hex rendering, or `$(…)` would strip the newline, and the copy would silently differ.
   Expected: the script refuses that item and changes nothing. Covered by
   `TestMigrateRefusesASecretThatIsNotPlainText` in Task 1.
2. **Rafiq or Wakil running during the migration.** It holds state files open and may rewrite
   them. Expected: refusal. Covered by `TestMigrateRefusesWhileTheAppIsRunning` in Task 1.
3. **A project registered in an org whose `.rafiq/` folder is missing, or already moved.**
   Expected: the registry is still rewritten, the script says which project it skipped, and it
   does not fail. Covered by `TestMigrateMovesStateKeychainAndProjects` in Task 1 (one present
   project, one missing).
4. **An unrelated Keychain item that shares the prefix or the account** (`rafiq:x` held by another
   account, or account `rafiq` under another service). Expected: untouched. Covered by the same
   test's two decoy items.
5. **A substring rewrite that changes behavior**: a fixture whose bytes, hash or sort order depend
   on the name. Expected: the suites catch it, and it is fixed by reading the test, not by
   loosening it. Covered by Task 2's full suites, with no test deleted.

---

### Task 1: The migration script

**Files:**
- Create: `scripts/migrate-from-rafiq.sh`
- Test: `scripts/migrate_from_rafiq_test.go` (package `scripts`; reuses `mkdir`, `writeExecutable`
  and `asExitError` from `register_provider_test.go`)

**Interfaces:**
- Produces: `scripts/migrate-from-rafiq.sh [--reverse]`. It exits 0 on success and 1 on any
  refusal or failure, and writes a report to stdout. Environment: `MIGRATE_KEYCHAIN` (default
  `~/Library/Keychains/login.keychain-db`) and `MIGRATE_SECURITY` (default `/usr/bin/security`).
  It finds `pgrep` and `defaults` on `PATH`.

- [ ] **Step 1: Write the failing tests**

`scripts/migrate_from_rafiq_test.go`:

```go
package scripts

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The migration's tests run against a throwaway keychain and a temporary HOME.
// Nothing here reads or writes the login keychain or the operator's real state.

const migrateSecurity = "/usr/bin/security"

type migrateEnv struct {
	t           *testing.T
	home        string
	keychain    string
	bin         string
	defaultsLog string
	pgrepExit   string
}

func newMigrateEnv(t *testing.T) *migrateEnv {
	t.Helper()
	dir := t.TempDir()
	e := &migrateEnv{
		t:           t,
		home:        filepath.Join(dir, "home"),
		keychain:    filepath.Join(dir, "migrate.keychain-db"),
		bin:         filepath.Join(dir, "bin"),
		defaultsLog: filepath.Join(dir, "defaults.log"),
		pgrepExit:   "1",
	}
	mkdir(t, e.home)
	mkdir(t, e.bin)
	e.sec("create-keychain", "-p", "pw", e.keychain)
	t.Cleanup(func() { _ = exec.Command(migrateSecurity, "delete-keychain", e.keychain).Run() })
	e.sec("unlock-keychain", "-p", "pw", e.keychain)
	e.sec("set-keychain-settings", e.keychain)
	writeExecutable(t, filepath.Join(e.bin, "defaults"), `#!/bin/sh
printf '%s\n' "$*" >> "`+e.defaultsLog+`"
case "$1 $2" in
"read dev.rafiq.app") exit 0 ;;
"read "*) exit 1 ;;
"export "*) echo '<plist/>' ;;
esac
`)
	return e
}

func (e *migrateEnv) sec(args ...string) string {
	e.t.Helper()
	out, err := exec.Command(migrateSecurity, args...).CombinedOutput()
	if err != nil {
		e.t.Fatalf("security %s: %v: %s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func (e *migrateEnv) addItem(service, account, secret string) {
	e.t.Helper()
	e.sec("add-generic-password", "-s", service, "-a", account, "-w", secret, e.keychain)
}

// secret returns the item's password and whether it exists.
func (e *migrateEnv) secret(service, account string) (string, bool) {
	out, err := exec.Command(migrateSecurity, "find-generic-password", "-s", service, "-a", account, "-w", e.keychain).Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSuffix(string(out), "\n"), true
}

func (e *migrateEnv) write(rel, body string) string {
	e.t.Helper()
	p := filepath.Join(e.home, rel)
	mkdir(e.t, filepath.Dir(p))
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		e.t.Fatal(err)
	}
	return p
}

func (e *migrateEnv) run(args ...string) (string, error) {
	e.t.Helper()
	writeExecutable(e.t, filepath.Join(e.bin, "pgrep"), "#!/bin/sh\nexit "+e.pgrepExit+"\n")
	cmd := exec.Command("bash", append([]string{"migrate-from-rafiq.sh"}, args...)...)
	cmd.Env = append(os.Environ(),
		"HOME="+e.home,
		"PATH="+e.bin+":/usr/bin:/bin",
		"MIGRATE_KEYCHAIN="+e.keychain,
	)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// seed lays down a small Rafiq install: one org registering two projects (one
// whose .rafiq folder exists, one whose folder is gone), a journal line that
// mentions the old name, two items to migrate, and two decoys.
func (e *migrateEnv) seed() {
	proj := filepath.Join(e.home, "work", "api")
	e.write("work/api/.rafiq/project.json", `{"name":"api"}`)
	e.write(".rafiq/orgs/personal/projects.json",
		`{"api":{"path":"`+proj+`/.rafiq/project.json"},"gone":{"path":"`+e.home+`/work/gone/.rafiq/project.json"}}`)
	e.write(".rafiq/journal/a.jsonl", `{"note":"rafiq:personal:db:core was used"}`+"\n")
	e.addItem("rafiq:personal:db:core", "rafiq", "s3cret-one")
	e.addItem("rafiq:personal:jira:personal", "rafiq", "tok:two")
	e.addItem("rafiq:decoy", "someone-else", "keep-me")
	e.addItem("other-service", "rafiq", "keep-me-too")
}

func TestMigrateMovesStateKeychainAndProjects(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	out, err := e.run()
	if err != nil {
		t.Fatalf("migrate failed: %v\n%s", err, out)
	}
	for svc, want := range map[string]string{"wakil:personal:db:core": "s3cret-one", "wakil:personal:jira:personal": "tok:two"} {
		if got, ok := e.secret(svc, "wakil"); !ok || got != want {
			t.Errorf("%s = (%q, %v); want %q", svc, got, ok, want)
		}
	}
	for _, svc := range []string{"rafiq:personal:db:core", "rafiq:personal:jira:personal"} {
		if _, ok := e.secret(svc, "rafiq"); ok {
			t.Errorf("%s still exists after a successful migration", svc)
		}
	}
	if got, ok := e.secret("rafiq:decoy", "someone-else"); !ok || got != "keep-me" {
		t.Error("an item held by another account was touched")
	}
	if got, ok := e.secret("other-service", "rafiq"); !ok || got != "keep-me-too" {
		t.Error("an item under another service was touched")
	}
	if exists(filepath.Join(e.home, ".rafiq")) || !exists(filepath.Join(e.home, ".wakil", "orgs", "personal")) {
		t.Error("~/.rafiq was not moved to ~/.wakil")
	}
	reg, _ := os.ReadFile(filepath.Join(e.home, ".wakil", "orgs", "personal", "projects.json"))
	if strings.Contains(string(reg), "/.rafiq/") || !strings.Contains(string(reg), "/work/api/.wakil/project.json") {
		t.Errorf("projects.json not rewritten: %s", reg)
	}
	if !exists(filepath.Join(e.home, "work", "api", ".wakil", "project.json")) || exists(filepath.Join(e.home, "work", "api", ".rafiq")) {
		t.Error("the present project's .rafiq folder was not moved to .wakil")
	}
	if !strings.Contains(out, "work/gone") {
		t.Errorf("the missing project is not reported:\n%s", out)
	}
	journal, _ := os.ReadFile(filepath.Join(e.home, ".wakil", "journal", "a.jsonl"))
	if !strings.Contains(string(journal), "rafiq:personal:db:core was used") {
		t.Error("the journal is history and must not be rewritten")
	}
	log, _ := os.ReadFile(e.defaultsLog)
	if !strings.Contains(string(log), "export dev.rafiq.app -") || !strings.Contains(string(log), "import dev.wakil.app -") {
		t.Errorf("preferences not copied; defaults log:\n%s", log)
	}
	if strings.Contains(out, "s3cret-one") || strings.Contains(out, "tok:two") {
		t.Error("the report printed a secret")
	}
}

func TestMigrateReverseRestoresTheOriginal(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	if out, err := e.run(); err != nil {
		t.Fatalf("forward: %v\n%s", err, out)
	}
	if out, err := e.run("--reverse"); err != nil {
		t.Fatalf("reverse: %v\n%s", err, out)
	}
	if got, ok := e.secret("rafiq:personal:db:core", "rafiq"); !ok || got != "s3cret-one" {
		t.Error("--reverse did not restore the original item")
	}
	if _, ok := e.secret("wakil:personal:db:core", "wakil"); ok {
		t.Error("--reverse left the wakil item behind")
	}
	if !exists(filepath.Join(e.home, ".rafiq")) || exists(filepath.Join(e.home, ".wakil")) {
		t.Error("--reverse did not move the state back")
	}
	if !exists(filepath.Join(e.home, "work", "api", ".rafiq", "project.json")) {
		t.Error("--reverse did not move the project folder back")
	}
}

func TestMigrateRefusesWhenTheTargetExists(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	mkdir(t, filepath.Join(e.home, ".wakil"))
	if out, err := e.run(); err == nil || !strings.Contains(out, "already exists") {
		t.Fatalf("want a refusal naming the existing ~/.wakil; got err=%v\n%s", err, out)
	}
	if _, ok := e.secret("wakil:personal:db:core", "wakil"); ok {
		t.Error("a refusal still created a Keychain item")
	}
	if _, ok := e.secret("rafiq:personal:db:core", "rafiq"); !ok {
		t.Error("a refusal deleted an original")
	}
}

func TestMigrateRefusesWhileTheAppIsRunning(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	e.pgrepExit = "0"
	if out, err := e.run(); err == nil || !strings.Contains(out, "is running") {
		t.Fatalf("want a refusal while the app runs; got err=%v\n%s", err, out)
	}
	if !exists(filepath.Join(e.home, ".rafiq")) {
		t.Error("state moved while the app was running")
	}
}

func TestMigrateRefusesASecretThatIsNotPlainText(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	e.addItem("rafiq:personal:db:multiline", "rafiq", "line1\nline2")
	if out, err := e.run(); err == nil || !strings.Contains(out, "not plain text") {
		t.Fatalf("want a refusal for the multi-line secret; got err=%v\n%s", err, out)
	}
	if _, ok := e.secret("wakil:personal:db:core", "wakil"); ok {
		t.Error("the refusal left a half-migrated item behind")
	}
	if _, ok := e.secret("rafiq:personal:db:core", "rafiq"); !ok {
		t.Error("the refusal deleted an original")
	}
}

func TestMigrateRollsBackWhenACopyDoesNotReadBack(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	// A security wrapper that corrupts one write: everything else passes through.
	writeExecutable(t, filepath.Join(e.bin, "security-corrupting"), `#!/bin/sh
if [ "$1" = add-generic-password ] && [ "$3" = wakil:personal:jira:personal ]; then
	exec `+migrateSecurity+` add-generic-password -s "$3" -a "$5" -w corrupted "$8"
fi
exec `+migrateSecurity+` "$@"
`)
	t.Setenv("MIGRATE_SECURITY", filepath.Join(e.bin, "security-corrupting"))
	if out, err := e.run(); err == nil || !strings.Contains(out, "did not read back") {
		t.Fatalf("want a read-back failure; got err=%v\n%s", err, out)
	}
	for _, svc := range []string{"wakil:personal:db:core", "wakil:personal:jira:personal"} {
		if _, ok := e.secret(svc, "wakil"); ok {
			t.Errorf("rollback left %s behind", svc)
		}
	}
	for _, svc := range []string{"rafiq:personal:db:core", "rafiq:personal:jira:personal"} {
		if _, ok := e.secret(svc, "rafiq"); !ok {
			t.Errorf("rollback lost the original %s", svc)
		}
	}
	if !exists(filepath.Join(e.home, ".rafiq")) {
		t.Error("state moved although the Keychain step failed")
	}
}
```

The corrupting wrapper relies on the script calling
`add-generic-password -s <svc> -a <acct> -w <secret> <keychain>`, so the arguments are in
positions 3, 5, 7 and 8. The script below keeps that order.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd scripts && CGO_ENABLED=0 go test -run TestMigrate -count=1 . 2>&1 | tail -20`
Expected: FAIL in every `TestMigrate…`, because `bash: migrate-from-rafiq.sh: No such file or directory`.

- [ ] **Step 3: Write the script**

`scripts/migrate-from-rafiq.sh`:

```bash
#!/usr/bin/env bash
# migrate-from-rafiq — moves this Mac's Rafiq state to Wakil, once.
#
# The product was named Rafiq until 2026-10-15. This script and its test are the
# only code that still uses that name, on purpose: they exist to find the old
# state. Spec: docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md.
#
#   scripts/migrate-from-rafiq.sh            Rafiq -> Wakil
#   scripts/migrate-from-rafiq.sh --reverse  Wakil -> Rafiq (the rollback)
#
# Tests set MIGRATE_KEYCHAIN (default: the login keychain) and
# MIGRATE_SECURITY (default: /usr/bin/security). An operator never needs to.
#
# A secret passes through `security add-generic-password -w` on argv for the
# length of one call, the same trade-off rafiqcore.SecretSet documents: there is
# no cgo Keychain binding to hand it over any other way.
set -euo pipefail

from=rafiq; to=wakil; From=Rafiq; To=Wakil
if [ "${1:-}" = "--reverse" ]; then from=wakil; to=rafiq; From=Wakil; To=Rafiq; fi

keychain="${MIGRATE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
security="${MIGRATE_SECURITY:-/usr/bin/security}"

die() { echo "migrate: $*" >&2; exit 1; }

# 1. Refuse rather than overwrite.
for app in Rafiq Wakil; do
	if pgrep -x "$app" >/dev/null 2>&1; then die "$app is running; quit it first"; fi
done
[ -d "$HOME/.$from" ] || die "nothing to migrate: $HOME/.$from does not exist"
[ ! -e "$HOME/.$to" ] || die "$HOME/.$to already exists; refusing to overwrite it"

# 2. Keychain: copy every item, read every copy back, and only then delete the
#    originals. Any failure deletes the copies made so far and changes nothing else.
services=$("$security" dump-keychain "$keychain" | FROM="$from" perl -ne '
	BEGIN { $/ = "keychain: " }
	next unless /^class: "genp"/m;
	next unless /^\s*"acct"<blob>="\Q$ENV{FROM}\E"$/m;
	if (/^\s*"svce"<blob>=0x/m) { print "UNPRINTABLE\n"; next }
	print "$1\n" if /^\s*"svce"<blob>="(\Q$ENV{FROM}\E:[^"\n]*)"$/m;
')
if grep -qx UNPRINTABLE <<<"$services"; then
	die "a $from Keychain item has a service name that is not plain text; move it by hand"
fi

created=()
rollback() {
	for svc in ${created[@]+"${created[@]}"}; do
		"$security" delete-generic-password -s "$svc" -a "$to" "$keychain" >/dev/null 2>&1 || true
	done
}

count=0
while IFS= read -r svc; do
	[ -n "$svc" ] || continue
	new="$to${svc#"$from"}"
	raw=$("$security" find-generic-password -s "$svc" -a "$from" -g "$keychain" 2>&1 >/dev/null) \
		|| { rollback; die "could not read $svc"; }
	case "$raw" in *"password: 0x"*) rollback; die "$svc holds a secret that is not plain text; move it by hand";; esac
	secret=$("$security" find-generic-password -s "$svc" -a "$from" -w "$keychain") \
		|| { rollback; die "could not read $svc"; }
	"$security" add-generic-password -s "$new" -a "$to" -w "$secret" "$keychain" \
		|| { rollback; die "could not add $new (does it already exist?)"; }
	created+=("$new")
	back=$("$security" find-generic-password -s "$new" -a "$to" -w "$keychain") \
		|| { rollback; die "could not read back $new"; }
	[ "$back" = "$secret" ] || { rollback; die "$new did not read back what was written; nothing was deleted"; }
	count=$((count + 1))
done <<<"$services"

while IFS= read -r svc; do
	[ -n "$svc" ] || continue
	"$security" delete-generic-password -s "$svc" -a "$from" "$keychain" >/dev/null
done <<<"$services"
echo "keychain: moved $count item(s) from $from: to $to:"

# 3. State, then each registered project's folder. The journal is history and
#    is not rewritten; only the org files' project paths are.
mv "$HOME/.$from" "$HOME/.$to"
echo "state: moved ~/.$from to ~/.$to"
while IFS= read -r -d '' f; do
	if grep -q "/\.$from/project\.json" "$f"; then
		FROM="$from" TO="$to" perl -pi -e 's{/\.\Q$ENV{FROM}\E/project\.json}{/.$ENV{TO}/project.json}g' "$f"
		echo "  rewrote ${f#"$HOME/"}"
	fi
done < <(find "$HOME/.$to/orgs" -name '*.json' -print0 2>/dev/null)

find "$HOME/.$to/orgs" -name projects.json -print0 2>/dev/null \
	| xargs -0 cat 2>/dev/null \
	| TO="$to" perl -ne 'print "$1\n" while m{"path"\s*:\s*"([^"]+)/\.\Q$ENV{TO}\E/project\.json"}g' \
	| sort -u | while IFS= read -r dir; do
		if [ -d "$dir/.$from" ] && [ ! -e "$dir/.$to" ]; then
			mv "$dir/.$from" "$dir/.$to"
			echo "  project: moved $dir/.$from to .$to (commit it in that repository if it is tracked)"
		elif [ -d "$dir/.$to" ]; then
			echo "  project: $dir already has .$to"
		else
			echo "  project: $dir/.$from not found; left as it is"
		fi
	done

# 4. Preferences. The old domains stay: they are harmless, and they are the only
#    rollback for window state.
for pair in "dev.$from.app dev.$to.app" "${From}App ${To}App"; do
	set -- $pair
	if defaults read "$1" >/dev/null 2>&1; then
		defaults export "$1" - | defaults import "$2" -
		echo "defaults: copied $1 to $2"
	fi
done

# 5. What this script does not touch.
echo "Not changed; check these yourself:"
for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME"/.claude*/settings.json "$HOME"/.claude*/.claude.json; do
	if [ -f "$f" ] && grep -qi "$from" "$f"; then echo "  $f mentions $from"; fi
done
echo "  Re-run scripts/register-provider.sh for each org and provider, so Claude's MCP"
echo "  config names the $to-* servers."
```

Run: `chmod +x scripts/migrate-from-rafiq.sh`

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd scripts && CGO_ENABLED=0 go test -run TestMigrate -count=1 -v . 2>&1 | grep -E '^(=== RUN|--- |ok|FAIL)'`
Expected: six `--- PASS`, then `ok`. Then run `security list-keychains` and confirm no
`migrate.keychain-db` is left on the search list.

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-from-rafiq.sh scripts/migrate_from_rafiq_test.go
git commit -m "Scripts: migrate-from-rafiq moves this Mac's Keychain items, state, project files and preferences to Wakil, all-or-nothing, with --reverse"
```

---

### Task 2: The rename

**Files:**
- Move: all 637 tracked paths containing the old name (`cmd/rafiq*`, `internal/rafiqcore`,
  `app/Sources/Rafiq*`, `app/Tests/RafiqKitTests`, `docs/rafiq`, `e2e/cmd/rafiq-*`,
  `e2e/driver/liverafiq*.go`, `docs/architecture/rafiq*.md`, one phase-1 plan), except the
  allowed files in Global Constraints.
- Modify: every tracked text file, except Monaco and the allowed files.
- Hand-edit: `docs/superpowers/specs/2026-10-15-public-repo-split-design.md`,
  `docs/superpowers/plans/2026-10-15-public-repo-split.md`, and `IdentifierCorpusTests.swift`'s
  non-truth lines.
- Outside the tree: move `~/.config/rafiq/public-denylist.txt` to `~/.config/wakil/`.

**Interfaces:**
- Consumes: nothing from Task 1's code (the script names both prefixes literally).
- Produces: binaries `wakil`, `wakil-ctx`, `wakil-db`, `wakil-files`, `wakil-git`, `wakil-http`,
  `wakil-pm`, `wakil-recall`; Go package `internal/wakilcore`; Swift targets `WakilKit`,
  `WakilApp` and `WakilKitTests`; `app/Wakil.app`; `public-check.sh` reading `WAKIL_DENYLIST`.

- [ ] **Step 1: Write the rename check, and watch it fail**

`.scratch/rename/check.sh` (throwaway, not committed):

```bash
#!/usr/bin/env bash
# Lists every tracked path or line that still names the old product, outside the allowed files.
cd "$(git rev-parse --show-toplevel)"
allow=(':!app/Resources/monaco' ':!scripts/migrate-from-rafiq.sh' ':!scripts/migrate_from_rafiq_test.go'
  ':!docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md'
  ':!docs/superpowers/plans/2026-10-15-rename-to-wakil.md'
  ':!docs/superpowers/specs/2026-10-15-public-repo-split-design.md'
  ':!docs/superpowers/plans/2026-10-15-public-repo-split.md'
  ':!scripts/probe/stt-2026-10-06-apple.tsv' ':!scripts/probe/stt-set2/apple-2026-10-06.tsv'
  ':!scripts/probe/stt-set2/utterances.tsv' ':!scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt'
  ':!app/Tests/*/IdentifierCorpusTests.swift')
paths=$(git ls-files -- . "${allow[@]}" | grep -i rafiq)
lines=$(git grep -niI rafiq -- . "${allow[@]}")
corpus=$(git grep -n -i rafiq -- 'app/Tests/*/IdentifierCorpusTests.swift' | grep -v '^\S*:4[4-9]:\|^\S*:5[0-2]:')
[ -z "$paths$lines$corpus" ] && { echo "rename clean"; exit 0; }
printf '%s\n' "$paths" "$lines" "$corpus" | grep -v '^$' | head -40
echo "rename-check: $(printf '%s\n' "$paths" "$lines" "$corpus" | grep -cv '^$') hit(s)" >&2
exit 1
```

The corpus line filter allows only lines 44–52 (the `setOneTruth` literal) once the file is
renamed. Confirm those line numbers with `grep -n setOneTruth` after Step 3, and adjust the
filter if they moved.

Run: `bash .scratch/rename/check.sh; echo "rc=$?"`
Expected: `rc=1` and some thousands of hits.

- [ ] **Step 2: Move every path**

```bash
git ls-files -- . ':!app/Resources/monaco' ':!scripts/migrate-from-rafiq.sh' ':!scripts/migrate_from_rafiq_test.go' \
  ':!docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md' ':!docs/superpowers/plans/2026-10-15-rename-to-wakil.md' \
  | grep -i rafiq > .scratch/rename/paths.txt
wc -l < .scratch/rename/paths.txt     # expect 637
while IFS= read -r old; do
  new=$(printf '%s' "$old" | perl -pe 's/Rafiq/Wakil/g; s/rafiq/wakil/g; s/RAFIQ/WAKIL/g')
  mkdir -p "$(dirname "$new")"
  git mv "$old" "$new"
done < .scratch/rename/paths.txt
find . -type d -empty -path '*rafiq*' -not -path './.git/*' -delete
git ls-files | grep -ic rafiq   # expect 2: the migration script and its test
git commit -q -m "Rename: move every path from Rafiq to Wakil (contents follow in the next commit)"
```

- [ ] **Step 3: Rewrite the contents**

`.scratch/rename/rewrite.pl` (throwaway):

```perl
#!/usr/bin/perl -pi
# Case-preserving rename. The module path goes first, so the generic rule can't produce
# github.com/yehia/wakil. In IdentifierCorpusTests.swift the setOneTruth literal is
# measured data and is skipped.
if ($ARGV =~ /IdentifierCorpusTests\.swift$/) {
  if (/^private let setOneTruth/ .. /^\]/) { next }
}
s{github\.com/yehia/rafiq}{github.com/yehia-khalil/wakil}g;
s/Rafiq/Wakil/g; s/rafiq/wakil/g; s/RAFIQ/WAKIL/g;
```

```bash
git ls-files -z -- . ':!app/Resources/monaco' ':!scripts/migrate-from-rafiq.sh' ':!scripts/migrate_from_rafiq_test.go' \
  ':!docs/superpowers/specs/2026-10-15-rename-to-wakil-design.md' ':!docs/superpowers/plans/2026-10-15-rename-to-wakil.md' \
  ':!docs/superpowers/specs/2026-10-15-public-repo-split-design.md' ':!docs/superpowers/plans/2026-10-15-public-repo-split.md' \
  ':!scripts/probe/stt-2026-10-06-apple.tsv' ':!scripts/probe/stt-set2/apple-2026-10-06.tsv' \
  ':!scripts/probe/stt-set2/utterances.tsv' ':!scripts/probe/stt-set2/vocab-snapshot-2026-10-06.txt' \
  | xargs -0 grep -lIi rafiq -- 2>/dev/null | tr '\n' '\0' | xargs -0 perl -pi .scratch/rename/rewrite.pl
gofmt -l cmd internal e2e scripts | xargs -r gofmt -w
grep -n '^module' go.mod    # expect: module github.com/yehia-khalil/wakil
```

- [ ] **Step 4: Move the denylist and point public-check at it**

```bash
mkdir -p ~/.config/wakil && mv ~/.config/rafiq/public-denylist.txt ~/.config/wakil/ && rmdir ~/.config/rafiq
perl -pi -e 's{^allow:github\\\.com/yehia/rafiq$}{allow:github\\.com/yehia-khalil/wakil}' ~/.config/wakil/public-denylist.txt
grep -n 'WAKIL_DENYLIST\|config/wakil' scripts/public-check.sh   # expect both, from Step 3
scripts/public-check.sh; echo "rc=$?"                            # expect 0
```

- [ ] **Step 5: Hand-edit the four files the rewrite skipped**

- `docs/superpowers/specs/2026-10-15-public-repo-split-design.md`: in **Cutover**, step 2 becomes
  "Archive `yehia-khalil/rafiq` where it stands; it is not renamed." Step 3 becomes "Create a
  new **private** `yehia-khalil/wakil` and push the single commit." Drop the sentence about
  reusing the name. The denylist path becomes `~/.config/wakil/public-denylist.txt`.
- `docs/superpowers/plans/2026-10-15-public-repo-split.md`, Task 8:
  - Step 3 becomes `gh repo archive yehia-khalil/rafiq --yes`.
  - Step 4 creates `yehia-khalil/wakil`, with `--source ~/Desktop/scripts/wakil-public`.
  - Step 2's export directory becomes `~/Desktop/scripts/wakil-public`.
  - Every `RAFIQ_DENYLIST` becomes `WAKIL_DENYLIST`, and every `~/.config/rafiq` becomes
    `~/.config/wakil`.
  - Steps 6–8 use `yehia-khalil/wakil` for the new repository and `yehia-khalil/rafiq` for the
    archive.
- `app/Tests/WakilKitTests/IdentifierCorpusTests.swift`: check that the rewrite changed
  `@testable import` and the comments, and left the `setOneTruth` values alone.

Run: `bash .scratch/rename/check.sh; echo "rc=$?"`
Expected: `rename clean`, `rc=0`.

- [ ] **Step 6: Build and run every suite**

```bash
make build > .scratch/rename/build.log 2>&1; echo "build rc=$?"; ls bin
CGO_ENABLED=0 go test ./... > .scratch/rename/go.log 2>&1; echo "go rc=$?"
make app-test > .scratch/rename/app.log 2>&1; echo "app rc=$?"
make app-bundle > .scratch/rename/bundle.log 2>&1; echo "bundle rc=$?"; ls app/Wakil.app/Contents/MacOS
```

Expected: every `rc=0`. `bin/` holds the eight `wakil*` binaries, and `app/Wakil.app/Contents/MacOS/Wakil`
exists. Capture each status with `rc=$?`; never pipe the run into `tail`.

A failure here is a test whose data depended on the name. Read the test, fix the data or the
expectation so the test still proves what it proved before, and rerun. Do not delete or skip a
test. If `app-test` fails once in a timing test, rerun that suite alone before treating it as
real (the suites flake under load).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Rename: Rafiq is now Wakil — binaries, packages, targets, bundle ids, env vars, Keychain service and state paths"
bash .scratch/rename/check.sh && scripts/public-check.sh && echo "both clean"
```

---

### Task 3: Review and the PR

- [ ] **Step 1: Whole-branch review** by a fresh reviewer (most capable model), with this plan's
  Review Focus. Fix Critical and Important findings in one pass, each with a test that failed
  first, and rerun Task 2, Step 6.

- [ ] **Step 2: Draft the PR for the operator.** The title is "Rename Rafiq to Wakil". The body
  covers the mapping table, the allowed old-name files and why, the migration script and its six
  tests, the gate results, and the instruction to run `scripts/migrate-from-rafiq.sh` once after
  merging. Push and open the PR **only after sign-off**.

---

### Task 4: Migrate this Mac (operator, after the merge)

Each step waits for the operator's yes. None is reversible by `git`.

- [ ] **Step 1: Back up first.** `cp -R ~/.rafiq ~/.rafiq.bak-2026-10-15`, then
  `security export -k ~/Library/Keychains/login.keychain-db -t identities -o /dev/null` to confirm
  the keychain is unlocked. The script's `--reverse` is the Keychain rollback.
- [ ] **Step 2: Quit Rafiq**, build from `main` (`make build app-bundle`), then run
  `scripts/migrate-from-rafiq.sh`. Expected: `keychain: moved 50 item(s)`, then the state and
  project lines, then the not-changed list.
- [ ] **Step 3: Re-register MCP servers** for each org and provider it lists:
  `scripts/register-provider.sh <org> <provider> "$PWD/bin"`.
- [ ] **Step 4: Launch `app/Wakil.app`** (a GUI run, so ask first). Expected: the same org list,
  and one secret-backed action (a db query) works in each org.
- [ ] **Step 5: Then resume the public-split plan at Task 8**, which now creates `yehia-khalil/wakil`.
