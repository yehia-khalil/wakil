# 3a-iii: a git account per organisation — push, pull, fetch, sync, clone — and agent instructions

**Date:** 2026-10-22
**Status:** designed with the operator 2026-10-22, question by question; spec awaiting review
**Sub-phase:** 3a-iii, the phase-map row *"A git account per organisation — sign in, the credential
in the Keychain; push, pull, fetch, sync"*. Follows 3a-ii-b (main e1c128b, #42/#43).
**Depends on 2e-ii** for two parts: *Clone from a link* extends 2e-ii's **+ Add a project**, and the
project's instruction boxes sit on 2e-ii's Project page; the account rows and the organisation's
boxes sit in Settings → Organisation, where 2e-ii is also working. Design now; build after
2e-ii lands.

---

## Problem

3a-ii commits on this Mac; nothing in Wakil reaches a remote. Pushing means a terminal, and which
account pushes is decided by how the remote happens to be spelled, not by whose work it is.
Measured on the operator's Mac (2026-10-22):

- Two GitHub accounts, kept apart by hand: `~/.ssh/config` aliases (`github.com` → the
  `initech_github` key, `github-umbrella` → the `umbrella` key), a `url.insteadOf` rewrite for
  `umbrella-corp`, an `includeIf` for Umbrella's identity, and `gh` logged in to both
  (`dev-initech` active, `dev-umbrella`), serving HTTPS through `gh auth git-credential`.
- 56 repositories: about 30 cloned over SSH (the alias decides the account), about 11 over HTTPS
  (whichever `gh` account is active decides), one with a token written into its remote URL.
- An HTTPS clone of a Umbrella repository pushes as `dev-initech` unless `gh` is switched first.

Orca, measured as a reference (1.4.232): it runs the system `git` with every prompt disabled and
inherits the machine's credentials; its only per-account feature binds a `gh` login per project for
`gh` calls (issues, PRs), not for `git push`. It has the same weakness.

## Decisions the operator took during this design (2026-10-22)

- **Every provider, now.** GitHub, GitLab, Bitbucket and any other host.
- **Three methods, each where the provider allows it:**
  - **Sign in** (a browser sign-in with a short code, OAuth device flow): GitHub and GitLab.com.
  - **Paste a token** (HTTPS): Bitbucket (its API tokens replace app passwords), self-hosted GitLab,
    any other host.
  - **SSH key**: every provider — pick a key already in `~/.ssh`, or **Generate** one; Wakil shows
    only the public half, with Copy and a button that opens the host's add-key page, then **Test**.
- **The provider is chosen first**, suggested from the organisation's projects' remotes.
- **Wakil runs git itself and hands it the organisation's credential**; no per-host CLI is needed.
  `gh` is optional: if present, its logins are offered as a shortcut for GitHub.
- **Pull strategy is a setting**, in Settings → Organisation → Git: Merge, Rebase, or
  Fast-forward only. Default **Rebase**.
- **Every remote operation is priced *allow*, for every channel.** The operator's buttons, the
  composer and voice all push, pull, sync and publish without asking: "push this" said or typed to
  the agent pushes. (The operator first chose a gate for the agent, then ruled it out the same
  day: a push asked for in words must happen.) Invariant 7's *allow* exception covers the voice
  half, as for 3a-ii's commit.
- **Clone from a link** is added to **+ Add a project**, beside 2e-ii's folder picker.
- **Agent instructions, at two levels.** The organisation page gets an **Agent** section with
  **General** instructions, and its **Git** section gets **Commits** and **Pull requests**
  instructions. The **Project** page (2e-ii's) gets the same three boxes for that project alone.
  The agent's prompt carries Wakil's rules, then the organisation's text, then the project's; the
  repository's own `CLAUDE.md` stays the team's committed layer and Wakil does not touch it.

## Calls made for the operator (flagged for review)

1. **A key Wakil generates lives in Wakil's own folder** (`~/.wakil/orgs/<org>/git/ssh/`), not
   `~/.ssh`: the terminal, Orca and the agent's shell keep behaving exactly as now. Its passphrase
   is random and kept in the Keychain; the operator never sees it.
2. **One account per provider per organisation.** A client that needs a second GitHub account gets
   its own organisation.
3. **Wakil's `ssh` keeps the alias's route but never its keys.** Before each command Wakil reads
   `ssh -G <alias>` and passes on only `HostName`, `Port`, `User`, `ProxyJump` and
   `HostKeyAlias`, then runs `ssh -F /dev/null` with the organisation's key alone. A push can then
   never fall back to another account's key from `~/.ssh/config` (which would push as the wrong
   account), and an alias such as `github-umbrella` or a self-hosted port still works.
4. **A picked `~/.ssh` key with a passphrase** is detected (`ssh-keygen -y -P ""` fails) and the sheet
   asks for the passphrase once; it goes to the Keychain under the same name as a generated key's,
   and Wakil's askpass answers both.
5. **Sign in is built last in the plan**, with the GitHub and GitLab.com client IDs as
   configuration, so the rest does not wait on the operator registering the two OAuth apps.
6. **The agent may clone but not add a project.** `editor_clone` from the agent clones only into the
   folder the operator last cloned into or chose, and does not register a project; Wakil shows
   `Cloned to <path> — Add as project`, one click for the operator. The operator's own **Clone from a
   link…** clones and adds in one step. (Adding a project stays operator-only, Decision 30; a clone
   writes outside every root, which no agent file write may.)
7. *(Superseded by the operator, 2026-10-22 — see "Instruction edits apply from the agent's next
   turn" below.)*
8. **A gentle size warning** past about 2,000 words per box (all of it rides on every agent turn);
   nothing is refused.
9. **Background fetch every 5 minutes** while an editor pane is open and the app is active, plus on
   opening the Changes view. Quiet: a failure shows only on the root's header line.

## What the operator gets

### Settings → Organisation → Git

The section 3a-ii made (Name, Email) gains:

1. **Accounts**, a list of rows such as `github.com · SSH · dev-umbrella` or
   `bitbucket.org · Token · dev_initech`, and **+ Add a git account**:
   1. **Provider:** GitHub, GitLab, Bitbucket, or **Other…** (a host). Suggestions come from the
      organisation's projects' remotes — `github.com — 25 repositories` — with a remote host
      resolved through `ssh -G` (so `github-umbrella` counts as `github.com`).
   2. **Method**, offering only what the provider supports (the table above).
   3. The method's steps (below), ending in a **Test** that names the account the host knows.
2. **Pull strategy:** Merge · Rebase · Fast-forward only (segmented, default Rebase), saved on
   click (Rule 2).
3. Each account row: **Test**, **Replace**, **Remove** (Remove asks, in the pane: it ends access
   — Rule 1). Removing a generated key sends it to the Trash and deletes its passphrase; Wakil
   says to delete the public key on the host too, which it cannot do itself.

**Sign in (GitHub, GitLab.com):** Wakil shows a short code and opens the provider's device page
(`github.com/login/device`); the operator approves; Wakil polls, stores the token in the Keychain,
and reads the account name. **Use a gh login** (GitHub, when `gh` is installed) lists `gh auth
status` accounts and copies that login's token (`gh auth token --user <u>`) into the Keychain once.

**Paste a token:** a secure field, a link to the provider's token page with the scopes named
(GitHub `repo`; GitLab `read_repository write_repository`; Bitbucket repository read/write), and
for Bitbucket a username field. The token goes to the Keychain and is never shown again.

**SSH key:** a list of `~/.ssh` keys by comment and file, or **Generate a new key** (ed25519,
comment `<user or email> (Wakil · <org>)`). Then the public key with **Copy** and **Open <host>'s
SSH keys page** (title suggested: `Wakil · <org> · <Mac name>`), and **Test connection**:
`✓ github.com knows this key as dev-umbrella`, or the host's refusal whole.

### The Changes view

4. **Each root's header shows its branch and distance**: `main ↑2 ↓1`, `main ↑2`, `feature · no
   upstream`.
5. **One main button, beside Commit's ▾, cycles as the state needs:** **Publish** (no upstream),
   **Push** (ahead only), **Pull** (behind only), **Sync** (both: pull with the strategy, then
   push). **Fetch** is in the ▾ menu. Nothing to do: no button.
6. **A remote operation in flight** shows a spinner and the git progress line (`Writing objects
   42%`), and **Cancel** (Rules 4, 5). One remote operation per root at a time, beside 3a-ii's one
   write per root.
7. **Errors** are whole, under the root's box, with credentials stripped, and say where to go:
   `Authentication failed for dev-umbrella on github.com — Settings → Organisation → Git`;
   `Rejected: the remote has newer commits. Pull or Sync first`;
   `No git account for bitbucket.org in Umbrella — add one in Settings → Organisation → Git`.
8. **A pull that conflicts** stops: with Rebase or Merge, Wakil aborts it (`git rebase --abort` /
   `git merge --abort`), leaves the tree as it was, and lists the conflicting files whole. Resolving
   conflicts in Wakil is 3a-v's.

### Clone from a link (after 2e-ii)

9. **+ Add a project** offers **Choose a folder…** (2e-ii, unchanged) and **Clone from a link…**:
   a link field (`https://…`, `git@…`, GitLab and Bitbucket links), a destination folder (the last
   one used; **Change…** opens the picker), and **Clone**, with progress and Cancel. It clones
   with the organisation's account for that host — an HTTPS link with the SSH account if that is
   what the organisation has. Done, it becomes a project exactly as a chosen folder does in 2e-ii.

### Agent instructions

11. **Settings → Organisation → Agent → General**, and **Settings → Organisation → Git → Commits**
    and **Pull requests**: three multi-line text boxes, saved when left (Rule 2), each with a
    one-line hint and an example as placeholder (`Imperative subject under 72 characters; reference
    the Jira key`). They hold how this organisation wants the agent to behave, to write commit
    messages, and to write PR titles and descriptions (Wakil opens no PRs; the agent does, with `gh`
    in its shell).
12. **Settings → Project** (after 2e-ii): the same three boxes, for that project only, under the
    project's Name.
13. **What the agent receives:** after Wakil's own rules (`agentSystemPrompt`), the organisation's
    General, Commits and Pull requests texts, then the project's, each under a heading
    (`## Organisation initech — commits`). Empty boxes add nothing. The project's text comes last,
    so where they disagree it is the one the agent read most recently.
14. **The ✨ draft** (3a-ii-b) adds the organisation's and the project's Commits texts to its
    instructions, from the next press.
15. **Instruction edits apply from the agent's next turn, in the same conversation** (operator,
    2026-10-22). Saving a box marks every live agent in that organisation (or that project) as
    holding stale instructions. Before its next turn — never during one — Wakil restarts that
    agent's process with `--resume <its session>` and the new appended text, so the conversation
    and its history carry on. The thread shows one quiet line: `Instructions updated — the agent
    has the new ones from this turn.` *Probe first (the plan's first task):* that a resumed Claude
    Code session takes a changed `--append-system-prompt`. If it does not, the spec is amended
    before build.

### The agent and voice

10. `editor_changes_fetch`, `_pull`, `_push`, `_sync`, `_publish`, and `editor_clone` reach the same
    paths, and none asks: "push api" in the composer or by voice is an agent turn that pushes.

## What it does not do

- **No force push**, ever, from any channel.
- **No branch create, switch or delete, no stash** (3a-iv); **no conflict resolution, history or
  blame** (3a-v); no PR creation.
- **No uploading a public key or deleting one on the host** through its API.
- **No change to the terminal, Orca, or the agent's own shell**: they keep the Mac's own git and
  SSH setup. Only Wakil's own actions use the organisation's account.
- **No two accounts for one provider in one organisation.**
- **No migration** of existing `~/.ssh` aliases or `gh` logins; Wakil only reads them.

## Design

### `wakil-git` — `GitRemote` (Invariant 10)

3a-ii's `GitWriter` blocks every network path (`GIT_ALLOW_PROTOCOL=none`, no lazy fetch) and stays
as it is. Remote operations get a third runner, **`GitRemote`**, with the same root check and
scrubbed environment except:

- **Protocols:** `GIT_ALLOW_PROTOCOL=ssh:https` (plus `file` under test only). No `ext::`, `git://`
  or `http://`.
- **Prompts off**, as Orca does: `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`,
  `-c credential.interactive=false`, `-c core.askPass=` — except Wakil's own askpass below.
- **The repository's config cannot choose a program here:** `-c core.sshCommand=` is overridden by
  Wakil's, `-c credential.helper=` is reset before Wakil's helper is added, and
  `remote.<r>.uploadpack` / `receivepack` are refused when set to anything but the default.
- **Identity** (3a-ii's) still passes as `-c user.name/user.email` where a merge or rebase commits.

**Credential injection, per command** — nothing is written to `~/.ssh` or to any git config:

| Method | What Wakil passes |
|---|---|
| SSH | `GIT_SSH_COMMAND="ssh -F /dev/null -i <key> -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=<wakil known_hosts> -o StrictHostKeyChecking=accept-new <-o HostName/Port/User/ProxyJump from ssh -G>"` (call 3), and for a key with a passphrase `SSH_ASKPASS=<wakil askpass>` with `SSH_ASKPASS_REQUIRE=force`, answering it from the Keychain (call 4). An `https://<host>/` remote is rewritten for the one command: `-c url.git@<host>:.insteadOf=https://<host>/` |
| Token / Sign in | `-c credential.helper=` then `-c credential.helper=!<wakil> git-credential --org <org> --host <host>`, which answers `username` (`x-access-token` for GitHub, `oauth2` for GitLab, the Bitbucket username) and `password` from the Keychain. An `ssh://` or `git@` remote is rewritten to `https://<host>/` for the one command |

The **host** of a remote is resolved through `ssh -G <alias>` (`hostname`), so an alias in
`~/.ssh/config` finds its real host and therefore its organisation account. **No account for the
host** refuses before git runs, naming the host and the organisation.

| Tool | Runs | Notes |
|---|---|---|
| `git_fetch` | `git fetch --prune <remote>` | |
| `git_pull` | `git pull --rebase` / `--no-rebase` / `--ff-only` by the org's strategy | a conflict aborts and returns the conflicting paths |
| `git_push` | `git push <remote> <branch>` | `--force*` never; refused when no upstream (use publish) |
| `git_publish` | `git push --set-upstream <remote> <branch>` | |
| `git_sync` | pull (strategy) then push, stopping at the first failure | |
| `git_clone` | `git clone --progress <url> <dest>` | dest must not exist; a failed clone removes its partial folder |
| `git_remote_whoami` | `ssh -T git@<host>` / an authenticated API `GET /user` | for **Test**; returns the account name or the host's words |

Progress lines (`--progress`) stream back for the spinner line; a cancelled call kills git's
process group (3a-ii's rule).

### Organisation record and Keychain — Go

- `Org` gains `GitAccounts []GitAccount` (`json:"gitAccounts,omitempty"`) and `PullStrategy string`
  (`rebase` default when empty, `merge`, `ff-only`).
- `GitAccount{Host, Provider, Method ("ssh"|"token"|"signin"), User, KeyPath (ssh), Username
  (bitbucket)}`. One per `Host`.
- Secrets in the Keychain under Invariant 4's names: `wakil:<org>:git-<host>-token`,
  `wakil:<org>:git-<host>-ssh-passphrase`. Removed with the account.
- New `wakil-ctx` tools, operator-only like every Settings write (Decision 30): `ctx_git_account_add`,
  `_remove`, `ctx_git_key_generate`, `ctx_git_device_start` / `_poll`, `ctx_git_token_set`;
  `ctx_update_org` takes `pullStrategy`. `config_tree` returns the accounts (no secrets) and the
  provider suggestions from the projects' remotes.
- **OAuth apps:** Wakil is registered once as a GitHub OAuth App and a GitLab.com application
  (device flow; public client IDs, no secret) — an operator-todo before build. Scopes: GitHub
  `repo`; GitLab `read_repository write_repository read_user`.

### Actions — WakilKit (Invariant 2)

| Action | Kind | Price (production, otherwise) |
|---|---|---|
| `editor_changes_fetch`, `_pull`, `_push`, `_sync`, `_publish` | `.mutate` | allow, allow |
| `editor_clone` | `.mutate` | allow, allow |

Every remote action is priced *allow* everywhere (Decision 25's mechanism, unchanged), as 3a-ii's
writes are. The agent can therefore push in any turn, not only one the operator asked for; the
journal records each push with its params and caller, and **force is never available**, so a
mistaken push is undone by a following commit.

The window keeps per-root `changesRemote[root]` state (in flight, progress line, last error), and
the status re-read after every remote operation also reads `ahead`/`behind` (already in
`GitStatus`).

### Agent instructions — Go and WakilKit

- `Org` gains `AgentGeneral`, `GitCommitInstructions`, `GitPRInstructions` (strings, omitempty),
  written by `ctx_update_org` and returned by `config_tree`. The project record (`project.json`)
  gains `agent: {general, commits, pullRequests}`, written through 2e-ii's project write path.
- A pure `agentInstructions(org:, project:) -> String` in `WakilKit/Harness/AgentInstructions.swift`
  composes the appended text; `ClaudeCodeCLIHarness` passes `agentSystemPrompt + that` to
  `--append-system-prompt` when a session starts, read from the place's org and project at launch.
- `CommitDraft.request` gains `commitInstructions: String` (organisation's, then project's).
- The texts are not secrets and are not scrubbed; they are journalled like any setting.

### WakilApp

- Settings → Organisation → Git: **Accounts** (rows, **+ Add a git account** sheet: provider →
  method → steps), **Pull strategy**. Identifiers `settings.org.git.account.<host>`,
  `.add`, `.test`, `.remove`, `settings.org.git.pullStrategy.<value>`.
- Changes view root header: distance text, the main remote button
  (`editor.changes.<root>.remote`), ▾ **Fetch** (`editor.changes.<root>.fetch`), progress and Cancel.
- Add a project: **Clone from a link…** (after 2e-ii; identifiers named against 2e-ii's).
- Organisation page: **Agent** section (`settings.org.agent.general`); Git section's
  `settings.org.git.commits`, `settings.org.git.pullRequests`. Project page (after 2e-ii):
  `settings.project.agent.general`, `.commits`, `.pullRequests`.

### Interaction rules

- **Rule 1:** removing an account asks (it ends access); push, pull, fetch, sync and clone do not,
  from any channel (a push is undone by a follow-up commit, never by force).
- **Rule 2:** the token field and Pull strategy keep their value when left.
- **Rule 3:** the Add-account sheet opens with the provider list focused; Clone's link field
  arrives focused.
- **Rule 4:** every remote operation, the device-flow wait and clone can be cancelled.
- **Rule 5:** one remote operation per root, shown in flight.
- **Rule 6:** after a remote operation the Changes view keeps its selection and scroll.
- **Rule 7:** an unsupported method is not offered (no refusal); an `https` remote with an SSH
  account is rewritten, not refused.
- **Rule 8:** git's and the host's words, whole, credentials stripped.
- **Rule 9:** Rebase is a default, shown, and changeable per organisation.

## Errors and edges

| Case | What happens |
|---|---|
| No account for the remote's host | Refused before git runs, naming host and organisation, with the Settings path |
| Host key unknown | `accept-new` records it in Wakil's own `known_hosts` (not `~/.ssh/known_hosts`); a changed key refuses whole |
| Push rejected (non-fast-forward) | `Rejected: the remote has newer commits. Pull or Sync first` |
| Pull conflicts | Aborted, tree as before, conflicting paths listed; 3a-v resolves |
| Device flow expires or is denied | The sheet says so whole; **Try again** restarts it |
| Token revoked | The next operation's authentication failure names the account and the Settings path |
| Generated key's passphrase missing from the Keychain | Refused whole; **Replace** generates a new key |
| Clone destination exists | Refused before git runs |
| A remote with `ext::`, `git://` or `http://` | Refused: the protocol is not allowed |
| An org switch mid-push | The push finishes in the repository it started in; its result is dropped (3a-ii's rule) |

## Testing

- **Go:** `GitRemote` against local bare repositories over `file://` (allowed under test): fetch,
  pull per strategy (and the conflict abort), push, publish, sync, clone and its cleanup; the
  command construction per method (SSH command, askpass, credential helper, the insteadOf rewrites)
  pinned without a network; `ssh -G` host resolution; the `wakil git-credential` helper's answers
  per provider; refusals (no account, force, bad protocol, existing destination).
- **WakilKit, instructions:** `agentInstructions` composition (order, headings, empty boxes
  skipped); the harness passing it on launch; `CommitDraft` carrying the commit texts.
- **WakilKit:** each action's params, kind and price (allow, from the agent, in production); the
  status re-read; one remote operation per root; the error mapping.
- **e2e (seeded):** a fixture with a bare `file://` remote: Push, Pull, Sync, Publish and Fetch from
  the button and by dispatch, the dispatch asking nothing; Pull strategy saved; Clone from a link into
  a new project. Sign-in, token and SSH flows against real hosts are walk-only.
- **Runbook:** the operator's own GitHub accounts (Initech SSH, Umbrella sign-in), a Bitbucket
  token, a clone, and `git log origin/main` checked in a terminal.

## Charter changes this sub-phase makes

- **Invariant 6:** *Push, pull, fetch and clone — remote git for the project's roots | wakil-git |
  <date>.* The appendix: a push publishes beyond this Mac, priced *allow* for every channel
  (voice included) at the operator's ruling; it is never forced, so a mistaken push is undone by a
  following commit, and the journal records who pushed what.
- **Decision 44** (new): the organisation's git account per provider (three methods), credentials
  in the Keychain and passed per command, never written to the Mac's SSH or git config; pull
  strategy per organisation; every remote write priced *allow*. *Reverse if:* injecting credentials
  per command proves unable to reach a host the Mac's own setup reaches — or an agent push the
  operator did not ask for is found on a remote, and then push becomes *gate* for the agent.
- **Decision 45** (new): agent instructions per organisation (General, Commits, Pull requests) and
  per project, appended after Wakil's rules at session start; the repository's `CLAUDE.md` stays
  the committed layer. *Reverse if:* the appended text is found to override Wakil's own rules in
  practice — then Wakil's rules go last.
- **Phase map:** 3a-iii reworded to name clone and agent instructions; *Met* on its walk. A new
  row, **New conversation** (`session_new`: end this place's conversation and return to its
  Landing — the path `WindowModel.sessionStarted`'s note records as owed), added by the operator
  2026-10-22, not part of 3a-iii; and after it **Track** (two sessions in one place, each its own
  thread — revisits Decision 41; its agenda is the parked #78–#86), also added by the operator.
- **operator-todo:** register the GitHub OAuth App and the GitLab.com application, and record their
  client IDs.
