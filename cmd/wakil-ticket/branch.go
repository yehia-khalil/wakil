package main

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yehia-khalil/wakil/internal/wakilcore"
)

// branch.go assembles ticket_branch and ticket_in_flight from local git, GitHub (the
// organization's git account) and Jira, each source failing alone (Rule 8).

// readBudget bounds one read, under the window's 20 s cancel so that a slow source comes back as
// a partial note rather than as the window's "Read stopped": GitHub's calls run inside it, and
// each Jira call gets at most jiraCallTimeout of it.
const readBudget = 15 * time.Second

// jiraCallTimeout bounds each Jira read (a var so a test can shorten it).
var jiraCallTimeout = 5 * time.Second

// seconds writes d as "5 s", or as Go writes it when it is not whole seconds.
func seconds(d time.Duration) string {
	if d%time.Second == 0 {
		return fmt.Sprintf("%d s", int(d/time.Second))
	}
	return d.String()
}

// SourceNote is a source that could not be read, and why, whole. Source is "github", "jira" or
// "git".
type SourceNote struct {
	Source  string `json:"source"`
	Message string `json:"message"`
}

// TicketRef is one ticket of a branch. Sources are where it was found, in linking order ("wakil",
// "branch", "pr", "trailer"), or "stack" for a ticket of a PR one step up or down the stack.
// Marked is the ticket the branch is for. Error is why its Jira read failed, if it did; the title
// and status are then the record's last read.
type TicketRef struct {
	Key      string                 `json:"key"`
	Title    string                 `json:"title"`
	Status   string                 `json:"status"`
	Assignee string                 `json:"assignee"`
	URL      string                 `json:"url"`
	Sources  []string               `json:"sources"`
	Marked   bool                   `json:"marked"`
	Record   wakilcore.TicketRecord `json:"record"`
	Error    string                 `json:"error,omitempty"`
}

// The pull request shapes as the window reads them. They mirror wakilcore's, with a summary
// type for the parent: an output schema cannot describe a type that holds itself.
type Comment struct {
	Author    string `json:"author"`
	Body      string `json:"body"`
	CreatedAt string `json:"createdAt"`
}

type Thread struct {
	ID         string    `json:"id"`
	Path       string    `json:"path"`
	Line       int       `json:"line"`
	Outdated   bool      `json:"outdated"`
	Resolved   bool      `json:"resolved"`
	Comments   []Comment `json:"comments"`
	ResolvedBy string    `json:"resolvedBy,omitempty"`
}

type Check struct {
	Name  string `json:"name"`
	State string `json:"state"`
	URL   string `json:"url,omitempty"`
}

type PRSummary struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	URL    string `json:"url"`
	State  string `json:"state"`
	Head   string `json:"head"`
	Base   string `json:"base"`
	Author string `json:"author"`
}

type PullRequest struct {
	Number             int        `json:"number"`
	Title              string     `json:"title"`
	Body               string     `json:"body"`
	URL                string     `json:"url"`
	State              string     `json:"state"`
	Head               string     `json:"head"`
	Base               string     `json:"base"`
	HeadSHA            string     `json:"headSHA"`
	Author             string     `json:"author"`
	Checks             []Check    `json:"checks"`
	Threads            []Thread   `json:"threads"`
	RequestedReviewers []string   `json:"requestedReviewers"`
	Parent             *PRSummary `json:"parent,omitempty"`
}

// TicketBranch is one root's branch. Repo is <host>/<owner>/<repo>, empty without a readable
// remote. Stack is the open PRs bottom to top (the parent, this branch's, those based on it), empty
// when the branch's PR stands alone.
type TicketBranch struct {
	Root      string        `json:"root"`
	Repo      string        `json:"repo"`
	Branch    string        `json:"branch"`
	Viewer    string        `json:"viewer"`
	LongLived bool          `json:"longLived"`
	Tickets   []TicketRef   `json:"tickets"`
	Looked    []string      `json:"looked"`
	Linked    bool          `json:"linked"`
	PRs       []PullRequest `json:"prs"`
	BasePRs   []PullRequest `json:"basePRs"`
	Stack     []int         `json:"stack"`
	Partial   []SourceNote  `json:"partial"`
}

// InFlightRow is one row of In flight or Waiting on you. State is the row's one state in words
// ("#212 · 2 threads", "checks failing"), composed here for the window to show as is.
type InFlightRow struct {
	Key    string `json:"key"`
	Title  string `json:"title"`
	Status string `json:"status"`
	State  string `json:"state"`
	Root   string `json:"root"`
	Branch string `json:"branch"`
	PR     int    `json:"pr"`
}

type InFlight struct {
	WaitingOnYou []InFlightRow `json:"waitingOnYou"`
	InFlight     []InFlightRow `json:"inFlight"`
	Partial      []SourceNote  `json:"partial"`
}

// orgRoots is every root of every project of the organization.
func orgRoots(org string) []string {
	reg, err := wakilcore.LoadRegistryFor(org)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(reg))
	for n := range reg {
		names = append(names, n)
	}
	sortStrings(names)
	var roots []string
	for _, n := range names {
		p, err := wakilcore.LoadProject(reg[n].Path)
		if err != nil {
			continue
		}
		roots = append(roots, wakilcore.ProjectRootPaths(wakilcore.Resolved{Org: org, Project: p, ProjectPath: reg[n].Path})...)
	}
	return roots
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// rootRepo is a root's local state and the GitHub repository it reads. NotGitHub is why pull
// requests are not read from the remote (empty when its host may be GitHub's): the remote is
// missing, unreadable or not GitHub.
type rootRepo struct {
	g                *wakilcore.GitRunner
	Root             string
	Branch, Detached string
	Local            []wakilcore.GitBranch
	Remote           string
	Host, Owner      string
	Name             string
	RepoKey          string
	NotGitHub        string
}

// openRoot reads the root's branch and its remote: the branch's upstream remote, else origin
// (forks are out). A root that is not one of the organization's is an error.
func openRoot(ctx context.Context, org, root string) (*rootRepo, error) {
	return openRootOn(ctx, org, root, "")
}

// openRootOn is openRoot reading `branch` as if it were the current one (a ticket picked from In
// flight); "" is the root's current branch. Nothing is checked out.
func openRootOn(ctx context.Context, org, root, branch string) (*rootRepo, error) {
	g, err := wakilcore.NewGitRunner(root, orgRoots(org))
	if err != nil {
		return nil, err
	}
	b, err := wakilcore.ReadBranches(ctx, g)
	if err != nil {
		return nil, err
	}
	r := &rootRepo{g: g, Root: g.Root, Branch: b.Current, Detached: b.Detached, Local: b.Local, Remote: "origin"}
	if branch = strings.TrimSpace(branch); branch != "" {
		r.Branch, r.Detached = branch, ""
	}
	if r.Branch != "" {
		if out, err := g.Run(ctx, "for-each-ref", "--format=%(upstream:remotename)", "refs/heads/"+r.Branch); err == nil {
			if name := strings.TrimSpace(string(out)); name != "" {
				r.Remote = name
			}
		}
	}
	raw, err := wakilcore.RemoteURLOf(r.Root, r.Remote)
	if err != nil {
		r.NotGitHub = "Pull requests not read: this root has no remote named " + r.Remote + "."
		return r, nil
	}
	remote, err := wakilcore.ParseRemoteURL(raw)
	if err != nil {
		r.NotGitHub = "Pull requests not read: " + err.Error()
		return r, nil
	}
	if remote.Scheme == "file" {
		r.NotGitHub = "Pull requests are read from GitHub only."
		return r, nil
	}
	parts := strings.Split(strings.TrimSuffix(strings.Trim(remote.Path, "/"), ".git"), "/")
	r.Host = wakilcore.RemoteHost(remote)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		r.NotGitHub = "Pull requests not read: the remote " + r.Remote + " names no owner/repository."
		return r, nil
	}
	r.Owner, r.Name = parts[0], parts[1]
	r.RepoKey = wakilcore.RepoKey(r.Host, r.Owner, r.Name)
	return r, nil
}

// defaultBranch is the remote's default (<remote>/HEAD), else a local main or master.
func (r *rootRepo) defaultBranch(ctx context.Context) string {
	if out, err := r.g.Run(ctx, "rev-parse", "--abbrev-ref", r.Remote+"/HEAD"); err == nil {
		if d, ok := strings.CutPrefix(strings.TrimSpace(string(out)), r.Remote+"/"); ok && d != "HEAD" {
			return d
		}
	}
	for _, d := range []string{"main", "master"} {
		if _, err := r.g.Run(ctx, "rev-parse", "--verify", "refs/heads/"+d); err == nil {
			return d
		}
	}
	return ""
}

// commitMessages are the messages of the branch's commits not on the default branch (at most
// 100): where `Ticket:` trailers are read.
func (r *rootRepo) commitMessages(ctx context.Context, def string) []string {
	if def == "" || def == r.Branch {
		return nil
	}
	base := def
	if _, err := r.g.Run(ctx, "rev-parse", "--verify", "refs/remotes/"+r.Remote+"/"+def); err == nil {
		base = r.Remote + "/" + def
	}
	out, err := r.g.Run(ctx, "log", "--format=%B", "-z", "--max-count=100", base+".."+r.Branch)
	if err != nil {
		return nil
	}
	var msgs []string
	for _, m := range strings.Split(string(out), "\x00") {
		if m = strings.TrimSpace(m); m != "" {
			msgs = append(msgs, m)
		}
	}
	return msgs
}

// github is the organization's client for the root's host, or the note saying why there is none.
func (r *rootRepo) github(org string) (*wakilcore.GitHubClient, *SourceNote) {
	if r.NotGitHub != "" {
		return nil, &SourceNote{Source: "github", Message: r.NotGitHub}
	}
	gh, err := wakilcore.NewGitHubFor(org, r.Host)
	if err != nil {
		return nil, &SourceNote{Source: "github", Message: err.Error()}
	}
	return gh, nil
}

// viewers caches the login a token belongs to, per endpoint, so a branch read after the first
// is one GraphQL query. A new token (another sign-in) is a new entry.
var viewers sync.Map

func viewerFor(ctx context.Context, gh *wakilcore.GitHubClient) string {
	k := gh.Endpoint + "\x00" + gh.Token
	if v, ok := viewers.Load(k); ok {
		return v.(string)
	}
	login, err := gh.Viewer(ctx)
	if err != nil || login == "" {
		return ""
	}
	viewers.Store(k, login)
	return login
}

// jiraReads fetches each ticket once, concurrently, under the read's context. A key's prefix must
// be one of the organization's project keys; Jira is then asked with that prefix.
type jiraReads struct {
	ctx  context.Context
	keys []string

	once      sync.Once
	client    *wakilcore.JiraClient
	clientErr error

	mu      sync.Mutex
	results map[string]*jiraResult
}

type jiraResult struct {
	done     chan struct{}
	issue    wakilcore.Issue
	err      error
	notFound bool
}

func newJiraReads(ctx context.Context, keys []string) *jiraReads {
	return &jiraReads{ctx: ctx, keys: keys, results: map[string]*jiraResult{}}
}

// start begins key's read if it has not begun.
func (j *jiraReads) start(key string) *jiraResult {
	j.mu.Lock()
	defer j.mu.Unlock()
	if res, ok := j.results[key]; ok {
		return res
	}
	res := &jiraResult{done: make(chan struct{})}
	j.results[key] = res
	go func() {
		defer close(res.done)
		prefix, _, _ := strings.Cut(key, "-")
		known := false
		for _, k := range j.keys {
			if k == prefix {
				known = true
			}
		}
		if !known {
			res.err, res.notFound = wakilcore.UserError("Not read from Jira: "+prefix+" is not a project key of this organization."), true
			return
		}
		j.once.Do(func() { j.client, j.clientErr = wakilcore.NewJiraFromEnv() })
		if j.clientErr != nil {
			res.err = j.clientErr
			return
		}
		ctx, cancel := context.WithTimeout(j.ctx, jiraCallTimeout)
		defer cancel()
		res.issue, res.err = j.client.GetIssue(ctx, prefix, key)
		if res.err != nil && ctx.Err() == context.DeadlineExceeded && j.ctx.Err() == nil {
			res.err = wakilcore.UserError("Jira did not answer within " + seconds(jiraCallTimeout))
		}
		res.notFound = res.err != nil && strings.HasPrefix(res.err.Error(), "issue not found: ")
	}()
	return res
}

func (j *jiraReads) get(key string) *jiraResult {
	res := j.start(key)
	<-res.done
	return res
}

// notes are the Jira failures that are not one ticket's own: Jira unreachable or unconfigured,
// each message once. A key Jira does not know is that ticket's error only.
func (j *jiraReads) notes() []SourceNote {
	j.mu.Lock()
	defer j.mu.Unlock()
	var out []SourceNote
	seen := map[string]bool{}
	for _, res := range j.results {
		<-res.done
		if res.err == nil || res.notFound || seen[res.err.Error()] {
			continue
		}
		seen[res.err.Error()] = true
		out = append(out, SourceNote{Source: "jira", Message: res.err.Error()})
	}
	sortNotes(out)
	return out
}

func sortNotes(n []SourceNote) {
	for i := 1; i < len(n); i++ {
		for j := i; j > 0 && n[j].Message < n[j-1].Message; j-- {
			n[j], n[j-1] = n[j-1], n[j]
		}
	}
}

// readTicketBranch is ticket_branch: local git first, then GitHub and Jira concurrently under one
// 20 s budget (a ticket found only in the PR's text is read from Jira once the PR is in).
func readTicketBranch(ctx context.Context, org, root, branch string, now time.Time) (TicketBranch, error) {
	ctx, cancel := context.WithTimeout(ctx, readBudget)
	defer cancel()
	r, err := openRootOn(ctx, org, root, branch)
	if err != nil {
		return TicketBranch{}, err
	}
	out := TicketBranch{Root: r.Root, Repo: r.RepoKey, Branch: r.Branch}
	if r.Branch == "" {
		out.Partial = []SourceNote{{Source: "git", Message: "detached HEAD: no branch to read"}}
		return out.normalized(), nil
	}
	keys := wakilcore.OrgProjectKeys(org)
	var link string
	if r.RepoKey != "" {
		link, out.Linked = wakilcore.TicketLinkFor(org, r.RepoKey, r.Branch)
	}
	def := r.defaultBranch(ctx)
	messages := r.commitMessages(ctx, def)

	jira := newJiraReads(ctx, keys)
	onDefault := r.Branch == def
	// Started before GitHub answers: the link, or the branch name's keys (a branch whose name
	// carries a key is never long-lived). Trailer keys wait for the long-lived check, since a
	// staging branch carries every merged commit's trailer.
	if !onDefault {
		if link != "" {
			jira.start(strings.ToUpper(link))
		} else {
			for _, k := range wakilcore.TicketKeysIn(r.Branch, keys) {
				jira.start(k)
			}
		}
	}

	var heads, bases []wakilcore.PullRequest
	gh, note := r.github(org)
	if note != nil {
		out.Partial = append(out.Partial, *note)
	} else {
		var wg sync.WaitGroup
		var ghErr error
		wg.Add(2)
		go func() { defer wg.Done(); heads, bases, ghErr = gh.BranchPRs(ctx, r.Owner, r.Name, r.Branch) }()
		go func() { defer wg.Done(); out.Viewer = viewerFor(ctx, gh) }()
		wg.Wait()
		if ghErr != nil {
			out.Partial = append(out.Partial, SourceNote{Source: "github", Message: ghErr.Error()})
		}
	}
	for _, p := range heads {
		out.PRs = append(out.PRs, pullRequest(p))
	}
	for _, p := range bases {
		out.BasePRs = append(out.BasePRs, pullRequest(p))
	}

	// The branch's PR: its newest open one, else its newest.
	var own *wakilcore.PullRequest
	for i := range heads {
		if isOpen(heads[i].State) {
			own = &heads[i]
			break
		}
	}
	if own == nil && len(heads) > 0 {
		own = &heads[0]
	}
	var open []wakilcore.PRHeadBase
	for _, p := range append(append([]wakilcore.PullRequest{}, heads...), bases...) {
		if isOpen(p.State) {
			open = append(open, wakilcore.PRHeadBase{Head: p.Head, Base: p.Base})
		}
		if p.Parent != nil && isOpen(p.Parent.State) {
			open = append(open, wakilcore.PRHeadBase{Head: p.Parent.Head, Base: p.Parent.Base})
		}
	}
	for _, b := range wakilcore.LongLivedBranches(def, open, keys) {
		if b == r.Branch {
			out.LongLived = true
		}
	}
	if out.LongLived {
		out.Partial = append(out.Partial, jira.notes()...)
		return out.normalized(), nil
	}

	prNumber, prTexts := 0, []string(nil)
	if own != nil {
		prNumber, prTexts = own.Number, []string{own.Title, own.Body}
	}
	matches, looked := wakilcore.MatchTickets(link, r.Branch, prNumber, prTexts, len(messages), messages, keys)
	out.Looked = looked

	sourcesOf := func(key string) []string {
		if link != "" {
			return []string{"wakil"}
		}
		var s []string
		if contains(wakilcore.TicketKeysIn(r.Branch, keys), key) {
			s = append(s, "branch")
		}
		if contains(wakilcore.TicketKeysIn(strings.Join(prTexts, "\n"), keys), key) {
			s = append(s, "pr")
		}
		if contains(wakilcore.TrailerKeys(messages, keys), key) {
			s = append(s, "trailer")
		}
		return s
	}
	var ownPRs []wakilcore.TicketPRRef
	for _, p := range heads {
		ownPRs = append(ownPRs, wakilcore.TicketPRRef{Repo: r.RepoKey, Number: p.Number, State: p.State})
	}
	type found struct {
		key     string
		sources []string
		prs     []wakilcore.TicketPRRef
		stack   bool
	}
	var tickets []found
	have := map[string]bool{}
	for _, m := range matches {
		have[m.Key] = true
		jira.start(m.Key)
		tickets = append(tickets, found{key: m.Key, sources: sourcesOf(m.Key), prs: ownPRs})
	}
	// The tickets the stack carries: the PR one step down and those one step up.
	var stackPRs []wakilcore.PullRequest
	if own != nil && own.Parent != nil {
		stackPRs = append(stackPRs, *own.Parent)
	}
	stackPRs = append(stackPRs, bases...)
	for _, p := range stackPRs {
		for _, k := range wakilcore.TicketKeysIn(p.Head+"\n"+p.Title, keys) {
			if have[k] {
				continue
			}
			have[k] = true
			jira.start(k)
			tickets = append(tickets, found{key: k, sources: []string{"stack"}, stack: true,
				prs: []wakilcore.TicketPRRef{{Repo: r.RepoKey, Number: p.Number, State: p.State}}})
		}
	}

	at := now.UTC().Format(time.RFC3339)
	for i, t := range tickets {
		res := jira.get(t.key)
		ref := TicketRef{Key: t.key, Sources: t.sources, Marked: i == 0 && !t.stack}
		var seen wakilcore.TicketSeen
		if res.err == nil {
			seen = wakilcore.TicketSeen{Title: res.issue.Summary, Status: res.issue.Status, Assignee: res.issue.Assignee, URL: res.issue.URL, At: at}
		} else {
			ref.Error = res.err.Error()
		}
		var branches []wakilcore.TicketBranchRef
		if !t.stack && r.RepoKey != "" {
			branches = []wakilcore.TicketBranchRef{{Repo: r.RepoKey, Branch: r.Branch, Source: t.sources[0]}}
		}
		prs := t.prs
		if r.RepoKey == "" {
			prs = nil
		}
		if err := wakilcore.RecordTicketSeen(org, t.key, seen, branches, prs); err != nil && ref.Error == "" {
			ref.Error = "The record was not updated: " + err.Error()
		}
		rec, err := wakilcore.ReadTicketRecord(org, t.key)
		if err != nil {
			if ref.Error == "" {
				ref.Error = err.Error()
			}
			rec = emptyRecord(t.key)
		}
		ref.Record = rec
		ref.Title, ref.Status, ref.Assignee, ref.URL = rec.Seen.Title, rec.Seen.Status, rec.Seen.Assignee, rec.Seen.URL
		out.Tickets = append(out.Tickets, ref)
	}
	out.Partial = append(out.Partial, jira.notes()...)

	if own != nil && isOpen(own.State) {
		var chain []int
		if own.Parent != nil && isOpen(own.Parent.State) {
			chain = append(chain, own.Parent.Number)
		}
		chain = append(chain, own.Number)
		for _, b := range bases {
			chain = append(chain, b.Number)
		}
		if len(chain) > 1 {
			out.Stack = chain
		}
	}
	return out.normalized(), nil
}

func isOpen(state string) bool { return state == "open" || state == "blocked" }

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// readInFlight is ticket_in_flight: each root's local branches that carry a ticket, and per
// GitHub host one search of the operator's open PRs and the PRs asking for their review.
func readInFlight(ctx context.Context, org string) InFlight {
	ctx, cancel := context.WithTimeout(ctx, readBudget)
	defer cancel()
	var out InFlight
	keys := wakilcore.OrgProjectKeys(org)
	jira := newJiraReads(ctx, keys)

	type rowAt struct {
		row  InFlightRow
		repo string
	}
	var rows []rowAt
	owners := map[string]map[string]bool{} // GitHub host -> owners
	rootOf := map[string]string{}          // repo key -> the first root on it
	var hosts []string
	for _, root := range orgRoots(org) {
		r, err := openRoot(ctx, org, root)
		if err != nil {
			continue
		}
		if r.NotGitHub == "" {
			if owners[r.Host] == nil {
				owners[r.Host] = map[string]bool{}
				hosts = append(hosts, r.Host)
			}
			owners[r.Host][r.Owner] = true
			if _, ok := rootOf[r.RepoKey]; !ok {
				rootOf[r.RepoKey] = r.Root
			}
		}
		for _, b := range r.Local {
			key := ""
			if r.RepoKey != "" {
				key, _ = wakilcore.TicketLinkFor(org, r.RepoKey, b.Name)
			}
			if key == "" {
				if found := wakilcore.TicketKeysIn(b.Name, keys); len(found) > 0 {
					key = found[0]
				}
			}
			if key == "" {
				continue
			}
			jira.start(key)
			rows = append(rows, rowAt{row: InFlightRow{Key: key, State: "local branch", Root: r.Root, Branch: b.Name}, repo: r.RepoKey})
		}
	}

	type hostPRs struct {
		authored, requested []wakilcore.PullRequest
		note                *SourceNote
	}
	results := make([]hostPRs, len(hosts))
	var wg sync.WaitGroup
	for i, host := range hosts {
		var list []string
		for o := range owners[host] {
			list = append(list, o)
		}
		sortStrings(list)
		wg.Add(1)
		go func(i int, host string, list []string) {
			defer wg.Done()
			gh, err := wakilcore.NewGitHubFor(org, host)
			if err != nil {
				results[i].note = &SourceNote{Source: "github", Message: err.Error()}
				return
			}
			a, q, err := gh.MyOpenPRs(ctx, list)
			results[i].authored, results[i].requested = a, q
			if err != nil {
				results[i].note = &SourceNote{Source: "github", Message: err.Error()}
			}
		}(i, host, list)
	}
	wg.Wait()

	prKey := func(p wakilcore.PullRequest) string {
		for _, text := range []string{p.Head, p.Title, p.Body} {
			if found := wakilcore.TicketKeysIn(text, keys); len(found) > 0 {
				return found[0]
			}
		}
		return ""
	}
	var waiting []InFlightRow
	for i, host := range hosts {
		res := results[i]
		if res.note != nil {
			out.Partial = append(out.Partial, *res.note)
		}
		for _, p := range res.authored {
			repo := repoOfPR(host, p.URL)
			root := rootOf[repo]
			key := prKey(p)
			if key != "" {
				jira.start(key)
			}
			state := fmt.Sprintf("#%d · %s", p.Number, p.State)
			matched := false
			for j := range rows {
				if rows[j].repo == repo && rows[j].row.Branch == p.Head {
					rows[j].row.PR, rows[j].row.State = p.Number, state
					matched = true
				}
			}
			if !matched && key != "" {
				rows = append(rows, rowAt{row: InFlightRow{Key: key, State: state, Root: root, Branch: p.Head, PR: p.Number}, repo: repo})
			}
			// The viewer wrote the PR, so their login is its author.
			threads, failing := 0, false
			for _, t := range p.Threads {
				if t.Resolved || t.Outdated || len(t.Comments) == 0 {
					continue
				}
				if t.Comments[len(t.Comments)-1].Author != p.Author {
					threads++
				}
			}
			for _, c := range p.Checks {
				if c.State == "failure" {
					failing = true
				}
			}
			switch {
			case threads > 0:
				noun := "threads"
				if threads == 1 {
					noun = "thread"
				}
				waiting = append(waiting, InFlightRow{Key: key, State: fmt.Sprintf("#%d · %d %s", p.Number, threads, noun), Root: root, Branch: p.Head, PR: p.Number, Title: p.Title})
			case failing:
				waiting = append(waiting, InFlightRow{Key: key, State: "checks failing", Root: root, Branch: p.Head, PR: p.Number, Title: p.Title})
			}
		}
		for _, p := range res.requested {
			key := prKey(p)
			if key != "" {
				jira.start(key)
			}
			waiting = append(waiting, InFlightRow{Key: key, State: "review requested", Root: rootOf[repoOfPR(host, p.URL)], Branch: p.Head, PR: p.Number, Title: p.Title})
		}
	}

	fill := func(row *InFlightRow) {
		if row.Key == "" {
			return
		}
		if res := jira.get(row.Key); res.err == nil {
			row.Title, row.Status = res.issue.Summary, res.issue.Status
		} else if rec, err := wakilcore.ReadTicketRecord(org, row.Key); err == nil && rec.Seen.Title != "" {
			row.Title, row.Status = rec.Seen.Title, rec.Seen.Status
		}
	}
	for _, r := range rows {
		row := r.row
		fill(&row)
		out.InFlight = append(out.InFlight, row)
	}
	for _, row := range waiting {
		fill(&row)
		out.WaitingOnYou = append(out.WaitingOnYou, row)
	}
	out.Partial = append(out.Partial, jira.notes()...)
	if out.WaitingOnYou == nil {
		out.WaitingOnYou = []InFlightRow{}
	}
	if out.InFlight == nil {
		out.InFlight = []InFlightRow{}
	}
	if out.Partial == nil {
		out.Partial = []SourceNote{}
	}
	return out
}

// repoOfPR is a PR's repository key, from its URL (https://<host>/<owner>/<repo>/pull/<n>).
func repoOfPR(host, prURL string) string {
	u, err := url.Parse(prURL)
	if err != nil {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 {
		return ""
	}
	return wakilcore.RepoKey(host, parts[0], parts[1])
}

func comment(c wakilcore.ReviewComment) Comment {
	return Comment{Author: c.Author, Body: c.Body, CreatedAt: c.CreatedAt}
}

// pullRequest is p as the window reads it, every list an array.
func pullRequest(p wakilcore.PullRequest) PullRequest {
	out := PullRequest{
		Number: p.Number, Title: p.Title, Body: p.Body, URL: p.URL, State: p.State, Head: p.Head, Base: p.Base,
		HeadSHA: p.HeadSHA, Author: p.Author,
		Checks: []Check{}, Threads: []Thread{}, RequestedReviewers: append([]string{}, p.RequestedReviewers...),
	}
	for _, c := range p.Checks {
		out.Checks = append(out.Checks, Check{Name: c.Name, State: c.State, URL: c.URL})
	}
	for _, t := range p.Threads {
		th := Thread{ID: t.ID, Path: t.Path, Line: t.Line, Outdated: t.Outdated, Resolved: t.Resolved, ResolvedBy: t.ResolvedBy, Comments: []Comment{}}
		for _, c := range t.Comments {
			th.Comments = append(th.Comments, comment(c))
		}
		out.Threads = append(out.Threads, th)
	}
	if q := p.Parent; q != nil {
		out.Parent = &PRSummary{Number: q.Number, Title: q.Title, URL: q.URL, State: q.State, Head: q.Head, Base: q.Base, Author: q.Author}
	}
	return out
}

// normalized writes every list as an array, never null.
func (b TicketBranch) normalized() TicketBranch {
	if b.Tickets == nil {
		b.Tickets = []TicketRef{}
	}
	for i := range b.Tickets {
		if b.Tickets[i].Sources == nil {
			b.Tickets[i].Sources = []string{}
		}
	}
	if b.Looked == nil {
		b.Looked = []string{}
	}
	if b.PRs == nil {
		b.PRs = []PullRequest{}
	}
	if b.BasePRs == nil {
		b.BasePRs = []PullRequest{}
	}
	if b.Stack == nil {
		b.Stack = []int{}
	}
	if b.Partial == nil {
		b.Partial = []SourceNote{}
	}
	return b
}

// emptyRecord is a record with nothing in it, its lists arrays: what a record that cannot be
// read is shown as.
func emptyRecord(key string) wakilcore.TicketRecord {
	return wakilcore.TicketRecord{Key: key, Branches: []wakilcore.TicketBranchRef{}, PRs: []wakilcore.TicketPRRef{},
		Decisions: []wakilcore.TicketLine{}, NotDone: []wakilcore.TicketLine{}, WaitingOn: []wakilcore.TicketLine{},
		Verified: []wakilcore.TicketLine{}, Rulings: []wakilcore.TicketLine{}}
}
