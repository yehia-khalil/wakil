package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
)

// sessionLineageFileName is where a fork's parent is recorded, beside
// org.json, active.json, projects.json and providers/ under one org's
// own directory: ~/.wakil/orgs/<org>/sessions.json.
const sessionLineageFileName = "sessions.json"

// sessionLineagePath resolves org's lineage file through OrgDirFor,
// refusing an org that has not been created — the same route registry.go
// (LoadRegistryFor/SaveRegistry), active.go (activePath) and provider.go
// (providersDirFor, used by AddProvider for both read AND write) already
// take for every other piece of per-org state in this package.
// orgDirCreate is deliberately NOT used here: its own doc comment says it
// is "the ONLY thing that creates" an org directory, precisely so that
// OrgDirFor's refusal reliably means "nobody ran `wakil org create`" — a
// mistyped WAKIL_ORG is caught here instead of silently growing a
// sessions.json under a phantom org, which is the exact failure mode
// OrgDirFor's doc comment (paths.go) describes and was written to
// prevent.
func sessionLineagePath(org string) (string, error) {
	dir, err := OrgDirFor(org)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, sessionLineageFileName), nil
}

// SessionParents maps child session id -> parent session id for the
// active org.
//
// An absent store is an empty map, not an error: an org that has never
// forked a session has a known-empty answer, not an unknown one — the
// same "could not look" vs "looked and found nothing" line
// SessionList.Skipped's doc comment (sessions.go) draws.
//
// A thin wrapper around SessionParentsFor(CurrentOrg()). Callers that
// already hold the org they resolved against — ListSessions, most
// notably, which gets it from Resolve() — should call SessionParentsFor
// directly rather than this, so the org is read from the environment
// exactly once per request. Reading it here AND in the caller risks the
// two disagreeing if WAKIL_ORG changes between the two reads, which is
// exactly the ambient-second-read shape sessionLineagePath's own doc
// comment (via OrgDirFor) is written to avoid.
func SessionParents() (map[string]string, error) {
	org, err := CurrentOrg()
	if err != nil {
		return nil, err
	}
	return SessionParentsFor(org)
}

// SessionParentsFor is SessionParents for a caller-supplied org, rather
// than one read from the environment. See SessionParents' doc comment for
// why this exists separately.
func SessionParentsFor(org string) (map[string]string, error) {
	path, err := sessionLineagePath(org)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, UserError("sessions.json for org " + strconv.Quote(org) + " is unreadable: " + err.Error())
	}
	return out, nil
}

// LineageRootIn resolves a session id to the oldest ancestor reachable
// from it through `parents`, which is the identity one conversation has
// across every resume that forked it.
//
// A resume is a fork, not a continue-in-place: it mints a new id and
// records the old one as parent, so a conversation the operator thinks of
// as one thing is a chain of sessions. The root is what ⌘P already
// collapses that chain to when it draws a single row for it, so it is the
// unit an operator means by "this conversation".
//
// # Why this lives here and not in the window
//
// The Swift side already walks parent links, in sessionItems(from:), to
// do that collapsing — but it walks only the rows in the listing it was
// handed, and ListSessions filters to the active project's roots. A chain
// whose ancestor ran in another project resolves to a different root
// depending on what happens to be listed, which is harmless for a display
// grouping and fatal for a storage key: an arrangement filed under one
// root and looked up under another is an arrangement silently lost. This
// map is the whole org's, unfiltered, so the answer does not move.
//
// # Termination
//
// The write path does not reject a self-parent or a cycle — RecordSessionParent
// takes two ids and stores them — so a hand-edited or malformed
// sessions.json can contain A -> A, or A -> B -> A. Neither is
// hypothetical enough to leave unguarded: this walk visits each id at
// most once and returns the last id it reached rather than looping. An id
// absent from the map is its own root, which is also the honest answer
// for a session that was started fresh.
func LineageRootIn(parents map[string]string, id string) string {
	if id == "" {
		return ""
	}
	seen := map[string]bool{id: true}
	root := id
	for {
		parent, ok := parents[root]
		if !ok || parent == "" || seen[parent] {
			return root
		}
		seen[parent] = true
		root = parent
	}
}

// SessionLineageRoot is LineageRootIn against an org's recorded lineage.
//
// Takes the org rather than reading it, for the reason SessionParentsFor
// exists separately from SessionParents: a caller that already resolved
// the org must not cause a second ambient read that could disagree with
// its first.
func SessionLineageRoot(org, id string) (string, error) {
	parents, err := SessionParentsFor(org)
	if err != nil {
		return "", err
	}
	return LineageRootIn(parents, id), nil
}

// SessionParent returns the session `child` was forked from, or "" when
// it was started fresh, or when its lineage was never recorded.
func SessionParent(child string) (string, error) {
	all, err := SessionParents()
	if err != nil {
		return "", err
	}
	return all[child], nil
}

// RecordSessionParent records that `child` was forked from `parent`.
//
// The CLI records no such link: session-resume-probe.md §2 looked for
// forkedFrom, parentSessionId and sourceSessionId on a forked transcript
// and found none — a fork is a full copy of the parent's history with
// nothing in it naming its origin. Wakil mints the child id when it
// starts a resumed session, so this store is the only place the
// relationship can live. Without it, ⌘P grows a near-identical entry per
// resume with nothing to show they are one conversation.
//
// Per-org, beside the org's other state (org.json, active.json,
// projects.json, providers/): Invariant 4 makes the org directory a
// boundary that cross-org bleed must be structurally unable to cross,
// and a session belongs to a provider which belongs to an org.
//
// This read-modify-write is NOT serialised against a concurrent call:
// two resume-forks landing in the same window can both read the same
// starting map, and the second write wins, silently dropping the
// first's entry. writeFileAtomic does not prevent this — it guarantees
// no torn or partially-written file, never a serialised update, and its
// own doc comment makes no wider claim. The loss is bounded, not silent
// corruption: every reader of this store already treats a lookup
// failure as "no parent" (see ReadSession and ListSessions), so a
// dropped entry just makes that one fork look started-fresh — no seam
// label on its rebuilt thread, no grouping in the command palette, and
// nothing else. Every other per-org writer in this package has this
// same shape with more at stake (WriteActive races on the active
// project, SaveRegistry on the project registry), so a fix belongs to
// all of them at once, not to this file alone.
func RecordSessionParent(child, parent string) error {
	if child == "" || parent == "" {
		return UserError("both child and parent session ids are required")
	}
	org, err := CurrentOrg()
	if err != nil {
		return err
	}
	path, err := sessionLineagePath(org)
	if err != nil {
		return err
	}
	all, err := SessionParents()
	if err != nil {
		return err
	}
	all[child] = parent
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	// writeFileAtomic (paths.go): the same atomic-replace-via-rename every
	// other per-org JSON file in this package uses, and at the same
	// permissions (0o644) — see its doc comment for why a per-call temp
	// name rather than a fixed one is what keeps two concurrent writers
	// from tearing each other's file. It does not serialise the
	// read-modify-write above; see this function's doc comment for that.
	return writeFileAtomic(path, b)
}
