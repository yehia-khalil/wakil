package wakilcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"regexp"
	"testing"
	"time"
)

// CredentialPresence is what the settings pane is told about a stored
// credential: that it exists, and when it was last written. Never its
// value, and never anything derived from its value.
//
// **This is the "presence-only wire type" #200 owes**, alongside
// MachineProvider and on that type's own precedent. The standing rule is
// that a credential row shows ref and presence and never a value — so the
// type that carries a row must be incapable of carrying one, rather than
// merely not being asked for one today.
type CredentialPresence struct {
	// Ref is the Keychain ENTRY NAME, which is not a secret and is
	// exactly what an operator's own settings pane is for.
	Ref string `json:"ref"`
	// Present is whether an item exists at that name, for that org.
	Present bool `json:"present"`
	// Modified is when the item was last WRITTEN — the Keychain's own
	// `mdat`, and zero when the item is absent or its date could not be
	// read.
	//
	// **`mdat` and not `cdat`, and that is measured rather than argued.**
	// On this machine, 2026-09-22: storing a value set both to the same
	// second; re-storing the same item with `-U` seven seconds later left
	// `cdat` at 130250 and moved `mdat` to 130257. A minted token's age is
	// a 365-day clock that RESTARTS when the operator re-authenticates, so
	// computing it from `cdat` would silently under-report every
	// re-authentication — showing an operator who repaired an account
	// yesterday a credential that expires next week.
	Modified time.Time `json:"modified,omitempty"`

	// Checked is whether the Keychain ANSWERED — so `Present: false`
	// means "there is no such item" rather than "the lookup failed".
	//
	// **It is on the wire, and that is a correction.** It was unexported
	// at first, on the reasoning that a consumer should ask
	// `Account.CredentialLess()` rather than reassemble the question. But
	// the consumer that matters is across a process boundary: Swift
	// decodes this type, and with nothing to decode it reconstructed
	// "readable" from the whole-table `keychainUnavailable` — so a row
	// whose OWN lookup failed, on a machine where the tool works fine,
	// decoded as a missing credential. That is precisely the "could not
	// look" / "is missing" conflation the row exists to keep apart.
	Checked bool `json:"checked"`
}

// MarshalJSON omits a zero `Modified` instead of writing `0001-01-01`.
//
// **`omitempty` does not work on a struct field**, so the zero
// `time.Time` was crossing the wire as `"0001-01-01T00:00:00Z"` — which
// Swift parsed as a perfectly good date and turned into an expiry in the
// year 2. The pane drew "expires 2 Jan 0002" for a credential with no
// recorded date.
//
// That is precisely the failure `parseKeychainModified` refuses to commit
// — *a wrong date is worse than no date, because it is the one fact on
// the row an operator plans against* — reintroduced one layer out, at the
// encoder. Caught by running the app against this machine's real
// accounts; the unit tests never saw it because they assert on the Go
// value, which was correct all along.
func (c CredentialPresence) MarshalJSON() ([]byte, error) {
	// A shadow type, so this does not recurse into itself.
	type wire struct {
		Ref      string     `json:"ref"`
		Present  bool       `json:"present"`
		Modified *time.Time `json:"modified,omitempty"`
		Checked  bool       `json:"checked"`
	}
	out := wire{Ref: c.Ref, Present: c.Present, Checked: c.Checked}
	if !c.Modified.IsZero() {
		modified := c.Modified
		out.Modified = &modified
	}
	return json.Marshal(out)
}

// Expiry is when a minted token stops working, given how long one lasts.
//
// Zero when the item's date is unknown, so a caller can tell "expires
// then" from "no idea" rather than being handed the epoch and having to
// know that means nothing.
func (c CredentialPresence) Expiry(lifetime time.Duration) time.Time {
	if c.Modified.IsZero() {
		return time.Time{}
	}
	return c.Modified.Add(lifetime)
}

// MintedTokenLifetime is how long a `claude setup-token` credential lasts.
//
// **365 days, not forever.** Named here so the one place that turns a
// modification date into an expiry is the one place that has to be
// corrected if Anthropic changes it.
const MintedTokenLifetime = 365 * 24 * time.Hour

// keychainDatePattern matches one attribute line of `security
// find-generic-password`'s plain (no `-g`, no `-w`) output:
//
//	"mdat"<timedate>=0x32303236...5A00  "20260922130257Z\000"
//
// The quoted tail is read rather than the hex, because it is already the
// string the hex encodes and parsing it needs no second decoder.
var keychainDatePattern = regexp.MustCompile(`"(cdat|mdat)"<timedate>=.*?"(\d{14})Z`)

// SecretPresence reports whether a credential is stored for ref in the
// CURRENT org, and when it was last written — WITHOUT reading its value.
func SecretPresence(ref string) (CredentialPresence, error) {
	org, err := CurrentOrg()
	if err != nil {
		return CredentialPresence{Ref: ref}, err
	}
	return SecretPresenceFor(org, ref)
}

// SecretPresenceFor reports whether a credential is stored for ref under
// org, and when it was last written.
//
// **It reads no value, and that is the whole reason it exists rather than
// SecretGet being called and thrown away.** `security
// find-generic-password` WITHOUT `-w` and WITHOUT `-g` prints the item's
// attributes and no password at all — measured on this machine,
// 2026-09-22 — so it neither returns the secret nor raises the access
// prompt that reading one can. The settings pane draws every account on
// the machine on open; doing that through SecretGet would ask the
// operator to approve a Keychain read per row, for values it then
// discards.
//
// **An absent item is not an error.** Exit 44 is the ordinary answer for
// one of the three credential-less bindings this pane exists to NAME, and
// reporting it as a failure would make the pane unable to tell "missing"
// from "could not look" — which is the distinction the row is drawn to
// carry.
//
// **It shells out to the ABSOLUTE path**, as `SecretGet` and `SecretSet`
// now do too — see `securityBinary` for why the path is load-bearing and
// for the defect #201 paid there.
func SecretPresenceFor(org, ref string) (CredentialPresence, error) {
	out := CredentialPresence{Ref: ref}
	service, err := keychainService(org, ref)
	if err != nil {
		return out, err
	}

	cmd := keychainCommand("find-generic-password",
		"-s", service, "-a", keychainAccount)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == keychainNotFoundExitCode {
			// Absent, and that is an ANSWER rather than a failure — so
			// the lookup was checked, and found nothing.
			out.Checked = true
			return out, nil
		}
		return out, UserError("could not read keychain attributes for ref " + ref +
			" in org " + org + ": " + diagnostic(err, &stderr))
	}

	out.Present = true
	out.Checked = true
	// The attributes go to stdout; `security` writes some of its chatter
	// to stderr, so both are scanned rather than guessing which.
	out.Modified = parseKeychainModified(stdout.String() + stderr.String())
	return out, nil
}

// parseKeychainModified pulls `mdat` out of `security
// find-generic-password`'s attribute dump.
//
// **Extracted and tested directly**, which is this phase's standing rule
// for a decoder: the Keychain itself belongs to the runbook, and
// everything either side of it is a pure function of bytes.
//
// **It refuses rather than guessing.** An output with no `mdat` line, or
// one whose date does not parse, yields the zero time — which a caller
// renders as "unknown" rather than as the epoch. A minted token's age is
// the only thing on the row an operator uses to plan, and a wrong date is
// worse than no date.
//
// `cdat` is deliberately NOT a fallback. It is the wrong answer rather
// than a worse one: it survives a re-store, so falling back to it would
// report a re-authenticated account as still carrying its original
// credential's clock.
func parseKeychainModified(attributes string) time.Time {
	for _, match := range keychainDatePattern.FindAllStringSubmatch(attributes, -1) {
		if match[1] != "mdat" {
			continue
		}
		// `security` prints these in UTC, with the trailing Z this
		// pattern has already consumed.
		when, err := time.ParseInLocation("20060102150405", match[2], time.UTC)
		if err != nil {
			return time.Time{}
		}
		return when
	}
	return time.Time{}
}

// securityBinary is the Keychain tool, by ABSOLUTE path.
//
// **The path is load-bearing and is not defensive spelling.** Shelling out
// is the design and not an implementation detail: no hardened-runtime
// entitlement covers Keychain access, what governs it is the item's own
// ACL, and the CLI's item trusts exactly one application —
// `/usr/bin/security` — because the CLI created it by shelling out too. An
// in-process `SecItem` implementation would prompt. So the name Wakil
// invokes has to be the one the ACL names, and a bare `security` resolved
// off PATH is a different application as far as that ACL is concerned.
//
// Until 2e (#201) every call site here invoked the bare name `security`
// while the ACL argument named the absolute path. That is the defect this
// pays.
//
// **`WAKIL_SECURITY_BINARY` overrides it IN TESTS ONLY**, and the
// restriction is the whole point. Ten tests across this repository stood
// up a fake `security` by putting it first on PATH — which is what the
// product used to resolve, and which stopped intercepting the moment this
// became an absolute path. Left unaddressed, every one of them would have
// started reaching the operator's real login keychain, silently and while
// still passing. They need a seam, and a package-internal one does not
// reach across `cmd/wakil-pm`, `cmd/wakil-db` and `cmd/wakil-recall`.
//
// **`testing.Testing()` is what keeps it from being a production trust
// knob.** A first cut honoured the variable unconditionally and argued it
// was narrower than PATH; that argument was true and beside the point —
// it still added a way to point a shipped Wakil at a different Keychain
// tool, which is exactly the door the absolute path was introduced to
// close. In a shipped binary this function returns the constant and reads
// no environment at all.
var securityBinary keychainTool = defaultSecurityBinary

// keychainTool is the Keychain program's path, as a type the compiler
// will not let a caller pass straight to `exec.Command`.
//
// **The conversion is the guard, and it is deliberately annoying.** #301
// happened because a call site can reach the Keychain by spelling out
// `exec.Command(securityTool(), …)` — which compiles, passes every
// behavioural test, and writes to whatever keychain is default, meaning
// the operator's login keychain during an e2e run. A grep can detect
// that; a type stops it. `keychainCommand` does the one `string(...)`
// conversion, where the keychain positional is appended, and any other
// call site that wants one has to write the conversion out and be seen
// doing it.
//
// This is the same trade `wakil-controls` made when `confirmButton` lost
// its defaulted identifier: the compiler holds what a gate can only
// report, and it needs no maintenance.
type keychainTool string

// defaultSecurityBinary is what the product uses when nothing overrides
// it. Read through securityTool() rather than captured at init, so that a
// test setting the variable with `t.Setenv` is honoured — a package-level
// value computed once would ignore every such test and send it at the real
// keychain, which is exactly the failure this seam exists to prevent.
const defaultSecurityBinary keychainTool = "/usr/bin/security"

// securityTool resolves the Keychain tool for one call.
func securityTool() keychainTool {
	// The override is unreachable outside a test binary. `testing.Testing()`
	// is false in everything `make build` produces.
	if testing.Testing() {
		if override := os.Getenv("WAKIL_SECURITY_BINARY"); override != "" {
			return keychainTool(override)
		}
	}
	return securityBinary
}

// keychainSelectorEnv names the keychain FILE every Keychain call this
// package makes is scoped to. Empty or unset means the default keychain,
// which for an operator is their login keychain — the behaviour a shipped
// Wakil has always had and still has.
//
// **It is read in a shipped binary, and `WAKIL_SECURITY_BINARY` is not.
// The asymmetry is the entire design, so here is why it is not an
// inconsistency.**
//
// A tool override hands a caller the *code that runs*. Honouring one
// outside a test binary is a way to point a shipped Wakil at a different
// Keychain program, which is the door `securityBinary`'s absolute path
// was introduced to close, and `testing.Testing()` is what keeps it shut.
// That argument stands and nothing here weakens it.
//
// A keychain selector hands a caller the *file operated on*. It names a
// path; it executes nothing. `/usr/bin/security` still runs, so the
// item's ACL — which trusts that binary and no other — is satisfied
// exactly as before, and the three generic-password subcommands already
// take the keychain as a documented trailing positional. Nothing about
// the trust model moves.
//
// **And it is strictly weaker than the channel it replaces.** Until #201
// this package resolved `security` through PATH, so any parent process
// that could set an environment variable could already substitute the
// whole tool. A variable that can only redirect which keychain file is
// written is less power than that, granted to the same caller.
//
// **That second argument is "no worse than before", and "before" is a
// state #201 judged unacceptable and closed — so here is the residual
// risk stated plainly rather than left for a reader to find.** The ACL
// protects an EXISTING item from other applications. It says nothing
// about Wakil legitimately writing a NEW item somewhere else, through
// the very binary it trusts. So an attacker who can set this variable
// does not attack the item: they redirect Wakil's writes, and the next
// minted token lands in a keychain file they control. That is
// exfiltration with the trust model entirely intact, and no ACL
// anywhere prevents it.
//
// **What makes it acceptable is who can do it.** It requires control of
// Wakil's process environment — a parent that launches Wakil, or code
// already running as the operator. Such a caller can substitute
// `claude` itself on PATH, read the config dir, or drive the app; it is
// already inside every boundary this program has. This grants it nothing
// it could not otherwise obtain. That is the argument, and it is a
// threat-model argument rather than a historical one, which is what the
// first two legs were missing.
//
// **What it buys is the e2e fixture's central claim, which was false
// between #201 and #301.** `fixture.go` argues that isolation "has to be
// structural, because Invariant 4 requires cross-org bleed to be
// impossible rather than avoided, and a fixture run that wrote into the
// operator's login keychain would break that invariant on the operator's
// own machine." The PATH shim it relies on stopped reaching the product
// the moment the path became absolute — and `VerifyIsolation` went on
// certifying runs as isolated, because it checks PATH. A guard that
// cannot see the channel it guards is worse than no guard; this is the
// channel, and the guard now reads it.
//
// See Decision 33.
const keychainSelectorEnv = "WAKIL_KEYCHAIN"

// keychainSelector resolves the keychain file for one call, or "" for the
// default.
//
// **Deliberately no `testing.Testing()` gate** — see keychainSelectorEnv.
// A copy of `securityTool`'s shape here would compile, pass every
// behavioural test, and leave the e2e fixture unable to isolate the
// product; `TestTheKeychainSelectorIsReadInAShippedBinary` reads this
// body to keep that from being re-introduced.
func keychainSelector() string {
	return os.Getenv(keychainSelectorEnv)
}

// keychainCommand builds one `security` invocation: the tool the ACL
// names, the caller's arguments, and the selected keychain last.
//
// **Every Keychain call in this package goes through here, and a test
// enforces that** (`TestEveryKeychainCallIsBuiltByKeychainCommand`). The
// alternative — appending the positional at each of the five call sites —
// is correct exactly until the sixth is written, and a sixth that forgets
// does not fail: it writes to the operator's login keychain and passes.
// #301 is what that costs, so the constructor is the only door.
//
// **An unset selector appends NOTHING, not an empty argument.** `security`
// would read a trailing "" as a keychain named "", where no positional at
// all means the default. The two are not the same and only one of them is
// the behaviour a shipped Wakil has.
func keychainCommand(args ...string) *exec.Cmd {
	if keychain := keychainSelector(); keychain != "" {
		args = append(args, keychain)
	}
	return exec.Command(string(securityTool()), args...)
}

// keychainToolOnPath reports whether securityBinary can be executed at
// all, so a caller can degrade rather than reporting every account's
// credential missing on a machine where it is not there.
func keychainToolOnPath() bool {
	_, err := exec.LookPath(string(securityTool()))
	return err == nil
}
