# 3c-iii — history, bookmarks and links: acceptance

**Spec:** [`2026-10-25-3c-browser-design.md`](../superpowers/specs/2026-10-25-3c-browser-design.md) §3c-iii,
and decision 8 of [`2026-10-26-3c-browser-next-decisions.md`](../superpowers/specs/2026-10-26-3c-browser-next-decisions.md)
· **Plan:** [`2026-10-27-3c-iii-history-bookmarks-links.md`](../superpowers/plans/2026-10-27-3c-iii-history-bookmarks-links.md)

The exit criterion: the address field suggests open tabs, then bookmarks, then history, and completes
the address inline. ⌘D and the ★ menu bookmark a page. ⌘P lists the open tabs and the bookmarks. A
⌘-click on a link in the terminal or the editor opens it in Wakil's browser, and ⌘⌥-click opens it in
the system browser. Search-engine suggestions are a setting, off by default.

The operator walked every row on 2026-10-27, after two rounds of fixes (rows 1, 5, 6, 9 and 10).

## 0. Setup

Run this in the worktree root, on this Mac. It is safe to re-run.

```bash
make build && make app-bundle
WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil
```

Organisation **A** is `personal` and **B** is `orgb`. Row 6 needs a project whose `origin` is on
github.com.

## 1. The walk

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | ⌘K → **New Browser pane**. Visit `github.com`, then `example.com`, then `news.ycombinator.com`, each typed and followed by Return. ⌘T, then type `gi` slowly | Under the field, over the page, a list appears with an icon per row. ⧉ is an open tab, ★ a bookmark, 🕘 history and 🔍 search. `github.com` is in the list. The field completes inline to `github.com` with the added part selected. ⌫ removes the completion and it does not come back on that keystroke | ✓ 2026-10-27 |
| 2 | Wakil | In the same tab, type `example` at your normal speed, then ↓ ↓ ↑, then Esc, then type ` again` and press Return. Then ⌘T, type `news`, and choose the ⧉ row for the Hacker News tab | No lost or doubled letters (never `example.comxample`). ↓ and ↑ move the highlight, and the field shows the highlighted row's address. Esc gives back exactly what you typed and closes the list. Return on `example again` searches with the engine. Choosing ⧉ selects the open Hacker News tab without loading it again, and the new blank tab is never listed as a suggestion | ✓ 2026-10-27 |
| 3 | Wakil | On `github.com`, press ⌘D. Open ★ at the right of the address row. Press ⌘D again. Press ⌘D once more, then visit `example.com` and choose GitHub from ★ | The first ⌘D fills ★ in amber with no dialog. The menu says **Remove Bookmark**, then lists the bookmarks, newest first. The second ⌘D empties ★. On `example.com` the menu says **Bookmark This Page**, and choosing GitHub opens it in the active tab. On a blank tab the toggle is greyed out. The ★ menu item shows no ⌘D (the menu bar owns it) | ✓ 2026-10-27 |
| 4 | Wakil | Open an editor pane and press ⌘D in it. Then ⌘P and type `git` | ⌘D in the editor does what it did before 3c-iii and adds no bookmark. ⌘P lists the open browser tabs (kind `tab`, verb *switch to*) and the bookmarks (`bookmark`, *open*). Choosing a tab focuses its pane and selects it. Choosing a bookmark opens it | ✓ 2026-10-27 |
| 5 | Wakil | Ask the agent in a terminal to `echo https://example.com/p?a=1&b=two:three and https://github.com`. Then ⌘-click the first link, ⌘⌥-click the second, plain-click the first, and drag across a link | Both URLs show as links: link colour and a faint underline, in the live grid and in finished agent blocks. ⌘-click opens the URL exactly as written, query included, in a new tab of this place's browser pane, which opens if none is there and comes forward with the keyboard. ⌘⌥ opens the system browser. A plain click does nothing to the link. A drag selects the text, ⌘C copies it, and what you type next still goes to the shell | ✓ 2026-10-27 |
| 6 | Wakil | In an editor pane, type `// https://example.com/p?a=1&b=two:three` and `// mailto:me@example.com`. ⌘-click the first, ⌘⌥-click the first, ⌘-click the mailto. Then click **Open on GitHub** on a line's blame, and ⌥-click it | The first link opens exactly as written (no `%3A`) in the browser pane, which comes forward with the keyboard. ⌘⌥ opens it in the system browser. The mailto goes to the Mail app, not the browser. Blame Open goes to the pane, which comes forward, and ⌥ to the system browser | ✓ 2026-10-27 |
| 7 | Wakil | In the browser, go to `github.com/yehia-khalil`, click into a repository, then ⌘T and type the repository's name | GitHub changes the address without loading a page, and the repository still shows up as a history row. Visiting `#section` on one page adds no row | ✓ 2026-10-27 |
| 8 | Wakil | ⌘, → **Browser**: check **Search suggestions**, then set it **On**. Back in a ⌘T tab, type `swift concurr`. Then set it back to **Off** | It starts at **Off**. With **On**, up to four 🔍 rows from the engine appear after the local ones (Kagi gives none). With **Off**, no 🔍 engine rows appear beyond the one typed search | ✓ 2026-10-27 |
| 9 | Wakil | ⌘⇧O → **B** (`orgb`), open a browser pane, ⌘T and type `gi`. Open ★. Then back to **A**: ⌘, → **Browser** → **Clear this organisation's browsing data…** → **Delete**, then ⌘T and type `gi` | In **B** there is no GitHub suggestion and no bookmark from **A**. The clear question reads `Delete personal's browsing data? Every site signs you out, in every project, and its history is deleted. Bookmarks stay.` After Delete, the history rows are gone (except pages the open tabs reload, a known gap). The ★ bookmarks stay | ✓ 2026-10-27 |
| 10 | Wakil | Go to `https://proof.ovh.net/files/10Mb.dat`. When it finishes, click the **×** at the strip's right end, just left of `resize` | While it runs the strip shows `10Mb.dat`, a bar filling as it goes, `Downloading · 3.2 of 10 MB` and **Cancel**. Finished, it reads `Downloaded · 10 MB to Downloads` with **Show in Finder**, and an × that `resize` does not cover. The × clears the finished download, and the strip goes away | ✓ 2026-10-27 |

## 2. Known and not fixed

- Clearing browsing data then reloading the open tabs writes those pages back into history (M-b).
- A fragment change followed by a title change drops the new title from history.
- The history read is capped at 200 rows before ranking.
- Keys sent with no gap at all (a script, not a person) can land after the completion instead of
  over it (`youtube.comoutube.com`). At 30 ms a key or slower, the completion is typed over as it
  should be.
- Long plain terminal output may draw more slowly, since every row is scanned for links (M-d). Try
  `seq 1 200000` in an agent block and see whether it feels slower than on main.

## 3. The machine walk

Not run before merge: the operator merged on the walk. The night run (`make e2e-full` on main) covers it.
