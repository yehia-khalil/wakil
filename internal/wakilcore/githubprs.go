package wakilcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// MyPullRequest is one open pull request the operator wrote or was asked to review. Reason is
// "author" or "review-requested"; a pull request that is both reads "author".
type MyPullRequest struct {
	Number     int    `json:"number"`
	Title      string `json:"title"`
	URL        string `json:"url"`
	Repository string `json:"repository"`
	Reason     string `json:"reason"`
}

// PullRequestsResult is the read's answer. Absent is why there is no list (no GitHub account, an
// SSH one, no token): a state, not a failure. Host is the account that was asked.
type PullRequestsResult struct {
	PullRequests []MyPullRequest `json:"pullRequests"`
	Absent       string        `json:"absent,omitempty"`
	Host         string        `json:"host,omitempty"`
}

// githubPullRequestsBudget is both searches' total time. It stays under the app's read timeout
// for this call (MCPClient.readReplyTimeout, 10 s), so a host that hangs reads "<host> did not
// answer: …" rather than the app's own timeout. Overridable by tests.
var githubPullRequestsBudget = 8 * time.Second

// githubAPIBase is where a GitHub host's REST API lives (overridable by tests).
var githubAPIBase = func(host string) string {
	if host == "github.com" {
		return "https://api.github.com"
	}
	return "https://" + host + "/api/v3"
}

// GitHubPullRequests reads org's open pull requests (authored by the token's owner, and awaiting
// their review) from the organisation's GitHub account. It never returns the token.
func GitHubPullRequests(ctx context.Context, org string) (PullRequestsResult, error) {
	none := PullRequestsResult{PullRequests: []MyPullRequest{}}
	o, err := LoadOrgFor(org)
	if err != nil {
		return none, err
	}
	var accounts []GitAccount
	for _, a := range o.GitAccounts {
		if a.Provider == "github" {
			accounts = append(accounts, a)
		}
	}
	if len(accounts) == 0 {
		none.Absent = "No pull-request group: " + org + " has no GitHub account."
		return none, nil
	}
	sort.SliceStable(accounts, func(i, j int) bool {
		gi, gj := accounts[i].Host == "github.com", accounts[j].Host == "github.com"
		if gi != gj {
			return gi
		}
		return accounts[i].Host < accounts[j].Host
	})
	a := accounts[0]
	none.Host = a.Host
	if a.Method == "ssh" {
		none.Absent = "No pull-request group: " + org + "'s GitHub account on " + a.Host +
			" uses an SSH key, which can't read pull requests — add a token or Sign in under Settings → Organisation → Git."
		return none, nil
	}
	// Only a missing item is "no token": a locked or denied Keychain is an error, whole.
	token, err := SecretGetFor(org, gitTokenRef(a.Host))
	if err != nil && !errors.Is(err, ErrSecretNotFound) {
		return none, err
	}
	if token == "" {
		none.Absent = "No pull-request group: no token is kept for " + a.Host + " in " + org + "."
		return none, nil
	}
	ctx, cancel := context.WithTimeout(ctx, githubPullRequestsBudget)
	defer cancel()
	base := githubAPIBase(a.Host)
	type found struct {
		MyPullRequest
		updated string
	}
	byURL := map[string]*found{}
	for _, search := range []struct{ q, reason string }{
		{"is:pr is:open author:@me", "author"},
		{"is:pr is:open review-requested:@me", "review-requested"},
	} {
		items, err := githubSearch(ctx, base, a.Host, token, search.q)
		if err != nil {
			return none, err
		}
		for _, it := range items {
			if have, ok := byURL[it.HTMLURL]; ok {
				if search.reason == "author" {
					have.Reason = "author"
				}
				continue
			}
			repo := ""
			if parts := strings.Split(strings.TrimRight(it.RepositoryURL, "/"), "/"); len(parts) >= 2 {
				repo = parts[len(parts)-2] + "/" + parts[len(parts)-1]
			}
			byURL[it.HTMLURL] = &found{
				MyPullRequest: MyPullRequest{Number: it.Number, Title: it.Title, URL: it.HTMLURL, Repository: repo, Reason: search.reason},
				updated:     it.UpdatedAt,
			}
		}
	}
	all := make([]*found, 0, len(byURL))
	for _, f := range byURL {
		all = append(all, f)
	}
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].updated != all[j].updated {
			return all[i].updated > all[j].updated
		}
		return all[i].URL < all[j].URL
	})
	out := PullRequestsResult{PullRequests: []MyPullRequest{}, Host: a.Host}
	for _, f := range all {
		out.PullRequests = append(out.PullRequests, f.MyPullRequest)
	}
	return out, nil
}

type githubSearchItem struct {
	Number        int    `json:"number"`
	Title         string `json:"title"`
	HTMLURL       string `json:"html_url"`
	RepositoryURL string `json:"repository_url"`
	UpdatedAt     string `json:"updated_at"`
}

func githubSearch(ctx context.Context, base, host, token, q string) ([]githubSearchItem, error) {
	u := strings.TrimRight(base, "/") + "/search/issues?q=" + url.QueryEscape(q) + "&per_page=50&sort=updated"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, UserError(host + " did not answer: " + err.Error())
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		var m struct {
			Message string `json:"message"`
		}
		json.Unmarshal(body, &m)
		if m.Message == "" {
			m.Message = strings.TrimSpace(string(body))
		}
		return nil, UserError(fmt.Sprintf("%s refused the pull-request search (HTTP %d): %s", host, resp.StatusCode, m.Message))
	}
	var r struct {
		Items []githubSearchItem `json:"items"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, UserError(host + " did not answer: " + err.Error())
	}
	return r.Items, nil
}
