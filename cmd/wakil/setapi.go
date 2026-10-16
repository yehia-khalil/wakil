package main

import (
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// ---------------------------------------------------------------------
// `secrets set-api`
// ---------------------------------------------------------------------
//
// `wakil secrets set-api <ref> --auth <bearer|basic> [--user U]` composes
// an Authorization header VALUE from a credential and stores it under
// ref, exactly where an api entry's authRef points.
//
// WHY A COMPOSING AID EXISTS AT ALL. Until this command, an operator
// storing an HTTP credential typed the whole header value — prefix
// included — into bare `wakil secrets set`. A missing "Bearer " then
// yields a 401 that Wakil cannot diagnose, because Wakil never inspects
// the value it sends: doRequest puts the stored string in the entry's
// header and nothing anywhere knows what a well-formed one looks like.
// The composition, and the six refusals below, are the place that
// knowledge lives.
//
// WHY --auth IS REQUIRED. A default that composes silently is this
// command's own failure mode: an operator who meant basic and got
// "Bearer " + a base64 pair is back to the undiagnosable 401, one step
// further from the paste that caused it. `secrets set-db --driver` is
// the precedent and it is required for the same reason.
//
// WHY THERE IS NO `raw` MODE. It would compose nothing, which makes it
// byte-for-byte `wakil secrets set`, and it is the one mode the
// double-prefix refusal below cannot reach — a `raw` that accepted
// "Bearer x" would accept "Bearer Bearer x" too. `wakil secrets set` is
// named in EVERY refusal here as the honest home for a complete header
// value this aid will not compose.
//
// TWO GAPS, RECORDED RATHER THAN CLOSED. The --auth choice is stored
// nowhere: nothing later can tell a bearer ref from a basic one, so
// nothing can warn that an entry's credential is of the wrong kind. And
// the basic pair is not a scrub form — NewAuthHeaderScrubber registers
// the composed value and its base64 credential, so a response echoing
// the DECODED "user:password" is not redacted. Both are filed as #230.
//
// THERE IS NO READ-BACK, and no `secrets get`. The API client pane is
// the read-back, and a 401 shows the failure where the credential is
// used. What this command does owe the operator is the edit it did not
// make: storing a credential under a ref no api entry names reproduces
// the diagnosis gap one step later, so the success line says which
// authRef is still owed.

const (
	authBearer = "bearer"
	authBasic  = "basic"
)

// apiTarget holds the NON-SECRET half of an API credential: the scheme,
// and the user name that only basic has. The credential is kept out of
// this struct for the same reason dbTarget keeps the password out — a
// future %+v on it cannot leak one.
type apiTarget struct {
	Auth string
	User string
}

// setAPIFlagSet declares this command's flags against target. It is a
// function rather than six lines inside the parser so that the test which
// pins the flag SET — no flag in this binary may ever take a secret value
// — asks the flag set itself rather than reading the parser's source.
func setAPIFlagSet(target *apiTarget) *flag.FlagSet {
	fs := flag.NewFlagSet("secrets set-api", flag.ContinueOnError)
	// See parseSecretsSetDB: the flag package writes its own message and
	// the caller writes the returned error too, which double-prints.
	fs.SetOutput(io.Discard)
	fs.StringVar(&target.Auth, "auth", "", "bearer or basic")
	fs.StringVar(&target.User, "user", "", "basic only: the user name half of the credential")
	return fs
}

// setAPIEscape is appended to every refusal this command makes. The aid
// composes; when it will not, the operator still has somewhere to go, and
// being told where is the difference between a refusal and a dead end.
const setAPIEscape = " — to store a complete header value verbatim, prefix and all, use `wakil secrets set` instead"

// unknownAuthScheme is the one refusal for a scheme this command does not
// compose. Both the parser and the composer reach it, so the two cannot
// drift into naming different supported sets.
func unknownAuthScheme(value string) error {
	return wakilcore.UserError("unknown --auth " + strconv.Quote(value) +
		" — supported schemes are bearer and basic" + setAPIEscape)
}

// parseSecretsSetAPI parses `wakil secrets set-api <ref> --auth ...` from
// os.Args[1:]. Like parseSecretsSetDB it checks only the SHAPE of the
// invocation; what the credential itself may contain is
// composeAPIHeaderValue's to judge, because that runs on the secret
// reader's output and this runs before a byte of stdin is read.
//
// The four refusals here are the first four of the command's six, in
// order: an unusable --auth is reported before anything that depends on
// knowing the scheme, and --user's applicability before its content.
func parseSecretsSetAPI(args []string) (string, apiTarget, error) {
	if len(args) < 2 || args[0] != "secrets" || args[1] != "set-api" {
		return "", apiTarget{}, wakilcore.UserError("unknown command\n\n" + usage)
	}
	if len(args) < 3 {
		return "", apiTarget{}, wakilcore.UserError("missing <ref>\n\n" + usage)
	}
	ref := args[2]
	if err := validateRef(ref); err != nil {
		return "", apiTarget{}, err
	}

	var t apiTarget
	fs := setAPIFlagSet(&t)
	if err := fs.Parse(args[3:]); err != nil {
		return "", apiTarget{}, wakilcore.UserError("bad flags for `wakil secrets set-api`: " + err.Error() + "\n\n" + usage)
	}
	if fs.NArg() > 0 {
		return "", apiTarget{}, wakilcore.UserError("unexpected argument " + strconv.Quote(fs.Arg(0)) + " — the credential is read from stdin, never from the command line (an argv token lands in your shell history and is readable by any local process via `ps -ww`)\n\n" + usage)
	}

	switch t.Auth {
	case "":
		return "", apiTarget{}, wakilcore.UserError("missing required flag --auth (bearer or basic)" + setAPIEscape)
	case authBearer:
		// A bearer token carries no user name, so a --user here means
		// the operator believes they are composing something this
		// command will not compose. Accepting and dropping it would
		// store a credential missing the half they typed.
		if t.User != "" {
			return "", apiTarget{}, wakilcore.UserError("flag --user does not apply to --auth bearer — a bearer token is the whole credential and carries no user name" + setAPIEscape)
		}
	case authBasic:
		if t.User == "" {
			return "", apiTarget{}, wakilcore.UserError("missing required flag --user for --auth basic" + setAPIEscape)
		}
		// The colon is the pair's own separator (RFC 7617), and it is
		// not escapable: "ad:min" with password "pw" base64s to exactly
		// what user "ad" with password "min:pw" does, and the server
		// reads the second one. The password half may contain colons
		// freely — only the user half is ambiguous.
		if strings.Contains(t.User, ":") {
			return "", apiTarget{}, wakilcore.UserError("flag --user contains a colon, which is the separator between the user and the password in a basic credential — a user name containing one cannot be encoded unambiguously" + setAPIEscape)
		}
	default:
		return "", apiTarget{}, unknownAuthScheme(t.Auth)
	}
	return ref, t, nil
}

// composeAPIHeaderValue builds the header value stored under the ref:
// "Bearer " + token, or "Basic " + base64(user + ":" + password), one
// space each, per RFC 9110's `credentials = auth-scheme 1*SP token68`.
//
// IT RUNS ON THE SECRET READER'S OUTPUT, never on raw stdin. A token
// pasted with its trailing newline — `claude setup-token`'s output, then
// Enter, then Ctrl-D — would otherwise be refused for whitespace it does
// not have, which is the most likely paste there is.
//
// THE TWO BEARER REFUSALS ARE ORDERED. The double-prefix check runs
// first, so "Bearer sk-1" is diagnosed as the prefix the operator typed
// rather than as the space that prefix happens to contain. Reversed, the
// message would send them hunting for a space in a token that has none.
//
// THE BASIC SIDE IS DELIBERATELY UNGUARDED. That half is a password, and
// a password may contain anything — a leading "Bearer ", a colon, a tab.
// Every byte the bearer guards refuse is one a real password may hold, so
// refusing them there would reject valid credentials to catch a mistake
// the base64 encoding makes harmless anyway.
func composeAPIHeaderValue(target apiTarget, secret string) (string, error) {
	switch target.Auth {
	case authBasic:
		return "Basic " + base64.StdEncoding.EncodeToString([]byte(target.User+":"+secret)), nil
	case authBearer:
		// The first WORD, not a prefix: "bearerish-token" is a token,
		// and refusing it would send the operator to `wakil secrets set`
		// for a value this command composes perfectly well.
		word := secret
		if i := strings.IndexAny(secret, " \t"); i >= 0 {
			word = secret[:i]
		}
		if lower := strings.ToLower(word); lower == authBearer || lower == authBasic {
			return "", wakilcore.UserError("the credential already begins with a scheme word (" + strconv.Quote(word) + ") — this command composes the prefix itself, and storing it twice sends " + strconv.Quote(word+" "+word+" ...") + " to the backend" + setAPIEscape)
		}
		if strings.ContainsAny(secret, " \t") {
			return "", wakilcore.UserError("the credential contains a space or tab — a bearer token is one word, and a header value split across one would be read as a scheme plus a different token" + setAPIEscape)
		}
		return "Bearer " + secret, nil
	default:
		// Unreachable through the CLI: parseSecretsSetAPI refuses every
		// other scheme before stdin is read. It is an error rather than
		// a panic because this function is exported to its own tests and
		// may outlive that one caller — and it is the SAME sentence the
		// parser refuses with, because two spellings of one refusal are
		// two things that can drift into disagreeing about what this
		// command supports.
		return "", unknownAuthScheme(target.Auth)
	}
}

// runSetAPI implements `wakil secrets set-api`. It mirrors runSetDB's
// shape exactly — parse, resolve the org, prompt, read, compose, store —
// so that the two composing aids stay one thing an operator can learn
// once. The composed value is never printed: it contains the credential.
func runSetAPI(args []string, stdin io.Reader, stderr io.Writer, store secretStore) int {
	ref, target, err := parseSecretsSetAPI(args)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	org, err := wakilcore.CurrentOrgChecked()
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}

	switch target.Auth {
	case authBasic:
		fmt.Fprintf(stderr, "Paste the password for user %q, for %q in org %q, then press Ctrl-D:\n", target.User, ref, org)
	default:
		fmt.Fprintf(stderr, "Paste the bearer token for %q in org %q, then press Ctrl-D:\n", ref, org)
	}
	secret, err := readSecretValue(stdin)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}

	value, err := composeAPIHeaderValue(target, secret)
	if err != nil {
		fmt.Fprintln(stderr, message(err))
		return 2
	}
	if err := store(ref, value); err != nil {
		fmt.Fprintln(stderr, message(err))
		return 1
	}
	fmt.Fprintf(stderr, "stored a %s credential under %q in the keychain for org %q.\n", target.Auth, ref, org)
	fmt.Fprintf(stderr, "still owed: %q on the api entry that should send it, in the project's project.json — until an entry names this ref, nothing reads it.\n", `"authRef": "`+ref+`"`)
	return 0
}
