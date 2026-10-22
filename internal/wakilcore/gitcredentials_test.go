package wakilcore

import (
	"strings"
	"testing"
)

func joined(inv GitInvocation) string {
	return strings.Join(inv.Args, " ") + " | " + strings.Join(inv.Env, " ")
}

func TestSSHInvocationUsesOnlyTheOrganisationsKey(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	a := GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/keys/org_ed25519"}
	remote := RemoteURL{Scheme: "ssh", User: "git", Host: "github-umbrella", Path: "o/r.git"}
	route := SSHRoute{HostName: "github.com", Port: "22", User: "git"}
	inv := RemoteInvocation("initech", a, remote, route, "/bin/wakil", "/kh")
	s := joined(inv)
	for _, want := range []string{
		"GIT_SSH_COMMAND=ssh -F /dev/null -i /keys/org_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none",
		"-o UserKnownHostsFile=/kh", "-o StrictHostKeyChecking=accept-new", "-o HostName=github.com", "-o Port=22",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in %s", want, s)
		}
	}
	if strings.Contains(s, ".ssh/") {
		t.Errorf("a ~/.ssh path reached the command: %s", s)
	}
	if strings.Contains(s, "SSH_ASKPASS") {
		t.Errorf("askpass without a kept passphrase: %s", s)
	}
}

func TestSSHInvocationRewritesHTTPS(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	a := GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k"}
	inv := RemoteInvocation("initech", a, RemoteURL{Scheme: "https", Host: "github.com", Path: "o/r"}, SSHRoute{HostName: "github.com"}, "/bin/wakil", "/kh")
	if !strings.Contains(joined(inv), "-c url.git@github.com:.insteadOf=https://github.com/") {
		t.Fatalf("no rewrite: %s", joined(inv))
	}
}

func TestTokenInvocationResetsHelpersAndRewritesSSH(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	a := GitAccount{Host: "bitbucket.org", Provider: "bitbucket", Method: "token", Username: "dev_initech"}
	inv := RemoteInvocation("initech", a, RemoteURL{Scheme: "ssh", User: "git", Host: "bitbucket.org", Path: "o/r.git"}, SSHRoute{HostName: "bitbucket.org"}, "/bin/wakil", "/kh")
	s := joined(inv)
	for _, want := range []string{
		"-c credential.helper= -c credential.helper=!/bin/wakil --org initech git-credential --host bitbucket.org",
		"-c credential.interactive=false",
		"-c url.https://bitbucket.org/.insteadOf=git@bitbucket.org:",
		"-c url.https://bitbucket.org/.insteadOf=ssh://git@bitbucket.org/",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in %s", want, s)
		}
	}
	if strings.Contains(s, "GIT_SSH_COMMAND") {
		t.Errorf("ssh command on a token account: %s", s)
	}
}

func TestAskpassOnlyWhenAPassphraseIsKept(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	SecretSetFor("initech", "git-github.com-ssh-passphrase", "pp")
	a := GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k"}
	inv := RemoteInvocation("initech", a, RemoteURL{Scheme: "ssh", Host: "github.com"}, SSHRoute{HostName: "github.com"}, "/bin/wakil", "/kh")
	s := joined(inv)
	if !strings.Contains(s, "SSH_ASKPASS=/bin/wakil --org initech git-askpass --host github.com") || !strings.Contains(s, "SSH_ASKPASS_REQUIRE=force") {
		t.Fatalf("no askpass: %s", s)
	}
}

func TestGitCredentialUsernamePerProvider(t *testing.T) {
	for _, c := range []struct {
		a    GitAccount
		want string
	}{
		{GitAccount{Provider: "github"}, "x-access-token"},
		{GitAccount{Provider: "gitlab"}, "oauth2"},
		{GitAccount{Provider: "bitbucket", Username: "dev_initech"}, "dev_initech"},
		{GitAccount{Provider: "bitbucket"}, "x-bitbucket-api-token-auth"},
		{GitAccount{Provider: "other", Username: "me"}, "me"},
	} {
		if got := GitCredentialUsername(c.a); got != c.want {
			t.Errorf("%+v = %q, want %q", c.a, got, c.want)
		}
	}
}
