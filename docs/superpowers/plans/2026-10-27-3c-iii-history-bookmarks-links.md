# 3c-iii: history, bookmarks and links — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The browser remembers where the operator has been and what they kept: the address field suggests
open tabs, bookmarks and history as they type (and, if they turn it on, the search engine's suggestions),
⌘D bookmarks a page, ⌘P lists open tabs and bookmarks, and a ⌘-click on a URL in the terminal or the editor
opens it in Wakil's browser.

**Architecture:** Everything that decides is WakilKit: the history store (`BrowserHistory`, SQLite through the
system library, one file per organisation), bookmarks (`bookmarks.json` beside it, cached per organisation in
the browser kind's `Shared`), the ranking and inline completion (`BrowserSuggestions`), the engine suggestion
URL and parser, and where a URL sits in a terminal line (`TerminalLinks`). WindowModel records a visit when a
tab's load finishes and answers the address field's question. WakilApp draws the list and the ★ menu, and
routes ⌘-clicks to `WakilLinks.open`, which already exists (the blame hover uses it).

**Tech Stack:** Swift 6 / SwiftUI / AppKit, `SQLite3` (system module), `NSDataDetector`, WebKit, Monaco
(`monaco.editor.registerLinkOpener`), Swift Testing; Go (`internal/wakilcore/browsersettings.go`).

**Spec:** `docs/superpowers/specs/2026-10-25-3c-browser-design.md`: call 10, call 11, call 12's 3c-iii line,
"History, bookmarks and links (3c-iii)". Also decision 8 of
`docs/superpowers/specs/2026-10-26-3c-browser-next-decisions.md` (search-engine suggestions as a setting, off
by default). That note's later items (tab groups, identities, passwords, PiP, vertical tabs) are out of scope.

## Rulings

Every choice the spec left open is decided here. Each one is a **planner's call**.

1. **History is one row per URL**: `visits(url TEXT PRIMARY KEY, title TEXT NOT NULL, count INTEGER NOT NULL,
   last REAL NOT NULL)`, where `last` is seconds since 1970. Only `http` and `https` pages are recorded. A
   visit is recorded when a tab's load **finishes** (`isLoading` goes from true to false) with no failure; a
   title that changes after the load updates the row's title without counting a visit. Rows older than 90
   days are deleted on every write. Agent navigations count too: history is what the tab showed.
2. **No connection is kept open.** Each `BrowserHistory` call opens the file, runs, and closes, with
   `busy_timeout` 2000 ms and `journal_mode=WAL`. That costs well under a millisecond locally, needs no cache
   on WindowModel, and lets the clear-data action delete the files under no open handle.
3. **Clear browsing data deletes history** (`history.sqlite`, `-wal`, `-shm`) **and keeps bookmarks**, as
   Safari's Clear History does. The question's copy says so (Global Constraints).
4. **A bookmark is `{url, title, added}`**, stored in `bookmarks.json` in the order bookmarks were added and
   matched by exact URL string. A `bookmarks.json` that exists but does not parse is never written over: a
   toggle refuses with the file's error, so a bookmark list is never lost.
5. **`browser_bookmark {pane?, tab?, on?}`** is `.control`, `.agentReachable`. With `on` omitted it toggles
   (⌘D), `true` adds and `false` removes, so an agent states what it means. Only `http`, `https` and `file`
   pages can be bookmarked. The reply is the pane's `read_pane` plus `pane`, and `read_pane` gains
   `bookmarked` (the active tab's, a Bool; `false` with no tab). Bookmarks themselves are not in `read_pane`.
6. **The agent does not read history.** No action lists it. Opt-in history as the agent's context is an
   unconfirmed item in the decisions note, so it is left out.
7. **Ranking.** Matching ignores case. A candidate's *bare URL* is its URL without the scheme, a leading `www.`
   and a trailing `/`. The typed text is trimmed and split on whitespace, and every word must occur in the bare
   URL or the title, or the candidate is dropped. Score: 3 when the bare URL starts with the whole typed text, 2
   when a title word (split on non-alphanumerics) starts with the first typed word, else 1. Groups go in a fixed
   order: **open tabs** (≤ 3, strip order on ties), **bookmarks** (≤ 3, newest first on ties), **history**
   (filling to 8 rows in all, then `count` desc and `last` desc on ties), and **search** (≤ 4, the engine's
   order, only when the setting is on). A URL already in an earlier group is dropped from later ones. The tab
   being edited is never suggested. Empty text gives no rows.
8. **Inline completion** comes from the first row, in group order, whose bare URL starts with the typed text,
   and only when the text has no whitespace. It completes to the end of the host, or to the whole bare URL
   once the typed text contains `/`. It is offered only after a character is inserted at the end of the
   field. A deletion or a caret moved off the end drops it. The completed part is selected, so the next
   keystroke replaces it.
9. **Keys in the field.** ↓ and ↑ move the highlight through the rows, and the field then shows that row's URL,
   or its words for a search row. ↑ above the first row brings back what was typed. Return opens the highlighted
   row, else what the field shows (the typed text plus any completion). Esc with rows showing hides them and
   restores what was typed. Esc with no rows keeps today's behaviour. Choosing a tab row is
   `browser_select_tab`, a bookmark or history row is `browser_navigate {input: url}`, and a search row is
   `browser_navigate {input: words}`. A click on a row chooses it.
10. **Engine suggestions** (setting `searchSuggestions`, default off) are asked only for text that is not an
    address (`BrowserAddress.looksLikeAddress` false), 150 ms after the last keystroke, through an
    **ephemeral** `URLSession` (no cookies, no cache, so no organisation's login travels with them), with a
    2 s timeout. A failure shows no search rows and says nothing. Endpoints, all returning OpenSearch
    `[query, [s1, s2, …]]`: Google `https://suggestqueries.google.com/complete/search?client=firefox&q=`,
    DuckDuckGo `https://duckduckgo.com/ac/?type=list&q=`, Bing `https://api.bing.com/osjson.aspx?query=`.
    **Kagi has none**: its endpoint needs the operator's Kagi login, which an ephemeral session lacks.
11. **⌘P's Resources** gain two sources after the API entries: **open tabs** (every tab of every browser pane
    on the canvas; title `BrowserTab.label`, subtitle the bare URL, kind `tab`, verb `switch to`, dispatching
    `browser_select_tab {pane, tab, focus: true}`) and **bookmarks** (title, bare URL, kind `bookmark`, verb
    `open`, dispatching `browser_open {url, newTab: true}`). `browser_select_tab` gains `focus` (Bool, default
    false), which focuses the pane through `LayoutStore.focus(id:)`.
12. **The ★ control** sits at the address row's right, before the tag chip. It is one `Menu`: the first item is
    `Bookmark This Page` or `Remove Bookmark` (⌘D shown), then a divider, then every bookmark, newest first,
    which opens in the active tab (`browser_navigate`). The glyph is `star.fill` in §5's amber when the active
    tab is bookmarked, `star` at the meta opacity otherwise. With no bookmarks the list part reads `No
    bookmarks yet`.
13. **⌘D** is a `Browser` menu item, `Add Bookmark` (`BrowserKey.bookmark`). Outside a browser pane the key is
    passed on as the other browser keys are, so Monaco's ⌘D (select the next match) keeps working. The browser
    web view passes ⌘D (key code 2) to the menu first, as it already does ⌘T and ⌘L.
14. **Terminal links.** Only text that itself starts with `http://` or `https://` is a link, so `main.go` and
    `foo.sh` never become links. The end of the URL is `NSDataDetector`'s. A link keeps its run's colour and
    gains an underline at 0.35 of that colour. **⌘-click** opens it in Wakil (`WakilLinks.open`), **⌘⌥-click**
    in the system browser, and a plain click does nothing to the link, so selection works as it does today.
    This covers the live grid, an operator block's output and an agent block's output. A URL wrapped across
    two live-grid rows links only the part on each row (a known limit, in the runbook).
15. **Editor links.** Monaco already detects URLs and follows them on ⌘-click. The host page registers a link
    opener that posts `{type: 'link', url, alt}` for `http` and `https` and declines anything else, and the
    renderer hands it to the same closure the blame hover's Open uses. That closure is renamed from
    `blameWeb` to `openLink` on the host, since it now serves both.
16. **`BrowserTab.label`** (title, else display host, else `New Tab`) moves from WakilApp's `browserTabLabel`
    into WakilKit, because ⌘P needs it and a label is a pure decision. Every call site switches to it.

## Global Constraints

- Platform floor `macOS 14.4`. No new Swift package dependency (`SQLite3` and `NSDataDetector` ship with
  macOS). Go changes only in `internal/wakilcore/browsersettings.go`, its test and `cmd/wakil-ctx`'s tool text.
- Files under `~/.wakil/orgs/<org>/browser/`: `history.sqlite` and `bookmarks.json`. History keeps **90 days**.
- Action changes: `browser_bookmark` (new, `.control`, `.agentReachable`); `browser_select_tab` gains `focus`;
  `read_pane` gains `bookmarked`. No action reads history.
- Copy, verbatim:
  - Clear question: `Delete <org>'s browsing data? Every site signs you out, in every project, and its history
    is deleted. Bookmarks stay.`
  - Refusals: `browser_bookmark: only a web page can be bookmarked, not <scheme>:`;
    `browser_bookmark: bookmarks.json can't be read (<error>) — fix or move it; Wakil won't write over it.`
  - ★ menu: `Bookmark This Page`, `Remove Bookmark`, `No bookmarks yet`. Menu bar: `Add Bookmark`.
  - Settings → Browser → Search: a toggle `Search suggestions`, hint `Sends what you type in the address bar
    to the search engine as you type. Off, nothing leaves the Mac until you press Return. Kagi gives none.`
  - Suggestion row kinds (accessibility and ⌘P `kindLabel`): `tab`, `bookmark`, `history`, `search`.
- Accessibility identifiers: `browser.suggestions`, `browser.suggestion.<n>` (0 first), `browser.bookmarks`
  (the ★ menu), `browser.bookmark.toggle`, `settings.browser.searchSuggestions`.
- Nothing committed names a home path or a real organisation: use `example.com`, `initech`.
- No `Co-Authored-By` or "Generated with" lines in commits.

## Review Focus

1. **A history write racing a clear.** A load finishing while Clear browsing data runs must not leave a
   `history.sqlite` behind with the old organisation's pages in it. Pinned in Task 2's
   `aWriteAfterRemovalStartsAFreshFileWithOnlyThatVisit` and Task 5's
   `historyIsNotRecordedForAPlaceNoLongerOnScreen`. Recording goes through `browserScopeIsShown`, and clear
   runs after the store's pages are gone.
2. **One organisation's history suggesting in another's.** An organisation switch must change which file
   is read. Pinned in Task 5's `suggestionsReadTheActiveOrganisationsHistoryOnly`.
3. **A broken `bookmarks.json`.** Toggling must refuse rather than write `[]` over it. Pinned in Task 3's
   `aBookmarkFileThatDoesNotParseIsNeverWrittenOver`.
4. **Text that looks like a link but isn't** in the terminal (`main.go`, `v1.2.3`, `user@host:path`, a URL
   followed by `)` or `.`). Pinned in Task 7's table.
5. **The typed text leaking.** Engine suggestions must never be asked for while the setting is off, nor for an
   address, nor with cookies. Pinned in Task 5's `noEngineIsAskedWhileTheSettingIsOff` and
   `anAddressIsNeverSentToTheEngine`, and Task 4's `theSuggestionSessionCarriesNoCookies`.

---

### Task 1: The `searchSuggestions` setting

**Files:**
- Modify: `internal/wakilcore/browsersettings.go`, `internal/wakilcore/browsersettings_test.go`
- Modify: `cmd/wakil-ctx/main.go` (the `browser_settings` and `set_browser_settings` descriptions)
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsBrowser`)
- Test: `app/Tests/WakilKitTests/BrowserActionsTests.swift` (decode)

**Interfaces:**
- Produces: Go `BrowserAppSettings.SearchSuggestions bool \`json:"searchSuggestions,omitempty"\``,
  `BrowserSettings.SearchSuggestions bool \`json:"searchSuggestions"\``, and `BrowserSettingsPatch` gains a
  `*bool` for it. Swift `SettingsBrowser.searchSuggestions: Bool` (default `false`, decoded with
  `decodeIfPresent`), with `init(searchEngine:startPage:searchSuggestions: Bool = false)`.

- [ ] **Step 1: Write the failing Go tests** `TestBrowserSettingsSearchSuggestionsDefaultsOff` (a missing
  key reads `false`), `TestWriteBrowserSettingsSearchSuggestionsKeepsOtherKeys` (writing `true` keeps
  `searchEngine` and the `editor` key), and the Swift test `browserSettingsDecodeSearchSuggestions` (`{}` →
  `false`; `{"searchSuggestions": true}` → `true`).
- [ ] **Step 2: Run them to see them fail:** `go test ./internal/wakilcore -run SearchSuggestions` and
  `make app-test` (filter `browserSettingsDecodeSearchSuggestions`). Expected: they fail to compile.
- [ ] **Step 3: Implement** the field through read, resolve, patch and write, and the tool descriptions
  (`searchSuggestions (true or false; off by default)`).
- [ ] **Step 4: Run them to see them pass:** `make build && go test ./internal/wakilcore && make app-test`.
- [ ] **Step 5: Commit** `browser: the search-suggestions setting, off by default`.

### Task 2: The history store

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserHistory.swift`
- Modify: `app/Sources/WakilKit/Browser/BrowserOrgFiles.swift` (`historyURL`, the removal, the doc comment's
  file list), the clear question's copy in the same file
- Test: `app/Tests/WakilKitTests/BrowserHistoryTests.swift`, `BrowserOrgFilesTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserHistoryEntry: Sendable, Equatable { url: String; title: String; count: Int; last: Date }`
  - `public struct BrowserHistory: Sendable { public init(url: URL); func record(url: String, title: String,
    at: Date, newVisit: Bool) throws; func matching(_ words: [String], limit: Int) throws -> [BrowserHistoryEntry];
    static let keep: TimeInterval = 90 * 86_400 }`. `matching` returns rows where every word occurs in the URL
    or title (SQL `LIKE` with `%`, `_` and `\` escaped, `ESCAPE '\'`), ordered `count DESC, last DESC`.
  - `BrowserOrgFiles.history: BrowserHistory` (at `historyURL`, `<dir>/history.sqlite`).
  - `removeEverythingButTheProfile()` also removes `history.sqlite`, `-wal` and `-shm`, and keeps
    `bookmarks.json`.

- [ ] **Step 1: Write the failing tests** in `BrowserHistoryTests` (each on a temporary directory):
  `aFinishedVisitIsRecordedAndCounted` (two `newVisit: true` records → `count == 2`, `last` is the second
  date); `aTitleChangeIsNotAVisit` (`newVisit: false` → count unchanged, title updated; with no row it inserts
  nothing); `onlyWebPagesAreRecorded` (`file:///x`, `about:blank` and `data:…` → no rows);
  `rowsOlderThanNinetyDaysAreDroppedOnWrite` (a row at `now - 91 days`, then any write → gone; one at 89 days
  stays); `everyWordMustMatchUrlOrTitle` (`["initech", "docs"]` finds `https://docs.initech.dev` and not
  `https://initech.dev`); `likeWildcardsInTypedTextAreLiteral` (`"100%"` matches only a URL holding `100%`);
  `aWriteAfterRemovalStartsAFreshFileWithOnlyThatVisit`. In `BrowserOrgFilesTests`:
  `clearingRemovesHistoryAndKeepsBookmarksAndProfile`, and the clear question's new copy.
- [ ] **Step 2: Run them to see them fail:** `make app-test`. Expected: `BrowserHistory` is undefined.
- [ ] **Step 3: Implement** with `import SQLite3`: open with `sqlite3_open_v2(…, READWRITE|CREATE|FULLMUTEX)`,
  `PRAGMA journal_mode=WAL`, `busy_timeout(2000)`, `CREATE TABLE IF NOT EXISTS` (ruling 1), and bound
  parameters only (never text interpolated into SQL). Create the directory on the first write; a read of a
  missing file returns `[]` without creating it.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: history per organisation, 90 days, cleared with browsing data`.

### Task 3: Bookmarks, `browser_bookmark` and `BrowserTab.label`

**Files:**
- Modify: `BrowserOrgFiles.swift` (bookmarks), `BrowserPaneKind.swift` (`BrowserShared.bookmarks`,
  `readPane`'s `bookmarked`), `PaneStore+Browser.swift`, `BrowserActions.swift` (`browser_bookmark`,
  `BrowserKey.bookmark`, `browser_select_tab`'s `focus`), `BrowserSnapshot.swift` (`BrowserTab.label`)
- Modify: `app/Sources/WakilApp/BrowserPaneHeader.swift` and other callers of `browserTabLabel` (switch to
  `label` and delete the free function)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`browserKey`'s `.bookmark` → `browser_bookmark`)
- Test: `BrowserOrgFilesTests.swift`, `BrowserActionsTests.swift`, `BrowserStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserBookmark: Codable, Sendable, Equatable { url: String; title: String; added: Date }`
  - `BrowserOrgFiles.bookmarks() throws -> [BrowserBookmark]` (`[]` when missing; throws when present but
    unparsable); `setBookmark(url: String, title: String, on: Bool?, now: Date) throws -> Bool` (the result
    is whether it is bookmarked afterwards; `on == nil` toggles).
  - `PaneStore.browserSetBookmarks(org: String, _ b: [BrowserBookmark])`, `browserBookmarks(org:) -> [BrowserBookmark]`.
  - `BrowserKey.bookmark`.
  - `extension BrowserTab { public var label: String }`.

- [ ] **Step 1: Write the failing tests:** `aBookmarkTogglesOnAndOff`, `onTrueTwiceKeepsOneBookmark`,
  `bookmarksKeepTheOrderTheyWereAdded`, `aBookmarkFileThatDoesNotParseIsNeverWrittenOver` (the bytes are
  unchanged after the refusal); `browserBookmarkTogglesTheActiveTabAndReadPaneSaysSo` (`bookmarked` flips, and
  the store's org list updates); `browserBookmarkRefusesANonWebPage` (`about:blank` → the copy);
  `readPaneAlwaysCarriesBookmarked` (`false` with no tab); `selectTabWithFocusFocusesThePane` (the layout's
  focused id becomes the pane; without `focus` it stays); `tabLabelFallsBackToHostThenNewTab`. Then update the
  classification test list (`browser_bookmark` is `.agentReachable`).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.** `browser_bookmark` reads `orgFiles()`, writes, then sets the store's list from the
  file, so the file stays the truth. `readPane`'s `bookmarked` compares the active tab's URL with
  `browserBookmarks(org: store.activeScope.organization)`.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: bookmarks per organisation and browser_bookmark`.

### Task 4: Ranking, inline completion and the engine's suggestions (pure)

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserSuggestions.swift`
- Modify: `BrowserAddress.swift` (`looksLikeAddress`)
- Test: `app/Tests/WakilKitTests/BrowserSuggestionsTests.swift`, `BrowserAddressTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserSuggestion: Sendable, Equatable, Identifiable { enum Kind: String { case tab,
    bookmark, history, search }; kind: Kind; title: String; url: String /* words for .search */; tab: String? }`
    with `id` `"\(kind):\(url)"`.
  - `public enum BrowserSuggestions { static func rank(_ typed: String, tabs: [BrowserTab], editing: String?,
    bookmarks: [BrowserBookmark], history: [BrowserHistoryEntry], search: [String]) -> [BrowserSuggestion];
    static func completion(_ typed: String, in rows: [BrowserSuggestion]) -> String? /* the suffix */;
    static func bareURL(_ url: String) -> String; static func words(_ typed: String) -> [String] }`
  - `public enum BrowserEngineSuggest { static func url(engine: String, query: String) -> URL? /* nil for
    kagi and unknown */; static func parse(_ data: Data) -> [String]; static func session() -> URLSession }`
  - `BrowserAddress.looksLikeAddress(_ typed: String) -> Bool`: true exactly when `resolve` would not search.

- [ ] **Step 1: Write the failing tests:** `groupsComeTabsBookmarksHistorySearch`;
  `groupLimitsAreThreeThreeEightFour`; `aUrlInAnEarlierGroupIsDroppedLater`; `theTabBeingEditedIsNotSuggested`;
  `aPrefixOfTheBareUrlOutranksATitleWordOutranksContains`; `historyTiesGoByCountThenLast`;
  `emptyTextSuggestsNothing`; `completionRunsToTheEndOfTheHost` (`"git"` over `https://github.com/x/y` →
  `"hub.com"`); `completionRunsToTheWholeUrlOnceASlashIsTyped` (`"github.com/x"` → `"/y"`);
  `noCompletionWithWhitespace`; `completionKeepsWhatWasTypedAndIgnoresCase` (`"GIT"` → `"hub.com"`);
  `engineUrlsEncodeTheQuery` (each engine's URL for `a&b c`; kagi → nil); `parseReadsOpenSearchAndIgnoresJunk`
  (`["q",["a","b"]]` → `[a, b]`; `{}` and non-JSON → `[]`); `theSuggestionSessionCarriesNoCookies`
  (`session().configuration.httpCookieStorage == nil`, `httpShouldSetCookies == false`,
  `urlCache == nil`, `timeoutIntervalForRequest == 2`); and `looksLikeAddress` over `BrowserAddressTests`'
  existing table (`localhost:3000` true, `confirm booking 409` false).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** to rulings 7, 8 and 10.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: address suggestions ranked, inline completion, engine suggest`.

### Task 5: The window records visits and answers the field

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`browserPageDidReport`; bookmarks loaded where the
  organisation's sites are set, ~:2306 and ~:9695; a new `browserSuggestions`)
- Test: `app/Tests/WakilKitTests/WindowModelBrowserTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces: `public func browserSuggestions(typed: String, pane: String) async -> [BrowserSuggestion]` (local
  groups only) and `public func browserEngineSuggestions(typed: String) async -> [String]` (empty when the
  setting is off, the text is an address, the engine has no endpoint, or the fetch fails). The view merges
  them with `BrowserSuggestions.rank`. For the test, the engine fetch goes through an injectable
  `browserSuggestFetch: @Sendable (URL) async throws -> Data` (default: `BrowserEngineSuggest.session()`),
  classified in `InvalidationContractTests` as not org-derived.

- [ ] **Step 1: Write the failing tests:** `aFinishedLoadIsRecordedOnce` (reports loading → loaded → a title
  change → `count == 1` and the new title); `aFailedLoadIsNotRecorded`; `historyIsNotRecordedForAPlaceNoLongerOnScreen`;
  `suggestionsReadTheActiveOrganisationsHistoryOnly` (a visit in `initech`, switch to `personal` → no history
  row); `bookmarksAreLoadedWhenTheOrganisationIsActivated`; `noEngineIsAskedWhileTheSettingIsOff` (the fetch
  closure records no call); `anAddressIsNeverSentToTheEngine` (setting on, `localhost:3000` → no call);
  `engineSuggestionsComeBackWhenOn` (a stubbed `["q",["a"]]` → `["a"]`).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.** In `browserPageDidReport`, after `browserScopeIsShown`: when the tab's previous
  `isLoading` was true and the report's is false with no failure, record a visit; when only the title
  moved on a finished page, record with `newVisit: false`. The history write runs in a `Task.detached` on the
  `BrowserOrgFiles` of `scope`, never the active one, so a write can't land in another organisation.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: visits recorded on load, suggestions answered per organisation`.

### Task 6: ⌘P lists open tabs and bookmarks

**Files:**
- Modify: `app/Sources/WakilKit/Command/PaletteSources.swift` (`BrowserTabsSource`, `BookmarksSource`),
  `app/Sources/WakilKit/App/WindowModel.swift` (`paletteOpenSources`, after the API entries)
- Test: `app/Tests/WakilKitTests/PaletteSourcesTests.swift` (or the file that tests `ApiEntriesSource`)

**Interfaces:**
- Produces: `public struct BrowserTabsSource: PaletteSource { init(tabs: @escaping @Sendable () async -> [(pane:
  String, tab: BrowserTab)]) }` with id `browsertabs`, and `public struct BookmarksSource: PaletteSource {
  init(bookmarks: @escaping @Sendable () async -> [BrowserBookmark]) }` with id `bookmarks`, both
  `group = .resources`, with rows per ruling 11 and entry ids `browsertab:<pane>/<tab>` and `bookmark:<url>`.

- [ ] **Step 1: Write the failing tests:** `openTabsRowSwitchesToTheTabAndFocusesItsPane` (the action is
  `browser_select_tab` with `pane`, `tab`, `focus: true`; title is `label`, subtitle the bare URL);
  `bookmarkRowOpensInANewTab`; `bookmarksAreListedNewestFirst`; `noBrowserPaneGivesNoTabRows`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement**, reading tabs from the layout's browser panes and the store, and bookmarks from
  `browserBookmarks(org:)`.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `palette: open tabs and bookmarks under Resources`.

### Task 7: Links in the terminal

**Files:**
- Create: `app/Sources/WakilKit/Terminal/TerminalLinks.swift`
- Modify: `app/Sources/WakilApp/TerminalPane.swift` (`terminalRunText` takes a link; the live grid,
  `OperatorRow.outputText` and `MirroredRow` output go through `TerminalLinks.split`, plain fallbacks included,
  as one default-style run per line; an `openLink: (String, Bool) -> Void` on `TerminalPane` and an
  `.environment(\.openURL, …)` per ruling 14), `app/Sources/WakilApp/Canvas.swift` (pass `openLink` as for
  the editor at :501)
- Test: `app/Tests/WakilKitTests/TerminalLinksTests.swift`

**Interfaces:**
- Produces: `public struct TerminalLink: Sendable, Equatable { range: Range<Int> /* Character offsets */; url:
  URL }`; `public enum TerminalLinks { static func find(in line: String) -> [TerminalLink]; static func
  split(_ runs: [TerminalStyleRun]) -> [(run: TerminalStyleRun, link: URL?)] }`.
- The openURL handler reads `NSApp.currentEvent?.modifierFlags`: without ⌘ it returns `.discarded`; with ⌘
  it calls `openLink(url.absoluteString, flags.contains(.option))` and returns `.handled`.

- [ ] **Step 1: Write the failing tests:** a table test `onlySchemedHttpUrlsAreLinks` over `See
  https://example.com/a.` → `https://example.com/a` (the trailing `.` excluded); `(https://example.com/x)` → the
  parens excluded; `main.go`, `v1.2.3`, `git@github.com:o/r.git`, `example.com`, `ftp://example.com` → none;
  `http://localhost:3000/api?x=1#y` → whole; two URLs in one line → two links in order. Then
  `splitCutsRunsAtLinkEdges` (one run holding text, URL, text → three pieces, only the middle linked, styles
  kept) and `aLinkAcrossTwoRunsLinksBothPieces`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** `find` with `NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)`,
  keeping only matches whose own text starts with `http://` or `https://` (case-insensitive). Then the view
  per ruling 14.
- [ ] **Step 4: Run them to see them pass:** `make app-test`, then `make build`.
- [ ] **Step 5: Commit** `terminal: ⌘-click a URL opens it in Wakil's browser, ⌘⌥ in the system's`.

### Task 8: Links in the editor

**Files:**
- Modify: `app/Sources/WakilApp/monaco-host.html` (a link opener beside the blame commands, reusing
  `pressAlt`), `app/Sources/WakilApp/MonacoEditorRenderer.swift` (handle `type: 'link'`),
  `app/Sources/WakilApp/EditorPane.swift` (`blameWeb` renamed `openLink`; `:210`, `:857`, `:956`)

**Interfaces:**
- Consumes: the `openLink` closure `Canvas.swift:501` already passes.
- Message: `{type: 'link', url: string, alt: boolean}`. The opener returns `true` only for `http`/`https`.

- [ ] **Step 1: Add the opener** with `monaco.editor.registerLinkOpener({ open(resource) { … } })`, posting
  and clearing `pressAlt` as the blame `web` command does.
- [ ] **Step 2: Handle the message** in the renderer and route it to `openLink(url, alt)`, validating that
  `url` is a string with an `http`/`https` scheme before passing it on (the page is Wakil's own, but a
  file's text is not).
- [ ] **Step 3: Build:** `make build`. Expected: success. There is no WakilKit logic here. The Cover rung's
  check exercises it (a fixture file holding a URL, ⌘-click, the browser pane opens the fixture page).
- [ ] **Step 4: Commit** `editor: ⌘-click a URL opens it in Wakil's browser`.

### Task 9: The pane on screen: suggestions, the ★ menu, ⌘D and the setting

**Files:**
- Create: `app/Sources/WakilApp/BrowserSuggestionList.swift`
- Modify: `app/Sources/WakilApp/BrowserPane.swift` (the field's keys, rows and completion per rulings 8–9;
  `.onKeyPress` for ↓ ↑ Esc; the completion set through the field editor as `selectAddress()` already reaches
  it), `BrowserPaneHeader.swift` (`BrowserBookmarkMenu`, ruling 12), `BrowserWebView.swift` (key code 2 in
  `commandKeys`), `AppScene.swift` (`Add Bookmark` ⌘D in the `Browser` menu), `BrowserSettingsForm.swift` (the
  `Search suggestions` toggle with the hint copied from Global Constraints)

**Interfaces:**
- Consumes: `browserSuggestions(typed:pane:)`, `browserEngineSuggestions(typed:)`,
  `BrowserSuggestions.rank`/`completion`, `browserBookmarks(org:)`, `browser_bookmark`, `BrowserKey.bookmark`.
- Layout: the list overlays the page under the address field, the field's width, rows 26 pt, at most 12; each
  row is a glyph (`square.on.square` tab, `star` bookmark, `clock` history, `magnifyingglass` search), the
  title at `SettingsScale.body`, and the bare URL in mono at `metaSize`/`metaOpacity`; the highlight is the
  rail's row lift. It is drawn inside the pane (Rule 8), never a window.
- Local rows are asked on every edit, and engine rows through `.task(id: draft)` after 150 ms, so a newer
  keystroke cancels an older ask.

- [ ] **Step 1: Build the list and the keys.** Run `make build`. Expected: success.
- [ ] **Step 2: Build the ★ menu, ⌘D and the setting toggle.** Run `make build`. Expected: success.
- [ ] **Step 3: Check the rules on paper.** Rule 2: Return is the field's stated exception, unchanged. Rule 3:
  focus stays in the field while rows show. Rule 6: choosing a tab row stays in the pane. Rule 7: Esc restores
  what was typed. No confirmation is added anywhere. Write each in the commit body.
- [ ] **Step 4: Commit** `browser: address suggestions, the ★ menu and ⌘D on screen`.

### Task 10: Docs, and the hand-off to Cover

**Files:**
- Modify: `docs/architecture/README.md` (Browser: the history store and bookmarks; Terminal: `TerminalLinks`),
  `docs/wakil/north-star.md` §8 (the 3c-iii row: Built), `docs/wakil/design-language.md` §11's Browser row
  (suggestions, ★, ⌘D), the decisions note (decision 8 marked built)

- [ ] **Step 1: Update the docs.** Keep north-star within its word budget, which already fails (4334/4000):
  replace words, don't add.
- [ ] **Step 2: Run** `make build && make test && make app-test`. Expected: green except the known
  north-star word count, unchanged or lower.
- [ ] **Step 3: Commit** `docs: 3c-iii`.
- [ ] **Step 4: Hand the branch to the e2e auditor (Cover).** It should check: suggestions (each group, ↓ ↑,
  Return, Esc, a click), inline completion, ⌘D and the ★ menu, ⌘P's two sources, `browser_select_tab
  {focus}`, the setting toggle, and ⌘-click links from a terminal block and an editor file onto the fixture
  server. **Ask the operator before using the screen.**
