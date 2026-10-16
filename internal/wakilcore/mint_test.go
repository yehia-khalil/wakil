package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NOTE. Nothing here spawns the real `claude` or touches the real
// keychain. `DecodeMintedToken` is a pure function, and the one test that
// runs `MintProviderToken` points both `securityBinary` and the agent
// binary at fakes.

// TestDecodeMintedTokenTakesTheTokenAndNothingElse. The CLI prints the
// credential on a line of its own, amid chatter.
func TestDecodeMintedTokenTakesTheTokenAndNothingElse(t *testing.T) {
	const output = `Opening your browser to authorize...
Waiting for authorization...

Your long-lived token (valid for 1 year):

sk-ant-oat01-EXAMPLEEXAMPLEEXAMPLEEXAMPLE

Store it somewhere safe.
`
	if got := DecodeMintedToken(output); got != "sk-ant-oat01-EXAMPLEEXAMPLEEXAMPLEEXAMPLE" {
		t.Fatalf("DecodeMintedToken = %q", got)
	}
}

// TestDecodeMintedTokenTakesTheLastCandidate. Instructions printed AHEAD
// of the token can mention the prefix — "your token starts with sk-ant-"
// — so first-match is the wrong rule and last-match is the right one.
func TestDecodeMintedTokenTakesTheLastCandidate(t *testing.T) {
	const output = `Tokens look like sk-ant-oat01-XXXXXXXXXXXXXXXXXXXX and are shown once.
sk-ant-oat01-THEREALONEREALONEREALONE
`
	if got := DecodeMintedToken(output); got != "sk-ant-oat01-THEREALONEREALONEREALONE" {
		t.Fatalf("DecodeMintedToken = %q", got)
	}
}

// TestDecodeMintedTokenRefusesRatherThanPassingSomethingOn is the rule
// that matters most here: storing a plausible non-token puts rubbish under
// a name the window then launches sessions with, and it fails much later
// with a 401 pointing nowhere near the step that caused it — exactly how
// the hex-encoding defect survived Phase 1.
//
// The prefix is matched rather than the shape, deliberately: a shape rule
// ("long, no spaces") matches a URL, a session id, and half the chatter
// around it.
func TestDecodeMintedTokenRefusesRatherThanPassingSomethingOn(t *testing.T) {
	for name, output := range map[string]string{
		"nothing at all":        "",
		"only whitespace":       "   \n\n  \t\n",
		"chatter with no token": "Opening your browser...\nAuthorization complete.\n",
		"a url":                 "Visit https://claude.ai/oauth/authorize?code=abcdefghijklmnop\n",
		"a session id":          "session 9f8e7d6c5b4a39281706f5e4d3c2b1a0\n",
		"the prefix quoted":     `Your token begins with "sk-ant-".` + "\n",
		"the bare prefix":       "sk-ant-\n",
		"too short":             "sk-ant-oat01-abc\n",
		"has a space":           "sk-ant-oat01-EXAMPLE EXAMPLE EXAMPLE\n",
	} {
		t.Run(name, func(t *testing.T) {
			if got := DecodeMintedToken(output); got != "" {
				t.Errorf("DecodeMintedToken(%q) = %q; want nothing", output, got)
			}
		})
	}
}

// TestMintRefusesToMintAgainstADirectoryThatIsNotSignedIn. A wrong "yes"
// mints a real 365-day credential against the wrong directory, so the
// sign-in is re-verified BEFORE the browser trip rather than after it.
func TestMintRefusesToMintAgainstADirectoryThatIsNotSignedIn(t *testing.T) {
	dir := t.TempDir()
	claude := fakeBinary(t, dir, "claude", `
case "$2" in
  status) echo '{"loggedIn":false,"authMethod":"none"}' ;;
  *) echo "sk-ant-oat01-SHOULD-NEVER-BE-REACHED-AAAA" ;;
esac`)
	useFakeSecurity(t, `exit 0`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", claude)
	if outcome.Stored {
		t.Fatal("a mint ran against a directory that is not signed in")
	}
	if outcome.Uncertain {
		t.Error("refusing BEFORE the trip is a clean failure, not an uncertain one")
	}
	if !strings.Contains(outcome.Detail, "not signed in") {
		t.Errorf("detail = %q", outcome.Detail)
	}
}

// TestMintStoresTheTokenAndReturnsNothingAboutIt. The token reaches the
// Keychain and nothing else — the outcome carries no field it could
// travel in, which is what makes "the token never reaches Swift" a
// property of the type rather than a promise.
func TestMintStoresTheTokenAndReturnsNothingAboutIt(t *testing.T) {
	fakeKeychain(t)
	dir := t.TempDir()
	claude := fakeBinary(t, dir, "claude", `
case "$2" in
  status) echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test"}' ;;
  *) echo "minting..."; echo "sk-ant-oat01-EXAMPLEEXAMPLEEXAMPLE" ;;
esac`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", claude)
	if !outcome.Stored {
		t.Fatalf("the token was not stored: %+v", outcome)
	}
	if outcome.Uncertain {
		t.Error("a stored token is not uncertain")
	}
	// Nothing about the token comes back.
	if strings.Contains(outcome.Detail, "sk-ant-") {
		t.Errorf("the outcome carries the token: %q", outcome.Detail)
	}

	stored, err := SecretGetFor("acme", ProviderTokenRef("main"))
	if err != nil {
		t.Fatal(err)
	}
	if stored != "sk-ant-oat01-EXAMPLEEXAMPLEEXAMPLE" {
		t.Errorf("stored = %q", stored)
	}
}

// TestMintStoresATokenPrintedByAProcessThatThenFailed.
//
// The decode happens BEFORE the error is consulted, and this is why: a
// process can print a credential and then exit non-zero — a broken pipe
// on the way out, a cleanup step that fails — and in that case the
// credential EXISTS. Discarding it because the exit status was unhappy
// would destroy a one-year credential that is printed once and kept
// nowhere.
func TestMintStoresATokenPrintedByAProcessThatThenFailed(t *testing.T) {
	fakeKeychain(t)
	dir := t.TempDir()
	claude := fakeBinary(t, dir, "claude", `
case "$2" in
  status) echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test"}' ;;
  *) echo "sk-ant-oat01-PRINTEDTHENFAILEDAAAA"; echo "cleanup failed" >&2; exit 1 ;;
esac`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", claude)
	if !outcome.Stored {
		t.Fatalf("a printed token was discarded because the process exited badly: %+v", outcome)
	}
	stored, err := SecretGetFor("acme", ProviderTokenRef("main"))
	if err != nil || stored != "sk-ant-oat01-PRINTEDTHENFAILEDAAAA" {
		t.Errorf("stored = %q, %v", stored, err)
	}
}

// TestMintReportsACleanFailureWhenNothingWasPrinted. A process that ran
// and failed WITHOUT printing is an observed refusal, and may say so —
// this is the branch that is allowed to claim nothing was created.
func TestMintReportsACleanFailureWhenNothingWasPrinted(t *testing.T) {
	fakeKeychain(t)
	dir := t.TempDir()
	claude := fakeBinary(t, dir, "claude", `
case "$2" in
  status) echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test"}' ;;
  *) echo "authorization declined" >&2; exit 1 ;;
esac`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", claude)
	if outcome.Stored {
		t.Fatal("Stored = true with nothing printed")
	}
	if outcome.Uncertain {
		t.Error("a refusal that printed nothing is a CLEAN failure, not an uncertain one")
	}
	if !strings.Contains(outcome.Detail, "authorization declined") {
		t.Errorf("the refusal's own message was dropped: %q", outcome.Detail)
	}
}

// TestMintIsUncertainWhenATokenWasCreatedAndCouldNotBeStored.
//
// **The worst outcome in the phase, and it has a name.** A credential was
// created and Wakil could not keep it; it is printed once and persisted
// nowhere, so it cannot be recovered. Reporting this as "the mint failed"
// would leave a live 365-day credential at Anthropic that the operator
// does not know exists.
func TestMintIsUncertainWhenATokenWasCreatedAndCouldNotBeStored(t *testing.T) {
	dir := t.TempDir()
	claude := fakeBinary(t, dir, "claude", `
case "$2" in
  status) echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test"}' ;;
  *) echo "sk-ant-oat01-CREATEDBUTUNSTORABLE" ;;
esac`)
	// A keychain that refuses to write.
	useFakeSecurity(t, `echo "User interaction is not allowed." >&2; exit 51`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", claude)
	if outcome.Stored {
		t.Fatal("Stored = true after a failed write")
	}
	if !outcome.Uncertain {
		t.Fatalf("a created-but-unstored credential must be UNCERTAIN: %+v", outcome)
	}
	// The sentence has to say the credential exists, that it cannot be
	// recovered, and what to do — revoke it.
	for _, phrase := range []string{"WAS created", "cannot be recovered", "revoke"} {
		if !strings.Contains(outcome.Detail, phrase) {
			t.Errorf("the detail does not say %q: %q", phrase, outcome.Detail)
		}
	}
	// And never the token itself.
	if strings.Contains(outcome.Detail, "sk-ant-") {
		t.Errorf("the detail carries the token: %q", outcome.Detail)
	}
}

// TestMintRefusesWhenTheSignInCouldNotBeChecked. "Could not look" is not
// "is signed in", and minting on the optimistic reading is what mints a
// real credential against the wrong directory.
func TestMintRefusesWhenTheSignInCouldNotBeChecked(t *testing.T) {
	fakeKeychain(t)
	dir := t.TempDir()
	broken := fakeBinary(t, dir, "claude", `echo "boom" >&2; exit 3`)

	outcome := MintProviderToken("acme", "main", "/Users/x/.claude-main", broken)
	if outcome.Stored {
		t.Fatal("a mint ran after a sign-in check that did not answer")
	}
	if !strings.Contains(outcome.Detail, "could not be re-checked") {
		t.Errorf("detail = %q", outcome.Detail)
	}
}

// TestMintRefusesWithNoConfigDir. There is nothing to mint against, and
// an empty CLAUDE_CONFIG_DIR would mint against whatever default account
// the CLI finds — the cross-account confusion Invariant 4 exists to
// prevent.
func TestMintRefusesWithNoConfigDir(t *testing.T) {
	outcome := MintProviderToken("acme", "main", "", "claude")
	if outcome.Stored || outcome.Uncertain {
		t.Fatalf("outcome = %+v", outcome)
	}
	if !strings.Contains(outcome.Detail, "no config dir") {
		t.Errorf("detail = %q", outcome.Detail)
	}
}

// TestDecodeMintedTokenReadsATokenPrintedInsideASentence — #244.
//
// The whole reason the mint kept failing after the spawn was fixed: on a
// terminal the CLI prints the credential inline, so a line-based scan
// never matched and every successful mint was discarded.
func TestDecodeMintedTokenReadsATokenPrintedInsideASentence(t *testing.T) {
	token := "sk-ant-oat01-EXAMPLEEXAMPLEEXAMPLEEXAMPLE"
	rendered := "✓ Long-lived authentication token created successfully! " +
		"Your OAuth token (valid for 1 year): " + token + " Store this token securely. " +
		"You won't be able to see it again. Use this token by setting: " +
		"export CLAUDE_CODE_OAUTH_TOKEN=<token>"

	if got := DecodeMintedToken(rendered); got != token {
		t.Errorf("DecodeMintedToken = %q, want %q", got, token)
	}
}

// And it still refuses the prose around it: the placeholder `<token>`, the
// environment variable's NAME, and the prefix quoted in a sentence are all
// in that same output.
func TestDecodeMintedTokenStillRefusesTheProseAroundIt(t *testing.T) {
	for name, output := range map[string]string{
		"the placeholder":     "Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>",
		"the variable name":   "export CLAUDE_CODE_OAUTH_TOKEN=",
		"the prefix in prose": `Your token begins with "sk-ant-".`,
		"a callback url": "redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode" +
			"%2Fcallback&scope=user%3Ainference",
	} {
		if got := DecodeMintedToken(output); got != "" {
			t.Errorf("%s: decoded %q, want nothing", name, got)
		}
	}
}

// ---------------------------------------------------------------------
// CommitMintedProvider — #259
// ---------------------------------------------------------------------

// commitGround sets up one org with a fake keychain and a fake agent, and
// returns the config dir and the agent's path.
func commitGround(t *testing.T, org, id string) (configDir, agent string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("WAKIL_ORG", org)
	fakeKeychain(t)

	configDir = filepath.Join(home, ".claude-"+id)
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	agent = fakeBinary(t, home, "claude", `echo '{"loggedIn":true}'`)
	if err := CreateOrg(org, Org{}); err != nil {
		t.Fatal(err)
	}
	return configDir, agent
}

// TestCommitRecordsTheAgentExecutable — the defect this ticket exists for.
//
// A binding with no `claudePath` that homes its own directory resolves to
// "" for ever, so `setProvider` refuses it and nothing in the pane can
// repair it: an operator never types a path. Every account added through
// the pane was born unusable, while the same account added by the CLI
// worked — the CLI takes `--claude-path`.
func TestCommitRecordsTheAgentExecutable(t *testing.T) {
	configDir, agent := commitGround(t, "acme", "main")
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-EXAMPLE"); err != nil {
		t.Fatal(err)
	}

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err != nil {
		t.Fatal(err)
	}

	record, err := LoadProviderFor("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if record.ClaudePath != agent {
		t.Errorf("ClaudePath = %q, want %q", record.ClaudePath, agent)
	}
	// The property that actually matters: it resolves, so a session can
	// start under it.
	resolved, err := ResolveProviderClaudePath(*record)
	if err != nil || resolved != agent {
		t.Errorf("ResolveProviderClaudePath = %q, %v; want %q", resolved, err, agent)
	}
}

// **A check, not a convention.** Refusing here is what makes the unusable
// record unreachable rather than merely unlikely.
func TestCommitRefusesAClaudeCodeBindingWithNoExecutable(t *testing.T) {
	configDir, _ := commitGround(t, "acme", "main")
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-EXAMPLE"); err != nil {
		t.Fatal(err)
	}

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", ""); err == nil {
		t.Fatal("committed a claude-code binding with no agent executable")
	}
	if _, err := LoadProviderFor("acme", "main"); err == nil {
		t.Error("a refused commit still wrote a record")
	}
}

// Mint before record, stated as a check — the ordering #204 made a
// property rather than a convention, and never pinned.
func TestCommitRefusesWhenNoCredentialIsStored(t *testing.T) {
	configDir, agent := commitGround(t, "acme", "main")

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err == nil {
		t.Fatal("wrote a binding for an account with no stored credential")
	}
}

// A repair commits nothing and is not an error (#244) — but only when the
// directory matches, because re-homing an account silently would move it
// out from under every organisation sharing the directory it used to name.
func TestCommitIsIdempotentForARepairAndRefusesARehome(t *testing.T) {
	configDir, agent := commitGround(t, "acme", "main")
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-EXAMPLE"); err != nil {
		t.Fatal(err)
	}
	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err != nil {
		t.Fatal(err)
	}

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err != nil {
		t.Errorf("a repair was refused: %v", err)
	}

	elsewhere := filepath.Join(t.TempDir(), ".claude-elsewhere")
	if err := os.MkdirAll(elsewhere, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := CommitMintedProvider("main", elsewhere, "claude-code", "", agent); err == nil {
		t.Error("silently re-homed a binding to a different directory")
	}
	// Compared resolved, because that is how AddProvider stored it — the
	// same reason the product compares them that way.
	record, err := LoadProviderFor("acme", "main")
	if err != nil || resolvedConfigDir(record.ConfigDir) != resolvedConfigDir(configDir) {
		t.Errorf("ConfigDir = %q, want the original %q", record.ConfigDir, configDir)
	}
}

// TestARepairBackfillsTheAgentExecutable — #271, found by review.
//
// #259 recorded the executable on a first add and left the repair path
// alone, so every record this phase had already created — `{kind,
// configDir}` and nothing else — stayed unusable for ever: a
// re-authentication stored the credential and changed nothing, and
// re-authenticating is the only repair the pane offers.
func TestARepairBackfillsTheAgentExecutable(t *testing.T) {
	configDir, agent := commitGround(t, "acme", "main")
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-EXAMPLE"); err != nil {
		t.Fatal(err)
	}
	// A record in the shape this phase used to write: no claudePath.
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: "claude-code", ConfigDir: configDir,
	}); err != nil {
		t.Fatal(err)
	}
	before, err := LoadProviderFor("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if before.ClaudePath != "" {
		t.Fatalf("the fixture already names an executable: %q", before.ClaudePath)
	}

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err != nil {
		t.Fatal(err)
	}

	after, err := LoadProviderFor("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if after.ClaudePath != agent {
		t.Errorf("ClaudePath = %q after a repair, want %q", after.ClaudePath, agent)
	}
	if resolved, err := ResolveProviderClaudePath(*after); err != nil || resolved != agent {
		t.Errorf("still does not resolve: %q, %v", resolved, err)
	}
}

// **It fills a gap; it does not overrule a choice.** A record that names
// an executable keeps the one it names.
func TestARepairDoesNotOverwriteAnExecutableAlreadyNamed(t *testing.T) {
	configDir, agent := commitGround(t, "acme", "main")
	chosen := fakeBinary(t, t.TempDir(), "claude", `echo '{"loggedIn":true}'`)
	if err := SecretSetFor("acme", ProviderTokenRef("main"), "sk-ant-oat01-EXAMPLE"); err != nil {
		t.Fatal(err)
	}
	if err := AddProvider("acme", Provider{
		ID: "main", Kind: "claude-code", ConfigDir: configDir, ClaudePath: chosen,
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := CommitMintedProvider("main", configDir, "claude-code", "", agent); err != nil {
		t.Fatal(err)
	}

	after, err := LoadProviderFor("acme", "main")
	if err != nil {
		t.Fatal(err)
	}
	if after.ClaudePath != chosen {
		t.Errorf("ClaudePath = %q, want the one already recorded %q", after.ClaudePath, chosen)
	}
}
