package wakilcore

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestListSSHKeysMarksEncryptedOnes(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ssh := filepath.Join(home, ".ssh")
	os.MkdirAll(ssh, 0o700)
	for name, pass := range map[string]string{"plain": "", "locked": "hunter22"} {
		out, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", pass, "-C", name+"@example.invalid", "-f", filepath.Join(ssh, name)).CombinedOutput()
		if err != nil {
			t.Fatalf("%v %s", err, out)
		}
	}
	keys := ListSSHKeys()
	if len(keys) != 2 {
		t.Fatalf("keys = %+v", keys)
	}
	for _, k := range keys {
		want := strings.HasSuffix(k.Path, "locked")
		if k.Encrypted != want || !strings.Contains(k.Comment, "@example.invalid") || k.Type != "ssh-ed25519" {
			t.Errorf("%+v", k)
		}
	}
}

func TestGenerateGitKeyStoresThePassphraseAndAnEncryptedKey(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	pub, path, err := GenerateGitKey("initech", "github.com", "dev-initech (Wakil · initech)")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(pub, "ssh-ed25519 ") || !strings.HasSuffix(strings.TrimSpace(pub), "dev-initech (Wakil · initech)") {
		t.Fatalf("pub = %q", pub)
	}
	dir, _ := OrgDirFor("initech")
	if path != filepath.Join(dir, "git", "ssh", "github.com_ed25519") {
		t.Fatalf("path = %s", path)
	}
	pass, _ := SecretGetFor("initech", "git-github.com-ssh-passphrase")
	if len(pass) < 32 {
		t.Fatalf("passphrase %q", pass)
	}
	if err := exec.Command("ssh-keygen", "-y", "-P", "", "-f", path).Run(); err == nil {
		t.Fatal("the generated key opens without its passphrase")
	}
	if err := exec.Command("ssh-keygen", "-y", "-P", pass, "-f", path).Run(); err != nil {
		t.Fatal("the kept passphrase does not open the key")
	}
}

func TestParseSSHGreeting(t *testing.T) {
	for text, want := range map[string]string{
		"Hi dev-umbrella! You've successfully authenticated, but GitHub does not provide shell access.": "dev-umbrella",
		"Welcome to GitLab, @dev-initech!": "dev-initech",
		"authenticated via ssh key.\n\nYou can use git to connect to Bitbucket. Shell access is disabled": "",
		"logged in as dev_initech.\n\nYou can use git or hg to connect to Bitbucket.":                     "dev_initech",
	} {
		got, ok := parseSSHGreeting(text)
		if !ok || got != want {
			t.Errorf("%q = %q %v, want %q", text, got, ok, want)
		}
	}
	if _, ok := parseSSHGreeting("git@github.com: Permission denied (publickey)."); ok {
		t.Fatal("a refusal read as a greeting")
	}
}

func TestTokenTestAsksTheProvidersAPI(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok-9" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"login":"dev-initech"}`))
	}))
	defer srv.Close()
	old := gitUserAPI["github"]
	gitUserAPI["github"] = srv.URL
	defer func() { gitUserAPI["github"] = old }()
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	SetGitToken("initech", "github.com", "tok-9")
	user, err := TestGitAccount(context.Background(), "initech", "github.com")
	if err != nil || user != "dev-initech" {
		t.Fatalf("user %q err %v", user, err)
	}
	SetGitToken("initech", "github.com", "wrong")
	if _, err := TestGitAccount(context.Background(), "initech", "github.com"); err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("err = %v", err)
	}
}

func TestSSHCommandQuotesAKeyPathWithSpaces(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	a := GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/My Keys/org key"}
	inv := RemoteInvocation("initech", a, RemoteURL{Scheme: "ssh", Host: "github.com"}, SSHRoute{HostName: "github.com"}, "/bin/wakil", "/kh")
	if !strings.Contains(strings.Join(inv.Env, " "), "-i '/My Keys/org key'") {
		t.Fatalf("not quoted: %v", inv.Env)
	}
}

// Walk 3a-iii row 8: a key left behind with no account using it (an earlier Generate whose account
// did not keep its path) goes to the Trash, and Generate makes a new one. A key an account uses
// still refuses.
func TestGenerateGitKeyReplacesAnUnusedKey(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	rec := stubTrashCopying(t, "exit 0")
	first, path, err := GenerateGitKey("initech", "github.com", "c")
	if err != nil {
		t.Fatal(err)
	}
	// The stub copies rather than moves; remove the pair as the real Trash would.
	trashBin = filepath.Join(t.TempDir(), "mv")
	os.WriteFile(trashBin, []byte("#!/bin/sh\nfor a; do last=\"$a\"; done\nmv \"$last\" "+rec+"/\n"), 0o755)
	second, _, err := GenerateGitKey("initech", "github.com", "c")
	if err != nil || second == first {
		t.Fatalf("not replaced: %v", err)
	}
	if _, err := os.Stat(filepath.Join(rec, "github.com_ed25519")); err != nil {
		t.Fatal("the old key did not go to the Trash")
	}
	if err := AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: path}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := GenerateGitKey("initech", "github.com", "c"); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("a key in use was replaced: %v", err)
	}
}

func TestGitAPIAccessTestAsksGitHubWithTheToken(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok-9" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"login":"dev-initech"}`))
	}))
	defer srv.Close()
	old := gitUserAPI["github"]
	gitUserAPI["github"] = srv.URL
	defer func() { gitUserAPI["github"] = old }()
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k/id"})
	if _, err := TestGitAPIAccess(context.Background(), "initech", "github.com"); err == nil {
		t.Fatal("no API access yet: want an error")
	}
	SetGitAPIAccessToken("initech", "github.com", "tok-9")
	user, err := TestGitAPIAccess(context.Background(), "initech", "github.com")
	if err != nil || user != "dev-initech" {
		t.Fatalf("user %q err %v", user, err)
	}
	SetGitAPIAccessToken("initech", "github.com", "wrong")
	if _, err := TestGitAPIAccess(context.Background(), "initech", "github.com"); err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("err = %v", err)
	}
}
