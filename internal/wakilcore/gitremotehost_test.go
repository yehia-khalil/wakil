package wakilcore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRemoteURL(t *testing.T) {
	for _, c := range []struct {
		raw                         string
		scheme, user, host, port, p string
	}{
		{"git@github.com:o/r.git", "ssh", "git", "github.com", "", "o/r.git"},
		{"git@github-umbrella:umbrella-corp/api.git", "ssh", "git", "github-umbrella", "", "umbrella-corp/api.git"},
		{"ssh://git@git.example.com:2222/o/r", "ssh", "git", "git.example.com", "2222", "o/r"},
		{"https://github.com/o/r", "https", "", "github.com", "", "o/r"},
		{"https://tok@github.com/o/r.git", "https", "tok", "github.com", "", "o/r.git"},
		{"file:///tmp/r", "file", "", "", "", "/tmp/r"},
	} {
		u, err := ParseRemoteURL(c.raw)
		if err != nil {
			t.Fatalf("%s: %v", c.raw, err)
		}
		if u.Scheme != c.scheme || u.User != c.user || u.Host != c.host || u.Port != c.port || u.Path != c.p {
			t.Errorf("%s = %+v", c.raw, u)
		}
	}
	for raw, scheme := range map[string]string{"ext::sh -c x": "ext", "git://h/r": "git", "http://h/r": "http"} {
		if _, err := ParseRemoteURL(raw); err == nil || !strings.Contains(err.Error(), "protocol not allowed: "+scheme) {
			t.Errorf("%s: %v", raw, err)
		}
	}
}

func TestResolveSSHRouteReadsOnlyTheRoute(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	os.WriteFile(filepath.Join(home, ".ssh", "config"), []byte(
		"Host github-umbrella\n  HostName github.com\n  User git\n  Port 22\n  IdentityFile ~/.ssh/umbrella\n  IdentitiesOnly yes\n"), 0o600)
	r, err := ResolveSSHRoute("github-umbrella")
	if err != nil {
		t.Fatal(err)
	}
	if r.HostName != "github.com" || r.Port != "22" || r.User != "git" {
		t.Fatalf("route = %+v", r)
	}
	if strings.Contains(r.HostName+r.Port+r.User+r.ProxyJump+r.HostKeyAlias, "umbrella") && r.HostName != "github.com" {
		t.Fatalf("an identity leaked into the route: %+v", r)
	}
	plain, err := ResolveSSHRoute("bitbucket.org")
	if err != nil || plain.HostName != "bitbucket.org" {
		t.Fatalf("plain = %+v %v", plain, err)
	}
}

func TestGitHostSuggestionsCountRepositoriesPerHost(t *testing.T) {
	localOrg(t)
	t.Setenv("WAKIL_ORG", "initech")
	home := os.Getenv("HOME")
	os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	os.WriteFile(filepath.Join(home, ".ssh", "config"), []byte("Host github-umbrella\n  HostName github.com\n"), 0o600)
	for name, remote := range map[string]string{
		"a": "git@github-umbrella:o/a.git", "b": "https://github.com/o/b", "c": "git@bitbucket.org:o/c.git",
	} {
		dir := filepath.Join(t.TempDir(), name)
		os.MkdirAll(dir, 0o755)
		gitInit(t, dir)
		gitIn(t, dir, "remote", "add", "origin", remote)
		if _, _, err := CreateProject(dir, name); err != nil {
			t.Fatal(err)
		}
	}
	got := GitHostSuggestions("initech")
	want := []GitHostSuggestion{{Host: "github.com", Repositories: 2}, {Host: "bitbucket.org", Repositories: 1}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("suggestions = %+v", got)
	}
}
