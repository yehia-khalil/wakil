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
| A project's configuration (roots, scopes, environments, databases, API entries, editor tabs) | the project's `project.json`, by convention `.wakil/project.json` inside the project | the operator; Go `projectwrite.go` (`set_database_dsn`, `remove_database`) and `editorsettings.go` (`set_project_editor_settings`, the `editor` key) |
| Browser profile id (`profile.json`: `{"identifier":"<UUID>"}`, the organisation's WebKit data-store id), zoom per host (`zoom.json`: `{"<host>": <factor>}`), per-tab state (`tabs/<place-digest>.<pane>.<tab>.state`, WebKit's binary `interactionState`, so ‹ › survive a relaunch) | `~/.wakil/orgs/<org>/browser/`. The store itself (cookies, logins, site storage) is WebKit's, under `~/Library/WebKit/`, outside Wakil's reach; Settings → Browser → Clear removes it through the id and keeps `profile.json` | Swift: `BrowserOrgFiles`; zoom by `browser_zoom`, tab state by `BrowserTabHost` |
| The browser's sites and the agent's reach: the organisation's production sites, the active environment's tags, each conversation's allowed sites (`PlaceAgent.id` → site keys) and each tab's last read | **memory only**: `PaneStore`'s browser kind, rebuilt from the config tree and never written; a closed conversation and an org switch forget theirs, a relaunch asks again | Swift: `BrowserSites`, `browserAllow`, `browserRecordRead` |
| Pane arrangement per project (a browser pane's `browserTabs` — id, URL and title per tab — and `browserActiveTab` are saved with it; only the active tab loads on restore) | `~/.wakil/layouts/<org>/<project>.json` | Swift: `LayoutPersistence` |
| Pane arrangement per conversation | `~/.wakil/layouts/<org>/conversations/<lineageRoot>/<project>.json` | Swift: `LayoutPersistence` |
| The window's own memory (`railCollapsed`: the rail put away to its spine; absent means shown) | `~/.wakil/layouts/window.json` | Swift: `LayoutPersistence.saveWindowState`, from `WindowModel` |
| Action journal (append-only, one line per dispatch) | `~/.wakil/journal/<sessionId>.jsonl` | Swift: `ActionRegistry` (`JournalEntry`) |
| Code-identifier cache | `~/.wakil/vocabulary/` | Swift: `CodeSource` |
| Agent transcripts | `<provider configDir>/projects/…` | the `claude` CLI; read by Go `sessions.go`, `transcript.go` |

The org comes from `WAKIL_ORG` (`CurrentOrg` in `internal/wakilcore/paths.go`), never from a file.
The full org and provider model is in `docs/wakil/org-and-provider-model.md`.

## In the Keychain

| Service name | Holds | Read by |
|---|---|---|
| `wakil:<org>:<ref>` | a database DSN, an API credential, or Jira (`ref` is `jira:<org>`) named by a `project.json` ref | Go `SecretGet` (`internal/wakilcore/secrets.go`, `keychainService`) |
| `wakil:<org>:provider:<id>` | an account's minted OAuth token (`ProviderTokenRef`) | Go; the app asks `wakil provider credentials` (`WakilCLICredentialsLookup`) |

Go reaches the Keychain only by running `/usr/bin/security` at its absolute path
(`internal/wakilcore/credpresence.go`). `WAKIL_KEYCHAIN` names a keychain file instead of the login
keychain; the e2e harness uses it. The Swift app never reads the Keychain directly. Values are
never written to `project.json`, only the ref.

## Only in memory

- **Pane contents** (`PaneStore`): rows, terminal blocks, api drafts and responses, editor tabs and their text (the layout saves only each file tab's path, cursor and scroll; a scratch buffer is not saved). A
  result set is not persisted; the pane's page and sort (`PaneFetch`) are, with the layout.
- **Recent api sends**, capped at `PaneStore.recentCap` (200) per list, gone with the session.
- **Live PTYs** (`TerminalStore`).
- **Pending confirmations** (`ConfirmationBroker`, one per conversation), resume and provider-switch requests (`ResumeBroker`,
  `ProviderSwitchBroker`).
- **The window's own state** (`WindowModel`): context, snapshots, thought thread, status, palette.
- **The window's git status** (`GitStatus`, mirrored in `WindowModel.gitRoots`, 3b-iii): one read
  per root, kept while an editor pane is open (`syncGitWatcher()` watches the roots then) and
  emptied when the last one closes or the organisation switches. Diff tabs are never saved; a
  saved Git pane loads as an editor pane on Changes (`layoutMigratingGitPanes`).

## What an org switch resets

`WindowModel.invalidateForOrgChange()` (`app/Sources/WakilKit/App/WindowModel.swift`) resets only
what belongs to the organisation itself: the vocabulary (`dropAll`), project and environment,
production flags (here and in the registry), settings and accounts, an in-flight sign-in (a mint in
flight is left to finish), the provider id, `lookup` and roots, capacity, the palette, and the
editor's pending requests and unsaved prompt (they name panes on the screen being left), and the
window's git status and its `gitRoots` mirror (of the screen's roots). Then
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
