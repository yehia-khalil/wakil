package wakilcore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestPickDatabase(t *testing.T) {
	env := Environment{Databases: []Database{
		{Name: "core", Driver: "mysql", Ref: "a"},
		{Name: "events", Driver: "sqlite", Ref: "b"},
	}}
	if _, err := PickDatabase(env, ""); err == nil {
		t.Fatal("ambiguous empty name with 2 dbs must error")
	}
	d, err := PickDatabase(env, "events")
	if err != nil || d.Driver != "sqlite" {
		t.Fatalf("pick events: %+v %v", d, err)
	}
	single := Environment{Databases: []Database{{Name: "only", Driver: "sqlite", Ref: "x"}}}
	d, err = PickDatabase(single, "")
	if err != nil || d.Name != "only" {
		t.Fatalf("single default: %+v %v", d, err)
	}
	if _, err := PickDatabase(env, "nope"); err == nil {
		t.Fatal("unknown name must error")
	}
}

func TestPickDatabaseNoDatabasesIsUserError(t *testing.T) {
	env := Environment{}
	_, err := PickDatabase(env, "anything")
	if err == nil {
		t.Fatal("empty environment must error")
	}
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
}

func TestPickDatabaseAmbiguousEmptyNameIsUserError(t *testing.T) {
	env := Environment{Databases: []Database{
		{Name: "core", Driver: "mysql", Ref: "a"},
		{Name: "events", Driver: "sqlite", Ref: "b"},
	}}
	_, err := PickDatabase(env, "")
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
}

func TestPickDatabaseUnknownNameIsUserError(t *testing.T) {
	env := Environment{Databases: []Database{{Name: "core", Driver: "mysql", Ref: "a"}}}
	_, err := PickDatabase(env, "nope")
	if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
}

// TestPickDatabaseDuplicateNameIsAmbiguous pins down the collision case:
// two databases sharing a name must never silently resolve to "whichever
// one happens to be first in the slice" — that hides which connection the
// caller actually got. A duplicate name must be reported as an error
// naming the collision, exactly like the "no such name" and "ambiguous
// empty name" cases above.
func TestPickDatabaseDuplicateNameIsAmbiguous(t *testing.T) {
	env := Environment{Databases: []Database{
		{Name: "core", Driver: "mysql", Ref: "a"},
		{Name: "core", Driver: "sqlite", Ref: "b"},
	}}
	_, err := PickDatabase(env, "core")
	if err == nil {
		t.Fatal("duplicate database name must error, not silently pick the first match")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if !strings.Contains(msg, "core") {
		t.Fatalf("expected the error to name the colliding database, got %q", msg)
	}
}

// TestOpenDatabaseUnknownDriverFailsBeforeSecretGet pins the order of
// operations inside OpenDatabase: GetDriver is called and can fail before
// SecretGet is ever invoked. This matters because SecretGet shells out to
// the real macOS login Keychain — a typo'd driver name must never trigger
// a Keychain lookup (or, worse, an unlock prompt) for a database that was
// never going to work anyway.
//
// SecretGet isn't a var, so it can't be swapped out for a fake from a
// test without changing production code, which is out of scope here.
// Instead this test relies on the fact that GetDriver's and SecretGet's
// error messages are textually disjoint: GetDriver's is "no driver for
// database kind: ..." while every SecretGet failure mentions "keychain" or
// "credential" (see internal/wakilcore/secrets.go). If OpenDatabase's
// GetDriver/SecretGet calls were ever reordered so SecretGet ran first, Ref
// "x" (never stored under any ref used by this suite) would produce a
// Keychain-flavored error instead, and this test would fail as designed by
// noticing the message doesn't match the expected shape.
//
// t.Setenv("PATH", t.TempDir()) below closes the actual hazard this test
// exists to prevent: without it, a reordered OpenDatabase would shell out
// to the REAL /usr/bin/security before failing (a genuine, if fast,
// Keychain lookup against the developer's own login Keychain, on every
// test run, for every developer). Pointing PATH at an empty temp dir means
// `security` resolves to nothing at all, so a reorder fails inside
// exec.Command itself ("executable file not found in $PATH") without ever
// touching the real binary — and that failure still contains "keychain"
// (from SecretGet's own wrapping message), so the guard below still fires
// correctly on a reorder. No fake `security` binary is needed for this
// case, since GetDriver failing first means SecretGet must never run at
// all under correct code.
func TestOpenDatabaseUnknownDriverFailsBeforeSecretGet(t *testing.T) {
	t.Setenv("WAKIL_SECURITY_BINARY", filepath.Join(t.TempDir(), "security"))

	_, err := OpenDatabase(context.Background(), Database{Driver: "no-such-driver-kind-task13", Ref: "x"})
	if err == nil {
		t.Fatal("expected an error for an unregistered driver kind")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v (%T)", err, err)
	}
	if !strings.Contains(msg, "no driver for database kind") {
		t.Fatalf("expected the no-driver error (proving GetDriver ran and failed first), got %q", msg)
	}
	if strings.Contains(msg, "keychain") || strings.Contains(msg, "credential") {
		t.Fatalf("error mentions the keychain/credential path, which would mean SecretGet ran before GetDriver: %q", msg)
	}
}

// fakeTestConn is a no-op Conn returned by fakeTestDriver.Connect so
// OpenDatabase can complete successfully in tests without touching any
// real database.
type fakeTestConn struct{}

func (fakeTestConn) ListColumns(ctx context.Context) ([]TableColumns, error) { return nil, nil }
func (fakeTestConn) ListContainers(ctx context.Context) ([]Container, error) { return nil, nil }
func (fakeTestConn) Describe(ctx context.Context, name string) (Schema, error) {
	return Schema{}, nil
}
func (fakeTestConn) Read(ctx context.Context, spec QuerySpec, limit int) (Rows, error) {
	return Rows{}, nil
}
func (fakeTestConn) ReadTable(context.Context, string, int, int, []QuerySort) (Rows, error) {
	return Rows{}, nil
}

// PrimaryKey exists only to satisfy the Conn interface, not to model a
// real driver's keyness — this fake never has one.
func (fakeTestConn) PrimaryKey(context.Context, string) ([]string, error) {
	return nil, nil
}

// Write exists only to satisfy the Conn interface, not to model a real
// driver's write path — this fake is used solely to exercise OpenDatabase's
// read-only resolution plumbing, which never calls Write.
func (fakeTestConn) Write(ctx context.Context, spec QuerySpec) (Written, error) {
	return Written{}, UserError("fake: write not implemented")
}

func (fakeTestConn) Close() error { return nil }

// testFakeDriverKind is a clearly test-only driver kind name. RegisterDriver
// panics on a duplicate registration and offers no unregister, so this name
// must never collide with a kind used anywhere else in the suite.
const testFakeDriverKind = "wakil-test-fake-driver-task13-dbresolve"

var (
	fakeDriverRegisterOnce sync.Once
	fakeDriverMu           sync.Mutex
	fakeDriverGotConn      Connection
)

// fakeTestDriver records the Connection it was asked to Connect with, so
// tests can assert OpenDatabase threaded Ref/URL/ReadOnly through correctly.
type fakeTestDriver struct{}

func (fakeTestDriver) Kind() string { return testFakeDriverKind }

func (fakeTestDriver) Connect(ctx context.Context, conn Connection) (Conn, error) {
	fakeDriverMu.Lock()
	fakeDriverGotConn = conn
	fakeDriverMu.Unlock()
	return fakeTestConn{}, nil
}

func (fakeTestDriver) AssertReadOnly(spec QuerySpec) error { return nil }

// ConnectWritable and AssertMutation exist only to satisfy DbDriver; this
// fake is used solely to exercise OpenDatabase's read-only resolution
// plumbing, which never calls either.
func (fakeTestDriver) ConnectWritable(ctx context.Context, conn Connection) (Conn, error) {
	return nil, UserError("fakeTestDriver: ConnectWritable not implemented")
}

func (fakeTestDriver) AssertMutation(spec QuerySpec) error {
	return UserError("fakeTestDriver: AssertMutation not implemented")
}

// fakeSecurityBinary writes a fake `security` executable to a temp dir,
// prepends only that dir to PATH for the duration of the test, and returns
// the fixed DSN string the fake binary will report for any
// `find-generic-password ... -w` invocation, plus the path to a file the
// script records its own argv into. This makes SecretGet's
// `exec.Command("security", ...)` resolve to a script under the test's
// control instead of the real `/usr/bin/security` binary, so the test can
// observe a real SecretGet success (needed to test that OpenDatabase
// threads the resolved URL through) without ever touching the actual
// macOS login Keychain. The same PATH-substitution technique is already
// used the other way around (to simulate `security` being absent) by
// TestSecretGetMissingSecurityBinary in secrets_test.go.
//
// The script records "$@" to argsFile before printing the DSN, so a
// caller can verify SecretGet actually invoked `security` with the
// expected `-s <service>` argument — not merely that *some* invocation of
// `security` succeeded and returned the fixed DSN, which would pass just
// as well if SecretGet queried the wrong service name.
func fakeSecurityBinary(t *testing.T) (dsn, argsFile string) {
	t.Helper()
	const fakeDSN = "fake-dsn://wakil-test-task13"
	dir := t.TempDir()
	script := filepath.Join(dir, "security")
	argsPath := filepath.Join(dir, "security-args.txt")
	body := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$@\" > \"%s\"\nprintf '%%s' %q\n", argsPath, fakeDSN)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write fake security binary: %v", err)
	}
	// **`WAKIL_SECURITY_BINARY`, not PATH** (2e, #201). The product now
	// invokes the Keychain tool by its absolute path, because the ACL on
	// the CLI's own item names `/usr/bin/security` and a bare name
	// resolved off PATH is a different application to that ACL. A
	// PATH-based fake stopped intercepting the moment that landed — and
	// would have pointed this test at the operator's real login keychain
	// while still passing.
	t.Setenv("WAKIL_SECURITY_BINARY", script)
	return fakeDSN, argsPath
}

// wantSecurityServiceArg fails t unless the fake security script recorded
// at argsFile was invoked with "-s <wantService>" somewhere in its
// argument list — i.e. that SecretGet actually queried the expected
// Keychain service name, not just that some call to `security` happened to
// succeed.
//
// Callers must pass a LITERAL expected service name, never
// keychainService(org, ref). That name is a persistence key: it is the address
// under which real credentials already live in users' login Keychains
// (see secrets.go, used by both SecretGet and SecretSet), so changing the
// scheme orphans every stored credential. Deriving the expectation from
// the same function under test would make this assertion self-referential
// and let exactly that silent migration through.
func wantSecurityServiceArg(t *testing.T, argsFile, wantService string) {
	t.Helper()
	raw, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("read fake security invocation args: %v", err)
	}
	args := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	for i, a := range args {
		if a == "-s" && i+1 < len(args) && args[i+1] == wantService {
			return
		}
	}
	t.Fatalf("fake security invocation args %v do not contain \"-s %s\" — SecretGet did not query the expected keychain service", args, wantService)
}

// TestOpenDatabaseThreadsConnectionFields pins that Ref, URL (resolved via
// SecretGet) and ReadOnly all flow unchanged from the Database argument (and
// the Keychain secret) into the Connection handed to the driver's Connect
// method. It also pins the LITERAL Keychain service name SecretGet queries,
// "wakil:<org>:<ref>" — not just that some `security` invocation happened to
// succeed, and deliberately not via keychainService, so a change to the
// naming scheme fails here rather than silently orphaning stored
// credentials. (It did exactly that when the org was added to the scheme:
// this assertion is the tripwire that made the migration a decision rather
// than an accident.)
//
// WAKIL_ORG is pinned because the org is now part of that name, so
// leaving it inherited would make the expected service name depend on the
// shell the suite happens to run in.
func TestOpenDatabaseThreadsConnectionFields(t *testing.T) {
	fakeDriverRegisterOnce.Do(func() { RegisterDriver(testFakeDriverKind, fakeTestDriver{}) })

	t.Setenv("WAKIL_ORG", "initech")
	wantURL, argsFile := fakeSecurityBinary(t)

	d := Database{Driver: testFakeDriverKind, Ref: "task13-test-ref"}
	conn, err := OpenDatabase(context.Background(), d)
	if err != nil {
		t.Fatalf("OpenDatabase: %v", err)
	}
	if conn == nil {
		t.Fatal("expected a non-nil Conn")
	}
	defer conn.Close()

	wantSecurityServiceArg(t, argsFile, "wakil:initech:"+d.Ref)

	fakeDriverMu.Lock()
	got := fakeDriverGotConn
	fakeDriverMu.Unlock()

	if got.Ref != d.Ref {
		t.Errorf("Connection.Ref = %q, want %q", got.Ref, d.Ref)
	}
	if got.URL != wantURL {
		t.Errorf("Connection.URL = %q, want %q", got.URL, wantURL)
	}
	// Unconditionally true, not copied from the Database: OpenDatabase is
	// the read-only route by definition, and the per-database flag it used
	// to read was removed for asserting a protection it did not provide
	// (issue #14).
	if !got.ReadOnly {
		t.Error("OpenDatabase must label its Connection read-only unconditionally")
	}
}

// No writeRef means the database cannot be mutated by anything, by anyone.
// The refusal must happen WITHOUT reading the Keychain: this test would
// otherwise touch the operator's login keychain, which no test here may do,
// so a passing run is itself the evidence that no lookup was attempted.
func TestOpenDatabaseWritableRefusesWithoutAWriteRef(t *testing.T) {
	d := Database{Name: "orders", Driver: "sqlite", Ref: "db:staging"}
	_, err := OpenDatabaseWritable(context.Background(), d)
	if err == nil {
		t.Fatal("a database with no writeRef must not be mutable")
	}
	for _, want := range []string{"orders", "writeRef"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message should name %q, got %q", want, err)
		}
	}
}

// The driver is resolved before the credential, so an unknown driver is
// reported as an unknown driver rather than as a missing secret.
func TestOpenDatabaseWritableRefusesAnUnknownDriver(t *testing.T) {
	d := Database{Name: "orders", Driver: "postgres", Ref: "db:staging", WriteRef: "db:staging:write"}
	if _, err := OpenDatabaseWritable(context.Background(), d); err == nil {
		t.Fatal("an unknown driver must fail")
	}
}

// TestOpenDatabaseThreadsWritability pins that Connection.Writable is
// derived from the database's writeRef and nothing else.
//
// **Writable is advertisement, never permission**, and the distinction is
// the whole reason it is a SECOND field rather than a reuse of ReadOnly.
// ReadOnly was demoted to a label (issue #14) precisely because a driver
// branching on a config-supplied boolean makes the unconditional read-only
// gate conditional. Writable must never be consulted by any gate for the
// same reason; its only job is to let a read say whether an edit could
// ever succeed, so a surface does not offer one that OpenDatabaseWritable
// will refuse.
func TestOpenDatabaseThreadsWritability(t *testing.T) {
	fakeDriverRegisterOnce.Do(func() { RegisterDriver(testFakeDriverKind, fakeTestDriver{}) })
	t.Setenv("WAKIL_ORG", "initech")
	_, argsFile := fakeSecurityBinary(t)
	_ = argsFile

	for _, tc := range []struct {
		name     string
		writeRef string
		want     bool
	}{
		{"no writeRef is not writable", "", false},
		{"a writeRef is writable", "orders-write", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := Database{Driver: testFakeDriverKind, Ref: "read-ref", WriteRef: tc.writeRef}
			conn, err := OpenDatabase(context.Background(), d)
			if err != nil {
				t.Fatalf("OpenDatabase: %v", err)
			}
			defer conn.Close()

			fakeDriverMu.Lock()
			got := fakeDriverGotConn
			fakeDriverMu.Unlock()

			if got.Writable != tc.want {
				t.Errorf("Connection.Writable = %v, want %v", got.Writable, tc.want)
			}
			// Unchanged by any of this: the read route is still
			// labelled read-only whatever the write credential says.
			if !got.ReadOnly {
				t.Error("the read route must stay labelled read-only")
			}
		})
	}
}
