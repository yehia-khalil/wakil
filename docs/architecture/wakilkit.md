# WakilKit

`WakilKit` (`app/Sources/WakilKit/`) is the testable library under the macOS app. It holds
everything the window does that is not drawing: the action registry, the stores, the MCP client and
server, the agent harness, the gate, and the window's model. `WakilApp` (the executable, no test
target) imports it and draws. It is **one Swift module**, so the compiler does not stop one folder
from using another; the folders are its layers, and `LayeringTests` is what keeps them honest.

A file at the module root, `WakilKit.swift`, holds only `enum WakilKit` and its `version`.

## The rules

| Rule | Enforced by |
|---|---|
| Nothing in WakilKit uses `App/` (`WindowModel` stays on top) | `wakilKitKeepsItsLayering` in `app/Tests/WakilKitTests/LayeringTests.swift` |
| `Core/` uses no other folder; any folder may use `Core/` | `wakilKitKeepsItsLayering` |
| Every other folder link is listed in `app/Tests/WakilKitTests/Fixtures/layering-allowed.txt` | `wakilKitKeepsItsLayering` (fails on an unlisted link) |
| The allow-list only shrinks | `wakilKitKeepsItsLayering` (fails on a listed link that no longer exists) |
| Every WakilKit folder has a `### <Folder>/` section in this file | `TestArchitectureDocsCoverEveryFolderAndBinary` in `scripts/architecture_docs_test.go` |

**How `LayeringTests` sees a link.** `FolderGraph.build` reads every `.swift` file under
`app/Sources/WakilKit/`. It indexes the names each folder declares: types (`struct`, `class`, `enum`,
`protocol`, `actor`, `typealias`) and top-level, non-`private` `func`, `let` and `var`. A file in
folder B that names something declared in folder A is a link `B -> A`. Comments and string literals
are stripped first, but the code inside a `\( )` interpolation is kept. A name declared in two
folders is skipped and listed, not guessed at, and so are the generic names in
`FolderGraph.genericNames` (`CodingKeys`, `Source`, `Contents`, `Kind`, `State`, `handle`). The test
prints the link count and the skipped names.

**Changing the allow-list.** If the test reports a new link, either remove the dependency or add the
line `From -> To` to `layering-allowed.txt`. The reviewer sees that line in the diff. If the test
reports a stale link, delete its line. Links into `Core/` are never listed.

## Folders

Each section says what the folder is for, its key types, what it uses (from the allow-list; every
folder may also use `Core/`), and the test files in `app/Tests/WakilKitTests/` that own it.

### Api/ — the api client pane's logic

The api pane's draft request, its editing rules, how a draft becomes a wire request, and its
actions. Everything the pane decides is a pure function here, so the view in `WakilApp` only draws.
The pane's stored state and its store methods live here too (see "Pane kinds" below).

- `ApiPaneKind.swift` — `ApiPaneKind` (the `PaneKind` conformance, name `api`), `ApiContents` (one
  pane's state), `ApiShared` (store-wide: the resolution mark, flight subscribers, recent sends),
  `ApiFlight`, `ApiRecentKey`, `ApiRecentList`, and `PaneSnapshot.api`.
  `ApiPaneKind+ReadPane.swift` — what `read_pane` returns for an api pane.
- `PaneStore+Api.swift` — the api pane's `PaneStore` methods, as an `extension PaneStore`
  (`openApi`, `setApiDraft`, `setApiResponse`, `clearApiResponses(to:)`, `beginApiSend`,
  `finishApiSend`, `recordApiSend`, `apiFlights`, `apiSources`, …); recent sends are in memory,
  `PaneStore.recentCap = 200`.
- `ApiSnapshot.swift` — `ApiSnapshot` and the api request and response types.
  `ApiSnapshot+Identifiers.swift` — its `OffersIdentifiers` conformance.
- `ApiDraft.swift` — `ApiDraft` (the request being drafted, four regions in wire order: path,
  query, headers, body), `ApiPart`, `ApiBinding`, `ApiWireRequest`.
- `ApiActions.swift` — `registerApiActions` (`api_open`, `api_set_request`, `api_bind`,
  `api_unbind`, `api_request`, `api_send`, `api_cancel`, `api_reopen`, `api_render_curl`,
  `api_fill_from_curl`, `api_undo_fill`, …), `ApiPaneResolver` (re-resolves every api pane on an
  environment change).
- `ApiResolveDraft.swift` — `resolveDraft`: a draft plus source-pane rows to a wire request, or one
  refusal naming every failure.
- `ApiEditorText.swift`, `ApiEditorRules.swift`, `ApiDraftAuthor.swift`, `ApiSaveAsTyped.swift` —
  the field editor's model, its key rules, who wrote what, and save-as-you-type.
- `ApiPathQuery.swift`, `ApiHeaderRegion.swift`, `ApiRows.swift`, `ApiParts.swift`,
  `ApiBodyFormat.swift`, `ApiCurlFill.swift`, `ApiChipKeys.swift` — one region or gesture each.
- `ApiPaneLayout.swift`, `ApiPaneLines.swift` — sizes and sentences the view draws.

Uses: `Context`, `Identifiers`, `Layout`, `MCP`, `Panes`, `Registry`.
Tests: `Api*Tests.swift` (for example `ApiSendTests`, `ApiResolveDraftTests`, `ApiWireContractTests`),
with `ApiTestSupport.swift`.

### App/ — the window's model and the assembly

The top layer. `WindowModel` is everything the window does that is not drawing; `WakilWiring`
assembles one Wakil. **Nothing else in WakilKit may use `App/`**, so code goes here only when it must
see everything (see `CONTRIBUTING.md`, "Where does my code go?").

- `WindowModel.swift` — `WindowModel` (`@MainActor @Observable`): the active context, the panes'
  snapshots (one cell per open pane, `paneCells`, read per pane through `terminal(_:)`, `api(_:)`
  and `editor(_:)`), the window's git status mirror (`gitRoots`, 3b-iii), the thought thread, the harness, the org switch. Every state change goes through
  `registry.dispatch(..., origin: .ui)` and its handlers. `WindowModel` itself writes `PaneStore`
  only for a few window-side marks (failure lines, api focus, response clears, a cleared terminal
  proposal, scope switches and the org-switch clear); see [runtime.md](runtime.md).
  3c-ii: it keeps the browser's sites in step with the config tree (`refreshSettings`, skipped when the
  org changed meanwhile), forgets a closed conversation's allow-list, and answers the site question:
  `siteQuestionWantsTyping` (true unless the proposing conversation's last turn, `PlaceAgent.lastTurnSource`,
  was typed) and `allowPendingSite` (a click answers only a `.site` ask that does not want typing).
- `WindowModelSupport.swift` — `apiSurfaceCallDetaches`.
- `QuickTasks.swift` — `QuickTasks` (3b-viii, Decision 42): the one entry point for quick tasks.
  `infill` and `respond` route to the org's `quickProvider`, else the active provider, fall back once
  when a local endpoint will not connect, keep the endpoint's error whole, and refuse after shutdown.
  `WindowModel+QuickTasks.swift` builds it per org and stops it on org switch and quit.
- `GhostText.swift` — ghost-text's logic, the same for both surfaces: the context window, schema table
  matching, reply clean-up and `GhostTextSession` (debounce, one request per pane, stale replies dropped).
  The editor's window side is in `WindowModel` too: a watcher on the project's roots while an editor
  pane is open (a change dispatches `editor_refresh`), ⌘T / ⌘S / ⌘W methods, saved-tab writes
  debounced after the last view report (`editorTabsDelay`), and **the unsaved prompt** —
  `UnsavedIntent` (close a tab, close a pane, switch organisation, quit), `UnsavedPrompt`,
  `resolveUnsaved(_:)` (Save / Don't Save / Cancel) and `requestQuit()`. A prompt is never replaced
  by another, except that a quit outranks one. `WakilApp/AppScene.swift` asks it on window close
  and on ⌘Q.
- `PaneKinds.swift` — `PaneKinds`: `standard` (every pane kind this build knows, the one list that
  names them all), `kind(named:)`, `is(_:_:)`. See "Pane kinds" below.
- `PaneSnapshotCell.swift` — `PaneSnapshotCell` (`@MainActor @Observable`): one pane's snapshot,
  observed on its own, so a terminal tick invalidates only the views reading that pane's cell
  (`refreshPanes`, after every action, still rewrites every cell).
- `AppWiring.swift` — `WakilWiring` (`build`, `switchOrg`, `shutdown`, `binaryURL`,
  `wakilOwnedClients`, `mcpSurface`, `useActiveContext(of:)`), `GitRootsSource`. See
  [runtime.md](runtime.md).
- `AgentMCPConfig.swift` — `agentFacingServers`, `agentMCPConfigJSON`, `agentAllowedTools`.
- `ComposerModel.swift`, `ComposerText.swift` — the composer bar's model (typed and spoken text).
- `ProviderCredentials.swift`, `ProviderCredentialsLookup.swift` (`WakilCLICredentialsLookup`),
  `ProviderMint.swift` (`WakilCLIProviderMint`), `ProviderLogin.swift`, `ProviderLoginSession.swift`,
  `ClaudeCodeProviderLogin.swift`, `ClaudeExecutable.swift`, `ClaudeLocator.swift`,
  `PseudoTerminal.swift` — accounts: reading and minting credentials through the `wakil` CLI, and the
  sign-in flow.
- `OrgListings.swift`, `PaletteItems.swift`, `SurfaceChain.swift`, `ThoughtRow.swift`,
  `ThreadDisclosure.swift` — smaller pieces the model uses.

Uses: every other folder (`Api`, `Command`, `Context`, `Gate`, `Git`, `Harness`, `Identifiers`,
`Layout`, `MCP`, `Panes`, `Query`, `Registry`, `Speech`, `Terminal`, `Visual`).
Tests: `WindowModelTests`, `WindowModelGitTests`, `WindowModelPaletteTests`, `WindowModelVoiceTests`,
`AppWiringTests`, `InvalidationContractTests`, `ShutdownContractTests`, `OrgSwitchTests`,
`PaneKindsTests`, `PaneSnapshotCellTests`,
`ComposerModelTests`, `ComposerTextTests`, `ProviderLoginTests`, `ProviderCredentialsLookupTests`,
`ClaudeExecutableTests`, `ClaudeLocatorTests`, `OrgListingsTests`, `SurfaceChainTests`,
`ThreadDisclosureTests`.

### Browser/ — the browser pane's logic

- `BrowserAddress.swift` — `BrowserAddress` (3c-i): the pure rule that turns typed text into a URL or a
  search (`resolve`, with the settings' search engine), `isSecure` (https, file, loopback http) and
  `displayHost` (host without `www.`, or a file's name), and `lockDetail` — what the address
  field's padlock says under the pointer: the host and TLS for https, plain HTTP for http (Not
  Secure except to a loopback host, beside `isSecure`, so the glyph and its words agree), and the
  certificate's reason when it was not trusted; nothing for a blank page.
- `BrowserSiteConsent.swift` — `BrowserSite` (3c-ii): which site a page is (`key`: host and any non-default
  port, `www.` kept; `label` for display), `BrowserSites` (the org's production sites and the active
  environment's tags, `www.` forgiven; unread means every site is production) and `browserActPrice`:
  production always gates, elsewhere only an agent on a site not allowed for the conversation does.
- `BrowserPage.swift` — a page as the agent reads it (3c-ii): `BrowserElement` (ref, role, label, state),
  `BrowserPageRead`, `BrowserPageAct` (click, type, select, press, scroll), `BrowserKeyName`, the
  `BrowserPageDriver` seam WakilApp's `BrowserPageAgent` fills, `browserFitToCap` (the 204,800-byte cap:
  says where it cut, never splits a character), `browserIdleWait` (the 1 s quiet after the operator
  types) and the copy helpers: labels trimmed to 60 characters, `browserThreadLine`, `browserStatement`.
- `BrowserFieldRules.swift` — `BrowserFieldRules` (3c-ii): the never-list of fields that are the
  operator's to fill (password, card number and code, one-time code), read from a field's type,
  autocomplete, name, id and label with camelCase split; `scriptSource` generates the same rules as
  JavaScript for the page script's act-time re-check, so the two cannot drift.
- `BrowserReachActions.swift` — `browserReachActions` (3c-ii): `browser_read_page` (`.read`);
  `browser_click`, `browser_type`, `browser_select`, `browser_press`, `browser_scroll` (`.mutate`,
  agent-reachable, each with a `callPrice` and a `proposal`); `browser_revoke_site` (`.control`,
  operator-only). `browserActTarget` is the one place an act is checked against the tab's last read
  (no read, unknown ref, URL changed, non-web page, never-list field, wrong role, unknown option, bad
  key); price and proposal run it and fall back to *allow* / nothing on any failure, and the handler
  runs it again. `BrowserReachError` holds the refusal sentences.
- `BrowserFocusRetry.swift` — `browserRetryFocus`: a page focus that waits for its web view to
  join the window asks again before every try whether the pane may still take the keyboard and the
  tab is still the active one, and gives up quietly when not (Rule 6).
- `BrowserDownloadNames.swift` — where a download lands (`browserDownloadDestination`: the suggested
  name cut to its last component, `name 2.ext` when taken) and the strip's size line
  (`browserDownloadSize`, decimal units).
- `BrowserSnapshot.swift` — `BrowserSnapshot` (tabs, `active` id, `find`, `downloads`, the ⌘⇧T
  `closed` stack, `nextTab` for `"t<n>"` ids), `BrowserTab` (with `loaded`, false until its web view has
  fetched, and `command`, the latest `BrowserCommand` for the host to apply), `BrowserFind`,
  `BrowserDownload` and `BrowserPageReport`, what a web view reports.
- `BrowserPaneKind.swift` — `BrowserPaneKind` (`browser`): contents are the snapshot, `failure` is the
  active tab's, `readPane` gives tabs, address, title, loading, history, zoom, find and downloads, and per tab the
  `site`, `production` and `environment` the agent's price follows, never page text; `PaneRestorable` restores saved tabs through `browser_restore`.
- `PaneStore+Browser.swift` — `browserSnapshot`, `updateBrowser` (the `updateEditor` shape),
  `browserRestore` (keeps the saved ids, loads only the active tab), and **the seam** the web view
  reports through: `browserPageDidReport`, `browserFindDidReport`, `browserDownloadDidChange`,
  `browserPageOpenedTab`. The seam never creates a pane and never issues a command. 3c-ii adds, in
  **memory only**: `browserSetSites` / `browserSites(org:)` (the organisation's production sites and
  the active environment's tags), the conversation allow-list (`browserAllow`, `browserAllowed`,
  `browserRevoke`, `browserForget`, in the browser kind's `Shared`, keyed by `PlaceAgent.id`) and
  each tab's last read (`browserRecordRead`, `browserDropRead`; a read whose first ref is not above
  `refsIssued` is refused, so a ref names one element). None of it is saved.
- `BrowserActions.swift` — `registerBrowserActions` (3c-i): `browser_open` (opens a pane when none is),
  `browser_navigate` (the address rule; refuses blank and `javascript:`), back, forward, reload, stop,
  new/close/reopen/select/move tab, focus address (⌘L), find, find step and close, zoom (the fixed ladder), download cancel
  and clear, and the operator-only `browser_restore`. `pane` defaults to the focused browser pane,
  else the one most recently focused, else the last opened (`LayoutStore.preferredPane`, one call over
  the arrangement and its in-memory focus order): the spec's call 11, where a link from elsewhere in
  Wakil opens. That link's one path is `WindowModel.openLinkInWakil` (`App/WindowModel+Links.swift`,
  `browser_open` with `newTab` and `keepFocus`, so a pane it has to open does not take focus, Rule 6);
  the app's `WakilLinks.open` sends it there, or to the system browser on ⌥-click. 3c-i routes the
  blame hover's Open on GitHub through it; 3c-iii routes the terminal's, the editor's and an API entry's
  links. Each command bumps its tab's `command.seq`; tab changes write the layout's
  saved tabs. Also `BrowserKey`, the keys `WindowModel.browserKey` takes over in a focused browser pane.
  `browser_clear_data` (`.mutate`, operator-only, gated in production and out of it) asks the injected
  `removeData` to delete the organisation's WebKit store, handing it the deletion of `tabs/` and
  `zoom.json` to run after the store is gone (`browserRemoveStoreThenFiles`: a store that will not
  go deletes nothing, and its error is shown whole). Its `org` is the organisation the
  operator's question named; it refuses `The organisation changed; ask again.` when that is no longer
  the active one, and refuses without a remover (nothing but the app can) or without an active
  organisation. `BrowserSettingsCache` holds the search engine and start page the actions read,
  refreshed by `WindowModel.refreshBrowserSettings` at launch and after a save.
- `BrowserOrgFiles.swift` — `BrowserOrgFiles` (3c-i): one organisation's `~/.wakil/orgs/<org>/browser/`:
  `profile.json` (the id of its `WKWebsiteDataStore(forIdentifier:)`, created on first use, replaced
  when unreadable), `zoom.json` (zoom per host) and `tabs/` (per-tab state, named by `stateKey`:
  a digest of the place, then pane and tab, since ids repeat from place to place). The organisation is used
  as the directory name as Go's `OrgDirFor` does; `init` throws for `/`, `.`, `..` or empty, never
  flattening, so no id can be shared. `WindowModel.browserOrgFiles` is the active organisation's, nil
  while none is active; the registered actions ask for the caller's own. WebKit keeps the store's own
  files under `~/Library/WebKit/`, outside Wakil's reach, so deleting them goes through `removeData`.
  `BrowserClearDataQuestion` is the Settings confirmation's copy and its Keep it / Delete labels.

Uses: `Layout` (`Pane`, `BrowserSavedTab`, `PaneRestorable`, `LayoutStore`), `Panes` (`PaneKind`,
`PaneStore`), `Registry` (`ActionRegistry`, `Action`).
Tests: `BrowserAddressTests`, `BrowserStoreTests`, `BrowserActionsTests`, `BrowserFocusRetryTests`, `WindowModelBrowserTests`.

### Command/ — the ⌘K and ⌘P palettes

The palettes' state machine and their lists, pure so the window only feeds keys and acts on effects.

- `PaletteModel.swift` — `PaletteModel`: modes, the `>` switch, input steps, one run per Return.
- `CommandCatalog.swift` — `CommandCatalog`: the curated ⌘K list, each row pinned to a registered
  action.
- `PaletteSources.swift` — `PaletteSource` and its sources (`OpenPanesSource`, `NewPaneSource`,
  `TablesSource`, `ApiEntriesSource`, `ChangedFilesSource`), `PaletteClients`. `FilesSource` does the same
  as the tree when `showIgnored` is false.
- `PaletteEntry.swift`, `PaletteItem.swift` (`fuzzyScore`), `PaletteSearch.swift`,
  `PaletteFocusReturn.swift`.

Uses: `Api`, `Context`, `Git`, `Identifiers`, `Layout`, `MCP`, `Panes`, `Registry`.
Tests: `PaletteModelTests`, `PaletteSearchTests`, `PaletteSourcesTests`, `PaletteTests`,
`CommandCatalogTests`.

### Context/ — the active organisation, project and environment

- `ContextStore.swift` — `ContextStore` (actor): wraps the `wakil-ctx` client and maps its
  `get_context` tool onto the active org, project and environment; `PartialContext` (what a failed
  `get_context` still knows); `mcpErrorText`.

Uses: `MCP`.
Tests: `ContextStoreTests`, `ContextListingTests`.

### Core/ — shared value types with no dependencies

The vocabulary every folder shares. **Uses no other folder** (tested), so anything here must stand
alone.

- `Action.swift` — `Action`, `ActionDescriptor`, `ActionKind` (`read`, `control`, `mutate`),
  `ActionAudience` (`agentReachable`, `operatorOnly`), `ActionOrigin` (`ui`, `agent`, `debug`).
  3c-ii adds `Action.callPrice` (a `.mutate` priced by the call, not the action), `Action.proposal`
  (what the plane shows for one call), `ActionProposal` (statement and ask) and `PendingAsk`
  (`change`, `site`, `productionSite`).
- `GateDecision.swift` — `GateDecision` (`allow`, `gate`, `block`).
- `JSONValue.swift` — `JSONValue`, `safeInt`, `safeInt64`.
- `ToolCaller.swift` — `ToolCaller`, the one-method port (`callTool`) every MCP client is used
  through.
- `EnvironmentName.swift` (`EnvironmentProduction`, `isProductionEnvironment`),
  `EnvironmentListing.swift`, `LayoutScope.swift` (`LayoutScope`; `ScopeRouting.home`, the task-local scope a dispatch writes
  into, read by `LayoutStore` and `PaneStore` in place of the on-screen one), `PaneContents.swift` (`PaneCell`,
  `PaneColumn`, `PaneSort`, `sortedRows`, `PaneSelection`), `WakilShimServerName.swift`
  (`wakilShimServerName = "wakil"`).

Uses: nothing.
Tests: `JSONValueIntegerTests`, `IntegerPassthroughTests`, `ToolCallerTests`, `PaneContentsTests`,
`PaneSelectionAfterClickTests`.

### Editor/ — the editor pane's logic

The `editor` kind (3b-i; the left column, search and find from 3b-ii):

- `EditorSnapshot.swift` — `EditorSnapshot` (tabs, the active one), `EditorTabSubject` (a file path or
  a scratch number — what a tab *is*, stable while its position moves), `EditorDiskState`
  (`inSync`, `changedOnDisk`, `deleted`), `EditorRange`. A tab holds its text, the text last read or
  written (what dirty is measured against), disk state, cursor, selection and scroll.
- `EditorPaneKind.swift` — the `PaneKind` conformance (`read_pane`: tabs with `preview`, the active
  tab's cursor, selection, visible lines and their text — never the whole file — and `column`,
  `find` and `search`) and its `PaneRestorable` conformance: the restore step is `editor_restore`,
  when the layout saved tabs or a column.
- `PaneStore+Editor.swift` — `updateEditor`, `editorViewDidReport`, and `editorBufferDidChange`, the one
  non-action path, for the operator's typing. It carries the agent-edit serial the page had applied
  (`basis`) and drops a write built before the latest agent edit, so an agent edit survives typing.
- `EditorTabs.swift` — titles (`parent/name` where two open files share a name), ⌘W's tab-then-pane rule, scratch
  numbers, language by extension, UTF-16 range helpers. 3b-ii-b adds the move and drop-target rules:
  `editorMovingTab` (the active tab stays the same tab), `editorTabDropTarget` (a drop over a tab takes
  its index; a gap takes the slot there; its own place or off the strip moves nothing), `EditorTabDrop`
  and `editorTabDropX` (where the violet drop line draws).
- `EditorActions.swift` — `registerEditorActions`: `editor_open`, `editor_new_scratch`,
  `editor_focus_tab`, `editor_close` (discards), `editor_goto`, `editor_select`, `editor_set_language`,
  `editor_replace_range`, `editor_save` (with an `as` path for a scratch tab; refuses a read-only tab;
  the one `.mutate`, priced *allow* — Decision 36), `editor_reload`, `editor_restore` (merges the saved
  tabs into the pane), `editor_refresh` (a disk change under a root, with the burst's paths). Files go through `wakil-files`.
  `pane_close` of an editor pane with dirty tabs refuses unless `discard: true`.
  3b-ii adds `editor_tree` (the column: shown, view, width), `editor_tree_expand` and
  `editor_tree_collapse` (refusing a path outside the roots), `editor_find`, `editor_search` (with
  `cancel`; `EditorSearchRuns` keeps one run per pane, so a newer search or a cancel stops the older)
  and `files_search`, which answers without touching a pane.
  3b-ii-b adds `editor_replace` (batched `files_replace`, open tabs edited in their buffers, `cancel`),
  `editor_replace_undo`, `editor_move_tab` and `editor_tree_reveal`, and `editor_search`'s `replace`.
  3b-iii adds `editor_changes_select`, `editor_changes_step`, `editor_changes_collapse`,
  `editor_changes_expand`, `editor_open_file`, and `editor_refresh`'s `what`. 3a-ii adds
  `editor_changes_group_collapse` / `_expand` (a group of one root, kept on the column for the
  window's life and never saved; readable as `column.changes_closed_groups`).
- `GhostBridge.swift` (3b-viii) — the editor's side of ghost-text: `ghostCaret`, `ghostTabContext`
  (which tab and caret a request is for) and `GhostRequestOrder` (a reply is dropped once a newer
  request was made).
- `EditorChanges.swift` (3b-iii) — the Changes view's rows over the window's `GitStatus`:
  `editorChangesRows` (step order, a collapsed root and a closed group left out), `editorChangesStep`,
  `editorChangesShown` (where the highlight goes when its group closes),
  `editorChangesResolve` (where the highlight goes after a refresh, Rule 6), `editorChangesFile` and
  `editorTreeStatus` (the Files tree's status letter).
- `EditorDiff.swift` (3b-iii) — diff tabs: `GitDiffState` (a diff's two sides and the facts about
  them), `gitDiffBanner`, `editorDiffRevs` (which revisions a group compares), `editorDiffOpensFile`
  and `editorCommandReturnOpensFile` (⌘⏎), and `EditorDiffFlights` (one fetch per diff tab).
- `EditorTree.swift` — `EditorRootListing` (one root's `files_list`: files, ignored, heavy folders,
  child repositories), `EditorDirEntry`, `EditorTreeRow` and `editorTreeRows` (what the column draws;
  it leaves ignored files out when `showIgnored` is false (3b-v)), the keyboard's steps (`editorTreeStep`, `editorTreeLeft`, `editorTreeTypeAhead`,
  `editorTreeSelection`), `editorColumnWidth` (160 pt to half the pane) and `editorPruneOpen`.
- `EditorFileLists.swift` — `EditorFileLists`, the window's one list per root, behind ⌘P's files source
  and every pane's tree: a `ToolCaller` that keeps `files_list` while the roots are watched,
  `invalidate`s a root the watcher reports, and loads heavy folders one at a time
  (`files_list_dir`); `EditorFileListsState` is what the trees draw from.
- `EditorSearch.swift` — `EditorSearchState` and `EditorSearchMatch` (the Search view: query, switches,
  in flight, the 2,000-match and 50,000-file caps, *changed since*, error, results),
  `editorSearchGroups` (by root, then file) and `editorSearchMarks`; `EditorFindRequest` (what the bar
  is asked to show), `EditorFindReport` (what Monaco reports back) and `editorFindMatches`;
  `EditorDebounce`, the 250 ms pause before a typed query runs.
- `EditorReplace.swift` (3b-ii-b) — `EditorReplaceState` (the Replace field: shown, text, preview, in
  flight, the last result and its undo record), `EditorReplaceResult`, `EditorReplaceUndoRecord`,
  `EditorReplaceFailure`, `EditorReplaceEdit`; `editorReplacePreviewSpans` (struck and inserted spans),
  `editorReplaceSummary` (*Replaced 3 in 3 files*), `editorReplaceAvailable`, and the decoders of
  `files_replace`'s batches (`editorReplaceBatch`, `editorReplacedTexts`; Decision 39).
- `EditorRenderer.swift` — the seam Monaco sits behind (`EditorRenderer`), `EditorRendered` (what it was
  last told, per tab) and `editorRenderSteps` / `editorSnapshotToRender`, which decide what to call so
  the untested view only applies steps.
- `EditorSettings.swift` — `EditorViewOptions` (what Monaco is told: font size, word wrap, tab size, insert
  spaces), `EditorSettings` (the app-wide and project tiers as `ctx_editor_settings` answers them, `appError`
  included), and `decodeEditorSettings`.
- `EditorAutosave.swift` — `editorAutosaveEligible` (a file, dirty, in sync with disk, writable, not saving),
  `EditorAutosaveStep`, and `EditorAutosave`, the per-pane memory that says which tabs to arm or save; the
  window keeps the timers.

Uses `Panes/`, `Layout/`, `Core/`, `Registry/`, `MCP/`, `Context/` and `Git/` (`Editor -> Git`,
3b-iii: the Changes view and diff tabs read the window's `GitStatus`; `Git/` uses nothing in
`Editor/`, so the link is one way). Window-side code is in `App/` (below).
Tests: `EditorStoreTests`, `EditorTabsTests`, `EditorActionsTests`, `EditorReadPaneTests`,
`EditorRefreshTests`, `EditorRendererTests`, `WindowModelEditorTests`, `EditorTreeTests`,
`EditorTreeActionsTests`, `EditorSearchTests`, `EditorSearchActionsTests`, `EditorChangesTests`,
`EditorChangesActionsTests`, `EditorDiffTabsTests`, `EditorDiffBannerTests`.

### Gate/ — the write gate and confirmations

- `WriteGate.swift` — `writeGate(environment:kind:origin:targetEnvironment:price:production:)`:
  `.read` is allowed; `.mutate` is priced by the action's `price` (production / otherwise, default
  block / gate); `.control` is gated only for an agent switching into or out of production.
  `environmentSwitchIsNoOp`.
- `ConfirmationBroker.swift` — `ConfirmationBroker` (actor): holds at most one refused mutation while
  a human decides. One per assembly, shared by the agent's path and the window's.
- `PendingMutation.swift` — `PendingMutation` (with its `ask`, 3c-ii), `ConfirmationDecision`, `mutationAffectsEveryRow`.

Uses: nothing but `Core`.
Tests: `WriteGateTests`, `ConfirmationBrokerTests`, `ProductionDeclarationTests`.

### Git/ — the window's git status

The Git pane kind folded into the editor in 3b-iii (Decision 40): what is left is the window's one
status and what reads it. A saved Git pane loads as an editor pane on Changes
(`Layout/LayoutStore.swift`, `layoutMigratingGitPanes`).

- `GitStatus.swift` — `GitStatus` (actor): the window's one `git_status` per root per wake, shared by
  the window, the editor's actions and `GitSource`; and the types it holds, moved here from the Git
  pane: `GitGroup`, `GitFileRow`, `GitRootState`, `GitActionError`.
- `GitPaneLines.swift` — the text helpers the Changes view draws: `gitRootLine`, `gitRootErrorDetail`,
  `gitGroupLabel`, `gitListSections`, `gitRowLabel`, `gitStatusTone`.
- `GitSource.swift` — `GitSource`, the changed files' names offered to the vocabulary, read from the
  window's `GitStatus` (so only while an editor pane keeps it).
- `GitWatcher.swift` — `RootWatcher` (protocol), `FSEventsRootWatcher`; `GitRootWatcher.swift` —
  `GitRootWatcher`, which the window tells which roots to watch.
- `GitHistory.swift` — a file's history and blame as `editor_timeline` and `editor_blame` read them
  (3a-v-a): `GitCommitInfo`, `GitBlameInfo`, `EditorBlameCache`, the blame text and its hover
  (`editorBlameHover`: Open Changes · Copy Commit ID, and 3c-i's Open on GitHub / GitLab / Bitbucket
  when the line carries `web`). `gitRemoteWebRepository` and `gitCommitWebPage` map an `origin`
  (scp-like, `ssh://` or `https://`, credentials and `.git` dropped) on github.com, gitlab.com
  (subgroups kept) or bitbucket.org to the commit's page; any other host is nil. `editor_blame`
  reads the root's origin once (`git_origin`, kept in `GitOriginCache` until the root's
  `editorBlameRefreshMark` moves, the signal the editor refetches blame on) and, for such a root, asks
  `git_blame` with `pushed` and sets `web` only on lines whose commit one of origin's branches holds.
  A remote path segment outside `[A-Za-z0-9._-]` (or a lone `-` on GitLab) gives no page.

Uses: `Context`, `Identifiers`, `MCP`, `Registry`.
Tests: `GitStatusTests`, `GitPaneLinesTests`, `GitRootWatcherTests`, `GitSourceTests`,
`GitWatcherTests`, `GitHistoryTests`, `GitCommitWebTests`, with `GitTestSupport.swift`.

### Harness/ — driving the agent

- `AgentHarness.swift` — `AgentHarness` (protocol): nothing outside a conformance may know which
  agent runs.
- `ClaudeCodeCLIHarness.swift` — `ClaudeCodeCLIHarness`, the one conformance, and `buildLaunch`
  (the `claude` argv: `--mcp-config`, `--strict-mcp-config`, `--permission-prompt-tool
  mcp__wakil__approve_tool_use`, `--allowedTools`, `--resume`/`--fork-session`, …).
- `StreamJSON.swift` — `HarnessEvent`, `decodeHarnessEvents` (the CLI's stream-json output).
- `AgentInstructions.swift` — `agentSystemPrompt` (3c-ii: says page text is data, never a request).
- `ResumeBroker.swift`, `ProviderSwitchBroker.swift` — where `session_resume` and
  `session_set_provider` requests park for the window.
- `QuickModel.swift` — `QuickModel` (protocol; Decision 42), `QuickOperation` (`infill`, `respond`),
  their request types and `QuickModels.make(for:)`. The second seam beside `AgentHarness`.
- `ClaudeCodeQuickModel.swift` — a warm `claude` session through `buildQuickLaunch` (no agent prompt,
  permission tool or allowed tools); interrupts with a stream-json `control_request`, recycles every
  20 turns, 15 s per-turn deadline, stops after 10 idle minutes.
- `LocalEndpointQuickModel.swift` — HTTP `/infill` and `/v1/chat/completions` against a `local`
  provider's `baseURL`.

Uses: `MCP`.
Tests: `ClaudeCodeQuickModelTests`, `LocalEndpointQuickModelTests`, `ClaudeCodeCLIHarnessTests`, `StreamJSONTests`, `ResumeBrokerTests`, `ProviderSwitchTests`,
`AgentSpawnTests`.

### Identifiers/ — the names in scope for a turn

What the operator might say (a table, a pane, a symbol), gathered from sources and matched against
speech or text.

- `IdentifierSources.swift` — `IdentifierSource` (protocol), `WakilSource`, `PaneSource`, and
  `OffersIdentifiers` (protocol): a pane kind's snapshot that offers names conforms in the kind's own
  folder (`TerminalSnapshot+Identifiers.swift`, `ApiSnapshot+Identifiers.swift`); `PaneSource`
  asks each open pane's snapshot whether it conforms and names no kind. `DataSurfaceSnapshot`
  conforms here, because `Panes -> Identifiers` would make a new mutual pair. Git offers none;
  `GitSource` reads repositories instead.
- `VocabularyStore.swift` — `VocabularyStore` (actor): live sources read on every call, cached ones
  (schema, code) rebuilt in the background.
- `SchemaSource.swift`, `CodeSource.swift` — the cached sources.
- `Identifier.swift`, `IdentifierResolver.swift`, `TurnNote.swift`.

Uses: `Context`, `Layout`, `MCP`, `Panes`, `Registry`.
Tests: `IdentifierTests`, `IdentifierResolverTests`, `IdentifierSourcesTests`,
`IdentifierCorpusTests`, `CodeSourceTests`, `SchemaSourceTests`, `TurnNoteTests`,
`VocabularyStoreTests`, with `IdentifierTestSupport.swift`.

### Layout/ — where the panes are

- `Pane.swift` — `Pane`, `PaneFrame`, `PaneDensity`; `Pane.kinds` (`db`, `terminal`, `api`,
  `settings`, `editor`: the kinds `pane_open` accepts and a loaded layout may hold), `Pane.settingsKind`.
  Which `PaneKind` holds each kind's contents is `App/PaneKinds.swift`'s, not this file's.
- `LayoutStore.swift` — `LayoutStore` (actor): every visited `LayoutScope`'s arrangement, the
  current one being the caller's `ScopeRouting.home` or else the one on screen (a focus off
  screen raises no focus request); `LayoutSnapshot`; `layoutMigratingGitPanes` (a saved Git pane
  becomes an editor pane on Changes, 3b-iii) and `layoutDroppingUnknownPaneKinds`.
- `LayoutPersistence.swift` — `LayoutPersistence`: reads and writes a scope's arrangement on disk
  (see [state.md](state.md)).
- `LayoutActions.swift` — `registerLayoutActions` (`pane_open`, `pane_close`, `pane_move`,
  `pane_resize`, `pane_snap`, `pane_focus`, `pane_maximize`, `pane_restore`, `pane_set_density`,
  `settings_open`). `pane_close` asks an injected `unsavedEditorTabs` closure for a pane's dirty
  editor tabs (wired in `App/AppWiring.swift`); Layout does not import Editor.
- `SnapSolver.swift`, `SnapGraph.swift` — magnetic snapping, as pure functions.

Uses: `Panes`, `Registry`, `Terminal`.
Tests: `LayoutStoreTests`, `LayoutActionsTests`, `LayoutPersistenceTests`, `PaneTests`,
`SnapSolverTests`, `SnapGraphTests`, `PaneDrawOriginTests`, `QueryTargetPaneTests`,
`PaneKindClassificationTests` (which checks `Pane.kinds` against `PaneKinds.standard` and
`PaneStore`).

### MCP/ — the protocol, both directions

- `MCPClient.swift` — `MCPClient` (actor): one child Go binary over stdio; `start()`, `callTool`,
  `stop()`. `MCPClient+ToolCaller.swift` makes it a `ToolCaller`.
- `MCPServer.swift` — `MCPSocketServer` (actor): the unix socket the shim connects to; `handle`;
  `MCPSurface` (registry, pane store and layout store as one value); the hand-written `read_pane`
  and `read_layout` tools. `read_pane` answers a settings pane from the config tree and every other
  pane with `PaneStore.readPane(paneId:kind:)`, which asks the pane's kind.
- `Shim.swift` — `runShim`: copies bytes between stdio and the socket; parses nothing.
- `PermissionPrompt.swift` — `approve_tool_use` (`permissionPromptToolName`), `permissionDecision`,
  `operatorOnlyActions`.
- `JSONRPC.swift`, `ConfirmationDescription.swift`.

Uses: `Gate`, `Layout`, `Panes`, `Registry`.
Tests: `MCPClientTests`, `MCPServerTests`, `JSONRPCTests`, `PermissionPromptTests`, `ShimTests`.

### Panes/ — what each pane shows

The store every pane's contents live in, the `PaneKind` protocol each kind conforms to, and the two
kinds that stay here (the db pane's data surface and settings). **`Panes/` names no other kind**:
Terminal, Api and Editor keep their conformance and store methods in their own folders.

- `PaneKind.swift` — `PaneKind` (protocol, refines `SendableMetatype`), `PaneKindSnapshot`
  (a kind's snapshot; equality across kinds is false), `PaneSlot` (one pane: its kind and that
  kind's contents, held opaquely). See "Pane kinds" below.
- `PaneStore.swift` — `PaneStore` (actor): one `PaneSlot` per pane id within a `LayoutScope`, and
  each kind's store-wide state. `PaneStore(kinds:)` takes the kinds list. The generic access each
  kind's store methods are written with is internal: `contents`, `setContents` (refuses a pane
  holding another kind), `holds`, `kindState` / `setKindState`, `scope(holding:paneId:where:)`,
  `inScope`, `paneKeys`, `activeScope`, `holdsContents`. Public and kind-free:
  `snapshot(paneId:kind:)`, `readPane(paneId:kind:)`, `paneIds`, `switchScope`,
  `drop`, `onDrop`. The db pane's methods are here too (`setRows`, `setSelection`, `setFailure`,
  `reorder`, `setScrollTarget`, `pageable`, `sort`, `editable`, …), with the db read flight
  (`beginDBRead`, `armDBRead`, `cancelDBRead`, `finishDBRead`): one read per
  pane, cancel ends it at once and keeps the rows, and a reply for a project switched away is dropped.
- `PaneSnapshot.swift` — `PaneSnapshot` (`kind`, `failure`, and `contents`, the kind's own
  snapshot), `PaneSnapshot.dataSurface`, `DataSurfaceSnapshot`, `PaneEditableSummary`.
- `DataSurfacePaneKind.swift` — `DataSurfaceContents` and `DataSurfacePaneKind` (name `db`; its
  subject, a read, re-runs on restore).
- `QuickTaskSettings.swift` (3b-viii) — the Settings choices for quick tasks: the org's Quick tasks
  list, a local provider's URL and what it serves, and the reachable-or-error line.
- `SettingsPaneKind.swift` — `SettingsPaneKind` (name `settings`): no contents in the store;
  `read_pane` builds a settings pane from the config tree (`MCP/MCPServer.swift`).
- `GridCopy.swift` — the grid's Copy formats (one cell, TSV with a header, JSON keeping types;
  repeated column names suffixed), used by `DataSurface`.
- `RowDetail.swift` — the row detail strip's fields (whole values, JSON pretty-printed), used by
  `RowDetailStrip`.
- `DataSurfaceKeys.swift` — the grid's key rule (⌘C, Space, ↑↓, Esc) and the footer's flight line.
- `PaneTable.swift`, `PaneFetch.swift`, `PaneEditable.swift` — the db pane's table, paging and sort,
  and cell write-back.
- `SettingsTree.swift`, `AccountTable.swift`, `UnlinkReport.swift`, `DatabaseConnection.swift` —
  the settings pane's decoded data (each environment carries `production`, the config tree's flag that
  `BrowserSites.from` reads).
- `TabStripLayout.swift` — `TabStripLayout`: a pane's tab strip when its tabs do not fit, the
  browser's and the editor's (`PaneTabStrip` draws it) — `widths` (200 pt while they fit, then
  shrinking evenly to 96, the active one to no less than 140, before the strip scrolls),
  `overflows` (for fixed widths, and for entries that keep their own width, the editor's),
  `hidden` (how many entries a scroll offset leaves out of sight on each side), `pageTarget` /
  `pageOffset` (where a side's count scrolls to) and `needsReveal` / `revealOffset` (whether, and
  where, the active entry is scrolled into view).

Uses: nothing but `Core`.
Tests: `PaneStoreTests`, `PaneKindStorageTests`, `PaneFetchTests`, `PaneEditableTests`,
`PaneColumnLayoutTests`, `AccountTableTests`, `DatabaseConnectionStringTests`, `TabStripLayoutTests`.

### Query/ — the db pane's query line

- `SQLTokenizer.swift`, `SQLStyle.swift`, `SQLFormat.swift` (`QueryDialect`, `SQLFormat`),
  `QueryLineKeys.swift`, `QueryLineGhost.swift` (3b-viii: when the query line asks — caret at the end
  of its line, multi-line only at the end of the text — and what Tab, Esc and Return do with a ghost).

Uses: nothing but `Core`.
Tests: `SQLTokenizerTests`, `SQLStyleTests`, `SQLFormatTests`, `QueryLineKeysTests`, `QueryLineGhostTests`,
`QueryDialectTests`.

### Registry/ — the one place every state change runs

- `ActionRegistry.swift` — `ActionRegistry` (actor): `register`, `all()`, and `dispatch(name:params:
  origin:environment:confirmation:)`, which asks `writeGate`, runs the handler and journals every
  outcome; `setProductionLookup` and `setScopeLookup` (an agent caller's own flags and scope;
  the scope is bound around the handler as `ScopeRouting.home`); **the price per call** (3c-ii): for a
  `.mutate` with a `callPrice` the registry works out the caller's home first and asks `callPrice`
  under the handler's own task-locals, so a background agent is priced against its own pane and site;
  `proposal(name:params:caller:)` describes a parked call the same way; `setScreenScope` (every other
  dispatch is bound to the scope on screen when it began, so writes after an await land there); `ActionError` (`unknown`, `needsConfirmation`, `blockedInProduction`).
- `StandardActions.swift` — `registerStandardActions` (the `ctx_*`, `db_*` and `session_*`
  actions, and `pane_sort`), `StandardActionError`, `readConfigTree`. `db_cancel` ends the pane's
  read; every pane-bound db read runs as a flight through `dbReadInFlight`.
- `Journal.swift` — `JournalEntry`, one line of the append-only journal.
- `DebugDispatch.swift` — `runDebugScript`, behind `--dispatch`.
- `PaneContentActions.swift` — `registerPaneContentActions` (`pane_select_cell`, `pane_select_rows`,
  `pane_scroll_to_row`, `pane_scroll_clear`, `pane_set_column_width`): the db pane's content
  actions, which refuse a pane of another kind by name.

Uses: `Context`, `Gate`, `Harness`, `Layout`, `MCP`, `Panes`.
Tests: `ActionRegistryTests`, `StandardActionsTests`, `DebugDispatchTests`, `DispatchCLITests`,
`JournalPermissionsTests`, `JournalReasonTests`, `JournalRedactionTests`, `ActionClassificationTests`,
`MutationActionTests` (`db_run_mutation`), `PaneContentActionsTests`.

### Speech/ — push-to-talk

- `SpeechProvider.swift` — `SpeechProvider` (protocol), `SpeechRegistry` (which engines exist; a new
  engine is one conformance and one entry).
- `AppleSpeechProvider.swift`, `ScriptedSpeechProvider.swift` — the conformances.
- `ListeningMachine.swift` — `ListeningMachine`, push-to-talk as a pure state machine.

Uses: nothing but `Core`.
Tests: `ListeningMachineTests`, `ScriptedSpeechProviderTests`, `SpeechRegistryTests`,
`SpeechWiringTests`, `SettingsOrgSpeechTests`.

### Terminal/ — the terminal pane's logic

- `TerminalStore.swift` — `TerminalStore` (actor): every live PTY, keyed by pane id, and only the
  live resource; each shell is keyed by the scope it was opened in and its pane id
  (`TerminalKey`; pane ids repeat across loaded scopes) and publishes into that scope; `shutdownAll(runStream:)`.
- `TerminalSession.swift` — `TerminalSession`, one shell.
- `TerminalPaneKind.swift` — `TerminalContents` (one pane's state), `TerminalPaneKind` (the
  `PaneKind` conformance, name `terminal`, and what `read_pane` returns for a terminal pane),
  `PaneSnapshot.terminal`.
- `PaneStore+Terminal.swift` — the terminal pane's `PaneStore` methods, as an `extension PaneStore`
  (`recordTerminal`, `setTerminalLiveState`, `setTerminalProposal`, `clearTerminal`,
  `appendMirrored`, …).
- `TerminalSnapshot.swift` — `TerminalSnapshot`. `TerminalSnapshot+Identifiers.swift` — its
  `OffersIdentifiers` conformance.
- `TerminalActions.swift` — `registerTerminalActions` (`term_open`, `term_propose`, `term_run`,
  `term_scroll`).
- `ShellIntegration.swift` — `shellLaunch`, `terminalChildEnvironment`.
- `ActiveShellContext.swift` — `ActiveShellContext`: the window's live org, project and environment
  for a new shell.
- `TerminalMirror.swift` (`TerminalMirrorFeed`: the agent's `Bash` calls mirrored into panes),
  `TerminalBlock.swift`, `TerminalLineEdit.swift`, `TerminalMarkScanner.swift`,
  `TerminalAnsiColor.swift`, `TerminalPaneSupport.swift`.

Uses: `Harness`, `Identifiers`, `Layout`, `Panes`, `Registry`, `Visual`.
Tests: `Terminal*Tests.swift` (for example `TerminalStoreTests`, `TerminalActionsTests`,
`TerminalLineEditTests`).

### Visual/ — design-language values

Pure numbers and colours the views and the Metal shader read.

- `Plane.swift` (`Plane`), `CoreState.swift` (`CoreState`), `CoreMotion.swift`, `BreathClock.swift`,
  `VoidPalette.swift`, `VoidUniforms.swift`, `EnvironmentBadge.swift`, `RailTreatment.swift`,
  `Contrast.swift`.

Uses: `Terminal`.
Tests: `PlaneTests`, `CoreStateTests`, `CoreMotionTests`, `BreathClockTests`, `VoidPaletteTests`,
`VoidUniformsTests`, `EnvironmentBadgeTests`, `RailTreatmentTests`, `ContrastTests`.

## The cycle

Measured from `layering-allowed.txt` with the Python snippet in Task 9 Step 2 of
`docs/superpowers/plans/2026-10-11-pluggable-pane-kinds-and-architecture-docs.md`, run from the
repository root.

| | Before the pluggable pane kinds stack | After it (2026-10-11) |
|---|---|---|
| Listed links | 67 | 62 |
| Cycle groups | one, of 11 folders: `Api`, `Context`, `Git`, `Harness`, `Identifiers`, `Layout`, `MCP`, `Panes`, `Registry`, `Terminal`, `Visual` | one, of 8 folders: `Context`, `Harness`, `Identifiers`, `Layout`, `MCP`, `Registry`, `Terminal`, `Visual` |
| Mutual pairs | 10 | 4 |

The stack removed seven links and added two:

- Removed: `Panes -> Api`, `Panes -> Git`, `Panes -> Layout`, `Panes -> Registry`,
  `Panes -> Terminal` (each kind's code left `Panes/`, and `PaneContentActions.swift` moved to
  `Registry/`); `MCP -> Api` (`read_pane` asks the pane's kind); `Identifiers -> Api`
  (`PaneSource` asks `OffersIdentifiers`).
- Added: `Api -> Identifiers`, `Terminal -> Identifiers` (each kind's `OffersIdentifiers`
  conformance lives in its own folder).

The six mutual pairs that went: `Api <-> Panes`, `Git <-> Panes`, `Layout <-> Panes`,
`Panes <-> Registry`, `Panes <-> Terminal`, `Api <-> MCP`. `Panes` now uses nothing but `Core`, and
`Api`, `Git` and `Panes` are outside the cycle with `App`, `Command`, `Core`, `Gate`, `Query` and
`Speech`.

The four left: `Layout <-> Registry`, `Layout <-> Terminal`, `MCP <-> Registry`,
`Terminal <-> Visual`. They were out of the stack's scope.

## Pane kinds

A pane kind is a `PaneKind` conformance in its own folder. `PaneStore` holds each pane as a slot of
some kind and names no kind outside `Panes/` (the data surface and settings kinds live there);
`App/PaneKinds.swift` is the one list naming every kind.

- **The protocol** — `Panes/PaneKind.swift`: `protocol PaneKind: SendableMetatype` with associated
  types `Contents` (one pane's state), `Shared` (store-wide state, default `Void`) and `Snapshot` (a
  `PaneKindSnapshot`, what a reader gets). Requirements: `names` (the `Pane.kind` strings it
  serves), `emptyContents`, `emptyShared`, `emptySnapshot` (what a never-written pane answers;
  `nil` for settings), `rerunsSubjectOnRestore` (default `false`), `snapshot(of:in:)`,
  `failure(of:)` (default `nil`), `readPane(_:in:)` (its keys in `read_pane`'s answer, merged into
  the `kind` / `failure` envelope), and two scope hooks on the store-wide state,
  `sharedAfterClearingAllScopes` (default: back to `emptyShared`) and `sharedAfterSwitchingScope`
  (default: unchanged). `snapshot(of:in:)` and `readPane(_:in:)` run isolated to the store, because
  Api's previews read data-surface rows. Refining `SendableMetatype` is what makes
  `[any PaneKind.Type]` `Sendable` under Swift 6.
- **Restoring** — `Layout/PaneRestorable.swift`: a kind that must do something when its pane is
  restored (launch, an org switch loaded from disk) conforms to `PaneRestorable` and returns a
  `PaneRestoreStep` (an action, its params, whether a refusal is written into the pane) from
  `restoreStep(for:)`. `WindowModel.restorePaneContents` names no kind. Two conform: `db`
  (`db_refetch`) and `editor` (`editor_restore`). `rerunsSubjectOnRestore` is the older flag
  for a kind whose subject is a read.
- **Slots** — `PaneStore` keeps one `PaneSlot` (the kind and its contents) per pane id per
  `LayoutScope`. A kind's store methods use `contents(K.self, paneId)` (the kind's empty contents
  for a pane holding nothing or another kind) and `setContents(K.self, paneId, _)` (refuses a pane
  holding another kind). Store-wide state is `kindState(K.self)` / `setKindState(K.self, _)`,
  created on first touch so that a scope change reaches state that has only been read.
  `switchScope(to:)` and `switchScope(to:adoptingFrom:)` call each touched kind's hook.
- **The kinds list** — `App/PaneKinds.swift`: `PaneKinds.standard` (`DataSurfacePaneKind`,
  `TerminalPaneKind`, `ApiPaneKind`, `SettingsPaneKind`, `EditorPaneKind`), `kind(named:)` and
  `is(_:_:)`. `WakilWiring.build` passes it to `PaneStore(kinds:)`; the store uses it only for a
  pane that was never written. A never-written pane of a kind the list does not hold answers no
  contents and a failure naming the kind, not an empty grid.
- **Where each kind's code lives:**

  | Kind | Folder | Files |
  |---|---|---|
  | `db` | `Panes/` | `DataSurfacePaneKind.swift`; its store methods in `PaneStore.swift` |
  | `settings` | `Panes/` | `SettingsPaneKind.swift` (no contents in the store) |
  | `terminal` | `Terminal/` | `TerminalPaneKind.swift`, `PaneStore+Terminal.swift`, `TerminalSnapshot.swift`, `TerminalSnapshot+Identifiers.swift` |
  | `api` | `Api/` | `ApiPaneKind.swift`, `ApiPaneKind+ReadPane.swift`, `PaneStore+Api.swift`, `ApiSnapshot.swift`, `ApiSnapshot+Identifiers.swift` |
  | `editor` | `Editor/` | `EditorPaneKind.swift`, `PaneStore+Editor.swift`, `EditorSnapshot.swift`, `EditorTabs.swift`, `EditorActions.swift`, `EditorRenderer.swift`, `EditorTree.swift`, `EditorFileLists.swift`, `EditorSearch.swift`, `EditorReplace.swift`, `EditorSettings.swift`, `EditorAutosave.swift`, `EditorChanges.swift`, `EditorDiff.swift` |

- **`read_pane`** — `PaneStore.readPane(paneId:kind:)` builds the envelope and merges the pane's
  kind's `readPane`. `MCPServer`'s `read_pane` calls it; settings is answered in
  `MCP/MCPServer.swift` from the config tree.
- **Identifiers** — `Identifiers/IdentifierSources.swift` defines `OffersIdentifiers`; a kind's
  snapshot conforms in the kind's folder, and `PaneSource` asks each pane's snapshot.
- **The window** — `WindowModel.paneCells` holds one `PaneSnapshotCell` (`App/PaneSnapshotCell.swift`)
  per open pane; views read it through `terminal(_:)`, `api(_:)` and `editor(_:)`. `refreshPanes()`
  writes each pane's cell (`setCell`) and replaces the dictionary only when a pane opens or closes;
  `refreshTerminal(pane:)` writes only its own pane's cell, so a tick writes only that pane's
  cell and only views reading that cell are invalidated (the 240.5 ms/frame rule in its doc
  comment). Whether SwiftUI then redraws only that view depends on `paneView`'s call site in
  `WakilApp/Canvas.swift`, which is unchanged and untested. `PaneSnapshotCellTests` pins the write
  (including that a tick leaves another pane's existing cell alone), and `paneCells` is classified
  in `InvalidationContractTests`.
- **The canvas switch stays** — `WakilApp/Canvas.swift` keeps its `switch pane.kind`, the one
  view-side place a new kind touches (see [wakilapp.md](wakilapp.md)).

| Rule | Enforced by |
|---|---|
| Every kind in `PaneKinds.standard` is listed once and no two serve the same name | `everyKindIsListedOnceAndNamesAreUnique` in `PaneKindsTests.swift` |
| Every `Pane.kinds` entry has a kind, and every kind's names are `Pane.kinds` entries | `everyLayoutKindIsServed`, `everyKindsNamesAreLayoutKinds` (`PaneKindsTests`); `everyLayoutKindHasAPaneKind` (`PaneKindClassificationTests`) |
| Every kind's never-written pane answers `read_pane` with its kind and no failure | `everyKindsEmptyPaneAnswersReadPane` (`PaneKindsTests`) |
| A pane holding one kind refuses another's write; store-wide state hears scope changes | `PaneKindStorageTests` |
| Only `db` (a read) re-runs its subject on restore; a kind that restores by its own action (`editor_restore`) conforms to `PaneRestorable` instead | `onlyReadsRerunOnRestore`, `theOnlyKindsWhoseSubjectIsRerunAtLaunchAreReads` (`PaneKindClassificationTests`) |
| `Panes/` uses no folder but `Core`, so it names no kind outside it | `wakilKitKeepsItsLayering` (no `Panes -> ` line is listed, so a new one fails) |

Adding a kind: `CONTRIBUTING.md`, "A new pane kind".
