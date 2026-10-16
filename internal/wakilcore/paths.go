package wakilcore

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
)

// WakilDir returns the path to the ~/.wakil directory.
// It errors if $HOME is unset or cannot be determined.
func WakilDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", fmt.Errorf("cannot determine home directory: %w", err)
	}
	return filepath.Join(home, ".wakil"), nil
}

// orgFileTokenPattern is what an org id must match to be usable as a
// directory name under ~/.wakil/orgs and as the org component of a
// Keychain service name. Moved here from active.go: the org id is an
// identity concern, and both users of the pattern now sit downstream of
// this file.
//
// The filename use needs no "/" and no leading dot; the Keychain use
// needs no ":" (see keychainService for why a colon would let two
// distinct org/ref pairs collide on one credential). Requiring a leading
// alphanumeric rejects "/", "..", ".", a bare dash and a bare space.
//
// An invalid org is an ERROR rather than something to sanitise.
// Sanitising would silently map two different orgs onto one directory,
// which is the exact collision the per-org split exists to prevent.
var orgFileTokenPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// CurrentOrg returns the org this process was launched for.
//
// The value comes from WAKIL_ORG and from nothing else. There is
// deliberately NO fallback to CLAUDE_CONFIG_DIR: a fallback resolves
// silently to whatever config dir the process happened to inherit, and
// the failure then surfaces far from its cause as a missing credential.
//
// It must stay a launcher-declared value. A project.json declares which
// org it BELONGS to — that is what Resolve() checks against — but it must
// never be able to SET the ambient org, or the cross-org guard becomes a
// comparison of a value against itself.
func CurrentOrg() (string, error) {
	org := os.Getenv("WAKIL_ORG")
	if org == "" {
		return "", UserError("WAKIL_ORG is not set — every Wakil process runs for exactly one org. " +
			"Registered servers get it from scripts/register-provider.sh; on the CLI pass --org <org>.")
	}
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	return org, nil
}

// validateOrgToken reports whether org can be used as a directory name
// and as the org component of a Keychain service name.
func validateOrgToken(org string) error {
	if orgFileTokenPattern.MatchString(org) {
		return nil
	}
	// Quoted: an org id can contain a space or a newline (both measured as
	// accepted by `security`), and an unquoted one renders as an invisible
	// or line-breaking message that hides the actual problem.
	return UserError("unusable org id " + strconv.Quote(org) +
		" — an org id must start with a letter or digit and contain only letters, digits, dot, dash or underscore")
}

// CurrentOrgChecked is CurrentOrg. It survives as a name because
// cmd/wakil calls it to get the org BEFORE prompting for a secret, and
// that call site reads better spelled "checked". CurrentOrg now validates
// on every call, so there is nothing extra to do here.
func CurrentOrgChecked() (string, error) { return CurrentOrg() }

// OrgsDir is the root under which every org's state lives. It is not
// required to exist; OrgDirFor is what refuses a missing org.
func OrgsDir() (string, error) {
	wakilDir, err := WakilDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(wakilDir, "orgs"), nil
}

// OrgDirFor returns ~/.wakil/orgs/<org>, refusing an org that has not
// been created.
//
// This existence check is load-bearing. Before org ids were free-form, a
// mistyped org was caught by the filesystem: register-provider.sh's
// predecessor, register-org.sh, refused because ~/.claude-umbrela did not
// exist. Nothing else would catch
// WAKIL_ORG=umbrela — it is a legal token — so without this the typo would
// quietly create state under a phantom org and fail much later as a
// missing credential.
func OrgDirFor(org string) (string, error) {
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	root, err := OrgsDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, org)
	fi, err := os.Stat(dir)
	if os.IsNotExist(err) {
		return "", UserError("org " + strconv.Quote(org) + " is not registered — create it with: wakil org create " + org)
	}
	if err != nil {
		return "", err
	}
	if !fi.IsDir() {
		return "", UserError("org " + strconv.Quote(org) + " is not usable: " + dir + " exists but is not a directory")
	}
	return dir, nil
}

// OrgDir returns the current org's directory.
func OrgDir() (string, error) {
	org, err := CurrentOrg()
	if err != nil {
		return "", err
	}
	return OrgDirFor(org)
}

// orgDirCreate makes an org's directory. It is the ONLY thing that
// creates one, so that OrgDirFor's refusal means "nobody ran
// `wakil org create`" and never "some unrelated write happened to
// MkdirAll it into existence".
func orgDirCreate(org string) (string, error) {
	if err := validateOrgToken(org); err != nil {
		return "", err
	}
	root, err := OrgsDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, org)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// writeFileAtomic replaces path's contents atomically: write to a fresh
// temp file in path's directory, then rename over path.
//
// The temp file gets a per-call name from os.CreateTemp rather than a
// fixed "<path>.tmp". The rename is what makes the replacement atomic
// for READERS, but a fixed temp name is not atomic for WRITERS: two
// processes writing the same path share that one temp path too, both
// open it O_TRUNC, and the shorter write can leave the longer one's tail
// behind before its rename publishes the mixture. os.CreateTemp gives
// each writer its own file, so the only shared operation left is the
// rename, which the kernel makes atomic. It is created in path's own
// directory on purpose: a rename across filesystems fails.
func writeFileAtomic(path string, b []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	// Any failure from here on must not leave a stray temp file behind.
	defer func() { _ = os.Remove(tmp) }()
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
