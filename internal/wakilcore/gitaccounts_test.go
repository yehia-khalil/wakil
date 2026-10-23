package wakilcore

import (
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
