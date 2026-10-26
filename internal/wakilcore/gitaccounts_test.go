package wakilcore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAddGitAccountReplacesTheSameHost(t *testing.T) {
	localOrg(t)
	if err := AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token", User: "a"}); err != nil {
		t.Fatal(err)
	}
	if err := AddGitAccount("initech", GitAccount{Host: "bitbucket.org", Provider: "bitbucket", Method: "token", User: "b", Username: "bu"}); err != nil {
		t.Fatal(err)
	}
	if err := AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", User: "c", KeyPath: "/k"}); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOrgFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(o.GitAccounts) != 2 {
		t.Fatalf("accounts = %+v", o.GitAccounts)
	}
	a, ok := GitAccountFor("initech", "github.com")
	if !ok || a.Method != "ssh" || a.User != "c" {
		t.Fatalf("github.com = %+v %v", a, ok)
	}
	if _, ok := GitAccountFor("initech", "gitlab.com"); ok {
		t.Fatal("gitlab.com has no account")
	}
}

func TestAddGitAccountRefusesAnUnknownMethodOrNoHost(t *testing.T) {
	localOrg(t)
	if err := AddGitAccount("initech", GitAccount{Host: "github.com", Method: "password"}); err == nil {
		t.Fatal("method password accepted")
	}
	if err := AddGitAccount("initech", GitAccount{Method: "ssh"}); err == nil {
		t.Fatal("empty host accepted")
	}
}

func TestRemoveGitAccountDeletesItsSecretsAndTrashesAGeneratedKey(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	args := fakeTrash(t)
	dir, err := OrgDirFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(dir, "git", "ssh", "github.com_ed25519")
	os.MkdirAll(filepath.Dir(key), 0o700)
	os.WriteFile(key, []byte("k"), 0o600)
	os.WriteFile(key+".pub", []byte("p"), 0o644)
	SecretSetFor("initech", "git-github.com-ssh-passphrase", "pp")
	SecretSetFor("initech", "git-github.com-token", "tt")
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: key})
	if err := RemoveGitAccount("initech", "github.com"); err != nil {
		t.Fatal(err)
	}
	if _, ok := GitAccountFor("initech", "github.com"); ok {
		t.Fatal("account still there")
	}
	for _, ref := range []string{"git-github.com-ssh-passphrase", "git-github.com-token"} {
		if v, _ := SecretGetFor("initech", ref); v != "" {
			t.Errorf("%s still in the Keychain", ref)
		}
	}
	recorded, _ := os.ReadFile(args)
	if !strings.Contains(string(recorded), "github.com_ed25519") {
		t.Errorf("generated key not trashed: %q", recorded)
	}
}

func TestRemoveGitAccountLeavesAKeyOutsideTheOrgsFolder(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	args := fakeTrash(t)
	outside := filepath.Join(t.TempDir(), "id_ed25519")
	os.WriteFile(outside, []byte("k"), 0o600)
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: outside})
	if err := RemoveGitAccount("initech", "github.com"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("the operator's own key was touched")
	}
	if recorded, _ := os.ReadFile(args); len(recorded) != 0 {
		t.Fatalf("trash ran: %q", recorded)
	}
}

func TestPullStrategyDefaultsToRebaseAndRefusesOtherValues(t *testing.T) {
	localOrg(t)
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if tree.Org.PullStrategy != "rebase" {
		t.Fatalf("default = %q", tree.Org.PullStrategy)
	}
	for _, v := range []string{"merge", "ff-only", "rebase"} {
		v := v
		if err := UpdateOrg("initech", OrgPatch{PullStrategy: &v}); err != nil {
			t.Fatalf("%s: %v", v, err)
		}
	}
	bad := "squash"
	err = UpdateOrg("initech", OrgPatch{PullStrategy: &bad})
	if err == nil || !strings.Contains(err.Error(), "pullStrategy is rebase, merge or ff-only") {
		t.Fatalf("squash: %v", err)
	}
}

func TestConfigTreeListsAccountsWithoutSecrets(t *testing.T) {
	localOrg(t)
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token", User: "dev-initech"})
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(tree.Org.GitAccounts) != 1 || tree.Org.GitAccounts[0].User != "dev-initech" {
		t.Fatalf("accounts = %+v", tree.Org.GitAccounts)
	}
}

func sshKeyAccount(t *testing.T) {
	t.Helper()
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k/id", User: "dev-initech"})
}

func TestAPIAccessTokenKeepsSSHMethod(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	sshKeyAccount(t)
	before, _, _, err := credentials("initech", "git@github.com:initech/api.git", GitRemoteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if err := SetGitAPIAccessToken("initech", "github.com", " tok-1 "); err != nil {
		t.Fatal(err)
	}
	a, _ := GitAccountFor("initech", "github.com")
	if a.Method != "ssh" || a.APIAccess != "token" || a.KeyPath != "/k/id" {
		t.Fatalf("account = %+v", a)
	}
	if v, _ := SecretGetFor("initech", "git-github.com-token"); v != "tok-1" {
		t.Fatalf("token = %q", v)
	}
	after, _, _, err := credentials("initech", "git@github.com:initech/api.git", GitRemoteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(before.Env, "\n") != strings.Join(after.Env, "\n") || strings.Join(before.Args, "\n") != strings.Join(after.Args, "\n") {
		t.Fatalf("the ssh invocation changed:\n%+v\n%+v", before, after)
	}
	if err := FinishAPIAccessSignIn("initech", "github.com", "tok-2"); err != nil {
		t.Fatal(err)
	}
	a, _ = GitAccountFor("initech", "github.com")
	if a.Method != "ssh" || a.APIAccess != "signin" {
		t.Fatalf("account = %+v", a)
	}
}

func TestAPIAccessRefusedOnNonSSHOrNonGitHub(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	for name, a := range map[string]GitAccount{
		"token account": {Host: "github.com", Provider: "github", Method: "token"},
		"gitlab ssh":    {Host: "gitlab.com", Provider: "gitlab", Method: "ssh", KeyPath: "/k/id"},
	} {
		AddGitAccount("initech", a)
		for _, err := range []error{
			SetGitAPIAccessToken("initech", a.Host, "t"),
			FinishAPIAccessSignIn("initech", a.Host, "t"),
		} {
			if _, ok := IsUserError(err); !ok {
				t.Errorf("%s: err = %v, want a UserError", name, err)
			}
		}
		if v, _ := SecretGetFor("initech", gitTokenRef(a.Host)); v != "" {
			t.Errorf("%s: a token was kept", name)
		}
	}
	if err := SetGitAPIAccessToken("initech", "nowhere.test", "t"); err == nil {
		t.Error("no account: want an error")
	}
}

func TestGitHubTokenForEachMethod(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	sshCopy := "Pull requests not read: this organization's github.com account signs in with SSH, which reads no pull requests. Add API access to the GitHub account in Settings → Organisation → Git."

	if _, err := GitHubTokenFor("initech", "github.com"); err == nil || err.Error() != "Pull requests not read: this organization has no git account for github.com. Add one in Settings → Organisation → Git." {
		t.Fatalf("no account: %v", err)
	}
	for _, method := range []string{"signin", "token"} {
		AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: method})
		SetGitToken("initech", "github.com", "tok-"+method)
		if got, err := GitHubTokenFor("initech", "github.com"); err != nil || got != "tok-"+method {
			t.Errorf("%s: %q %v", method, got, err)
		}
	}
	SecretDelete("initech", "git-github.com-token")
	if _, err := GitHubTokenFor("initech", "github.com"); err == nil || err.Error() != "no token kept for github.com" {
		t.Errorf("missing token: %v", err)
	}

	sshKeyAccount(t)
	if _, err := GitHubTokenFor("initech", "github.com"); err == nil || err.Error() != sshCopy {
		t.Errorf("ssh without API access: %v", err)
	}
	if err := SetGitAPIAccessToken("initech", "github.com", "tok-ssh"); err != nil {
		t.Fatal(err)
	}
	if got, err := GitHubTokenFor("initech", "github.com"); err != nil || got != "tok-ssh" {
		t.Errorf("ssh with API access: %q %v", got, err)
	}

	AddGitAccount("initech", GitAccount{Host: "gitlab.com", Provider: "gitlab", Method: "token"})
	if _, err := GitHubTokenFor("initech", "gitlab.com"); err == nil || err.Error() != "Pull requests are read from GitHub only." {
		t.Errorf("gitlab: %v", err)
	}
}

func TestRemoveGitAPIAccessKeepsTheAccount(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	sshKeyAccount(t)
	SetGitAPIAccessToken("initech", "github.com", "tok-1")
	if err := RemoveGitAPIAccess("initech", "github.com"); err != nil {
		t.Fatal(err)
	}
	a, ok := GitAccountFor("initech", "github.com")
	if !ok || a.Method != "ssh" || a.APIAccess != "" || a.KeyPath != "/k/id" {
		t.Fatalf("account = %+v %v", a, ok)
	}
	if v, _ := SecretGetFor("initech", "git-github.com-token"); v != "" {
		t.Fatal("the token is still in the Keychain")
	}
	if err := RemoveGitAPIAccess("initech", "nowhere.test"); err == nil {
		t.Fatal("no account: want an error")
	}
}

func TestRemoveGitAccountAlsoDropsAPIAccessToken(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	fakeTrash(t)
	sshKeyAccount(t)
	SetGitAPIAccessToken("initech", "github.com", "tok-1")
	if err := RemoveGitAccount("initech", "github.com"); err != nil {
		t.Fatal(err)
	}
	if v, _ := SecretGetFor("initech", "git-github.com-token"); v != "" {
		t.Fatal("the API access token outlived its account")
	}
}

func TestConfigTreeCarriesAPIAccessNotToken(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	sshKeyAccount(t)
	SetGitAPIAccessToken("initech", "github.com", "ghp-s3cret")
	tree, err := LoadConfigTreeFor("initech")
	if err != nil {
		t.Fatal(err)
	}
	if len(tree.Org.GitAccounts) != 1 || tree.Org.GitAccounts[0].APIAccess != "token" {
		t.Fatalf("accounts = %+v", tree.Org.GitAccounts)
	}
	raw, _ := json.Marshal(tree)
	if !strings.Contains(string(raw), `"apiAccess":"token"`) || strings.Contains(string(raw), "ghp-s3cret") {
		t.Fatalf("tree = %s", raw)
	}
}
