package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/go-sql-driver/mysql"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// NOTE ON KEYCHAIN SAFETY. Not one test in this file may reach
// wakilcore.SecretSet, which shells out to `security add-generic-password`
// against the developer's real login keychain (it can raise a GUI prompt
// and it leaves a real item behind). The only place SecretSet is named is
// main(), which no test calls; every test that exercises run() passes the
// recorder below instead. WAKIL_KEYCHAIN_TEST is deliberately not set
// anywhere here.

// recorder is the injected secretStore. It records every call so a test
// can assert not only WHAT was stored but that nothing was stored at all
// on a rejection path — the assertion that actually matters for the
// empty-secret failure mode.
type recorder struct {
	calls []struct{ ref, value string }
	err   error
}

func (r *recorder) store(ref, value string) error {
	r.calls = append(r.calls, struct{ ref, value string }{ref, value})
	return r.err
}

// failingStore is a secretStore that fails the test the instant it is
// called. It is passed to run() by every org/provider/project test in
// orgcmd_test.go: none of those commands may ever reach the Keychain
// writer, and a recorder (which merely records the call) would let a
// wiring mistake that routes one of them into runSecrets pass silently.
func failingStore(t *testing.T) secretStore {
	t.Helper()
	return func(ref, value string) error {
		t.Fatalf("secretStore must not be called for an org/provider/project command (ref=%q)", ref)
		return nil
	}
}

// failingReader is the read-side counterpart of failingStore: any test
// whose subcommand must not read a secret passes this, so an accidental
// Keychain read fails the test instead of prompting the operator.
func failingReader(t *testing.T) secretReader {
	t.Helper()
	return func(ref string) (string, error) {
		t.Fatalf("unexpected keychain read for ref %q", ref)
		return "", nil
	}
}

func TestRunThreadsTheSecretReader(t *testing.T) {
	var stderr bytes.Buffer
	called := ""
	read := func(ref string) (string, error) { called = ref; return "tok", nil }
	_ = run([]string{"--org", "acme", "provider", "list"},
		strings.NewReader(""), io.Discard, &stderr, failingStore(t), read)
	if called != "" {
		t.Fatalf("provider list read ref %q; it must read no secret", called)
	}
}

// wantMessage fails t unless err is non-nil and its message contains want.
// Asserting the MESSAGE, not merely "an error happened", is what stops a
// rejection test from passing for the wrong reason — an "error is
// non-nil" check passes just as happily when a completely different guard
// fires, or when a guard is deleted and a later one picks up the slack.
func wantMessage(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected an error containing %q, got nil", want)
	}
	msg, ok := wakilcore.IsUserError(err)
	if !ok {
		msg = err.Error()
	}
	if !strings.Contains(msg, want) {
		t.Fatalf("error message = %q, want it to contain %q", msg, want)
	}
}

// ---------------------------------------------------------------------
// `secrets set` parsing
// ---------------------------------------------------------------------

// TestParseSecretsArgs is the plan's own Task 17 test, kept verbatim in
// intent: it pins the happy path, the missing ref, and the requirement
// that an unknown command shows usage.
func TestParseSecretsArgs(t *testing.T) {
	ref, err := parseSecretsSet([]string{"secrets", "set", "booking-staging-core"})
	if err != nil || ref != "booking-staging-core" {
		t.Fatalf("parse: %q %v", ref, err)
	}
	if _, err := parseSecretsSet([]string{"secrets", "set"}); err == nil {
		t.Fatal("missing ref must error")
	}
	if _, err := parseSecretsSet([]string{"nonsense"}); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Fatal("unknown command must show usage")
	}
}

func TestParseSecretsSet(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		wantRef string
		wantMsg string
	}{
		{name: "happy", args: []string{"secrets", "set", "booking-staging-core"}, wantRef: "booking-staging-core"},
		{name: "happy with colons and dots", args: []string{"secrets", "set", "jira:initech"}, wantRef: "jira:initech"},
		{name: "no args at all", args: nil, wantMsg: "unknown command"},
		{name: "unknown command", args: []string{"nonsense"}, wantMsg: "usage"},
		{name: "secrets without verb", args: []string{"secrets"}, wantMsg: "unknown command"},
		{name: "unknown verb", args: []string{"secrets", "delete", "x"}, wantMsg: "unknown command"},
		{name: "missing ref", args: []string{"secrets", "set"}, wantMsg: "missing <ref>"},
		{name: "empty ref", args: []string{"secrets", "set", ""}, wantMsg: "ref must not be empty"},
		{name: "extra trailing argument", args: []string{"secrets", "set", "ref", "hunter2"}, wantMsg: "too many arguments"},
		{name: "leading dash ref", args: []string{"secrets", "set", "-w"}, wantMsg: "invalid ref"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ref, err := parseSecretsSet(tc.args)
			if tc.wantMsg != "" {
				wantMessage(t, err, tc.wantMsg)
				if ref != "" {
					t.Fatalf("ref = %q on a rejected parse, want %q", ref, "")
				}
				return
			}
			if err != nil {
				t.Fatalf("parseSecretsSet: %v", err)
			}
			if ref != tc.wantRef {
				t.Fatalf("ref = %q, want %q", ref, tc.wantRef)
			}
		})
	}
}

// TestParseSecretsSetRejectsSetDB pins that parseSecretsSet does not
// depend on run's dispatch order to keep "set-db" out: it compares
// args[1] to "set" exactly.
func TestParseSecretsSetRejectsSetDB(t *testing.T) {
	_, err := parseSecretsSet([]string{"secrets", "set-db", "ref"})
	wantMessage(t, err, "unknown command")
}

// TestParseSecretsSetErrorsMentionUsage keeps every rejection actionable:
// each one has to tell the operator what the command actually looks like.
func TestParseSecretsSetErrorsMentionUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"nonsense"}, {"secrets"}, {"secrets", "set"}, {"secrets", "set", "ref", "extra"}} {
		if _, err := parseSecretsSet(args); err == nil || !strings.Contains(err.Error(), "usage") {
			t.Fatalf("parseSecretsSet(%q) = %v, want an error containing %q", args, err, "usage")
		}
	}
}

// ---------------------------------------------------------------------
// ref validation
// ---------------------------------------------------------------------

func TestValidateRef(t *testing.T) {
	cases := []struct {
		name    string
		ref     string
		wantMsg string
	}{
		{name: "simple", ref: "booking"},
		{name: "dots colons and hyphens", ref: "a.b:c-d_e9"},
		{name: "digit first", ref: "9lives"},
		{name: "empty", ref: "", wantMsg: "ref must not be empty"},
		{name: "leading hyphen", ref: "-w", wantMsg: "invalid ref"},
		{name: "leading dot", ref: ".hidden", wantMsg: "invalid ref"},
		{name: "leading colon", ref: ":x", wantMsg: "invalid ref"},
		{name: "embedded space", ref: "a b", wantMsg: "invalid ref"},
		{name: "trailing newline", ref: "a\n", wantMsg: "invalid ref"},
		{name: "embedded newline", ref: "a\nb", wantMsg: "invalid ref"},
		{name: "NUL", ref: "a\x00b", wantMsg: "invalid ref"},
		{name: "slash", ref: "a/b", wantMsg: "invalid ref"},
		{name: "at sign", ref: "a@b", wantMsg: "invalid ref"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateRef(tc.ref)
			if tc.wantMsg == "" {
				if err != nil {
					t.Fatalf("validateRef(%q) = %v, want nil", tc.ref, err)
				}
				return
			}
			wantMessage(t, err, tc.wantMsg)
			// The message has to name the rule, not just say "no".
			msg, _ := wakilcore.IsUserError(err)
			if !strings.Contains(msg, "^[A-Za-z0-9][A-Za-z0-9._:-]*$") {
				t.Fatalf("message = %q, want it to state the ref rule", msg)
			}
		})
	}
}

// TestRefPatternRejectsEverythingSecurityCouldMisread covers the outermost
// of the three layers described on refPattern: refs that would look like
// an option to `security`, and refs carrying whitespace or a NUL. The two
// inner layers (secrets.go's "wakil:" prefix, and `security` being run via
// exec.Command with no shell) are not exercised here — reaching them means
// calling wakilcore.SecretSet, which is the real login keychain. What this
// test guarantees is that none of these strings gets that far in the first
// place.
func TestRefPatternRejectsEverythingSecurityCouldMisread(t *testing.T) {
	for _, ref := range []string{"-w", "-s", "--help", "-", "a b", "a\tb", "a\x00"} {
		if err := validateRef(ref); err == nil {
			t.Fatalf("validateRef(%q) = nil, want a rejection", ref)
		}
	}
}

// ---------------------------------------------------------------------
// reading the secret value from stdin
// ---------------------------------------------------------------------

// partialThenErrorReader yields data once and then fails. This is the
// shape of a real stdin failure (a closed pipe mid-read, an I/O error on a
// redirected file) and it is the case that distinguishes "the read error
// is checked" from "the read error is discarded": with the error
// discarded, io.ReadAll's partial result looks exactly like a complete
// secret and would be stored as one.
type partialThenErrorReader struct {
	data []byte
	done bool
}

func (r *partialThenErrorReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, errors.New("simulated stdin failure")
	}
	r.done = true
	n := copy(p, r.data)
	return n, nil
}

// immediateErrorReader fails before yielding a single byte.
type immediateErrorReader struct{}

func (immediateErrorReader) Read([]byte) (int, error) {
	return 0, errors.New("simulated stdin failure")
}

func TestReadSecretValue(t *testing.T) {
	cases := []struct {
		name    string
		in      io.Reader
		want    string
		wantMsg string
	}{
		{name: "no trailing newline", in: strings.NewReader("s3cret"), want: "s3cret"},
		{name: "one trailing LF", in: strings.NewReader("s3cret\n"), want: "s3cret"},
		{name: "one trailing CRLF", in: strings.NewReader("s3cret\r\n"), want: "s3cret"},
		// EVERY trailing terminator comes off, and these three cases
		// inverted on 2026-09-11. They used to assert that exactly one was
		// stripped, so that a secret ending in a newline could round-trip.
		// It never did: `security find-generic-password -w` returns a value
		// ending in a newline as lowercase HEX with no marker, so the
		// preserved terminator turned the whole secret into 224 characters
		// of hex that failed at first use with a 401. Absorbing the
		// terminators here is what stops that being reachable; SecretGet's
		// decodeKeychainHex repairs items already stored the old way.
		//
		// The input that forced it is the ordinary one: a token copied from
		// `claude setup-token` (whose output ends in a newline), pasted,
		// then Enter, then Ctrl-D — two newlines, of which one used to
		// survive.
		{name: "two trailing LFs are both stripped", in: strings.NewReader("s3cret\n\n"), want: "s3cret"},
		{name: "two trailing CRLFs are all stripped", in: strings.NewReader("s3cret\r\n\r\n"), want: "s3cret"},
		{name: "interior newlines preserved", in: strings.NewReader("-----BEGIN-----\nline\n-----END-----\n"), want: "-----BEGIN-----\nline\n-----END-----"},
		{name: "leading and trailing spaces preserved", in: strings.NewReader("  pw  \n"), want: "  pw  "},
		{name: "bare CR is stripped too", in: strings.NewReader("s3cret\r"), want: "s3cret"},
		{name: "empty input", in: strings.NewReader(""), wantMsg: "no secret value on stdin"},
		{name: "only a newline", in: strings.NewReader("\n"), wantMsg: "no secret value on stdin"},
		{name: "two newlines", in: strings.NewReader("\n\n"), wantMsg: "no secret value on stdin"},
		{name: "whitespace only", in: strings.NewReader("   \t \n"), wantMsg: "no secret value on stdin"},
		{name: "NUL in value", in: strings.NewReader("s3\x00cret\n"), wantMsg: "contains a NUL byte"},
		{name: "read error after partial data", in: &partialThenErrorReader{data: []byte("s3cret")}, wantMsg: "could not read the secret value from stdin"},
		{name: "read error with no data", in: immediateErrorReader{}, wantMsg: "could not read the secret value from stdin"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readSecretValue(tc.in)
			if tc.wantMsg != "" {
				wantMessage(t, err, tc.wantMsg)
				if got != "" {
					t.Fatalf("value = %q on a rejected read, want %q", got, "")
				}
				return
			}
			if err != nil {
				t.Fatalf("readSecretValue: %v", err)
			}
			if got != tc.want {
				t.Fatalf("value = %q, want %q", got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------
// `secrets set-db` parsing
// ---------------------------------------------------------------------

func TestParseSecretsSetDB(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		wantRef    string
		wantTarget dbTarget
		wantMsg    string
	}{
		{
			name:       "mysql happy",
			args:       []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "db.internal", "--port", "3306", "--db", "app", "--user", "reader"},
			wantRef:    "core",
			wantTarget: dbTarget{Driver: "mysql", Host: "db.internal", Port: "3306", DB: "app", User: "reader"},
		},
		{
			name:       "mongo happy",
			args:       []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "27017", "--db", "app", "--user", "reader"},
			wantRef:    "core",
			wantTarget: dbTarget{Driver: "mongo", Host: "m.internal", Port: "27017", DB: "app", User: "reader"},
		},
		{
			name:       "mongo happy with auth source",
			args:       []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "27017", "--db", "app", "--user", "reader", "--auth-source", "admin"},
			wantRef:    "core",
			wantTarget: dbTarget{Driver: "mongo", Host: "m.internal", Port: "27017", DB: "app", User: "reader", AuthSource: "admin"},
		},
		{
			name:       "sqlite happy",
			args:       []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/var/db/app.db"},
			wantRef:    "core",
			wantTarget: dbTarget{Driver: "sqlite", DB: "/var/db/app.db"},
		},
		{name: "mysql rejects auth source", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--db", "d", "--user", "u", "--auth-source", "admin"}, wantMsg: "--auth-source does not apply to --driver mysql"},
		{name: "sqlite rejects auth source", args: []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/x.db", "--auth-source", "admin"}, wantMsg: "--auth-source does not apply to --driver sqlite"},
		{name: "missing ref", args: []string{"secrets", "set-db"}, wantMsg: "missing <ref>"},
		{name: "invalid ref", args: []string{"secrets", "set-db", "-w", "--driver", "mysql"}, wantMsg: "invalid ref"},
		{name: "missing driver", args: []string{"secrets", "set-db", "core", "--host", "h", "--port", "3306", "--db", "d", "--user", "u"}, wantMsg: "missing required flag --driver"},
		{name: "unknown driver", args: []string{"secrets", "set-db", "core", "--driver", "postgres", "--host", "h", "--port", "5432", "--db", "d", "--user", "u"}, wantMsg: `unknown --driver "postgres"`},
		{name: "mysql missing host", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--port", "3306", "--db", "d", "--user", "u"}, wantMsg: "missing required flag --host"},
		{name: "mysql missing port", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--db", "d", "--user", "u"}, wantMsg: "missing required flag --port"},
		{name: "mysql missing db", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--user", "u"}, wantMsg: "missing required flag --db"},
		{name: "mysql missing user", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--db", "d"}, wantMsg: "missing required flag --user"},
		{name: "mongo missing host", args: []string{"secrets", "set-db", "core", "--driver", "mongo", "--port", "27017", "--db", "d", "--user", "u"}, wantMsg: "missing required flag --host"},
		{name: "mongo missing port", args: []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "h", "--db", "d", "--user", "u"}, wantMsg: "missing required flag --port"},
		{name: "mongo missing db", args: []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "h", "--port", "27017", "--user", "u"}, wantMsg: "missing required flag --db"},
		{name: "mongo missing user", args: []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "h", "--port", "27017", "--db", "d"}, wantMsg: "missing required flag --user"},
		{name: "sqlite missing db", args: []string{"secrets", "set-db", "core", "--driver", "sqlite"}, wantMsg: "missing required flag --db for --driver sqlite"},
		{name: "sqlite rejects host", args: []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/x.db", "--host", "h"}, wantMsg: "--host does not apply to --driver sqlite"},
		{name: "sqlite rejects port", args: []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/x.db", "--port", "1"}, wantMsg: "--port does not apply to --driver sqlite"},
		{name: "sqlite rejects user", args: []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/x.db", "--user", "u"}, wantMsg: "--user does not apply to --driver sqlite"},
		{name: "unknown flag", args: []string{"secrets", "set-db", "core", "--driver", "mysql", "--password", "x"}, wantMsg: "bad flags"},
		{name: "positional after flags", args: []string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/x.db", "hunter2"}, wantMsg: `unexpected argument "hunter2"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ref, target, err := parseSecretsSetDB(tc.args)
			if tc.wantMsg != "" {
				wantMessage(t, err, tc.wantMsg)
				if ref != "" || target != (dbTarget{}) {
					t.Fatalf("ref/target = %q/%+v on a rejected parse, want zero values", ref, target)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseSecretsSetDB: %v", err)
			}
			if ref != tc.wantRef {
				t.Fatalf("ref = %q, want %q", ref, tc.wantRef)
			}
			if target != tc.wantTarget {
				t.Fatalf("target = %+v, want %+v", target, tc.wantTarget)
			}
		})
	}
}

// ---------------------------------------------------------------------
// DSN composition
// ---------------------------------------------------------------------

// specialPasswords are the characters Ruling 2 calls out, each on its own
// plus one password made of nothing but them. Every one of these is a
// character that terminates or re-delimits some part of a connection
// string if it is carried naively.
var specialPasswords = map[string]string{
	"at sign":     "pa@ss",
	"slash":       "pa/ss",
	"colon":       "pa:ss",
	"question":    "pa?ss",
	"hash":        "pa#ss",
	"percent":     "pa%ss",
	"all of them": "@/:?#%",
	// A percent followed by two hex digits is the nastiest case: it is
	// already a valid percent-escape, so a composer that escapes
	// correctly and a decoder that decodes twice disagree.
	"percent escape lookalike": "pa%40ss",
	"looks like a mysql dsn":   "a@tcp(x:1)/y",
	"looks like a mongo uri":   "mongodb://u:p@h/db",
}

func mysqlTarget() dbTarget {
	return dbTarget{Driver: "mysql", Host: "db.internal", Port: "3306", DB: "app", User: "reader"}
}

func mongoTarget() dbTarget {
	return dbTarget{Driver: "mongo", Host: "m.internal", Port: "27017", DB: "app", User: "reader"}
}

// TestComposeMySQLDSNPasswordRoundTrip decodes the composed DSN back with
// go-sql-driver/mysql's OWN parser — the code that will actually read this
// string at connect time — and asserts the password comes back byte for
// byte. Using the real parser rather than net/url is the point: this DSN
// format is not a URL, and percent-encoding the password would make this
// test fail with a mangled password rather than pass.
func TestComposeMySQLDSNPasswordRoundTrip(t *testing.T) {
	for name, pw := range specialPasswords {
		t.Run(name, func(t *testing.T) {
			dsn, err := composeMySQLDSN(mysqlTarget(), pw)
			if err != nil {
				t.Fatalf("composeMySQLDSN: %v", err)
			}
			cfg, err := mysql.ParseDSN(dsn)
			if err != nil {
				t.Fatalf("mysql.ParseDSN: %v", err)
			}
			if cfg.Passwd != pw {
				t.Fatalf("password round-trip: got %q, want %q", cfg.Passwd, pw)
			}
			if cfg.User != "reader" || cfg.Addr != "db.internal:3306" || cfg.DBName != "app" || cfg.Net != "tcp" {
				t.Fatalf("connection fields round-trip: user=%q addr=%q db=%q net=%q", cfg.User, cfg.Addr, cfg.DBName, cfg.Net)
			}
		})
	}
}

// TestComposeMySQLDSNCarriesReadOnlyMarker pins the marker wakilcore's
// mysql driver already speaks: driver_mysql.go sets
// cfg.Params["transaction_read_only"]="1" on every Connect, and the stored
// DSN says the same thing.
func TestComposeMySQLDSNCarriesReadOnlyMarker(t *testing.T) {
	dsn, err := composeMySQLDSN(mysqlTarget(), "pw")
	if err != nil {
		t.Fatalf("composeMySQLDSN: %v", err)
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatalf("mysql.ParseDSN: %v", err)
	}
	if cfg.Params["transaction_read_only"] != "1" {
		t.Fatalf("transaction_read_only = %q, want %q", cfg.Params["transaction_read_only"], "1")
	}
}

// TestComposeMySQLDSNRejectsColonUser pins the one field this DSN format
// genuinely cannot carry. mysql.ParseDSN splits the userinfo at the FIRST
// colon, so "u:v" as a username would come back as user "u" with the rest
// glued onto the password — a silently wrong credential rather than a
// failure. Measured against the real parser below so the claim cannot rot.
func TestComposeMySQLDSNRejectsColonUser(t *testing.T) {
	target := mysqlTarget()
	target.User = "u:v"
	_, err := composeMySQLDSN(target, "pw")
	wantMessage(t, err, "cannot be expressed in a go-sql-driver DSN")

	// Why the rule exists, measured rather than asserted.
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd, cfg.Net, cfg.Addr, cfg.DBName = "u:v", "pw", "tcp", "h:3306", "app"
	back, err := mysql.ParseDSN(cfg.FormatDSN())
	if err != nil {
		t.Fatalf("mysql.ParseDSN: %v", err)
	}
	if back.User == "u:v" {
		t.Fatal("go-sql-driver now round-trips a colon in the username — the rejection above can be relaxed")
	}
}

func TestComposeMySQLDSNRejectsBadFields(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*dbTarget)
		pw      string
		wantMsg string
	}{
		{name: "empty host", mutate: func(d *dbTarget) { d.Host = "" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "host with paren", mutate: func(d *dbTarget) { d.Host = "h)x(" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "host with slash", mutate: func(d *dbTarget) { d.Host = "h/x" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "host with at sign", mutate: func(d *dbTarget) { d.Host = "h@x" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "non numeric port", mutate: func(d *dbTarget) { d.Port = "mysql" }, pw: "pw", wantMsg: "invalid --port"},
		{name: "port zero", mutate: func(d *dbTarget) { d.Port = "0" }, pw: "pw", wantMsg: "invalid --port"},
		{name: "port too high", mutate: func(d *dbTarget) { d.Port = "65536" }, pw: "pw", wantMsg: "invalid --port"},
		{name: "db with slash", mutate: func(d *dbTarget) { d.DB = "a/b" }, pw: "pw", wantMsg: "invalid --db"},
		{name: "db with question mark", mutate: func(d *dbTarget) { d.DB = "a?b" }, pw: "pw", wantMsg: "invalid --db"},
		{name: "newline in user", mutate: func(d *dbTarget) { d.User = "a\nb" }, pw: "pw", wantMsg: "the --user value contains a control character"},
		// DEL is not below 0x20, so it needs its own arm in
		// checkPrintable; it is still a control character and still
		// corrupts a stored credential silently.
		{name: "DEL in user", mutate: func(d *dbTarget) { d.User = "a\x7fb" }, pw: "pw", wantMsg: "the --user value contains a control character"},
		{name: "NUL in password", mutate: func(d *dbTarget) {}, pw: "a\x00b", wantMsg: "the password value contains a control character"},
		{name: "newline in password", mutate: func(d *dbTarget) {}, pw: "a\nb", wantMsg: "the password value contains a control character"},
		{name: "DEL in password", mutate: func(d *dbTarget) {}, pw: "a\x7fb", wantMsg: "the password value contains a control character"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			target := mysqlTarget()
			tc.mutate(&target)
			dsn, err := composeMySQLDSN(target, tc.pw)
			wantMessage(t, err, tc.wantMsg)
			if dsn != "" {
				t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
			}
			// A rejection message must never echo the password.
			msg, _ := wakilcore.IsUserError(err)
			if tc.pw != "pw" && strings.Contains(msg, tc.pw) {
				t.Fatalf("message %q echoes the password", msg)
			}
		})
	}
}

// TestHostRejectionsAndAcceptances pins checkHost on both sides.
//
// The rejections matter because the pattern this replaced had a "*" on
// BOTH sides of the colon in its IPv6 alternative, so ":", "..:.." and
// ":::::" all matched. None of them is an address, and none of them was
// caught downstream either: net.JoinHostPort brackets anything containing
// a colon and mysql.ParseDSN round-trips the result, so `--host :::::`
// was composed and stored as "tcp([:::::]:3306)" — measured below, so
// that the reason for this test cannot rot into "someone was cautious".
func TestHostRejectionsAndAcceptances(t *testing.T) {
	bad := []string{":", "a:b", "..:..", ":::::", "::::::::::", "1:2", "fe80::1%en0", "[::1]", "h)x(", "h/x", "h@x", "h?x", "h#x", ""}
	for _, h := range bad {
		t.Run("reject "+strconv.Quote(h), func(t *testing.T) {
			target := mysqlTarget()
			target.Host = h
			_, err := composeMySQLDSN(target, "pw")
			wantMessage(t, err, "invalid --host "+strconv.Quote(h))

			mt := mongoTarget()
			mt.Host = h
			_, err = composeMongoDSN(mt, "pw")
			wantMessage(t, err, "invalid --host "+strconv.Quote(h))
		})
	}

	// What the loose pattern let through, measured against the real
	// mysql parser: it is not that these were caught later.
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd, cfg.Net, cfg.Addr, cfg.DBName = "reader", "pw", "tcp", net.JoinHostPort(":::::", "3306"), "app"
	if back, err := mysql.ParseDSN(cfg.FormatDSN()); err != nil || back.Addr != "[:::::]:3306" {
		t.Fatalf("mysql.ParseDSN no longer round-trips a bogus IPv6 address (addr=%q err=%v) — the host check may be relaxable", back.Addr, err)
	}

	good := []string{"db.internal", "localhost", "1.2.3.4", "a_b", "::1", "::", "2001:db8::1", "::ffff:1.2.3.4", "fe80::1"}
	for _, h := range good {
		t.Run("accept "+strconv.Quote(h), func(t *testing.T) {
			target := mysqlTarget()
			target.Host = h
			if _, err := composeMySQLDSN(target, "pw"); err != nil {
				t.Fatalf("composeMySQLDSN(host=%q): %v", h, err)
			}
			mt := mongoTarget()
			mt.Host = h
			if _, err := composeMongoDSN(mt, "pw"); err != nil {
				t.Fatalf("composeMongoDSN(host=%q): %v", h, err)
			}
		})
	}
}

// TestPortMustBeCanonicalDecimal pins the fix for a guard that was applied
// at the wrong scope: the port was range-checked as a NUMBER but composed
// as the raw STRING. strconv.Atoi accepts a leading "+" and leading
// zeros, so both of these passed the range check and then composed
// "tcp(h:+3306)" / "h:0065" — stored, and rejected only at dial time.
func TestPortMustBeCanonicalDecimal(t *testing.T) {
	for _, p := range []string{"+3306", "0065", "03306", "-3306", " 3306", "3306 ", "3306\n", "0", "65536", "", "mysql", "0x10", "3_306"} {
		t.Run(strconv.Quote(p), func(t *testing.T) {
			target := mysqlTarget()
			target.Port = p
			dsn, err := composeMySQLDSN(target, "pw")
			wantMessage(t, err, "invalid --port "+strconv.Quote(p))
			if dsn != "" {
				t.Fatalf("dsn = %q on a rejected port, want %q", dsn, "")
			}

			mt := mongoTarget()
			mt.Port = p
			if _, err := composeMongoDSN(mt, "pw"); err == nil {
				t.Fatalf("composeMongoDSN accepted --port %q", p)
			}
		})
	}
	for _, p := range []string{"1", "80", "3306", "65535"} {
		target := mysqlTarget()
		target.Port = p
		dsn, err := composeMySQLDSN(target, "pw")
		if err != nil {
			t.Fatalf("composeMySQLDSN(port=%q): %v", p, err)
		}
		if !strings.Contains(dsn, "tcp(db.internal:"+p+")") {
			t.Fatalf("dsn = %q, want the port composed as %q", dsn, p)
		}
	}
}

// TestComposeMySQLDSNBackstopCatchesEmptyUser is the round-trip
// backstop's live case. go-sql-driver's FormatDSN writes the password
// only inside the "user[:password]@" group, so a target with no user
// DROPS the password entirely and yields a credential-less DSN. Without
// the backstop that DSN is stored and "stored" is printed.
//
// parseSecretsSetDB requires --user, so this is not reachable from the
// command line — it is reachable through composeDBDSN, which its own doc
// comment promises is safe to call on its own.
func TestComposeMySQLDSNBackstopCatchesEmptyUser(t *testing.T) {
	target := mysqlTarget()
	target.User = ""
	dsn, err := composeMySQLDSN(target, "hunter2")
	wantMessage(t, err, "could not compose a mysql DSN that reads back unchanged")
	if dsn != "" {
		t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
	}
	msg, _ := wakilcore.IsUserError(err)
	if strings.Contains(msg, "hunter2") {
		t.Fatalf("message %q echoes the password", msg)
	}

	// Why the backstop is what catches it, measured against the real
	// formatter rather than asserted.
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd, cfg.Net, cfg.Addr, cfg.DBName = "", "hunter2", "tcp", "db.internal:3306", "app"
	raw := cfg.FormatDSN()
	if strings.Contains(raw, "hunter2") {
		t.Fatalf("FormatDSN now carries the password with an empty user (%q) — the backstop's rationale has changed", raw)
	}
	back, err := mysql.ParseDSN(raw)
	if err != nil {
		t.Fatalf("mysql.ParseDSN: %v", err)
	}
	if back.Passwd != "" {
		t.Fatalf("parsed password = %q, want it to have been dropped", back.Passwd)
	}
}

// TestMySQLDSNRoundTripsComparesEveryField exercises the backstop's
// comparison field by field. Driving it through composeMySQLDSN cannot:
// the denylist there leaves exactly one reachable failing input (an empty
// username, which shows up in Passwd), so a narrowed comparison — say,
// one that had lost its Addr or DBName arm — would still pass every test
// that goes through the composer. Each case below feeds a DSN that
// differs from cfg in ONE field and asserts the predicate says no.
func TestMySQLDSNRoundTripsComparesEveryField(t *testing.T) {
	base := func() *mysql.Config {
		cfg := mysql.NewConfig()
		cfg.User, cfg.Passwd, cfg.Net, cfg.Addr, cfg.DBName = "reader", "pw", "tcp", "db.internal:3306", "app"
		cfg.Params = map[string]string{"transaction_read_only": "1"}
		return cfg
	}
	if !mysqlDSNRoundTrips(base().FormatDSN(), base()) {
		t.Fatal("an untouched DSN must round-trip")
	}
	cases := []struct {
		field  string
		mutate func(*mysql.Config)
	}{
		{"User", func(c *mysql.Config) { c.User = "other" }},
		{"Passwd", func(c *mysql.Config) { c.Passwd = "other" }},
		{"Net", func(c *mysql.Config) { c.Net = "unix" }},
		{"Addr", func(c *mysql.Config) { c.Addr = "other.internal:3306" }},
		{"DBName", func(c *mysql.Config) { c.DBName = "other" }},
		{"transaction_read_only", func(c *mysql.Config) { c.Params = map[string]string{"transaction_read_only": "0"} }},
	}
	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			other := base()
			tc.mutate(other)
			if mysqlDSNRoundTrips(other.FormatDSN(), base()) {
				t.Fatalf("a DSN differing in %s was accepted as an unchanged round trip", tc.field)
			}
		})
	}
	// A DSN the driver's parser rejects outright must not be accepted
	// either: an error return has to mean "no", not "no comparison".
	if mysqlDSNRoundTrips("not a dsn at all", base()) {
		t.Fatal("an unparseable DSN was accepted as an unchanged round trip")
	}
}

// TestMongoURIRoundTripsComparesEveryField is the mongo half of the same
// argument: composeMongoDSN's field checks leave nothing that reaches
// this predicate and fails it, so its comparisons are exercised here
// directly, one field at a time.
func TestMongoURIRoundTripsComparesEveryField(t *testing.T) {
	target := mongoTarget()
	target.AuthSource = "admin"
	const host = "m.internal:27017"
	const pw = "pw"
	good := "mongodb://reader:pw@m.internal:27017/app?authSource=admin"
	if !mongoURIRoundTrips(good, host, target, pw) {
		t.Fatalf("%q must round-trip", good)
	}
	cases := []struct {
		field string
		dsn   string
	}{
		{"username", "mongodb://other:pw@m.internal:27017/app?authSource=admin"},
		{"no userinfo at all", "mongodb://m.internal:27017/app?authSource=admin"},
		{"username with no password", "mongodb://reader@m.internal:27017/app?authSource=admin"},
		{"password", "mongodb://reader:other@m.internal:27017/app?authSource=admin"},
		{"host", "mongodb://reader:pw@other.internal:27017/app?authSource=admin"},
		{"port", "mongodb://reader:pw@m.internal:27018/app?authSource=admin"},
		{"database", "mongodb://reader:pw@m.internal:27017/other?authSource=admin"},
		{"auth source", "mongodb://reader:pw@m.internal:27017/app?authSource=other"},
		{"auth source dropped", "mongodb://reader:pw@m.internal:27017/app"},
		{"unparseable", "mongodb://reader:pw@[::1:27017/app"},
	}
	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			if mongoURIRoundTrips(tc.dsn, host, target, pw) {
				t.Fatalf("a URI differing in %s (%q) was accepted as an unchanged round trip", tc.field, tc.dsn)
			}
		})
	}
}

// TestComposeMongoDSNBackstopCatchesEmptyUser is the same failure in the
// mongo format, and the reason the backstop asks the MONGO DRIVER and not
// only net/url: "mongodb://:hunter2@m.internal:27017/app" round-trips
// through net/url perfectly — username "", password "hunter2" — while the
// driver that will actually open this connection reads it as having NO
// credentials at all.
func TestComposeMongoDSNBackstopCatchesEmptyUser(t *testing.T) {
	target := mongoTarget()
	target.User = ""
	dsn, err := composeMongoDSN(target, "hunter2")
	wantMessage(t, err, "could not compose a mongodb URI the mongo driver reads back unchanged")
	if dsn != "" {
		t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
	}
	msg, _ := wakilcore.IsUserError(err)
	if strings.Contains(msg, "hunter2") {
		t.Fatalf("message %q echoes the password", msg)
	}

	// The measurement behind the paragraph above: net/url says this URI
	// is fine, and the driver says it has no credentials.
	raw := "mongodb://:hunter2@m.internal:27017/app"
	u, perr := url.Parse(raw)
	if perr != nil {
		t.Fatalf("url.Parse: %v", perr)
	}
	if pw, ok := u.User.Password(); !ok || pw != "hunter2" || u.User.Username() != "" {
		t.Fatalf("net/url no longer round-trips %q as an empty user with a password (user=%q pw=%q ok=%v) — the backstop's rationale has changed", raw, u.User.Username(), pw, ok)
	}
	if auth := options.Client().ApplyURI(raw).Auth; auth != nil {
		t.Fatalf("the mongo driver now reads %q as credentialed (%+v) — net/url alone would suffice", raw, auth)
	}
}

// TestComposeMongoDSNPasswordRoundTrip decodes with net/url (as Ruling 2
// asks) AND with the Mongo driver's own connection-string handling, since
// that is what actually reads this URI at connect time. Both must return
// the password byte for byte.
func TestComposeMongoDSNPasswordRoundTrip(t *testing.T) {
	for name, pw := range specialPasswords {
		t.Run(name, func(t *testing.T) {
			dsn, err := composeMongoDSN(mongoTarget(), pw)
			if err != nil {
				t.Fatalf("composeMongoDSN: %v", err)
			}

			u, err := url.Parse(dsn)
			if err != nil {
				t.Fatalf("url.Parse: %v", err)
			}
			got, ok := u.User.Password()
			if !ok || got != pw {
				t.Fatalf("net/url password round-trip: got %q (ok=%v), want %q", got, ok, pw)
			}
			if u.User.Username() != "reader" || u.Host != "m.internal:27017" || strings.TrimPrefix(u.Path, "/") != "app" {
				t.Fatalf("connection fields round-trip: user=%q host=%q path=%q", u.User.Username(), u.Host, u.Path)
			}

			// ApplyURI parses only; it opens no connection.
			opts := options.Client().ApplyURI(dsn)
			if opts.Auth == nil {
				t.Fatal("mongo ApplyURI produced no auth credentials")
			}
			if opts.Auth.Password != pw {
				t.Fatalf("mongo driver password round-trip: got %q, want %q", opts.Auth.Password, pw)
			}
			if opts.Auth.Username != "reader" {
				t.Fatalf("mongo driver username round-trip: got %q, want %q", opts.Auth.Username, "reader")
			}
		})
	}
}

// TestComposeMongoDSNEscapesUserinfo pins the escaping itself, not just
// its round trip: a raw "@" or "/" left in the userinfo would re-delimit
// the URI even when a lenient decoder happens to put it back together.
func TestComposeMongoDSNEscapesUserinfo(t *testing.T) {
	dsn, err := composeMongoDSN(mongoTarget(), "@/:?#%")
	if err != nil {
		t.Fatalf("composeMongoDSN: %v", err)
	}
	userinfo := strings.TrimPrefix(dsn, "mongodb://")
	userinfo = userinfo[:strings.LastIndex(userinfo, "@")]
	for _, raw := range []string{"@", "/", "?", "#"} {
		if strings.Contains(strings.TrimPrefix(userinfo, "reader:"), raw) {
			t.Fatalf("userinfo %q still contains a raw %q", userinfo, raw)
		}
	}
	if want := "reader:%40%2F%3A%3F%23%25"; userinfo != want {
		t.Fatalf("userinfo = %q, want %q", userinfo, want)
	}
}

func TestComposeMongoDSNRejectsBadFields(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*dbTarget)
		pw      string
		wantMsg string
	}{
		{name: "empty host", mutate: func(d *dbTarget) { d.Host = "" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "host with slash", mutate: func(d *dbTarget) { d.Host = "h/x" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "host with at sign", mutate: func(d *dbTarget) { d.Host = "h@x" }, pw: "pw", wantMsg: "invalid --host"},
		{name: "bad port", mutate: func(d *dbTarget) { d.Port = "-1" }, pw: "pw", wantMsg: "invalid --port"},
		{name: "db with dot", mutate: func(d *dbTarget) { d.DB = "a.b" }, pw: "pw", wantMsg: "invalid --db"},
		{name: "newline in user", mutate: func(d *dbTarget) { d.User = "a\nb" }, pw: "pw", wantMsg: "the --user value contains a control character"},
		{name: "NUL in password", mutate: func(d *dbTarget) {}, pw: "a\x00b", wantMsg: "the password value contains a control character"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			target := mongoTarget()
			tc.mutate(&target)
			dsn, err := composeMongoDSN(target, tc.pw)
			wantMessage(t, err, tc.wantMsg)
			if dsn != "" {
				t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
			}
		})
	}
}

// TestComposeMongoDSNAcceptsIPv6 pins that net.JoinHostPort's brackets
// survive the URI, so the operator types the bare address.
func TestComposeMongoDSNAcceptsIPv6(t *testing.T) {
	target := mongoTarget()
	target.Host = "::1"
	dsn, err := composeMongoDSN(target, "pw")
	if err != nil {
		t.Fatalf("composeMongoDSN: %v", err)
	}
	if !strings.Contains(dsn, "@[::1]:27017/app") {
		t.Fatalf("dsn = %q, want a bracketed IPv6 authority", dsn)
	}
}

// TestComposeMongoDSNAuthSource pins the flag against the parser that
// applies the rule it exists for. With no authSource option the driver
// authenticates against the database in the URI path, so a reader created
// in "admin" — the usual place for a least-privilege user — cannot
// authenticate at all. Both halves are measured here, not asserted.
func TestComposeMongoDSNAuthSource(t *testing.T) {
	// Default: the path database becomes the auth source.
	dsn, err := composeMongoDSN(mongoTarget(), "pw")
	if err != nil {
		t.Fatalf("composeMongoDSN: %v", err)
	}
	if strings.Contains(dsn, "authSource") {
		t.Fatalf("dsn = %q, want no authSource option when --auth-source is not given", dsn)
	}
	if got := options.Client().ApplyURI(dsn).Auth.AuthSource; got != "app" {
		t.Fatalf("default AuthSource = %q, want %q (the --db database)", got, "app")
	}

	// With --auth-source the option is explicit in the stored DSN and
	// the driver honours it.
	target := mongoTarget()
	target.AuthSource = "admin"
	dsn, err = composeMongoDSN(target, "pw")
	if err != nil {
		t.Fatalf("composeMongoDSN: %v", err)
	}
	if want := "mongodb://reader:pw@m.internal:27017/app?authSource=admin"; dsn != want {
		t.Fatalf("dsn = %q, want %q", dsn, want)
	}
	auth := options.Client().ApplyURI(dsn).Auth
	if auth == nil || auth.AuthSource != "admin" || auth.Username != "reader" || auth.Password != "pw" {
		t.Fatalf("driver read %+v, want user reader against authSource admin", auth)
	}
	// The database being READ is still --db, not the auth source.
	back, err := url.Parse(dsn)
	if err != nil {
		t.Fatalf("url.Parse: %v", err)
	}
	if strings.TrimPrefix(back.Path, "/") != "app" {
		t.Fatalf("path = %q, want the --db database %q", back.Path, "app")
	}
}

func TestComposeMongoDSNRejectsBadAuthSource(t *testing.T) {
	for _, as := range []string{"a b", "a/b", "a?b", "admin&x=1", "$external", "a\nb"} {
		t.Run(strconv.Quote(as), func(t *testing.T) {
			target := mongoTarget()
			target.AuthSource = as
			dsn, err := composeMongoDSN(target, "pw")
			wantMessage(t, err, "invalid --auth-source "+strconv.Quote(as))
			if dsn != "" {
				t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
			}
		})
	}
}

func TestComposeSQLiteDSN(t *testing.T) {
	cases := []struct {
		name    string
		path    string
		want    string
		wantMsg string
	}{
		{name: "plain absolute path", path: "/var/db/app.db", want: "file:/var/db/app.db?mode=ro"},
		// "?" and "#" inside a path would otherwise terminate it and
		// silently drop mode=ro.
		{name: "question mark in path", path: "/var/db/we?rd.db", want: "file:/var/db/we%3Frd.db?mode=ro"},
		{name: "hash in path", path: "/var/db/we#rd.db", want: "file:/var/db/we%23rd.db?mode=ro"},
		{name: "space in path", path: "/var/db/we rd.db", want: "file:/var/db/we%20rd.db?mode=ro"},
		{name: "relative path", path: "db/app.db", wantMsg: "must be absolute"},
		{name: "bare filename", path: "app.db", wantMsg: "must be absolute"},
		{name: "empty path", path: "", wantMsg: "must be absolute"},
		{name: "newline in path", path: "/var/db/a\nb.db", wantMsg: "the --db value contains a control character"},
		{name: "DEL in path", path: "/var/db/a\x7fb.db", wantMsg: "the --db value contains a control character"},
		// The round-trip backstop's live case: "//a/b.db" is absolute,
		// so it passes the check above, but url.URL.String() renders a
		// double-slashed path as the opaque "file:%2F/a/b.db" (to stop
		// it reading as an authority) and that has no Path at all when
		// parsed back. Composing it would store a DSN this code cannot
		// reason about.
		{name: "double leading slash", path: "//a/b.db", wantMsg: "could not compose a sqlite DSN that reads back unchanged"},
		{name: "triple leading slash", path: "///a/b.db", wantMsg: "could not compose a sqlite DSN that reads back unchanged"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dsn, err := composeSQLiteDSN(dbTarget{Driver: "sqlite", DB: tc.path})
			if tc.wantMsg != "" {
				wantMessage(t, err, tc.wantMsg)
				if dsn != "" {
					t.Fatalf("dsn = %q on a rejected compose, want %q", dsn, "")
				}
				return
			}
			if err != nil {
				t.Fatalf("composeSQLiteDSN: %v", err)
			}
			if dsn != tc.want {
				t.Fatalf("dsn = %q, want %q", dsn, tc.want)
			}
			// Whether these DSNs name the file the operator meant is
			// NOT decided by re-parsing them with net/url — that is
			// not the parser that opens them, and it disagrees with
			// the one that does (driver_sqlite.go: modernc.org/sqlite
			// splits at the first "?" and has no fragment concept).
			// TestComposeSQLiteDSNOpensTheIntendedFile settles it
			// against the real driver, on real files.
		})
	}
}

// TestComposeSQLiteDSNOpensTheIntendedFile is the oracle for the sqlite
// composer: a DSN it produces, handed to the code that actually consumes
// it, must open the exact file whose path was given and nothing else.
//
// "The code that actually consumes it" is wakilcore's registered sqlite
// driver — sqliteReadOnlyDSN plus modernc.org/sqlite — reached here
// through the public GetDriver/Connect surface, which is the same path
// wakil-db takes at runtime. Re-parsing the DSN with net/url instead
// would prove only that net/url agrees with itself: the two parsers
// deliberately differ, and every name below is a case where they can.
//
// Each file gets its own uniquely named table, so "it opened SOMETHING"
// cannot pass for "it opened the right file" — and if a "?" or "#" in the
// path silently truncated the filename, SQLite would create a fresh empty
// database instead of failing, which is precisely the outcome an
// assertion on the table name catches.
func TestComposeSQLiteDSNOpensTheIntendedFile(t *testing.T) {
	dir := t.TempDir()
	names := []string{"plain", "with space", "with%percent", "with#hash", "with?q", "with%2Fenc"}

	for i, name := range names {
		path := filepath.Join(dir, name+".db")
		marker := "marker_" + strconv.Itoa(i)
		seedSQLite(t, path, marker)

		dsn, err := composeSQLiteDSN(dbTarget{Driver: "sqlite", DB: path})
		if err != nil {
			t.Fatalf("composeSQLiteDSN(%q): %v", path, err)
		}

		drv, err := wakilcore.GetDriver("sqlite")
		if err != nil {
			t.Fatalf("GetDriver: %v", err)
		}
		conn, err := drv.Connect(context.Background(), wakilcore.Connection{Ref: "test", URL: dsn, ReadOnly: true})
		if err != nil {
			t.Fatalf("connect to %q (dsn %q): %v", path, dsn, err)
		}
		containers, err := conn.ListContainers(context.Background())
		if cerr := conn.Close(); cerr != nil {
			t.Fatalf("close: %v", cerr)
		}
		if err != nil {
			t.Fatalf("list tables in %q (dsn %q): %v", path, dsn, err)
		}
		var got []string
		for _, c := range containers {
			got = append(got, c.Name)
		}
		if len(got) != 1 || got[0] != marker {
			t.Fatalf("dsn %q opened a database whose tables are %v, want exactly [%s] — it opened the wrong file, or created a new one", dsn, got, marker)
		}
	}
}

// seedSQLite creates a database containing one table named marker and
// then moves it into place. It is written at a boring temporary name and
// renamed, so that seeding never has to reason about how the writing
// driver would interpret a "?" or "#" in the filename — the point of the
// test is what the COMPOSED DSN does with that name, not what a second,
// differently-composed path does.
func seedSQLite(t *testing.T, path, marker string) {
	t.Helper()
	tmp := filepath.Join(filepath.Dir(path), "seed.tmp.db")
	db, err := sql.Open("sqlite", tmp)
	if err != nil {
		t.Fatalf("open seed db: %v", err)
	}
	if _, err := db.Exec("CREATE TABLE " + marker + " (id INTEGER)"); err != nil {
		db.Close()
		t.Fatalf("create table: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close seed db: %v", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatalf("rename seed db to %q: %v", path, err)
	}
}

func TestComposeDBDSNUnknownDriver(t *testing.T) {
	_, err := composeDBDSN(dbTarget{Driver: "postgres"}, "pw")
	wantMessage(t, err, `unknown driver "postgres"`)
}

// ---------------------------------------------------------------------
// end-to-end through run()
// ---------------------------------------------------------------------

func TestRunSecretsSetStoresExactValue(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	var rec recorder
	var errb bytes.Buffer
	code := run([]string{"secrets", "set", "jira:initech"}, strings.NewReader("me@x.com:tok:en\n"), io.Discard, &errb, rec.store, failingReader(t))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0 (stderr: %s)", code, errb.String())
	}
	if len(rec.calls) != 1 {
		t.Fatalf("store called %d times, want 1", len(rec.calls))
	}
	if rec.calls[0].ref != "jira:initech" || rec.calls[0].value != "me@x.com:tok:en" {
		t.Fatalf("stored %q=%q, want %q=%q", rec.calls[0].ref, rec.calls[0].value, "jira:initech", "me@x.com:tok:en")
	}
	if !strings.Contains(errb.String(), "stored") {
		t.Fatalf("stderr = %q, want a confirmation line", errb.String())
	}
}

// TestRunSecretsSetStoresNothingOnBadStdin is the guard against the worst
// failure mode in this command: a stdin problem that ends with an empty or
// truncated credential in the Keychain and the word "stored" on the
// terminal. Each case asserts THREE things — a non-zero exit, that the
// store was never called at all, and that the confirmation line was never
// printed.
func TestRunSecretsSetStoresNothingOnBadStdin(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	cases := []struct {
		name    string
		in      io.Reader
		wantMsg string
	}{
		{name: "empty stdin", in: strings.NewReader(""), wantMsg: "no secret value on stdin"},
		{name: "newline only", in: strings.NewReader("\n"), wantMsg: "no secret value on stdin"},
		{name: "whitespace only", in: strings.NewReader("  \n"), wantMsg: "no secret value on stdin"},
		{name: "read fails immediately", in: immediateErrorReader{}, wantMsg: "could not read the secret value from stdin"},
		{name: "read fails after partial data", in: &partialThenErrorReader{data: []byte("s3cret")}, wantMsg: "could not read the secret value from stdin"},
		{name: "NUL in value", in: strings.NewReader("a\x00b\n"), wantMsg: "contains a NUL byte"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var rec recorder
			var errb bytes.Buffer
			code := run([]string{"secrets", "set", "ref"}, tc.in, io.Discard, &errb, rec.store, failingReader(t))
			if code == 0 {
				t.Fatalf("exit code = 0, want non-zero")
			}
			if len(rec.calls) != 0 {
				t.Fatalf("store was called with %+v, want no call at all", rec.calls)
			}
			if !strings.Contains(errb.String(), tc.wantMsg) {
				t.Fatalf("stderr = %q, want it to contain %q", errb.String(), tc.wantMsg)
			}
			if strings.Contains(errb.String(), "stored ") {
				t.Fatalf("stderr = %q, want no confirmation line", errb.String())
			}
		})
	}
}

func TestRunSecretsSetPropagatesStoreFailure(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	rec := recorder{err: wakilcore.UserError("could not write keychain entry for ref x: keychain is locked")}
	var errb bytes.Buffer
	code := run([]string{"secrets", "set", "x"}, strings.NewReader("v\n"), io.Discard, &errb, rec.store, failingReader(t))
	if code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errb.String(), "keychain is locked") {
		t.Fatalf("stderr = %q, want the store's own diagnostic", errb.String())
	}
	if strings.Contains(errb.String(), "stored \"x\"") {
		t.Fatalf("stderr = %q, want no confirmation line after a failed write", errb.String())
	}
}

func TestRunUsageErrorsExitTwo(t *testing.T) {
	for _, args := range [][]string{nil, {"nonsense"}, {"secrets", "set"}, {"secrets", "set", "-w"}, {"secrets", "set-db", "core", "--driver", "postgres"}} {
		var rec recorder
		var errb bytes.Buffer
		if code := run(args, strings.NewReader("v\n"), io.Discard, &errb, rec.store, failingReader(t)); code != 2 {
			t.Fatalf("run(%q) exit code = %d, want 2 (stderr: %s)", args, code, errb.String())
		}
		if len(rec.calls) != 0 {
			t.Fatalf("run(%q) stored %+v, want no call", args, rec.calls)
		}
	}
}

func TestRunSetDBStoresComposedDSN(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	cases := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{
			name:  "mysql",
			args:  []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "db.internal", "--port", "3306", "--db", "app", "--user", "reader"},
			stdin: "pa@ss/word\n",
			want:  "reader:pa@ss/word@tcp(db.internal:3306)/app?transaction_read_only=1",
		},
		{
			name:  "mongo",
			args:  []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "27017", "--db", "app", "--user", "reader"},
			stdin: "pa@ss/word\n",
			want:  "mongodb://reader:pa%40ss%2Fword@m.internal:27017/app",
		},
		{
			name:  "mongo with auth source",
			args:  []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "27017", "--db", "app", "--user", "reader", "--auth-source", "admin"},
			stdin: "pa@ss/word\n",
			want:  "mongodb://reader:pa%40ss%2Fword@m.internal:27017/app?authSource=admin",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var rec recorder
			var errb bytes.Buffer
			code := run(tc.args, strings.NewReader(tc.stdin), io.Discard, &errb, rec.store, failingReader(t))
			if code != 0 {
				t.Fatalf("exit code = %d, want 0 (stderr: %s)", code, errb.String())
			}
			if len(rec.calls) != 1 {
				t.Fatalf("store called %d times, want 1", len(rec.calls))
			}
			if rec.calls[0].ref != "core" || rec.calls[0].value != tc.want {
				t.Fatalf("stored %q=%q, want %q=%q", rec.calls[0].ref, rec.calls[0].value, "core", tc.want)
			}
			// The DSN carries the password; it must never be echoed.
			if strings.Contains(errb.String(), "pa@ss/word") || strings.Contains(errb.String(), rec.calls[0].value) {
				t.Fatalf("stderr = %q, want no password or DSN in it", errb.String())
			}
		})
	}
}

// TestRunSetDBSQLiteReadsNoStdin pins that the sqlite path never consults
// stdin: a sqlite "connection" has no password, and reading one would make
// readSecretValue's empty rejection fire on a valid registration.
func TestRunSetDBSQLiteReadsNoStdin(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	var rec recorder
	var errb bytes.Buffer
	code := run([]string{"secrets", "set-db", "local", "--driver", "sqlite", "--db", "/var/db/app.db"}, immediateErrorReader{}, io.Discard, &errb, rec.store, failingReader(t))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0 (stderr: %s)", code, errb.String())
	}
	if len(rec.calls) != 1 || rec.calls[0].value != "file:/var/db/app.db?mode=ro" {
		t.Fatalf("stored %+v, want file:/var/db/app.db?mode=ro", rec.calls)
	}
}

func TestRunSetDBStoresNothingOnBadStdin(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	args := []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--db", "app", "--user", "reader"}
	for _, tc := range []struct {
		name    string
		in      io.Reader
		wantMsg string
	}{
		{name: "empty", in: strings.NewReader(""), wantMsg: "no secret value on stdin"},
		{name: "read error after partial data", in: &partialThenErrorReader{data: []byte("pw")}, wantMsg: "could not read the secret value from stdin"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var rec recorder
			var errb bytes.Buffer
			if code := run(args, tc.in, io.Discard, &errb, rec.store, failingReader(t)); code == 0 {
				t.Fatal("exit code = 0, want non-zero")
			}
			if len(rec.calls) != 0 {
				t.Fatalf("store was called with %+v, want no call at all", rec.calls)
			}
			if !strings.Contains(errb.String(), tc.wantMsg) {
				t.Fatalf("stderr = %q, want it to contain %q", errb.String(), tc.wantMsg)
			}
			if strings.Contains(errb.String(), "stored ") {
				t.Fatalf("stderr = %q, want no confirmation line", errb.String())
			}
		})
	}
}

// TestRunSetDBStoresNothingWhenComposeFails covers the failure this
// subcommand exists to prevent, and the one place `secrets set` cannot
// have it: a compose error AFTER stdin has been read successfully. Drop
// composeDBDSN's error there and an EMPTY DSN is written to the Keychain
// while "stored" is printed and the command exits 0 — the operator has a
// credential-shaped hole under a ref that a project.json names, and finds
// out inside a Claude session.
//
// Each case reaches the composer with valid flag SHAPE (parseSecretsSetDB
// checks which flags are present, not what is in them) and a value only
// the composer rejects.
func TestRunSetDBStoresNothingWhenComposeFails(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	cases := []struct {
		name    string
		args    []string
		wantMsg string
	}{
		{
			// mysql.ParseDSN splits the userinfo at the first colon, so
			// a colon in the username cannot be expressed at all.
			name:    "mysql user with a colon",
			args:    []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--db", "app", "--user", "u:v"},
			wantMsg: "cannot be expressed in a go-sql-driver DSN",
		},
		{
			name:    "mysql host that is not an address",
			args:    []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", ":::::", "--port", "3306", "--db", "app", "--user", "reader"},
			wantMsg: `invalid --host ":::::"`,
		},
		{
			name:    "mongo port with a leading plus",
			args:    []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "+27017", "--db", "app", "--user", "reader"},
			wantMsg: `invalid --port "+27017"`,
		},
		{
			name:    "mongo auth source that is not a database name",
			args:    []string{"secrets", "set-db", "core", "--driver", "mongo", "--host", "m.internal", "--port", "27017", "--db", "app", "--user", "reader", "--auth-source", "admin&w=1"},
			wantMsg: "invalid --auth-source",
		},
		{
			// sqlite reads no stdin, so this one fails on the compose
			// with nothing else in the way.
			name:    "sqlite relative path",
			args:    []string{"secrets", "set-db", "local", "--driver", "sqlite", "--db", "relative/app.db"},
			wantMsg: "must be absolute",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var rec recorder
			var errb bytes.Buffer
			code := run(tc.args, strings.NewReader("hunter2\n"), io.Discard, &errb, rec.store, failingReader(t))
			if code != 2 {
				t.Fatalf("exit code = %d, want 2 (stderr: %s)", code, errb.String())
			}
			if len(rec.calls) != 0 {
				t.Fatalf("store was called with %+v, want no call at all", rec.calls)
			}
			if !strings.Contains(errb.String(), tc.wantMsg) {
				t.Fatalf("stderr = %q, want it to contain %q", errb.String(), tc.wantMsg)
			}
			if strings.Contains(errb.String(), "stored ") {
				t.Fatalf("stderr = %q, want no confirmation line", errb.String())
			}
			if strings.Contains(errb.String(), "hunter2") {
				t.Fatalf("stderr = %q, want no password in it", errb.String())
			}
		})
	}
}

// TestRunSetDBPropagatesStoreFailure is the `secrets set` test of the
// same name, for set-db: a Keychain write that fails must not be reported
// as a success.
func TestRunSetDBPropagatesStoreFailure(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	for _, tc := range []struct {
		name  string
		args  []string
		stdin string
	}{
		{
			name:  "mysql",
			args:  []string{"secrets", "set-db", "core", "--driver", "mysql", "--host", "h", "--port", "3306", "--db", "app", "--user", "reader"},
			stdin: "hunter2\n",
		},
		{
			// sqlite never reads stdin, so it reaches the store by a
			// different route through runSetDB.
			name:  "sqlite",
			args:  []string{"secrets", "set-db", "local", "--driver", "sqlite", "--db", "/var/db/app.db"},
			stdin: "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := recorder{err: wakilcore.UserError("could not write keychain entry for ref core: keychain is locked")}
			var errb bytes.Buffer
			code := run(tc.args, strings.NewReader(tc.stdin), io.Discard, &errb, rec.store, failingReader(t))
			if code != 1 {
				t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, errb.String())
			}
			if len(rec.calls) != 1 {
				t.Fatalf("store called %d times, want 1", len(rec.calls))
			}
			if !strings.Contains(errb.String(), "keychain is locked") {
				t.Fatalf("stderr = %q, want the store's own diagnostic", errb.String())
			}
			if strings.Contains(errb.String(), "stored ") {
				t.Fatalf("stderr = %q, want no confirmation line after a failed write", errb.String())
			}
		})
	}
}

// TestMessageLabelsUnclassifiedErrors pins both of message()'s branches.
// A wakilcore.UserError is shown exactly as written — no prefix, nothing
// added — and anything else is shown with a prefix saying so, because an
// unclassified error reaching this terminal is a bug and the errors this
// command must never print verbatim (mysql.ParseDSN's, which quotes the
// DSN and therefore the password) are exactly the unclassified kind.
//
// The store seam is what makes the second branch reachable: it is the one
// place run() takes an error it did not construct.
func TestMessageLabelsUnclassifiedErrors(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	const prefix = "unexpected error (not an operator-facing message, so it may quote internals): "

	if got := message(wakilcore.UserError("no secret value on stdin")); got != "no secret value on stdin" {
		t.Fatalf("message(UserError) = %q, want it verbatim", got)
	}
	if got := message(errors.New("boom")); got != prefix+"boom" {
		t.Fatalf("message(plain error) = %q, want %q", got, prefix+"boom")
	}

	// End to end: a curated store failure is printed clean...
	rec := recorder{err: wakilcore.UserError("keychain is locked")}
	var errb bytes.Buffer
	if code := run([]string{"secrets", "set", "x"}, strings.NewReader("v\n"), io.Discard, &errb, rec.store, failingReader(t)); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errb.String(), "keychain is locked") || strings.Contains(errb.String(), "unexpected error") {
		t.Fatalf("stderr = %q, want the curated message with no unexpected-error label", errb.String())
	}

	// ...and an unclassified one is labelled.
	rec = recorder{err: errors.New("exit status 1: security: SecKeychainAddGenericPassword")}
	errb.Reset()
	if code := run([]string{"secrets", "set", "x"}, strings.NewReader("v\n"), io.Discard, &errb, rec.store, failingReader(t)); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	if !strings.Contains(errb.String(), prefix) {
		t.Fatalf("stderr = %q, want it to contain %q", errb.String(), prefix)
	}
	if !strings.Contains(errb.String(), "SecKeychainAddGenericPassword") {
		t.Fatalf("stderr = %q, want the underlying diagnostic kept", errb.String())
	}
}

// ---------------------------------------------------------------------
// org scoping (see wakilcore.keychainService)
// ---------------------------------------------------------------------

// TestRunSecretsSetNamesTheOrgOnBothSides pins that the org this command
// stores under is shown to the operator twice: in the prompt, where it can
// still be aborted, and in the confirmation, where it becomes the record
// in the terminal scrollback.
//
// This is not cosmetic. Credentials are now addressed as
// "wakil:<org>:<ref>", and the org comes from WAKIL_ORG at the moment of
// the call. An operator who stores under the wrong org writes a
// credential that no MCP server ever reads: the write succeeds, the read
// fails much later somewhere else, and the org printed here is what makes
// the mismatch visible at the point it is created rather than at the
// point it hurts.
func TestRunSecretsSetNamesTheOrgOnBothSides(t *testing.T) {
	t.Setenv("WAKIL_ORG", "umbrella")
	var rec recorder
	var errb bytes.Buffer
	code := run([]string{"secrets", "set", "db:staging"}, strings.NewReader("a-dsn\n"), io.Discard, &errb, rec.store, failingReader(t))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0 (stderr: %s)", code, errb.String())
	}
	out := errb.String()
	if !strings.Contains(out, `Paste the secret for "db:staging" in org "umbrella"`) {
		t.Errorf("prompt does not name the org, so the operator cannot abort before pasting: %q", out)
	}
	if !strings.Contains(out, `stored "db:staging" in the keychain for org "umbrella"`) {
		t.Errorf("confirmation does not name the org: %q", out)
	}
}

// TestRunSecretsSetDBNamesTheOrg pins the same for set-db. The sqlite case
// is the one that matters here: it never prompts, so the confirmation line
// is the ONLY place the org can appear.
func TestRunSecretsSetDBNamesTheOrg(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	var rec recorder
	var errb bytes.Buffer
	code := run([]string{"secrets", "set-db", "core", "--driver", "sqlite", "--db", "/var/db/app.db"},
		strings.NewReader(""), io.Discard, &errb, rec.store, failingReader(t))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0 (stderr: %s)", code, errb.String())
	}
	if !strings.Contains(errb.String(), `in the keychain for org "initech"`) {
		t.Errorf("confirmation does not name the org: %q", errb.String())
	}
}

// TestRunSecretsSetRefusesAnUnusableOrgBeforePrompting pins that an org id
// validateOrgToken cannot accept is rejected BEFORE the paste prompt and
// before anything is stored.
//
// wakilcore.SecretSet would refuse it anyway and store nothing, so the
// safety property is not what is being tested. What is being tested is
// that the operator is never asked to type a real credential into a
// terminal for a call that was already certain to fail.
func TestRunSecretsSetRefusesAnUnusableOrgBeforePrompting(t *testing.T) {
	for _, org := range []string{"/", "a:b"} {
		t.Run(org, func(t *testing.T) {
			t.Setenv("WAKIL_ORG", org)
			var rec recorder
			var errb bytes.Buffer
			code := run([]string{"secrets", "set", "db:staging"}, strings.NewReader("a-dsn\n"), io.Discard, &errb, rec.store, failingReader(t))
			if code != 2 {
				t.Fatalf("exit code = %d, want 2 (stderr: %s)", code, errb.String())
			}
			if len(rec.calls) != 0 {
				t.Fatalf("store was called %d times, want 0", len(rec.calls))
			}
			if strings.Contains(errb.String(), "Paste") {
				t.Fatalf("the operator was prompted for a secret that could never be stored: %q", errb.String())
			}
			if !strings.Contains(errb.String(), "unusable org id") {
				t.Fatalf("rejection does not name the org problem: %q", errb.String())
			}
		})
	}
}

// 3a-iii-a: the credential helper and askpass git calls back into. They answer from the
// organisation's Keychain items for the host, and print nothing else.
func TestGitCredentialAnswersFromTheKeychain(t *testing.T) {
	read := func(ref string) (string, error) {
		if ref == "git-github.com-token" {
			return "tok-1", nil
		}
		return "", nil
	}
	var out, errb bytes.Buffer
	code := runGitCredential([]string{"--host", "github.com", "get"}, strings.NewReader("protocol=https\nhost=github.com\n\n"), &out, &errb, read,
		func(host string) (wakilcore.GitAccount, bool) {
			return wakilcore.GitAccount{Host: host, Provider: "github", Method: "token"}, true
		})
	if code != 0 || out.String() != "username=x-access-token\npassword=tok-1\n" {
		t.Fatalf("code %d out %q err %q", code, out.String(), errb.String())
	}
	out.Reset()
	if code := runGitCredential([]string{"--host", "github.com", "store"}, strings.NewReader(""), &out, &errb, read, nil); code != 0 || out.Len() != 0 {
		t.Fatalf("store must do nothing: %d %q", code, out.String())
	}
}

func TestGitAskpassPrintsThePassphrase(t *testing.T) {
	read := func(ref string) (string, error) {
		if ref == "git-github.com-ssh-passphrase" {
			return "pp-1", nil
		}
		return "", nil
	}
	var out, errb bytes.Buffer
	if code := runGitAskpass([]string{"--host", "github.com", "Enter passphrase for key:"}, &out, &errb, read); code != 0 || out.String() != "pp-1\n" {
		t.Fatalf("code %d out %q", code, out.String())
	}
}

// Review C1: ssh calls the askpass as `<wakil> <prompt>` — one program path, the prompt its only
// argument — so the host comes from WAKIL_ASKPASS_HOST.
func TestAskpassAsSSHCallsIt(t *testing.T) {
	t.Setenv("WAKIL_ASKPASS_HOST", "github.com")
	read := func(ref string) (string, error) {
		if ref == "git-github.com-ssh-passphrase" {
			return "pp-1", nil
		}
		return "", nil
	}
	var out, errb bytes.Buffer
	if code := run([]string{"Enter passphrase for key '/k/id': "}, strings.NewReader(""), &out, &errb, nil, read); code != 0 || out.String() != "pp-1\n" {
		t.Fatalf("code %d out %q err %q", code, out.String(), errb.String())
	}
	// A real subcommand under the same environment still runs as itself.
	out.Reset()
	if code := run([]string{"git-credential", "--host", "github.com", "store"}, strings.NewReader(""), &out, &errb, nil, read); code != 0 || out.Len() != 0 {
		t.Fatalf("subcommand hijacked: %d %q", code, out.String())
	}
}

// Review C2: the helper's -c reaches every git process the command starts — a submodule on another
// host, a push URL elsewhere — so it answers only a request for https on its own host.
func TestGitCredentialAnswersOnlyItsOwnHost(t *testing.T) {
	read := func(string) (string, error) { return "tok-1", nil }
	account := func(host string) (wakilcore.GitAccount, bool) {
		return wakilcore.GitAccount{Host: host, Provider: "github", Method: "token"}, true
	}
	for _, req := range []string{
		"protocol=https\nhost=git.corp.example\n\n",
		"protocol=http\nhost=github.com\n\n",
		"protocol=https\n\n",
	} {
		var out, errb bytes.Buffer
		if code := runGitCredential([]string{"--host", "github.com", "get"}, strings.NewReader(req), &out, &errb, read, account); code != 0 || out.Len() != 0 {
			t.Errorf("request %q: code %d out %q", req, code, out.String())
		}
	}
}
