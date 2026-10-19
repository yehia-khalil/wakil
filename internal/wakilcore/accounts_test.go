package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NOTE ON KEYCHAIN AND CLI SAFETY. Nothing in this file touches the real
// login keychain or runs the real `claude`. `securityBinary` is pointed at
// a fake script per test, and the liveness reads go through a fake
// `claude` whose path is handed in explicitly. The one function that could
// reach an operator's credentials — SecretPresenceFor — is exercised only
// against those fakes.

// fakeBinary writes an executable shell script at dir/name and returns its
// path.
func fakeBinary(t *testing.T, dir, name, script string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// useFakeSecurity points securityBinary at a script for the duration of
// one test.
func useFakeSecurity(t *testing.T, script string) {
	t.Helper()
	path := fakeBinary(t, t.TempDir(), "security", script)
	previous := securityBinary
	securityBinary = keychainTool(path)
	t.Cleanup(func() { securityBinary = previous })
}

// ---------------------------------------------------------------------
// parseKeychainModified — the mdat decoder
// ---------------------------------------------------------------------

// TestParseKeychainModifiedReadsMdatAndNotCdat is the measured rule, and
// the sample below is verbatim output from this machine on 2026-09-22
// after a store followed seven seconds later by a re-store with `-U`.
//
// A minted token's 365-day clock RESTARTS when the operator
// re-authenticates. `cdat` survives a re-store and `mdat` does not, so
// reading `cdat` would show an operator who repaired an account yesterday
// a credential that expires next week. MUTATION CHECK: swapping the field
// name in parseKeychainModified makes this fail on the second.
func TestParseKeychainModifiedReadsMdatAndNotCdat(t *testing.T) {
	const attributes = `keychain: "/Users/x/Library/Keychains/login.keychain-db"
class: "genp"
attributes:
    "acct"<blob>="wakil"
    "cdat"<timedate>=0x32303236303932323133303235305A00  "20260922130250Z\000"
    "mdat"<timedate>=0x32303236303932323133303235375A00  "20260922130257Z\000"
    "svce"<blob>="wakil:acme:provider:main"
`
	got := parseKeychainModified(attributes)
	want := time.Date(2026, 9, 22, 13, 2, 57, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("parseKeychainModified = %v; want %v (mdat, not cdat)", got, want)
	}
}

// TestParseKeychainModifiedRefusesRatherThanGuessing. A wrong date is
// worse than no date: the minted token's age is the one thing on the row
// an operator plans against, and the epoch rendered as a date reads as a
// credential minted in 1970 rather than as "unknown".
//
// `cdat` is explicitly not a fallback — it is the WRONG answer rather than
// a worse one, for the reason above.
func TestParseKeychainModifiedRefusesRatherThanGuessing(t *testing.T) {
	for name, attributes := range map[string]string{
		"nothing at all": "",
		"no date lines":  `attributes:` + "\n" + `    "acct"<blob>="wakil"`,
		"cdat only": `attributes:` + "\n" +
			`    "cdat"<timedate>=0x3230323630393232313330323530.5A00  "20260922130250Z\000"`,
		"unparseable date": `    "mdat"<timedate>=0xAA  "99999999999999Z\000"`,
	} {
		t.Run(name, func(t *testing.T) {
			if got := parseKeychainModified(attributes); !got.IsZero() {
				t.Errorf("parseKeychainModified = %v; want the zero time", got)
			}
		})
	}
}

// TestCredentialPresenceExpiryIsZeroWhenTheDateIsUnknown, so a caller can
// tell "expires then" from "no idea" rather than being handed the epoch
// plus 365 days and having to know that means nothing.
func TestCredentialPresenceExpiryIsZeroWhenTheDateIsUnknown(t *testing.T) {
	if got := (CredentialPresence{Ref: "provider:main"}).Expiry(MintedTokenLifetime); !got.IsZero() {
		t.Errorf("Expiry = %v; want zero for an unknown modification date", got)
	}
	minted := time.Date(2026, 9, 22, 0, 0, 0, 0, time.UTC)
	got := CredentialPresence{Ref: "provider:main", Present: true, Modified: minted}.
		Expiry(MintedTokenLifetime)
	if want := minted.AddDate(1, 0, 0); !got.Equal(want) {
		t.Errorf("Expiry = %v; want %v (365 days, not forever)", got, want)
	}
}

// ---------------------------------------------------------------------
// SecretPresenceFor — presence without a value
// ---------------------------------------------------------------------

// TestSecretPresenceReadsNoValue is the standing rule made structural: the
// lookup runs WITHOUT `-w` and WITHOUT `-g`, so `security` prints
// attributes and no password at all — which is also why it raises no
// access prompt. The pane draws every account on the machine on open;
// going through SecretGet would ask the operator to approve a Keychain
// read per row, for values it then discards.
func TestSecretPresenceReadsNoValue(t *testing.T) {
	argsFile := filepath.Join(t.TempDir(), "args")
	useFakeSecurity(t, `echo "$@" >> `+argsFile+`
cat <<'EOF'
attributes:
    "mdat"<timedate>=0xAA  "20260922130257Z\000"
EOF`)

	presence, err := SecretPresenceFor("acme", "provider:main")
	if err != nil {
		t.Fatal(err)
	}
	if !presence.Present {
		t.Error("Present = false for an item security answered for")
	}
	if presence.Modified.IsZero() {
		t.Error("Modified was not read")
	}

	recorded, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	args := string(recorded)
	// Compared as whole arguments, not as substrings: "-g" is a substring
	// of "find-generic-password", and a Contains check here passes or
	// fails for the wrong reason.
	for _, flag := range strings.Fields(args) {
		if flag == "-w" {
			t.Errorf("the presence check asked for the value: %q", args)
		}
		if flag == "-g" {
			t.Errorf("the presence check asked for the password line: %q", args)
		}
	}
	if !strings.Contains(args, "wakil:acme:provider:main") {
		t.Errorf("the org-scoped service name was not used: %q", args)
	}
}

// TestSecretPresenceTreatsAnAbsentItemAsAnAnswer. Exit 44 is the ordinary
// reply for one of the credential-less bindings this pane exists to NAME,
// and reporting it as a failure would leave the pane unable to tell
// "missing" from "could not look" — the distinction the row is drawn to
// carry.
func TestSecretPresenceTreatsAnAbsentItemAsAnAnswer(t *testing.T) {
	useFakeSecurity(t, `exit 44`)
	presence, err := SecretPresenceFor("acme", "provider:main")
	if err != nil {
		t.Fatalf("an absent item must not be an error: %v", err)
	}
	if presence.Present {
		t.Error("Present = true for an item that does not exist")
	}
	if presence.Ref != "provider:main" {
		t.Errorf("Ref = %q", presence.Ref)
	}
}

// TestSecretPresenceReportsARealFailureAsOne. A locked keychain, a denied
// prompt, a missing binary — none of those is "there is no credential",
// and the row must not draw them as one.
func TestSecretPresenceReportsARealFailureAsOne(t *testing.T) {
	useFakeSecurity(t, `echo "User interaction is not allowed." >&2; exit 51`)
	_, err := SecretPresenceFor("acme", "provider:main")
	if err == nil {
		t.Fatal("a keychain failure was reported as an absent credential")
	}
	msg, ok := IsUserError(err)
	if !ok {
		t.Fatalf("expected a UserError, got %v", err)
	}
	if !strings.Contains(msg, "User interaction is not allowed") {
		t.Errorf("the diagnostic was dropped: %q", msg)
	}
}

// TestSecretPresenceUsesTheAbsolutePathTheACLNames. Shelling out IS the
// design — no hardened-runtime entitlement covers Keychain access, the
// item's own ACL governs it, and the CLI's item trusts exactly one
// application, `/usr/bin/security`, because the CLI created it by shelling
// out too. A bare `security` off PATH is a different application to that
// ACL.
func TestSecretPresenceUsesTheAbsolutePathTheACLNames(t *testing.T) {
	// The CONSTANT, not the variable: `useFakeSecurity` overrides the
	// variable, and a test asserting on it would be asserting on whatever
	// the previous test left behind.
	if defaultSecurityBinary != "/usr/bin/security" {
		t.Fatalf("defaultSecurityBinary = %q; want the absolute path the ACL argument names",
			defaultSecurityBinary)
	}
	// And with nothing overriding it, that constant is what resolves.
	t.Setenv("WAKIL_SECURITY_BINARY", "")
	if got := securityTool(); got != defaultSecurityBinary {
		t.Errorf("securityTool() = %q", got)
	}
}

// TestTheKeychainToolSeamIsHonouredPerCall. The override is read on every
// call rather than captured at package init — a value computed once would
// ignore every test that sets it with `t.Setenv` and send those tests at
// the operator's real keychain, which is the failure the seam exists to
// prevent.
func TestTheKeychainToolSeamIsHonouredPerCall(t *testing.T) {
	fake := filepath.Join(t.TempDir(), "security")
	t.Setenv("WAKIL_SECURITY_BINARY", fake)
	if got := securityTool(); got != keychainTool(fake) {
		t.Fatalf("securityTool() = %q; want the override", got)
	}
}

// ---------------------------------------------------------------------
// The liveness read
// ---------------------------------------------------------------------

// TestSignInReadEnvironmentRemovesTheOAuthToken is the measurement this
// whole function exists for. On this machine, 2026-09-22:
//
//	CLAUDE_CONFIG_DIR=~/.claude-initech                       -> loggedIn: false
//	…the same dir, CLAUDE_CODE_OAUTH_TOKEN=<garbage>      -> loggedIn: true
//
// `auth status --json` does not VALIDATE a token; it reports that one is
// present. Wakil's own harness exports that variable, so a liveness read
// inheriting the parent environment would report every account alive,
// always — and the pane's red rows would be unreachable.
func TestSignInReadEnvironmentRemovesTheOAuthToken(t *testing.T) {
	parent := []string{
		"PATH=/usr/bin",
		claudeOAuthTokenEnv + "=sk-ant-oat01-not-a-real-token",
		claudeConfigDirEnv + "=/some/other/dir",
		"HOME=/Users/x",
	}
	got := signInReadEnvironment(parent, "/Users/x/.claude-main")

	for _, entry := range got {
		if strings.HasPrefix(entry, claudeOAuthTokenEnv+"=") {
			t.Fatalf("the OAuth token survived into the child environment: %q", entry)
		}
	}
	// Exactly one config dir, and it is the one asked for — a duplicate
	// key's winner is not something to leave to the platform.
	var configDirs []string
	for _, entry := range got {
		if strings.HasPrefix(entry, claudeConfigDirEnv+"=") {
			configDirs = append(configDirs, entry)
		}
	}
	if len(configDirs) != 1 || configDirs[0] != claudeConfigDirEnv+"=/Users/x/.claude-main" {
		t.Fatalf("config dir entries = %v", configDirs)
	}
	// Everything else survives: HOME in particular, without which the CLI
	// reads a different machine's worth of state.
	if !containsEntry(got, "HOME=/Users/x") || !containsEntry(got, "PATH=/usr/bin") {
		t.Errorf("unrelated variables were dropped: %v", got)
	}
}

func containsEntry(entries []string, want string) bool {
	for _, entry := range entries {
		if entry == want {
			return true
		}
	}
	return false
}

// TestDecodeSignInLivenessReadsARealAnswer, using verbatim output from
// this machine, 2026-09-22.
func TestDecodeSignInLivenessReadsARealAnswer(t *testing.T) {
	const live = `{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "configDirectory": "/Users/x/.claude-umbrella",
  "email": "someone@example.test",
  "orgName": "example.test",
  "subscriptionType": "enterprise"
}`
	got := DecodeSignInLiveness([]byte(live))
	if !got.LoggedIn || got.Email != "someone@example.test" || got.SubscriptionType != "enterprise" {
		t.Fatalf("liveness = %+v", got)
	}
	if !got.HasIdentity() {
		t.Error("HasIdentity = false for an answer carrying an email")
	}
	// A live sign-in with an identity is one trip: the mint alone.
	if got.TripsToRepair() != 1 {
		t.Errorf("TripsToRepair = %d; want 1", got.TripsToRepair())
	}
}

// TestDecodeSignInLivenessOnALapsedDirectory — verbatim from this machine
// too, and the measurement #205's trip count rests on: a lapsed directory
// reports logged out with NO IDENTITY AT ALL, so there is nothing to offer
// a `Continue as <email>` for, and the repair costs two trips.
func TestDecodeSignInLivenessOnALapsedDirectory(t *testing.T) {
	const lapsed = `{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty",
  "configDirectory": "/Users/x/.claude-initech"
}`
	got := DecodeSignInLiveness([]byte(lapsed))
	if got.LoggedIn {
		t.Fatal("LoggedIn = true for a logged-out directory")
	}
	if got.HasIdentity() {
		t.Errorf("a lapsed directory reported an identity: %+v", got)
	}
	if got.TripsToRepair() != 2 {
		t.Errorf("TripsToRepair = %d; want 2 — and the FIRST trip is the one that clears the red",
			got.TripsToRepair())
	}
	if got.Failure != "" {
		t.Errorf("a successful read of a logged-out directory is not a failure: %q", got.Failure)
	}
}

// TestDecodeSignInLivenessRefusesRatherThanPassingOn — the phase's
// standing rule for a decoder. A zero value here reads as a confident
// "this account is logged out", which is a sentence about the operator's
// machine that nothing established.
func TestDecodeSignInLivenessRefusesRatherThanPassingOn(t *testing.T) {
	for name, raw := range map[string]string{
		"empty":           "",
		"whitespace":      "   \n ",
		"not json":        "command not found",
		"no loggedIn":     `{"authMethod":"none"}`,
		"loggedIn a word": `{"loggedIn":"yes"}`,
	} {
		t.Run(name, func(t *testing.T) {
			got := DecodeSignInLiveness([]byte(raw))
			if got.Failure == "" {
				t.Errorf("decoded %q without a failure: %+v", raw, got)
			}
			if got.LoggedIn {
				t.Errorf("an unreadable answer reported LoggedIn: %+v", got)
			}
		})
	}
}

// TestReadSignInLivenessPinsTheConfigDirVerbatim. The CLI hashes the
// literal string it is handed to name the Keychain item and does not
// resolve symlinks, so resolving here would read one directory under a
// name nothing ever wrote to — a fresh, correct sign-in that reads as
// logged out.
func TestReadSignInLivenessPinsTheConfigDirVerbatim(t *testing.T) {
	dir := t.TempDir()
	seen := filepath.Join(dir, "seen")
	claude := fakeBinary(t, dir, "claude", `
printf '%s' "$CLAUDE_CONFIG_DIR" > `+seen+`
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo '{"loggedIn":true,"authMethod":"oauth_token"}'
else
  echo '{"loggedIn":false,"authMethod":"none"}'
fi`)

	t.Setenv(claudeOAuthTokenEnv, "sk-ant-oat01-not-a-real-token")
	got := ReadSignInLiveness("/a/symlinked/path/.claude-main", claude)

	// The token was set in this process and must not have reached the
	// child — if it had, the fake would have reported logged in.
	if got.LoggedIn {
		t.Error("the OAuth token reached the child and poisoned the read")
	}
	recorded, err := os.ReadFile(seen)
	if err != nil {
		t.Fatal(err)
	}
	if string(recorded) != "/a/symlinked/path/.claude-main" {
		t.Errorf("CLAUDE_CONFIG_DIR = %q; want the string handed over, unresolved", recorded)
	}
}

// TestReadSignInLivenessReportsAFailureRatherThanLoggedOut. A read that
// could not run says nothing about the account; drawing it as "logged out"
// would tell the operator their account had lapsed when nothing of the
// kind was established.
func TestReadSignInLivenessReportsAFailureRatherThanLoggedOut(t *testing.T) {
	dir := t.TempDir()
	broken := fakeBinary(t, dir, "claude", `echo "boom" >&2; exit 3`)
	got := ReadSignInLiveness("/Users/x/.claude-main", broken)
	if got.Failure == "" {
		t.Fatalf("a failed read was reported as a clean answer: %+v", got)
	}
	if got.LoggedIn {
		t.Error("a failed read reported LoggedIn")
	}

	// And a binding with no config dir at all is its own sentence: there
	// is nothing to read, which is not the same as reading nothing.
	noDir := ReadSignInLiveness("", broken)
	if !strings.Contains(noDir.Failure, "config dir") {
		t.Errorf("failure = %q", noDir.Failure)
	}
}

// ---------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------

func addAccount(t *testing.T, org, id string) string {
	t.Helper()
	configDir := filepath.Join(t.TempDir(), ".claude-"+id)
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider(org, Provider{
		ID: id, Kind: ProviderKindClaudeCode, ConfigDir: configDir,
	}); err != nil {
		t.Fatal(err)
	}
	return configDir
}

// TestListAccountsLeavesLocalModelsOut — a `local` provider is an endpoint
// the operator runs, with no sign-in and no credential (3b-viii): Settings
// draws it under LOCAL MODELS, so a row here, and a "no stored credential"
// warning for it, would name a repair that does not exist.
func TestListAccountsLeavesLocalModelsOut(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `exit 44`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")
	if err := SetLocalProvider("acme", Provider{ID: "qwen", BaseURL: "http://127.0.0.1:8012"}); err != nil {
		t.Fatal(err)
	}

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if len(listing.Accounts) != 1 || listing.Accounts[0].ID != "main" {
		t.Fatalf("accounts = %+v, want only main", listing.Accounts)
	}
}

// TestListAccountsDrawsEveryAccountOnTheMachineWithKindAsAColumn — one
// flat table, including accounts registered in OTHER organisations, so
// adopting one later is a gesture rather than a search.
func TestListAccountsDrawsEveryAccountOnTheMachineWithKindAsAColumn(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// A `claude` that answers instantly, so the table's liveness half
	// does not depend on a real CLI being installed.
	useFakeSecurity(t, `exit 44`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := CreateOrg("other", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")
	addAccount(t, "other", "elsewhere")

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if len(listing.Accounts) != 2 {
		t.Fatalf("accounts = %+v", listing.Accounts)
	}
	// The operator's own organisation first, so the rows they can act on
	// are at the top.
	if !listing.Accounts[0].Mine || listing.Accounts[0].ID != "main" {
		t.Fatalf("first row = %+v", listing.Accounts[0])
	}
	// The row homed elsewhere is present and visibly not this
	// organisation's.
	if listing.Accounts[1].Mine {
		t.Errorf("a row in another organisation reported Mine: %+v", listing.Accounts[1])
	}
	if listing.Accounts[1].Org != "other" {
		t.Errorf("Org = %q", listing.Accounts[1].Org)
	}
	// Kind is a column on every row, not a heading some rows sit under.
	for _, row := range listing.Accounts {
		if row.Kind != ProviderKindClaudeCode {
			t.Errorf("Kind = %q on %s", row.Kind, row.ID)
		}
	}
}

// TestListAccountsNamesACredentialLessBindingFromACheck. The existing
// organisation-plane warning fired on "an adoption happened this session",
// so it was right about this machine by luck and silent on relaunch. This
// asks the Keychain.
func TestListAccountsNamesACredentialLessBindingFromACheck(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `exit 44`) // nothing stored, for anything
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	row := listing.Accounts[0]
	if !row.CredentialLess() {
		t.Fatalf("a binding with nothing in the Keychain was not named: %+v", row)
	}
	if row.Credential.Ref != "provider:main" {
		t.Errorf("Ref = %q; the reference is shown and the value is not", row.Credential.Ref)
	}
}

// TestACredentialThatCouldNotBeReadIsNotReportedMissing — "could not look"
// and "is missing" are different facts, and reporting the first as the
// second sends an operator to repair an account that is fine.
func TestACredentialThatCouldNotBeReadIsNotReportedMissing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `echo "User interaction is not allowed." >&2; exit 51`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	row := listing.Accounts[0]
	if row.Credential.Present {
		t.Error("Present = true after a failed lookup")
	}
	if row.CredentialLess() {
		t.Error("a credential that could not be READ was reported as missing")
	}
}

// TestListAccountsPublishesNoCredentialValue. Checked on the encoded form,
// because the wire is what leaves the process.
func TestListAccountsPublishesNoCredentialValue(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `cat <<'EOF'
attributes:
    "mdat"<timedate>=0xAA  "20260922130257Z\000"
EOF`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if !listing.Accounts[0].Credential.Present {
		t.Fatal("the credential was not found")
	}
	b, err := json.Marshal(listing)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"value"`, `"secret"`, `"password"`, `"token"`, "credentialReadable"} {
		if strings.Contains(string(b), forbidden) {
			t.Errorf("the account table publishes %s: %s", forbidden, b)
		}
	}
}

// TestListAccountsIsStableBetweenTwoReadsOfAnUnchangedDisk. The pane reads
// disk on open and on every read, so an unsorted table would visibly
// reorder itself while the operator looked at it.
func TestListAccountsIsStableBetweenTwoReadsOfAnUnchangedDisk(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `exit 44`)
	for _, org := range []string{"acme", "other"} {
		if err := CreateOrg(org, Org{}); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"zebra", "alpha", "mango"} {
		addAccount(t, "acme", id)
	}
	addAccount(t, "other", "beta")

	var first []string
	for range 3 {
		listing, err := listAccountsFor("acme")
		if err != nil {
			t.Fatal(err)
		}
		var order []string
		for _, row := range listing.Accounts {
			order = append(order, row.Org+"/"+row.ID)
		}
		if first == nil {
			first = order
			continue
		}
		if strings.Join(order, ",") != strings.Join(first, ",") {
			t.Fatalf("the table reordered itself: %v then %v", first, order)
		}
	}
	want := "acme/alpha,acme/mango,acme/zebra,other/beta"
	if got := strings.Join(first, ","); got != want {
		t.Errorf("order = %s; want %s (this organisation first, then by org and id)", got, want)
	}
}

// TestListAccountsAnswersWithNoOrganisationChosen. The pane is reachable
// before an organisation has been picked, and a table of everything on the
// machine is exactly what an operator in that state needs. Every row
// reports Mine false, which is true.
func TestListAccountsAnswersWithNoOrganisationChosen(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	useFakeSecurity(t, `exit 44`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")

	listing, err := listAccountsFor("")
	if err != nil {
		t.Fatal(err)
	}
	if len(listing.Accounts) != 1 {
		t.Fatalf("accounts = %+v", listing.Accounts)
	}
	if listing.Accounts[0].Mine {
		t.Error("Mine = true with no organisation chosen")
	}
}

// ---------------------------------------------------------------------
// Found by running the app, not by a test (2026-09-22)
// ---------------------------------------------------------------------

// TestTheLivenessReadGuaranteesUSER.
//
// **Without `USER`, `claude auth status --json` reports `loggedIn: false`
// for a directory that IS signed in.** Measured against
// `~/.claude-umbrella`:
//
//	env -i HOME=… PATH=… CLAUDE_CONFIG_DIR=…  -> loggedIn: false
//	…the same, plus USER=…                    -> loggedIn: true
//
// Bisected across USER, LOGNAME, SHELL, TMPDIR, SSH_AUTH_SOCK and
// __CF_USER_TEXT_ENCODING; only USER changes the answer.
//
// It matters because `WakilWiring.childProcessEnvironment` builds what
// `wakil-ctx` is spawned with key by key — HOME, PATH, WAKIL_ORG,
// WAKIL_PROVIDER — so in the shipped app this process has no USER to
// forward, and every account read as signed out.
//
// The exact mirror of the OAuth-token removal: that one stops a false
// ALIVE, this one stops a false DEAD.
func TestTheLivenessReadGuaranteesUSER(t *testing.T) {
	// A parent with no USER at all, which is what `wakil-ctx` has.
	got := signInReadEnvironment(
		[]string{"HOME=/Users/x", "PATH=/usr/bin"}, "/Users/x/.claude-main")

	var user string
	for _, entry := range got {
		if name, value, _ := strings.Cut(entry, "="); name == "USER" {
			user = value
		}
	}
	if user == "" {
		t.Fatal("USER was not supplied; every liveness read would report signed out")
	}

	// A parent that HAS one keeps it — the derivation is a fallback, not
	// an override.
	got = signInReadEnvironment(
		[]string{"HOME=/Users/x", "USER=someoneelse"}, "/Users/x/.claude-main")
	if !containsEntry(got, "USER=someoneelse") {
		t.Errorf("the parent's own USER was replaced: %v", got)
	}
}

// TestALoggedOutDirectoryIsNotReportedAsUnreadable.
//
// **`claude auth status --json` EXITS 1 WHEN LOGGED OUT**, while printing
// a perfectly good answer. Measured:
//
//	~/.claude-initech      exit=1  loggedIn: false
//	~/.claude-umbrella  exit=0  loggedIn: true
//
// Reading the exit status first made every genuinely signed-out account
// report "could not read the sign-in" — which loses the red row the
// column exists to draw, hides the repair control hanging off it, and
// leaves the trip count reading from a failure rather than from liveness.
//
// Same ordering, same reason, as `MintProviderToken`: read what the
// process SAID before judging how it ended.
func TestALoggedOutDirectoryIsNotReportedAsUnreadable(t *testing.T) {
	dir := t.TempDir()
	// Prints the logged-out answer and exits 1, exactly as the real CLI
	// does.
	claude := fakeBinary(t, dir, "claude",
		`echo '{"loggedIn":false,"authMethod":"none"}'; exit 1`)

	got := ReadSignInLiveness("/Users/x/.claude-main", claude)
	if got.Failure != "" {
		t.Fatalf("a logged-out directory was reported as unreadable: %q", got.Failure)
	}
	if got.LoggedIn {
		t.Error("LoggedIn = true for a logged-out directory")
	}
	// And the repair cost comes out of liveness rather than out of a
	// failure.
	if got.TripsToRepair() != 2 {
		t.Errorf("TripsToRepair = %d; want 2", got.TripsToRepair())
	}
}

// TestAnUnreadableAnswerIsStillAFailure — the other half of that
// ordering. Exiting badly with nothing readable is not "signed out".
func TestAnUnreadableAnswerIsStillAFailure(t *testing.T) {
	dir := t.TempDir()
	broken := fakeBinary(t, dir, "claude", `echo "boom" >&2; exit 3`)

	got := ReadSignInLiveness("/Users/x/.claude-main", broken)
	if got.Failure == "" {
		t.Fatal("a process that said nothing readable was reported as a clean answer")
	}
}

// TestARowWhoseOwnLookupFailedIsNotReportedMissing — the review finding.
//
// The whole-table `keychainUnavailable` is not the only way a lookup can
// fail: a single row can fail on a machine where the tool works fine (a
// locked keychain, a denied prompt). `Checked` therefore travels PER ROW,
// because a consumer reconstructing it from the table-level flag decodes
// that row as a MISSING credential — the exact conflation the row exists
// to keep apart.
func TestARowWhoseOwnLookupFailedIsNotReportedMissing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	// The tool RUNS — so the table is not "unavailable" — and answers
	// with a real failure rather than exit 44.
	useFakeSecurity(t, `echo "User interaction is not allowed." >&2; exit 51`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	addAccount(t, "acme", "main")

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if listing.KeychainUnavailable {
		t.Fatal("the tool ran, so the table is not unavailable; this tests the wrong case")
	}
	row := listing.Accounts[0]
	if row.Credential.Checked {
		t.Error("Checked = true after a lookup that failed")
	}
	if row.CredentialLess() {
		t.Error("a row whose own lookup failed was reported as missing its credential")
	}

	// And it crosses the wire, which is where the conflation happened.
	b, err := json.Marshal(row.Credential)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"checked":false`) {
		t.Errorf("the per-row check did not reach the wire: %s", b)
	}
}

// TestTheRecordedBinaryReachesTheLivenessRead — the review finding. An
// `Account` carries neither `ClaudePath` nor `Shared`, so a `Provider`
// rebuilt from a row resolves to "" every time and every liveness read
// silently falls back to bare `claude`.
func TestTheRecordedBinaryReachesTheLivenessRead(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	useFakeSecurity(t, `exit 44`)
	if err := CreateOrg("acme", Org{}); err != nil {
		t.Fatal(err)
	}
	configDir := filepath.Join(t.TempDir(), ".claude-main")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	// A recorded binary that answers distinctively, so "was it used?" is
	// observable rather than inferred.
	recorded := fakeBinary(t, t.TempDir(), "claude",
		`echo '{"loggedIn":true,"authMethod":"claude.ai","email":"recorded@example.test"}'`)
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: ProviderKindClaudeCode, ConfigDir: configDir, ClaudePath: recorded,
	}); err != nil {
		t.Fatal(err)
	}

	listing, err := listAccountsFor("acme")
	if err != nil {
		t.Fatal(err)
	}
	if got := listing.Accounts[0].Liveness.Email; got != "recorded@example.test" {
		t.Errorf("liveness email = %q; the recorded binary was not used", got)
	}
}

// TestAZeroModificationDateIsOmittedFromTheWire.
//
// **`omitempty` does not work on a struct field**, so a zero `time.Time`
// crossed the wire as `"0001-01-01T00:00:00Z"` — which the Swift side
// parsed as a perfectly good date and rendered as an expiry in the year
// 2. That is the failure `parseKeychainModified` refuses to commit, *a
// wrong date is worse than no date*, reintroduced at the encoder.
func TestAZeroModificationDateIsOmittedFromTheWire(t *testing.T) {
	b, err := json.Marshal(CredentialPresence{Ref: "provider:main", Checked: true})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "0001-01-01") {
		t.Errorf("the zero time reached the wire: %s", b)
	}
	if strings.Contains(string(b), "modified") {
		t.Errorf("an absent date was still published: %s", b)
	}

	// A real one still travels.
	when := time.Date(2026, 9, 22, 13, 2, 57, 0, time.UTC)
	b, err = json.Marshal(CredentialPresence{Ref: "provider:main", Present: true, Checked: true, Modified: when})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "2026-09-22") {
		t.Errorf("a real date did not travel: %s", b)
	}
}

// TestTheResolvedBinaryTravelsOnTheWire — #238.
//
// Swift spawns this executable to sign in, and it has no other way to
// name it: `Process.executableURL` does not search PATH, and a GUI
// launched from Finder inherits launchd's minimal one. While `binary`
// was unexported the surface fell back to bare "claude", which resolved
// against the working directory and failed with `NSFilePath=/claude`.
func TestTheResolvedBinaryTravelsOnTheWire(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, ".claude-wire")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	agent := fakeBinary(t, home, "claude", `echo '{"loggedIn":false}'`)

	if err := CreateOrg("wire-org", Org{}); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("wire-org", Provider{
		ID: "main", Kind: "claude-code", ConfigDir: configDir, ClaudePath: agent,
	}); err != nil {
		t.Fatal(err)
	}

	listing, err := listAccountsFor("wire-org")
	if err != nil {
		t.Fatal(err)
	}
	if len(listing.Accounts) != 1 {
		t.Fatalf("accounts = %+v", listing.Accounts)
	}
	if got := listing.Accounts[0].Binary; got != agent {
		t.Errorf("Binary = %q, want the recorded claudePath %q", got, agent)
	}

	b, err := json.Marshal(listing.Accounts[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"binary":"`+agent+`"`) {
		t.Errorf("the resolved binary did not reach the wire: %s", b)
	}
}
