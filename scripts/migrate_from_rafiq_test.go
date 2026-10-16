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
	pgrepMatch  string // a substring of pgrep's arguments that "finds" a process
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
	writeExecutable(e.t, filepath.Join(e.bin, "pgrep"), "#!/bin/sh\nm='"+e.pgrepMatch+"'\ncase \"$*\" in *\"$m\"*) [ -n \"$m\" ] && exit 0;; esac\nexit 1\n")
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
	e.pgrepMatch = "Rafiq"
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

func TestMigrateRefusesWhileTheUnbundledAppIsRunning(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	e.pgrepMatch = "RafiqApp"
	if out, err := e.run(); err == nil || !strings.Contains(out, "is running") {
		t.Fatalf("want a refusal while `swift run RafiqApp` runs; got err=%v\n%s", err, out)
	}
}

// An open Claude session keeps rafiq-* MCP servers alive, and they recreate
// ~/.rafiq the moment it is gone.
func TestMigrateRefusesWhileAnMCPServerIsRunning(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	e.pgrepMatch = "(rafiq|wakil)"
	if out, err := e.run(); err == nil || !strings.Contains(out, "server") {
		t.Fatalf("want a refusal naming the running servers; got err=%v\n%s", err, out)
	}
	if !exists(filepath.Join(e.home, ".rafiq")) {
		t.Error("state moved while a server was running")
	}
}

func TestMigrateFinishesWhenThereAreNoOrgs(t *testing.T) {
	e := newMigrateEnv(t)
	e.write(".rafiq/journal/a.jsonl", "{}\n")
	out, err := e.run()
	if err != nil {
		t.Fatalf("a state with no orgs/ must still migrate; got %v\n%s", err, out)
	}
	if !strings.Contains(out, "Not changed") {
		t.Errorf("the run stopped before its report:\n%s", out)
	}
}

func TestMigrateSaysWhatIsLeftWhenAnOriginalWillNotDelete(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	writeExecutable(t, filepath.Join(e.bin, "security-stubborn"), `#!/bin/sh
if [ "$1" = delete-generic-password ] && [ "$3" = rafiq:personal:jira:personal ]; then exit 1; fi
exec `+migrateSecurity+` "$@"
`)
	t.Setenv("MIGRATE_SECURITY", filepath.Join(e.bin, "security-stubborn"))
	out, err := e.run()
	if err == nil || !strings.Contains(out, "rafiq:personal:jira:personal") || !strings.Contains(out, "copies are in place") {
		t.Fatalf("want a failure naming the original that remains; got err=%v\n%s", err, out)
	}
	if got, ok := e.secret("wakil:personal:jira:personal", "wakil"); !ok || got != "tok:two" {
		t.Error("the copy must survive a failed delete of its original")
	}
}

func TestMigrateReportsTheOldTestContainers(t *testing.T) {
	e := newMigrateEnv(t)
	e.seed()
	writeExecutable(t, filepath.Join(e.bin, "docker"), "#!/bin/sh\nprintf 'rafiq-acc-mysql\\nunrelated\\n'\n")
	out, err := e.run()
	if err != nil {
		t.Fatalf("migrate failed: %v\n%s", err, out)
	}
	if !strings.Contains(out, "rafiq-acc-mysql") || strings.Contains(out, "unrelated") {
		t.Errorf("want the old test container named, and only it:\n%s", out)
	}
}
