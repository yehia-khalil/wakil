# The Ticket view: the ticket record, and review comments in the file

**Date:** 2026-10-26
**Status:** design awaiting the operator's review. Piece 2 of
`2026-10-25-ticket-work-design.md` (the umbrella), built on piece 1,
`2026-10-25-connections-design.md`. The operator chose to skip questions; every call the designer
made is under *Calls made for the operator*, for a builder check to follow. Pieces 2 and 3 ship
together (the umbrella's call): this design leaves piece 3's slots open and does not fill them.

---

## Problem

A ticket's state is spread over four places Wakil does not join: the PM tool (status, assignee),
git (the branch), the code host (pull requests, review threads, CI checks) and the operator's
head (what was decided, what is not done, what was checked). Wakil reads the first two separately
(`wakil-pm`, agent-facing only and scoped to the active project; `wakil-git`) and the third not at
all. The operator reads review comments on a website, then finds the file and line in the editor
by hand, and keeps the record of where a ticket stands in per-harness handoff notes that only one
harness reads.

## Decided by the operator (2026-10-25, copied from the umbrella)

1. **A fourth view in the editor's left column: Files · Search · Changes · Ticket.** It follows the
   branch the editor is on. **No new pane**, nothing new permanently on screen.
2. **The header** (the branch has a ticket): key and title, PM status, who it is waiting on, and
   **Next:** one line. A repo's steps row joins it in piece 4.
3. **Below the header:** the branch's pull requests, each with its open review threads (file:line
   and the first words), its CI checks and its state (open, merged, blocked). At the bottom, folded
   under one line, **Decisions · Not done · Verified ▸**.
4. **Each review comment is also drawn in the file**, under its line, the way the conflict actions
   row is (`placeConflictRows`, `monaco-host.html`): author, time, text, and **Reply · Hand to
   agent · Resolve · "1 of 5 · ⌥↓ next"**. No "fix it" button. **Reply** opens a draft inside the
   box; nothing is posted until **Send**; posting is a write whose price is *gate*. Clicking a
   thread in the column opens its file at its line and leaves the column where it was.
5. **The three non-ticket cases** (default branch, no ticket found, several tickets) and **In
   flight**, as the umbrella's table and definition say; picking a ticket never switches the branch.
6. **Linking, first answer wins, all answers shown when several match:** a link made in Wakil; the
   branch name; the PR's title and body; commit trailers (`Ticket: INI-142`); the PM tool's
   development panel. **Only keys of a project of the organization's PM connection count.**
7. **The ticket record:** one per ticket per organization, written by Wakil from what it reads and
   by whoever works the ticket through a Wakil action; agents read and write it through an MCP
   tool. **It never replaces a harness's own notes.**
8. **Provider- and harness-agnostic; skills stay out.**

## What the operator gets

1. **Ticket** in the column's header, after Changes (`editor_tree` view `ticket`). On a branch
   `ini-142-login` of an Initech root:

   ```
   INI-142  Sign-in keeps the last organization        In Progress · waiting on reviewer
   Next: answer the two token comments, then QA deploy                                ↻
   ─────────────────────────────────────────────────────────────────────────────
   #212  ini-142-login → main      open · checks 7/9 · 1 failing
     ✗ unit (Linux)                                                    details ↗
     src/auth/session.go:88   "Should this read the org from the…"        2 replies
     src/auth/token.go:41     "Nit: the error should name the host"
   ─────────────────────────────────────────────────────────────────────────────
   Decisions 3 · Not done 2 · Verified 1 ▸
   ```

   With more than one root in the project, a line above the header names the root it follows: the
   root of the file in front, else the project's first root.
2. **Next** is a field: click it, it is focused (Rule 3), it keeps what is typed on blur (Rule 2).
   The folded section opens to five lists — **Decisions** (each with its *why*), **Not done**,
   **Waiting on**, **Verified** (each with *how*), **Rulings** — each line editable the same way,
   each list with **+** that adds a focused line. A line removed asks nothing (Rule 1); it is kept
   in the record's log. Each line shows who wrote it (you, an agent, Wakil) and when.
3. **A review thread in the file:** a box under the thread's line, over a view zone as tall as the
   box, holding the first comment (author, time, text) and its replies folded ("2 replies ▸"), then
   **Reply · Resolve · 1 of 5 · ⌥↓ next**. **Reply** grows the box with a draft field, focused
   (Rule 3), kept on blur and across tab switches for the window's life (Rule 2), with **Send** and
   **Discard**. **Send** raises the permission plane showing the text, the PR and the thread; the
   draft stays until the post succeeds. **Resolve** resolves the thread and the box folds to one
   line ("Resolved by you · Unresolve"). A thread GitHub calls outdated is not drawn in the file;
   its column row says *outdated*.
4. **Clicking a thread row** opens its file at its line in the editor, the box in view; the column
   stays on Ticket, scrolled where it was (Rule 6). **⌥↓ / ⌥↑** step through the branch's open
   threads across files (see open question 1).
5. **The three non-ticket cases:**

   | Case | What the view shows |
   |---|---|
   | The default or a long-lived branch | No header. **Waiting on you** — threads on your open PRs whose last word is not yours, PRs that ask for your review, your PRs with a failing check — then **In flight** in this organization. Each row: key, title, PM status, one state in words ("#212 · 2 threads", "checks failing"). Picking one shows it in the view, with **Back to this branch**; the branch never switches (Rule 6). |
   | No ticket found | "No ticket found for `fix-utf-8`", then where Wakil looked (branch name, PR #215's title and body, 4 commits' trailers) and **Link a ticket…**: one field, focused, kept on blur, checked against the PM tool when it is left; a key it cannot find is kept and says so (Rule 7). The branch's own PRs and threads still show. |
   | Several tickets | The header lists each ticket the branch or its stack carries (key, title, status), marks the one this branch is for, and shows one **Next**: the marked ticket's, or, when it has none, the newest among the others, labelled with its key. |
6. **A source Wakil could not read says so whole, and blocks nothing else** (Rule 8): "Pull
   requests not read: this organization's github.com account signs in with SSH, which reads no pull
   requests. Add a token in Settings → Git accounts, or a GitHub connection." The record and the PM
   status still show.

## How it works (the parts decided)

### The capability: `wakil-ticket`

A new Go binary (Invariant 10), **window-owned**: started in `WakilWiring.build`, in
`wakilOwnedClients`, restarted on an org switch, and pinned to an agent caller's place the way
every window client is (`pinnedPlace`). Logic in `internal/wakilcore` (`ticketrecord.go`,
`ticketlink.go`, `githubreview.go`). It is not in `agentFacingServers`: the agent reaches it only
through registry actions over the shim, so the operator and the agent dispatch the same actions
(Invariant 2, Decision 19). Its writes answer only when `WAKIL_IN_WINDOW` is `1`, as `wakil-http`'s
`send` does.

Its tools: `ticket_branch` (one root's branch: tickets with their sources, PRs with threads and
checks, the stack, partiality), `ticket_in_flight` (the organization's tickets in flight and
Waiting on you), `ticket_record` (read one), `ticket_record_write`, `ticket_link`, `review_reply`,
`review_resolve`.

### Where each fact comes from

| Fact | Source | Why |
|---|---|---|
| Branch, commits, trailers, remote | local git, `wakilcore.GitRunner` | already Wakil's, free |
| PRs, review threads, checks, requested reviewers, stack | **GitHub's GraphQL API with the organization's git account token** for the remote's host (`GitAccountFor`, Keychain `git-<host>-token`) | the account already exists per organization and per host (3a-iii); a Sign in carries scope `repo`, which reads PRs and replies to threads; `git_account_test` already calls GitHub's API with it |
| — when that account is SSH | the organization's **GitHub connection's** token (`conn:<name>`), sent to the API directly | same organization, same Keychain prefix; no new sign-in |
| — when neither exists | nothing; the partiality line above | — |
| PM status, assignee, title | `wakilcore.JiraClient.GetIssue` with the org's Jira site and `jira:<org>` token, as `wakil-pm` does | no second Jira path; scoped to the org's PM project keys, not only the active project's |

**Not `gh`:** its login is the machine's, not the organization's, so Invariant 4 rules it out
(`git_gh_import` already copies one into an organization once). **Not the GitHub connection's MCP
tools:** they run inside the agent's process tree, their shapes are the server's to change, and
the window has no client for them. Only github.com and GitHub Enterprise hosts (an account whose
provider is `github`) are read; a GitLab or Bitbucket root says "pull requests are read from GitHub
only". `WAKIL_GITHUB_API` overrides the API base for tests and e2e, as `WAKIL_JIRA_BASE` does.

One `ticket_branch` read is one GraphQL query per root: the PRs whose head is the branch (newest
first, open, merged and closed), each with its last commit's check rollup and its review threads
(`isResolved`, `isOutdated`, `path`, `line`, comments), and the open PRs whose base is the branch;
a stack is the chain of open PRs joined head to base, followed both ways. Plus one Jira read per
ticket key. `ticket_in_flight` adds one GitHub search per host (`is:open is:pr author:@me`, and
`review-requested:@me`, limited to the organization's repositories) and reads every root's local
branches.

### When it reads

No timer. A read runs, and is kept in memory per (root, branch) while an editor pane is open, as
the window's git status is:

| Trigger | Reads |
|---|---|
| An editor pane opens; the branch a root is on changes (`GitWatcher` already wakes on `HEAD`) | `ticket_branch` for that root |
| ↻ in the header (`ticket_refresh`) | the view's current read |
| A push, publish or sync from Wakil | that root's `ticket_branch` (CI starts on a push) |
| Send or Resolve succeeds | that PR again |
| Wakil becomes the active app and the last read is over 60 s old, with the Ticket view showing | the view's current read |
| The view shows the default branch | `ticket_in_flight` |

The file's review boxes come from the same read, so they appear with the Ticket view hidden. A
read in flight shows on ↻ and cannot be fired twice (Rule 5); one that hangs past 20 s is
cancelled and says so. Piece 3's noticing will need reads with no editor open; its own design picks
that cadence.

### Linking

Piece 2 ships sources 1–4. **Source 5, the PM tool's development panel, is deferred**: Jira serves
it only through an undocumented endpoint (`dev-status`), and sources 3–4 find the same links from
the code host's side.

A key counts when its prefix is a `scopes.pm.projectKey` of any project of the organization, matched
case-insensitively and written uppercase (`ini-142-login` → `INI-142`; `fix-UTF-8` is not a ticket
because `UTF` is no project's key). With no PM connection nothing is inferred; a link made in Wakil
still counts, since the operator typed it. Several answers from one source make several tickets;
answers from different sources are shown together, the first source's marked. A link made in Wakil
overrides an inferred one (Rule 7); **Unlink** goes back to inference.

**Long-lived branches** are the remote's default (`origin/HEAD`), plus any branch that is the base
of an open PR, carries no key and is the head of none — so `staging` and `production` are found
without a list. **In flight** in piece 2 is a ticket with a local branch in any of the
organization's roots or an open PR by the operator; "an agent working on it" joins with piece 3,
which is where a conversation gets a ticket.

### Review comments in the file

The page gains `wakilSetReviews(key, threads)`, drawn exactly as `drawConflictRows` is: an overlay
widget over a view zone (content in a zone gets no clicks), placed by the same layout callback,
only on file tabs (not diff tabs). The zone is as tall as the box; growing the box (replies,
draft) re-lays the zone. **Comment text is set as text, never as HTML**: it was written by other
people. The draft field is a `textarea` in the widget that takes the keyboard while focused, so
Monaco's keys do not fire in it.

**Placing a thread:** GitHub gives its line on the PR's head commit. WakilKit maps that line
through the diff between the head commit and the buffer (the diff machinery the gutter marks
already use). A line that survives is drawn under; a line edited locally is drawn under its nearest
surviving line, with "line changed since". A file not in the buffer's tab set draws nothing until
it is opened.

**Thread ids** are GitHub's node ids. `1 of 5` counts the branch's open, drawn threads in file
order, then line order.

### The ticket record

**Stored** as one file per ticket per organization: `~/.wakil/orgs/<org>/tickets/<KEY>.json`, with
`<KEY>.log.jsonl` beside it, append-only, holding every line's text before each change. Links
live in `~/.wakil/orgs/<org>/tickets/links.json`, keyed by repository (remote host and path, so
worktrees share them) and branch. Under the org folder: Invariant 4's per-org directory; a file,
because Wakil keeps no database of its own (`state.md`).

```json
{
  "key": "INI-142",
  "seen": {"title": "…", "status": "In Progress", "assignee": "…", "at": "…"},
  "branches": [{"repo": "github.com/initech/api", "branch": "ini-142-login", "source": "branch"}],
  "prs": [{"repo": "github.com/initech/api", "number": 212, "state": "open"}],
  "next": {"text": "…", "by": "operator", "at": "…"},
  "decisions": [{"id": "d1", "text": "…", "why": "…", "by": "agent", "conversation": "…", "at": "…"}],
  "notDone": [{"id": "n1", "text": "…", "by": "…", "at": "…"}],
  "waitingOn": [{"id": "w1", "who": "…", "what": "…", "by": "…", "at": "…"}],
  "verified": [{"id": "v1", "text": "…", "how": "…", "by": "…", "at": "…"}],
  "rulings": [{"id": "r1", "text": "…", "why": "…", "state": "open", "by": "agent", "at": "…"}]
}
```

- **Wakil writes** `seen`, `branches` and `prs` from what `ticket_branch` reads — a cache of reads,
  like the vocabulary, not state anyone edits. A record is created the first time a ticket is read
  or written; branches and PRs stay after a branch is deleted, so the record outlives them.
- **The operator and any agent write** `next` and the five lists, through one action. `by` is set
  by Wakil from the dispatch's origin, never by the caller; an agent's line also carries its
  conversation. An agent may edit any line, the operator's included: the old text is in the log and
  the line then says "edited by agent". Nothing is refused (Rule 7).
- **Rulings** are stored and listed in piece 2; their count in the header and **Keep / Overrule**
  are piece 4.

**Writing the record is not a write that earns in under Invariant 6.** The invariant governs what
Wakil does to systems it binds; the record is Wakil's own store, nothing outside this Mac sees it,
and every change is kept in the log — the class of `session_record_parent` and `capacity_record`.
Its action is a `.mutate` priced *allow* everywhere, voice included, journalled like every
dispatch.

**The handoff notes.** Wakil never reads a harness's notes: `~/.claude/handoffs/` is one harness's
path, and reading it would make the core know Claude (Invariant 1). The umbrella's "the content of
today's handoff note" names **what** the folded section shows — decisions, not done, verified —
held in the record. Nothing is imported. An agent asked to can copy its own note into the record
through the action, which leaves the harness reading its own files.

### Actions

| Action | Kind · audience | Price | What |
|---|---|---|---|
| `editor_tree` | control · agent | — | gains view `ticket` |
| `ticket_read` | read · agent | — | the view's state for a root's branch, or for one key |
| `ticket_refresh` | control · agent | — | read again now |
| `ticket_show` | control · agent | — | show a key in the view (from In flight), or `null` for the branch's own |
| `ticket_in_flight` | read · agent | — | the organization's tickets in flight and Waiting on you |
| `ticket_link` | mutate · agent | allow | link a repo's branch to a key, or unlink |
| `ticket_record_update` | mutate · agent | allow | set `next`; add, edit or remove one line of a list |
| `review_open` | control · agent | — | open a thread's file at its line, column unchanged |
| `review_step` | control · agent | — | the next or previous open thread (`delta`) |
| `review_reply_draft` | control · agent | — | keep a thread's draft (the field dispatches on blur; piece 3's agent writes drafts here) |
| `review_reply_send` | mutate · agent | **gate**, every channel | post the draft as a reply to the thread |
| `review_resolve` | mutate · agent | allow; **agent gate** | resolve or unresolve a thread |

Each new control gets an e2e check or an `uncoverable.tsv` line (`CONTRIBUTING.md`). The journal
records each dispatch with its parameters as usual: `review_reply_send` with repo, PR, thread and
body, outcome `ok`, `gated` or `error`; `review_resolve` with the thread and `resolved`;
`ticket_record_update` with the key, section, line id and text. No parameter is secret.

**Posting earns in under Invariant 6**, recorded with the plan in `decisions.md` and as one row of
§4's table: *Reply to a review thread; resolve and unresolve one — `wakil-ticket`, with the
organization's GitHub account.* A reply is published to other people and cannot be taken back by
Wakil, so it is *gate* for every channel, the operator's click included: the plane is the sign-off
on the exact text. Resolve has its undo one click away (**Unresolve**) and posts no words, so the
operator's click confirms in place and the agent's ask raises the plane (Decision 46's agent
price). **Still refused:** a new top-level PR comment, a review (approve, request changes),
editing or deleting a comment, merging, labels, and every other GitHub write.

### Readable state

The editor pane's snapshot gains the Ticket view's state (Invariant 3): the root and branch it
follows, the shown ticket(s) and the marked one, the PRs with their thread counts, the thread whose
box holds the cursor, and which drafts exist (not their text). "Reply to this comment" resolves
against it.

## Invariants

| Invariant | How this keeps it |
|---|---|
| 1 Agent-agnostic core | No harness's notes are read; the agent's path is registry actions over the shim. |
| 2 Actions only | Every write — record, link, reply, resolve, draft — is a registry action; the view and the agent dispatch the same ones. Wakil's cache of reads is not operator state. |
| 3 Panes observable | The column's ticket state is in the editor's snapshot. |
| 4 Credential boundary | Tokens are the organization's own (git account, then its GitHub connection), read in its own process; `gh` is not used; the record lives under the org folder; the client restarts on an org switch and its memory resets in `invalidateForOrgChange`. |
| 6 Earned writes | Reply and resolve earn in, above; the record is Wakil's own store; everything else on GitHub stays refused. |
| 7 Voice | Send is *gate*, so a spoken "send it" raises the plane and needs typed confirmation. |
| 10 Layers | `wakil-ticket` is headless; the view and the boxes own no logic WakilKit cannot test. |

## Interaction Rules

| Rule | Where it bites | How this meets it |
|---|---|---|
| 1 | Send, Resolve, removing a record line | Send's price is *gate*, so the plane asks. Resolve asks nothing of the operator (Unresolve undoes it). A removed line asks nothing; the log keeps it. |
| 2 | Next, record lines, Link a ticket, the reply draft | Each keeps what is typed on blur; Enter is a shortcut (⌘↩ in the draft, which takes newlines). |
| 3 | Reply, **+** on a list, Next, Link a ticket | The field arrives focused. |
| 4 | A read that hangs | ↻ becomes **Cancel** while a read runs; 20 s cancels it and says so. |
| 5 | ↻, Send, Resolve | Each shows its work and is disabled while it runs; a draft cannot be posted twice. |
| 6 | Thread rows, ⌥↓, In flight, Back to this branch | The column stays on Ticket and scrolled; no branch switch; the editor moves, nothing else. |
| 7 | Linking, record edits, an unknown key | A link overrides inference; an agent's edit is kept, not refused; an unfound key is kept and says so. |
| 8 | GitHub, Jira, a failed post | The service's message whole; one source failing leaves the others shown; a failed Send keeps the draft. |
| 9 | Several tickets, the root followed | The marked ticket and the followed root are defaults; picking another is one click. |

## Non-goals

- A code-review website: no diff review, no new top-level comment, no approve or request changes.
- A CI dashboard: checks are listed with a **details ↗** link to the provider's page.
- GitLab and Bitbucket pull requests.
- Reading or writing any harness's handoff notes.
- Noticing (the amber tick, the Landing, ⌘P `#`) and **Hand to agent**: piece 3. The box's action
  row ships without the button; piece 3 adds it between Reply and Resolve. No disabled placeholder.
- The steps row and Keep / Overrule (piece 4); Then (piece 5); people, recall and cost (piece 6).
- PM writes: no transition from the view (open question 15 stands).

## What is left to the builder

- The GraphQL query's exact shape and paging (over 100 threads, over 50 checks), and GitHub
  Enterprise's API base (`https://<host>/api/graphql`).
- Whether the folder is `Ticket/` in WakilKit (say why in the PR) and the view's file in
  `WakilApp`; the box's styling within `design-language.md`.
- How the review box's height follows its content in the zone, and short labels at narrow widths
  (the conflict row's `dataset.short` pattern).
- The record's write as one Go function that reads, merges and writes atomically (temp file and
  rename), with the log line first.
- The exact copy.

## E2E coverage and the walk

**e2e** (a GraphQL stub at `WAKIL_GITHUB_API`, a Jira stub at `WAKIL_JIRA_BASE`, a seeded record):
the Ticket tab and its focus; the header from the stub and the record; Next and a list line kept on
blur and focused on open; Link a ticket and Unlink; a thread row opens the file at the line with the
column unchanged; the box drawn under the mapped line; Reply focused, kept on blur; `review_reply_send`
refused without confirmation (`refuses`) and posted with it; Resolve and Unresolve; `review_step`;
In flight's pick without a branch switch; a GitHub error shown whole beside a Jira header; an agent's
`ticket_record_update` shown as the agent's; frames at a narrow `do.resize`.

**Walk only:** a real reply and resolve on a real PR, read back on GitHub; real Jira status; a
stack of PRs; a thread whose line was edited locally; ⌥↓ beside Monaco's own keys; long comments
at narrow widths.

## Calls made for the operator

- **my call:** PR, thread and CI data come from GitHub's GraphQL API with the organization's git
  account token, falling back to its GitHub connection's token; never `gh`, never the connection's
  MCP tools.
- **my call:** Jira status and assignee come from `wakilcore.JiraClient` inside `wakil-ticket`,
  checked against the organization's PM project keys.
- **my call:** one new window-owned binary, `wakil-ticket`; the agent reaches it only through
  registry actions.
- **my call:** reads on editor open, branch change, ↻, Wakil's own push, Send or Resolve, and app
  activation after 60 s with the view showing. No timer.
- **my call:** the record is a JSON file per ticket under the org folder, with an append-only log;
  links in one `links.json`.
- **my call:** writing the record is Wakil's own state, priced *allow* everywhere, not an
  Invariant 6 write; an agent may edit the operator's lines, the old text kept.
- **my call:** Wakil never reads `~/.claude/handoffs`; the folded section shows the record.
- **my call:** Send is *gate* for every channel; Resolve is the operator's click in place and *gate*
  for the agent (Decision 46). Reply and resolve earn in as one row.
- **my call:** Hand to agent is not in piece 2, not even disabled.
- **my call:** linking ships sources 1–4; the Jira development panel is deferred.
- **my call:** long-lived branches are the remote default plus bases of open PRs with no key; In
  flight in piece 2 is a branch or an open PR of the operator's.
- **my call:** outdated threads are listed, not drawn; a locally edited line draws at the nearest
  surviving line.

## Open questions

1. **⌥↓ is Monaco's Move Line Down.** The umbrella's box says "⌥↓ next". This design takes ⌥↓/⌥↑
   for threads only while focus is in a review box or the Ticket column, and leaves Move Line Down
   in the text. Should ⌥↓ step threads from the text too, giving up Move Line Down?
2. Open question 15 (PM transition reversibility) is untouched here; it applies to piece 5's Move.
