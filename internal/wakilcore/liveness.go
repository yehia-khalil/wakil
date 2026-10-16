package wakilcore

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"os/user"
	"strings"
	"time"
)

// SignInLiveness is what `claude auth status --json` says about a config
// directory's sign-in.
//
// **It describes the SIGN-IN, never the minted token**, and the surface
// must say so or a red row reads as a broken session when it is not one.
// The two credentials a row carries differ in REVOCABILITY, and the
// irrevocable one — the minted `setup-token` — is the one that actually
// launches sessions. A directory whose sign-in has lapsed still launches
// sessions perfectly well.
//
// So this is an **identity signal, not a capability signal**. The token's
// state is a computed date (`CredentialPresence.Expiry`), never a probe.
type SignInLiveness struct {
	// LoggedIn is the CLI's own answer, read with the OAuth-token
	// environment variable ABSENT — see ReadSignInLiveness for why that
	// is not optional.
	LoggedIn bool `json:"loggedIn"`
	// AuthMethod is "claude.ai", "oauth_token", "none", … as the CLI
	// reports it.
	AuthMethod string `json:"authMethod,omitempty"`
	// Email, OrgName and SubscriptionType are the IDENTITY, and they are
	// what makes a live sign-in re-usable: #205's re-entry offers
	// `Continue as <email>` and can only do so when one came back.
	//
	// Measured on this machine, 2026-09-22: a lapsed directory reports
	// `loggedIn: false`, `authMethod: "none"` and NO identity at all — no
	// email, no org. So "has an identity" and "is logged in" arrive
	// together or not at all, and there is nothing to offer a
	// `Continue as` for on a dead directory.
	Email            string `json:"email,omitempty"`
	OrgName          string `json:"orgName,omitempty"`
	SubscriptionType string `json:"subscriptionType,omitempty"`
	// Failure is why the read did not happen, when it did not. A read
	// that could not run and a directory that is logged out are
	// different facts: the first says nothing about the account, and
	// drawing it as the second would tell the operator their account had
	// lapsed when nothing of the kind was established.
	Failure string `json:"failure,omitempty"`
}

// HasIdentity reports whether the CLI named whose sign-in this is.
//
// The re-entry prompt turns on this rather than on LoggedIn, because
// there is nothing to say "continue as" about without a name — and
// because the two only ever disagree in the direction that matters: a
// poisoned read (see ReadSignInLiveness) reports logged in with no
// identity at all.
func (l SignInLiveness) HasIdentity() bool { return l.Email != "" }

// claudeOAuthTokenEnv is the variable that makes `auth status --json`
// worthless when it is set.
const claudeOAuthTokenEnv = "CLAUDE_CODE_OAUTH_TOKEN"

// claudeConfigDirEnv scopes the CLI to one account's directory.
const claudeConfigDirEnv = "CLAUDE_CONFIG_DIR"

// ReadSignInLiveness asks the CLI whether configDir's sign-in is live.
//
// **The OAuth-token variable is removed from the child's environment, and
// that is not hygiene — without it this function is worthless.** Measured
// on this machine, 2026-09-22: `~/.claude-initech` is a genuinely logged-out
// directory and reports `loggedIn: false, authMethod: "none"`; the same
// directory read with `CLAUDE_CODE_OAUTH_TOKEN` set to the literal string
// `sk-ant-oat01-definitely-not-a-real-token` reports `loggedIn: true,
// authMethod: "oauth_token"`. `auth status --json` does not VALIDATE a
// token; it reports that one is present. Wakil's own harness exports that
// variable, so a liveness read inheriting the parent environment would
// report every account alive, always.
//
// **One string.** `configDir` is used exactly as handed over — the CLI
// hashes the literal string it is given to name the Keychain item and does
// not resolve symlinks (`phase-2e-probe.md` §2.2), so resolving here would
// read one directory under a name nothing wrote to. Resolve once, at the
// derivation; this is downstream of that.
//
// **The first read of a FRESH directory creates its scaffolding.**
// Measured: against a directory that has never been used, the CLI writes
// `.claude.json`, `.claude.json.lock` and `backups/` before answering;
// against an initialised one it writes nothing. So reading liveness is not
// side-effect-free on first contact — which strengthens "Wakil creating
// the directory is belt-and-braces" — and re-reads put nothing in a write
// loop.
//
// A failure is reported in the returned value rather than as an error,
// because a row that could not be read is still a row, and the pane has
// to draw it as "could not look" rather than as "logged out".
func ReadSignInLiveness(configDir, claudeBinary string) SignInLiveness {
	if configDir == "" {
		return SignInLiveness{Failure: "this account records no config dir, so its sign-in cannot be read"}
	}
	if claudeBinary == "" {
		claudeBinary = "claude"
	}

	ctx, cancel := context.WithTimeout(context.Background(), signInReadTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, claudeBinary, "auth", "status", "--json")
	cmd.Env = signInReadEnvironment(os.Environ(), configDir)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	// **Decoded BEFORE the exit status is consulted, and that ordering is
	// the whole of this function's correctness.**
	//
	// `claude auth status --json` EXITS 1 WHEN LOGGED OUT while printing
	// a perfectly good answer. Measured on this machine, 2026-09-22:
	//
	//	~/.claude-initech      exit=1  loggedIn: false
	//	~/.claude-umbrella  exit=0  loggedIn: true
	//
	// Reading the status first made every genuinely signed-out account
	// report "could not read the sign-in" — which loses the red row this
	// whole column exists to draw, hides the repair control that hangs
	// off it, and leaves #205's trip count reading from a failure rather
	// than from liveness. "Could not look" and "is signed out" are
	// different facts, and the exit status alone cannot tell them apart.
	//
	// Same ordering, same reason, as `MintProviderToken`: read what the
	// process SAID before judging how it ended.
	if decoded := DecodeSignInLiveness(stdout.Bytes()); decoded.Failure == "" {
		return decoded
	}

	if err := runErr; err != nil {
		if ctx.Err() != nil {
			// Named as a timeout rather than folded into the generic
			// failure: a read that ran out of time says nothing about
			// the account, and an operator told "could not read the
			// sign-in" would go looking for a broken account instead of
			// a slow one.
			return SignInLiveness{
				Failure: "the sign-in check did not answer within " + signInReadTimeout.String(),
			}
		}
		return SignInLiveness{
			Failure: "could not read the sign-in: " + diagnostic(err, &stderr),
		}
	}
	// It exited cleanly and still said nothing readable — report that as
	// the failure it is rather than as a confident "signed out".
	return DecodeSignInLiveness(stdout.Bytes())
}

// signInReadEnvironment builds the child environment for a liveness read:
// the parent's, with the config dir pinned, the OAuth token REMOVED, and
// `USER` guaranteed present.
//
// Extracted so both properties are pure functions a test can assert on
// directly. Each is the difference between this function being useful and
// being a generator of wrong answers, in opposite directions, and neither
// may rest on a spawn nobody can observe.
//
// # USER must be there, and that is measured
//
// **Without `USER`, `claude auth status --json` reports `loggedIn: false`
// for a directory that IS signed in.** Measured on this machine,
// 2026-09-22, against `~/.claude-umbrella`:
//
//	env -i HOME=… PATH=… CLAUDE_CONFIG_DIR=…   -> loggedIn: false
//	…the same, plus USER=…                     -> loggedIn: true
//
// Bisected across `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `SSH_AUTH_SOCK`
// and `__CF_USER_TEXT_ENCODING`; only `USER` changes the answer.
//
// **This is not hypothetical, and it is why the guarantee is here rather
// than at the call site.** `WakilWiring.childProcessEnvironment` builds
// what `wakil-ctx` is spawned with key by key — `HOME`, `PATH`,
// `WAKIL_ORG`, `WAKIL_PROVIDER` and nothing else — so inside the shipped
// app this process has no `USER` to forward. Every liveness read would
// report every account signed out: a red row on a perfectly good account,
// and #205's trip count reading "2 of 2" when the repair needs one.
//
// It is the exact mirror of the OAuth-token removal above. That one stops
// a false ALIVE; this one stops a false DEAD. A read that can only be
// wrong in one direction is still worthless.
//
// Derived from the process's own identity when the parent lacks it, so the
// guarantee does not depend on whoever spawned us having got it right.
func signInReadEnvironment(parent []string, configDir string) []string {
	out := make([]string, 0, len(parent)+2)
	hasUser := false
	for _, entry := range parent {
		name, value, found := strings.Cut(entry, "=")
		if !found {
			continue
		}
		// Both are replaced rather than appended-after: a duplicate key's
		// winner is not something to leave to the platform.
		if name == claudeOAuthTokenEnv || name == claudeConfigDirEnv {
			continue
		}
		if name == userEnv && value != "" {
			hasUser = true
		}
		out = append(out, entry)
	}
	if !hasUser {
		if name := currentUserName(); name != "" {
			out = append(out, userEnv+"="+name)
		}
	}
	return append(out, claudeConfigDirEnv+"="+configDir)
}

// userEnv is the variable whose absence makes the CLI report a signed-in
// directory as signed out.
const userEnv = "USER"

// currentUserName answers this process's login name without needing the
// environment to carry it — which is the whole point, since the process
// that spawned us may have built a minimal one.
func currentUserName() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}

// DecodeSignInLiveness turns `claude auth status --json`'s output into a
// SignInLiveness.
//
// **Extracted and tested directly**, the phase's standing rule for a
// decoder (following `decodeProviderCredentials`), and it **refuses an
// empty or missing field rather than passing it on**: output that is not
// JSON at all, or that carries no `loggedIn`, is reported as a failure
// rather than decoded to a zero value that reads as a confident
// "logged out".
func DecodeSignInLiveness(raw []byte) SignInLiveness {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return SignInLiveness{Failure: "the sign-in check printed nothing"}
	}
	// Decoded into a map first, so "absent" and "false" can be told
	// apart. A struct decode makes them identical, and the difference is
	// exactly what separates a real answer from an unrecognised one.
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &fields); err != nil {
		return SignInLiveness{Failure: "the sign-in check did not answer JSON: " + err.Error()}
	}
	rawLoggedIn, ok := fields["loggedIn"]
	if !ok {
		return SignInLiveness{Failure: "the sign-in check answered JSON with no loggedIn field"}
	}
	var out SignInLiveness
	if err := json.Unmarshal(rawLoggedIn, &out.LoggedIn); err != nil {
		return SignInLiveness{Failure: "the sign-in check's loggedIn was not a boolean"}
	}
	for key, target := range map[string]*string{
		"authMethod":       &out.AuthMethod,
		"email":            &out.Email,
		"orgName":          &out.OrgName,
		"subscriptionType": &out.SubscriptionType,
	} {
		if raw, ok := fields[key]; ok {
			// A field of the wrong type is dropped rather than failing
			// the whole read: it is descriptive, and losing an org name
			// must not cost the operator the one fact — logged in or not
			// — the row exists to show.
			_ = json.Unmarshal(raw, target)
		}
	}
	return out
}

// TripsToRepair is how many browser trips re-authenticating this account
// costs: one when the sign-in is live and names somebody, two otherwise.
//
// **The count derives from LIVENESS, not from the directory existing**
// (`phase-2e-probe.md` §3.2, §4). Under the rejected reading — a directory
// that merely resolves counts as live — pressing Re-authenticate on a red
// row succeeded and LEFT THE ROW RED, because nothing on a mint-only path
// writes the sign-in. Liveness and re-entry are the same signal read
// twice, so the counter needs no rule of its own.
//
// #205 ships the flow; the number is here because it is a property of the
// liveness reading and belongs beside it.
func (l SignInLiveness) TripsToRepair() int {
	if l.LoggedIn && l.HasIdentity() {
		return 1
	}
	return 2
}

// signInReadTimeout bounds one liveness read.
//
// The settings pane reads every account on the machine on open, so a
// single hung CLI must not hold the whole table. Generous against a
// measured read — well under a second on this machine — because the cost
// of being wrong in the other direction is a row that reports "could not
// look" for an account that is fine.
const signInReadTimeout = 10 * time.Second
