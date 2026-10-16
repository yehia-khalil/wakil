package wakilcore

import (
	"os"
	"path/filepath"
)

// DeriveConfigDir returns the config directory an account with this id
// uses: `~/.claude-<id>`, resolved.
//
// **The operator never types or sees a path.** One directory per provider
// id, a pure function of the id — which is also what makes re-entry cost
// one trip rather than two: the next add of the same id computes the same
// directory and finds the sign-in still there (#205).
//
// **One string.** Whatever Wakil puts in `CLAUDE_CONFIG_DIR` is the string
// it must hash to name the Keychain item. The CLI **does not resolve
// symlinks** — it hashes the literal string it is handed and looks that
// name up (`phase-2e-probe.md` §2.2; the earlier `realpath` ruling in
// `provider-login-probe.md` §9.1 is withdrawn, its `realpath` having been
// Orca's). But *stop resolving* is the wrong correction, because
// `findConfigDirOwner` genuinely needs the resolved value to refuse a
// second provider claiming one directory. So the rule is: **resolve once,
// here, and use that one value for the spawn, the record and the hash.**
//
// **This phase is where it can break, and the failure is silent in the
// worst way.** Today's launch path satisfies the rule by accident — it
// passes a stored, therefore already-resolved, path. Here the pane spawns
// a login BEFORE any record exists, so a spawn handed the unresolved
// derivation plus an `AddProvider` storing the resolved one gives Go a
// Keychain name the login never wrote to: a fresh, correct sign-in that
// reads as logged out. The trigger is narrow — a symlinked component, a
// symlinked home among them.
//
// **The WHOLE path is resolved when it exists, and only the parent when
// it does not.** `filepath.EvalSymlinks` fails on a path that is not
// there, and the point of this function is to name a directory that
// usually does not exist yet — so the parent is the fallback, not the
// rule.
//
// **Resolving only the parent is not enough, and that was measured.**
// `AddProvider` stores `EvalSymlinks(abs)` — the whole path. With
// `~/.claude-acme` itself a symlink, a parent-only derivation hands the
// spawn `<home>/.claude-acme` while the record keeps the link's target,
// so the login writes one Keychain name and Go looks up another. Probed
// on this machine, 2026-09-22:
//
//	derived (what the spawn gets):     …/leafprobe…/.claude-acme
//	stored  (what AddProvider keeps):  …/realdir…
//
// That is precisely the failure the spec names — a fresh, correct sign-in
// that reads as logged out — reached through the leaf rather than through
// the home.
//
// **Wakil creating the directory is belt-and-braces**, not a requirement:
// the CLI `mkdir`s it recursively itself, and the first liveness read of a
// derived-but-unused directory creates its scaffolding before answering
// (`phase-2e-probe.md` §5).
func DeriveConfigDir(id string) (string, error) {
	if err := validateProviderToken(id); err != nil {
		return "", err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", UserError("could not determine the home directory: " + err.Error())
	}
	// Resolved once, here. A failure to resolve is not fatal — a home
	// directory that cannot be resolved is still a home directory, and
	// refusing to derive a path because of it would make the pane
	// unusable on a machine where the unresolved name works perfectly
	// well.
	if resolved, err := filepath.EvalSymlinks(home); err == nil {
		home = resolved
	}
	candidate := filepath.Join(home, ".claude-"+id)

	// The whole path, when there is one to resolve. This is what makes
	// the derivation agree with what `AddProvider` will store — see the
	// measurement above.
	if resolved, err := filepath.EvalSymlinks(candidate); err == nil {
		return resolved, nil
	}
	return candidate, nil
}

// EnsureConfigDir derives the directory for id and creates it if it is not
// there.
//
// Belt-and-braces, as above. It returns the SAME string `DeriveConfigDir`
// returns whether or not it had to create anything — creating a directory
// must not change the string that names it, or the one-string rule is
// broken by the very call that prepares the ground for it.
func EnsureConfigDir(id string) (string, error) {
	dir, err := DeriveConfigDir(id)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", UserError("could not create the config dir " + dir + ": " + err.Error())
	}
	return dir, nil
}
