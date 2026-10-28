# 3d-i — the tab model: acceptance

**Spec:** [`2026-10-27-3d-browser-you-live-in-design.md`](../superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md) §Lane A, 3d-i
· **Plan:** [`2026-10-27-3d-i-tab-model.md`](../superpowers/plans/2026-10-27-3d-i-tab-model.md)

The exit criterion: a browser pane's tabs take a shape. Same-site tabs and a page's own pop-ups fall
into automatic groups named once by the `respond` quick task. The operator makes, renames, recolours,
collapses and drags tabs between their own groups. One pull-request group per organisation fills itself
from its GitHub account. Tabs and groups pin per project. A Browser setting turns the strip into a left
column that ⌃⌘S tucks away.

## 0. Setup

Run this in the worktree root, on this Mac. It is safe to re-run.

```bash
make build && make app-bundle
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

Organisation **A** has a GitHub token account. Organisation **B** has none. Row 5 needs a project with
two places (two environments).

## 1. The walk

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | Open YouTube twice, GitHub twice, a Jira issue and a Confluence page | Three groups: *YouTube*, *GitHub* and *Atlassian*. Each is first shown by its site name, then renamed once by the model. A third YouTube tab joins without renaming | |
| 2 | Wakil | Search Amazon, ⌘-click three products | They join the search's group. The active tab, its scroll and the keyboard never move | |
| 3 | Wakil | Right-click a tab → **New Group…**, type a name, click away. Then rename, recolour and collapse an automatic group | The new group is kept. The automatic group never moves, and collapsed it shows its name and the last tab open | |
| 4 | Wakil | Drag a tab out of a group and back. Ungroup a group, then open another tab of its site | The dragged tab leaves and returns. The ungrouped tabs stay loose | |
| 5 | Wakil | Pin a tab and a group to the project. Switch to another place of the project. Unpin there, then return to the first place | In the other place both are first and unloaded. After the unpin they are gone from the first place's pane on return | |
| 6 | Wakil | ⌘W on a pinned tab. Wait 3 s, ⌘W. Then ⌘W twice quickly. Then click the × on a pinned tab | The first ⌘W shows `Press ⌘W again to close`. After 3 s the tip shows again. Twice quickly closes it. The × closes in one click | |
| 7 | Wakil | Organisation A: look at the top of the strip, expand the *Pull Requests* group, press ⌘R on its header. Then switch to organisation B and open ⌘, → **Browser** | A shows the group at the top, collapsed. Expanded, it lists your open PRs and reviews, and ⌘R shows it refreshing. B has no group, and Settings → Browser says why in one line | |
| 8 | Wakil | ⌘, → **Browser** → **Tabs** → **Vertical**. Drag the column's edge to 360 and to 160. Press ⌃⌘S. Rest the pointer at the left edge, then move away | The column is on the left: pinned, then groups, then loose. The width stops at 360 and at 160. ⌃⌘S hides it. At the edge it slides out, and back when you leave | |
| 9 | Wakil | Hide the column in a narrow pane and show it in a wide one. Relaunch | Each pane keeps its own hidden or shown state. The width is the same in both | |
| 10 | Wakil | ⌘, → **Browser** → **Name groups with AI** → Off. Form a new group. Break the quick-tasks provider, turn it On and form another group | With it Off the group keeps its site name. With a broken provider the group keeps its site name and Settings → Providers shows the error whole | |
| 11 | Wakil | Open a few real sites (`github.com`, `wikipedia.org`, a site naming no icon) and a page with a `data:` icon. Go offline and open another | Each tab shows its site's own icon, from the page's `link rel=icon` or `/favicon.ico`; the `data:` page keeps its icon. Offline, or with a missing or oversized icon, the tab keeps the globe. The request carries no cookies: the page has already contacted that site | |
| 12 | Wakil | Collapse a group that holds the active tab, in the horizontal strip and then the vertical column. Select a tab outside it, then back. Click the header | The active tab shows under the header like a member row (indented in the column, beside the pill in the strip) and the rest are hidden. With the active tab outside, the group shows its header only. Clicking the header expands it fully | |
| 13 | Wakil | Focus a browser pane on a real page and press ⌘⇧C. Paste into the address field of another app. Press ⌘⇧C with an editor pane, then a terminal pane, focused | The page's address is on the clipboard and `Copied` shows near the address field, fading in about a second and a half. The keyboard stays where it was and the page does not change. In the editor and the terminal the key does what it did before and copies nothing from the browser. The agent's `browser_copy_url` does the same, naming a tab if asked | |
| 14 | Wakil | On a page with links, middle-click one, then ⌘-click another, then middle-click a link that opens in a new window (`target=_blank`) | Each opens in a new tab behind the page, joining the page's group as a ⌘-click does. The active tab, the scroll and the keyboard do not move | |
| 15 | Wakil | Middle-click a tab in the horizontal strip, then in the vertical column. Middle-click a pinned tab. Middle-click a group's header. Left-click, drag and hover tabs as before | Each tab closes at once, as its × does; a pinned tab closes in one click, not two ⌘W presses. The header does nothing. Left clicks, drags, hover and tooltips behave as before | |
| 16 | Wakil | Tabs = Vertical. Look at the header, then narrow the pane until the address is short. Press ⌘L, load a page, start a download. Switch to Horizontal | Vertical: one header row (browser glyph, ‹ › ↻, the address field, ★) over the page; the tab count sits at the column's foot beside *New Tab* and opens the tab menu. Narrow, the address field shrinks first and the glyph, controls and ★ keep their size. ⌘L, the progress line and the download row work. Horizontal is unchanged: the strip row, then the address row | |
| 17 | Wakil | Have three groups of different colours, one pinned, and the *Pull Requests* group. Look at them with Tabs = Vertical, then Horizontal. Collapse and expand a group in the column, then turn on Reduce Motion and do it again. Select a member of an expanded group | Each header is a pill tinted with its own colour, a solid dot in that colour, the name in medium weight and the member count at its right; no dot is grey. Collapsed, up to three member favicons overlap before the count. In the column the chevron turns as it opens (at once under Reduce Motion), and one line in the group's colour runs down its members, broken at the active one, where the violet tick stands in its place: never two bars side by side. The strip shows the same pill, its members underlined in the colour | |
| 18 | Wakil | Tabs = Vertical. Pin two tabs and a group, then reopen the project so one pinned tab is not loaded. Drag the column's edge to 160 and 360. Drag a loose tab onto the tiles, a tile below the line, a tile between two tiles. Middle-click a tile, hover it and click its ×, right-click it. Unpin everything. Switch to Horizontal and repeat the drags | At the top a grid of square favicon tiles, four to a row at the default width (three at 160, seven at 360), the title on hover; the active one is raised with a violet bar under its favicon, the unloaded one dimmed. The pinned group's pill and members follow, then a thin line; no unpinned tab is ever above it. The loose tab dropped on the tiles is pinned there; the tile dropped below the line is unpinned where it lands; between tiles it moves. Middle-click and × close the tile at once, the menu is the tab menu, and nothing takes the keyboard. With nothing pinned there is no section and no line. Horizontal: pinned tabs are favicon-only entries at the left, the pinned group's pill after them, then a vertical line; the same drags pin and unpin | |

## 2. Known and not fixed

None yet. This section fills in at the walk.

## 3. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
