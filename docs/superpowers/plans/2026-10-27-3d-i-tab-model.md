# 3d-i: the tab model — groups, pinning, vertical tabs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A browser pane's tabs take a shape: same-site tabs and a page's own pop-ups fall into automatic
groups named once by the `respond` quick task; the operator makes, renames, recolours, collapses and
drags tabs between their own groups; one pull-request group per organisation fills itself from its GitHub
account; tabs and groups pin per project; and a Browser setting turns the strip into a left column that
⌃⌘S tucks away.

**Architecture:** Every rule is WakilKit and pure where it can be: the site key (`BrowserSiteKey`, eTLD+1
from a bundled public-suffix snapshot plus a family table), the grouping rules on `BrowserSnapshot`
(`BrowserGrouping.swift`), the naming prompt and reply rule (`BrowserGroupNames`), the pins file
(`BrowserOrgFiles.pins`) and the ⌘W second-press rule (`BrowserPinnedClose`). The store applies them at
the seam (a tab opened by a page, a load that finished) and in the `browser_*` actions; groups are pane
state saved in the layout beside the tabs. WindowModel asks for names, reconciles pins and keeps the
pull-request list fresh through Go's `ctx_github_pull_requests`. WakilApp draws group chips in the strip
and the vertical column (`BrowserTabColumn.swift`).

**Tech Stack:** Swift 6 / SwiftUI / AppKit, WebKit, Swift Testing; Go (`internal/wakilcore`, `cmd/wakil-ctx`,
`net/http` to the GitHub search API). No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md`: "Decisions the operator
took", calls 1–10, "Lane A, 3d-i", "What it does not do", Design, Interaction rules, Errors and edges,
Testing and Charter changes, as they apply to 3d-i. Identities (3d-ii), picture-in-picture (3d-iii) and
passwords (3d-iv) are out of scope: no `BrowserTab.identity`, no `pictureInPicture` setting, no Invariant 4
or 6 edits here.

## Rulings

Every choice the spec left open, and every place it disagrees with the code, is decided here. Each is a
**planner's call** unless it says otherwise.

1. **The action is `browser_move_tab`, not `browser_tab_move`.** The spec's name does not exist; the shipped
   action gains `group` (spec gap: the code wins).
2. **`BrowserGroup` lives in `Layout/Pane.swift`**, beside `BrowserSavedTab`, not in `Browser/`: `Layout/`
   may not use `Browser/` (`wakilKitKeepsItsLayering`), and the layout saves groups. One type serves the
   snapshot and the layout.
3. **A pin is an id, not a Bool.** `BrowserTab.pin: String?` and `BrowserGroup.pin: String?` name the entry in
   `pins/<project>.json`; `BrowserTab.isPinned` is derived (`pin != nil`, or its group has a pin). Unpin
   in every pane and *Pin Current Page* need the id the spec's `pinned: Bool` cannot carry.
4. **Order.** `tabs` is always kept in drawn order by `arrange()`: pinned tabs, pinned groups, the
   pull-request group, then every other group **in the order it was made**, then loose tabs. The spec's
   list puts "your groups" before "automatic groups"; that would move a group the moment the operator
   renames it, which Rule 6 forbids. **Rule 6 wins**: becoming yours never moves a group.
5. **Colours.** Six swatches, in this order: `blue #7f97b2`, `steel #8d98a8`, `teal #77a0a3`, `sand #ad9f86`,
   `stone #a0938b`, `smoke #9b9da6`. The spec excludes violet, amber and red; design-language §5 reserves
   green too, so none is green-leaning. A new automatic group takes the first swatch no group in the pane
   uses, else swatch `groups.count % 6`.
6. **Site key** (`BrowserSiteKey.of`): nil for anything not `http`/`https`. Then, in order: a **family** when
   the host is, or ends in `.`+, one of `youtube.com youtu.be` (`family:youtube`, *YouTube*), `atlassian.net
   atlassian.com` (`family:atlassian`, *Atlassian*), `github.com githubusercontent.com` (`family:github`,
   *GitHub*), `docs.google.com drive.google.com sheets.google.com slides.google.com` (`family:google-docs`,
   *Google Docs*); a loopback host, an IP literal, or a host ending `.test` or `.localhost` → `host:port`
   (`BrowserSite.key`'s form); else the registrable domain from the public-suffix rules (wildcards and `!`
   exceptions honoured; a host that is itself a suffix, or one label, is its own key). A site's name is the
   family's, else the key's first label with its first letter upper-cased (`amazon.com` → *Amazon*), else
   the key itself for `host:port`.
7. **The opener rule runs when the tab is made; the site rule runs when a load finishes** (`isLoading` true
   → false, no failure — history's visit rule). So a server redirect through a sign-in host never moves a
   tab. A tab made with a URL and no opener sits loose until its first load finishes.
8. **The opener rule, exactly.** The opener is in a group that is not the pull-request group → the new tab
   joins it and keeps `opener`. The opener is loose, not pinned and not `keptLoose`, and the new tab's site
   key differs from the opener's → the two form an automatic group with `siteKey` nil, named after the
   opener's title cut to three words (else the opener's site name). Otherwise the new tab gets no `opener`
   and waits for the site rule.
9. **The site rule, exactly**, for a tab that is not pinned and not `keptLoose`: in an own group, or in an
   automatic group it joined by opener → it stays. In an automatic group of another site key → it leaves.
   Then an automatic group of its key in the pane → it joins; else every other loose eligible tab of that
   key, with it, forms an automatic group (at two). An automatic group left with one tab dissolves; an own
   group left empty is removed; an own group of one stays.
10. **`keptLoose`.** A tab the operator drags out of a group, or whose group they ungroup, is marked
    `keptLoose` and the site rule never pulls it into a group again; dragging it into a group clears it.
    Without it, Ungroup would be undone by the next tab of the site (spec: "Wakil then never regroups").
11. **Becomes yours** (kind `.automatic` → `.own`): rename, recolour, pin, a tab dragged into or out of it.
    Collapse does not. An own group is never touched by the rules above.
12. **Naming.** A group is due when it is automatic, `named` is false, and at least two of its tabs have a
    non-empty title; the window asks once per group per launch. Titles: up to five, in the order the tabs
    were opened (`t<n>` ascending). The reply lands only if the group still exists, is still automatic and
    `named` is still false, in the same place; it sets `name` and `named = true`. A model failure is kept
    by `QuickTasks` as today; a reply that does not parse is recorded with `QuickTasks.recordFailure` so
    Settings shows it whole. Off, or no provider, the fallback name stays.
13. **The pins file.** `~/.wakil/orgs/<org>/browser/pins/<project>.json`, the project's registry key
    percent-encoded (`BrowserOrgFiles.encoded`'s rule). `{"items":[…]}`, each item
    `{"id","kind":"tab"|"group"|"pullRequests", "url","title"}` for a tab, `{"id","kind","name","colour",
    "tabs":[{"url","title"}]}` for a group. Pin ids are `p` + the first 8 hex of a UUID. Written whole and
    atomically; a file that exists and does not parse is never written over, and its error goes on every
    browser pane of the project (`BrowserSnapshot.pinsError`) and in `browser_pin`'s refusal. Clearing
    browsing data keeps `pins/`, as it keeps bookmarks.
14. **Reconcile.** *Full* — when a browser pane is opened, restored, or its canvas is shown: every pin the
    pane lacks is added (unloaded, not selected); every tab or group whose pin id the file no longer holds
    is removed (the active one replaced as `browser_close_tab` does). *Delta* — after `browser_pin`,
    `browser_unpin` and *Update Pin*: only that pin is added to, or removed from, every other browser pane
    on the canvas. Unpin keeps the tab or group in the pane it was unpinned in, unpinned.
15. **Closing a pinned tab** (× or ⌘W twice) closes it in this pane only; the pin stays and the tab comes
    back at the pane's next full reconcile. Removing a pin is Unpin. Tabs of a pinned group count as pinned
    for ⌘W.
16. **Updating a pin.** A pinned tab's *Pin Current Page* rewrites its entry's `url` and `title`; a pinned
    group's *Update Pin* rewrites its `name`, `colour` and `tabs` from the pane. Delta reconcile does not
    re-point other panes' live pages (call 8).
17. **The pull-request read** is wakil-ctx's `github_pull_requests`, dispatched as `ctx_github_pull_requests`,
    `.read`, `.agentReachable`: it reads the **active** organisation (`CurrentOrg()`), takes no `id`, and
    returns no credential, so an agent cannot read another organisation's list. Its account: the
    organisation's git account with provider `github`, `github.com` first, else the first by host. API base
    `https://api.github.com` for `github.com`, else `https://<host>/api/v3`. Two searches, `is:pr is:open
    author:@me` and `is:pr is:open review-requested:@me`, `per_page=50`, `sort=updated`, merged by URL with
    `author` winning, newest first.
18. **The pull-request group in a pane** has id `pr`, kind `.pullRequests`, name `Pull Requests`, starts
    **collapsed** (a long list in every pane would crowd it; Rule 9: a default). Each entry is a tab with
    `pullRequest` set to the PR's URL and the title `<title> · <repository>#<number>` until its page loads.
    A refresh matches by `pullRequest`: listed ones stay with their pages, new ones are added unloaded, gone
    ones are removed — except the active tab, which leaves the group as a loose tab. Its tabs are not saved
    in the layout; the group's `collapsed` is. Pinning it writes an item of kind `pullRequests`, which sorts
    it into the pinned section.
19. **Refresh times.** A loop starts when the canvas first shows a browser pane, runs a refresh, then one
    every 300 s while any browser pane is on the canvas; it ends with the last pane, on an organisation
    switch and on shutdown. A pane opened while the loop runs gets the cached list. ⌘R with the group's
    header focused refreshes now; a refresh while one runs returns without a second fetch (Rule 5).
20. **Vertical tabs.** The column's width is app-wide in `@AppStorage("browser.tabColumn.width")`, clamped
    160–360, default 220 (the precedent is `EditorTimeline`'s `@AppStorage`); a setting in settings.json
    for a drag would cost a Go round trip per resize. Hidden is per pane, saved in the layout
    (`Pane.browserColumnHidden`). ⌃⌘S is a Browser menu item that acts only on a focused browser pane in
    vertical mode, and passes the key on elsewhere.
21. **The collapsed group's tab** is `lastOpen`: `arrange()` sets it to the active tab whenever the active
    tab is in the group. ⌘1–9 and next/previous tab walk `tabs` (drawn order), collapsed groups included;
    selecting a collapsed group's tab makes it the one shown.
22. **A reopened tab** (⌘⇧T) returns to its group if the pane still has it, else waits for the site rule.
23. **Agent actions** are `.control`, `.agentReachable`, price allow: `browser_group`, `browser_pin`,
    `browser_unpin`, `browser_tab_column`, `browser_pull_requests_refresh`. `browser_new_tab` gains
    `opener`; `browser_move_tab` gains `group` (`""` takes the tab out); `read_pane` gains each tab's
    `group` and `pinned`, and `groups`, `tabColumnHidden`, `pinsError`.

## Global Constraints

- Platform floor `macOS 14.4`. No new Swift package or Go module. Go changes only in
  `internal/wakilcore/browsersettings.go`, a new `internal/wakilcore/githubprs.go`, their tests, and
  `cmd/wakil-ctx/main.go`.
- Numbers, verbatim from the spec: a group forms at **two** tabs and an automatic one dissolves at **one**;
  naming sends **up to five** titles and keeps **at most three** words; **six** swatches; ⌘W's second press
  within **2 s**; the pull-request refresh every **five minutes**; the column **220 pt**, resizable
  **160–360 pt**; the peek after the pointer rests **150 ms** on the pane's left **6 pt**.
- The model sees **tab titles only**, never addresses or page text (spec call 5).
- Settings in `~/.wakil/settings.json` under `browser`: `tabs` (`horizontal` | `vertical`, default
  `horizontal`) and `nameGroups` (default `true`).
- Copy, verbatim:
  - Tip on a pinned tab: `Press ⌘W again to close`.
  - Tab menu: `New Group…`, `Add to Group`, `Remove from Group`, `Pin to <project>`, `Unpin`,
    `Pin Current Page`, `Close Tab`. Group menu: `Rename…`, `Colour`, `Collapse` / `Expand`,
    `Pin to <project>`, `Unpin`, `Update Pin`, `Ungroup`, `Close Group`. Pull-request group menu: `Refresh`,
    `Collapse` / `Expand`, `Pin to <project>` / `Unpin`. A new group's name: `New Group`. The PR group:
    `Pull Requests`. Menu bar (Browser): `Toggle Tab Column`.
  - Settings → Browser → Tabs: `Tabs` with options `Horizontal`, `Vertical`, hint `Vertical puts the tabs in
    a column at the pane's left; ⌃⌘S hides and shows it.` — `Name groups with AI`, options `Off`, `On`,
    hint `Sends the titles of a new group's first tabs — never addresses or page text — to this
    organisation's quick-tasks model for a name of up to three words. Off, a group is named after its
    site.`
  - Refusals: `browser_group: this pane has no group <id>`; `browser_group: the pull-request group can't be
    <renamed|recoloured|ungrouped|closed>`; `browser_group: colour is one of blue, steel, teal, sand,
    stone, smoke`; `browser_pin: no project is active`; `browser_pin: pins/<project>.json can't be read
    (<error>) — fix or move it; Wakil won't write over it.`
  - Go: `No pull-request group: <org> has no GitHub account.`; `No pull-request group: <org>'s GitHub
    account on <host> uses an SSH key, which can't read pull requests — add a token or Sign in under
    Settings → Organisation → Git.`; `No pull-request group: no token is kept for <host> in <org>.`;
    `<host> refused the pull-request search (HTTP <code>): <message>`; `<host> did not answer: <error>`.
- Accessibility identifiers: `browser.group.<id>` (chip or header), `browser.group.<id>.name` (rename
  field), `browser.group.<id>.error`, `browser.group.<id>.refreshing`, `browser.tab.<id>.closeTip`,
  `browser.pinsError`, `browser.tabColumn`, `browser.tabColumn.edge`, `settings.browser.tabs`,
  `settings.browser.nameGroups`, `settings.browser.pullRequests.absent`. Group ids are `g<n>` (a pane's
  `nextGroup`), and `pr`.
- Nothing committed names a home path or a real organisation: use `example.com`, `initech`.
- No `Co-Authored-By` or "Generated with" lines in commits.

## Review Focus

1. **A sign-in hop.** A GitHub tab that redirects through `accounts.google.com` and back must not leave its
   group or start one. Pinned in Task 7's `aRedirectThroughAnotherHostDoesNotRegroup`.
2. **A late name.** A reply landing after the operator renamed the group, after it dissolved, or after a
   place or organisation switch must change nothing. Pinned in Task 10's `aLateNameNeverOverwritesTheOperatorsName`,
   `aNameForADissolvedGroupIsDropped` and `aNameAfterASwitchIsDropped`.
3. **A broken `pins/<project>.json`.** Pinning must refuse and reconcile must remove nothing, rather than
   write `{"items":[]}` over it and strip every pane. Pinned in Task 8's `anUnreadablePinsFileIsNeverWrittenOver`
   and `reconcileRemovesNothingWhenThePinsFileIsUnreadable`.
4. **Pins of another project or organisation.** Two projects whose browser panes share ids (`browser-1`)
   must each read their own file. Pinned in Task 10's `pinsAreReadForThePlaceShownOnly`.
5. **⌘W across tabs and time.** A first ⌘W on pinned tab A, then ⌘W on pinned tab B, or a second press after
   2 s, must arm again rather than close. Pinned in Task 9's `aSecondPressOnAnotherTabArmsAgain` and
   `aPressAfterTwoSecondsArmsAgain`.

---

### Task 1: The `tabs` and `nameGroups` settings

**Files:**
- Modify: `internal/wakilcore/browsersettings.go`, `internal/wakilcore/browsersettings_test.go`
- Modify: `cmd/wakil-ctx/main.go` (`setBrowserSettingsArgs`, both tools' descriptions)
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsBrowser`),
  `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_set_browser_settings` schema and forwarding)
- Test: `app/Tests/WakilKitTests/BrowserActionsTests.swift` (decode)

**Interfaces:**
- Produces: Go `BrowserAppSettings.Tabs string \`json:"tabs,omitempty"\``, `NameGroups *bool
  \`json:"nameGroups,omitempty"\``; `BrowserSettings.Tabs string \`json:"tabs"\``, `NameGroups bool
  \`json:"nameGroups"\``; `BrowserSettingsPatch.Tabs *string`, `.NameGroups *bool`. Swift
  `SettingsBrowser.tabs: String` (`"horizontal"`), `.nameGroups: Bool` (`true`), both `decodeIfPresent`, and
  `init(searchEngine:startPage:searchSuggestions:tabs: String = "horizontal", nameGroups: Bool = true)`.

- [ ] **Step 1: Write the failing tests:** Go `TestBrowserSettingsTabsAndNamingDefaults` (missing keys read
  `horizontal` and `true`; a hand-edited `"tabs":"diagonal"` reads `horizontal`),
  `TestWriteBrowserSettingsTabsRefusesUnknown` (`"grid"` → `UserError` `tabs is horizontal or vertical, not
  "grid"`, nothing written), `TestWriteBrowserSettingsNameGroupsFalseIsKept` (writing `false` stores
  `"nameGroups": false` and keeps `searchEngine` and the `editor` key); Swift `browserSettingsDecodeTabsAndNaming`
  (`{}` → `horizontal`, `true`; `{"tabs":"vertical","nameGroups":false}` → both).
- [ ] **Step 2: Run them to see them fail:** `go test ./internal/wakilcore -run 'Tabs|NameGroups'` and
  `make app-test`. Expected: compile failures.
- [ ] **Step 3: Implement** through resolve, patch, write and both tool descriptions (`tabs (horizontal or
  vertical)`, `nameGroups (true or false; on by default)`), and forward the two fields in
  `ctx_set_browser_settings`.
- [ ] **Step 4: Run them to see them pass:** `make build && go test ./internal/wakilcore ./cmd/wakil-ctx && make app-test`.
- [ ] **Step 5: Commit** `browser: the tabs and name-groups settings`.

### Task 2: `ctx_github_pull_requests`

**Files:**
- Create: `internal/wakilcore/githubprs.go`, `internal/wakilcore/githubprs_test.go`
- Modify: `cmd/wakil-ctx/main.go` (tool `github_pull_requests`), `cmd/wakil-ctx/schema_test.go` (its name)
- Modify: `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_github_pull_requests`, beside
  `ctx_browser_settings`)
- Test: `app/Tests/WakilKitTests/MCPClientTests.swift`, `StandardActionsTests.swift`, `AppWiringTests.swift`
  (the pinned name lists)

**Interfaces:**
- Produces: Go `type PullRequest struct { Number int \`json:"number"\`; Title, URL, Repository, Reason string
  /* json title,url,repository,reason; Reason "author" | "review-requested" */ }`,
  `type PullRequestsResult struct { PullRequests []PullRequest \`json:"pullRequests"\`; Absent string
  \`json:"absent,omitempty"\`; Host string \`json:"host,omitempty"\` }`,
  `func GitHubPullRequests(ctx context.Context, org string) (PullRequestsResult, error)` and
  `var githubAPIBase = func(host string) string` (overridable by tests). Swift action `ctx_github_pull_requests`
  `{}` → the tool's `structuredContent`.

- [ ] **Step 1: Write the failing Go tests** with `localOrg(t)`, `fakeKeychain(t)`, `SetGitToken` and an
  `httptest` server behind `githubAPIBase` (as `TestTokenTestAsksTheProvidersAPI` does):
  `TestPullRequestsAbsentWithoutAGitHubAccount` (Absent is the copy, no error);
  `TestPullRequestsAbsentForAnSSHAccount`; `TestPullRequestsAbsentWithNoToken`;
  `TestPullRequestsSearchesAuthorAndReviewRequested` (both `q` values seen, `Authorization: Bearer <tok>`,
  `Accept: application/vnd.github+json`; a PR in both lists comes once with `author`; repository read from
  `repository_url`'s last two segments; newest `updated_at` first);
  `TestPullRequestsRefusalIsWhole` (a 401 with `{"message":"Bad credentials"}` → the copy with `HTTP 401` and
  `Bad credentials`); `TestPullRequestsPrefersGithubDotCom` (accounts on `ghe.example.com` and `github.com`
  → github.com's base asked). Then the Swift pins: `MCPClientTests`' tool list and the two action lists
  gain the names.
- [ ] **Step 2: Run them to see them fail:** `go test ./internal/wakilcore -run PullRequests`; `make app-test`.
- [ ] **Step 3: Implement** to ruling 17 with a 20 s timeout and the body read through `io.LimitReader(…, 1<<20)`.
  The tool reads `CurrentOrg()`; the Swift action is `.read`, `.agentReachable`, and goes through
  `callChecked` with `MCPClient.readReplyTimeout`.
- [ ] **Step 4: Run them to see them pass:** `make build && go test ./... && make app-test`.
- [ ] **Step 5: Commit** `wakil-ctx: github_pull_requests — the organisation's open PRs, read only`.

### Task 3: The site key

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserSiteKey.swift`,
  `app/Sources/WakilKit/Browser/BrowserPublicSuffixes.swift` (generated)
- Test: `app/Tests/WakilKitTests/BrowserSiteKeyTests.swift`

**Interfaces:**
- Produces: `public enum BrowserSiteKey { static func of(_ url: String) -> String?; static func name(_ key:
  String) -> String; static func registrableDomain(_ host: String) -> String }` and
  `let browserPublicSuffixRules: String` (the list, one rule per line).

- [ ] **Step 1: Generate the snapshot** (one-off; the file's first line says when and how):

```bash
{ printf '// Generated %s from https://publicsuffix.org/list/public_suffix_list.dat (ICANN and private\n// sections, comments dropped). Regenerate with the command in the 3d-i plan, Task 3.\n' "$(date +%F)"
  printf 'let browserPublicSuffixRules = #"""\n'
  curl -fsSL https://publicsuffix.org/list/public_suffix_list.dat | sed -e 's#^//.*##' -e 's/[[:space:]]*$//' | grep -v '^$'
  printf '"""#\n'; } > app/Sources/WakilKit/Browser/BrowserPublicSuffixes.swift
```

- [ ] **Step 2: Write the failing tests:** a table test `siteKeysFollowTheRule` — `https://www.youtube.com/watch`
  and `https://youtu.be/x` → `family:youtube`; `https://initech.atlassian.net/browse/X-1` and
  `https://initech.atlassian.net/wiki` → `family:atlassian`; `https://raw.githubusercontent.com/a` →
  `family:github`; `https://docs.google.com/spreadsheets/d/1` → `family:google-docs` while
  `https://www.google.com/search?q=x` → `google.com`; `https://www.amazon.co.uk/dp/1` → `amazon.co.uk`;
  `https://a.example.github.io` vs `https://b.example.github.io` differ (private section);
  `http://localhost:3000/x` → `localhost:3000`; `http://app.test:8080` → `app.test:8080`;
  `http://127.0.0.1:5173` → `127.0.0.1:5173`; `file:///tmp/a.html`, `about:blank` → nil. Then
  `wildcardAndExceptionRulesApply` (a `*.` rule and its `!` exception from the generated list);
  `namesUseTheFamilyElseTheFirstLabel` (`family:github` → `GitHub`, `amazon.co.uk` → `Amazon`,
  `localhost:3000` → `localhost:3000`).
- [ ] **Step 3: Run them to see them fail:** `make app-test`. Expected: `BrowserSiteKey` undefined.
- [ ] **Step 4: Implement** to ruling 6. Parse the rules once into three `Set<String>` (plain, wildcard,
  exception) in a `static let`; never per call.
- [ ] **Step 5: Run them to see them pass:** `make app-test`.
- [ ] **Step 6: Commit** `browser: the site key — registrable domain and the family table`.

### Task 4: Groups, pins and the column in the snapshot and the layout

**Files:**
- Modify: `app/Sources/WakilKit/Layout/Pane.swift` (`BrowserGroup`, `BrowserGroupKind`, `BrowserGroupColour`,
  `BrowserSavedTab`'s fields, `Pane.browserGroups`, `Pane.browserColumnHidden`)
- Modify: `app/Sources/WakilKit/Layout/LayoutStore.swift` (`setBrowserTabs`, `browserTabs(id:)`)
- Modify: `app/Sources/WakilKit/Browser/BrowserSnapshot.swift` (`BrowserTab` and `BrowserSnapshot` fields),
  `BrowserActions.swift` (`browserSavedTabs`, `persist`, `browser_restore`), `PaneStore+Browser.swift`
  (`browserRestore`), `app/Sources/WakilKit/App/WindowModel.swift` (`scheduleBrowserTabsWrite`)
- Test: `app/Tests/WakilKitTests/BrowserStoreTests.swift`, `LayoutStoreTests.swift` (or the file that tests
  `setBrowserTabs`)

**Interfaces:**
- Produces:
  - `public enum BrowserGroupKind: String, Codable, Sendable { case automatic, own, pullRequests }`
  - `public enum BrowserGroupColour: String, Codable, Sendable, CaseIterable { case blue, steel, teal, sand,
    stone, smoke; public var hex: UInt32 }` (ruling 5's values)
  - `public struct BrowserGroup: Codable, Sendable, Equatable { id: String; name: String; colour:
    BrowserGroupColour; collapsed: Bool; lastOpen: String?; kind: BrowserGroupKind; siteKey: String?; named:
    Bool; pin: String? }`; an unknown kind or colour decodes as `.own` / `.blue`.
  - `BrowserSavedTab` gains `group: String?`, `opener: String?`, `pin: String?`, `keptLoose: Bool` (absent →
    false), with `init(id:url:title:group:opener:pin:keptLoose:)` defaulting the new ones.
  - `BrowserTab` gains `group`, `opener`, `pin`, `keptLoose` (same defaults, `decodeIfPresent`) and
    `pullRequest: String?`. `BrowserSnapshot` gains `groups: [BrowserGroup]`, `nextGroup: Int` (1),
    `tabColumnHidden: Bool`, `pinsError: String?`.
  - `Pane.browserGroups: [BrowserGroup]?`, `Pane.browserColumnHidden: Bool?`, in `CodingKeys`, decoded with
    `try?` as `browserTabs` is.
  - `LayoutStore.setBrowserTabs(id: String, to: [BrowserSavedTab], active: String?, groups: [BrowserGroup],
    columnHidden: Bool)`; `browserTabs(id:) -> (tabs: [BrowserSavedTab], active: String?, groups:
    [BrowserGroup], columnHidden: Bool)?`.
  - `PaneStore.browserRestore(paneId:tabs:active:groups:columnHidden:)`; `browserSavedTabs(_:)` skips tabs
    with a `pullRequest` and saves the PR group without tabs.

- [ ] **Step 1: Write the failing tests:** `aLayoutFrom3cDecodesWithNoGroups` (a pane JSON with only
  `browserTabs` → `browserGroups == nil`, every tab `group == nil`, `keptLoose == false`);
  `savedTabsRoundTripGroupsPinsAndColumn` (save → restore keeps group, opener, pin, keptLoose, the groups
  in order, `collapsed`, `lastOpen`, `named`, `nextGroup` past the highest `g<n>`, `tabColumnHidden`);
  `pullRequestTabsAreNotSaved`; `anUnknownGroupKindOrColourDecodesAsOwnAndBlue`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement**, updating every caller of the two `LayoutStore` methods.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: groups, pins and the column saved with a pane's tabs`.

### Task 5: The grouping rules (pure)

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserGrouping.swift`
- Test: `app/Tests/WakilKitTests/BrowserGroupingTests.swift`

**Interfaces:**
- Consumes: Task 3's `BrowserSiteKey`, Task 4's types.
- Produces, as `extension BrowserSnapshot`:
  - `func group(_ id: String) -> BrowserGroup?`; `func isPinned(_ tab: BrowserTab) -> Bool`
  - `mutating func placeOpened(tab: String, opener: String)` (ruling 8)
  - `mutating func placeLoaded(tab: String)` (ruling 9)
  - `@discardableResult mutating func newGroup(tabs: [String], name: String, kind: BrowserGroupKind,
    siteKey: String?) -> String` (takes `nextColour()`, id `g<nextGroup>`)
  - `mutating func makeOwn(_ group: String)`
  - `mutating func moveTab(_ tab: String, into group: String?, at index: Int?)` (`nil` group = loose and
    `keptLoose`; into a group clears `keptLoose`; an automatic group it enters or leaves becomes own)
  - `func dropGroup(moving tab: String, before index: Int) -> String?` (the strip's drag: the group of the
    tab it lands before; at the end, loose)
  - `func nextColour() -> BrowserGroupColour`
  - `mutating func arrange()` — ruling 4's order (stable within a section), dissolve at one, drop empty own
    groups, set `lastOpen` (ruling 21). Every rule above ends with it.
  - `static func fallbackName(siteKey: String?, openerTitle: String?) -> String`

- [ ] **Step 1: Write the failing tests:** `twoTabsOfASiteFormAGroupOneStaysLoose`;
  `aThirdTabJoinsTheSitesGroup`; `familySitesShareAGroup` (Jira and Confluence on `initech.atlassian.net`);
  `aPopupJoinsItsOpenersGroupWhateverItsSite`; `aLooseOpenerAndItsOtherSitePopupFormAChainGroupNamedFromTheOpener`
  (opener title `Amazon.com : usb c hub 4 port` → `Amazon.com : usb`); `aPopupOfThePullRequestGroupWaitsForTheSiteRule`;
  `aTabNavigatingToAnotherSiteLeavesItsSiteGroup` (and the group of two dissolves);
  `aTabThatCameByOpenerStaysWhenItNavigates`; `ownGroupsAreNeverRegrouped`;
  `aKeptLooseTabIsNeverPulledIn`; `draggingIntoAGroupClearsKeptLooseAndMakesItOwn`;
  `makeOwnTurnsAnAutomaticGroupOwnAndKeepsItsPlace`;
  `arrangeOrdersPinnedThenPullRequestsThenGroupsByAgeThenLoose`; `becomingOwnDoesNotMoveAGroup`;
  `pinnedTabsAreNeverGrouped`; `theCollapsedGroupShowsTheTabLastOpen`;
  `coloursTakeTheFirstFreeSwatchThenCycle`; `dropGroupIsTheGroupOfTheTabLandedBefore`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** to rulings 4–11 and 21.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: groups form by site and opener, dissolve at one, and become yours`.

### Task 6: Naming a group with the `respond` quick task (pure)

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserGroupNames.swift`
- Modify: `app/Sources/WakilKit/App/QuickTasks.swift` (`recordFailure`)
- Test: `app/Tests/WakilKitTests/BrowserGroupNamesTests.swift`, `QuickTasksTests.swift`

**Interfaces:**
- Produces:
  - `public enum BrowserGroupNames { static let replySchema: String /* {"name": string} */; static func
    due(_ s: BrowserSnapshot) -> [String] /* group ids, ruling 12 */; static func titles(of group: String, in
    s: BrowserSnapshot) -> [String] /* ≤ 5, t<n> ascending, non-empty */; static func request(titles:
    [String]) -> RespondRequest /* maxTokens 20 */; static func parse(_ reply: String) throws -> String }`
  - `QuickTasks.recordFailure(_ error: String, for op: QuickOperation)` — kept under `routedId(op)` like a
    model's error, logged the same way.
- Instructions, verbatim: `Name this group of browser tabs from their titles. Answer with at most three words
  and no punctuation, as JSON: {"name": "..."}.` Input: the titles, one per line.

- [ ] **Step 1: Write the failing tests:** `requestCarriesTitlesOnly` (input is exactly the titles joined by
  `\n`; no `http`, no URL); `titlesAreTheFirstFiveInOpeningOrder` (`t12` after `t3`; empty titles skipped);
  `dueNeedsTwoTitledTabsAndAnUnnamedAutomaticGroup` (own, PR and `named` groups never due);
  `parseKeepsThreeWordsWithoutQuotesOrPunctuation` (`{"name":"\"Rust async docs, part 2.\""}` → `Rust async
  docs`); `parseReadsInsideACodeFence`; `parseRefusesAnEmptyName` (`QuickModelError.invalidReply` naming the
  reply whole); and in `QuickTasksTests` `recordFailureShowsUnderTheRoutedProvider`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** after `CommitDraft.request` / `parse`'s shape.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: a group's name from its first titles, a quick task`.

### Task 7: The store and the actions place and change groups

**Files:**
- Modify: `app/Sources/WakilKit/Browser/PaneStore+Browser.swift` (`browserPageDidReport`,
  `browserPageOpenedTab`, a new `browserNameGroup`), `BrowserActions.swift` (`browser_new_tab`'s `opener`,
  `browser_move_tab`'s `group`, `browser_close_tab` and `browser_reopen_tab` through `arrange()`,
  a new `browser_group`, error cases), `BrowserPaneKind.swift`
  (`readPane`)
- Modify: `app/Sources/WakilApp/BrowserWebView.swift` (`openInBackground` passes `opener`)
- Test: `app/Tests/WakilKitTests/BrowserActionsTests.swift`, `BrowserStoreTests.swift`,
  `ActionClassificationTests.swift` / `AppWiringTests.swift` (name lists)

**Interfaces:**
- Consumes: Task 5's extension.
- Produces:
  - `browserPageDidReport` runs `placeLoaded` when the report ends a load (`before.isLoading && !report.isLoading
    && report.failure == nil`); `browserPageOpenedTab` runs `placeOpened`.
  - `PaneStore.browserNameGroup(paneId: String, group: String, name: String) -> Bool` (ruling 12's guard).
  - `browser_group {action: "create"|"rename"|"recolour"|"collapse"|"expand"|"ungroup"|"close", group?,
    tabs?: [String], name?, colour?}` — `create` makes an own group named `name` (default `New Group`) of
    `tabs` (default the active tab); `rename`/`recolour` make it own; `ungroup` marks its tabs `keptLoose`;
    `close` closes its tabs as `browser_close_tab` does, the pane too when none is left; the PR group refuses
    all but collapse and expand. Reply: `read_pane` plus `pane`, and `group` for `create`.
  - `browser_move_tab {tab, to?, group?}`: `group` present → `moveTab(into:at:)`; absent → today's move then
    `arrange()`. `to` is now optional; at least one of the two is required.
  - `read_pane`: each tab gains `group` (string or null) and `pinned`; top level gains `groups` (each `{id,
    name, colour, collapsed, kind, pinned, tabs}`), `tabColumnHidden`, `pinsError`.

- [ ] **Step 1: Write the failing tests:** `aFinishedLoadPlacesTheTabBySite` (two tabs report finished loads on
  `example.com` → one group, `read_pane` shows it); `aRedirectThroughAnotherHostDoesNotRegroup` (a grouped
  github tab reports loading on `accounts.google.com`, then finished on `github.com` → same group);
  `aPopupJoinsItsOpenersGroup` (`browserPageOpenedTab`); `newTabWithOpenerUsesTheOpenerRule`;
  `groupCreateRenameRecolourCollapseUngroupClose` (one test per verb, each reading `read_pane`; rename and
  recolour make the group own, collapse does not);
  `closingAGroupClosesItsTabsAndTheLastClosesThePane`; `thePullRequestGroupRefusesRename` (the copy);
  `anUnknownColourIsRefusedWithTheList`; `moveTabIntoAndOutOfAGroup`; `groupingNeverChangesTheActiveTab`
  (Rule 6: every rule above leaves `active` as it was, and a tab moved into a group stays selected);
  `browserNameGroupLandsOnlyOnAnUnnamedAutomaticGroup`; `readPaneCarriesGroupsAndPins`. Add the new action
  to the name lists.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.** Every handler that changes tabs or groups ends with `arrange()` and `persist(pane)`;
  `persist` now passes `groups` and `tabColumnHidden`.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: tabs placed at the seam, browser_group, browser_move_tab into a group`.

### Task 8: Pins per project

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPins.swift` (the file's types and `PaneStore` reconcile)
- Modify: `BrowserOrgFiles.swift` (`pins(project:)`, `setPins(_:project:)`, the doc comment's file list;
  `removeEverythingButTheProfile` keeps `pins/`), `BrowserActions.swift` (`browser_pin`, `browser_unpin`, full
  reconcile when `browserPane(open:)` opens a pane and in `browser_restore`; `BrowserActionError` cases)
- Test: `app/Tests/WakilKitTests/BrowserPinsTests.swift`, `BrowserOrgFilesTests.swift`, `BrowserActionsTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserPin: Codable, Sendable, Equatable { id: String; kind: Kind /* tab, group,
    pullRequests */; url: String?; title: String?; name: String?; colour: BrowserGroupColour?; tabs:
    [BrowserPinTab]? }`, `public struct BrowserPinTab: Codable, Sendable, Equatable { url: String; title:
    String }`, `public struct BrowserPinsUnreadable: Error, Sendable, Equatable { reason: String }`.
  - `BrowserOrgFiles.pins(project: String) throws -> [BrowserPin]` (`[]` when missing; throws
    `BrowserPinsUnreadable` when present and unreadable); `setPins(_ pins: [BrowserPin], project: String) throws`
    (refuses when the present file is unreadable).
  - `PaneStore.browserReconcilePins(paneId: String, pins: Result<[BrowserPin], BrowserPinsUnreadable>)` (full)
    and `browserApplyPin(paneId: String, add: BrowserPin?, remove: String?)` (delta), each ending in `arrange()`.
  - `browser_pin {tab? | group?, update?: Bool}` (`update` = *Pin Current Page* / *Update Pin*; the pull-request
    group pins as kind `pullRequests`); `browser_unpin {tab? | group?}`. The project is
    `await panes.activeScope.project`; the file is `orgFiles()`'s. Each delta-reconciles every other browser
    pane in `layout.snapshot()`.

- [ ] **Step 1: Write the failing tests:** `pinsFileRoundTripsInOrder`; `aMissingPinsFileReadsEmpty`;
  `anUnreadablePinsFileIsNeverWrittenOver` (bytes unchanged; `browser_pin` throws the copy);
  `reconcileRemovesNothingWhenThePinsFileIsUnreadable` (and sets `pinsError` whole);
  `aProjectKeyWithASlashIsOneFileName`; `clearingBrowsingDataKeepsPins`;
  `pinningATabShowsItInTheOtherBrowserPaneUnloaded` (two panes on the canvas; the other's copy has
  `loaded == false` and is not selected); `pinningAGroupWritesItsTabs`;
  `unpinKeepsItHereAndRemovesItFromTheOtherPane`; `pinCurrentPageRewritesTheEntryOnly` (the other pane's
  live tab keeps its URL); `aClosedPinnedTabComesBackAtTheNextFullReconcile`;
  `aNewBrowserPaneOpensWithTheProjectsPins`; `pinMakesAnAutomaticGroupOwn`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement** to rulings 13–16; writes atomic, directory created on first write.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: pin tabs and groups per project`.

### Task 9: ⌘W on a pinned tab, ⌃⌘S and the column action

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPinnedClose.swift`
- Modify: `BrowserActions.swift` (`BrowserKey.toggleTabColumn`, `browser_tab_column`),
  `app/Sources/WakilKit/App/WindowModel.swift` (`browserKey`'s `.closeTab` and `.toggleTabColumn`;
  `browserCloseArm`, `browserNow`)
- Test: `app/Tests/WakilKitTests/BrowserPinnedCloseTests.swift`, `WindowModelBrowserTests.swift`,
  `InvalidationContractTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserCloseArm: Sendable, Equatable { pane: String; tab: String; at: Date }`;
    `public enum BrowserPinnedClose { static let window: TimeInterval = 2; static let tip = "Press ⌘W again to
    close"; enum Outcome { case arm, close }; static func press(_ armed: BrowserCloseArm?, pane: String, tab:
    String, now: Date) -> Outcome }`.
  - `WindowModel.browserCloseArm: BrowserCloseArm?` (observed: the view draws the tip while set), cleared 2 s
    after it is set and on any close; `@ObservationIgnored var browserNow: @Sendable () -> Date` (a test seam).
    Both classified in `InvalidationContractTests`; `browserCloseArm` reset in `invalidateForOrgChange()`.
  - `browser_tab_column {hidden?: Bool}` (omitted toggles) sets `tabColumnHidden` and persists.
  - `browserKey(.toggleTabColumn)` returns false (key passed on) unless a browser pane is focused and
    `browserSettings.tabs == "vertical"`.

- [ ] **Step 1: Write the failing tests:** `aFirstPressArmsASecondWithinTwoSecondsCloses`;
  `aPressAfterTwoSecondsArmsAgain`; `aSecondPressOnAnotherTabArmsAgain`; `anUnpinnedTabClosesOnTheFirstPress`
  (WindowModel: ⌘W on a loose tab closes at once); `aPinnedTabTakesTwoPresses` (WindowModel, `browserNow`
  stepped); `aTabOfAPinnedGroupCountsAsPinned`; `theAgentClosesAPinnedTabInOneCall`
  (`browser_close_tab` has no guard); `tabColumnTogglesAndIsSaved`; `toggleTabColumnPassesTheKeyInHorizontalMode`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: ⌘W twice on a pinned tab; the tab column's action`.

### Task 10: The window names groups and reconciles pins

**Files:**
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`browserPageDidReport` asks for due names; full
  reconcile at the end of `activateLayout` and `showCanvas`; `browserNamingAsked`)
- Test: `app/Tests/WakilKitTests/WindowModelBrowserTests.swift`, `InvalidationContractTests.swift`

**Interfaces:**
- Consumes: Tasks 6–8; the quick-task fake `WindowModelCommitDraftTests` installs.
- Produces: `private func nameDueGroups(scope: LayoutScope, pane: String)` (ruling 12: only when
  `browserSettings.nameGroups` and `quickTasks != nil`; the reply checked against `browserScope == scope` and
  `quickTasksGeneration` before `panes.browserNameGroup`, then `refreshBrowser` and
  `scheduleBrowserTabsWrite`); `func browserReconcilePins() async` (every browser pane on the canvas, the file
  read off the main actor from `browserOrgFiles(for: scope)` for `scope.project`);
  `@ObservationIgnored var browserNamingAsked: Set<String>` (`"<pane>/<group>"`), emptied on an
  organisation change.

- [ ] **Step 1: Write the failing tests:** `aFormedGroupIsNamedByTheQuickTask` (fake reply `{"name":"Rust
  docs"}` → the group's name; the request's input holds both titles and no URL);
  `namingIsAskedOncePerGroup`; `namingOffKeepsTheSiteName`; `aReplyThatDoesNotParseReachesTheStatus`
  (`quickTaskStatus().errors` holds it whole); `aLateNameNeverOverwritesTheOperatorsName` (rename while the
  fake waits → the operator's name stays); `aNameForADissolvedGroupIsDropped`; `aNameAfterASwitchIsDropped`;
  `pinsAreReadForThePlaceShownOnly` (projects `alpha` and `beta` both with `browser-1`; each shows its own
  pins after a switch); `showingACanvasReconcilesItsPins`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: groups named by the quick model; pins follow the project on screen`.

### Task 11: The pull-request group

**Files:**
- Modify: `app/Sources/WakilKit/Browser/BrowserPaneKind.swift` (`BrowserShared.pullRequests`),
  `PaneStore+Browser.swift` (`browserSetPullRequests`, `browserApplyPullRequests`), `BrowserActions.swift`
  (`browser_pull_requests_refresh`; a `pullRequests` closure param on `browserActions` and
  `registerBrowserActions`, default `{ nil }`), `app/Sources/WakilKit/App/AppWiring.swift` (the closure,
  dispatching `ctx_github_pull_requests`), `app/Sources/WakilKit/App/WindowModel.swift` (the loop, ⌘R on the
  header, `browserHeaderFocus`, `browserPullRequestsInterval`)
- Test: `app/Tests/WakilKitTests/BrowserActionsTests.swift`, `WindowModelBrowserTests.swift`,
  `InvalidationContractTests.swift`

**Interfaces:**
- Consumes: Task 2's reply shape.
- Produces:
  - `public struct BrowserPullRequest: Codable, Sendable, Equatable { number: Int; title, url, repository,
    reason: String }`; `public struct BrowserPullRequests: Sendable, Equatable { items: [BrowserPullRequest];
    absent: String?; error: String?; refreshing: Bool }`; `BrowserShared.pullRequests: [String:
    BrowserPullRequests]` by organisation.
  - `PaneStore.browserApplyPullRequests(paneId: String, org: String)` (ruling 18: no list or `absent` → no `pr`
    group; else the group, collapsed when new, its tabs matched by `pullRequest`).
  - `browser_pull_requests_refresh {}` — returns at once while `refreshing`; else fetches, stores the list (a
    failure keeps the last list and sets `error` whole), applies it to every browser pane in
    `layout.snapshot()`, and answers `{org, count, absent, error}`.
  - `WindowModel.browserHeaderFocus: BrowserHeaderFocus?` (`{pane, group}`, set by the view);
    `browserKey(.reload)` dispatches `browser_pull_requests_refresh` when it names this pane's `pr`.
  - `@ObservationIgnored var browserPullRequestsInterval: Duration = .seconds(300)`, and a loop task started
    and stopped per ruling 19 from `refreshLayout()`, cancelled in `invalidateForOrgChange()` and shutdown.
  - `WindowModel.browserPullRequestsAbsent: String?` for Settings (the active organisation's `absent`).
  - `read_pane`'s `pr` group carries `error` and `refreshing`.

- [ ] **Step 1: Write the failing tests:** `pullRequestsFillAGroupCollapsedOfUnloadedTabs`;
  `aRefreshKeepsListedTabsAddsNewDropsGone`; `theActivePullRequestTabStaysAsALooseTab` (Rule 6);
  `aFailedRefreshKeepsTheListAndShowsTheErrorWhole`; `aRefreshWhileOneRunsFetchesOnce` (the closure counts
  calls); `absentMeansNoGroupAndNoError`; `aNewPaneGetsTheCachedList`; `pullRequestTabsAreNeverGrouped`;
  WindowModel `theLoopRefreshesWhenTheFirstBrowserPaneOpensAndStopsWithTheLast` (interval shortened);
  `cmdRWithTheHeaderFocusedRefreshes`; `anOrganisationSwitchStopsTheLoop`.
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: the pull-request group, refreshed every five minutes`.

### Task 12: Groups in the strip, the menus and the tip

**Files:**
- Modify: `app/Sources/WakilApp/PaneTabStrip.swift` (`closable: ((Int) -> Bool)?`, `contextMenu: ((Int) ->
  AnyView)?`, both defaulting to today's behaviour), `BrowserPaneHeader.swift` (`BrowserTabList` draws chips
  and grouped entries from `snapshot.tabs`; `BrowserTabCount`'s menu by group), `BrowserPane.swift` (the
  pins error row, the tip, `browserHeaderFocus`)
- Create: `app/Sources/WakilApp/BrowserGroupViews.swift` (the chip, the header, the rename field, the menus,
  shared by Task 13)

**Interfaces:**
- Consumes: `browser_group`, `browser_move_tab {group}`, `browser_pin`, `browser_unpin`,
  `browser_pull_requests_refresh`, `BrowserGroupColour.hex`, `BrowserPinnedClose.tip`,
  `WindowModel.browserCloseArm`, `BrowserSnapshot.dropGroup`.
- Layout: a chip is a strip entry with no ×: an 8 pt dot in the group's colour and its name at
  `BrowserPaneStyle.tabTitleSize`; collapsed, the name and its `lastOpen` tab's favicon. An expanded group's
  tabs follow its chip with a 2 pt underline in its colour. A click on the chip collapses or expands; a
  double-click on its name renames. The rename field opens focused with the text selected; focus leaving
  saves (Rule 2), Esc puts the name back. The PR header shows `arrow.triangle.2.circlepath` while
  refreshing and its error whole in a line under the strip (`browser.group.pr.error`). The tip is a small
  label under the pinned tab's entry, shown while `browserCloseArm` names it. The pins error is one row
  under the strip, whole, wrapping.

- [ ] **Step 1: Build the chips, the grouped entries and the drag into or out of a group.** Run `make build`.
  Expected: success.
- [ ] **Step 2: Build the menus (Global Constraints' copy), the rename field, the tip and the error rows.**
  Run `make build`. Expected: success.
- [ ] **Step 3: Check the rules on paper**, one line each in the commit body: Rule 1 — nothing here asks;
  closing a group, ungrouping and unpinning don't; ⌘W twice is the spec's named exception. Rule 2 — rename
  keeps what was typed on focus loss. Rule 3 — *New Group…* and *Rename…* open the field focused. Rule 5 — the
  PR header shows its refresh and ignores a second. Rule 6 — grouping, collapsing and pinning never change
  the active tab or take the keyboard. Rule 8 — the naming, refresh and pins errors are whole.
- [ ] **Step 4: Commit** `browser: group chips, menus and the pinned tab's tip in the strip`.

### Task 13: The vertical column and Settings

**Files:**
- Create: `app/Sources/WakilApp/BrowserTabColumn.swift`
- Modify: `app/Sources/WakilApp/BrowserPane.swift` (column or strip by `tabs`; the edge peek),
  `AppScene.swift` (`Toggle Tab Column`, ⌃⌘S, in the `Browser` menu), `BrowserWebView.swift` (`isWakilKey`
  passes ⌃⌘S, key code 1, to the menu), `BrowserSettingsForm.swift` (a `Tabs` section: the two rows, and the
  pull-request absent line), `SettingsPane.swift:1038` (pass `pullRequestsAbsent`)
- Modify: `app/Sources/WakilKit/Browser/BrowserGrouping.swift` (`BrowserTabColumnRules`: `width` 220,
  `minWidth` 160, `maxWidth` 360, `edge` 6, `peekDelay` 150 ms, `clamp(_:)`)
- Test: `app/Tests/WakilKitTests/BrowserGroupingTests.swift` (`columnWidthClampsTo160Through360`)

**Interfaces:**
- Consumes: Task 12's views; `browser_tab_column`; `SettingsBrowser.tabs`, `.nameGroups`;
  `WindowModel.browserPullRequestsAbsent`.
- Layout: the column sits on the pane's left under the address row's height, full height, rows 28 pt —
  pinned tabs, then each group's header and (expanded) its tabs indented 12 pt, then loose tabs, ＋ at the
  bottom; a 1 pt divider at its right edge drags the width (`@AppStorage("browser.tabColumn.width")`,
  clamped). In vertical mode the strip row keeps the glyph and the count but no entries. Hidden, a 6 pt
  hover zone at the pane's left (`browser.tabColumn.edge`) slides the column out over the page after
  150 ms, and it slides back when the pointer leaves it; Reduce Motion makes both a fade.

- [ ] **Step 1: Write the failing test** `columnWidthClampsTo160Through360`; run `make app-test` (fails);
  implement `BrowserTabColumnRules`; run again (passes).
- [ ] **Step 2: Build the column, the peek and ⌃⌘S.** Run `make build`. Expected: success.
- [ ] **Step 3: Build the Settings rows** with the copy and identifiers in Global Constraints. Run `make build`.
- [ ] **Step 4: Check the rules on paper** in the commit body: Rule 6 — hiding, showing and peeking never take
  the keyboard from the page or the address field; Rule 9 — horizontal and naming-on are defaults, each a
  setting.
- [ ] **Step 5: Commit** `browser: vertical tabs, ⌃⌘S and the edge peek; Settings → Browser → Tabs`.

### Task 14: Docs and the charter

**Files:**
- Modify: `docs/architecture/wakilkit.md` (Browser/: `BrowserSiteKey`, `BrowserGrouping`, `BrowserGroupNames`,
  `BrowserPins`, `BrowserPinnedClose`), `docs/architecture/state.md` (`pins/<project>.json`; the layout's
  `browserGroups` and `browserColumnHidden`; the column width in user defaults; the PR list in memory only),
  `docs/architecture/go.md` (wakil-ctx's `github_pull_requests`)
- Modify: `docs/wakil/north-star.md` §8, `docs/wakil/decisions.md`, `docs/wakil/design-language.md` §11

- [ ] **Step 1: north-star §8.** After the 3c-iii row add `**3d**` *The browser you live in* (waits on 3c),
  `**3d-i**` *Tab groups — automatic, named by the quick model, and your own; the pull-request group; pins per
  project; vertical tabs* (3c-iii), `**3d-ii**` *Identities inside an organisation* (3d-i), `**3d-iii**`
  *Picture-in-picture* (3c-i), `**3d-iv**` *Passwords in the Keychain* (3c-ii), `Met` empty. The file is over
  its limit already (4381/4000): make room by moving words out, never in — shorten the 3c rows or move a
  narrative line to `phase-log.md` — so `make docs-check`'s count is unchanged or lower.
- [ ] **Step 2: Decision 49** in `decisions.md`, after 48, in its shape (bold one-line ruling; *(2026-10-27,
  operator, during the 3d design — <spec path>.)*; body; *Why*; *Reverse if*). Ruling: **groups are the
  pane's, automatic and yours alike, and pinning per project is the one way to share them; identities are
  stores inside the organisation; picture-in-picture is WebKit's own through one private preference; Wakil
  keeps its own passwords in the Keychain.** Body: calls 1–5 and 8 in a sentence each, the PR group as the
  one organisation-wide group read through Go, and that it overturns 3c's "no tab groups" and "no password
  manager of Wakil's own". *Why*: org-wide automatic groups would need every pane in every place kept in step;
  a pin is a static list. *Reverse if*: the operator keeps re-making the same group in each place — then
  groups are argued for at the project level.
- [ ] **Step 3: design-language §11's Browser row:** add a sentence on groups (a coloured chip in the strip, or a
  header in the column; collapsed, its name and last-open tab; six muted swatches, never a reserved hue),
  pins (first, per project; ⌘W twice), and the vertical column (left, 220 pt, ⌃⌘S, the edge peek). Set
  **Updated** to the build date. Identities and the key glyph wait for their own plans.
- [ ] **Step 4: Run** `make build && make test && make app-test`. Expected: green except `docs-check`'s known
  north-star count, unchanged or lower.
- [ ] **Step 5: Commit** `docs: 3d-i — architecture, §8 rows, Decision 49, design-language`.
- [ ] **Step 6: Hand the branch to the e2e auditor (Cover).** It should check, on fixture pages served from
  two loopback hosts and an opener page: automatic grouping and dissolving, the opener rule, a named group via
  a scripted quick-task provider, rename (focus, blur keeps), recolour, collapse, drag in and out, pin across
  two places of one project, ⌘W twice, the vertical column and ⌃⌘S, the peek, both settings, and the PR
  group's absent line. **Ask the operator before using the screen.**

### Task 15: The acceptance walk

**Files:**
- Create: `docs/wakil/phase-3d-i-acceptance.md`

- [ ] **Step 1: Write the runbook** in `phase-3c-iii-acceptance.md`'s shape: links to the spec and this plan,
  the exit criterion (the Goal above), **0. Setup** (`make build && make app-bundle`, then
  `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`; organisation A has a GitHub token account, B has
  none), **1. The walk** with these ten rows, `Walked` empty:
  1. Open YouTube twice, GitHub twice, a Jira issue and a Confluence page → three groups (*YouTube*,
     *GitHub*, *Atlassian*), each first shown by site name, then renamed once by the model; a third YouTube tab
     joins without renaming.
  2. Search Amazon, ⌘-click three products → they join the search's group; the active tab, scroll and keyboard
     never move.
  3. Right-click a tab → *New Group…*, type a name, click away → kept; rename, recolour and collapse an
     automatic group → it never moves, and collapsed shows its name and the last tab open.
  4. Drag a tab out of a group and back; ungroup a group, then open another tab of its site → the ungrouped
     tabs stay loose.
  5. Pin a tab and a group to the project; switch to another place of the project → both are first, unloaded;
     unpin there → gone from the first place's pane on return.
  6. ⌘W on a pinned tab → `Press ⌘W again to close`; wait 3 s, ⌘W → the tip again; ⌘W twice quickly → closed;
     the × closes in one click.
  7. Organisation A: the *Pull Requests* group at the top, collapsed; expand → your open PRs and reviews; ⌘R on
     its header shows it refreshing; organisation B → no group, and Settings → Browser says why in one line.
  8. Settings → Browser → Tabs → *Vertical*: the column on the left, pinned, then groups, then loose; drag its
     edge to 360 and 160; ⌃⌘S hides it; rest the pointer at the left edge → it slides out, and back when you
     leave.
  9. Narrow pane hidden, wide pane shown: relaunch → each keeps its own; the width is the same in both.
  10. *Name groups with AI* → Off; form a new group → it keeps the site name; break the quick-tasks provider
      and turn it On → the group keeps its site name and Settings → Providers shows the error whole.
  Then **2. Known and not fixed** (empty until the walk) and **3. The machine walk** with the two
  `machine-walk` marker lines from `docs/agents/workflow.md`.
- [ ] **Step 2: Commit** `docs: 3d-i acceptance runbook`.

**Next:** Build the plan task by task  ·  **Tool:** `superpowers:subagent-driven-development`  ·  **Blocked by:** —
