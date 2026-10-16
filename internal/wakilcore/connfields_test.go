package wakilcore

import (
	"testing"

	"github.com/go-sql-driver/mysql"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// The settings pane builds connection strings from separate fields in Swift
// (app/Sources/WakilKit/Panes/DatabaseConnection.swift), and the drivers
// here are what read them. These are the literals
// DatabaseConnectionStringTests.swift pins, fed to the real parsers, so a
// string Swift considers built is one Go can connect with. Change one file's
// literals and not the other's, and this stops meaning anything.

func TestTheFormsMySQLStringsParseAsTheirParts(t *testing.T) {
	cases := []struct {
		dsn, user, passwd, addr, db string
	}{
		{"reader:s3cret@tcp(db.internal:3306)/orders", "reader", "s3cret", "db.internal:3306", "orders"},
		{"reader:s3cret@tcp(db.internal:3307)/orders", "reader", "s3cret", "db.internal:3307", "orders"},
		{"reader:p@ss:w/rd?1@tcp(db.internal:3306)/orders", "reader", "p@ss:w/rd?1", "db.internal:3306", "orders"},
		{"reader:@tcp(db.internal:3306)/orders", "reader", "", "db.internal:3306", "orders"},
	}
	for _, c := range cases {
		cfg, err := mysql.ParseDSN(c.dsn)
		if err != nil {
			t.Errorf("ParseDSN(%q): %v", c.dsn, err)
			continue
		}
		if cfg.User != c.user || cfg.Passwd != c.passwd || cfg.Addr != c.addr || cfg.DBName != c.db {
			t.Errorf("ParseDSN(%q) = user %q passwd %q addr %q db %q, want %q %q %q %q",
				c.dsn, cfg.User, cfg.Passwd, cfg.Addr, cfg.DBName, c.user, c.passwd, c.addr, c.db)
		}
	}
}

// The shape the form replaced. The e2e fixture stored exactly this, and the
// driver never accepts it — which is why the pane stopped asking for the
// string. If this ever parses, the test above has lost its reason.
func TestTheURLFormTheFormReplacedDoesNotParse(t *testing.T) {
	if _, err := mysql.ParseDSN("mysql://e2e:secret@localhost/ledger"); err == nil {
		t.Fatal("ParseDSN accepted URL form; the field split's premise no longer holds")
	}
}

func TestTheFormsMongoStringsParseAsTheirParts(t *testing.T) {
	cases := []struct {
		uri, user, password, host, db string
	}{
		{"mongodb://reader:s3cret@db.internal:27017/orders", "reader", "s3cret", "db.internal:27017", "orders"},
		{"mongodb://app%40ops:p%40ss%3Aw%2Frd%3F1@db.internal:27017/orders", "app@ops", "p@ss:w/rd?1", "db.internal:27017", "orders"},
	}
	for _, c := range cases {
		opts := options.Client().ApplyURI(c.uri)
		if err := opts.Validate(); err != nil {
			t.Errorf("ApplyURI(%q): %v", c.uri, err)
			continue
		}
		if opts.Auth == nil || opts.Auth.Username != c.user || opts.Auth.Password != c.password {
			t.Errorf("ApplyURI(%q) auth = %+v, want user %q password %q", c.uri, opts.Auth, c.user, c.password)
		}
		if len(opts.Hosts) != 1 || opts.Hosts[0] != c.host {
			t.Errorf("ApplyURI(%q) hosts = %v, want [%q]", c.uri, opts.Hosts, c.host)
		}
		if got := databaseFromURI(c.uri); got != c.db {
			t.Errorf("databaseFromURI(%q) = %q, want %q", c.uri, got, c.db)
		}
	}
}
