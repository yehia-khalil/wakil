package main

import (
	"context"
	"errors"
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
	Root         string  `json:"root,omitempty" jsonschema:"a root of one of the organization's projects the ticket is worked in"`
	Branch       string  `json:"branch,omitempty" jsonschema:"the branch the ticket is worked on in root; with root, the record gains it"`
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
	// Errors are GitHub's errors answered beside the posted comment, each whole; the reply is
	// posted all the same.
	Errors []string `json:"errors"`
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

type draftWriteArg struct {
	Thread       string `json:"thread" jsonschema:"the review thread's GitHub node id"`
	Text         string `json:"text,omitempty" jsonschema:"the draft reply; left out or empty removes the thread's draft"`
	By           string `json:"by" jsonschema:"operator or agent: who the window's dispatch came from"`
	Conversation string `json:"conversation,omitempty" jsonschema:"an agent draft's conversation"`
	Root         string `json:"root,omitempty" jsonschema:"the root the draft was written in"`
	Branch       string `json:"branch,omitempty" jsonschema:"the branch the draft was written on"`
}

type draftsResult struct {
	Drafts map[string]wakilcore.TicketDraft `json:"drafts" jsonschema:"each review thread's draft, by thread id"`
}

// noDrafts is a refusal's output: drafts is an object even then, as the output schema says.
func noDrafts() draftsResult { return draftsResult{Drafts: map[string]wakilcore.TicketDraft{}} }

// handoffArg is the hand-off the window started; its id, time, May push and end are Wakil's.
type handoffArg struct {
	Conversation string          `json:"conversation" jsonschema:"the handed conversation's id"`
	Title        string          `json:"title,omitempty" jsonschema:"the conversation's title, the brief's first line"`
	Thread       string          `json:"thread,omitempty" jsonschema:"the review thread it was handed from; empty from the header or ⌘P"`
	Harness      string          `json:"harness" jsonschema:"the harness Start ran"`
	Provider     string          `json:"provider" jsonschema:"the provider binding Start used"`
	Place        wakilcore.Place `json:"place,omitempty" jsonschema:"where the conversation runs"`
}

type handoffWriteArg struct {
	Op            string      `json:"op" jsonschema:"add, end or carry"`
	Key           string      `json:"key,omitempty" jsonschema:"add: the ticket key, or pr:<host>/<owner>/<repo>#<n> for a PR with no ticket key"`
	Handoff       *handoffArg `json:"handoff,omitempty" jsonschema:"add: the hand-off"`
	MayPush       bool        `json:"mayPush,omitempty" jsonschema:"add: the operator's May push switch at Start"`
	Conversations []string    `json:"conversations,omitempty" jsonschema:"end: the conversations whose hand-offs end, or with keepLive the live ones to keep"`
	KeepLive      bool        `json:"keepLive,omitempty" jsonschema:"end: end every open hand-off whose conversation is not listed"`
	From          string      `json:"from,omitempty" jsonschema:"carry: the handed conversation a resume started from"`
	To            string      `json:"to,omitempty" jsonschema:"carry: the new conversation the resume started"`
}

type handoffWriteResult struct {
	Carried *bool                    `json:"carried,omitempty" jsonschema:"carry: whether from was handed and its hand-off carried; false says, explicitly, there was none"`
	Key     string                   `json:"key,omitempty" jsonschema:"carry: the ticket key, or pr:<host>/<owner>/<repo>#<n>, the hand-off is kept by"`
	Handoff *wakilcore.TicketHandoff `json:"handoff,omitempty" jsonschema:"add: the hand-off as kept, with its id; carry: the new conversation's, none when from was never handed"`
}

type conversationArg struct {
	Conversation string `json:"conversation" jsonschema:"a conversation's id"`
}

type mayPushResult struct {
	MayPush bool `json:"mayPush" jsonschema:"on only when exactly one stored hand-off names the conversation and it says on"`
}

type handoffDefaultsResult struct {
	Defaults wakilcore.HandoffDefaults `json:"defaults"`
	Found    bool                      `json:"found" jsonschema:"whether a Start was ever made in this organization"`
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

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_in_flight", Description: "Read-only. The organization's tickets in flight (a local branch in any of its roots, or an open PR of yours) and Waiting on you (threads on your open PRs whose last word is not yours, PRs asking for your review, your PRs with a failing check), each with one state in words. Waiting on you is one row per PR carrying every reason — threads (the waiting thread ids), failing (failing check names), review (asks for your review), activity (newest change, RFC 3339) and count (1 per thread, 1 for any failing check, 1 for the review) — including PRs with no ticket key (key \"\") and review requests on repositories no project holds (root \"\", url to open on GitHub); count on the reply is the sum."},
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

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_record_write", Description: "Writes. Sets a ticket's next line, or adds, edits or removes one line of a list. Only from the Wakil window. The old line is kept in the record's log. An edit changes only the fields given. With root and branch, the record also gains that branch (by Wakil); a branch without a root is ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a recordWriteArg) (*mcp.CallToolResult, wakilcore.TicketRecord, error) {
			if err := assertWindow("ticket_record_write"); err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), wakilcore.TicketRecord{}, nil
			}
			r, err := writeRecordAt(ctx, org, a, time.Now())
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
			errs := []string{}
			var ge *wakilcore.GraphQLError
			if errors.As(err, &ge) {
				errs = append(errs, ge.Messages...)
			} else if err != nil {
				return toolErr(err), replyResult{}, nil
			}
			return nil, replyResult{Comment: comment(c), Errors: errs}, nil
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

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_drafts", Description: "Read-only. The organization's reply drafts by review thread id: text, who wrote it (operator or agent), an agent's conversation, the root and branch it was written in, when, and the operator's text an agent's draft replaced."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, draftsResult, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), noDrafts(), nil
			}
			m, err := wakilcore.ReadTicketDrafts(org)
			if err != nil {
				return toolErr(err), noDrafts(), nil
			}
			return nil, draftsResult{Drafts: m}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_draft_write", Description: "Writes. Sets a review thread's reply draft, or removes it when text is left out or empty. Only from the Wakil window. An agent's draft over the operator's keeps the operator's text as replaced; the operator's draft clears it. An agent's removal of a draft holding the operator's text is refused. Answers every draft."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a draftWriteArg) (*mcp.CallToolResult, draftsResult, error) {
			if err := assertWindow("ticket_draft_write"); err != nil {
				return toolErr(err), noDrafts(), nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), noDrafts(), nil
			}
			// A removal carries its by too: an agent's may not remove the operator's text.
			d := &wakilcore.TicketDraft{Text: a.Text, By: a.By, Conversation: a.Conversation, Root: a.Root, Branch: a.Branch}
			m, err := wakilcore.WriteTicketDraft(org, a.Thread, d, time.Now())
			if err != nil {
				return toolErr(err), noDrafts(), nil
			}
			return nil, draftsResult{Drafts: m}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_handoff_write", Description: "Writes. add keeps a hand-off in the ticket's record (a PR with no ticket key: by its PR, no record) with its May push, and makes its harness, provider and May push the organization's defaults; end marks open hand-offs ended: the conversations listed, or with keepLive every one not listed; carry gives conversation to the hand-off of conversation from (a resume into a new conversation), May push as from reads it, the defaults untouched. Only from the Wakil window."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a handoffWriteArg) (*mcp.CallToolResult, handoffWriteResult, error) {
			if err := assertWindow("ticket_handoff_write"); err != nil {
				return toolErr(err), handoffWriteResult{}, nil
			}
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), handoffWriteResult{}, nil
			}
			out, err := writeHandoff(org, a, time.Now())
			if err != nil {
				return toolErr(err), handoffWriteResult{}, nil
			}
			return nil, out, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_handoff_may_push", Description: "Read-only. A conversation's May push, from its stored hand-off: on only when exactly one hand-off names it and it says on; anything else, an unreadable file included, is off."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a conversationArg) (*mcp.CallToolResult, mayPushResult, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), mayPushResult{}, nil
			}
			return nil, mayPushResult{MayPush: wakilcore.TicketHandoffMayPush(org, strings.TrimSpace(a.Conversation))}, nil
		})

	mcp.AddTool(s, &mcp.Tool{Name: "ticket_handoff_defaults", Description: "Read-only. The harness, provider and May push the organization's last hand-off started with, and whether there was one."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ empty) (*mcp.CallToolResult, handoffDefaultsResult, error) {
			org, err := wakilcore.CurrentOrg()
			if err != nil {
				return toolErr(err), handoffDefaultsResult{}, nil
			}
			d, found, err := wakilcore.ReadHandoffDefaults(org)
			if err != nil {
				return toolErr(err), handoffDefaultsResult{}, nil
			}
			return nil, handoffDefaultsResult{Defaults: d, Found: found}, nil
		})

	return s
}

// writeHandoff is ticket_handoff_write: an add answers the hand-off as kept, its id assigned.
func writeHandoff(org string, a handoffWriteArg, now time.Time) (handoffWriteResult, error) {
	switch a.Op {
	case "add":
		if a.Handoff == nil {
			return handoffWriteResult{}, wakilcore.UserError("an add needs its hand-off")
		}
		h := a.Handoff
		r, err := wakilcore.AddTicketHandoff(org, strings.TrimSpace(a.Key), wakilcore.TicketHandoff{
			Conversation: h.Conversation, Title: h.Title, Thread: h.Thread, Harness: h.Harness, Provider: h.Provider, Place: h.Place,
		}, a.MayPush, now)
		if err != nil {
			return handoffWriteResult{}, err
		}
		added := r.Handoffs[len(r.Handoffs)-1]
		return handoffWriteResult{Handoff: &added}, nil
	case "end":
		return handoffWriteResult{}, wakilcore.EndTicketHandoffs(org, a.Conversations, a.KeepLive, now)
	case "carry":
		key, h, err := wakilcore.CarryTicketHandoff(org, strings.TrimSpace(a.From), strings.TrimSpace(a.To), now)
		if err != nil {
			return handoffWriteResult{}, err
		}
		carried := h != nil
		return handoffWriteResult{Key: key, Handoff: h, Carried: &carried}, nil
	}
	return handoffWriteResult{}, wakilcore.UserError("a hand-off op is add, end or carry, not " + strconvQuote(a.Op))
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

// writeRecordAt is writeRecord for a line that may name its place: with root and branch, the
// root is checked against the organisation's roots before anything is written, and after the line
// the record gains the branch (Source "wakil"), added or updated and never dropping another. A
// branch without a root names no place and is ignored (Rule 7); so is a root with no GitHub remote,
// whose branches the record cannot key.
func writeRecordAt(ctx context.Context, org string, a recordWriteArg, now time.Time) (wakilcore.TicketRecord, error) {
	root, branch := strings.TrimSpace(a.Root), strings.TrimSpace(a.Branch)
	if root == "" || branch == "" {
		return writeRecord(org, a, now)
	}
	ctx, cancel := context.WithTimeout(ctx, readBudget)
	defer cancel()
	r, err := openRootOn(ctx, org, root, branch)
	if err != nil {
		return wakilcore.TicketRecord{}, err
	}
	rec, err := writeRecord(org, a, now)
	if err != nil || r.RepoKey == "" {
		return rec, err
	}
	ref := wakilcore.TicketBranchRef{Repo: r.RepoKey, Branch: branch, Source: "wakil"}
	if err := wakilcore.RecordTicketSeen(org, a.Key, wakilcore.TicketSeen{}, []wakilcore.TicketBranchRef{ref}, nil); err != nil {
		return wakilcore.TicketRecord{}, err
	}
	return wakilcore.ReadTicketRecord(org, a.Key)
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
