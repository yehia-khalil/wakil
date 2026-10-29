# State: what is kept where

Everything Wakil keeps, where it lives, and who writes it. `~` is `HOME` as the process sees it:
both the Swift side and Go read the `HOME` variable, so an overridden `HOME` moves all of it.

## On disk

| What | Path | Written by |
|---|---|---|
| Organisation record (display name, Jira site, default provider, speech engine) | `~/.wakil/orgs/<org>/org.json` | Go: `org.go`, `orgupdate.go` (`wakil org`, `wakil-ctx` `create_org` / `update_org`) |
| App-wide editor settings (the `editor` key: font size, word wrap, autosave) | `~/.wakil/settings.json` | Go `editorsettings.go` (`wakil-ctx` `set_editor_settings`) |
| App-wide browser settings (the `browser` key: search engine, start page) | `~/.wakil/settings.json` | Go `browsersettings.go` (`wakil-ctx` `set_browser_settings`) |
| Project registry (name → `project.json` path, preferred provider) | `~/.wakil/orgs/<org>/projects.json` | Go: `registry.go` (`wakil project`) |
| Active context (project, environment, provider) | `~/.wakil/orgs/<org>/active.json` | Go: `active.go` (`wakil-ctx` `set_project`, `set_environment`, `set_provider`) |
| Provider (account) records | `~/.wakil/orgs/<org>/providers/<id>.json` | Go: `provider.go`, `adopt.go`, `unlink.go` |
| Session lineage (which session was forked from which) | `~/.wakil/orgs/<org>/sessions.json` | Go: `sessions_lineage.go` (`record_session_parent`) |
| Conversation names, by lineage root (`{"<lineageRoot>": {"operator": …, "ai": …}}`; an entry with neither name is removed; an unreadable file is never written over) | `~/.wakil/orgs/<org>/conversation-names.json` | Swift: `ConversationNameFile` |
| A project's configuration (roots, scopes, environments, databases, API entries, editor tabs) | the project's `project.json`, by convention `.wakil/project.json` inside the project | the operator; Go `projectwrite.go` (`set_database_dsn`, `remove_database`) and `editorsettings.go` (`set_project_editor_settings`, the `editor` key); `recipe.go` (`recipe_save`: the `recipes` key, and each root's `recipe`, `overrides`, `doesntRun`; a secret env value is `{"secret": "<ref>"}`, its value in the Keychain) |
| Sites never to offer saving a password for (`passwords-never.json`, a sorted array of site keys, no credential; clearing browsing data keeps it; an unreadable file is never written over) | `~/.wakil/orgs/<org>/browser/` | Swift: `BrowserOrgFiles` (`neverSave`), the `browser_password_never` action |
| Browser profile id (`profile.json`: `{"identifier":"<UUID>"}`, the organisation's WebKit data-store id), zoom per host (`zoom.json`: `{"<host>": <factor>}`), per-tab state (`tabs/<place-digest>.<pane>.<tab>.state`, WebKit's binary `interactionState`, so ‹ › survive a relaunch) | `~/.wakil/orgs/<org>/browser/`. The store itself (cookies, logins, site storage) is WebKit's, under `~/Library/WebKit/`, outside Wakil's reach; Settings → Browser → Clear removes it through the id and keeps `profile.json` | Swift: `BrowserOrgFiles`; zoom by `browser_zoom`, tab state by `BrowserTabHost` |
| A project's browser pins (3d-i): tabs, groups and the pull-request group, each with an id the pane's tab or group names; a tab pin and each tab of a pinned group carry the tab's `name` when it has one (names), a pinned tab's written at once when it is renamed | `~/.wakil/orgs/<org>/browser/pins/<project>.json` (`{"items":[…]}`, the project key percent-encoded), written whole and atomically; a file that will not parse is never written over | Swift: `BrowserPins` |
| The browser's sites and the agent's reach: the organisation's production sites, the active environment's tags, each conversation's allowed sites (`PlaceAgent.id` → site keys) and each tab's last read | **memory only**: `PaneStore`'s browser kind, rebuilt from the config tree and never written; a closed conversation and an org switch forget theirs, a relaunch asks again | Swift: `BrowserSites`, `browserAllow`, `browserRecordRead` |
| Pane arrangement per project (a browser pane's `browserTabs` — id, URL, title, group, pin and name per tab — `browserGroups`, `browserColumnHidden` and `browserActiveTab` are saved with it; only the active tab loads on restore) | `~/.wakil/layouts/<org>/<project>.json` | Swift: `LayoutPersistence` |
| The organisation's open pull requests, behind the pull-request group (3d-i) | **memory only**: `PaneStore`'s browser kind, refreshed from `wakil-ctx`'s `github_pull_requests` every five minutes and by ⌘R; never written | Swift: `browserSetPullRequests` |
| The vertical tab column's width (3d-i) | the user defaults key `browser.tabColumn.width`, one width for every pane | Swift: `BrowserTabColumn` |
| Pane arrangement per conversation in Main, or per workspace (its view, shared by its conversations; the folder is `workspace-<view key>`) | `~/.wakil/layouts/<org>/conversations/<lineageRoot or workspace-<key>>/<project>.json` | Swift: `LayoutPersistence` |
| Workspaces (each: id, name, slug, project, environment, tickets, parent, branch, checkouts — repo, path, branch, base, ports, last holder, in Main, snapshot — conversations by lineage root, view, archived); an unreadable file is never written over | `~/.wakil/orgs/<org>/workspaces.json` | Go: `workspaces.go` (`wakil-git` `workspaces_write`, the window only) |
| A workspace's checkouts (git worktrees of the project's roots; only recorded ones are touched) | `~/.wakil/orgs/<org>/workspaces/<project>/<slug>/<repo folder>` | Go: `worktree.go` (`git_worktree_add` / `_remove`, `git_take_from_main`) |
| A removed checkout's uncommitted work (a stash-shaped commit, never on the shared stash list); a branch carried out of Main while it moves | `refs/wakil/snapshots/<slug>/<repo>`, `refs/wakil/carry/<slug>/<repo>` in the repository | Go: `SnapshotCreate`, `TakeFromMain` |
| The window's own memory (`railCollapsed`: the rail put away to its spine; absent means shown) | `~/.wakil/layouts/window.json` | Swift: `LayoutPersistence.saveWindowState`, from `WindowModel` |
| Action journal (append-only, one line per dispatch) | `~/.wakil/journal/<sessionId>.jsonl` | Swift: `ActionRegistry` (`JournalEntry`) |
| A ticket's record (next, decisions, not done, waiting on, verified, rulings; empty lists as `[]`) and its log (append-only, the old line written before each change) | `~/.wakil/orgs/<org>/tickets/<KEY>.json`, `<KEY>.log.jsonl` (`<KEY>.json.lock` beside each, taken per key) | Go: `ticketrecord.go` (`wakil-ticket` `ticket_record_write`, `ticket_branch`'s seen/branch/PR fields) |
| Ticket links made in Wakil, keyed `<host>/<owner>/<repo>:<branch>` | `~/.wakil/orgs/<org>/tickets/links.json` | Go: `ticketlink.go` (`ticket_link`) |
| A ticket's hand-offs (`handoffs` in its record: conversation, harness, provider, place, thread, May push, ended), and a PR with no ticket key's (`pr:<repo>#<n>`) | the ticket's record above; `~/.wakil/orgs/<org>/tickets/pr-handoffs.json` | Go: `tickethandoff.go` (`ticket_handoff_write`), Wakil only |
| The last Hand to agent Start (`harness`, `provider`, `mayPush`, `at`), prefilling the next popover | `~/.wakil/orgs/<org>/tickets/handoff.json` | Go: `tickethandoff.go` |
| Review reply drafts by thread id (`text`, `by`, `conversation`, `root`, `branch`, `at`, `replaced`) | `~/.wakil/orgs/<org>/tickets/drafts.json` | Go: `ticketdrafts.go` (`ticket_draft_write`), Wakil only |
| Code-identifier cache | `~/.wakil/vocabulary/` | Swift: `CodeSource` |
| Agent transcripts | `<provider configDir>/projects/…` | the `claude` CLI; read by Go `sessions.go`, `transcript.go` |

The org comes from `WAKIL_ORG` (`CurrentOrg` in `internal/wakilcore/paths.go`), never from a file.
The full org and provider model is in `docs/wakil/org-and-provider-model.md`.

## In the Keychain

| Service name | Holds | Read by |
|---|---|---|
| `wakil:<org>:<ref>` | a database DSN, an API credential, or Jira (`ref` is `jira:<org>`) named by a `project.json` ref | Go `SecretGet` (`internal/wakilcore/secrets.go`, `keychainService`) |
| `wakil:<org>:provider:<id>` | an account's minted OAuth token (`ProviderTokenRef`) | Go; the app asks `wakil provider credentials` (`WakilCLICredentialsLookup`) |
| `wakil:<org>:browser-login:<identity>` (`default` today; account `<site> <username>`) | one saved browser password, trusting Wakil.app only | Swift, in-process: `BrowserPasswordStore` (Security.framework). Go only checks the service exists (`BrowserLoginsPresent`, attributes only, for `wakil org rm`) |

Go reaches the Keychain only by running `/usr/bin/security` at its absolute path
(`internal/wakilcore/credpresence.go`). `WAKIL_KEYCHAIN` names a keychain file instead of the login
keychain; the e2e harness uses it. The Swift app reads the Keychain directly only for browser passwords (Decision 49: an item `/usr/bin/security` trusts would be readable by the agent's shell). Values are
never written to `project.json`, only the ref.

## Only in memory

- **Pane contents** (`PaneStore`): rows, terminal blocks, api drafts and responses, editor tabs and their text (the layout saves only each file tab's path, cursor and scroll; a scratch buffer is not saved). A
  result set is not persisted; the pane's page and sort (`PaneFetch`) are, with the layout.
- **Recent api sends**, capped at `PaneStore.recentCap` (200) per list, gone with the session.
- **Live PTYs** (`TerminalStore`).
- **Who holds each checkout, and which workspace each live conversation is in** (`WorkspaceStore`):
  holds are live, so a relaunch holds nothing; the record keeps each checkout's last holder.
- **Pending confirmations** (`ConfirmationBroker`, one per conversation), resume and provider-switch requests (`ResumeBroker`,
  `ProviderSwitchBroker`).
- **The window's own state** (`WindowModel`): context, snapshots, thought thread, status, palette.
- **The window's git status** (`GitStatus`, mirrored in `WindowModel.gitRoots`, 3b-iii): one read
  per root, kept while an editor pane is open (`syncGitWatcher()` watches the roots then) and
  emptied when the last one closes or the organisation switches. Diff tabs are never saved; a
  saved Git pane loads as an editor pane on Changes (`layoutMigratingGitPanes`).

- **The Ticket view's reads** (`EditorTicketStore`): one cache entry per (root, branch), one read in flight each; review reply drafts and sends in flight beside them. Never saved with the layout. `reset()` on an org switch empties all of it and drops reads in flight by generation; the window's cache is filled only by the window's own client.

- **What needs the operator** (`WindowModel.ticketNeeds`): the last `ticket_in_flight` read of the active organization, from which the count, the rail tick, the Landing section and ⌘P's ticket rows are derived (`ticketNeedsRows`). There is no seen store. A poll task (`ticketPollTask`) reads it every 2 minutes while Wakil is the active app and the screen is unlocked. Never saved.

## What an org switch resets

`WindowModel.invalidateForOrgChange()` (`app/Sources/WakilKit/App/WindowModel.swift`) resets only
what belongs to the organisation itself: the vocabulary (`dropAll`), project and environment,
production flags (here and in the registry), settings and accounts, an in-flight sign-in (a mint in
flight is left to finish), the provider id, `lookup` and roots, capacity, the palette, and the
editor's pending requests and unsaved prompt (they name panes on the screen being left), and the
window's git status and its `gitRoots` mirror (of the screen's roots), and the ticket store (reads, drafts, sends) with the branch each root was last seen on (`ticketBranches`), and `ticketNeeds` with the poll task (`ticketOrganizationReady` reads the incoming organization). Then
`syncGitWatcher()` and `syncEditorWatcher()` follow the empty roots. `organization` is set by the
caller, `setOrganization`.

**Nothing of a place is reset.** Every place's agent, thread, turn and conversation
(`WindowModel.conversations`, by conversation id; `agents` reads the one each place shows), its waiting approval (`parkedProposals`), both stores' scopes, every shell,
every editor buffer and agents' reads in flight survive the switch (the operator's db reads in the org left are cancelled first, `PaneStore.cancelOperatorDBReads`, since they went out on the window's clients), keyed by their place or scope; coming
back to an org finds its canvas as it was left; its git and editor panes re-read the disk then (`catchUpReturnedCanvas`, R4).

**The tripwire.** `everyWindowModelPropertyIsClassifiedForTheOrgSwitch` in
`app/Tests/WakilKitTests/InvalidationContractTests.swift` reads every stored property of
`WindowModel` by reflection and fails on one not classified as org-derived, kept per place, or org-independent. It
proves every property was thought about, not that the reset is right;
`invalidationClearsEveryOrgDerivedValue` in `OrgSwitchTests.swift` covers the reset itself. Adding a stored property to `WindowModel` means
classifying it there (and resetting it here if it is org-derived).

The Go side is reset by `WakilWiring.switchOrg`, which restarts every Wakil-owned client under the
new `WAKIL_ORG`; `everyWakilOwnedClientJoinsTheOrgSwitch` (`AppWiringTests`) keeps that list whole.
