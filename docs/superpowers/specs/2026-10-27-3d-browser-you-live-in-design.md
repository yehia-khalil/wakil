# 3d: the browser you live in — groups, pinning, vertical tabs, identities, picture-in-picture, passwords

**Date:** 2026-10-27
**Status:** design written after a brainstorm with the operator ("go ahead"); the picture-in-picture
spike's findings folded in; builder check pending; awaiting the operator's review
**Sub-phase:** 3d, a new Phase 3 row after 3c. Follows main 3a5fee8 (3c-iii, #76).
**Supersedes:** `2026-10-26-3c-browser-next-decisions.md` (the brainstorming notes). Where this
spec and the notes differ, this spec wins and says so.

---

## Problem

The operator browses in Dia and wants Wakil's browser to replace it. 3c gave Wakil a full browser:
tabs, a profile per organisation, the agent's reach, history, bookmarks and links. What still sends
the operator back to Dia every day:

- **Tabs pile up with no shape.** In Dia, YouTube videos, GitHub tabs, and Jira and Confluence pages
  each fall into their own group without being asked, and products opened from an Amazon search stay
  with that search. "Its integrated nicely and seamless" (operator, 2026-10-27).
- **Nothing stays put per project.** The tabs a project always needs (its PRs, its staging site) are
  reopened by hand in every place.
- **A narrow pane wastes its tab strip.** Dia's vertical tabs, tucked away until wanted, are the
  shape the operator works in.
- **One login per site per organisation.** Testing a site as an admin and as a customer at once
  needs two browsers.
- **Video stops when you look away.** The operator watches a lot of video; leaving its tab hides it.
- **Passwords are retyped.** On the unsigned build a login form shows no Passwords suggestion
  (tested on `github.com/login`, 2026-10-26).

## Decisions the operator took

- **Groups form themselves, like Dia's, mostly by site** (2026-10-27): "its usually grouping youtube
  open vids, github tabs, jira and confluence pages. when searching for an item on amazon it groups
  related products and search results."
- **A group is named once, from the titles of its first tabs; later tabs never rename it**
  (2026-10-27): "the initial title it generates is by reading the titles of the first grouped tabs. it
  doesnt change by the ones added afterwards."
- **Naming is a quick task** (2026-10-27, "can it be part of quick tasks?"): it goes where ghost
  text and commit messages go, the organisation's quick-tasks provider, else its active one.
- **Groups are named, coloured and collapsible; collapsed, a group takes little room** — its title and
  its open tab (2026-10-27, notes decision 3).
- **A pull-request group fills itself**, one per organisation, from its GitHub account, read only
  (2026-10-26, notes decision 3).
- **Pinning is per project, of tabs and of groups; pinned first; ⌘W on a pinned tab closes it only on a
  second press within 2 s; its × closes it in one click** (2026-10-27, notes decision 3).
- **Vertical tabs are one Browser setting for every pane, and the column tucks away like Dia's**
  (2026-10-27: "a setting for all panes, like dia"; "like dia").
- **Identities inside an organisation, like Firefox containers** (2026-10-26, notes decision 5, kept
  as written there).
- **Passwords: Wakil's own, in the Keychain** (2026-10-26, notes decision 6 "now"). The operator has
  no paid Apple Developer account (2026-10-27), so the signed-build test of the Passwords app's
  autofill waits until there is one.
- **Picture-in-picture is automatic** (2026-10-26, notes decision 1). How it is built was left to a
  throwaway build, which ran on 2026-10-27 (below).
- **One spec, three build lanes, run side by side** (2026-10-27, "can we speed this up by grouping
  tasks together?" → "go ahead").

## Calls made for the operator (flagged for review)

1. **Every group lives in its pane; pinning shares it across a project** (operator, 2026-10-27:
   "project level is enough"). This overturns the notes' "groups belong to the organisation": automatic
   grouping touches nearly every tab, and org-wide groups would need their tabs kept in step across
   panes and places. So an automatic group and one you make are both the pane's, saved with its tabs in
   the layout as today. A group becomes **yours** when you rename, recolour or pin it, drag a tab into
   or out of it, or make one (right-click a tab → *New Group…*); Wakil then never regroups it. To have a
   group in every place of a project, pin it (call 8). Only the pull-request group is the
   organisation's.
2. **The site rule.** Two tabs share a site when their registrable domains match (eTLD+1:
   `www.youtube.com` and `m.youtube.com` → `youtube.com`), or when both fall in one family of a small
   built-in table: `youtube.com`/`youtu.be`; `atlassian.net`/`atlassian.com` (Jira and Confluence
   Cloud); `github.com`/`githubusercontent.com`; `google.com`'s Docs, Sheets and Drive hosts. Loopback
   and `.test`/`.localhost` hosts group by host and port. The table lives in WakilKit and grows by
   pull request, not by a setting.
3. **The opener rule.** A tab opened from a tab — `target=_blank`, ⌘-click or middle-click in a page,
   `window.open` — joins its opener's group, whatever its site (the Amazon case). A tab opened from
   the address field, ⌘T, ⌘P, a link elsewhere in Wakil or the agent is placed by the site rule only.
4. **A group forms at two tabs** of one site (or one opener chain) in the pane. One tab alone stays
   loose. An automatic group whose tabs drop to one dissolves; its last tab stays where it was.
5. **Naming.** When an automatic group forms, Wakil sends the titles of its first tabs (up to five,
   the order they were opened) to the `respond` quick task, asking for a name of at most three words.
   Until a reply comes, and for good if naming is off or fails, the group is named after the site
   (`YouTube`, `GitHub`, `Atlassian`) or, for an opener chain, after the opener's title cut to three
   words. Tab titles only, never addresses or page text. A failure goes to the quick-tasks status in
   Settings whole (Rule 8), as ghost text's do. **Browser → *Name groups with AI*** turns it off; on by
   default, because the provider is one the operator already chose for that organisation. (Quick tasks
   have no per-task list today, so the switch lives with the browser. This corrects what I said in the
   brainstorm.)
6. **Colours.** A group's colour is one of six muted swatches drawn from the design language's
   palette at low saturation, never the reserved violet, amber or red, so a group's colour is never
   read as state (`design-language.md` §5). An automatic group takes the next free swatch.
7. **Collapsed shows the tab last open in the group** (the notes' open point): its title and the
   group's name, so a collapsed group still says where you were.
8. **A pinned tab or group in two panes of one project** shows in both, each pane with its own live
   page. A pin keeps the address it was pinned at: navigating a pinned tab moves only that pane's page,
   and the pin's own address changes only by *Pin Current Page* on it (right-click). So
   `pins/<project>.json` is a static list, read when a pane opens and written when a pin changes; no
   live sync between panes. Unpinning removes it from every pane of the project.
9. **Vertical tabs:** the column sits on the pane's left, 220 pt wide (resizable 160–360 pt, kept app-
   wide). **⌃⌘S** hides and shows it (the Mac's Show Sidebar key). Hidden, a pointer resting on the
   pane's left 6 pt for 150 ms slides it out over the page, and it slides back when the pointer leaves
   it. Whether it is hidden is kept per pane, so a narrow pane can stay hidden while a wide one shows
   it.
10. **The pull-request group** refreshes when a browser pane of the organisation opens and every five
    minutes while one is open, and on ⌘R with the group's header focused. Its entries are tabs that load
    only when shown (as restored tabs already do, 3c-i), so a long list costs no web views. The read is
    Go's (Invariant 10): a `ctx_github_pull_requests` call through the organisation's GitHub account
    (3a-iii's token, `git-<host>-token`), returning number, title, URL and why it is listed. It is absent
    when the organisation has no GitHub account or its account holds no token (an ssh-only account),
    and Settings → Browser says why in one line. A failed
    refresh keeps the last list and shows the error whole on the group's header (Rule 8). It is never
    an automatic group and cannot be renamed; it can be collapsed and pinned.
11. **Picture-in-picture uses WebKit's own** (the spike, below), with one private preference.
12. **Passwords are saved per organisation and identity** in the login Keychain under Invariant 4's
    naming: service `wakil:<org>:browser-login:<identity>` (`default` for the default identity),
    account `<site> <username>`. The site key is the registrable domain, as for groups. They are read
    and written from WakilKit, not through Go: only the window fills a page, and the org in the name is
    checked on every read as `Resolve()` checks it, so another organisation's item is never returned.
    Lane C starts on the default identity; identities need no migration, since the name already
    carries one.
13. **Clearing an organisation's browsing data** (3c-i) clears every identity's store too. Passwords
    are not browsing data and stay; they are deleted per login in Settings. `wakil org rm` names the
    identities' stores and the password items as residue to clear first, as it names the profile store
    today; it deletes no Keychain item itself.
14. **Leaving a video** means its tab is no longer on screen: another tab selected, its pane closed or
    covered by a maximized pane, the place or the organisation switched, or the window minimized.
    Keyboard focus moving to another pane while the video is still visible does not float it.

## What the operator gets

Three lanes. A and B start together; C starts when a lane frees, on the default identity (call 12). Each lane is its own plan, branch,
review and walk. Lane A runs its two sub-phases in order because both change the tab model.

### Lane A, 3d-i: the tab model — groups, pinning, vertical tabs

- **Automatic groups** by the site and opener rules above, named once by a quick task.
- **Your own groups**: *New Group…*, rename (the name field opens focused, and keeps what is typed
  when focus leaves, Rules 2 and 3), recolour, drag tabs in and out, *Ungroup*, *Close Group*.
  The pane's, like an automatic group; pin it to share it across the project.
- **Collapse and expand** a group with a click on its header. Collapsed: header and its last-open tab.
- **The pull-request group**, one per organisation, at the top of the groups.
- **Pinning**: right-click a tab or a group → *Pin to <project>*. Pinned tabs and groups come first,
  in every browser pane of the project's places. ⌘W on a pinned tab shows `Press ⌘W again to close` on
  the tab; a second ⌘W within 2 s closes it; after that the tip goes. Its × closes it in one click.
- **Vertical tabs**: Browser → *Tabs: Horizontal · Vertical*. Vertical: the column on the left, pinned
  first, then groups, then loose tabs; ⌃⌘S hides it; hover at the edge peeks it.
- **Horizontal with groups**: a group is a coloured chip in the strip; expanded, its tabs follow the
  chip; collapsed, the chip shows its name and its last-open tab's favicon.
- The agent gets the same as actions (Invariant 2): `browser_group` (create, rename, recolour,
  collapse, ungroup, close), `browser_tab_move` gains a group, `browser_pin` / `browser_unpin`, and
  `read_pane` reports each tab's group and pin. Priced `.control`, allow, like the other tab actions.

### Lane A, 3d-ii: identities

As the notes' decision 5, unchanged:
- Right-click a tab → **Identity ▸** `Default · <each identity> · New Identity…`. Changing a tab's
  identity reloads its page in that identity. New Identity… opens a name field in the menu, focused,
  made when focus leaves it, no Enter (Rules 2, 3).
- ⌥-click ＋, or ⌘K *New Tab as <identity>*, opens a tab in an identity. A link opened from a tab keeps
  its identity. A group may have a default identity.
- A tab in an identity has a coloured mark, and its address field names it. The default identity has
  none.
- Settings → Browser → Identities: rename, recolour, delete. Delete asks in place (Rule 1) and clears the
  identity's store and its passwords.
- Each identity is its own `WKWebsiteDataStore(forIdentifier:)` inside the organisation, its id in
  `~/.wakil/orgs/<org>/browser/identities.json`. Identities never cross organisations.
- The agent: `browser_open {identity}`; it is still asked per site (Decision 48), and the site question
  names the identity when it is not the default.
- History stays per organisation, not per identity (my call: one place to find a page you saw).

### Lane B, 3d-iii: picture-in-picture

- A video that is **playing** floats out by itself into the system's picture-in-picture window when
  you leave its tab, its pane, the place or the organisation. A video you paused, or one that ended,
  does not. The window is macOS's own: drag it to a corner, resize it, Play/Pause, ±10 s, **Restore**
  (back to the tab) and Close. Close pauses the video.
- **Restore** takes you to that organisation, place, pane and tab and puts the video back in the page.
- Coming back to the tab yourself brings the video back into the page too (my call: the floating copy
  is for when you are away, so it ends when you return).
- One floating video at a time, the newest replacing the last (the notes' call, kept).
- Browser → *Picture in picture: On · Off*, on by default.

**How (the spike, 2026-10-27, findings in the operator's `.scratch/pip-spike/findings.md`):**
- Every tab's configuration sets `allowsPictureInPictureMediaPlayback` to true on `WKPreferences`
  through KVC, beside `developerExtrasEnabled`. **This is private API**: the public configuration
  property is iOS-only. Without it, every route answers `NotSupportedError`.
- On leaving, Wakil runs a script in every frame that finds a `<video>` that is `!paused` — or was
  playing when the page went hidden, while the page stays hidden — and `!ended && readyState > 2 &&
  !disablePictureInPicture`, calls `webkitSetPresentationMode('picture-in-picture')` and `play()`s it
  if WebKit paused it (amended 2026-10-27, below). The prefixed call needs no user gesture
  (`requestPictureInPicture()` from a no-gesture script is refused). It works before or after the web
  view leaves the window. A video with sound keeps playing with the view removed, hidden or ordered
  out; a muted or silent one is paused by WebKit the moment its view leaves, and floating plays it
  again. Tested on a local `<video>` and on YouTube (`blob:` media).
- Restore arrives as the private `WKUIDelegate` method `_webViewFullscreenMayReturnToInline:`; Wakil
  must switch to the tab **and put the web view back in the window synchronously, inside that call** —
  without it the page shows a blank video box while the window keeps playing.
- `_webView:hasVideoInPictureInPictureDidChange:` says which tab floats. Close needs no handling.
- Returning to the tab calls `webkitSetPresentationMode('inline')`, which leaves PiP cleanly.
- Every private selector is guarded with `responds(to:)`; if WebKit drops one, picture-in-picture is
  off and Settings says why, whole.

### Lane C, 3d-iv: passwords

As the notes' decision 6 "now", with these calls:
- **Saved per organisation and identity** in the login Keychain (call 12). Never in a file, never in
  the store's state, never in `read_pane`, never sent to the agent.
- **Fill:** a key glyph inside a page's username or password field, drawn by Wakil over the page at the
  rect the field reports. Pressing it lists the site's logins; choosing one fills both fields. Filling
  is the operator's only; there is no autofill without a press.
- **Save:** when a form with a password field is submitted, an in-place bar at the pane's top asks
  `Save the password for <user> on <site>?` — **Save**, **Not Now**, **Never for This Site**. An
  update to a saved login asks `Update the password…`. The bar never blocks the page.
- **Suggest:** a field with `autocomplete="new-password"` gets a strong password offered in the key's
  list (20 characters, Safari's shape: letters and digits in four groups of five with hyphens).
  Choosing it fills both new-password fields and saves when the form is submitted.
- **Import once from the Passwords app's CSV export** (Settings → Browser → Passwords → *Import…*):
  every row listed by site, each with an organisation picker defaulting to the current organisation,
  then *Import*. The CSV is read and never copied; after the import Wakil offers to move it to the
  Trash (asked in place).
- Settings → Browser → Passwords lists the organisation's logins by site: reveal (Touch ID or the
  Mac's password, through `LocalAuthentication`), copy, edit, delete (asked in place).
- The agent never sees a password, never fills one, and `browser_read_page` already reports a password
  field's value as absent (3c-ii's never-list).
- **Later, not in 3d:** with a paid Apple Developer account, a signed build tests whether the Passwords
  app's autofill and passkeys work in Wakil's web view. If they do, Wakil switches to them and drops
  its own store.

## What it does not do

- No grouping by page text or by a model reading pages. The model sees tab titles only, once per
  group, to name it.
- No regrouping: an automatic group keeps its name and never splits or merges on its own.
- No sync to the phone, no passkeys of Wakil's own, no one-time codes, no card filling.
- No Wakil-drawn picture-in-picture window; the floating-panel route stays the fallback if the private
  preference ever stops working, and needs its own spec then.
- No groups shared across a whole organisation or across organisations; a group reaches other places
  of its project only by being pinned.

## Design

### WakilKit — `Browser/`

- `BrowserTab` gains `group: String?` (a group id), `opener: String?` (the tab it was opened from),
  `identity: String?` (nil is the default) and `pinned: Bool`; `BrowserSavedTab` gains the same, so a
  relaunch keeps them. A pane's own state gains `groups: [BrowserGroup]` and
  `tabColumnHidden: Bool`.
- `BrowserGroup` (id, name, colour, collapsed, `lastOpen: String?`, kind `.automatic | .own | .pullRequests`,
  `siteKey: String?`, `named: Bool`).
- `BrowserGrouping.swift`: the pure rules — `siteKey(url)` (eTLD+1 from a bundled snapshot of the public suffix
  list, no network; my call, since Foundation exposes no public suffix API), the family table, `place(tab:in:)` answering which group a new or navigated tab joins, the
  two-tab threshold, dissolve at one, and "becomes yours" on any manual change.
- `BrowserGroupNames.swift`: the prompt and the reply rule for the `respond` quick task — titles in,
  at most three words out, trimmed of quotes and punctuation; the site-name fallback.
- Groups are pane state: `BrowserSavedTab.group` and the pane's saved groups go in the layout with its
  tabs, as tabs do today. Org-level state in `~/.wakil/orgs/<org>/browser/`: `pins/<project>.json`
  (that project's pinned tabs, and its pinned groups with their tabs as saved at pinning) and
  `identities.json`. Each
  written whole, atomically; an unreadable file is never written over (3c-iii's Ruling 4) and the
  error is shown whole in the pane.
- `BrowserPasswords.swift` (lane C): the Keychain seam, the CSV parser (Passwords' columns `Title,
  URL, Username, Password, Notes, OTPAuth`; extra columns ignored, Rule 7), the strong-password
  generator.
- Actions in `BrowserActions.swift`, each a `browser_*` action with its schema and audience.

### WakilApp

- `BrowserPane` draws the strip with group chips, or the vertical column (`BrowserTabColumn.swift`),
  from the same ordered list: pinned, PR group, your groups, automatic groups, loose tabs.
- `BrowserWebView`: the PiP preference and script, the private delegate methods, the opener recorded
  in `createWebViewWith`, the identity's data store, and the password field reports and key overlay.
- `AppScene`: ⌃⌘S, and ⌘W's second-press rule for a pinned tab.
- Settings → Browser: *Tabs*, *Name groups with AI*, *Picture in picture*, *Identities*, *Passwords*.

### Go

- `ctx_github_pull_requests` (call 10): `is:pr is:open author:@me` and `review-requested:@me` through
  the organisation's GitHub token, deduplicated; a failure returned whole.
- `browsersettings.go` gains `tabs` (`horizontal` | `vertical`), `nameGroups` and `pictureInPicture`,
  read-modify-write as today; `ctx_set_browser_settings` forwards them.
- `wakil org rm` names the identities' stores and the Keychain's password items as residue, as it
  names the profile store today.

## Interaction rules

1. **Confirm only what destroys.** Deleting an identity, a saved password, or the imported CSV asks in
   place. Closing a group, ungrouping or unpinning does not. **The named exception:** ⌘W on a pinned
   tab needs a second press within 2 s. It guards the keyboard, where ⌘W meant for another tab or the
   pane can land on a pinned one; the × still closes it in one click (operator, 2026-10-27).
2. **Enter is never required:** a group's name, a new identity's name, and a password being edited keep
   what was typed when focus leaves.
3. **New input focused:** *New Group…*, *Rename*, *New Identity…* open their field focused.
4. **Cancel:** the import can be cancelled while it runs; a naming request is never waited on.
5. **In flight:** the pull-request group's header shows it is refreshing and ignores a second ⌘R; the
   import's *Import* is disabled while it runs.
6. **Stay where the operator was:** grouping never changes the active tab, its scroll or the keyboard;
   a tab moved into a group stays selected. Restore from picture-in-picture is the exception the
   operator asked for: it is a request to go back.
7. **Override or ignore:** an unknown CSV column is ignored; a row with no URL or password is listed as
   skipped, not refused.
8. **Errors whole:** a naming failure, a pull-request refresh failure, an unreadable `pins/<project>.json`, a
   Keychain error and an unavailable private WebKit method are each shown in full.
9. **Defaults suggest:** naming on, PiP on, horizontal tabs, the default identity — each a setting.

## Errors and edges

- **A tab navigates to another site** inside an automatic group: it stays in the group if it came by
  the opener rule; otherwise it moves by the site rule (my call: a site group stays one site).
- **Closing a tab whose video floats** ends picture-in-picture: the system window goes with the web
  view, and WebKit sends no `hasVideoInPictureInPictureDidChange: false`, so Wakil clears the floating
  tab itself (probe, 2026-10-27).
- **Two videos playing at once:** the newest-playing one floats.
- **A video in a cross-origin iframe** (embedded YouTube) needs the script in every frame; the probe
  floated one by its frame, with no gesture.
- **The organisation has no GitHub account:** no pull-request group, no error.
- **Keychain denied or locked:** the key glyph's list shows the error whole; nothing is filled.
- **An identity deleted while its tabs are open:** they move to the default identity and reload.

## Testing

- **WakilKit:** the site key and family table; the opener rule; form at two, dissolve at one; becomes
  yours; naming's reply rule and fallback; pin per project and the 2 s second press; saved tabs round-
  trip with group, pin and identity; the CSV parser; the strong-password shape; refusal of an
  unreadable `pins/<project>.json`.
- **e2e:** fixture pages on two local hosts and an opener page; checks for automatic grouping, a named
  group via a scripted quick-task provider, rename, collapse, pin across two places of one project,
  ⌘W twice, the vertical column and ⌃⌘S, a tab in an identity signed in where the default is not, PiP
  entered on leaving a fixture video (read through `read_pane`'s floating tab) and ended on return,
  and save-then-fill on a fixture login form with a test password.
- **Walk:** real YouTube, GitHub, Jira and Amazon tabs grouping as in Dia; the PR group; picture-in-
  picture dragged to a corner and Restore; a real sign-in saved and filled; the Passwords CSV import.

## Charter changes

- `north-star.md` §8: a **3d** row and 3d-i … 3d-iv.
- **Decision 49:** groups per pane (automatic and yours alike), pinning per project as the one way to
  share them, identities
  as stores inside the organisation, WebKit's own picture-in-picture through one private preference,
  and Wakil's own passwords in the Keychain. It overturns 3c's "no tab groups" and "no password manager
  of Wakil's own".
- **Invariant 4:** a saved password is a credential; it lives only in the Keychain and never reaches
  the agent, the store, a file or a log.
- **Invariant 6, Still refused:** unchanged — the agent still never types into a password field, and
  now never fills one either.
- `design-language.md` §11's Browser row: groups, pins, the vertical column, the identity mark and the
  key glyph.

## Amendment, 2026-10-27 — what the 3d-iii probe found

`docs/wakil/3d-iii-pip-probe.md` (3d-iii Task 1) contradicts two lines of "How (the spike…)" and
settles two edges.

- **The candidate rule changes.** WebKit pauses a playing video that is muted or has no audio track
  the moment its web view leaves the window, or the window is minimised (the `pause` event 1–2 ms
  later), and resumes it when the view returns. A video with sound keeps playing. With the old rule
  (`!paused && …`) a float worked only when Wakil's script reached the page before that pause, which
  nothing guarantees. A video now counts if it is `!paused`, or if its own events said it was playing
  when the page went hidden (`visibilitychange`) and the page is still hidden; and `!ended &&
  readyState > 2 && !disablePictureInPicture`. Floating calls `play()` on such a video. A video you
  paused yourself still does not float. The body's "How" bullet is edited to match.
- **"The video keeps playing with the view removed, hidden or ordered out"** holds only for a video
  with sound. Edited.
- **Closing a tab whose video floats** ends picture-in-picture, but no `false` callback arrives; Wakil
  clears the floating tab itself. Edited under Errors and edges.
- **A cross-origin iframe's video** floats through its frame from the `wakil.pip` world. Edited under
  Errors and edges.
