package wakilcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// SecretDelete removes the Keychain item for ref under org.
//
// **Go's first secret delete** (#206). Everything about it follows
// `SecretGet` and `SecretSet`: the org-scoped service name, the absolute
// path to the tool the item's ACL names, and exit 44 distinguished from a
// real failure.
//
// **An absent item is success, not an error.** Unlink must never refuse,
// and a binding whose credential was already gone — which is the state
// three bindings on this machine are in today — is exactly the case
// unlink exists to clean up. Reporting "there was nothing to delete" as a
// failure would make the pane refuse to finish a removal the operator
// asked for.
func SecretDelete(org, ref string) error {
	service, err := keychainService(org, ref)
	if err != nil {
		return err
	}
	cmd := keychainCommand("delete-generic-password",
		"-s", service, "-a", keychainAccount)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == keychainNotFoundExitCode {
			return nil
		}
		return UserError("could not delete the keychain entry for ref " + ref +
			" in org " + org + ": " + diagnostic(err, &stderr))
	}
	return nil
}

// UnlinkOutcome is what an unlink did, and what it could not do.
//
// **It owes one permanent sentence: this phase creates a credential it
// cannot destroy.** `CredentialRemoved` says the organisation's own
// Keychain item is gone; `MintedTokenSurvives` says the credential that
// item held is still live at Anthropic, because a `setup-token` token is
// revocable by nothing Wakil can reach.
type UnlinkOutcome struct {
	// RecordRemoved is whether the binding's record was deleted.
	RecordRemoved bool `json:"recordRemoved"`
	// CredentialRemoved is whether this organisation's Keychain item was
	// deleted. False when there was none — which is not a failure.
	CredentialRemoved bool `json:"credentialRemoved"`
	// PointersCleared names the stale pointers this unlink had to fix.
	//
	// **Not housekeeping.** After a removal, `org.json` still names the
	// gone provider and `SaveOrg` then REFUSES to write the file at all —
	// so the settings pane breaks its own form. `active.json` has the
	// mirror defect and is validated nowhere.
	PointersCleared []string `json:"pointersCleared,omitempty"`
	// Backfilled names sharing records that inherited from this one and
	// were given the departing home's resolved agent binary before it
	// went.
	Backfilled []string `json:"backfilled,omitempty"`
	// WasLastBinding is whether no organisation holds this account any
	// more. **The sole exception to Invariant 4's refusal of revocation**
	// — and an OFFER, never automatic.
	WasLastBinding bool `json:"wasLastBinding"`
	// ConfigDir is the directory left in place, named so the operator can
	// see what survived.
	ConfigDir string `json:"configDir,omitempty"`
	// Notes are sentences the surface shows. Always carries the permanent
	// one about the credential this phase cannot destroy.
	Notes []string `json:"notes,omitempty"`
}

// MintedTokenIrrevocableNote is the one permanent sentence an unlink owes.
//
// A constant rather than a string built at the call site, because it is a
// promise about what Wakil did and did not do, and a surface that composes
// its own version of it will eventually compose a softer one.
const MintedTokenIrrevocableNote = "Wakil removed this organisation's stored credential, " +
	"but it cannot destroy the long-lived credential that was created for this account — " +
	"a setup-token credential is revocable only in your Anthropic account."

// RevocationUnreliableNote warns that the CLI's own logout lies.
//
// Measured: `claude auth logout` prints success when it revoked nothing,
// so anything shelling out to it reports a revocation it did not perform.
// The offer must say so, or it is Wakil passing on a false claim.
const RevocationUnreliableNote = "Revoking through the CLI is not reliable: it reports " +
	"success even when it revoked nothing. Check your Anthropic account rather than " +
	"trusting the result."

// UnlinkProvider removes one organisation's binding to an account.
//
// # An organisation unlinks a BINDING; it never removes a provider
//
// Decision 32. The record and the Keychain item are both per-(org, id);
// the ACCOUNT is the config directory; and one account on this machine
// carries four different ids across four organisations. *Home* is an
// artefact of which registration claimed the directory, not a setting
// anybody chose.
//
// # It never refuses
//
// `RemoveProvider`'s refusal does not survive, because it rests on a
// claim that is false and was measured so: it refuses to remove a record
// that HOMES a directory other records share, on the grounds that doing
// so would leave them with no home and no way to restore one. What it
// actually guarded is one optional field — the agent binary a sharer
// inherits — and the fix landed in the ADD path (#201): adoption records
// the resolved `claudePath`, and a binding added to an unhomed directory
// becomes the home. **Two changes in the add path, none in the remove
// path.**
//
// This function backfills anyway, for the records that predate that fix.
//
// # It deletes three things, all the organisation's own
//
//  1. The record.
//  2. The Keychain item — Go's first secret delete.
//  3. The stale pointers, which is not housekeeping: after a removal
//     `org.json` still names the gone provider and `SaveOrg` then refuses
//     to write the file, so the pane breaks its own form.
//
// # It backfills BEFORE deleting the departing home
//
// Dropping the orphan refusal means an unlinked home promotes `shared`
// bindings that would otherwise have nothing to inherit from. The order
// is forced: after the record is gone, there is nothing left to inherit.
//
// # It never touches the config directory
//
// Same reason as the add path: the Keychain item is named from a hash of
// the directory path, so deleting the directory makes the item's name
// uncomputable.
func UnlinkProvider(org, id string) (UnlinkOutcome, error) {
	outcome := UnlinkOutcome{}
	if err := validateProviderToken(id); err != nil {
		return outcome, err
	}
	record, err := LoadProviderFor(org, id)
	if err != nil {
		return outcome, err
	}
	outcome.ConfigDir = record.ConfigDir

	// **Backfill first.** After the record is gone there is nothing left
	// to inherit from, so this cannot be deferred to a cleanup pass.
	if record.ConfigDir != "" && !record.Shared {
		outcome.Backfilled = backfillSharers(org, id, *record)
	}

	// Whether this was the last binding has to be asked BEFORE the
	// delete, for the same reason.
	outcome.WasLastBinding = isLastBinding(org, id, record.ConfigDir)

	if err := removeProviderRecord(org, id); err != nil {
		return outcome, err
	}
	outcome.RecordRemoved = true

	// The Keychain item. An absent one is not a failure — three bindings
	// on this machine are in exactly that state.
	presence, presenceErr := SecretPresenceFor(org, ProviderTokenRef(id))
	if presenceErr == nil && presence.Present {
		if err := SecretDelete(org, ProviderTokenRef(id)); err != nil {
			outcome.Notes = append(outcome.Notes,
				"the record is gone, but this organisation's stored credential could not be "+
					"deleted: "+userFacing(err))
		} else {
			outcome.CredentialRemoved = true
		}
	}

	outcome.PointersCleared = clearStalePointers(org, id)

	// **The one permanent sentence.** Always, whether or not an item was
	// deleted: what survives is the credential at Anthropic, not the local
	// copy.
	outcome.Notes = append(outcome.Notes, MintedTokenIrrevocableNote)
	if outcome.ConfigDir != "" {
		outcome.Notes = append(outcome.Notes,
			"The config dir "+outcome.ConfigDir+" is left exactly as it was. Wakil never "+
				"deletes one: the credential's Keychain name is derived from that path, so "+
				"removing the directory would make the name uncomputable.")
	}
	return outcome, nil
}

// backfillSharers gives every record sharing this one's directory the
// resolved agent binary it has been inheriting, so that losing the home
// costs them nothing.
//
// Best-effort per sharer: one unwritable record must not block the
// unlink, which never refuses.
func backfillSharers(org, id string, departing Provider) []string {
	sharers, err := configDirSharers(departing.ConfigDir, org, id)
	if err != nil {
		return nil
	}
	resolved, err := ResolveProviderClaudePath(departing)
	if err != nil || resolved == "" {
		return nil
	}

	var filled []string
	for _, sharer := range sharers {
		sharerOrg, sharerID, ok := splitSharer(sharer)
		if !ok {
			continue
		}
		record, err := LoadProviderFor(sharerOrg, sharerID)
		if err != nil || record.ClaudePath != "" {
			// One that already names its own binary inherits nothing and
			// needs nothing.
			continue
		}
		record.ClaudePath = resolved
		// It is also no longer a share of anything: the directory it
		// shares is about to have no home. Promoting the first one is
		// what `AddProvider`'s unhomed branch would do for a new binding,
		// and doing it here keeps the invariant — a directory with
		// records has a home — true across the delete.
		if len(filled) == 0 {
			record.Shared = false
		}
		if err := updateProviderRecord(sharerOrg, *record); err != nil {
			continue
		}
		filled = append(filled, sharer)
	}
	return filled
}

// clearStalePointers removes every reference to a gone provider.
//
// **Not housekeeping.** `SaveOrg` refuses to write a record whose
// `defaultProvider` names nothing, so an unlink that left one behind would
// break the settings pane's own organisation form — the pane would refuse
// to save a field the operator never touched. `active.json` has the mirror
// defect and is validated nowhere, so a stale pointer there is silent
// until a launch reads it.
func clearStalePointers(org, id string) []string {
	var cleared []string

	if record, err := LoadOrgFor(org); err == nil && record.DefaultProvider == id {
		record.DefaultProvider = ""
		if err := SaveOrg(org, *record); err == nil {
			cleared = append(cleared, "org.json defaultProvider")
		}
	}

	// Only the CURRENT org's active context is this unlink's to touch —
	// another organisation's active context is inside a boundary this
	// call is not.
	if current, err := CurrentOrg(); err == nil && current == org {
		if active, err := ReadActive(); err == nil && active.Provider == id {
			active.Provider = ""
			if err := WriteActive(active); err == nil {
				cleared = append(cleared, "active.json provider")
			}
		}
	}
	return cleared
}

// isLastBinding reports whether no other organisation holds this account.
//
// Asked of the CONFIG DIRECTORY rather than of the id, because the account
// is the directory: one account carries four different ids across four
// organisations, so "is any binding to this account left" is a question
// about the path.
//
// A binding with no config dir is the last one for itself by definition —
// there is no directory to share.
func isLastBinding(org, id, configDir string) bool {
	if configDir == "" {
		return true
	}
	sharers, err := configDirSharers(configDir, org, id)
	if err != nil {
		return false
	}
	return len(sharers) == 0
}

// splitSharer parses the "org/id" form configDirSharers reports.
//
// Split on the FIRST separator: an org id cannot contain one
// (`validateOrgToken`), so anything after it belongs to the provider id.
func splitSharer(sharer string) (org, id string, ok bool) {
	org, id, found := strings.Cut(sharer, "/")
	return org, id, found && org != "" && id != ""
}

// updateProviderRecord writes a record back in place, for the backfill.
//
// It does not go through `AddProvider`, which refuses an id that already
// exists — the whole point here is to UPDATE one. Named distinctly from
// the test helper `writeProviderRecord` in `provider_test.go`, which
// writes a record by hand to construct a state the product cannot.
func updateProviderRecord(org string, p Provider) error {
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, p.ID+".json"), b)
}

// removeProviderRecord deletes the record file and nothing else.
//
// **Deliberately not `RemoveProvider`.** That function carries the orphan
// refusal this ticket drops, and reaching it here would reintroduce the
// refusal through the back door — an unlink that refuses is exactly what
// #206 rules out.
func removeProviderRecord(org, id string) error {
	dir, err := providersDirFor(org)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, id+".json")
	if err := os.Remove(path); err != nil {
		return UserError("could not remove the binding " + strconv.Quote(id) +
			" in org " + strconv.Quote(org) + ": " + err.Error())
	}
	return nil
}
