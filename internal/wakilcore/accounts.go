package wakilcore

import (
	"sort"
	"sync"
)

// Account is one row of the settings pane's flat account table: every
// account on this machine, with its credential's presence and its
// sign-in's liveness (#200).
//
// **One flat table with `kind` as a COLUMN**, not a kind-headed layout. A
// kind-headed one would make the pane teach the wrong word: §9 defines
// *Provider* as the credential and does not define *Kind* at all.
//
// **An account registered in ANOTHER organisation is a row in this same
// table**, so adopting it later is a gesture rather than a search. `Org`
// says which organisation holds the binding and `Mine` says whether that
// is the one the operator is standing in.
//
// **It carries a credential's REFERENCE and PRESENCE, never its value**,
// and there is no field here one could travel in.
type Account struct {
	// Org is the organisation whose record this binding is. A binding is
	// (organisation, provider id); the ACCOUNT is the config dir, and one
	// account on this machine carries four different ids across four
	// organisations.
	Org string `json:"org"`
	ID  string `json:"id"`
	// Kind is a COLUMN, which is the whole argument against a kind-headed
	// layout.
	Kind      string `json:"kind"`
	Label     string `json:"label,omitempty"`
	ConfigDir string `json:"configDir,omitempty"`
	// HomeOrg is the organisation whose WAKIL_ORG is pinned inside
	// ConfigDir. It differs from Org exactly when this binding is a
	// shared one, and that difference is the genuinely surprising thing
	// about a shared account: a plain `claude` session started in that
	// directory runs as HomeOrg.
	HomeOrg string `json:"homeOrg,omitempty"`
	// Mine is whether this row belongs to the organisation the operator
	// is standing in. A row that is not is drawn READ-ONLY and offers
	// Adopt (#201) — this pane never writes across the boundary that
	// defines an organisation.
	Mine bool `json:"mine"`

	// Credential is the minted token's reference and whether it is
	// present, never its value. `Credential.Modified` is where the
	// 365-day clock starts.
	Credential CredentialPresence `json:"credential"`
	// Liveness describes the SIGN-IN and not the token. The surface must
	// label it so, or a red row reads as a broken session when it is not
	// one: a directory whose sign-in has lapsed still launches sessions,
	// because the minted token is what launches them.
	Liveness SignInLiveness `json:"liveness"`

	// credentialReadable records that the Keychain ANSWERED — that
	// `Present: false` means "there is no such item" rather than "the
	// lookup failed".
	//
	// **Unexported, so it never reaches the wire, and that is deliberate.**
	// A consumer should ask `CredentialLess()`, which is the question the
	// pane actually has, rather than reassemble it from two fields and
	// get the "could not look" case wrong — which is precisely the
	// mistake `OrgPlane`'s session-based warning made in the other
	// direction.
	credentialReadable bool

	// Binary is the agent executable this account's liveness is read
	// with, RESOLVED from the full provider record while it is still in
	// hand.
	//
	// **It is held here because the row cannot rebuild it.** `Account`
	// carries neither `ClaudePath` nor `Shared`, so a `Provider`
	// reconstructed from a row resolves to "" every time and every
	// liveness read silently falls back to bare `claude` — an account
	// pointed at a different CLI would be read with the wrong one, and
	// the comment claiming otherwise would be the only trace.
	//
	// **It travels on the wire (#238), because the surface has the same
	// problem the liveness read had.** A re-authentication spawns that
	// executable, and Swift has no other way to name it: nothing in the
	// app resolves an agent binary, and a GUI launched from Finder gets
	// launchd's minimal PATH, in which the recorded path — here
	// `~/.local/bin/claude` — does not appear. It is a path and not a
	// secret; `claudePath` is already readable in every record on disk.
	Binary string `json:"binary,omitempty"`
}

// CredentialLess reports the condition the pane exists to NAME: a binding
// whose organisation has no stored credential for it.
//
// **From a CHECK, not from session history.** `OrgPlane`'s warning fired
// on "an adoption happened this session", so it was right about this
// machine by luck and silent on relaunch. This asks the Keychain.
//
// A row whose presence could not be read at all is deliberately NOT
// credential-less: "could not look" and "is missing" are different facts,
// and reporting the first as the second would send an operator to repair
// an account that is fine.
func (a Account) CredentialLess() bool {
	return !a.Credential.Present && a.Credential.Ref != "" && a.credentialReadable
}

// AccountListing is the whole table, plus what could not be read.
//
// Partiality travels with the data, the house rule: an organisation whose
// providers could not be listed is NAMED rather than dropped, so an empty
// table with a non-empty Skipped means "could not look" and never "there
// are none".
type AccountListing struct {
	// Accounts is never nil, so a machine with none marshals to [].
	Accounts []Account `json:"accounts"`
	// Skipped names organisations whose provider records could not be
	// read.
	Skipped []string `json:"skipped,omitempty"`
	// KeychainUnavailable is set when the Keychain tool could not be run
	// at all. Every row's credential then reports absent, which would
	// otherwise read as "every account on this machine is broken" — the
	// single most alarming and least true thing this pane could say.
	KeychainUnavailable bool `json:"keychainUnavailable,omitempty"`
}

// ListAccounts enumerates every account on this machine, with each one's
// credential presence and sign-in liveness, from the point of view of the
// organisation the operator is standing in.
//
// Reading across organisations is established practice rather than a new
// power: `AddProvider` has always scanned every org to enforce the
// config-dir rules. What is new is that each row carries a credential
// CHECK — which is what lets the pane name the three credential-less
// bindings on this machine by looking rather than by a window failing to
// start.
func ListAccounts() (AccountListing, error) {
	current, err := CurrentOrg()
	if err != nil {
		// Not fatal: the pane is reachable with no organisation chosen,
		// and a table of everything on the machine is exactly what an
		// operator in that state needs. `Mine` is then false for every
		// row, which is true.
		current = ""
	}
	return listAccountsFor(current)
}

func listAccountsFor(current string) (AccountListing, error) {
	orgs, err := ListOrgs()
	if err != nil {
		return AccountListing{Accounts: []Account{}}, err
	}

	out := AccountListing{Accounts: []Account{}, KeychainUnavailable: !keychainToolOnPath()}
	for _, org := range orgs {
		providers, skipped, err := listProvidersFor(org)
		if err != nil {
			out.Skipped = append(out.Skipped, org)
			continue
		}
		for _, name := range skipped {
			out.Skipped = append(out.Skipped, org+"/"+name)
		}
		for _, p := range providers {
			// A local model is an endpoint the operator runs, with no sign-in and no
			// credential (3b-viii): Settings draws it under LOCAL MODELS, not as an account.
			if p.Kind == ProviderKindLocal {
				continue
			}
			out.Accounts = append(out.Accounts, accountRow(org, current, p, out.KeychainUnavailable))
		}
	}

	sort.Slice(out.Accounts, func(i, j int) bool {
		// The operator's own organisation first, then by org and id, so
		// the rows they can act on are at the top and the order is stable
		// between two reads of an unchanged disk.
		a, b := out.Accounts[i], out.Accounts[j]
		if a.Mine != b.Mine {
			return a.Mine
		}
		if a.Org != b.Org {
			return a.Org < b.Org
		}
		return a.ID < b.ID
	})

	fillLiveness(out.Accounts)
	return out, nil
}

// accountRow builds one row's non-liveness half: the record, the home, and
// the credential CHECK.
func accountRow(org, current string, p Provider, keychainUnavailable bool) Account {
	row := Account{
		Org: org, ID: p.ID, Kind: p.Kind, Label: p.Label,
		ConfigDir: p.ConfigDir, Mine: org == current && current != "",
	}
	if p.ConfigDir != "" {
		if homeOrg, _, err := ConfigDirHome(p.ConfigDir); err == nil {
			row.HomeOrg = homeOrg
		}
	}

	// Resolved here, from the REAL record — a shared binding inherits its
	// binary from the directory's home, which only the full record can
	// answer for.
	if resolved, err := ResolveProviderClaudePath(p); err == nil {
		row.Binary = resolved
	}

	ref := ProviderTokenRef(p.ID)
	row.Credential = CredentialPresence{Ref: ref}
	if keychainUnavailable {
		return row
	}
	// **Per (org, id), which is the whole of Invariant 4's shape here.**
	// The ref carries no org, so the same account reached from two
	// organisations needs the same token stored twice — once per org.
	// Checking under `org` rather than under the current one is what makes
	// a row homed elsewhere report ITS organisation's credential rather
	// than this one's.
	presence, err := SecretPresenceFor(org, ref)
	if err != nil {
		// The Keychain answered something other than "not found".
		// `Present` stays false and `credentialReadable` stays false, so
		// `CredentialLess()` says no: "could not look" is not "is
		// missing".
		row.Credential = CredentialPresence{Ref: ref}
		return row
	}
	row.Credential = presence
	row.credentialReadable = true
	return row
}

// fillLiveness reads every row's sign-in, in parallel.
//
// **Parallel because the pane reads on open and caches nothing.** A
// liveness read spawns the CLI and takes the better part of a second;
// four accounts serially is four seconds of a pane drawing nothing, every
// time it is opened. The Keychain half is ~8.5 ms a lookup and needs no
// such treatment.
//
// Bounded by the number of rows rather than by a worker pool: this is a
// handful of accounts on one operator's machine, not a queue.
func fillLiveness(accounts []Account) {
	var wait sync.WaitGroup
	for i := range accounts {
		if accounts[i].ConfigDir == "" {
			accounts[i].Liveness = SignInLiveness{
				Failure: "this account records no config dir, so its sign-in cannot be read",
			}
			continue
		}
		wait.Add(1)
		go func(i int) {
			defer wait.Done()
			// The binary resolved in `accountRow`, from the full record.
			// Rebuilding a `Provider` from the ROW here would drop
			// `ClaudePath` and `Shared` and resolve to "" every time.
			accounts[i].Liveness = ReadSignInLiveness(
				accounts[i].ConfigDir, accounts[i].Binary)
		}(i)
	}
	wait.Wait()
}
