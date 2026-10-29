package wakilcore

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func prBase(t *testing.T, fn func(host string) string) {
	t.Helper()
	old := githubAPIBase
	githubAPIBase = fn
	t.Cleanup(func() { githubAPIBase = old })
}

func TestPullRequestsAbsentWithoutAGitHubAccount(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	AddGitAccount("initech", GitAccount{Host: "gitlab.com", Provider: "gitlab", Method: "token"})
	got, err := GitHubPullRequests(context.Background(), "initech")
	if err != nil || got.Absent != "No pull-request group: initech has no GitHub account." || len(got.PullRequests) != 0 {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestPullRequestsAbsentForAnSSHAccount(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "ssh", KeyPath: "/k"})
	got, err := GitHubPullRequests(context.Background(), "initech")
	want := "No pull-request group: initech's GitHub account on github.com uses an SSH key, which can't read pull requests — add a token or Sign in under Settings → Organisation → Git."
	if err != nil || got.Absent != want {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestPullRequestsAbsentWithNoToken(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	got, err := GitHubPullRequests(context.Background(), "initech")
	if err != nil || got.Absent != "No pull-request group: no token is kept for github.com in initech." {
		t.Fatalf("%+v %v", got, err)
	}
}

// A Keychain that holds the item but will not hand it over (locked, a denied prompt) is an error
// whole, never "no token is kept".
func TestPullRequestsAnUnreadableKeychainIsAnError(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	path := filepath.Join(t.TempDir(), "security")
	script := "#!/bin/sh\necho 'security: SecKeychainSearchCopyNext: User interaction is not allowed.' >&2\nexit 36\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	previous := securityBinary
	securityBinary = keychainTool(path)
	t.Cleanup(func() { securityBinary = previous })
	got, err := GitHubPullRequests(context.Background(), "initech")
	if err == nil || got.Absent != "" || !strings.Contains(err.Error(), "could not read keychain") ||
		!strings.Contains(err.Error(), "User interaction is not allowed") {
		t.Fatalf("%+v %v", got, err)
	}
	if errors.Is(err, ErrSecretNotFound) {
		t.Fatalf("a locked keychain is not a missing item: %v", err)
	}
}

// A host that does not answer within the budget reads "<host> did not answer: …", the spec's copy,
// before the app's own read timeout would.
func TestPullRequestsAHostThatHangsDidNotAnswer(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	defer close(release)
	prBase(t, func(string) string { return srv.URL })
	old := githubPullRequestsBudget
	githubPullRequestsBudget = 50 * time.Millisecond
	t.Cleanup(func() { githubPullRequestsBudget = old })
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	SetGitToken("initech", "github.com", "tok")
	_, err := GitHubPullRequests(context.Background(), "initech")
	if err == nil || !strings.HasPrefix(err.Error(), "github.com did not answer: ") {
		t.Fatalf("err = %v", err)
	}
	if old >= 10*time.Second {
		t.Fatalf("the budget %v must stay under the app's 10 s read timeout", old)
	}
}

func TestPullRequestsSearchesAuthorAndReviewRequested(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	var mu sync.Mutex
	seen := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok-1" || r.Header.Get("Accept") != "application/vnd.github+json" {
			w.WriteHeader(401)
			return
		}
		q := r.URL.Query().Get("q")
		mu.Lock()
		seen = append(seen, q)
		mu.Unlock()
		if r.URL.Query().Get("per_page") != "50" || r.URL.Query().Get("sort") != "updated" {
			t.Errorf("query %v", r.URL.RawQuery)
		}
		if strings.Contains(q, "author:@me") {
			w.Write([]byte(`{"items":[
{"number":1,"title":"Old","html_url":"https://github.com/initech/api/pull/1","repository_url":"https://api.github.com/repos/initech/api","updated_at":"2026-01-01T00:00:00Z"},
{"number":2,"title":"Both","html_url":"https://github.com/initech/web/pull/2","repository_url":"https://api.github.com/repos/initech/web","updated_at":"2026-03-01T00:00:00Z"}]}`))
			return
		}
		w.Write([]byte(`{"items":[
{"number":2,"title":"Both","html_url":"https://github.com/initech/web/pull/2","repository_url":"https://api.github.com/repos/initech/web","updated_at":"2026-03-01T00:00:00Z"},
{"number":3,"title":"Review me","html_url":"https://github.com/initech/api/pull/3","repository_url":"https://api.github.com/repos/initech/api","updated_at":"2026-02-01T00:00:00Z"}]}`))
	}))
	defer srv.Close()
	prBase(t, func(string) string { return srv.URL })
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	SetGitToken("initech", "github.com", "tok-1")
	got, err := GitHubPullRequests(context.Background(), "initech")
	if err != nil || got.Absent != "" || got.Host != "github.com" {
		t.Fatalf("%+v %v", got, err)
	}
	if len(seen) != 2 || !strings.Contains(strings.Join(seen, "|"), "is:pr is:open author:@me") ||
		!strings.Contains(strings.Join(seen, "|"), "is:pr is:open review-requested:@me") {
		t.Fatalf("searches %v", seen)
	}
	want := []MyPullRequest{
		{2, "Both", "https://github.com/initech/web/pull/2", "initech/web", "author"},
		{3, "Review me", "https://github.com/initech/api/pull/3", "initech/api", "review-requested"},
		{1, "Old", "https://github.com/initech/api/pull/1", "initech/api", "author"},
	}
	if len(got.PullRequests) != 3 {
		t.Fatalf("%+v", got.PullRequests)
	}
	for i := range want {
		if got.PullRequests[i] != want[i] {
			t.Errorf("[%d] = %+v, want %+v", i, got.PullRequests[i], want[i])
		}
	}
}

func TestPullRequestsRefusalIsWhole(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		w.Write([]byte(`{"message":"Bad credentials"}`))
	}))
	defer srv.Close()
	prBase(t, func(string) string { return srv.URL })
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	SetGitToken("initech", "github.com", "bad")
	_, err := GitHubPullRequests(context.Background(), "initech")
	if err == nil || err.Error() != "github.com refused the pull-request search (HTTP 401): Bad credentials" {
		t.Fatalf("err = %v", err)
	}
}

func TestPullRequestsPrefersGithubDotCom(t *testing.T) {
	localOrg(t)
	fakeKeychain(t)
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"items":[]}`))
	}))
	defer srv.Close()
	prBase(t, func(host string) string { asked = append(asked, host); return srv.URL })
	AddGitAccount("initech", GitAccount{Host: "ghe.example.com", Provider: "github", Method: "token"})
	AddGitAccount("initech", GitAccount{Host: "github.com", Provider: "github", Method: "token"})
	SetGitToken("initech", "ghe.example.com", "t1")
	SetGitToken("initech", "github.com", "t2")
	got, err := GitHubPullRequests(context.Background(), "initech")
	if err != nil || got.Host != "github.com" {
		t.Fatalf("%+v %v", got, err)
	}
	for _, h := range asked {
		if h != "github.com" {
			t.Fatalf("asked %v", asked)
		}
	}
}

func TestGitHubAPIBase(t *testing.T) {
	if githubAPIBase("github.com") != "https://api.github.com" || githubAPIBase("ghe.example.com") != "https://ghe.example.com/api/v3" {
		t.Fatal("bases")
	}
}
