package wakilcore

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// NOTE ON KEYCHAIN SAFETY. Only TestKeychainRoundTrip below touches the
// real login keychain, and it is gated behind WAKIL_KEYCHAIN_TEST=1 which
// nothing in this repository sets. Every other test in this file either
// exercises keychainService — a pure function that builds a string and
// never execs anything — or overrides `securityBinary` to point at a temp
// dir holding a fake `security` script. Neither route can reach the
// operator's credentials.
//
// The override replaced a PATH-based fake in 2e (#201), when the product
// started invoking the tool by its absolute path. A PATH fake stopped
// intercepting at that moment, which would have pointed these tests at
// the real keychain silently.

func TestSecretGetMissingSecurityBinary(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	// Pointed at a path that does not exist, rather than at an empty
	// PATH: the product invokes the Keychain tool by absolute path now
	// (#201), so "not installed" is a missing file and not an unresolvable
	// name.
	previous := securityBinary
	securityBinary = keychainTool(filepath.Join(t.TempDir(), "security"))
	t.Cleanup(func() { securityBinary = previous })

	_, err := SecretGet("some-ref")
	if err == nil {
		t.Fatal("expected error when the security binary is not installed")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v", err)
	}
	idx := strings.Index(msg, ": ")
	if idx == -1 || strings.TrimSpace(msg[idx+2:]) == "" {
		t.Fatalf("expected a non-empty diagnostic after the colon, got %q", msg)
	}
	if !strings.Contains(msg, "not found") && !strings.Contains(msg, "no such file") {
		t.Fatalf("expected message to mention the executable not being found, got %q", msg)
	}
}

// ---------------------------------------------------------------------
// keychainService — the org-scoped credential namespace
// ---------------------------------------------------------------------

// TestKeychainServiceScopesTheRefToTheOrg is the regression test for the
// cross-org credential-sharing bug: while the service name was
// "wakil:"+ref, two orgs whose project.json files both named "db:staging"
// read and overwrote ONE Keychain item.
//
// It asserts the literal names rather than "the two differ", because
// "differ" alone is satisfied by any scheme at all, including one that
// mixes org and ref in an order that could collide. The literal is also
// the persistence key: real credentials live at these exact addresses in
// an operator's login Keychain, so changing the scheme orphans them and
// must fail here loudly rather than pass quietly.
//
// A mutant that ignores org (`return "wakil:" + ref, nil`) fails on the
// first case's want, and would ALSO fail the distinctness check below —
// which is the specific property the finding was about.
func TestKeychainServiceScopesTheRefToTheOrg(t *testing.T) {
	cases := []struct{ org, ref, want string }{
		{"initech", "db:staging", "wakil:initech:db:staging"},
		{"umbrella", "db:staging", "wakil:umbrella:db:staging"},
		{"default", "booking-staging-core", "wakil:default:booking-staging-core"},
		// Jira's ref is itself org-scoped, so the org appears twice.
		// Deliberate and left alone — see keychainService's doc comment.
		{"initech", "jira:initech", "wakil:initech:jira:initech"},
	}
	for _, c := range cases {
		got, err := keychainService(c.org, c.ref)
		if err != nil {
			t.Fatalf("keychainService(%q, %q): unexpected error %v", c.org, c.ref, err)
		}
		if got != c.want {
			t.Errorf("keychainService(%q, %q) = %q, want %q", c.org, c.ref, got, c.want)
		}
	}

	a, err := keychainService("initech", "db:staging")
	if err != nil {
		t.Fatalf("keychainService: %v", err)
	}
	b, err := keychainService("umbrella", "db:staging")
	if err != nil {
		t.Fatalf("keychainService: %v", err)
	}
	if a == b {
		t.Fatalf("two orgs naming the same ref share one Keychain item (%q) — the cross-org credential leak is back", a)
	}
}

// TestKeychainServiceRefusesAnOrgItCannotNameSafely pins that an org id
// which cannot be used as a service-name component is a clean UserError
// rather than a silently-degraded name.
//
// "a:b" is the entry that matters most for THIS function specifically,
// and it is why the pattern's ban on ":" is load-bearing rather than
// incidental — see the collision test below.
func TestKeychainServiceRefusesAnOrgItCannotNameSafely(t *testing.T) {
	for _, org := range []string{"/", "..", ".", "", "a:b", "my org", "-x", "a\nb", "orgé"} {
		got, err := keychainService(org, "db:staging")
		if err == nil {
			t.Errorf("keychainService(%q, ...) = %q, want a rejection", org, got)
			continue
		}
		msg, ok := IsUserError(err)
		if !ok {
			t.Errorf("keychainService(%q, ...) returned %v, want a UserError an operator can act on", org, err)
			continue
		}
		if !strings.Contains(msg, "unusable org id") {
			t.Errorf("keychainService(%q, ...) message %q does not name the unusable org id", org, msg)
		}
	}
}

// TestKeychainServiceCannotCollideAcrossOrgs pins the reason the org is
// validated at all.
//
// The `security` CLI itself constrains nothing — measured against a
// throwaway keychain, it accepts "/", "..", "", a space, a newline and
// non-ASCII in a service name and round-trips the value unchanged. The
// real constraint is the ":" delimiter: cmd/wakil's refPattern permits
// ":" inside a ref (that is how "db:staging" is written), so if an org
// could contain one too, org "a:b"+ref "c" and org "a"+ref "b:c" would
// address the identical item "wakil:a:b:c" — the same cross-org sharing
// bug in a new costume.
//
// Deleting the ":" from orgFileTokenPattern's character class is the
// mutation this test exists to kill.
func TestKeychainServiceCannotCollideAcrossOrgs(t *testing.T) {
	valid, err := keychainService("a", "b:c")
	if err != nil {
		t.Fatalf("keychainService(\"a\", \"b:c\"): %v", err)
	}
	colliding, err := keychainService("a:b", "c")
	if err == nil {
		t.Fatalf("org %q was accepted and produced %q; ref %q under org %q already produces %q, so the two orgs would share one credential",
			"a:b", colliding, "b:c", "a", valid)
	}
}

// ---------------------------------------------------------------------
// SecretGet — the org reaches `security`, and the not-found message is
// the migration instruction
// ---------------------------------------------------------------------

// fakeSecurity writes a `security` script to a temp dir, puts ONLY that
// dir on PATH, and returns the path of the file the script records its
// own argv into. exitCode is what the script exits with, so a caller can
// drive SecretGet down either the not-found branch (44) or the success
// branch (0).
//
// This is what keeps these tests away from /usr/bin/security and thus
// away from the operator's real credentials, while still exercising the
// actual exec.Command call rather than a stub of it.
//
// stdout is emitted via `cat` on a fixture FILE, not inlined into the
// script text. Measured directly (see task-2-3-report.md): embedding
// stdout with strconv.Quote and printing it via `printf '%s'` only round
// trips when stdout has no control characters. strconv.Quote renders a
// real newline byte as the two characters backslash-n — correct Go
// SOURCE syntax, meant for a Go compiler to re-expand — but the receiving
// interpreter here is /bin/sh, whose printf does not expand backslash
// escapes inside a %s argument, so the newline never comes back; the
// script instead prints a literal backslash and an "n". That silently
// broke on the first stdout containing "\n", which SecretGet's own
// output always does. Writing the bytes to a file and `cat`-ing it makes
// the transport a filesystem read, with no interpreter re-escaping stdout
// at all, so it is verbatim for any byte sequence.
//
// **The fake is reached by overriding `securityBinary`, not by PATH**
// (2e, #201). The product now invokes the Keychain tool by its ABSOLUTE
// path, because the ACL on the CLI's own item names `/usr/bin/security`
// and a bare name resolved off PATH is a different application as far as
// that ACL is concerned. A PATH-based fake therefore stopped intercepting
// anything the moment that defect was paid — and, worse, would have let
// these tests reach the operator's real keychain without failing. The
// override is restored by `t.Cleanup`.
//
// PATH is still widened rather than narrowed, for the reason measured
// earlier: `cat` is an external binary, not a shell builtin, so a PATH
// holding only the fake dir leaves the script's own `cat` unresolvable and
// every caller gets an empty string with no error.
func fakeSecurity(t *testing.T, exitCode int, stdout string) (argsFile string) {
	t.Helper()
	dir := t.TempDir()
	argsPath := filepath.Join(dir, "args.txt")
	stdoutPath := filepath.Join(dir, "stdout.bin")
	if err := os.WriteFile(stdoutPath, []byte(stdout), 0o644); err != nil {
		t.Fatalf("write fake security stdout fixture: %v", err)
	}
	body := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + strconv.Quote(argsPath) +
		"\ncat " + strconv.Quote(stdoutPath) + "\nexit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "security"), []byte(body), 0o755); err != nil {
		t.Fatalf("write fake security binary: %v", err)
	}
	fake := filepath.Join(dir, "security")
	previous := securityBinary
	securityBinary = keychainTool(fake)
	t.Cleanup(func() { securityBinary = previous })
	return argsPath
}

// serviceArg returns the value `security` was invoked with after -s.
func serviceArg(t *testing.T, argsFile string) string {
	t.Helper()
	raw, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatalf("fake security recorded no invocation (%v) — SecretGet never ran it", err)
	}
	args := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	for i, a := range args {
		if a == "-s" && i+1 < len(args) {
			return args[i+1]
		}
	}
	t.Fatalf("no -s argument in recorded invocation %v", args)
	return ""
}

// TestSecretGetQueriesTheCurrentOrgsService pins that the org SecretGet
// puts in the service name is the one WAKIL_ORG names — not a constant,
// and not the ref's own contents. A mutant that drops the org from
// keychainService, or that reads the org from anywhere but CurrentOrg(),
// fails here with the wrong -s value.
func TestSecretGetQueriesTheCurrentOrgsService(t *testing.T) {
	t.Setenv("WAKIL_ORG", "umbrella")
	argsFile := fakeSecurity(t, 0, "the-dsn")

	got, err := SecretGet("db:staging")
	if err != nil {
		t.Fatalf("SecretGet: %v", err)
	}
	if got != "the-dsn" {
		t.Errorf("SecretGet returned %q, want %q", got, "the-dsn")
	}
	if svc := serviceArg(t, argsFile); svc != "wakil:umbrella:db:staging" {
		t.Errorf("security was queried for service %q, want %q", svc, "wakil:umbrella:db:staging")
	}
}

// TestSecretGetNotFoundNamesTheOrgAndTheMigration pins the message on the
// exit-44 path, which is the exact path every already-stored credential
// now lands on: org-scoping the service name orphaned all of them.
//
// A bare "item not found" here would read as data loss to an operator
// whose setup worked yesterday. The message must instead name the ref,
// name the org (the other way to reach 44 is storing with WAKIL_ORG set
// to one org while the servers run with it set to another), and point at
// the one-time re-store.
func TestSecretGetNotFoundNamesTheOrgAndTheMigration(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	fakeSecurity(t, keychainNotFoundExitCode, "")

	_, err := SecretGet("db:staging")
	if err == nil {
		t.Fatal("expected an error when the keychain item is absent")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v", err)
	}
	for _, want := range []string{"db:staging", "initech", "wakil secrets set", "MIGRATION", "operator-todo.md"} {
		if !strings.Contains(msg, want) {
			t.Errorf("not-found message %q does not mention %q", msg, want)
		}
	}
}

// TestSecretGetRefusesAnUnusableOrgBeforeRunningSecurity pins that a bad
// org is rejected as a UserError and, critically, that `security` is
// never invoked with a degraded name. The absence of the args file is the
// proof: the fake script writes it on every invocation.
func TestSecretGetRefusesAnUnusableOrgBeforeRunningSecurity(t *testing.T) {
	t.Setenv("WAKIL_ORG", "/")
	argsFile := fakeSecurity(t, 0, "should-never-be-read")

	if _, err := SecretGet("db:staging"); err == nil {
		t.Fatal("expected SecretGet to refuse an org of \"/\"")
	} else if _, ok := IsUserError(err); !ok {
		t.Fatalf("expected a UserError, got %v", err)
	}
	if _, err := os.Stat(argsFile); err == nil {
		t.Fatal("security was invoked despite the org being unusable — a degraded service name reached the keychain")
	}
}

// TestSecretGetStripsExactlyOneTrailingNewline pins the read half of a
// contract the write half already documents: readSecretValue strips at most
// ONE trailing newline, and cmd/wakil's help tells an operator to pipe a
// second newline when the secret itself must end in one (a PEM key is the
// motivating case). `security ... -w` then adds exactly one newline of its
// own when printing. TrimRight(…, "\n") removed BOTH, silently truncating
// the value, and made the two doc comments contradict each other.
func TestSecretGetStripsExactlyOneTrailingNewline(t *testing.T) {
	for _, tc := range []struct{ name, stored, want string }{
		{"ordinary secret", "hunter2", "hunter2"},
		{"secret that ends in a newline", "-----END KEY-----\n", "-----END KEY-----\n"},
		{"secret that ends in two newlines", "a\n\n", "a\n\n"},
		{"secret with interior newlines", "line1\nline2", "line1\nline2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("WAKIL_ORG", "testorg")
			// fakeSecurity emits its stdout with printf '%s' — exactly the
			// bytes given, no newline of its own — so the "\n" appended here
			// is standing in for the one the real `security -w` adds.
			fakeSecurity(t, 0, tc.stored+"\n")

			got, err := SecretGet("db:staging")
			if err != nil {
				t.Fatalf("SecretGet: %v", err)
			}
			if got != tc.want {
				t.Errorf("SecretGet returned %q, want %q — the value stored was %q",
					got, tc.want, tc.stored)
			}
		})
	}
}

// TestKeychainRoundTrip is the one test here that uses the REAL login
// keychain, and it only runs when the operator sets WAKIL_KEYCHAIN_TEST=1
// by hand (see docs/wakil/operator-todo.md). Nothing in this repository
// sets it, and no agent may.
func TestKeychainRoundTrip(t *testing.T) {
	if os.Getenv("WAKIL_KEYCHAIN_TEST") != "1" {
		t.Skip("set WAKIL_KEYCHAIN_TEST=1 to run the real-keychain spike test")
	}
	// Pinned rather than inherited, so the item this test creates and
	// deletes is always the same one no matter which org's shell the
	// operator happens to run it from.
	t.Setenv("WAKIL_ORG", "wakilselftest")
	ref := "wakil-unit-test-ref"
	t.Cleanup(func() {
		org, err := CurrentOrg()
		if err != nil {
			t.Errorf("cleanup could not determine the org: %v", err)
			return
		}
		service, err := keychainService(org, ref)
		if err != nil {
			t.Errorf("cleanup could not build the service name: %v", err)
			return
		}
		_ = exec.Command("security", "delete-generic-password",
			"-s", service, "-a", keychainAccount).Run()
	})
	if err := SecretSet(ref, "hunter2://db"); err != nil {
		t.Fatalf("SecretSet: %v", err)
	}
	got, err := SecretGet(ref)
	if err != nil {
		t.Fatalf("SecretGet: %v", err)
	}
	if got != "hunter2://db" {
		t.Fatalf("got %q", got)
	}
	if _, err := SecretGet("definitely-missing-ref"); err == nil {
		t.Fatal("missing ref should error")
	}
}

// TestDecodeKeychainHexUndoesSecuritysEncoding pins the repair for the
// defect an operator hit on the 2b-vi acceptance walk, 2026-09-11: a token
// stored with a trailing newline came back from `security -w` as lowercase
// hex, was handed to `claude` verbatim as CLAUDE_CODE_OAUTH_TOKEN, and
// produced `401 Invalid bearer token` with nothing upstream reporting a
// fault. The hex string below is the real measured output for the value
// "sk-ant-oat0-PROBE2222\n".
func TestDecodeKeychainHexUndoesSecuritysEncoding(t *testing.T) {
	const encoded = "736b2d616e742d6f6174302d50524f4245323232320a"
	const line = `password: 0x736B2D616E742D6F6174302D50524F4245323232320A  "sk-ant-oat0-PROBE2222\012"`
	if got, want := decodeKeychainHex(encoded, line), "sk-ant-oat0-PROBE2222"; got != want {
		t.Fatalf("decodeKeychainHex = %q, want %q", got, want)
	}
}

// TestDecodeKeychainHexLeavesOrdinarySecretsAlone is the other half, and
// the one that would make this repair dangerous if it were wrong: every
// value `security` prints verbatim must survive untouched.
func TestDecodeKeychainHexLeavesOrdinarySecretsAlone(t *testing.T) {
	for _, s := range []string{
		"",                      // absent
		"sk-ant-oat0-PROBE2222", // the ordinary token case
		"hunter2",
		"abc",        // hex digits, but odd length
		"zzzz",       // even length, not hex
		"deadbeefzz", // starts hex, is not
		// THE CASE THAT KILLED THE FIRST VERSION OF THIS FIX. This is the
		// real token httpclient_test.go authenticates with: even length,
		// every character a hex digit, and an entirely ordinary secret. A
		// rule that inspected only the value decoded it into nine bytes of
		// binary and the request failed with `invalid header field value`.
		// Without the `-g` marker below, it must be returned untouched.
		"0123456789abcdef01",
	} {
		if got := decodeKeychainHex(s, `password: "`+s+`"`); got != s {
			t.Fatalf("decodeKeychainHex(%q) = %q, want it unchanged", s, got)
		}
		if got := decodeKeychainHex(s, ""); got != s {
			t.Fatalf("decodeKeychainHex(%q) with no -g line = %q, want it unchanged", s, got)
		}
	}
}
