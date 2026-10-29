package wakilcore

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// GitAccount is one of an organisation's git accounts (3a-iii, Decision 44): at most one per host.
// Method is ssh, token or signin; Provider is github, gitlab, bitbucket or other. KeyPath is the
// private key an ssh account uses; Username is Bitbucket's, which its tokens need beside them.
// APIAccess is an ssh GitHub account's optional API credential: "" (none), "signin" or "token".
// It is kept at the same git-<host>-token ref a token account uses, and git still pushes over ssh.
// The secrets — a token, a key's passphrase — are in the Keychain under git-<host>-token and
// git-<host>-ssh-passphrase, never here.
type GitAccount struct {
	Host      string `json:"host"`
	Provider  string `json:"provider"`
	Method    string `json:"method"`
	User      string `json:"user,omitempty"`
	KeyPath   string `json:"keyPath,omitempty"`
	Username  string `json:"username,omitempty"`
	APIAccess string `json:"apiAccess,omitempty"`
}

func gitTokenRef(host string) string      { return "git-" + host + "-token" }
func gitPassphraseRef(host string) string { return "git-" + host + "-ssh-passphrase" }

// PullStrategyOf is the organisation's pull strategy, rebase when it names none.
func PullStrategyOf(o *Org) string {
	if o == nil || o.PullStrategy == "" {
		return "rebase"
	}
	return o.PullStrategy
}

// AddGitAccount records a for org, replacing the account it already has for a.Host.
func AddGitAccount(org string, a GitAccount) error {
	a.Host = strings.ToLower(strings.TrimSpace(a.Host))
	if a.Host == "" {
		return UserError("a git account needs a host")
	}
	switch a.Method {
	case "ssh", "token", "signin":
	default:
		return UserError("a git account's method is ssh, token or signin")
	}
	switch a.APIAccess {
	case "":
	case "signin", "token":
		if a.Method != "ssh" || a.Provider != "github" {
			return UserError("API access belongs to an ssh GitHub account")
		}
	default:
		return UserError("a git account's API access is signin or token")
	}
	if _, err := OrgDirFor(org); err != nil {
		return err
	}
	o, err := LoadOrgFor(org)
	if err != nil {
		return err
	}
	kept := []GitAccount{}
	for _, have := range o.GitAccounts {
		if have.Host != a.Host {
			kept = append(kept, have)
		}
	}
	o.GitAccounts = append(kept, a)
	return SaveOrg(org, *o)
}

// GitAccountFor is org's account for host, if it has one.
func GitAccountFor(org, host string) (GitAccount, bool) {
	o, err := LoadOrgFor(org)
	if err != nil {
		return GitAccount{}, false
	}
	host = strings.ToLower(host)
	for _, a := range o.GitAccounts {
		if a.Host == host {
			return a, true
		}
	}
	return GitAccount{}, false
}

// RemoveGitAccount forgets org's account for host: both Keychain secrets go, and a key Wakil
// generated (one under the organisation's git/ssh folder) goes to the Trash with its .pub. A key
// the operator picked from ~/.ssh is theirs and is never touched.
func RemoveGitAccount(org, host string) error {
	host = strings.ToLower(host)
	o, err := LoadOrgFor(org)
	if err != nil {
		return err
	}
	var removed *GitAccount
	kept := []GitAccount{}
	for i, a := range o.GitAccounts {
		if a.Host == host {
			removed = &o.GitAccounts[i]
			continue
		}
		kept = append(kept, a)
	}
	if removed == nil {
		return UserError("no git account for " + host + " in " + org)
	}
	for _, ref := range []string{gitTokenRef(host), gitPassphraseRef(host)} {
		if err := SecretDelete(org, ref); err != nil {
			return err
		}
	}
	if removed.KeyPath != "" {
		if dir, err := OrgDirFor(org); err == nil {
			keys := filepath.Join(dir, "git", "ssh") + string(filepath.Separator)
			if strings.HasPrefix(removed.KeyPath, keys) {
				for _, p := range []string{removed.KeyPath, removed.KeyPath + ".pub"} {
					if _, err := os.Stat(p); err == nil {
						if out, err := exec.Command(trashBin, "-s", p).CombinedOutput(); err != nil {
							return UserError("could not move " + p + " to the Trash: " + strings.TrimSpace(string(out)))
						}
					}
				}
			}
		}
	}
	o.GitAccounts = kept
	return SaveOrg(org, *o)
}
