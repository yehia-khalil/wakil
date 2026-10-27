# Ticket view — reviews and the ticket record in the editor: acceptance

**Spec:** [`2026-10-26-ticket-view-design.md`](../superpowers/specs/2026-10-26-ticket-view-design.md)
· **Plan:** [`2026-10-26-ticket-view.md`](../superpowers/plans/2026-10-26-ticket-view.md)
· **Charter:** Invariants 2, 4, 6 and 7; the decision of 2026-10-26, *reply to a review thread;
resolve and unresolve one*

The exit criterion, from the spec: the editor's left column shows the branch's ticket, its pull
requests, their open review threads and checks, and the ticket's record; each open thread is drawn
under its line in the file; replying asks on the plane before anything is posted; the operator and
an agent reach the same actions.

Walked by the operator on 2026-10-27: all ten rows passed, with the walk fixes below.

## 0. Setup

A private throwaway GitHub repository with one pull request on a branch named for a real ticket of
the organisation's Jira project, carrying two review comments on `notes.txt` (lines 2 and 5). The
walk project declares that Jira project as its `scopes.pm.projectKey` — a key no project of the
organisation claims never counts. The organisation's github.com git account signs in with SSH, so
row 2 adds its API access. Launch from the worktree root with
`WAKIL_ORG=initech app/Wakil.app/Contents/MacOS/Wakil`, make the project active with ⌘P, open an
editor pane and press **Ticket**.

## 1. The walk

| # | Do | Expect | Walked |
|---|---|---|---|
| 1 | Look at the Ticket view | Header: INI-141, its Jira title, status Backlog. Under it: "Pull requests not read … Add API access to the GitHub account in Settings → Organisation → Git". Nothing else blocked (Rule 8) | walked 2026-10-27 |
| 2 | Settings → Organisation → Git → github.com card → **API access** → **Use a token**, type your GitHub token (repo scope) without clicking first, **Store**. Close Settings, press ↻ | Field takes the keys on open (Rule 3); no Cancel while storing; then `•••• stored`. After ↻: PR #1 "INI-141 walk the ticket view", open, its checks, 2 threads (notes.txt:2, notes.txt:5) | walked 2026-10-27 |
| 3 | Click the notes.txt:2 thread row | notes.txt opens at line 2 with a box under it (author, time, text, Reply · Resolve · "1 of 2 · ⌥↓ next"); the column stays on Ticket, scrolled where it was (Rule 6) | walked 2026-10-27 |
| 4 | In the box: **Reply**, type `checking`, press **Discard**; then **Keep** | "Discard this reply?" Discard · Keep, keyboard on Keep; Keep leaves `checking` in the field | walked 2026-10-27 |
| 5 | **Send** → **Cancel** on the plane. **Send** again → type `confirm` → **Run**. Terminal: `gh pr view 1 -R initech/walk-ticket --comments` | The plane names wakil-walk-ticket, PR #1, notes.txt:2, the thread's author and your text, whole. Cancel posts nothing. After Run the reply shows in the box and in gh's output exactly once | walked 2026-10-27 |
| 6 | With the box focused press ⌥↓; then click into the code on any line and press ⌥↓, then ⌘Z | First ⌥↓ moves to notes.txt:5, "2 of 2", its box has the keyboard. In the code ⌥↓ is Move Line Down (a line moves); ⌘Z puts it back | walked 2026-10-27 |
| 7 | In the notes.txt:5 box press **Resolve**. Terminal: `gh api graphql -f query='{repository(owner:"initech",name:"wakil-walk-ticket"){pullRequest(number:1){reviewThreads(first:5){nodes{isResolved path line}}}}}'` | One click, no question; the box shows "Resolved by you"; gh shows line 5 `isResolved: true` | walked 2026-10-27 |
| 8 | In the Ticket view: click **Next**, type `ask about line five`, click elsewhere (no Enter). Open **Decisions · Not done · Verified ▸**, add a Decision `keep the walk small`. Terminal: `cat ~/.wakil/orgs/initech/tickets/INI-141.json` | Next keeps the text on blur (Rule 2) and is written once; the file holds the next line and the decision, lists as `[]` where empty | walked 2026-10-27 |
| 9 | Switch the branch to `main` (Changes → branch picker). Pick INI-141 in **In flight**. Then **Back to this branch** | On main: no header; Waiting on you / In flight lists INI-141. Picking it shows its header, Next, PR #1 and threads — the branch stays `main` (Rule 6). Switch back to INI-141-walk afterwards | walked 2026-10-27 |
| 10 | Terminal: `git -C "$TMPDIR/walk-ticket/work" switch -c walk-no-ticket`. Press ↻. **Link a ticket…**, type `INI-140`, click away. Then **Unlink** | "No ticket found for this branch" and where Wakil looked (branch name, no PR, commits). After linking: INI-140's header (Done). Unlink returns to "No ticket found" | walked 2026-10-27 |

## 2. Walk fixes (2026-10-27)

- The column's four view names wrapped letter by letter at the column's minimum width; they fall
  back to icons, each keeping its name as label and tooltip.
- GIT has an ⓘ, and the SSH step of adding a GitHub account a tip: SSH reads nothing from GitHub's
  API, so the Ticket view needs an access token beside the key.
- The column and the review threads restyled ("cards with state"): section micro-labels, hue pills
  for status and checks, threads as cards with an amber edge while waiting on the operator.
- In flight rows on two lines; the record as one list with **+ Add** and who wrote each entry.

## 3. Known and not fixed

- After a failed record, Next or Link write, a retry takes a keystroke: Enter on the same text sends
  nothing.
- A picked branch's read cannot be cancelled early; it stops at the 20 s limit.
- A key no project of the organisation claims shows only "No ticket found"; it does not say which
  project key is missing.

## 4. The machine walk

Rendered by `make e2e-runbook` once Cover's remaining checks have run.
