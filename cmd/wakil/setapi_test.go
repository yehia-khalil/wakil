package main

import (
	"bytes"
	"encoding/base64"
	"flag"
	"io"
	"strings"
	"testing"
)

// NOTE ON KEYCHAIN SAFETY: the same rule as main_test.go. Every test here
// drives run() with the recorder, never wakilcore.SecretSet.

// ---------------------------------------------------------------------
// `secrets set-api` parsing — the shape refusals
// ---------------------------------------------------------------------

// The four shape refusals fire before a byte of stdin is read, in the
// order the ticket fixes: missing/unrecognised --auth, --user under
// bearer, missing --user under basic, a --user containing a colon. Each
// case below carries a SECOND mistake that a later guard would also
// catch, so the test pins the ORDER rather than merely the set.
func TestParseSecretsSetAPIRefusals(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		wantMsg string
	}{
		{
			name:    "unknown command",
			args:    []string{"secrets", "set-apy", "x"},
			wantMsg: "unknown command",
		},
		{
			name:    "missing ref",
			args:    []string{"secrets", "set-api"},
			wantMsg: "missing <ref>",
		},
		{
			name:    "missing --auth wins over a colon in --user",
			args:    []string{"secrets", "set-api", "billing", "--user", "a:b"},
			wantMsg: "missing required flag --auth",
		},
		{
			name:    "unrecognised --auth wins over a colon in --user",
			args:    []string{"secrets", "set-api", "billing", "--auth", "digest", "--user", "a:b"},
			wantMsg: `unknown --auth "digest"`,
		},
		{
			name:    "--user under bearer wins over the colon in it",
			args:    []string{"secrets", "set-api", "billing", "--auth", "bearer", "--user", "a:b"},
			wantMsg: "--user does not apply to --auth bearer",
		},
		{
			name:    "missing --user under basic",
			args:    []string{"secrets", "set-api", "billing", "--auth", "basic"},
			wantMsg: "missing required flag --user for --auth basic",
		},
		{
			name:    "a colon in --user under basic",
			args:    []string{"secrets", "set-api", "billing", "--auth", "basic", "--user", "ad:min"},
			wantMsg: "--user contains a colon",
		},
		{
			name:    "a trailing positional is the credential on argv",
			args:    []string{"secrets", "set-api", "billing", "--auth", "bearer", "sk-live-1234"},
			wantMsg: "read from stdin, never from the command line",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := parseSecretsSetAPI(tc.args)
			wantMessage(t, err, tc.wantMsg)
		})
	}
}

// Every refusal this command makes names `wakil secrets set` — backticked,
// so the assertion cannot pass on the "wakil secrets set-api" that usage
// itself contains. The aid composes; when it will not, the operator needs
// the one command that stores a complete header value verbatim.
func TestSetAPIRefusalsNameTheEscape(t *testing.T) {
	shape := [][]string{
		{"secrets", "set-api", "billing"},
		{"secrets", "set-api", "billing", "--auth", "digest"},
		{"secrets", "set-api", "billing", "--auth", "bearer", "--user", "u"},
		{"secrets", "set-api", "billing", "--auth", "basic"},
		{"secrets", "set-api", "billing", "--auth", "basic", "--user", "a:b"},
	}
	for _, args := range shape {
		_, _, err := parseSecretsSetAPI(args)
		wantMessage(t, err, "`wakil secrets set`")
	}
	for _, secret := range []string{"Bearer sk-1", "sk live"} {
		_, err := composeAPIHeaderValue(apiTarget{Auth: authBearer}, secret)
		wantMessage(t, err, "`wakil secrets set`")
	}
}

func TestParseSecretsSetAPIHappy(t *testing.T) {
	ref, target, err := parseSecretsSetAPI([]string{"secrets", "set-api", "billing", "--auth", "bearer"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ref != "billing" || target.Auth != authBearer || target.User != "" {
		t.Fatalf("parsed ref=%q target=%+v, want billing / bearer / no user", ref, target)
	}
	ref, target, err = parseSecretsSetAPI([]string{"secrets", "set-api", "auth", "--auth", "basic", "--user", "svc"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ref != "auth" || target.Auth != authBasic || target.User != "svc" {
		t.Fatalf("parsed ref=%q target=%+v, want auth / basic / svc", ref, target)
	}
}

// ---------------------------------------------------------------------
// composing the header value
// ---------------------------------------------------------------------

func TestComposeAPIHeaderValue(t *testing.T) {
	cases := []struct {
		name   string
		target apiTarget
		secret string
		want   string
	}{
		{
			name:   "bearer, one space per RFC 9110",
			target: apiTarget{Auth: authBearer},
			secret: "sk-live-1234",
			want:   "Bearer sk-live-1234",
		},
		{
			name:   "basic base64s the pair",
			target: apiTarget{Auth: authBasic, User: "svc"},
			secret: "hunter2",
			want:   "Basic " + base64.StdEncoding.EncodeToString([]byte("svc:hunter2")),
		},
		{
			// A password is a password: the guards that protect a bearer
			// token do not apply to the basic half, because every byte
			// they would refuse is one a real password may contain.
			name:   "a basic password may contain anything",
			target: apiTarget{Auth: authBasic, User: "svc"},
			secret: "Bearer a b\tc:d ",
			want:   "Basic " + base64.StdEncoding.EncodeToString([]byte("svc:Bearer a b\tc:d ")),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := composeAPIHeaderValue(tc.target, tc.secret)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("composed %q, want %q", got, tc.want)
			}
		})
	}
}

// The double-prefix check runs BEFORE the whitespace check, so a
// double-prefixed token is diagnosed as the mistake the operator actually
// made rather than as the space that mistake happens to contain.
func TestComposeAPIHeaderValueBearerRefusals(t *testing.T) {
	cases := []struct {
		name    string
		secret  string
		wantMsg string
	}{
		{"already prefixed", "Bearer sk-live-1234", "already begins with a scheme"},
		{"prefixed in any case", "bEaRer sk-live-1234", "already begins with a scheme"},
		{"prefixed with the other scheme", "basic abc123", "already begins with a scheme"},
		{"interior space", "sk live 1234", "contains a space or tab"},
		{"interior tab", "sk\tlive", "contains a space or tab"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := composeAPIHeaderValue(apiTarget{Auth: authBearer}, tc.secret)
			wantMessage(t, err, tc.wantMsg)
			if got != "" {
				t.Fatalf("composed %q on a refusal, want nothing", got)
			}
		})
	}
}

// "bearerish" is a whole first WORD, not a prefix: a token that merely
// starts with those letters is a token, and refusing it would send the
// operator to `wakil secrets set` for a value this command composes fine.
func TestComposeAPIHeaderValueAcceptsBearerishTokens(t *testing.T) {
	for _, secret := range []string{"bearerish-token", "Basically-a-token", "bearer.token"} {
		if _, err := composeAPIHeaderValue(apiTarget{Auth: authBearer}, secret); err != nil {
			t.Fatalf("composing %q: unexpected refusal %v", secret, err)
		}
	}
}

// ---------------------------------------------------------------------
// end to end through run()
// ---------------------------------------------------------------------

func TestRunSetAPIStoresComposedValue(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	cases := []struct {
		name  string
		args  []string
		stdin string
		want  string
	}{
		{
			name: "bearer",
			args: []string{"secrets", "set-api", "billing", "--auth", "bearer"},
			// The paste that ends in a newline — `claude setup-token`'s
			// output, then Enter, then Ctrl-D — is absorbed, not refused
			// for whitespace it does not have.
			stdin: "sk-live-1234\n",
			want:  "Bearer sk-live-1234",
		},
		{
			name:  "basic",
			args:  []string{"secrets", "set-api", "auth", "--auth", "basic", "--user", "svc"},
			stdin: "hunter2\n",
			want:  "Basic " + base64.StdEncoding.EncodeToString([]byte("svc:hunter2")),
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
			if rec.calls[0].ref != tc.args[2] || rec.calls[0].value != tc.want {
				t.Fatalf("stored %q=%q, want %q=%q", rec.calls[0].ref, rec.calls[0].value, tc.args[2], tc.want)
			}
			// The composed value carries the credential; nothing echoes it.
			for _, leak := range []string{strings.TrimSuffix(tc.stdin, "\n"), tc.want} {
				if strings.Contains(errb.String(), leak) {
					t.Fatalf("stderr = %q, want no credential in it", errb.String())
				}
			}
			// "stored" without the authRef edit reproduces the diagnosis
			// gap one step later: a credential in the Keychain that
			// nothing reads.
			if !strings.Contains(errb.String(), "authRef") {
				t.Fatalf("stderr = %q, want it to name the authRef edit still owed", errb.String())
			}
			if !strings.Contains(errb.String(), "initech") {
				t.Fatalf("stderr = %q, want it to name the org", errb.String())
			}
		})
	}
}

func TestRunSetAPIRefusalsExitTwoAndStoreNothing(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	cases := []struct {
		name  string
		args  []string
		stdin string
	}{
		{"missing --auth", []string{"secrets", "set-api", "billing"}, "sk-live-1234\n"},
		{"unknown --auth", []string{"secrets", "set-api", "billing", "--auth", "digest"}, "sk-live-1234\n"},
		{"--user under bearer", []string{"secrets", "set-api", "billing", "--auth", "bearer", "--user", "u"}, "sk-live-1234\n"},
		{"missing --user under basic", []string{"secrets", "set-api", "billing", "--auth", "basic"}, "hunter2\n"},
		{"colon in --user", []string{"secrets", "set-api", "billing", "--auth", "basic", "--user", "a:b"}, "hunter2\n"},
		{"double prefix", []string{"secrets", "set-api", "billing", "--auth", "bearer"}, "Bearer sk-live-1234\n"},
		{"interior space", []string{"secrets", "set-api", "billing", "--auth", "bearer"}, "sk live\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var rec recorder
			var errb bytes.Buffer
			code := run(tc.args, strings.NewReader(tc.stdin), io.Discard, &errb, rec.store, failingReader(t))
			if code != 2 {
				t.Fatalf("exit code = %d, want 2 (stderr: %s)", code, errb.String())
			}
			if len(rec.calls) != 0 {
				t.Fatalf("store called %d times on a refusal, want 0", len(rec.calls))
			}
			if !strings.Contains(errb.String(), "`wakil secrets set`") {
				t.Fatalf("stderr = %q, want it to name `wakil secrets set`", errb.String())
			}
		})
	}
}

// There is no read-back: this command never resolves a ref it just wrote,
// and grows no `secrets get`. The API client pane is the read-back.
func TestRunSetAPIReadsNoSecret(t *testing.T) {
	t.Setenv("WAKIL_ORG", "initech")
	var rec recorder
	code := run([]string{"secrets", "set-api", "billing", "--auth", "bearer"},
		strings.NewReader("sk-live-1234\n"), io.Discard, io.Discard, rec.store, failingReader(t))
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
}

// The credential never reaches argv: no flag in this command takes a
// secret VALUE, and the one that takes a user name is the only string
// argument there is. A flag added later that carries the credential would
// fail here rather than in an operator's shell history.
func TestSetAPIHasNoFlagThatTakesACredential(t *testing.T) {
	var target apiTarget
	var names []string
	setAPIFlagSet(&target).VisitAll(func(f *flag.Flag) { names = append(names, f.Name) })
	want := map[string]bool{"auth": true, "user": true}
	if len(names) != len(want) {
		t.Fatalf("set-api flags = %v, want exactly auth and user", names)
	}
	for _, n := range names {
		if !want[n] {
			t.Fatalf("set-api grew flag --%s; no flag in this binary may carry a secret value", n)
		}
	}
}
