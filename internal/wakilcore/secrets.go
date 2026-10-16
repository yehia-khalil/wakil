package wakilcore

import (
	"bytes"
	"encoding/hex"
	"errors"
	"os/exec"
	"strings"
)

// keychainNotFoundExitCode is the exit status `security find-generic-password`
// returns when the requested item does not exist in the keychain (errSecItemNotFound).
// Measured against a throwaway keychain: a lookup for an absent service exits
// 44 and prints "SecKeychainSearchCopyNext: The specified item could not be
// found in the keychain." on stderr.
const keychainNotFoundExitCode = 44

// keychainAccount is the `security` account attribute every item this
// codebase writes carries. It is a CONSTANT, not a discriminator: it is
// "wakil" for every org and every ref, which is why the service name is
// the only place org scoping can live (see keychainService).
const keychainAccount = "wakil"

// keychainService builds the `security` service name a credential lives
// under: "wakil:<org>:<ref>".
//
// WHY THE ORG IS IN THE NAME. A project.json is a committable file that
// holds no secrets — it names a ref like "db:staging" and nothing more.
// While the service name was just "wakil:"+ref, two different orgs each
// with a project naming "db:staging" addressed the SAME Keychain item:
// whichever org stored last silently handed its credential to the other.
// That contradicts the model the rest of this codebase is built on — each
// organisation keeps its own credentials — and it is the same invariant
// Resolve()'s proj.Org re-check enforces one layer up. Jira's ref was
// already org-scoped ("jira:"+org, see NewJiraFromEnv), so the pattern
// was understood; this puts the DB and API ref namespace on the same
// footing instead of leaving it as the one hole.
//
// WHY THERE IS NO FALLBACK TO THE OLD UNSCOPED NAME, though one would
// spare the operator a migration. A Keychain item carries no org. Its
// only attributes are the service name and the account, and the account
// is the fixed constant above — so there is nothing in the item itself a
// fallback could re-check, and a fallback read of "wakil:"+ref could not
// tell this org's own old secret from another org's. It would hand over
// whichever one exists. That is exactly the cross-org sharing being
// fixed, so a fallback here would undo the fix while appearing to soften
// it. Old items are orphaned instead, and every credential is re-stored
// once (see the MIGRATION section of docs/wakil/operator-todo.md).
//
// WHY THE ORG IS VALIDATED, GIVEN THAT `security` DOES NOT CARE. Measured
// against a throwaway keychain (never the login keychain): add- and
// find-generic-password accepted "/", "..", ".", "", "my org", "orgé" and
// an embedded newline as the org component of a service name, and
// round-tripped the value byte-for-byte in every case. The Keychain
// imposes no constraint at all, and a leading "-" cannot be misread as an
// option either, because the service name always begins with the literal
// "wakil:" and is always the VALUE of -s. So this validation is not about
// what the tool tolerates. It is about the DELIMITER: ":" separates org
// from ref, and cmd/wakil's refPattern deliberately permits ":" inside a
// ref (that is how "db:staging" and "jira:initech" are written). If the org
// could also contain ":", then org "a:b" with ref "c" and org "a" with
// ref "b:c" would produce the identical service name "wakil:a:b:c" —
// re-creating, in a new form, the very cross-org collision this function
// exists to close. orgFileTokenPattern forbids ":", so with a validated
// org the name splits unambiguously at the first colon and no two
// distinct (org, ref) pairs can ever collide.
//
// An unusable org is a clean UserError, never a sanitised or degraded
// name, for the same reason activePath() refuses one: mapping two
// different orgs onto one credential is the bug, and quietly recreating
// it while appearing to fix it would be worse than refusing.
//
// The Jira redundancy is deliberate and is being LEFT ALONE. Its ref is
// already "jira:<org>", so the scoped service reads "wakil:initech:jira:initech".
// Shortening the ref to a bare "jira" would be a SECOND breaking rename
// on top of this one, and the operator already has a real Jira credential
// stored. Every rename is an opportunity to lock them out of a working
// setup; one is the unavoidable minimum, two would be a choice. Keeping
// the ref also keeps the migration instruction identical to the command
// the operator originally ran, with no new ref to learn, and keeps
// "jira:<org>" — which appears in the operator docs and in
// NewJiraFromEnv's own error message — meaning one thing everywhere. The
// duplication costs a few bytes in a name no human types.
func keychainService(org, ref string) (string, error) {
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	return "wakil:" + org + ":" + ref, nil
}

// SecretGet reads the secret stored for ref, in the CURRENT org, from the
// macOS login keychain.
//
// It distinguishes "no such item" (exit code 44) from any other failure
// (locked keychain, denied access prompt, missing security binary, ...) so
// the resulting message tells the human what actually happened instead of
// always suggesting a re-store that would not fix the real problem.
//
// The not-found message names the ORG as well as the ref, and says how to
// re-store. Both matter more than they look. Org-scoping the service name
// orphaned every credential stored under the old org-less scheme, so exit
// 44 is the exact path a previously-working setup now lands on, and "item
// not found" alone would read as data loss rather than a one-time
// migration. Naming the org also catches the other way to reach 44 after
// the change: storing a credential with WAKIL_ORG set to one org while the
// MCP servers run with it pinned to another — the write succeeds, the
// read fails, and only the org in the message makes the mismatch visible.
func SecretGet(ref string) (string, error) {
	org, err := CurrentOrg()
	if err != nil {
		return "", err
	}
	return SecretGetFor(org, ref)
}

// SecretGetFor reads the secret stored for ref under a NAMED org.
//
// **Split out by 2e (#201) for the credential copy an adoption performs.**
// Adoption reads the home organisation's credential and writes the
// adopting one's, in Go, silently — two organisations in one call, which
// the ambient-org form cannot express. Every rule SecretGet documents
// applies here unchanged; that function is now this one under
// `CurrentOrg()`.
//
// **The org-scoped service name is the whole of Invariant 4 here.** The
// ref carries no org, so the same account reached from two organisations
// needs the same token stored twice, once per org — which is exactly the
// copy this enables, and exactly the step whose omission leaves the three
// credential-less bindings on this machine today.
func SecretGetFor(org, ref string) (string, error) {
	service, err := keychainService(org, ref)
	if err != nil {
		return "", err
	}
	cmd := keychainCommand("find-generic-password",
		"-s", service, "-a", keychainAccount, "-w")
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == keychainNotFoundExitCode {
			return "", UserError("no credential stored for ref " + ref + " in org " + org +
				" — store it with: WAKIL_ORG=" + org + " wakil secrets set " + ref +
				". Credentials are namespaced per org (Keychain service \"wakil:<org>:<ref>\"); anything stored before that change lives under the old org-less name and must be re-stored once — see the MIGRATION section of docs/wakil/operator-todo.md")
		}
		return "", UserError("could not read keychain for ref " + ref + " in org " + org + ": " + diagnostic(err, &errb))
	}
	// Exactly ONE newline is removed, not all of them: `security -w` adds a
	// single newline of its own when printing, and readSecretValue on the
	// write side already strips at most one, so a secret whose own last byte
	// is a newline (a PEM key, per cmd/wakil's help text) must survive the
	// round trip. TrimRight would remove the value's own terminator too.
	// A second `security` call, `-g`, purely to learn whether the value
	// above was printed verbatim or hex-encoded — see decodeKeychainHex for
	// why that cannot be told from the value itself. Its failure is not an
	// error: an unreadable or unsupported `-g` leaves `passwordLine` empty,
	// which decodeKeychainHex treats as "verbatim", the behaviour this
	// function had before 2026-09-11.
	var gerr bytes.Buffer
	gcmd := keychainCommand("find-generic-password",
		"-s", service, "-a", keychainAccount, "-g")
	gcmd.Stdout = &bytes.Buffer{}
	gcmd.Stderr = &gerr
	_ = gcmd.Run()

	return decodeKeychainHex(strings.TrimSuffix(out.String(), "\n"), gerr.String()), nil
}

// decodeKeychainHex undoes `security`'s hex encoding of a stored password.
//
// MEASURED, 2026-09-11, after an operator hit it on a real acceptance walk.
// `security find-generic-password -w` does not always print the bytes it
// stored. When the stored value is not a plain printable string — most
// commonly because it ends in a newline — it prints the value as lowercase
// hex instead, with no marker of any kind:
//
//	stored "sk-ant-oat0-PROBE2222"    -> sk-ant-oat0-PROBE2222
//	stored "sk-ant-oat0-PROBE2222\n"  -> 736b2d616e742d6f6174302d50524f4245323232320a
//
// `-g` is the only form that says which it is (`password: 0x736B...  "…"`),
// and `-w` is what this function's caller uses because it is the only form
// that prints the value alone. So the hex has to be recognised here.
//
// WHY THIS MATTERS MORE THAN IT LOOKS. The failure is silent at every step
// that could catch it: the write succeeds, the read succeeds, `claude auth
// status` reports `loggedIn: true` because a token is *present*, and the
// only symptom is a 401 on the first real call — arriving long after the
// step that caused it. That is how it survived Phase 1 and was found only
// when 2b-vi made a provider token the thing a whole window depends on.
//
// WHY THIS IS NOT A HEURISTIC, having first been written as one. The
// obvious rule — "decode it if it is even-length and all hex digits" — is
// WRONG, and this repository's own suite proved it within minutes:
// `httpclient_test.go` authenticates with the token "0123456789abcdef01",
// which is even-length, entirely hex digits, and a perfectly ordinary
// secret. The heuristic decoded it into nine bytes of binary and the
// request died with `invalid header field value`. Any rule that inspects
// only the returned string has that flaw, because a hex-encoded value and a
// value that happens to look like hex are indistinguishable by inspection.
//
// So the encoding is not guessed, it is ASKED FOR. `-g` prints a line to
// STDERR (not stdout — measured) in one of two shapes:
//
//	password: "sk-ant-oat0-PROBE2222"                        // verbatim
//	password: 0x736B2D...0A  "sk-ant-oat0-PROBE2222\012"     // hex
//
// The `0x` is the marker `-w` does not give. `hexMarker` looks for it, and
// only then is the `-w` output decoded. A caller whose `security` does not
// support `-g`, or whose output is unrecognised, gets the raw value back
// unchanged — the pre-2026-09-11 behaviour, which is right for every secret
// that was never hex-encoded in the first place.
func decodeKeychainHex(raw, passwordLine string) string {
	if raw == "" || !strings.Contains(passwordLine, "password: 0x") {
		return raw
	}
	if len(raw)%2 != 0 {
		return raw
	}
	decoded, err := hex.DecodeString(raw)
	if err != nil {
		return raw
	}
	// A value is only stored hex-encoded because it was not a plain
	// printable string — in practice because it ends in a line terminator,
	// which is the whole defect this repairs. Removing it here means an item
	// written before the write-side fix reads back the same as one written
	// after it, so an operator does not have to re-store anything.
	return strings.TrimRight(string(decoded), "\r\n")
}

// SecretSet stores value in the macOS login keychain under ref for the
// CURRENT org, creating the item if absent or updating it in place if
// present (-U).
//
// The `security` CLI has no stdin- or file-based way to supply a password to
// add-generic-password: -w either takes the value as an argv token, or (when
// given with no value at the end of the command) triggers an interactive
// GUI/TTY prompt that would block a non-interactive caller. Because CGO is
// off in this project (see the Makefile), a cgo Keychain library that
// avoids argv is not an option either. So this shells out with -w <value>,
// which means the secret value is briefly visible in this process's argument
// list (readable via `ps -ww` by any local process) for the duration of the
// call. There is no way around that with the tooling available here.
//
// Which org this writes under is decided by WAKIL_ORG at the moment of
// the call and nothing else, so a caller that can be run by a human —
// cmd/wakil is the only one — must show the operator the org it
// resolved, or storing under the wrong one is silent until a read fails.
func SecretSet(ref, value string) error {
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	return SecretSetFor(org, ref, value)
}

// SecretSetFor writes the secret for ref under a NAMED org. See
// SecretGetFor for why the pair exists; every rule SecretSet documents,
// including the trailing-newline normalisation, applies here unchanged.
func SecretSetFor(org, ref, value string) error {
	service, err := keychainService(org, ref)
	if err != nil {
		return err
	}
	// Trailing line endings are removed HERE, in the store, and not only in
	// `cmd/wakil`'s stdin reader.
	//
	// The stdin reader strips them too, and has to — it needs the stripped
	// form to tell a real secret from an operator pressing Enter twice. But
	// that path is the CLI's alone. `design-language.md` §14 says the Phase 2
	// Settings UI "writes the same Keychain entries", and a UI has no stdin:
	// it would call this function directly, never touch `readSecretValue`,
	// and reintroduce the whole defect with a value pasted out of a text
	// field that happened to carry a newline.
	//
	// So the normalisation lives at the boundary every writer must cross.
	// Without it the fix would have covered exactly one caller — which is
	// precisely the question that surfaced it (the operator asked whether
	// this also works when secrets are added from the UI; it would not have).
	//
	// See decodeKeychainHex for what a surviving terminator actually does:
	// `security -w` returns the value as unmarked hex, and it fails at first
	// use with an error pointing nowhere near the paste that caused it.
	value = strings.TrimRight(value, "\r\n")

	cmd := keychainCommand("add-generic-password",
		"-U", "-s", service, "-a", keychainAccount, "-w", value)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return UserError("could not write keychain entry for ref " + ref + " in org " + org + ": " + diagnostic(err, &errb))
	}
	return nil
}

// diagnostic returns the trimmed stderr captured from a failed `security`
// invocation, falling back to err.Error() when stderr is empty — which
// happens when the command never started (e.g. the security binary is not
// on PATH), so there is nothing on stderr to report. It never includes any
// secret value: only stderr text and the exec package's own error message
// can appear here.
func diagnostic(err error, errb *bytes.Buffer) string {
	if s := strings.TrimSpace(errb.String()); s != "" {
		return s
	}
	return err.Error()
}
