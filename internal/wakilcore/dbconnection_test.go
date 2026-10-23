package wakilcore

import (
	"context"
	"strings"
	"sync"
	"testing"
)

// The strings pinned here are the ones the Swift form used to build
// (app/Tests/WakilKitTests/DatabaseConnectionStringTests.swift) and the
// ones connfields_test.go feeds to the real parsers; the sentences are
// ported verbatim.

func parts(host, port, database string) DatabaseConnection {
	return DatabaseConnection{Host: host, Port: port, Database: database}
}

func TestBuildConnectionStringPerDriver(t *testing.T) {
	cases := []struct {
		name     string
		driver   string
		conn     DatabaseConnection
		user     string
		password string
		want     string
	}{
		{"mysql is the driver's own form", "mysql", parts("db.internal", "", "orders"), "reader", "s3cret",
			"reader:s3cret@tcp(db.internal:3306)/orders"},
		{"mysql explicit port", "mysql", parts("db.internal", "3307", "orders"), "reader", "s3cret",
			"reader:s3cret@tcp(db.internal:3307)/orders"},
		{"mysql keeps structure in a password raw", "mysql", parts("db.internal", "", "orders"), "reader", "p@ss:w/rd",
			"reader:p@ss:w/rd@tcp(db.internal:3306)/orders"},
		{"mysql empty password", "mysql", parts("db.internal", "", "orders"), "reader", "",
			"reader:@tcp(db.internal:3306)/orders"},
		{"mongo is a URI", "mongo", parts("db.internal", "", "orders"), "reader", "s3cret",
			"mongodb://reader:s3cret@db.internal:27017/orders"},
		{"mongo percent-encodes the password", "mongo", parts("db.internal", "", "orders"), "reader", "p@ss:w/rd",
			"mongodb://reader:p%40ss%3Aw%2Frd@db.internal:27017/orders"},
		{"mongo percent-encodes the user, keeps unreserved", "mongo", parts("db.internal", "", "orders"), "app@ops-1.x_y~z", "p@ss:w/rd?1",
			"mongodb://app%40ops-1.x_y~z:p%40ss%3Aw%2Frd%3F1@db.internal:27017/orders"},
		{"mongo encodes non-ASCII as UTF-8 bytes", "mongo", parts("db.internal", "", "orders"), "reader", "é ",
			"mongodb://reader:%C3%A9%20@db.internal:27017/orders"},
		{"sqlite is its path", "sqlite", DatabaseConnection{Path: "/data/orders.db"}, "", "",
			"/data/orders.db"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := BuildConnectionString(c.driver, c.conn, c.user, c.password)
			if err != nil {
				t.Fatal(err)
			}
			if got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestEveryConnectionRefusalIsInWordsAndNeverQuotesThePassword(t *testing.T) {
	cases := []struct {
		name   string
		driver string
		conn   DatabaseConnection
		user   string
		want   string
	}{
		{"no host", "mysql", parts("", "", "orders"), "u", "a host is needed"},
		{"no host mongo", "mongo", parts("", "", "orders"), "u", "a host is needed"},
		{"no user", "mysql", parts("h", "", "orders"), "", "a user is needed"},
		{"no database", "mysql", parts("h", "", ""), "u", "a database name is needed"},
		{"host with paren", "mysql", parts("db)internal", "", "orders"), "u",
			`the host "db)internal" contains a character that would be read as part of the address — give the name or IP alone`},
		{"host with slash", "mysql", parts("a/b", "", "orders"), "u",
			`the host "a/b" contains a character that would be read as part of the address — give the name or IP alone`},
		{"host with space", "mongo", parts("db internal", "", "orders"), "u",
			`the host "db internal" contains a character that would be read as part of the address — give the name or IP alone`},
		{"database with slash", "mysql", parts("h", "", "or/ders"), "u",
			`the database name "or/ders" cannot contain / ? # or spaces`},
		{"database with query", "mysql", parts("h", "", "orders?x=1"), "u",
			`the database name "orders?x=1" cannot contain / ? # or spaces`},
		{"port 0", "mysql", parts("h", "0", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"port too big", "mysql", parts("h", "65536", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"port letters", "mysql", parts("h", "33o6", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"port negative", "mongo", parts("h", "-1", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"port with space", "mysql", parts("h", " 3306", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"port overflow", "mysql", parts("h", "99999999999999999999", "orders"), "u", "the port must be a number from 1 to 65535"},
		{"mysql user colon", "mysql", parts("h", "", "orders"), "a:b",
			`a MySQL user cannot contain ":" — the connection string has no way to escape it`},
		{"sqlite no path", "sqlite", DatabaseConnection{}, "", "a SQLite database needs the path to its file"},
		{"unknown driver", "postgres", parts("h", "", "orders"), "u",
			`"postgres" is not a driver Wakil has — choose one of mysql, mongo, sqlite`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := BuildConnectionString(c.driver, c.conn, c.user, "hunter2")
			msg, ok := IsUserError(err)
			if !ok {
				t.Fatalf("want a UserError, got %v", err)
			}
			if msg != c.want {
				t.Fatalf("got %q, want %q", msg, c.want)
			}
			if strings.Contains(msg, "hunter2") {
				t.Fatal("a refusal repeated the password")
			}
		})
	}
}

// --- the resolver ---

var (
	splitStubMu   sync.Mutex
	splitStubGot  []Connection
	splitStubSeen []string // "connect" or "connectWritable", in order
)

type splitStubDriver struct{ kind string }

func (d splitStubDriver) Kind() string { return d.kind }
func (d splitStubDriver) Connect(_ context.Context, c Connection) (Conn, error) {
	splitStubMu.Lock()
	defer splitStubMu.Unlock()
	splitStubGot = append(splitStubGot, c)
	splitStubSeen = append(splitStubSeen, "connect")
	return fakeTestConn{}, nil
}
func (d splitStubDriver) ConnectWritable(_ context.Context, c Connection) (Conn, error) {
	splitStubMu.Lock()
	defer splitStubMu.Unlock()
	splitStubGot = append(splitStubGot, c)
	splitStubSeen = append(splitStubSeen, "connectWritable")
	return fakeTestConn{}, nil
}
func (d splitStubDriver) AssertReadOnly(QuerySpec) error { return nil }
func (d splitStubDriver) AssertMutation(QuerySpec) error { return nil }

// stubServerDrivers swaps the registered mysql and mongo drivers for stubs
// that capture the Connection, restoring the real ones afterwards. The
// resolver decides "server driver" by NAME, so the stub has to wear it.
func stubServerDrivers(t *testing.T) {
	t.Helper()
	driversMutex.Lock()
	saved := map[string]DbDriver{}
	for _, kind := range []string{"mysql", "mongo"} {
		saved[kind] = drivers[kind]
		drivers[kind] = splitStubDriver{kind: kind}
	}
	driversMutex.Unlock()
	splitStubMu.Lock()
	splitStubGot, splitStubSeen = nil, nil
	splitStubMu.Unlock()
	t.Cleanup(func() {
		driversMutex.Lock()
		for kind, d := range saved {
			if d == nil {
				delete(drivers, kind)
			} else {
				drivers[kind] = d
			}
		}
		driversMutex.Unlock()
	})
}

func lastConnection(t *testing.T) Connection {
	t.Helper()
	splitStubMu.Lock()
	defer splitStubMu.Unlock()
	if len(splitStubGot) == 0 {
		t.Fatal("the stub driver was never asked to connect")
	}
	return splitStubGot[len(splitStubGot)-1]
}

func resolverOrg(t *testing.T) {
	t.Helper()
	fakeKeychain(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("WAKIL_ORG", "acme")
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
}

func TestASplitRecordConnectsWithItsPasswordOnly(t *testing.T) {
	resolverOrg(t)
	stubServerDrivers(t)
	if err := SecretSet("db:ledger:prod:core", "hunter2"); err != nil {
		t.Fatal(err)
	}
	d := Database{Name: "core", Driver: "mysql", Ref: "db:ledger:prod:core",
		Connection: &DatabaseConnection{Host: "db.internal", Port: "3306", Database: "ledger", User: "e2e"}}
	if _, err := OpenDatabase(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	got := lastConnection(t)
	if got.URL != "e2e:hunter2@tcp(db.internal:3306)/ledger" {
		t.Fatalf("URL = %q", got.URL)
	}
	if !got.ReadOnly {
		t.Fatal("the read route must stay read-only")
	}
}

func TestASplitRecordWithAPasswordThatLooksLikeStructureConnects(t *testing.T) {
	resolverOrg(t)
	stubServerDrivers(t)
	for driver, want := range map[string]string{
		"mysql": "e2e:p@ss:w/rd@tcp(db.internal:3306)/ledger",
		"mongo": "mongodb://e2e:p%40ss%3Aw%2Frd@db.internal:27017/ledger",
	} {
		ref := "db:ledger:prod:" + driver
		if err := SecretSet(ref, "p@ss:w/rd"); err != nil {
			t.Fatal(err)
		}
		d := Database{Name: driver, Driver: driver, Ref: ref,
			Connection: &DatabaseConnection{Host: "db.internal", Database: "ledger", User: "e2e"}}
		if _, err := OpenDatabase(context.Background(), d); err != nil {
			t.Fatal(err)
		}
		if got := lastConnection(t).URL; got != want {
			t.Fatalf("%s: URL = %q, want %q", driver, got, want)
		}
	}
}

func TestAWritableSplitRecordUsesTheWriteUser(t *testing.T) {
	resolverOrg(t)
	stubServerDrivers(t)
	if err := SecretSet("db:ledger:prod:core", "readpw"); err != nil {
		t.Fatal(err)
	}
	if err := SecretSet("db:ledger:prod:core:rw", "writepw"); err != nil {
		t.Fatal(err)
	}
	d := Database{Name: "core", Driver: "mysql", Ref: "db:ledger:prod:core", WriteRef: "db:ledger:prod:core:rw",
		Connection: &DatabaseConnection{Host: "db.internal", Database: "ledger", User: "reader", WriteUser: "writer"}}
	if _, err := OpenDatabaseWritable(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	got := lastConnection(t)
	if got.URL != "writer:writepw@tcp(db.internal:3306)/ledger" {
		t.Fatalf("write URL = %q", got.URL)
	}
	if got.ReadOnly || !got.Writable {
		t.Fatalf("write connection flags wrong: %+v", got)
	}
	if _, err := OpenDatabase(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if got := lastConnection(t).URL; got != "reader:readpw@tcp(db.internal:3306)/ledger" {
		t.Fatalf("read URL = %q", got)
	}
}

func TestALegacyRecordIsReadWhole(t *testing.T) {
	resolverOrg(t)
	stubServerDrivers(t)
	const whole = "reader:old@tcp(legacy.internal:3306)/orders"
	if err := SecretSet("db:ledger:prod:old", whole); err != nil {
		t.Fatal(err)
	}
	d := Database{Name: "old", Driver: "mysql", Ref: "db:ledger:prod:old"}
	if _, err := OpenDatabase(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if got := lastConnection(t).URL; got != whole {
		t.Fatalf("URL = %q, want the stored string untouched", got)
	}
}

func TestASQLiteRecordWithPartsStillReadsItsPathFromTheKeychain(t *testing.T) {
	resolverOrg(t)
	if err := SecretSet("db:ledger:prod:lite", "/data/orders.db"); err != nil {
		t.Fatal(err)
	}
	got, err := resolveDatabaseURL(Database{Driver: "sqlite", Connection: &DatabaseConnection{Path: "/data/orders.db"}},
		"db:ledger:prod:lite", "")
	if err != nil || got != "/data/orders.db" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestAHandEditedConnectionIsRefusedAtConnectNotPanicked(t *testing.T) {
	resolverOrg(t)
	stubServerDrivers(t)
	if err := SecretSet("db:ledger:prod:core", "hunter2"); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]DatabaseConnection{
		"port 0":    {Host: "db.internal", Port: "0", Database: "ledger", User: "e2e"},
		"host a/b":  {Host: "a/b", Database: "ledger", User: "e2e"},
		"no user":   {Host: "db.internal", Database: "ledger"},
		"no writes": {Host: "db.internal", Database: "ledger", User: "e2e", Port: "70000"},
	} {
		c := c
		d := Database{Name: "core", Driver: "mysql", Ref: "db:ledger:prod:core", Connection: &c}
		_, err := OpenDatabase(context.Background(), d)
		msg, ok := IsUserError(err)
		if !ok {
			t.Fatalf("%s: want a UserError, got %v", name, err)
		}
		if strings.Contains(msg, "hunter2") {
			t.Fatalf("%s: refusal quoted the password", name)
		}
	}
	splitStubMu.Lock()
	n := len(splitStubGot)
	splitStubMu.Unlock()
	if n != 0 {
		t.Fatalf("the driver was reached %d times despite refusals", n)
	}
}
