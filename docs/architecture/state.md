# State: what is kept where

Everything Wakil keeps, where it lives, and who writes it. `~` is `HOME` as the process sees it:
both the Swift side and Go read the `HOME` variable, so an overridden `HOME` moves all of it.

## On disk

| What | Path | Written by |
|---|---|---|
| Organisation record (display name, Jira site, default provider, speech engine) | `~/.wakil/orgs/<org>/org.json` | Go: `org.go`, `orgupdate.go` (`wakil org`, `wakil-ctx` `create_org` / `update_org`) |
| App-wide editor settings (the `editor` key: font size, word wrap, autosave) | `~/.wakil/settings.json` | Go `editorsettings.go` (`wakil-ctx` `set_editor_settings`) |
| Project registry (name → `project.json` path, preferred provider) | `~/.wakil/orgs/<org>/projects.json` | Go: `registry.go` (`wakil project`) |
| Active context (project, environment, provider) | `~/.wakil/orgs/<org>/active.json` | Go: `active.go` (`wakil-ctx` `set_project`, `set_environment`, `set_provider`) |
| Provider (account) records | `~/.wakil/orgs/<org>/providers/<id>.json` | Go: `provider.go`, `adopt.go`, `unlink.go` |
| Session lineage (which session was forked from which) | `~/.wakil/orgs/<org>/sessions.json` | Go: `sessions_lineage.go` (`record_session_parent`) |
| A project's configuration (roots, scopes, environments, databases, API entries, editor tabs) | the project's `project.json`, by convention `.wakil/project.json` inside the project | the operator; Go `projectwrite.go` (`set_database_dsn`, `remove_database`) and `editorsettings.go` (`set_project_editor_settings`, the `editor` key) |
| Pane arrangement per project | `~/.wakil/layouts/<org>/<project>.json` | Swift: `LayoutPersistence` |
| Pane arrangement per conversation | `~/.wakil/layouts/<org>/conversations/<lineageRoot>/<project>.json` | Swift: `LayoutPersistence` |
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

- **Pane contents** (`PaneStore`): rows, terminal blocks, api drafts and responses, git state, editor tabs and their text (the layout saves only each file tab's path, cursor and scroll; a scratch buffer is not saved). A
  result set is not persisted; the pane's page and sort (`PaneFetch`) are, with the layout.
- **Recent api sends**, capped at `PaneStore.recentCap` (200) per list, gone with the session.
- **Live PTYs** (`TerminalStore`).
- **Pending confirmation** (`ConfirmationBroker`), resume and provider-switch requests (`ResumeBroker`,
  `ProviderSwitchBroker`).
- **The window's own state** (`WindowModel`): context, snapshots, thought thread, status, palette.

## What an org switch resets

`WindowModel.invalidateForOrgChange()` (`app/Sources/WakilKit/App/WindowModel.swift`) clears
everything derived from the outgoing organisation: the vocabulary (`dropAll`), project and
environment, production flags (here and in the registry), the session (`sessionStarted`,
`assignedSessionId`, `lineageRoot`), settings and accounts, an in-flight sign-in (a mint in flight
is left to finish), every pane snapshot and query-line state, database choices and layout scope,
the thought thread and mirror, the provider id and harness, the pending confirmation and queued
switch, the layout snapshot, api send requests and the palette. Then it awaits
`layout.clearAllScopes()`, `panes.clearAllScopes()`, `terminals.shutdownAll(runStream: .keepOpen)`
and `syncGitWatcher()`. `organization` is set by the caller, `setOrganization`.

**The tripwire.** `everyWindowModelPropertyIsClassifiedForTheOrgSwitch` in
`app/Tests/WakilKitTests/InvalidationContractTests.swift` reads every stored property of
`WindowModel` by reflection and fails on one not classified as org-derived or org-independent. It
proves every property was thought about, not that the reset is right;
`invalidationClearsEveryOrgDerivedValue` in `OrgSwitchTests.swift` covers the reset itself. Adding a stored property to `WindowModel` means
classifying it there (and resetting it here if it is org-derived).

The Go side is reset by `WakilWiring.switchOrg`, which restarts every Wakil-owned client under the
new `WAKIL_ORG`; `everyWakilOwnedClientJoinsTheOrgSwitch` (`AppWiringTests`) keeps that list whole.
