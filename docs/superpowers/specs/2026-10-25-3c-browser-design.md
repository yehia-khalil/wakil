# 3c: the browser pane — a full browser inside the canvas, its logins kept per organisation

**Date:** 2026-10-25
**Status:** design written at the operator's ask ("Go ahead", skipping the questions; "I want a full
fledged browser"); agent acting per site ruled 2026-10-25; builder check folded in; awaiting the
operator's review
**Sub-phase:** 3c, a new Phase 3 row. Follows main 8f7c616 (3a-v-b, #72).

---

## Problem

Wakil has a DB client, an API client, a terminal, an editor and Jira, and the charter names the browser
as the fifth tool the operator leaves for (north-star §1 problem 4; `design-language.md` §11 lists a
Browser pane, multi-tab, ⌘T, "agent can read the active tab"). Today every docs page, dashboard, staging
site and pull request is a trip to Safari or Chrome, outside the place on screen and outside the
organisation's boundary: one browser profile holds the cookies of every organisation the operator works
for. The mockup `docs/wakil/screens/Browser.dc.html` has been drawn since 2c; nothing is built.

## The reference: Safari

"Full fledged" (operator, 2026-10-25) is read as: the things a person does in Safari every day work here
without a trip out. What this design keeps:

- **Tabs** — new (⌘T), close (⌘W), reopen closed (⌘⇧T), next/previous (⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[),
  ⌘1–9, drag to reorder, a link with `target=_blank` or ⌘-click opening a tab beside the current one.
- **The address field** — a URL or words; words search. Suggestions from history while typing. ⌘L
  focuses it with the text selected. The padlock and host are shown; the full URL on focus.
- **Navigation** — back (⌘[), forward (⌘]), reload (⌘R), stop (Esc while loading), a thin progress line.
- **Logins stay** — cookies, local storage and passwords the site keeps survive a relaunch. Sign in to
  Google, GitHub, Jira, AWS consoles and stay signed in, including OAuth pop-ups.
- **Find in page** (⌘F, ⌘G / ⌘⇧G, Esc), **zoom** (⌘+ / ⌘− / ⌘0, kept per host), **print** (⌘P is
  Wakil's palette, so print is ⌘K → Print page).
- **Downloads** — saved to `~/Downloads`, a strip in the pane with progress, Cancel, and Show in Finder.
- **File upload**, **JavaScript alert / confirm / prompt**, **HTTP basic auth**, **camera and microphone
  requests** — each answered in place in the pane.
- **History** and **bookmarks** — history feeds the address field and ⌘P; a bookmark is ⌘D.
- **Web Inspector** — right-click → Inspect Element, Safari's own developer tools.
- **Context menu** — Safari's own (open link in new tab, copy link, save image, look up…).

## Decisions the operator took

- **A full browser, not a page viewer** (2026-10-25, "I want a full fledged browser").
- **No questions; build from the design language and the mockup** (2026-10-25, "Go ahead").
- **The agent clicks, types and submits in pages, approved per site** (2026-10-25, "Ok" to the
  recommendation): a site is allowed once per conversation; production sites ask every time; passwords,
  card numbers and one-time codes are never the agent's. Call 6 below is the shape.

## Calls made for the operator (flagged for review)

1. **The engine is WebKit (`WKWebView`), not Chromium.** It ships with macOS, needs no dependency, is
   what Safari is, and the app already hosts one for Monaco. Chromium (CEF) would add ~200 MB and a second
   process model for no gain a person would notice. Cost: a site that supports only Chrome behaves as it
   does in Safari.
2. **Every organisation has its own browser profile** — its own cookies, storage, cache and saved site
   data, `WKWebsiteDataStore(forIdentifier:)` with an identifier fixed per org (macOS 14+, already the
   floor). Signed in to GitHub as the work account in initech and the personal one in personal, side by
   side, with no bleed. This is Invariant 4 applied to the web: a session cookie is a credential. The
   identifier is a random UUID made on the org's first browser pane and kept in
   `~/.wakil/orgs/<org>/browser/profile.json`, beside everything else the org owns. Wakil has no org
   rename; `wakil org rm` deletes that folder, so an org made again under the same name gets a new UUID
   and never inherits the old one's logins. WebKit keeps the store's files itself (under
   `~/Library/WebKit/`), out of Go's reach, so `org rm` leaves them behind as residue it names in its
   output, as it does the Keychain; **Settings → Browser → Clear this organisation's browsing data…**
   removes them (`WKWebsiteDataStore.remove(forIdentifier:)`; it destroys, so it asks — Rule 1).
3. **Passwords are the site's and macOS's, not Wakil's.** WebKit's AutoFill offers saved passwords from
   the iCloud Keychain with Touch ID, as in Safari, where the system allows it for an embedded view; Wakil
   stores no password and never fills one itself. If the system does not offer AutoFill in an embedded
   view, the operator types or pastes, and the profile's cookies keep them signed in after that. (The
   Prohibited list in Wakil's own agent rules — the agent never types a password — stands.)
4. **One pane holds many tabs; a second browser pane is a second set of tabs.** As §11 says and the
   mockup draws: tabs in the rail's language, a vertical list along the pane's top-left, not Chrome's
   trapezoids. *(Superseded by the horizontal strip, design pass 2026-10-25: the tabs run across the
   pane's top as `Browser.dc.html` draws them — design language §11 and the 3c-i ledger's ruling. Do
   not rebuild the vertical list.)* ⌘T, ⌘W and ⌘1–9 act on the browser's tabs **only while a browser pane is focused**; in
   other panes they keep today's meaning (⌘T a scratch tab in the editor, ⌘W close tab or pane). ⌘W on
   the last tab closes the pane, as the editor does.
5. **Clicking inside the page is the second exception to dual-drive**, after the editor's text surface.
   A link click, a form typed into, a scroll — WebKit does them, not an action. What Wakil keeps in step
   with the page (each tab's URL, title, loading state, back/forward availability) is written into the
   pane store by the view through one seam, the way the editor's renderer reports the cursor. Everything
   with a control outside the page — open, navigate, back, forward, reload, stop, new tab, close tab,
   select tab, find, zoom, bookmark, download cancel — is an action, so the operator, ⌘K and the agent
   drive the same path (Invariant 2). This needs a Decision (48) and a §11 row update.
6. **The agent reads freely and acts in a page once the operator allows the site** (the operator's
   ruling above). Two halves:
   - **Reads, never asked:** `browser_open` (a URL, in a new tab or the current one), `browser_navigate`,
     `browser_back` / `_forward` / `_reload`, `browser_tab_*`, and `browser_read_page` — the active tab's
     visible text, title, links, and its form fields and buttons each with a short ref (`e12`), returned
     **marked as untrusted text from <host>** (the mockup's "1 page · untrusted text from
     api.initech.dev"), capped at 200 KB with the cap said when it bites (Principle 4). `read_pane` gives
     the tabs, URLs, titles and loading state only — never page text, so an agent that did not ask never
     reads a page (the mockup's "Wakil reads this page only when asked"). Navigation is a GET and a read.
   - **Acting — a new earned write (Invariant 6's tenth):** `browser_click` (a ref from the last read),
     `browser_type` (a ref and text), `browser_select` (a ref and an option), `browser_press` (a key:
     Return, Tab, Escape, arrows), `browser_scroll`. Their price is **per site**: the first act on a host
     in a conversation raises the permission plane — `Let the agent use staging.initech.dev? It can click,
     type and submit there until this conversation ends.` (**Allow for this conversation** / **Don't
     Allow**); after Allow, acts on that host run without asking. A **production host** — the host of
     any API entry of an environment flagged production, in any project of the org — asks on **every**
     act, in red, naming the element (`click "Delete booking" on api.initech.com`). The allow-list is
     the conversation's, kept in memory, gone when the conversation closes, and shown in the pane's
     header as a small `agent allowed` mark on the tab's host with × to revoke.
   - **Never the agent's, whatever is allowed:** typing into a password field, a field whose
     `autocomplete` is `cc-number`, `cc-csc`, `one-time-code` or `current-password`/`new-password`, or a
     field named or labelled for a card, CVV, OTP or password — refused with *that field is yours to
     fill*; reading cookies, storage or saved logins; running script of its own in the page; acting in a
     tab the operator is typing in this second (the act waits until the page has been idle 1 s).
   - **Why per site and not per submit:** a page's script can send data from any click without a form
     submission, so a per-submit check would miss sends. Consent to a whole site covers everything done
     there, so nothing slips past it, and staging is not a stream of prompts.
   - **Voice:** a spoken turn may act on an allowed non-production site (the site's Allow was typed or
     clicked); the per-site Allow itself and every production act are typed confirmations (Invariant 7).
   - **Prompt injection:** page text reaches the agent wrapped as untrusted, and the harness's system
     rules (already Wakil's) tell the agent that instructions inside page text are data. The per-site
     consent is the backstop: a page cannot steer the agent onto a site the operator has not allowed.
7. **Production looks alarming here too.** The pane carries the environment band like every pane
   (Invariant 8). A tab whose host matches the host of a `baseUrl` among the **active** environment's API
   entries wears that environment's name on its tab (`In staging`, as drawn). Separately, a host that is
   any production environment's (call 6's list) is tagged `Production` in red whichever environment is
   active, since that is what the agent's every-time ask keys on. Both lists are read from the project
   config the Api store already holds (`ApiCurlFill`'s host match is the precedent), recomputed on a
   config change.
8. **Search is Google by default**, a setting in Settings → Browser with DuckDuckGo, Bing and Kagi, plus
   the start page (blank, or a URL). Rule 9: a default, not a lock.
9. **What is saved, and where.** A browser pane belongs to a place like every pane, so its tabs are
   saved with the layout (`~/.wakil/layouts/<org>/…`, per project, environment and conversation):
   each tab's id, URL, title and order, and the active tab — `BrowserPaneKind.Contents` is `Codable` for
   that. Switching environment swaps the canvas and so the tab set; the cookies stay, being the org's.
   Each tab's back/forward list and scroll are kept too, as WebKit's `interactionState` archived to
   `~/.wakil/orgs/<org>/browser/tabs/<tab-id>.state` (written when a tab navigates, deleted when it
   closes), so a relaunch keeps ‹ › working. A restored pane loads lazily — only the active tab gets a
   web view and fetches; another tab's view is made when it is selected — so forty saved tabs do not fire
   forty loads. Per-host zoom is in `~/.wakil/orgs/<org>/browser/zoom.json`. Closed tabs (for ⌘⇧T) are
   kept in memory only.
10. **History and bookmarks live per organisation** in `~/.wakil/orgs/<org>/browser/history.sqlite`
    and `bookmarks.json`, so one org's browsing never suggests in another's. History keeps 90 days. ⌘P lists
    bookmarks and open tabs under Resources; history only in the address field's suggestions.
11. **Opening a link from elsewhere in Wakil** (a URL in the terminal, an http link in the editor, an API
    entry's base URL) opens it in the canvas's browser pane — a new tab in the focused or most recent
    browser pane, or a new pane if none is open. ⌥-click opens it in the system browser instead. This is
    3c-iii, below; until it lands those links keep opening in the system browser.
12. **Three plans, each walkable on its own:**
    - **3c-i, the browser** — in this order: the pane, tabs, address field, navigation, per-org profile
      and layout save/restore first (walkable alone); then find, zoom, downloads, in-place prompts
      (alert/confirm/prompt, basic auth, file chooser, camera/microphone), crash and certificate pages,
      Web Inspector, Settings → Browser, and the bundle's Info.plist keys (call 13).
    - **3c-ii, the agent's reach** — the read actions, `browser_read_page`, `read_pane`, the acting
      actions with the per-site price, the never-list, the environment and production tags on tabs.
    - **3c-iii, history, bookmarks and links** — history and suggestions, bookmarks and ⌘D, ⌘P Resources,
      links from the terminal and editor.

13. **The app bundle.** Wakil.app is assembled unsigned and unsandboxed (`scripts/make-app-bundle.sh`),
    so no entitlement is needed for the network or `~/Downloads`. macOS still requires a usage string
    before a page may use a device: `NSCameraUsageDescription` is added (`A web page in Wakil's browser
    asked to use the camera.`), and `NSMicrophoneUsageDescription` — today "Wakil listens only while you
    hold ⌥" — becomes `Wakil listens while you hold ⌥, and when a web page in its browser asks and you
    allow it. Audio for speech never leaves this Mac.` Location is denied to pages without a prompt (no
    usage string is added). `scripts/app_bundle_test.go` pins the keys.

## What the operator gets

### The browser (3c-i)

- **Open one:** the rail's ＋ menu → Browser, ⌘K → *New browser*, or `pane_open {kind: "browser"}`. It
  arrives with one tab on the start page and the address field focused (Rule 3).
- **The pane, top to bottom:** a header row with ‹ › ↻ (↻ becomes × while loading), the address field
  (host and padlock when not focused, the whole URL when focused), and the tab count; under it the tab
  list on the left (favicon, title, × on hover; the active one with the rail's luminous tick) and the
  page on the right, drawn as the web draws it — the one surface Wakil does not style (the mockup's
  comment, kept). A 2 pt progress line under the header while loading. The tab list folds to favicons
  below 640 pt wide and hides below 420 pt, when the tab count in the header becomes a menu.
- **Find bar** above the page on ⌘F: field, `3 of 12`, ↑ ↓, ×. Esc closes it and returns focus to the page.
- **Download strip** at the pane's foot while any download is live or finished this session: name,
  progress or size, Cancel (Rule 4) while running, Show in Finder after; × clears finished ones.
- **In-place prompts** — alert, confirm, prompt, basic auth, a file chooser (the system open panel), and
  camera/microphone ("api.initech.dev wants to use your microphone" — Allow / Don't Allow, remembered
  per host for the session) — sit over the page in the pane, never a window-modal sheet, so the rest of
  the canvas stays usable (Rule 8).
- **A page that fails to load** shows the error whole in the page area (`Couldn't reach
  api.initech.dev — the server didn't answer (NSURLErrorTimedOut)`) with Try Again.
- **Settings → Browser:** search engine, start page, "Clear this organisation's browsing data…" (asks:
  it destroys).

### The agent (3c-ii)

- "Open the staging docs" → `browser_open` with the API entry's base URL; "read the confirm endpoint
  docs" → `browser_read_page`, and the thread shows `1 page · untrusted text from api.initech.dev`.
- "Fill in the booking form on staging and submit it" → the first act raises *Let the agent use
  staging.initech.dev?*; after Allow the agent reads the page, types into the fields by ref, clicks
  Submit, and reads the result back. The thread shows each act (`typed into "Guest name"`, `clicked
  "Confirm"`).
- On a production host each act asks, in red. A password or card field is refused: *that field is
  yours to fill*.

### History, bookmarks and links (3c-iii)

- Address-field suggestions: open tabs first, then bookmarks, then history, best match first; ↓ ↑ and
  Return, Esc restores what was typed.
- ⌘D bookmarks the tab (one tap, no dialog; ⌘D again removes it). Bookmarks are listed in ⌘P and in a
  ★ menu in the header.
- Links in the terminal (⌘-click) and editor (⌘-click on a URL) open in the browser pane.

## What it does not do

- No extensions, no content blocker, no reader mode, no private window, no tab groups, no sync with
  Safari's or Chrome's bookmarks or history (an import could come later on demand).
- No password manager of Wakil's own; the agent never fills credentials.
- No capture of a page's text into an API value (the mockup's *Bind to confirm*). #137 requires the
  browser to name when a captured value ends before it becomes a value source; that is its own row.
- No push notifications from sites.

## Design

### WakilKit — `Browser/` (a new folder)

- `BrowserPaneKind` (`names: ["browser"]`): `Contents` is the pane's tabs (`BrowserTab`: id, url,
  title, isLoading, progress, canGoBack, canGoForward, lastError, zoom), the active tab id, the find
  state and the pane's downloads. `rerunsSubjectOnRestore` stays false: restore is the lazy reload of
  call 9, a `PaneRestoreStep` that opens the active tab's URL.
- `PaneStore+Browser.swift`: the store methods the actions call, plus `browserPageDidChange(pane:tab:…)`,
  the one non-action write (call 5), which records only what the page reports and never navigates.
- `BrowserActions.swift`, `registerBrowserActions`: the actions of call 5 and 6, each with its
  audience. `browser_read_page` is `.read`; the acting actions are `.mutate` with a price computed per
  call from the host (allowed-in-conversation → allow; production → gate every time; otherwise gate,
  and an approval adds the host to the conversation's allow-list). Both reach the page through a
  `BrowserPageDriver` seam the view supplies, running Wakil's script in an isolated `WKContentWorld` so
  page script cannot see, call or spoof it; refs are assigned by that script on read and resolved by it
  on act, and a stale ref is refused with *the page changed since it was read — read it again*.
- `BrowserFieldRules.swift`: the never-list of call 6 as a pure rule over a field's type, autocomplete,
  name and label.
- `BrowserSiteConsent.swift`: the per-conversation allow-list, keyed by conversation lineage root, and
  the production-host list.
- `BrowserAddress.swift`: the pure rule turning what was typed into a URL or a search (`localhost:3000`,
  `10.0.0.5`, `foo.test`, `api.initech.dev/docs` are URLs; `confirm booking 409` is a search; a scheme is
  kept; `http://` is shown as not secure).
- `BrowserProfile.swift`: org → data-store identifier, created on first use, kept through rename.
- `Pane.kinds` gains `"browser"`; `PaneKinds.standard` gains `BrowserPaneKind`.

### WakilApp

- `BrowserPane.swift`: the header, tab list, find bar, download strip and prompts. One `WKWebView` per
  live tab, kept by a `BrowserTabHost` keyed by pane and tab, so switching tabs or layouts does not reload.
  Each web view's configuration uses the org's data store; `isInspectable = true` gives Web Inspector.
  `WKNavigationDelegate` / `WKUIDelegate` / `WKDownloadDelegate` report into the store through the seam.
- `Canvas.swift`: one `case "browser"`. `AppScene.swift`: ⌘T, ⌘W, ⌘⇧T, ⌘L, ⌘R, ⌘[ ⌘], ⌘F, ⌘D and the
  zoom keys are menu commands that check the focused pane's kind (as ⌘W's `closeFocusedTabOrPane`
  already does) and route to the browser when it is a browser pane, otherwise to today's targets. A
  focused `WKWebView` gets key equivalents before the menu, so the web view subclass passes Wakil's
  (⌘K, ⌘P, ⌘N, ⌘T, ⌘W, ⌘L, ⌘D, ⌘1–9, ⌘,) to the menu first and lets the page have the rest; an e2e
  check proves ⌘K and ⌘P open their planes while the page has focus. `PaneClickWatcher`'s treatment of a
  `WKWebView` as a text target is checked not to swallow them.
- The web view takes the keyboard while the page is focused and gives it back on a click outside, as the
  Monaco host does (3b-v's click-to-focus).

### Go — none in 3c-i and 3c-ii

The browser touches no system Wakil's Go layer owns; WebKit is the capability. 3c-iii's history store is
Swift (SQLite through the system library), beside the org's profile, since only the window reads it.

### Interaction rules

1. **Confirm only what destroys.** Closing a tab, a pane or a download does not ask; clearing browsing
   data and deleting it with an org do. Leaving a page with an unsent form is the page's own
   `beforeunload` prompt, shown in place.
2. **Enter is never required.** The address field commits on Return only, by its nature — leaving it
   without Return restores the current URL (it is a command line, not a stored field); called out as
   the exception, as Safari does.
3. **New input focused:** a new tab or pane focuses the address field; ⌘F focuses the find field.
4. **Cancel:** loading shows × (Esc), a download shows Cancel.
5. **In flight:** the progress line and × while loading; a second Return in the address field
   replaces the load, it does not queue a second.
6. **Stay where the operator was:** closing a tab selects its neighbour to the right, else left, as Safari.
7. **Override or ignore:** a typed URL without a scheme gets `https://`; an unknown scheme is handed
   to macOS (`mailto:` opens Mail).
8. **Errors whole:** load failures, download failures and the agent's refusals are shown in full.
9. **Defaults suggest:** search engine and start page are settings.

## Errors and edges

- **A certificate error** shows the error page with the host and the reason, and *Visit Anyway* for that
  host for the session — the operator's call, as in Safari; the agent's navigation never passes one.
- **A crashed web content process** (`webViewWebContentProcessDidTerminate`) shows "This page stopped"
  with Reload; other tabs are unaffected.
- **An org switch** swaps the canvas, so the old org's browser panes leave with it and their web views
  are kept alive for the return (R4's "canvas as it was left"); memory pressure may unload background
  tabs, which then reload on selection.
- **`window.open` pop-ups** (OAuth) open as a tab beside the opener with the opener's configuration, so
  `window.opener` works and the pop-up's `window.close()` closes the tab.
- **Hundreds of tabs:** web views beyond the 20 most recently used are released and keep only their URL.

## Testing

- **WakilKit:** `BrowserAddress` cases above; the store methods and every action's effect on `Contents`;
  `read_pane` keys (and that page text is never in them); the agent refusals; profile identifier stable
  across rename and distinct per org; restore loading only the active tab.
- **e2e:** a local fixture HTTP server (`e2e` already serves fixtures) with pages for links, `target=_blank`,
  a form, a download, an alert and a slow page; checks for open, address, back/forward, tabs, find,
  download cancel, the in-place alert, focus (Rule 3) and a narrow-width frame. Page content itself is a
  web view (the resolver cannot address HTML), so what a page shows is read through `read_pane` /
  `browser_read_page`, and clicking inside it is the walk's.
- **3c-ii's tests:** the price for each case (unallowed → gate and allow-list grows; allowed → allow;
  production → gate every time even when allowed); the never-list over each field shape; a stale ref
  refused; the allow-list emptied when the conversation closes; an e2e check on a fixture form: allow,
  type, submit, read back.
- **Walk:** signing in to a real site in one org and finding it signed out in another; OAuth pop-up;
  Web Inspector; a real download; camera prompt.

## Charter changes this sub-phase makes

- `north-star.md` §8: a **3c** row (and 3c-i/ii/iii); `design-language.md` §11's Browser row says what
  the agent may do and that the page is the second dual-drive exception.
- **Decision 48:** the browser — WebKit, a profile per organisation, the page as the second exception
  to dual-drive, the agent reads freely and acts in a page only on a site allowed for the conversation.
- **Invariant 6 gains a tenth write:** *Act in a web page — click, type, select, press — on a site the
  operator allowed for the conversation; every act on a production host gated* (adapter: the browser,
  2026-10-25), with its justification under *the writes that have earned in*, and *a password, card or
  one-time-code field typed by the agent* added to **Still refused**. Navigation stays a read.
- Decision 48 records the per-site price and why per-submit was rejected.
