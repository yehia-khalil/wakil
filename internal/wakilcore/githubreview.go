package wakilcore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// GitHubClient reads a repository's pull requests, review threads and checks over GitHub's
// GraphQL API, and replies to and resolves review threads — with the organization's git account
// for the remote's host, never `gh` and never a connection.
type GitHubClient struct {
	Endpoint, Token string
	http            *http.Client
}

// githubCallTimeout bounds every call: under the window's 20 s read timeout, so GitHub's own
// failure reaches the operator rather than the window's.
const githubCallTimeout = 15 * time.Second

// githubErrorBodyCap is how much of a failed response is shown: all of it, up to this size.
const githubErrorBodyCap = 64 << 10

// NewGitHubFor builds a client from org's GitHub account for host (GitHubTokenFor). The endpoint
// is WAKIL_GITHUB_API when set (tests and e2e), else api.github.com for github.com and
// https://<host>/api/graphql for a GitHub Enterprise host.
func NewGitHubFor(org, host string) (*GitHubClient, error) {
	host = strings.ToLower(strings.TrimSpace(host))
	token, err := GitHubTokenFor(org, host)
	if err != nil {
		return nil, err
	}
	return &GitHubClient{Endpoint: githubEndpoint(host), Token: token}, nil
}

func githubEndpoint(host string) string {
	if v := strings.TrimSpace(os.Getenv("WAKIL_GITHUB_API")); v != "" {
		return v
	}
	if host == "github.com" {
		return "https://api.github.com/graphql"
	}
	return "https://" + host + "/api/graphql"
}

type ReviewComment struct{ Author, Body, CreatedAt string }

type ReviewThread struct {
	ID, Path           string
	Line               int
	Outdated, Resolved bool
	Comments           []ReviewComment
	ResolvedBy         string
}

// CheckRun is one check or commit status; State is "success", "failure" or "pending".
type CheckRun struct{ Name, State, URL string }

// PullRequest's State is "open", "merged", "closed", or "blocked" (open, and GitHub says it
// cannot merge yet).
type PullRequest struct {
	Number                                               int
	Title, Body, URL, State, Head, Base, HeadSHA, Author string
	Checks                                               []CheckRun
	Threads                                              []ReviewThread
	RequestedReviewers                                   []string
	// Parent is the open PR whose head is this PR's base — the step down the stack — set on
	// BranchPRs' heads only, as a summary with no threads or checks.
	Parent *PullRequest
}

// GraphQLError is GitHub's `errors` list, every message whole. It can come back beside data.
type GraphQLError struct{ Messages []string }

func (e *GraphQLError) Error() string { return "GitHub: " + strings.Join(e.Messages, "; ") }

const githubPRFields = `
fragment pr on PullRequest {
  id number title body url state mergeStateStatus isCrossRepository
  headRefName baseRefName headRefOid author { login }
  reviewRequests(first: 20) { nodes { requestedReviewer {
    ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { name } } } }
}`

const githubThreadFields = `
fragment thread on PullRequestReviewThread {
  id path line originalLine isOutdated isResolved resolvedBy { login }
  comments(first: 50) { nodes { author { login } body createdAt } }
}`

const githubContextFields = `
fragment context on StatusCheckRollupContext {
  __typename
  ... on CheckRun { name status conclusion detailsUrl }
  ... on StatusContext { context state targetUrl }
}`

// githubBranchQuery is one BranchPRs read: the PRs whose head is the branch, newest first in
// every state, each with the open PR whose head is its base (its parent); and the open PRs
// whose base is the branch.
const githubBranchQuery = `query($owner: String!, $repo: String!, $branch: String!) {
  repository(owner: $owner, name: $repo) {
    heads: pullRequests(headRefName: $branch, first: 20, orderBy: {field: CREATED_AT, direction: DESC}, states: [OPEN, MERGED, CLOSED]) { nodes { ...full
      baseRef { associatedPullRequests(states: OPEN, first: 5) { nodes { ...pr } } } } }
    bases: pullRequests(baseRefName: $branch, first: 20, states: OPEN) { nodes { ...full } }
  }
}
fragment full on PullRequest {
  ...pr
  commits(last: 1) { nodes { commit { statusCheckRollup { id
    contexts(first: 100) { pageInfo { hasNextPage endCursor } nodes { ...context } } } } } }
  reviewThreads(first: 100) { pageInfo { hasNextPage endCursor } nodes { ...thread } }
}` + githubPRFields + githubThreadFields + githubContextFields

const githubThreadsPageQuery = `query($id: ID!, $after: String!) {
  node(id: $id) { ... on PullRequest {
    reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...thread } } } }
}` + githubThreadFields

const githubChecksPageQuery = `query($id: ID!, $after: String!) {
  node(id: $id) { ... on StatusCheckRollup {
    contexts(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...context } } } }
}` + githubContextFields

const githubViewerQuery = `query { viewer { login } }`

const githubReplyMutation = `mutation($id: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) {
    comment { author { login } body createdAt }
  }
}`

const githubResolveMutation = `mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
}`

const githubUnresolveMutation = `mutation($id: ID!) {
  unresolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
}`

// githubMyPRsQuery's authored PRs carry each thread's last comment and the last commit's checks
// (one page of each): what Waiting on you needs, in the same search.
const githubMyPRsQuery = `query($authored: String!, $requested: String!) {
  authored: search(query: $authored, type: ISSUE, first: 50) { nodes { ...pr ...waiting } }
  requested: search(query: $requested, type: ISSUE, first: 50) { nodes { ...pr } }
}
fragment waiting on PullRequest {
  commits(last: 1) { nodes { commit { statusCheckRollup { id
    contexts(first: 100) { pageInfo { hasNextPage endCursor } nodes { ...context } } } } } }
  reviewThreads(first: 100) { pageInfo { hasNextPage endCursor } nodes {
    id path line originalLine isOutdated isResolved resolvedBy { login }
    comments(last: 1) { nodes { author { login } body createdAt } } } }
}` + githubPRFields + githubContextFields

type ghLogin struct {
	Login string `json:"login"`
}

type ghPageInfo struct {
	HasNextPage bool   `json:"hasNextPage"`
	EndCursor   string `json:"endCursor"`
}

type ghComment struct {
	Author    *ghLogin `json:"author"`
	Body      string   `json:"body"`
	CreatedAt string   `json:"createdAt"`
}

type ghThread struct {
	ID           string   `json:"id"`
	Path         string   `json:"path"`
	Line         *int     `json:"line"`
	OriginalLine *int     `json:"originalLine"`
	IsOutdated   bool     `json:"isOutdated"`
	IsResolved   bool     `json:"isResolved"`
	ResolvedBy   *ghLogin `json:"resolvedBy"`
	Comments     struct {
		Nodes []ghComment `json:"nodes"`
	} `json:"comments"`
}

type ghThreads struct {
	PageInfo ghPageInfo `json:"pageInfo"`
	Nodes    []ghThread `json:"nodes"`
}

type ghContext struct {
	Typename   string `json:"__typename"`
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"detailsUrl"`
	Context    string `json:"context"`
	State      string `json:"state"`
	TargetURL  string `json:"targetUrl"`
}

type ghContexts struct {
	PageInfo ghPageInfo  `json:"pageInfo"`
	Nodes    []ghContext `json:"nodes"`
}

type ghPR struct {
	ID                string   `json:"id"`
	Number            int      `json:"number"`
	Title             string   `json:"title"`
	Body              string   `json:"body"`
	URL               string   `json:"url"`
	State             string   `json:"state"`
	MergeStateStatus  string   `json:"mergeStateStatus"`
	IsCrossRepository bool     `json:"isCrossRepository"`
	HeadRefName       string   `json:"headRefName"`
	BaseRefName       string   `json:"baseRefName"`
	HeadRefOid        string   `json:"headRefOid"`
	Author            *ghLogin `json:"author"`
	ReviewRequests    struct {
		Nodes []struct {
			RequestedReviewer *struct {
				Login string `json:"login"`
				Name  string `json:"name"`
			} `json:"requestedReviewer"`
		} `json:"nodes"`
	} `json:"reviewRequests"`
	Commits struct {
		Nodes []struct {
			Commit struct {
				StatusCheckRollup *struct {
					ID       string     `json:"id"`
					Contexts ghContexts `json:"contexts"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"commits"`
	ReviewThreads ghThreads `json:"reviewThreads"`
	BaseRef       *struct {
		AssociatedPullRequests struct {
			Nodes []ghPR `json:"nodes"`
		} `json:"associatedPullRequests"`
	} `json:"baseRef"`
}

func loginOf(l *ghLogin) string {
	if l == nil {
		return ""
	}
	return l.Login
}

func (p ghPR) pullRequest() PullRequest {
	state := strings.ToLower(p.State)
	if state == "open" && p.MergeStateStatus == "BLOCKED" {
		state = "blocked"
	}
	pr := PullRequest{
		Number: p.Number, Title: p.Title, Body: p.Body, URL: p.URL, State: state,
		Head: p.HeadRefName, Base: p.BaseRefName, HeadSHA: p.HeadRefOid, Author: loginOf(p.Author),
	}
	for _, n := range p.ReviewRequests.Nodes {
		if r := n.RequestedReviewer; r != nil {
			if r.Login != "" {
				pr.RequestedReviewers = append(pr.RequestedReviewers, r.Login)
			} else if r.Name != "" {
				pr.RequestedReviewers = append(pr.RequestedReviewers, r.Name)
			}
		}
	}
	return pr
}

// reviewThread keeps GitHub's `line`; an outdated thread has none, so it keeps the line it was
// written on.
func (t ghThread) reviewThread() ReviewThread {
	out := ReviewThread{ID: t.ID, Path: t.Path, Outdated: t.IsOutdated, Resolved: t.IsResolved, ResolvedBy: loginOf(t.ResolvedBy)}
	if t.Line != nil {
		out.Line = *t.Line
	} else if t.OriginalLine != nil {
		out.Line = *t.OriginalLine
	}
	for _, c := range t.Comments.Nodes {
		out.Comments = append(out.Comments, ReviewComment{Author: loginOf(c.Author), Body: c.Body, CreatedAt: c.CreatedAt})
	}
	return out
}

// checkRun folds a check run's status and conclusion, or a commit status's state, into
// success, failure or pending. Neutral and skipped runs pass.
func (c ghContext) checkRun() CheckRun {
	if c.Typename == "StatusContext" {
		state := "failure"
		switch c.State {
		case "SUCCESS":
			state = "success"
		case "PENDING", "EXPECTED":
			state = "pending"
		}
		return CheckRun{Name: c.Context, State: state, URL: c.TargetURL}
	}
	state := "failure"
	switch {
	case c.Status != "COMPLETED":
		state = "pending"
	case c.Conclusion == "SUCCESS" || c.Conclusion == "NEUTRAL" || c.Conclusion == "SKIPPED":
		state = "success"
	}
	return CheckRun{Name: c.Name, State: state, URL: c.DetailsURL}
}

// Viewer is the login the token belongs to.
func (c *GitHubClient) Viewer(ctx context.Context) (string, error) {
	var data struct {
		Viewer ghLogin `json:"viewer"`
	}
	err := c.do(ctx, githubViewerQuery, nil, &data)
	return data.Viewer.Login, err
}

// BranchPRs reads owner/repo's PRs whose head is branch (heads: newest first, open, merged and
// closed) and the open PRs whose base is branch (bases), in one query; a thread or check list
// longer than one page is paged on that connection alone. A PR whose head is in a fork is not
// matched — forks are out of scope.
//
// The stack is followed one step each way, in the same query, and no further: bases are the
// PRs based on this branch, and each head's Parent is the PR it is based on (the open PR whose
// head is its base; the first one when GitHub lists several).
//
// GraphQL errors beside data come back as a *GraphQLError with the data still returned.
func (c *GitHubClient) BranchPRs(ctx context.Context, owner, repo, branch string) (heads, bases []PullRequest, err error) {
	var data struct {
		Repository *struct {
			Heads struct {
				Nodes []ghPR `json:"nodes"`
			} `json:"heads"`
			Bases struct {
				Nodes []ghPR `json:"nodes"`
			} `json:"bases"`
		} `json:"repository"`
	}
	var gqlErrs []string
	if err := c.do(ctx, githubBranchQuery, map[string]any{"owner": owner, "repo": repo, "branch": branch}, &data); err != nil {
		var ge *GraphQLError
		if !errors.As(err, &ge) {
			return nil, nil, err
		}
		gqlErrs = append(gqlErrs, ge.Messages...)
	}
	if data.Repository == nil {
		return nil, nil, graphQLErrorOrNil(gqlErrs)
	}
	full := func(nodes []ghPR) ([]PullRequest, error) {
		var out []PullRequest
		for _, p := range nodes {
			if p.Number == 0 || p.IsCrossRepository {
				continue
			}
			pr, err := c.fullPR(ctx, p, &gqlErrs)
			if err != nil {
				return nil, err
			}
			out = append(out, pr)
		}
		return out, nil
	}
	if heads, err = full(data.Repository.Heads.Nodes); err != nil {
		return nil, nil, err
	}
	if bases, err = full(data.Repository.Bases.Nodes); err != nil {
		return nil, nil, err
	}
	return heads, bases, graphQLErrorOrNil(gqlErrs)
}

// fullPR converts p with its threads and checks, paging either past its first page.
func (c *GitHubClient) fullPR(ctx context.Context, p ghPR, gqlErrs *[]string) (PullRequest, error) {
	pr := p.pullRequest()
	if p.BaseRef != nil {
		for _, q := range p.BaseRef.AssociatedPullRequests.Nodes {
			if q.Number != 0 && !q.IsCrossRepository {
				parent := q.pullRequest()
				pr.Parent = &parent
				break
			}
		}
	}
	threads := p.ReviewThreads
	for {
		for _, t := range threads.Nodes {
			pr.Threads = append(pr.Threads, t.reviewThread())
		}
		if !threads.PageInfo.HasNextPage {
			break
		}
		var page struct {
			Node *struct {
				ReviewThreads ghThreads `json:"reviewThreads"`
			} `json:"node"`
		}
		if err := c.page(ctx, githubThreadsPageQuery, p.ID, threads.PageInfo.EndCursor, &page, gqlErrs); err != nil {
			return PullRequest{}, err
		}
		if page.Node == nil {
			break
		}
		threads = page.Node.ReviewThreads
	}
	if len(p.Commits.Nodes) == 0 || p.Commits.Nodes[0].Commit.StatusCheckRollup == nil {
		return pr, nil
	}
	rollup := p.Commits.Nodes[0].Commit.StatusCheckRollup
	contexts := rollup.Contexts
	for {
		for _, ctxNode := range contexts.Nodes {
			pr.Checks = append(pr.Checks, ctxNode.checkRun())
		}
		if !contexts.PageInfo.HasNextPage {
			break
		}
		var page struct {
			Node *struct {
				Contexts ghContexts `json:"contexts"`
			} `json:"node"`
		}
		if err := c.page(ctx, githubChecksPageQuery, rollup.ID, contexts.PageInfo.EndCursor, &page, gqlErrs); err != nil {
			return PullRequest{}, err
		}
		if page.Node == nil {
			break
		}
		contexts = page.Node.Contexts
	}
	return pr, nil
}

// page reads one more page of a connection; its GraphQL errors join the read's.
func (c *GitHubClient) page(ctx context.Context, query, id, after string, out any, gqlErrs *[]string) error {
	err := c.do(ctx, query, map[string]any{"id": id, "after": after}, out)
	var ge *GraphQLError
	if errors.As(err, &ge) {
		*gqlErrs = append(*gqlErrs, ge.Messages...)
		return nil
	}
	return err
}

func graphQLErrorOrNil(messages []string) error {
	if len(messages) == 0 {
		return nil
	}
	return &GraphQLError{Messages: messages}
}

// ReplyToThread adds body, verbatim, as a reply in the review thread.
func (c *GitHubClient) ReplyToThread(ctx context.Context, threadID, body string) (ReviewComment, error) {
	var data struct {
		Reply *struct {
			Comment ghComment `json:"comment"`
		} `json:"addPullRequestReviewThreadReply"`
	}
	if err := c.do(ctx, githubReplyMutation, map[string]any{"id": threadID, "body": body}, &data); err != nil {
		return ReviewComment{}, err
	}
	if data.Reply == nil {
		return ReviewComment{}, UserError("GitHub answered the reply with no comment")
	}
	cm := data.Reply.Comment
	return ReviewComment{Author: loginOf(cm.Author), Body: cm.Body, CreatedAt: cm.CreatedAt}, nil
}

// SetThreadResolved resolves or unresolves the review thread.
func (c *GitHubClient) SetThreadResolved(ctx context.Context, threadID string, resolved bool) error {
	mutation := githubUnresolveMutation
	if resolved {
		mutation = githubResolveMutation
	}
	return c.do(ctx, mutation, map[string]any{"id": threadID}, nil)
}

// MyOpenPRs searches the open PRs the token's user wrote, and those waiting on their review,
// in owners' repositories only. No owners, no search. An authored PR's Threads hold only each
// thread's last comment, and its Checks one page; neither is paged further.
//
// The owners go into one search as repeated `org:` qualifiers, which GitHub ORs. If that ever
// stops holding, the fallback is one search per owner.
func (c *GitHubClient) MyOpenPRs(ctx context.Context, owners []string) (authored, reviewRequested []PullRequest, err error) {
	if len(owners) == 0 {
		return nil, nil, nil
	}
	scope := ""
	for _, o := range owners {
		scope += " org:" + o
	}
	var data struct {
		Authored struct {
			Nodes []ghPR `json:"nodes"`
		} `json:"authored"`
		Requested struct {
			Nodes []ghPR `json:"nodes"`
		} `json:"requested"`
	}
	err = c.do(ctx, githubMyPRsQuery, map[string]any{
		"authored":  "is:open is:pr author:@me" + scope,
		"requested": "is:open is:pr review-requested:@me" + scope,
	}, &data)
	var ge *GraphQLError
	if err != nil && !errors.As(err, &ge) {
		return nil, nil, err
	}
	prs := func(nodes []ghPR, waiting bool) []PullRequest {
		var out []PullRequest
		for _, p := range nodes {
			if p.Number == 0 {
				continue
			}
			pr := p.pullRequest()
			if waiting {
				for _, t := range p.ReviewThreads.Nodes {
					pr.Threads = append(pr.Threads, t.reviewThread())
				}
				if len(p.Commits.Nodes) > 0 && p.Commits.Nodes[0].Commit.StatusCheckRollup != nil {
					for _, n := range p.Commits.Nodes[0].Commit.StatusCheckRollup.Contexts.Nodes {
						pr.Checks = append(pr.Checks, n.checkRun())
					}
				}
			}
			out = append(out, pr)
		}
		return out
	}
	return prs(data.Authored.Nodes, true), prs(data.Requested.Nodes, false), err
}

var errGitHubRedirect = errors.New("GitHub response tried to redirect; refusing to follow")

func (c *GitHubClient) client() *http.Client {
	if c.http == nil {
		c.http = &http.Client{
			Timeout: githubCallTimeout,
			// A redirect could carry the token to another host; GitHub's API never needs one.
			CheckRedirect: func(*http.Request, []*http.Request) error { return errGitHubRedirect },
		}
	}
	return c.http
}

// do posts one GraphQL request and decodes its data into out. GitHub's `errors` come back as a
// *GraphQLError after the data is decoded. The token never appears in an error.
func (c *GitHubClient) do(ctx context.Context, query string, variables map[string]any, out any) error {
	scrub := NewAuthHeaderScrubber("bearer " + c.Token)
	b, err := json.Marshal(map[string]any{"query": query, "variables": variables})
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, githubCallTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Endpoint, bytes.NewReader(b))
	if err != nil {
		return UserError(scrub.Scrub("could not build the GitHub request: " + err.Error()))
	}
	req.Header.Set("Authorization", "bearer "+c.Token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "wakil")
	resp, err := c.client().Do(req)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return UserError(fmt.Sprintf("GitHub did not answer within %d s", int(githubCallTimeout/time.Second)))
		}
		return UserError(scrub.Scrub("GitHub unreachable: " + err.Error()))
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		// The whole body, scrubbed: cut in raw coordinates past any credential straddling the
		// cap, scrub, then drop a trailing partial credential — as JiraClient.search does.
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, int64(githubErrorBodyCap+scrub.LongestForm())))
		body := strings.TrimSpace(string(raw))
		cut := scrub.CutPoint(body, githubErrorBodyCap)
		shown := truncateBytesAtRuneBoundary(scrub.Scrub(body[:cut]), githubErrorBodyCap)
		shown = scrub.StripPartialTail(shown)
		msg := fmt.Sprintf("GitHub error %d: %s", resp.StatusCode, shown)
		if readErr != nil {
			msg += " (response body was cut short by a read error)"
		}
		return UserError(msg)
	}

	var envelope struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return UserError(scrub.Scrub("GitHub's answer could not be read: " + err.Error()))
	}
	if out != nil && len(envelope.Data) > 0 && string(envelope.Data) != "null" {
		if err := json.Unmarshal(envelope.Data, out); err != nil {
			return UserError(scrub.Scrub("GitHub's answer could not be read: " + err.Error()))
		}
	}
	if len(envelope.Errors) > 0 {
		ge := &GraphQLError{}
		for _, e := range envelope.Errors {
			ge.Messages = append(ge.Messages, scrub.Scrub(e.Message))
		}
		return ge
	}
	return nil
}
