package wakilcore

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// MintOutcome is what a mint did, and it is deliberately narrow: a mint
// either stored a credential or it did not, and the one thing an operator
// must never be told is a clean failure that is not one.
type MintOutcome struct {
	// Stored is true only when the token reached the Keychain.
	Stored bool `json:"stored"`
	// Uncertain is the state that has no clean name: a one-year
	// credential may exist at Anthropic that Wakil never caught.
	//
	// **This is the outcome the whole design is arranged around.** The
	// token is printed ONCE and persisted nowhere, so dropping it between
	// capture and store *destroys* it — and a capture that produced
	// something Wakil then failed to store is indistinguishable, from the
	// outside, from one that never produced anything. It must not be
	// reported as a clean failure.
	Uncertain bool `json:"uncertain"`
	// Detail is the sentence an operator reads. Never the token, and
	// never anything derived from it.
	Detail string `json:"detail,omitempty"`
}

// mintTimeout bounds the second browser trip.
//
// The operator is approving a consent screen by hand, so this is generous
// for the same reason the login's is. What bounds it at all is that an
// abandoned mint must eventually release the band.
const mintTimeout = 5 * time.Minute

// MintProviderToken runs `claude setup-token` against configDir, captures
// the token it prints, and stores it to the Keychain — **atomically, in
// Go, printing nothing**.
//
// # Why this is a one-shot verb and not an MCP action
//
// Three reasons, each independently sufficient:
//
//   - Every `ctx_*` action is a thin proxy on a ten-second reply timeout,
//     and a browser trip is minutes.
//   - `JournalEntry.params` is written verbatim on every dispatch —
//     refused and blocked ones included — so *"delegate through an
//     action"* and *"the secret rides in the params"* cannot both be
//     true. Go captures and stores, so **the token never reaches Swift**
//     and nothing needs redacting.
//   - Being a separate process, a `wakil-ctx` restart cannot kill it
//     mid-flight.
//
// # Why mint-and-store must be atomic
//
// The token is printed **once and persisted nowhere**. Dropping it between
// capture and store does not lose a copy — it *destroys* the credential,
// and the only way to get another is a third browser trip. So there is no
// point between the capture and the store at which this function returns,
// logs, or hands anything to anybody.
//
// # Why the sign-in is re-verified first
//
// A wrong "yes" mints a real 365-day credential against the wrong
// directory. The check costs one fast local call and removes a class of
// error that is otherwise silent and expensive.
//
// # The cost, named rather than buried
//
// The spawn is deliberately not seamed on the Go side, following
// `secrets.go`, which shells out to `security` with no seam at all. So
// mint-and-store — the most dangerous operation in this phase — has **no
// automated coverage on either side of the language boundary**. The decode
// is extracted and tested directly (`DecodeMintedToken`), and the
// uncertain outcome above is the mitigation. It is a record, not a test.
func MintProviderToken(org, id, configDir, binary string) MintOutcome {
	if configDir == "" {
		return MintOutcome{Detail: "no config dir was given, so there is nothing to mint against"}
	}
	if binary == "" {
		binary = "claude"
	}

	// **Re-verified before minting.** `ReadSignInLiveness` reads with the
	// OAuth-token variable absent, so it answers about the DIRECTORY
	// rather than about whatever token this process happens to carry —
	// which is the only reading that can tell us we are about to mint
	// against the right account.
	liveness := ReadSignInLiveness(configDir, binary)
	if liveness.Failure != "" {
		return MintOutcome{
			Detail: "the sign-in could not be re-checked before minting, so nothing was minted: " +
				liveness.Failure,
		}
	}
	if !liveness.LoggedIn {
		return MintOutcome{
			Detail: "that directory is not signed in, so nothing was minted — " +
				"sign in first and then mint",
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), mintTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, binary, "setup-token")
	cmd.Env = signInReadEnvironment(os.Environ(), configDir)
	// **On a terminal, not a pipe.** `setup-token` renders through an
	// interactive console UI that writes nothing at all when its output
	// is not a terminal — so with pipes the browser trip completed, a
	// real credential was created at Anthropic, and Wakil saw zero bytes
	// and waited out the deadline. See `runOnPTY` for the measurement.
	//
	// One stream, not two: a terminal has a single output, so what would
	// have been stderr arrives interleaved here. Nothing downstream
	// needed them apart — the decode scans for a token and the failure
	// path quotes whatever was said.
	output, runErr := runOnPTY(cmd)

	// The decode happens BEFORE the error is consulted, deliberately. A
	// process can print a token and then exit non-zero — a broken pipe on
	// the way out, a cleanup step that fails — and in that case the
	// credential exists and is in this buffer. Reading the buffer first is
	// what turns that into a stored credential rather than an uncertain
	// one.
	token := DecodeMintedToken(output)

	if runErr != nil {
		if token == "" {
			if ctx.Err() != nil {
				// **A timeout may not claim what a refusal may.** The
				// process was killed; whether it had already completed an
				// exchange with Anthropic and was about to print is
				// exactly what nobody knows.
				return MintOutcome{
					Uncertain: true,
					Detail: "the credential step did not finish in time and was stopped. " +
						"Wakil did not catch a token — but one may have been created, " +
						"and Wakil cannot tell. Check your Anthropic account before minting again.",
				}
			}
			// The process ran and failed without printing. That is an
			// observed refusal and may say so.
			text := strings.TrimSpace(output)
			return MintOutcome{
				Detail: "no credential was created: " +
					firstNonEmpty(text, "the credential step failed without a message"),
			}
		}
		// Printed a token AND failed. The credential exists; storing it is
		// strictly better than discarding it.
	}

	if token == "" {
		// **It says what it saw, redacted.** "printed nothing a token
		// could be read from" is true and useless: it cannot distinguish
		// a refusal from a changed output shape from a credential the CLI
		// now keeps for itself, and each needs a different answer. The
		// excerpt is the tail, because that is where a result lands, and
		// every long unbroken run of credential-shaped characters is
		// removed first — this text reaches a surface and a journal.
		return MintOutcome{
			Uncertain: true,
			Detail: "the credential step ended without a token Wakil could read, so nothing " +
				"was stored — and a credential may still have been created, which is " +
				"revocable only in your Anthropic account. What it printed: " +
				redactedTail(output, 400),
		}
	}

	if err := SecretSetFor(org, ProviderTokenRef(id), token); err != nil {
		// **The worst outcome, and it is named.** A token was created and
		// Wakil could not keep it. It is irrecoverable — printed once,
		// persisted nowhere — and the operator must be told that rather
		// than told the mint failed.
		return MintOutcome{
			Uncertain: true,
			Detail: "a long-lived credential WAS created and could not be stored: " +
				userFacing(err) + ". It cannot be recovered — it is printed once and kept " +
				"nowhere — so revoke it in your Anthropic account and mint again.",
		}
	}
	return MintOutcome{Stored: true}
}

// DecodeMintedToken pulls the credential out of `claude setup-token`'s
// output.
//
// **Extracted and tested directly**, which is the phase's standing rule
// for a decoder and is doubly the rule here: the spawn around it has no
// automated coverage at all, so this is the only part of the mint a test
// can reach.
//
// **It refuses rather than passing something on.** Returning a plausible
// non-token would store rubbish under a name the window then launches
// sessions with, failing much later with a 401 that points nowhere near
// the step that caused it — which is exactly how the hex-encoding defect
// survived Phase 1.
//
// The CLI prints the token on a line of its own, usually amid other
// chatter. So: take the last line that looks like a credential, and
// nothing else. **Last rather than first**, because instructions printed
// ahead of it can mention the prefix.
func DecodeMintedToken(raw string) string {
	var found string
	// **Fields, not lines** (#244). The CLI prints the credential INSIDE a
	// sentence — "Your OAuth token (valid for 1 year): sk-ant-…  Store this
	// token securely." — so no line is ever equal to the token, and a
	// line-based scan found nothing however well the spawn worked. That
	// cost a real one-year credential per attempt: minted at Anthropic,
	// printed to Wakil, and dropped on the floor.
	//
	// Nothing is loosened by the change. A field has no whitespace by
	// construction, and the prefix and length rules below are what
	// actually do the work.
	for _, field := range strings.Fields(raw) {
		// Trailing sentence punctuation only, and never a leading
		// character: a token's own alphabet does not contain these, and
		// trimming the right-hand side is what lets the strictness below
		// stay strict rather than being widened to tolerate a full stop.
		candidate := strings.TrimRight(field, `.,;:"'`+"`")
		if isMintedToken(candidate) {
			found = candidate
		}
	}
	return found
}

// mintedTokenPrefix is what a `setup-token` credential begins with.
//
// Matching on the prefix rather than on shape is deliberate: a shape rule
// ("long, no spaces") matches a URL, a session id and half the chatter
// around it, and storing any of those is worse than storing nothing —
// nothing fails immediately and visibly.
const mintedTokenPrefix = "sk-ant-"

func isMintedToken(candidate string) bool {
	if !strings.HasPrefix(candidate, mintedTokenPrefix) {
		return false
	}
	// Long enough to be a credential rather than the prefix quoted in a
	// sentence, and free of whitespace, which no token contains.
	if len(candidate) < len(mintedTokenPrefix)+16 {
		return false
	}
	return !strings.ContainsAny(candidate, " \t\"'`")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

// CommitMintedProvider writes the binding for an account whose credential
// has just been minted, for the CURRENT organisation.
//
// **Mint before record, enforced rather than ordered.** It refuses unless
// a credential is already stored, which makes today's orphaned bindings —
// a record naming an account whose Keychain item was never written —
// unreproducible through this door. An ordering convention can be got
// wrong by a later caller; a check cannot.
//
// **One record, for the organisation the operator is standing in.** No
// list of organisations and no choosing: another organisation adopts the
// same account later from its own pane, which is `AdoptProvider` and is a
// different gesture with a different cost.
//
// It returns the row the pane draws — credential presence and sign-in
// liveness included — so the table shows the new account without a second
// round trip and without the pane assembling a row of its own.
func CommitMintedProvider(id, configDir, kind, label, claudePath string) (Account, error) {
	org, err := CurrentOrg()
	if err != nil {
		return Account{}, err
	}
	if kind == "" {
		kind = ProviderKindClaudeCode
	}

	// **A claude-code binding must record the executable it runs** (#259),
	// and this is a CHECK rather than a convention the caller could get
	// wrong — the same idiom as the credential check below it.
	//
	// Without it this function wrote records with no `claudePath`, and a
	// record with no `claudePath` that homes its own directory resolves to
	// "" for ever: `setProvider` refuses it with "the provider record is
	// missing claudePath", and nothing in the pane could repair it because
	// the pane has no field for a path an operator never types. So every
	// account added through the pane was born unusable, while the same
	// account added by the CLI worked — the CLI takes `--claude-path`.
	//
	// The caller always knows it: the sign-in and the mint it just ran
	// both spawned that exact binary.
	if kind == ProviderKindClaudeCode && claudePath == "" {
		return Account{}, UserError("refusing to write a claude-code binding for " +
			strconv.Quote(id) + " with no agent executable recorded: a binding that does " +
			"not name one cannot start a session, and nothing in the pane can add it later")
	}

	// **The check that makes the ordering a property.** A presence read,
	// not a value read: nothing here needs the token, and reading one
	// would raise an access prompt for a value that is immediately
	// discarded.
	presence, err := SecretPresenceFor(org, ProviderTokenRef(id))
	if err != nil {
		return Account{}, UserError("the credential could not be checked before writing the " +
			"binding, so nothing was written: " + userFacing(err))
	}
	if !presence.Present {
		return Account{}, UserError("no credential is stored for " + id + " in org " + org +
			" — the binding is written after the credential, never before. Mint first.")
	}

	// **A re-authentication commits nothing, and that is not an error**
	// (#244). `AddProvider` refuses an id this organisation already holds,
	// which is right for an ADD and wrong for a repair: the binding being
	// repaired is precisely one that exists. Without this, a successful
	// re-authentication stored the credential and then reported that the
	// binding could not be written — the one sentence reserved for a
	// genuinely orphaned credential.
	//
	// The directory still has to MATCH. A record pointing somewhere else
	// is not the binding that was just repaired, and silently re-homing it
	// would move an account out from under every organisation sharing the
	// directory it used to name.
	if existing, err := LoadProviderFor(org, id); err == nil {
		// **Compared RESOLVED, because that is how it was stored.**
		// `AddProvider` records `EvalSymlinks(abs)`, so a caller handing
		// in the same directory by its unresolved name — which on macOS
		// is every path under `/var`, `/tmp` or a symlinked home — would
		// otherwise look like a re-home and every repair of such an
		// account would be refused. Caught by the test, not by reading.
		if resolvedConfigDir(existing.ConfigDir) != resolvedConfigDir(configDir) {
			return Account{}, UserError("binding " + strconv.Quote(id) + " in org " +
				strconv.Quote(org) + " already points at " + strconv.Quote(existing.ConfigDir) +
				", not " + strconv.Quote(configDir) + ". The credential was stored; the " +
				"binding was left alone rather than re-homed.")
		}
		// **A repair BACKFILLS the executable, and that is the whole
		// repair for a record born without one** (#271). Committing
		// nothing was right for a record that already carries everything;
		// it was wrong for the records this phase itself created, which
		// carry `{kind, configDir}` and nothing else. Those cannot start a
		// session, and re-authenticating one — the only repair the pane
		// offers — stored a credential and then changed nothing, so the
		// binding stayed unusable for ever. Found by review, after the
		// commit that claimed to close it.
		//
		// Only ever FILLS a gap: a record that names an executable keeps
		// the one it names, because that is a choice somebody made and
		// this function is not the place to overrule it.
		if existing.ClaudePath == "" && claudePath != "" {
			existing.ClaudePath = claudePath
			if err := updateProviderRecord(org, *existing); err != nil {
				return Account{}, UserError("the credential was stored, but the binding's " +
					"agent executable could not be recorded: " + userFacing(err))
			}
		}
	} else if err := AddProvider(org, Provider{
		ID: id, Kind: kind, Label: label, ConfigDir: configDir, ClaudePath: claudePath,
	}); err != nil {
		return Account{}, err
	}

	provider, err := LoadProviderFor(org, id)
	if err != nil {
		return Account{}, err
	}
	row := accountRow(org, org, *provider, false)
	// Liveness for the one row, rather than a whole table: the pane is
	// about to re-read anyway, and what this answers is "did it land",
	// which the caller needs before that read returns.
	rows := []Account{row}
	fillLiveness(rows)
	return rows[0], nil
}

// credentialShaped matches any long unbroken run of the characters a
// credential is made of.
//
// **Deliberately broader than `mintedTokenPrefix`.** This guards text on
// its way to a surface and a journal, so it must not depend on the token
// still looking the way this build expects — the whole reason the excerpt
// exists is that the output shape may have changed.
var credentialShaped = regexp.MustCompile(`[A-Za-z0-9_\-]{20,}`)

// redactedTail answers the last n characters of s with anything
// credential-shaped removed, for a message an operator reads.
func redactedTail(s string, n int) string {
	s = strings.TrimSpace(credentialShaped.ReplaceAllString(s, "[redacted]"))
	s = strings.Join(strings.Fields(s), " ")
	if s == "" {
		return "(nothing at all)"
	}
	if len(s) > n {
		return "…" + s[len(s)-n:]
	}
	return s
}

// resolvedConfigDir answers the path AddProvider would have stored.
//
// A path that cannot be resolved answers itself: this is used to COMPARE
// two directories, and refusing to compare because one of them has gone
// missing would turn a repair into a refusal for a reason the operator
// cannot act on.
func resolvedConfigDir(dir string) string {
	if dir == "" {
		return ""
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return dir
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		return resolved
	}
	return abs
}
