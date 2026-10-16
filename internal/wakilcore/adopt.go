package wakilcore

import "strconv"

// AdoptRequest binds an account that already exists on this machine into
// another organisation.
//
// **`From` is what the shape gained in 2e (#201)**, and it is what makes
// an adoption instant. The credential is copied Keychain-to-Keychain from
// the organisation that already holds it, so no browser opens — possible
// only because the minted token is KEPT. The token is what is portable;
// the config directory's own sign-in is not.
type AdoptRequest struct {
	// Org is the organisation adopting the account, and ID is the id the
	// binding takes there. The operator may choose their own id, so the
	// two ids in this struct are genuinely independent.
	Org string
	ID  string

	Kind      string
	Label     string
	ConfigDir string

	// FromOrg and FromID name the binding the credential is copied FROM —
	// the row the operator pressed Adopt on.
	//
	// Both empty means "copy nothing", which is the honest shape for a
	// caller that has no source: the binding is still created, and the row
	// will report its credential missing rather than pretending one
	// arrived.
	FromOrg string
	FromID  string
}

// AdoptOutcome says what an adoption actually did, beyond writing the
// record.
//
// **It is a value and not a set of errors**, because none of these is a
// failure of the adoption: the binding exists either way, and the settings
// pane draws the row. What they are is the difference between a row that
// can start a session and one that cannot — which the operator has to be
// told rather than discover when a window refuses to open.
type AdoptOutcome struct {
	// CredentialCopied is whether a credential was read from the source
	// and written for the adopting organisation.
	CredentialCopied bool `json:"credentialCopied"`
	// CredentialNote is why it was not, when it was not. Empty when it
	// was, and empty when no source was named at all.
	CredentialNote string `json:"credentialNote,omitempty"`
	// ClaudePath is the agent binary recorded on the new binding, resolved
	// from the source. Empty when the source recorded none and none could
	// be inherited.
	ClaudePath string `json:"claudePath,omitempty"`
	// BecameHome is whether this binding became the config directory's
	// home, which happens when nothing homed it.
	BecameHome bool `json:"becameHome,omitempty"`
}

// AdoptProvider binds an existing account into another organisation,
// copying its credential.
//
// **Three changes make an adoption work, and the first is what makes it
// instant** (#201):
//
//  1. **The credential is copied** — a Keychain read followed by a
//     Keychain write, both in Go, both silent, the service name derived
//     rather than stored. Forgetting this second copy is exactly today's
//     defect: `ProviderTokenRef` carries no org, so the same account
//     reached from two organisations needs the same token stored twice,
//     and a binding without it leaves the window refusing to start against
//     a Keychain item that simply does not exist. Three such bindings are
//     on this machine.
//  2. **The resolved agent-binary path is recorded.** `adoptProviderArgs`
//     had no such field at all, so this ADDS an argument rather than
//     populating one (Decision 32 carries the correction).
//  3. **A binding added to a directory nothing homes becomes the home** —
//     in `AddProvider`, which is where that decision belongs.
//
// Together, (2) and (3) are what let #206 drop `RemoveProvider`'s orphan
// refusal: two changes in the add path, none in the remove path.
//
// **No browser opens at any point**, and nothing here reads or writes a
// config directory.
//
// **The credential copy is best-effort, and the outcome says so.** A
// source that holds no credential, or a Keychain that will not answer,
// does not fail the adoption — the binding is real, the row draws, and it
// reports its credential missing, which is true and repairable from that
// row (#205). Failing instead would leave the operator with neither a
// binding nor an explanation.
func AdoptProvider(request AdoptRequest) (AdoptOutcome, error) {
	var outcome AdoptOutcome

	// The agent binary, resolved from the SOURCE binding rather than
	// guessed. A shared binding inherits from its own home, which is
	// exactly what ResolveProviderClaudePath answers — so the adopting
	// record ends up naming a real binary even when the source named none
	// of its own.
	if request.FromOrg != "" && request.FromID != "" {
		if source, err := LoadProviderFor(request.FromOrg, request.FromID); err == nil {
			if resolved, err := ResolveProviderClaudePath(*source); err == nil {
				outcome.ClaudePath = resolved
			}
		}
	}

	// Whether this binding will become the home has to be asked BEFORE the
	// write, because afterwards the answer is trivially yes.
	if request.ConfigDir != "" {
		if homeOrg, _, err := ConfigDirHome(request.ConfigDir); err == nil && homeOrg == "" {
			outcome.BecameHome = true
		}
	}

	if err := AddProvider(request.Org, Provider{
		ID:         request.ID,
		Kind:       request.Kind,
		Label:      request.Label,
		ConfigDir:  request.ConfigDir,
		ClaudePath: outcome.ClaudePath,
		// Shared is what makes this an adoption rather than a re-home:
		// AddProvider refuses a config dir another org already homes
		// unless it is set. When nothing homes the directory, AddProvider
		// clears it and this binding becomes the home instead.
		Shared: true,
	}); err != nil {
		return outcome, err
	}

	outcome.CredentialCopied, outcome.CredentialNote = copyProviderCredential(request)
	return outcome, nil
}

// copyProviderCredential moves the minted token from the source
// organisation's Keychain item to the adopting organisation's.
//
// **Silent, in Go, and the service name is derived.** Nothing about the
// credential travels through an action's parameters, so nothing needs
// redacting — which is the whole reason a provider credential is minted
// and stored in Go rather than delegated (`JournalEntry.params` is written
// verbatim on every dispatch, refused and blocked ones included).
//
// It returns a NOTE rather than an error for every ordinary way it can
// decline, because none of them should undo a binding the operator asked
// for. See AdoptProvider.
func copyProviderCredential(request AdoptRequest) (copied bool, note string) {
	if request.FromOrg == "" || request.FromID == "" {
		return false, ""
	}
	// Adopting within one organisation would read and write the same item
	// when the ids match, and is meaningless when they do not: the source
	// binding's credential already serves that organisation.
	if request.FromOrg == request.Org && request.FromID == request.ID {
		return false, ""
	}

	value, err := SecretGetFor(request.FromOrg, ProviderTokenRef(request.FromID))
	if err != nil {
		return false, "the credential was not copied: " + userFacing(err) +
			" — this binding cannot start a session until one is stored for it"
	}
	if value == "" {
		return false, "the source binding " + strconv.Quote(request.FromOrg+"/"+request.FromID) +
			" holds no credential, so none was copied"
	}
	if err := SecretSetFor(request.Org, ProviderTokenRef(request.ID), value); err != nil {
		return false, "the credential could not be stored for " + strconv.Quote(request.Org) +
			": " + userFacing(err)
	}
	return true, ""
}

// userFacing renders err's sentence, preferring the UserError text.
func userFacing(err error) string {
	if msg, ok := IsUserError(err); ok {
		return msg
	}
	return err.Error()
}
