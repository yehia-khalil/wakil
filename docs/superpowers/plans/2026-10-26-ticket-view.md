# Ticket View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fourth view in the editor's left column, **Ticket**, that joins the branch's ticket (Jira), its pull requests, review threads and checks (GitHub) and Wakil's own ticket record; and each open review thread drawn in the file under its line, with Reply and Resolve.

**Architecture:** A new window-owned Go binary, `cmd/wakil-ticket`, reads local git, GitHub's GraphQL API with the organization's git account credential and Jira through `wakilcore.JiraClient`, and keeps the ticket record as files under the org folder (`internal/wakilcore/ticketrecord.go`, `ticketlink.go`, `githubreview.go`). WakilKit holds the reads per (root, branch), the drafts and every pure decision in `Editor/` (`EditorTicket*.swift`) and registers the actions; `WakilApp` draws the column view and the page draws the review boxes the way it draws conflict rows. An SSH GitHub account gains an optional **API access** row in Settings → Organisation → Git, stored at its own `git-<host>-token`.

**Tech Stack:** Go 1.27 (`net/http` to GitHub GraphQL, the forked MCP go-sdk), Swift (WakilKit, WakilApp, SwiftUI), Monaco in `monaco-host.html`.

**Spec:** `docs/superpowers/specs/2026-10-26-ticket-view-design.md` (umbrella piece 2: `docs/superpowers/specs/2026-10-25-ticket-work-design.md`).

## Global Constraints

- `wakil-ticket` is **window-owned** only: `WakilWiring.build`, `wakilOwnedClients`, `PlaceClients` pinned per place; never in `agentFacingServers`. Its write tools (`ticket_record_write`, `ticket_link`, `review_reply`, `review_resolve`) answer only when `wakilcore.InWakilWindow()` (`WAKIL_IN_WINDOW=1`).
- GitHub is read and written **only** with the organization's git account for the remote's host whose provider is `github`: Sign in or token → `git-<host>-token`; SSH → its API access, the same ref. Never `gh`, never a connection. `WAKIL_GITHUB_API` overrides the GraphQL endpoint; default `https://api.github.com/graphql` for `github.com`, `https://<host>/api/graphql` otherwise.
- SSH account without API access, copy: `Pull requests not read: this organization's <host> account signs in with SSH, which reads no pull requests. Add API access to the GitHub account in Settings → Organisation → Git.` A non-GitHub remote: `Pull requests are read from GitHub only.`
- A key counts only when its prefix is a `scopes.pm.projectKey` of any project of the organization, matched case-insensitively, written uppercase. No PM connection → nothing inferred; a link made in Wakil still counts.
- Linking sources in order: `wakil` (link made in Wakil), `branch`, `pr` (title and body), `trailer` (`Ticket: INI-142`). The Jira development panel is not read.
- Storage: `<OrgDirFor(org)>/tickets/<KEY>.json`, `<KEY>.log.jsonl` (append-only, the old line written before each change), `tickets/links.json` keyed `<host>/<owner>/<repo>:<branch>`. Writes are temp file + rename.
- `by` is set by WakilKit from `ActionRegistry.dispatchOrigin`: `ui` → `operator`, `agent` → `agent`, `debug` → `wakil`; an agent line carries `dispatchCaller?.conversation`. The caller never passes `by`.
- Prices: `ticket_link`, `ticket_record_update` `(production: .allow, otherwise: .allow)`; `review_reply_send` `(.gate, .gate)`; `review_resolve` `(.allow, .allow)` with `agentPrice: .gate`. All `.agentReachable`.
- Reads: no timer. Triggers are the spec's *When it reads* table; activation re-reads only when the last read is over **60 s** old with the Ticket view showing; a read past **20 s** is cancelled and says `Read stopped after 20 s. ↻ reads again.`; one read per (root, branch) in flight.
- Comment text reaches the page as data and is set with `textContent`, never `innerHTML`.
- ⌥↓ / ⌥↑ step threads only while focus is in a review box or the Ticket column; in the text they stay Monaco's Move Line Down / Up.
- No **Hand to agent** button, not even disabled. No PM writes. No new top-level comment, review, edit, delete or merge on GitHub.
- Forks are out: `ticket_branch` reads the branch's upstream remote's repository, else `origin`.
- Interaction Rules 1–9 as in the spec's table. Public repo: example names only (`initech/api`, `INI-142`); `scripts/public-check.sh` passes.

## Review Focus

1. **A root whose remote is not GitHub, has no remote, or is on a detached HEAD** — the view shows the local branch state and the one-line reason; nothing else errors. (Task 5 tests `TestTicketBranchNonGitHubRemoteSaysSo`, `TestTicketBranchDetachedHeadReadsNothingRemote`.)
2. **GitHub answers `data` and `errors` together** (SAML enforcement on one repository, a rate limit) — the errors are shown whole as a partial source, the data that came is shown. (Task 4 test `TestGraphQLErrorsBesideDataAreKeptWhole`.)
3. **The agent and the operator write the same record at once** — both lines land; neither is lost. (Task 2 test `TestConcurrentWritesKeepBothLines`.)
4. **An org switch while a read is in flight** — the old org's result is dropped, drafts and cache are empty in the new org. (Task 6 test `aReadFromTheOldOrgIsDropped`.)
5. **A thread whose line is past the buffer's end** (the file was cut down locally) — drawn under the last line with "line changed since", never off the model. (Task 7 test `aLinePastTheBufferEndDrawsAtTheLastLine`.)

## Execution order

1 → 2, 3, 4 (independent) → 5 → 6 → 7 → 8; 9 after 1, any time; 10 last. Then the whole-branch review, **Cover**, **Walk**.

---

### Task 1: An SSH GitHub account's API access (Go)

**Files:**
- Modify: `internal/wakilcore/gitaccounts.go` (`GitAccount.APIAccess string \`json:"apiAccess,omitempty"\`` — `""`, `"signin"` or `"token"`; only on `Method == "ssh"`), `internal/wakilcore/gitoauth.go`, `internal/wakilcore/gitaccountsetup.go`, `cmd/wakil-ctx/main.go`, `internal/wakilcore/configtree.go` (carries `apiAccess`, never the token)
- Test: `internal/wakilcore/gitaccounts_test.go`, `internal/wakilcore/gitaccountsetup_test.go`, `cmd/wakil-ctx/main_test.go`, `cmd/wakil-ctx/schema_test.go`

**Interfaces:**
- Produces:
  ```go
  func SetGitAPIAccessToken(org, host, token string) error   // ssh github account only; keeps Method, sets APIAccess "token"
  func FinishAPIAccessSignIn(org, host, token string) error  // same, APIAccess "signin"
  func RemoveGitAPIAccess(org, host string) error            // deletes git-<host>-token, clears APIAccess
  func GitHubTokenFor(org, host string) (string, error)       // the one resolver wakil-ticket uses
  func TestGitAPIAccess(ctx context.Context, org, host string) (string, error) // GET gitUserAPI["github"] with the token
  ```
  `GitHubTokenFor` errors (`UserError`, exact copy): no account → `Pull requests not read: this organization has no git account for <host>. Add one in Settings → Organisation → Git.`; provider not `github` → `Pull requests are read from GitHub only.`; SSH without API access → the Global Constraints copy; token missing → `no token kept for <host>`.
- `wakil-ctx` tools: `git_api_access_token_set {id, host, token}` (secret `token`), `git_api_access_remove {id, host}`, `git_api_access_test {id, host}` → `{user}`; `git_device_poll` gains `apiAccess bool` (true → `FinishAPIAccessSignIn` instead of `FinishSignIn`).

- [ ] **Step 1: Write the failing tests** — `TestAPIAccessTokenKeepsSSHMethod` (ssh account, set token → Method `ssh`, APIAccess `token`, `RemoteInvocation` still the ssh command); `TestAPIAccessRefusedOnNonSSHOrNonGitHub` (`UserError`); `TestGitHubTokenForEachMethod` (signin, token, ssh+apiAccess → the token; ssh without → the exact SSH copy; gitlab → `Pull requests are read from GitHub only.`); `TestRemoveGitAPIAccessKeepsTheAccount`; `TestRemoveGitAccountAlsoDropsAPIAccessToken` (existing ref list covers it — assert); `TestDevicePollAPIAccessDoesNotRewriteMethod` (wakil-ctx); `TestConfigTreeCarriesAPIAccessNotToken`; schema test lists the three tools. Use the secrets seam `gitaccounts_test.go` uses; `gitUserAPI` is already overridable.
- [ ] **Step 2:** `go test ./internal/wakilcore ./cmd/wakil-ctx -run 'APIAccess|GitHubToken|DevicePoll|ConfigTree|Schema'` → FAIL (undefined).
- [ ] **Step 3: Implement** beside `SetGitToken` / `FinishSignIn` / `TestGitAccount`, same `toolErr` shape.
- [ ] **Step 4:** same command → PASS; `go vet ./...` clean.
- [ ] **Step 5: Commit** `ticket view: an SSH GitHub account can carry API access, kept at its own token ref`.

### Task 2: The ticket record

**Files:**
- Create: `internal/wakilcore/ticketrecord.go`, `internal/wakilcore/ticketrecord_test.go`

**Interfaces:**
- Produces (JSON exactly the spec's record shape):
  ```go
  type TicketLine struct { ID, Text, Why, How, Who, What, State, By, Conversation, At string; Edited string `json:"edited,omitempty"` } // omitempty on all but ID, By, At
  type TicketSeen struct { Title, Status, Assignee, URL, At string }
  type TicketBranchRef struct { Repo, Branch, Source string }
  type TicketPRRef struct { Repo string; Number int; State string }
  type TicketRecord struct {
      Key string; Seen TicketSeen; Branches []TicketBranchRef; PRs []TicketPRRef
      Next *TicketLine; Decisions, NotDone, WaitingOn, Verified, Rulings []TicketLine
  }
  type TicketEdit struct {
      Section string // "next" | "decisions" | "notDone" | "waitingOn" | "verified" | "rulings"
      Op      string // "set" (next only) | "add" | "edit" | "remove"
      ID      string // edit, remove
      Line    TicketLine // text fields only; By, Conversation from the caller below
      By, Conversation string
  }
  func ReadTicketRecord(org, key string) (TicketRecord, error)            // absent → {Key: key}, no file written
  func UpdateTicketRecord(org, key string, e TicketEdit, now time.Time) (TicketRecord, error)
  func RecordTicketSeen(org, key string, seen TicketSeen, b []TicketBranchRef, prs []TicketPRRef) error // merges; never drops a branch or PR
  ```
  IDs: section letter + next free number (`d1`, `n1`, `w1`, `v1`, `r1`). An edit by `agent` of a line whose `By` is `operator` keeps `By: operator` and sets `Edited: "agent"`. Remove asks nothing and refuses nothing for a known id; an unknown id is a `UserError` naming it.
  Log line before each change: `{"at","by","section","op","id","old":<line or null>}`.

- [ ] **Step 1: Write the failing tests** — `TestReadAbsentRecordWritesNothing`; `TestAddAssignsNextId` (`d1`, `d2`, after removing `d1` the next is `d3`); `TestSetNextKeepsBy`; `TestAgentEditOfOperatorLineMarksEdited`; `TestRemoveLogsTheOldLine` (log has the old text, record lacks it); `TestLogLineIsWrittenBeforeTheRecord` (fail the rename via a read-only dir: the log has the line, the record is unchanged); `TestRecordSeenKeepsDeletedBranches`; `TestConcurrentWritesKeepBothLines` (two goroutines add to `decisions` 50 times each → 100 lines; a per-key in-process mutex plus temp-and-rename); `TestRecordLivesUnderTheOrg` (path `…/orgs/initech/tickets/INI-142.json`); `TestUnknownSectionRefused`.
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'Record|TicketRecord'` → FAIL.
- [ ] **Step 3: Implement** in `ticketrecord.go`: read, apply, append log, write temp, rename — one function per write.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `ticket view: the ticket record — one file per ticket under the org folder, every change logged first`.

### Task 3: Linking a branch to its tickets

**Files:**
- Create: `internal/wakilcore/ticketlink.go`, `internal/wakilcore/ticketlink_test.go`

**Interfaces:**
- Produces:
  ```go
  type TicketMatch struct { Key, Source string } // Source: "wakil" | "branch" | "pr" | "trailer"
  func OrgProjectKeys(org string) []string                     // every project's scopes.pm.projectKey, via LoadRegistryFor + LoadProject, uppercase, unique
  func TicketKeysIn(text string, projectKeys []string) []string // `(?i)\b([A-Z][A-Z0-9_]*)-(\d+)\b`, prefix in keys, uppercase, first-seen order
  func TrailerKeys(messages []string, projectKeys []string) []string // `Ticket:` trailer lines only
  func LinkTicket(org, repoKey, branch, key string) error     // key "" unlinks; key not checked here
  func TicketLinkFor(org, repoKey, branch string) (string, bool)
  func RepoKey(host, owner, repo string) string               // "github.com/initech/api"
  func MatchTickets(link string, branch string, prTexts []string, trailers []string, keys []string) (matches []TicketMatch, looked []string)
  func LongLivedBranches(defaultBranch string, openPRs []PRHeadBase, keys []string) []string
  type PRHeadBase struct{ Head, Base string }
  ```
  `MatchTickets`: a Wakil link alone wins (inference not consulted); otherwise every source is tried, each key once, first source's kept; `looked` names each source tried in the spec's words (`branch name`, `PR #215's title and body`, `4 commits' trailers`).
  `LongLivedBranches`: `defaultBranch` plus each open PR's base that carries no key and is no open PR's head.

- [ ] **Step 1: Write the failing tests** — `TestBranchNameKey` (`ini-142-login` → `INI-142`); `TestNotAProjectKey` (`fix-UTF-8` with keys `[INI]` → none); `TestNoProjectKeysInfersNothing`; `TestSeveralKeysFromOneSource`; `TestWakilLinkOverridesInference`; `TestUnlinkReturnsToInference`; `TestFirstSourceMarkedAllShown` (branch `INI-1`, PR body `INI-2` → both, `branch` first); `TestLookedNamesEachSource`; `TestLongLivedFindsStagingAndProduction` (PRs `ini-1→staging`, `ini-1b→production`, `staging→main` → `main, staging, production`); `TestLinksKeyedByRepoAndBranch` (two worktrees, one link).
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'Key|Link|LongLived|Looked'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `ticket view: linking a branch to its tickets, keys of the organization's projects only`.

### Task 4: GitHub's pull requests, threads and checks

**Files:**
- Create: `internal/wakilcore/githubreview.go`, `internal/wakilcore/githubreview_test.go`

**Interfaces:**
- Consumes: Task 1 `GitHubTokenFor`.
- Produces:
  ```go
  type GitHubClient struct { Endpoint, Token string; http *http.Client }
  func NewGitHubFor(org, host string) (*GitHubClient, error) // GitHubTokenFor + endpoint rule (WAKIL_GITHUB_API first)
  type ReviewComment struct { Author, Body, CreatedAt string }
  type ReviewThread struct { ID, Path string; Line int; Outdated, Resolved bool; Comments []ReviewComment; ResolvedBy string }
  type CheckRun struct { Name, State, URL string } // State "success" | "failure" | "pending"
  type PullRequest struct {
      Number int; Title, Body, URL, State, Head, Base, HeadSHA, Author string // State "open" | "merged" | "closed" | "blocked"
      Checks []CheckRun; Threads []ReviewThread; RequestedReviewers []string
  }
  func (c *GitHubClient) Viewer(ctx context.Context) (string, error)
  func (c *GitHubClient) BranchPRs(ctx context.Context, owner, repo, branch string) (heads, bases []PullRequest, err error)
  func (c *GitHubClient) ReplyToThread(ctx context.Context, threadID, body string) (ReviewComment, error) // addPullRequestReviewThreadReply
  func (c *GitHubClient) SetThreadResolved(ctx context.Context, threadID string, resolved bool) error   // resolveReviewThread | unresolveReviewThread
  func (c *GitHubClient) MyOpenPRs(ctx context.Context, owners []string) (authored, reviewRequested []PullRequest, err error) // search is:open is:pr author:@me / review-requested:@me, org:<owner> each
  type GraphQLError struct{ Messages []string } // Error() joins them whole
  ```
  One `BranchPRs` call is one query: `pullRequests(headRefName: branch, first: 20, orderBy: CREATED_AT DESC, states: [OPEN, MERGED, CLOSED])` and `pullRequests(baseRefName: branch, states: OPEN)`, each with `commits(last:1){…statusCheckRollup{contexts(first:100)}}` and `reviewThreads(first:100){…comments(first:50)}`; a `pageInfo.hasNextPage` on threads or checks pages that connection only. `blocked` = open with `mergeStateStatus: BLOCKED`. The token never appears in an error (scrub as `JiraClient.scrubSecrets` does).

- [ ] **Step 1: Write the failing tests** against an `httptest` GraphQL server: `TestBranchPRsDecodesThreadsAndChecks` (outdated and resolved flags, `line`, two comments in order, 7 of 9 checks with one failure carrying its URL); `TestBranchPRsPagesThreadsPast100`; `TestEndpointRules` (env override; `github.com` → api.github.com; `ghe.initech.example` → `https://ghe.initech.example/api/graphql`); `TestReplySendsTheBodyVerbatim`; `TestResolveAndUnresolveMutations`; `TestGraphQLErrorsBesideDataAreKeptWhole` (data plus `errors` → data returned and a `GraphQLError` with every message); `TestHTTPErrorShownWholeWithoutToken`; `TestMyOpenPRsScopedToOwners` (query text carries `org:initech`).
- [ ] **Step 2:** `go test ./internal/wakilcore -run 'GitHub|BranchPRs|Reply|Resolve|GraphQL|MyOpen|Endpoint'` → FAIL.
- [ ] **Step 3: Implement**; the query strings are constants in the file.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `ticket view: GitHub's pull requests, review threads and checks over GraphQL with the organization's account`.

### Task 5: `wakil-ticket`, the capability

**Files:**
- Create: `cmd/wakil-ticket/main.go`, `cmd/wakil-ticket/branch.go` (assembles `ticket_branch` and `ticket_in_flight`), `cmd/wakil-ticket/main_test.go`, `cmd/wakil-ticket/schema_test.go`
- Modify: `Makefile` (`BINS`, line 53), `scripts/make-app-bundle.sh` (copy loop, line 63), `scripts/app_bundle_test.go` (`bundledServers`), `.gitignore` (`/wakil-ticket`), `docs/architecture/go.md` (`### wakil-ticket`). Not `scripts/register-provider.sh`: it is not agent-facing.

**Interfaces:**
- Consumes: Tasks 1–4; `wakilcore.Resolve`, `ProjectRootPaths`, `NewGitRunner`, `ParseRemoteURL`, `RemoteHost`, `NewJiraFromEnv`, `JiraClient.GetIssue(ctx, prefix, key)`.
- Produces tools (structured output, `mcpx.ToolErr("wakil-ticket", err)` on failure):
  ```go
  type SourceNote struct{ Source, Message string } // "github" | "jira" | "git"
  type TicketRef struct { Key, Title, Status, Assignee, URL string; Sources []string; Marked bool; Record wakilcore.TicketRecord; Error string }
  type TicketBranch struct {
      Root, Repo, Branch, Viewer string; LongLived bool
      Tickets []TicketRef; Looked []string; Linked bool
      PRs []wakilcore.PullRequest; BasePRs []wakilcore.PullRequest; Stack []int
      Partial []SourceNote
  }
  type InFlightRow struct { Key, Title, Status, State, Root, Branch string; PR int }
  type InFlight struct { WaitingOnYou, InFlight []InFlightRow; Partial []SourceNote }
  ```
  `ticket_branch {root}` → `TicketBranch`; `ticket_in_flight {}` → `InFlight` (every root of every org project, `MyOpenPRs` per GitHub host, owners from the roots' remotes); `ticket_record {key}`; `ticket_record_write {key, section, op, id?, line, by, conversation?}`; `ticket_link {root, branch, key}` (key `""` unlinks; a key Jira cannot find is kept and answered with `notFound: true`); `review_reply {root, thread, body}` → `{comment}`; `review_resolve {root, thread, resolved}`.
  `ticket_branch` also calls `RecordTicketSeen` for each ticket. `Marked` is the first match's key; Waiting on you is threads on the viewer's open PRs whose last comment is not the viewer's, PRs requesting the viewer's review, and the viewer's PRs with a failing check; the stack is the chain of open PRs joined head→base both ways. Jira's `projectKey` argument is the key's own prefix, already checked against `OrgProjectKeys`. A root with no upstream reads `origin`; a detached HEAD reads nothing remote and says `detached HEAD: no branch to read`.

- [ ] **Step 1: Write the failing tests** (a temp git repo with an `origin` of `git@github.com:initech/api.git`, a GraphQL stub at `WAKIL_GITHUB_API`, a Jira stub at `WAKIL_JIRA_BASE`, a temp `HOME` with org `initech`, project key `INI`): `TestTicketBranchJoinsJiraGitHubAndRecord`; `TestTicketBranchGitHubDownKeepsJira` (stub 502 → `Partial[0].Source == "github"`, message whole, ticket title present); `TestTicketBranchJiraDownKeepsPRs`; `TestTicketBranchSSHWithoutAPIAccessSaysSo` (the exact copy); `TestTicketBranchNonGitHubRemoteSaysSo` (`gitlab.com` → `Pull requests are read from GitHub only.`); `TestTicketBranchDetachedHeadReadsNothingRemote` (stub sees zero requests); `TestTicketBranchNoTicketLooked`; `TestTicketBranchLongLived` (on `main`: `LongLived`, no tickets); `TestWritesRefusedOutsideTheWindow` (no `WAKIL_IN_WINDOW` → `ticket_record_write`, `ticket_link`, `review_reply`, `review_resolve` each refused naming the window; reads answer); `TestReviewReplyPostsToTheStub`; `TestInFlightBranchesAndMyPRs`; `TestLinkUnknownKeyIsKept`. Schema test lists the seven tools.
- [ ] **Step 2:** `go test ./cmd/wakil-ticket ./scripts -run 'Ticket|Review|InFlight|Link|Bundle|Architecture'` → FAIL.
- [ ] **Step 3: Implement.** `main.go` registers tools; `branch.go` assembles; GitHub and Jira reads run concurrently with one 20 s context.
- [ ] **Step 4:** → PASS; `make build` lists `wakil-ticket`; `go test ./scripts` passes.
- [ ] **Step 5: Commit** `ticket view: wakil-ticket — the branch's tickets, pull requests and record, window-owned, its writes from the window only`.

### Task 6: WakilKit — the ticket store, the actions and the wiring

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorTicket.swift` (value types and pure decisions), `app/Sources/WakilKit/Editor/EditorTicketStore.swift` (actor), `app/Sources/WakilKit/Editor/EditorTicketActions.swift`, `app/Sources/WakilKit/App/WindowModel+Ticket.swift`
- Modify: `app/Sources/WakilKit/App/PlaceClients.swift` (`ClientRole.ticket = "wakil-ticket"`), `app/Sources/WakilKit/App/AppWiring.swift` (`ticketClient`, `startClient("wakil-ticket")`, `wakilOwnedClients`, pass to `registerEditorActions`), `app/Sources/WakilKit/Editor/EditorActions.swift` (`registerEditorActions(…, ticket: EditorTicketStore? = nil)`; `editor_tree`'s `view` enum gains `ticket`; calls `registerTicketActions` with its `openFile`), `app/Sources/WakilKit/Layout/Pane.swift` (`EditorColumnView.ticket`; `EditorColumnState.ticketShown: String?`, not saved), `app/Sources/WakilKit/Editor/EditorChangesWrites.swift` (push, sync, publish success → `ticket?.invalidate(root:)`), `app/Sources/WakilKit/Editor/EditorPaneKind.swift` (`readPane` key `ticket`), `app/Sources/WakilKit/App/WindowModel.swift` (`readStatus` → `ticketBranchesChanged`, `setAppActive(true)` → `ticketActivated`, `invalidateForOrgChange` resets), `docs/architecture/wakilkit.md` (`Editor/` section names the three files)
- Test: `app/Tests/WakilKitTests/EditorTicketTests.swift`, `EditorTicketActionsTests.swift`, `ActionClassificationTests.swift` (no operator-only additions), `AppWiringTests.swift`, `InvalidationContractTests.swift`

No new WakilKit folder: the view is the editor column's and `review_open` needs the editor's `openFile`, so `Ticket/` would only add `Ticket -> Editor` and `Editor -> Ticket`.

**Interfaces:**
- Consumes: Task 5's tool shapes (decoded into Swift mirrors `TicketBranchState`, `TicketRefState`, `PullRequestState`, `ReviewThreadState`, `ReviewCommentState`, `TicketRecordState`, `TicketLineState`, `InFlightState`, `InFlightRowState`, `SourceNoteState`). `ReviewThreadState` also carries its PR's `number`, `headSHA` and `root`.
- Produces:
  ```swift
  public func ticketBy(_ origin: ActionOrigin) -> String                       // ui→"operator", agent→"agent", debug→"wakil"
  public func ticketFollowedRoot(front: String?, roots: [String]) -> String?   // the front file's root, else roots.first
  public func ticketStale(lastRead: Date?, now: Date) -> Bool                  // nil or > 60 s
  public func ticketWaitingOn(_ b: TicketBranchState, record: TicketRecordState?) -> [String] // PR-derived first, then record lines, exact duplicates once
  public func ticketNext(_ b: TicketBranchState) -> (text: String, key: String?)? // marked ticket's; else newest among others, labelled with its key
  public func ticketFoldLine(_ r: TicketRecordState) -> String                 // "Decisions 3 · Not done 2 · Verified 1 ▸"
  public func reviewOpenThreads(_ prs: [PullRequestState]) -> [ReviewThreadState] // unresolved, not outdated, path then line
  public func reviewStep(_ threads: [ReviewThreadState], from: String?, delta: Int) -> ReviewThreadState? // wraps
  public func reviewPosition(_ threads: [ReviewThreadState], id: String) -> String // "1 of 5"
  public actor EditorTicketStore {
      public init(ticket: (any ToolCaller)?, now: @escaping @Sendable () -> Date = Date.init)
      public func branch(root: String) -> TicketBranchState?
      public func read(root: String) async throws -> TicketBranchState  // one flight per root; 20 s; generation-checked
      public func cancel(root: String)
      public func invalidate(root: String) async
      public func inFlight() async throws -> InFlightState
      public func draft(thread: String) -> String?; public func setDraft(thread: String, text: String?)
      public func sending(thread: String) -> Bool
      public func reset()                                               // org switch: cache, drafts, flights, generation += 1
  }
  ```
- Actions (all `.agentReachable`, registered in `registerTicketActions(into:store:panes:layout:openFile:roots:)`): `ticket_read {root?, key?}` (.read), `ticket_refresh {pane?}`, `ticket_show {pane?, key: string|null}`, `ticket_in_flight {}` (.read), `ticket_link {root, key}`, `ticket_record_update {key, section, op, id?, text?, why?, how?, who?, what?}`, `review_open {thread}` (opens path at line through `openFile`, column untouched), `review_step {delta, pane?}`, `review_reply_draft {thread, text}`, `review_reply_send {root, repo, pr, thread, body}`, `review_resolve {root, thread, resolved}`; kinds and prices per the spec's Actions table and Global Constraints. `review_reply_send` refuses while one is in flight for that thread (`a reply to this thread is already being sent`), keeps the draft on failure, clears it on success, then `invalidate(root:)`. Its plane statement: `Reply on initech/api#212 · src/auth/token.go:41` then the body.
- `readPane` key `ticket`: `{root, branch, tickets: [key], marked, prs: [{number, state, openThreads}], cursorThread, drafts: [thread id]}` — draft text never.

- [ ] **Step 1: Write the failing tests** — `ticketByMapsEveryOrigin`; `followedRootIsTheFrontFilesElseFirst`; `staleAfterSixtySeconds`; `waitingOnDedupesAndOrders`; `nextFallsBackToNewestWithItsKey`; `foldLineCounts`; `openThreadsSkipOutdatedAndResolvedInFileThenLineOrder`; `stepWrapsBothWays`; `positionReadsOneOfFive`; `aSecondReadJoinsTheFirst` (stub caller counts one call); `aReadPastTwentySecondsIsCancelledAndSaysSo`; `aReadFromTheOldOrgIsDropped` (reset during a slow read → `branch(root:)` nil); `recordUpdateCarriesOriginNotParams` (dispatch as `.agent` with conversation `c1` → tool args `by: "agent", conversation: "c1"`; a `by` param is ignored); `replySendIsGateForTheOperatorToo` (`.ui` dispatch parks on `ConfirmationBroker`); `resolveAllowsTheOperatorAndGatesTheAgent`; `replyKeepsTheDraftWhenThePostFails`; `replyCannotBeSentTwice`; `reviewOpenLeavesTheColumnOnTicket`; `editorTreeAcceptsTicket`; `readPaneListsDraftsWithoutText`; `pushInvalidatesTheRootsRead`; `everyWakilOwnedClientJoinsTheOrgSwitch` (existing, now with `wakil-ticket`); classify the new `WindowModel` properties in `InvalidationContractTests`.
- [ ] **Step 2:** `cd app && ../scripts/swift-test.sh --filter 'EditorTicket|ActionClassification|AppWiring|InvalidationContract'` → FAIL.
- [ ] **Step 3: Implement** the types, the store, the actions, then the wiring and `WindowModel+Ticket.swift` (`ticketBranchesChanged(_ roots: [GitRootState])` reads a root whose branch changed while an editor pane is open; `ticketActivated()` re-reads when `ticketStale` and a pane shows the Ticket view; the default branch reads `ticket_in_flight`).
- [ ] **Step 4:** → PASS; `make build && make app-test` green.
- [ ] **Step 5: Commit** `ticket view: the window reads each root's ticket state, and every ticket and review write is a registry action`.

### Task 7: Review threads in the file

**Files:**
- Create: `app/Sources/WakilKit/Editor/EditorReviewPlacement.swift`
- Modify: `app/Sources/WakilKit/Editor/EditorRenderer.swift` (`func setReviews(key: String, boxes: [ReviewBox])`), `app/Sources/WakilApp/MonacoEditorRenderer.swift` (`setReviews` → `wakilSetReviews`; `case "review"` → `onReview`), `app/Sources/WakilApp/monaco-host.html` (`wakilSetReviews`, `drawReviewBoxes`, `placeReviewBoxes`), `app/Sources/WakilApp/EditorPane.swift` (push boxes for the shown file tab; route `onReview` to dispatches)
- Test: `app/Tests/WakilKitTests/EditorReviewPlacementTests.swift`, `EditorRendererTests.swift`

**Interfaces:**
- Consumes: Task 6's `ReviewThreadState`, `reviewPosition`, `reviewStep`, the store's drafts; `editorHunks(base:text:)`; `git_show` with rev `commit:<headSHA>`.
- Produces:
  ```swift
  public struct ReviewPlacement: Sendable, Equatable { public let line: Int; public let note: String? } // nil | "line changed since" | "line may differ"
  public func reviewPlacement(headText: String?, buffer: String, line: Int) -> ReviewPlacement
  public struct ReviewBox: Sendable, Equatable, Encodable {
      public let thread: String; public let line: Int; public let note: String?
      public let author: String; public let time: String; public let text: String
      public let replies: [ReviewCommentState]; public let position: String // "1 of 5"
      public let resolved: Bool; public let resolvedBy: String?; public let draft: String?; public let sending: Bool
  }
  public func reviewBoxes(threads: [ReviewThreadState], path: String, root: String,
                          headTexts: [String: String], buffer: String, drafts: [String: String], sending: Set<String>) -> [ReviewBox]
  ```
  `headTexts` is keyed by head SHA, read with `git_show` rev `commit:<sha>`; a SHA absent from it is not local.
  `reviewPlacement`: `headText == nil` → raw line, `"line may differ"`; a line inside an unchanged run maps by the hunks' offset; a line inside a `changed` or `deleted` hunk → the nearest surviving line above (else below), `"line changed since"`; past the buffer's end → the last line, `"line changed since"`.
  Page messages posted: `{type:'review', key, thread, op}` with `op` ∈ `reply`, `discard`, `draft` (+`text`, on blur), `send` (+`text`), `resolve`, `unresolve`, `step` (+`delta`), `replies`. `EditorPane` maps them to `review_reply_draft`, `review_reply_send`, `review_resolve`, `review_step`.
  Page rules: an overlay widget over a view zone per box, only on file tabs (not while `diffKey`), placed in `ed.onDidLayoutChange` as `placeConflictRows` is; zone height follows the box (`ResizeObserver` → `changeViewZones` re-lay); every text node via `textContent`; the draft `textarea` stops key propagation so Monaco's keys do not fire, ⌘↩ sends; Alt+ArrowDown / Alt+ArrowUp on the box post `step` and are swallowed there only; a resolved box folds to `Resolved by <who> · Unresolve`; action labels carry `dataset.full` / `dataset.short` for narrow panes. Row actions: **Reply · Resolve · 1 of 5 · ⌥↓ next**.

- [ ] **Step 1: Write the failing tests** — `anUnchangedLineMapsThroughAnInsertAbove` (3 lines inserted above line 10 → 13, no note); `anEditedLineDrawsAtTheNearestSurvivingLine`; `aMissingHeadDrawsRawWithLineMayDiffer`; `aLinePastTheBufferEndDrawsAtTheLastLine`; `boxesOnlyForThisFilesOpenDrawnThreads` (outdated skipped); `boxCarriesTheDraftAndSending`; `boxTextIsTheCommentVerbatim` (`<img src=x onerror=alert(1)>` unchanged in the payload); `rendererSendsSetReviewsForTheShownTab` (`EditorRendererTests` fake records the call; none for a diff tab).
- [ ] **Step 2:** `cd app && ../scripts/swift-test.sh --filter 'EditorReviewPlacement|EditorRenderer'` → FAIL.
- [ ] **Step 3: Implement** WakilKit first, then the renderer, the page and `EditorPane`.
- [ ] **Step 4:** → PASS; `make app-build` succeeds.
- [ ] **Step 5: Commit** `ticket view: each open review thread drawn under its line, with Reply and Resolve; ⌥↓ steps from a box`.

### Task 8: The Ticket view in the column

**Files:**
- Create: `app/Sources/WakilApp/EditorTicketView.swift`
- Modify: `app/Sources/WakilApp/EditorColumn.swift` (header button `Ticket` after Changes, `accessibilityIdentifier("editor.column.ticket")`; `case .ticket:` in the body and in `focusWanted`), `app/Sources/WakilKit/Editor/EditorTicket.swift` (view rows below)
- Test: `app/Tests/WakilKitTests/EditorTicketTests.swift`

**Interfaces:**
- Consumes: Task 6 store and actions.
- Produces (WakilKit, so the view decides nothing):
  ```swift
  public enum TicketViewCase: Equatable { case ticket, several, noTicket(branch: String), longLived, loading, error(String) }
  public func ticketViewCase(_ b: TicketBranchState?, shown: String?) -> TicketViewCase
  public func ticketPRLine(_ pr: PullRequestState) -> String          // "#212  ini-142-login → main      open · checks 7/9 · 1 failing"
  public func ticketThreadRow(_ t: ReviewThreadState) -> (place: String, words: String, replies: String?) // "src/auth/session.go:88", first words ≤ 40 chars + "…", "2 replies"; outdated → "outdated"
  public func inFlightState(_ r: InFlightRowState) -> String          // "#212 · 2 threads" | "checks failing"
  public func ticketPartialLine(_ notes: [SourceNoteState]) -> [String] // each message whole
  ```
  The view, per spec *What the operator gets* 1–6: the root line above the header only with more than one root; header key, title, `<status> · waiting on <who>`; **Next:** a field (focused on click, kept on blur through `ticket_record_update set next`); ↻ (`ticket_refresh`) becomes **Cancel** while a read runs; PR blocks with failing checks (`details ↗` opens the check URL) and thread rows (click → `review_open`); the fold line opens to the five lists, each line editable, removable, with **+** adding a focused line and a `by · when` caption (`you`, `agent`, `Wakil`; `edited by agent`); the three non-ticket cases with **Link a ticket…** (focused, kept on blur, `ticket_link` on leave; an unfound key kept with `INI-999 was not found in Jira; kept as typed.`), **Unlink**, In flight pick → `ticket_show`, **Back to this branch** → `ticket_show null`; partial sources as whole lines. ⌥↓ / ⌥↑ with focus in the column → `review_step`. Scroll position is per pane and survives `review_open`.

- [ ] **Step 1: Write the failing tests** — `caseForEachSpecRow` (ticket, several, no ticket, long-lived, shown key from In flight overrides the branch); `prLineMatchesTheMockup`; `threadRowTruncatesAndCountsReplies`; `outdatedThreadRowSaysOutdated`; `inFlightStateWords`; `partialLinesAreWhole`.
- [ ] **Step 2:** `cd app && ../scripts/swift-test.sh --filter EditorTicket` → FAIL.
- [ ] **Step 3: Implement** the functions, then the view.
- [ ] **Step 4:** → PASS; `make app-build` succeeds.
- [ ] **Step 5: Commit** `ticket view: the Ticket view — header, Next, pull requests and threads, the record, In flight and Link a ticket`.

### Task 9: Settings → Organisation → Git: the API access row

**Files:**
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsGitAccount.apiAccess: String`, decodes absent as `""`), `app/Sources/WakilKit/Panes/GitAccountSetup.swift` (`gitAPIAccessRow(_:) -> GitAPIAccessRow?` — nil unless `provider == "github" && method == "ssh"`; title `API access`, detail `Not set — pull requests are not read` / `Signed in` / `Access token`), `app/Sources/WakilKit/App/WindowModel+GitAccounts.swift` (`setGitAPIAccessToken(host:token:) async -> String?`, `removeGitAPIAccess(host:) async -> String?`, `testGitAPIAccess(host:) async -> (user: String?, error: String?)`, `gitDevicePoll(…, apiAccess: Bool)`), `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_git_api_access_token_set` secret `token`, `ctx_git_api_access_remove`, `ctx_git_api_access_test` in the git-accounts list; `ctx_git_device_poll` gains `apiAccess`), `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (`operatorOnlyActions`), `app/Sources/WakilApp/GitAccountsSection.swift` (the row under an SSH GitHub card: **Sign in** · **Use a token** · Test · Remove, the token field secure, focused on open, kept on blur)
- Test: `app/Tests/WakilKitTests/GitAccountSetupTests.swift`, `WindowModelGitAccountsTests.swift`, `ActionClassificationTests.swift` (pinned list in `theClassificationLeavesTodaysReachabilityExactlyAsItWas`)

**Interfaces:**
- Consumes: Task 1 tools.

- [ ] **Step 1: Write the failing tests** — `apiAccessRowOnlyOnSSHGitHub`; `apiAccessRowWording`; `apiAccessTokenIsRedactedInTheJournal`; `apiAccessActionsAreOperatorOnly` (`.agent` refused); `devicePollPassesAPIAccess`.
- [ ] **Step 2:** `cd app && ../scripts/swift-test.sh --filter 'GitAccountSetup|WindowModelGitAccounts|ActionClassification'` → FAIL.
- [ ] **Step 3: Implement** model, actions, then the row.
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `ticket view: Settings — an SSH GitHub account's API access row, Sign in or a token`.

### Task 10: The record

**Files:**
- Modify: `docs/wakil/decisions.md` (new `### 2026-10-26 — reply to and resolve a review thread` under *Invariant 6 — the writes that have earned in*: the class; why — the organization's own account, the exact text on the plane for every channel, Resolve undone by Unresolve; what stays refused — a new top-level PR comment, a review, editing or deleting a comment, merging, labels, every other GitHub write; and that the ticket record is Wakil's own store, priced *allow*, not an earned write), `docs/wakil/north-star.md` (§4 Invariant 6: "Eleven have earned in", row `| Reply to a review thread; resolve and unresolve one | wakil-ticket | 2026-10-26 |`; §8 a `Ticket view` row after Conversations), `docs/architecture/README.md` (`wakil-ticket` among the window's binaries; it is window-owned, not agent-facing), `docs/architecture/state.md` (the `tickets/` folder; the in-memory cache and drafts and their org-switch reset), `docs/architecture/runtime.md` (steps 2 and `wakilOwnedClients`: the window's clients now include `ticketClient`), `CONTRIBUTING.md` (nothing new to recipe; add one line: "A review thread is drawn as the conflict row is: `wakilSetReviews` in `monaco-host.html`")
- Test: `make test` (its `docs-check`), `scripts/public-check.sh`

- [ ] **Step 1:** Write the edits.
- [ ] **Step 2:** `make test` → PASS; `scripts/public-check.sh` → exit 0.
- [ ] **Step 3: Commit** `ticket view: the earned write, the charter row and the code map`.

---

## Cover

After Task 10 and the whole-branch review, the e2e auditor (`docs/agents/e2e.md`) writes the checks. **During the work run only new and affected checks:** `make e2e-new`, and `make e2e E2E_ONLY='e2e/checks/seeded/ticket-*.jsonl'` (plus any existing check the branch reaches, e.g. `3b-iii-*`, `3a-iii-git-account*`). **`make e2e-full` runs once, overnight, before merge.** Ask the operator before taking the screen.

The fixture first gains a GraphQL stub at `WAKIL_GITHUB_API` (`e2e/driver/githubstub.go`, beside `anthropicstub.go`), a Jira stub at `WAKIL_JIRA_BASE`, a seeded record for `INI-142` and a seeded branch `ini-142-login` with an `origin` on `github.com/initech/api`. The checks the spec requires:

| Check | Covers |
|---|---|
| `ticket-tab-focus` | the Ticket tab, and focus staying where it was (`expect.focus`) |
| `ticket-header` | the header from the stub and the record |
| `ticket-next-kept` | Next focused on open, kept on blur |
| `ticket-record-line` | a list line added focused, kept on blur, removed without a question |
| `ticket-link-unlink` | Link a ticket… and Unlink |
| `ticket-thread-opens-file` | a thread row opens the file at the line; the column stays on Ticket |
| `ticket-box-drawn` | the box drawn under the mapped line |
| `ticket-reply-draft` | Reply focused, the draft kept on blur |
| `ticket-reply-send` | `review_reply_send` refused without confirmation (`refuses`), posted with it |
| `ticket-resolve` | Resolve and Unresolve |
| `ticket-review-step` | `review_step` |
| `ticket-in-flight` | In flight's pick with no branch switch; Back to this branch |
| `ticket-github-error` | a GitHub error shown whole beside a Jira header |
| `ticket-agent-line` | an agent's `ticket_record_update` shown as the agent's |
| `ticket-narrow` | frames at a narrow `do.resize` |
| `git-account-api-access` | the SSH account's API access row (Task 9) |

**Walk only:** a real reply and resolve on a real PR, read back on GitHub; real Jira status; a stack of PRs; a thread whose line was edited locally; ⌥↓ beside Monaco's own keys; long comments at narrow widths. Walk runbook: `docs/wakil/phase-ticket-view-acceptance.md`, written in Cover.
