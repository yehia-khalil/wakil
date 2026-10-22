package wakilcore

import "strings"

// GitInvocation is what one remote git command gains to use an organisation's account (3a-iii,
// Decision 44): `-c` pairs before the subcommand, and environment variables. Nothing is written to
// ~/.ssh or to any git config; every value is for this one command.
type GitInvocation struct {
	Args []string
	Env  []string
}

// RemoteInvocation is how git reaches remote with account a. An ssh account runs Wakil's own ssh
// with the organisation's key alone — `-F /dev/null` and IdentityAgent=none, so no key from the
// operator's config or agent can be offered instead — on the route ResolveSSHRoute read, and an
// https remote is rewritten to ssh for the command. A token or sign-in account resets git's
// credential helpers to Wakil's and rewrites an ssh remote to https. wakilBin is the `wakil` binary
// the askpass and the helper call back into; knownHosts is the organisation's own known_hosts.
func RemoteInvocation(org string, a GitAccount, remote RemoteURL, route SSHRoute, wakilBin, knownHosts string) GitInvocation {
	host := a.Host
	var inv GitInvocation
	switch a.Method {
	case "ssh":
		parts := []string{"ssh", "-F", "/dev/null", "-i", a.KeyPath, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
			"-o", "UserKnownHostsFile=" + knownHosts, "-o", "StrictHostKeyChecking=accept-new"}
		for _, o := range [][2]string{{"HostName", route.HostName}, {"Port", route.Port}, {"ProxyJump", route.ProxyJump}, {"HostKeyAlias", route.HostKeyAlias}} {
			if o[1] != "" {
				parts = append(parts, "-o", o[0]+"="+o[1])
			}
		}
		// The URL carries its own user (git@…); the config's is used only when it has none.
		if remote.User == "" && route.User != "" {
			parts = append(parts, "-o", "User="+route.User)
		}
		quoted := make([]string, len(parts))
		for i, p := range parts {
			quoted[i] = shellQuote(p)
		}
		// git runs GIT_SSH_COMMAND through a shell: every part is quoted, so a key path with spaces holds.
		inv.Env = append(inv.Env, "GIT_SSH_COMMAND="+strings.Join(quoted, " "))
		if v, _ := SecretGetFor(org, gitPassphraseRef(host)); v != "" {
			// ssh runs SSH_ASKPASS as one program path with the prompt as its only argument, so the
			// organisation and host ride in the environment (`wakil` reads WAKIL_ASKPASS_HOST).
			inv.Env = append(inv.Env, "SSH_ASKPASS="+wakilBin, "SSH_ASKPASS_REQUIRE=force",
				"WAKIL_ASKPASS_HOST="+host, "WAKIL_ORG="+org)
		}
		if remote.Scheme == "https" {
			inv.Args = append(inv.Args, "-c", "url.git@"+host+":.insteadOf=https://"+host+"/")
		}
	default: // token, signin
		inv.Args = append(inv.Args,
			"-c", "credential.helper=",
			"-c", "credential.helper=!"+wakilBin+" --org "+org+" git-credential --host "+host,
			"-c", "credential.interactive=false")
		if remote.Scheme == "ssh" {
			inv.Args = append(inv.Args,
				"-c", "url.https://"+host+"/.insteadOf=git@"+host+":",
				"-c", "url.https://"+host+"/.insteadOf=ssh://git@"+host+"/")
		}
	}
	return inv
}

// GitCredentialUsername is the username a host expects beside a token: GitHub's and GitLab's fixed
// ones, Bitbucket's own username (or its API-token user when none is recorded), else the recorded one.
func GitCredentialUsername(a GitAccount) string {
	switch a.Provider {
	case "github":
		return "x-access-token"
	case "gitlab":
		return "oauth2"
	case "bitbucket":
		if a.Username != "" {
			return a.Username
		}
		return "x-bitbucket-api-token-auth"
	}
	if a.Username != "" {
		return a.Username
	}
	return "git"
}

// GitTokenRef and GitPassphraseRef name an account's Keychain items (Invariant 4's wakil:<org>:<ref>).
func GitTokenRef(host string) string      { return gitTokenRef(host) }
func GitPassphraseRef(host string) string { return gitPassphraseRef(host) }

// shellQuote leaves a plain word as it is and single-quotes anything else.
func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_./=:@,+", r))
	}) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
