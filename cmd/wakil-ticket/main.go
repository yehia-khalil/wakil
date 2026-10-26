package main

import (
	"context"
	"log"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/yehia-khalil/wakil/internal/mcpx"
	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// wakil-ticket is window-owned (spec: "The capability: wakil-ticket"): the window starts it, and
// the agent reaches it only through registry actions over the shim. Its reads answer anywhere;
// its writes answer only in a process the window started (WAKIL_IN_WINDOW=1), as wakil-http's
// send does.

type empty struct{}

type rootArg struct {
	Root string `json:"root" jsonschema:"a root of one of the organization's projects"`
}

type branchReadArg struct {
	Root   string `json:"root" jsonschema:"a root of one of the organization's projects"`
	Branch string `json:"branch,omitempty" jsonschema:"a branch to read instead of the root's current one (a ticket picked from In flight); nothing is checked out"`
}

type keyArg struct {
	Key string `json:"key" jsonschema:"a ticket key, e.g. INI-142"`
}

// lineArg is the text of a record line. A field left out keeps the line's current text on an
// edit, so an edit of one field never blanks the others; an empty string clears it.
type lineArg struct {
	Text  *string `json:"text,omitempty"`
	Why   *string `json:"why,omitempty"`
	How   *string `json:"how,omitempty"`
	Who   *string `json:"who,omitempty"`
	What  *string `json:"what,omitempty"`
	State *string `json:"state,omitempty" jsonschema:"a ruling's state; an added ruling is open"`
}

type recordWriteArg struct {
	Key          string  `json:"key" jsonschema:"the ticket key"`
	Section      string  `json:"section" jsonschema:"next, decisions, notDone, waitingOn, verified or rulings"`
	Op           string  `json:"op" jsonschema:"set (next only), add, edit or remove"`
	ID           string  `json:"id,omitempty" jsonschema:"the line's id, for edit and remove"`
	Line         lineArg `json:"line"`
	By           string  `json:"by" jsonschema:"operator, agent or wakil: who the window's dispatch came from"`
	Conversation string  `json:"conversation,omitempty" jsonschema:"an agent line's conversation"`
}

type linkArg struct {
	Root   string `json:"root" jsonschema:"a root of one of the organization's projects"`
	Branch string `json:"branch,omitempty" jsonschema:"the branch to link; the root's current branch when left out"`
	Key    string `json:"key" jsonschema:"the ticket key; an empty key unlinks, which returns the branch to inference"`
}

type replyArg struct {
	Root   string `json:"root" jsonschema:"the root whose remote the thread's pull request is on"`
	Thread string `json:"thread" jsonschema:"the review thread's GitHub node id"`
	Body   string `json:"body" jsonschema:"the reply, posted verbatim"`
}

type resolveArg struct {
	Root     string `json:"root" jsonschema:"the root whose remote the thread's pull request is on"`
	Thread   string `json:"thread" jsonschema:"the review thread's GitHub node id"`
	Resolved bool   `json:"resolved" jsonschema:"true resolves the thread, false unresolves it"`
}

type linkResult struct {
	Key    string `json:"key"`
	Linked bool   `json:"linked"`
	// NotFound: Jira does not know the key, or its prefix is no project of the organization's.
	// The link is kept either way.
	NotFound bool   `json:"notFound"`
	Message  string `json:"message,omitempty"`
}

type replyResult struct {
	Comment Comment `json:"comment"`
}

// threadResult is a review thread as GitHub describes it by its id: the place the confirmation
// plane names for a reply or a resolve, never the caller's word for it.
type threadResult struct {
	ID         string `json:"id"`
	Repo       string `json:"repo" jsonschema:"owner/name"`
	Number     int    `json:"number"`
	Path       string `json:"path"`
	Line       int    `json:"line"`
	Resolved   bool   `json:"resolved"`
	Outdated   bool   `json:"outdated"`
	Author     string `json:"author"`
	FirstWords string `json:"firstWords"`
}

type threadArg struct {
	Root   string `json:"root" jsonschema:"the root whose remote's GitHub account reads the thread"`
	Thread string `json:"thread" jsonschema:"the review thread's GitHub node id"`
}

type resolveResult struct {
	Thread   string `json:"thread"`
	Resolved bool   `json:"resolved"`
}

func toolErr(err error) *mcp.CallToolResult { return mcpx.ToolErr("wakil-ticket", err) }

// assertWindow refuses a write from a process the window did not start, naming the window.
func assertWindow(tool string) error {
	if wakilcore.InWakilWindow() {
		return nil
	}
	return wakilcore.UserError("this wakil-ticket was not started by the Wakil window, so it only reads: " + tool +
		" writes, and runs from the Wakil window, where the operator sees what it changes")
}

func newServer() *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "wakil-ticket", Version: "0.1.0"}, nil)

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_branch", Description: "Read-only. One root's branch (its current one, or the branch named): its tickets (key, title, PM status, where each was found, the ticket record), its pull requests with review threads and checks, the PRs based on it, the stack one step each way, and every source that could not be read, whole. A detached HEAD reads nothing remote. Writes the read into each ticket's record (seen, branch, PRs)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a branchReadArg) (*mcp.CallToolResult, TicketBranch, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), TicketBranch{}, nil
			}
			out, err := readTicketBranch(ctx, org, a.Root, a.Branch, time.Now())
			if err != nil {
				return toolErr(err), TicketBranch{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_in_flight", Description: "Read-only. The organization's tickets in flight (a local branch in any of its roots, or an open PR of yours) and Waiting on you (threads on your open PRs whose last word is not yours, PRs asking for your review, your PRs with a failing check), each with one state in words."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, InFlight, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), InFlight{}, nil
			}
			return nil, readInFlight(ctx, org), nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_record", Description: "Read-only. One ticket's record: next, decisions, not done, waiting on, verified and rulings, with who wrote each line; empty when none exists yet."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a keyArg) (*mcp.CallToolResult, wakilcore.TicketRecord, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			r, err := wakilcore.ReadTicketRecord(org, a.Key)
			if err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_record_write", Description: "Writes. Sets a ticket's next line, or adds, edits or removes one line of a list. Only from the Wakil window. The old line is kept in the record's log. An edit changes only the fields given."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recordWriteArg) (*mcp.CallToolResult, wakilcore.TicketRecord, error) {
			if err := assertWindow("ticket_record_write"); err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			r, err := writeRecord(org, a, time.Now())
			if err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			return nil, r, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_link", Description: "Writes. Links a repository's branch to a ticket key, overriding inference; an empty key unlinks. Only from the Wakil window. A key Jira cannot find is kept and answered with notFound."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a linkArg) (*mcp.CallToolResult, linkResult, error) {
			if err := assertWindow("ticket_link"); err != nil {
				return toolErr(err), linkResult{}, nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), linkResult{}, nil
			}
			out, err := linkBranch(ctx, org, a)
			if err != nil {
				return toolErr(err), linkResult{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "review_reply", Description: "Writes to GitHub. Posts body, verbatim, as a reply in a review thread, with the organization's GitHub account for the root's remote. Only from the Wakil window. Answers the posted comment."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a replyArg) (*mcp.CallToolResult, replyResult, error) {
			if err := assertWindow("review_reply"); err != nil {
				return toolErr(err), replyResult{}, nil
			}
			if strings.TrimSpace(a.Body) == "" {
				return toolErr(wakilcore.UserError("a reply needs text")), replyResult{}, nil
			}
			gh, err := githubForRoot(ctx, a.Root, a.Thread)
			if err != nil {
				return toolErr(err), replyResult{}, nil
			}
			c, err := gh.ReplyToThread(ctx, a.Thread, a.Body)
			if err != nil {
				return toolErr(err), replyResult{}, nil
			}
			return nil, replyResult{Comment: comment(c)}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "review_resolve", Description: "Writes to GitHub. Resolves or unresolves a review thread with the organization's GitHub account for the root's remote. Only from the Wakil window."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a resolveArg) (*mcp.CallToolResult, resolveResult, error) {
			if err := assertWindow("review_resolve"); err != nil {
				return toolErr(err), resolveResult{}, nil
			}
			gh, err := githubForRoot(ctx, a.Root, a.Thread)
			if err != nil {
				return toolErr(err), resolveResult{}, nil
			}
			if err := gh.SetThreadResolved(ctx, a.Thread, a.Resolved); err != nil {
				return toolErr(err), resolveResult{}, nil
			}
			return nil, resolveResult{Thread: a.Thread, Resolved: a.Resolved}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "review_thread", Description: "Read-only. A review thread as GitHub describes it by its node id, with the organization's GitHub account for the root's remote: its repository (owner/name), pull request, file and line, whether it is resolved, and who opened it with what first words. The window names a reply's or a resolve's place from this before it asks the operator."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a threadArg) (*mcp.CallToolResult, threadResult, error) {
			gh, err := githubForRoot(ctx, a.Root, a.Thread)
			if err != nil {
				return toolErr(err), threadResult{}, nil
			}
			t, err := gh.ReviewThread(ctx, a.Thread)
			if err != nil {
				return toolErr(err), threadResult{}, nil
			}
			return nil, threadResult{ID: t.ID, Repo: t.Repo, Number: t.Number, Path: t.Path, Line: t.Line,
				Resolved: t.Resolved, Outdated: t.Outdated, Author: t.Author, FirstWords: t.FirstWords}, nil
		})

	return s
}

// githubForRoot is the organization's GitHub client for the root's remote host.
func githubForRoot(ctx context.Context, root, thread string) (*wakilcore.GitHubClient, error) {
	if strings.TrimSpace(thread) == "" {
		return nil, wakilcore.UserError("no review thread named")
	}
	org, err := wakilcore.CurrentOrg()
	if err != nil {
		return nil, err
	}
	r, err := openRoot(ctx, org, root)
	if err != nil {
		return nil, err
	}
	if r.NotGitHub != "" {
		return nil, wakilcore.UserError(r.NotGitHub)
	}
	return wakilcore.NewGitHubFor(org, r.Host)
}

func main() {
	if err := newServer().Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}

// writeRecord applies one record edit. Only the fields the call gives change: the merge with
// the line's current text runs inside UpdateTicketRecord, under the ticket's lock, so an edit of
// one field never blanks the others and two edits of one line both land. An added ruling is open.
func writeRecord(org string, a recordWriteArg, now time.Time) (wakilcore.TicketRecord, error) {
	switch a.By {
	case "operator", "agent", "wakil":
	default:
		return wakilcore.TicketRecord{}, wakilcore.UserError("by is operator, agent or wakil, not " + strconvQuote(a.By))
	}
	var line wakilcore.TicketLine
	fields := []string{}
	for _, f := range []struct {
		name string
		from *string
		to   *string
	}{{"text", a.Line.Text, &line.Text}, {"why", a.Line.Why, &line.Why}, {"how", a.Line.How, &line.How},
		{"who", a.Line.Who, &line.Who}, {"what", a.Line.What, &line.What}, {"state", a.Line.State, &line.State}} {
		if f.from != nil {
			*f.to = *f.from
			fields = append(fields, f.name)
		}
	}
	if a.Op == "add" && a.Section == "rulings" && a.Line.State == nil {
		line.State = "open"
	}
	return wakilcore.UpdateTicketRecord(org, a.Key, wakilcore.TicketEdit{
		Section: a.Section, Op: a.Op, ID: a.ID, Line: line, Fields: fields, By: a.By, Conversation: a.Conversation,
	}, now)
}

// linkBranch links (or unlinks) the root's branch, then asks Jira whether it knows the key. The
// link is kept whatever Jira says (Rule 7).
func linkBranch(ctx context.Context, org string, a linkArg) (linkResult, error) {
	ctx, cancel := context.WithTimeout(ctx, readBudget)
	defer cancel()
	r, err := openRoot(ctx, org, a.Root)
	if err != nil {
		return linkResult{}, err
	}
	branch := strings.TrimSpace(a.Branch)
	if branch == "" {
		branch = r.Branch
	}
	if branch == "" {
		return linkResult{}, wakilcore.UserError("detached HEAD: no branch to link")
	}
	if r.RepoKey == "" {
		return linkResult{}, wakilcore.UserError("Not linked: a link is kept per repository, and " + strings.TrimPrefix(r.NotGitHub, "Pull requests not read: "))
	}
	key := strings.ToUpper(strings.TrimSpace(a.Key))
	if err := wakilcore.LinkTicket(org, r.RepoKey, branch, key); err != nil {
		return linkResult{}, err
	}
	if key == "" {
		return linkResult{}, nil
	}
	out := linkResult{Key: key, Linked: true}
	if res := newJiraReads(ctx, wakilcore.OrgProjectKeys(org)).get(key); res.notFound {
		out.NotFound = true
		out.Message = key + " was not found in Jira; the link is kept. " + res.err.Error()
	} else if res.err != nil {
		out.Message = "Jira was not asked whether it knows " + key + "; the link is kept. " + res.err.Error()
	}
	return out, nil
}

func strconvQuote(s string) string { return strconv.Quote(s) }
