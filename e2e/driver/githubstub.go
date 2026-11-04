package driver

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// The Ticket view's GitHub, replaced (Ticket view Cover). `wakil-ticket` reads pull requests,
// review threads and checks from GitHub's GraphQL API at WAKIL_GITHUB_API when it is set, and the
// window forwards that variable to the children it owns — so a launch that starts this stub never
// asks api.github.com anything, and every answer is the same every run.
//
// **What it answers is chosen by the branch asked about**, because a branch is the one thing a
// check can change mid-launch (a `git checkout` in a terminal pane) and the view reads again on
// every branch change. The seeded repository (`seedTicketRepo`) carries one branch per answer.
const (
	// TicketBranchOwn has one open PR, #212, with a failing check and two open threads — the
	// ticket view's whole column.
	TicketBranchOwn = "ini-142-login"
	// TicketBranchBroken answers GraphQL errors and no data: GitHub's error shown whole.
	TicketBranchBroken = "ini-150-broken"
	// TicketBranchStall never answers until the request is cancelled: ↻'s Cancel.
	TicketBranchStall = "ini-160-stall"
	// TicketBranchNone carries no key and has no PR: "No ticket found", and Link a ticket.
	TicketBranchNone = "feature-login"
	// TicketBranchSeveral carries two keys in its name and has no PR: the several layout.
	TicketBranchSeveral = "ini-170-ini-142-both"
	// TicketBranchMerged is the branch a workspace started by "write the merged note" works on
	// (decision 10's fallback name, the conversation's title as a slug): it heads one PR, #216,
	// merged — the home's Archive offer (workspaces, piece 3; decision 11). The workspace makes it,
	// so the seed does not.
	TicketBranchMerged = "write-the-merged-note"
)

// TicketBrokenMessage is the GraphQL error TicketBranchBroken answers.
const TicketBrokenMessage = "Something went wrong while executing your query. Please include `E2E:1` when reporting this issue."

// githubStubStallCap bounds a stalled answer, so a run that never cancels still frees the
// handler before the stub closes; it is past Go's own 15 s per call.
const githubStubStallCap = 60 * time.Second

// StartGitHubStub serves GitHub's GraphQL API on loopback for one launch. headSHA is the seeded
// repository's HEAD, given as PR #212's head so the review boxes place against a commit the
// repository has.
func StartGitHubStub(headSHA string) (string, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		_ = json.Unmarshal(body, &req)
		w.Header().Set("content-type", "application/json")
		answer := githubStubAnswer(req.Query, req.Variables, headSHA)
		if answer == nil {
			select {
			case <-r.Context().Done():
			case <-time.After(githubStubStallCap):
			}
			return
		}
		_ = json.NewEncoder(w).Encode(answer)
	})}
	go srv.Serve(ln)
	return "http://" + ln.Addr().String() + "/graphql", func() { srv.Close() }, nil
}

// githubStubAnswer is the stub's reply to one query; nil means stall.
func githubStubAnswer(query string, vars map[string]any, headSHA string) any {
	str := func(k string) string { s, _ := vars[k].(string); return s }
	switch {
	case strings.Contains(query, "addPullRequestReviewThreadReply"):
		return map[string]any{"data": map[string]any{"addPullRequestReviewThreadReply": map[string]any{
			"comment": map[string]any{"author": map[string]any{"login": "peter"}, "body": str("body"), "createdAt": "2026-10-26T09:00:00Z"}}}}
	case strings.Contains(query, "unresolveReviewThread"):
		return map[string]any{"data": map[string]any{"unresolveReviewThread": map[string]any{"thread": map[string]any{"id": str("id"), "isResolved": false}}}}
	case strings.Contains(query, "resolveReviewThread"):
		return map[string]any{"data": map[string]any{"resolveReviewThread": map[string]any{"thread": map[string]any{"id": str("id"), "isResolved": true}}}}
	case strings.Contains(query, "viewer { login }"):
		return map[string]any{"data": map[string]any{"viewer": map[string]any{"login": "peter"}}}
	case strings.Contains(query, "authored: search"):
		return map[string]any{"data": map[string]any{
			"authored":  map[string]any{"nodes": []any{githubStubPR(headSHA), githubStubKeylessPR()}},
			"requested": map[string]any{"nodes": []any{githubStubBillingPR()}},
		}}
	case strings.Contains(query, "... on PullRequestReviewThread"):
		for _, t := range githubStubThreads() {
			if t["id"] == str("id") {
				return map[string]any{"data": map[string]any{"node": map[string]any{
					"__typename": "PullRequestReviewThread", "id": t["id"], "path": t["path"], "line": t["line"],
					"originalLine": t["line"], "isResolved": false, "isOutdated": false,
					"pullRequest": map[string]any{"number": 212, "repository": map[string]any{"nameWithOwner": "initech/api"}},
					"comments":    t["comments"],
				}}}
			}
		}
		return map[string]any{"data": map[string]any{"node": nil}}
	case strings.Contains(query, "heads: pullRequests"):
		heads, bases := []any{}, []any{}
		switch str("branch") {
		case TicketBranchOwn:
			heads = append(heads, githubStubPR(headSHA))
		case TicketBranchMerged:
			heads = append(heads, githubStubMergedPR())
		case "main":
			bases = append(bases, githubStubPR(headSHA))
		case TicketBranchBroken:
			return map[string]any{"data": nil, "errors": []any{map[string]any{"message": TicketBrokenMessage}}}
		case TicketBranchStall:
			return nil
		}
		return map[string]any{"data": map[string]any{"repository": map[string]any{
			"heads": map[string]any{"nodes": heads}, "bases": map[string]any{"nodes": bases},
		}}}
	}
	return map[string]any{"errors": []any{map[string]any{"message": "the e2e GitHub stub does not answer this query"}}}
}

// githubStubThreads are PR #212's open threads: one on app.txt waiting on the author, one on
// README.md the author answered last.
func githubStubThreads() []map[string]any {
	comment := func(who, body string) map[string]any {
		return map[string]any{"author": map[string]any{"login": who}, "body": body, "createdAt": "2026-10-25T09:00:00Z"}
	}
	return []map[string]any{
		{"id": "T_1", "path": "app.txt", "line": 2,
			"comments": map[string]any{"nodes": []any{comment("reviewer", "Nit: name the host")}}},
		{"id": "T_2", "path": "README.md", "line": 1,
			"comments": map[string]any{"nodes": []any{comment("reviewer", "Say what the API serves"), comment("peter", "Done in the next push")}}},
	}
}

// githubStubPR is PR #212 on initech/api, head ini-142-login, by peter: one check failing, one
// passing, reviewer asked for, and the two threads.
func githubStubPR(headSHA string) map[string]any {
	threads := []any{}
	for _, t := range githubStubThreads() {
		threads = append(threads, map[string]any{"id": t["id"], "path": t["path"], "line": t["line"], "originalLine": t["line"],
			"isOutdated": false, "isResolved": false, "resolvedBy": nil, "comments": t["comments"]})
	}
	return map[string]any{
		"id": "PR_212", "number": 212, "title": "INI-142 Log in with a token", "body": "Ticket: INI-142",
		"url": "https://github.com/initech/api/pull/212", "state": "OPEN", "mergeStateStatus": "CLEAN",
		"updatedAt": "2026-10-25T08:00:00Z", "isCrossRepository": false, "headRefName": TicketBranchOwn, "baseRefName": "main", "headRefOid": headSHA,
		"author":         map[string]any{"login": "peter"},
		"reviewRequests": map[string]any{"nodes": []any{map[string]any{"requestedReviewer": map[string]any{"login": "reviewer"}}}},
		"commits": map[string]any{"nodes": []any{map[string]any{"commit": map[string]any{"statusCheckRollup": map[string]any{
			"id": "SCR_212", "contexts": map[string]any{"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}, "nodes": []any{
				map[string]any{"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE",
					"detailsUrl": "https://github.com/initech/api/actions/runs/1"},
				map[string]any{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
					"detailsUrl": "https://github.com/initech/api/actions/runs/2"},
			}}}}}}},
		"reviewThreads": map[string]any{"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}, "nodes": threads},
		"baseRef":       map[string]any{"associatedPullRequests": map[string]any{"nodes": []any{}}},
	}
}

// githubStubKeylessPR is PR #215 on initech/api, by peter, whose branch, title and body carry no
// ticket key: one check failing, so it waits on the operator as a row named by its PR.
func githubStubKeylessPR() map[string]any {
	return map[string]any{
		"id": "PR_215", "number": 215, "title": "Speed up the build", "body": "",
		"url": "https://github.com/initech/api/pull/215", "state": "OPEN", "mergeStateStatus": "CLEAN",
		"updatedAt": "2026-10-26T08:00:00Z", "isCrossRepository": false, "headRefName": "build-speed", "baseRefName": "main",
		"headRefOid": "def456", "author": map[string]any{"login": "peter"},
		"reviewRequests": map[string]any{"nodes": []any{}},
		"commits": map[string]any{"nodes": []any{map[string]any{"commit": map[string]any{"statusCheckRollup": map[string]any{
			"id": "SCR_215", "contexts": map[string]any{"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}, "nodes": []any{
				map[string]any{"__typename": "CheckRun", "name": "unit (Linux)", "status": "COMPLETED", "conclusion": "FAILURE",
					"detailsUrl": "https://github.com/initech/api/actions/runs/3"},
			}}}}}}},
		"reviewThreads": map[string]any{"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}, "nodes": []any{}},
	}
}

// githubStubMergedPR is PR #216 on initech/api, by peter, merged: TicketBranchMerged's only PR.
func githubStubMergedPR() map[string]any {
	return map[string]any{
		"id": "PR_216", "number": 216, "title": "Write the merged note", "body": "",
		"url": "https://github.com/initech/api/pull/216", "state": "MERGED", "mergeStateStatus": "UNKNOWN",
		"updatedAt": "2026-10-27T08:00:00Z", "isCrossRepository": false, "headRefName": TicketBranchMerged,
		"baseRefName": "main", "headRefOid": "aaa216", "author": map[string]any{"login": "peter"},
		"reviewRequests": map[string]any{"nodes": []any{}},
		"reviewThreads":  map[string]any{"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}, "nodes": []any{}},
	}
}

// githubStubBillingPR is PR #214 on initech/billing, a repository no seeded project holds, by
// another author, asking for peter's review.
func githubStubBillingPR() map[string]any {
	return map[string]any{
		"id": "PR_214", "number": 214, "title": "Bill per seat", "body": "",
		"url": "https://github.com/initech/billing/pull/214", "state": "OPEN", "mergeStateStatus": "CLEAN",
		"updatedAt": "2026-10-24T08:00:00Z", "isCrossRepository": false, "headRefName": "bill-per-seat", "baseRefName": "main",
		"headRefOid": "fed789", "author": map[string]any{"login": "milton"},
		"reviewRequests": map[string]any{"nodes": []any{map[string]any{"requestedReviewer": map[string]any{"login": "peter"}}}},
	}
}
