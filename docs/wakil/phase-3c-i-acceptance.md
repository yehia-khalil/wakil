# 3c-i — the browser: acceptance

**Spec:** [`2026-10-25-3c-browser-design.md`](../superpowers/specs/2026-10-25-3c-browser-design.md)
· **Plan:** [`2026-10-25-3c-i-browser.md`](../superpowers/plans/2026-10-25-3c-i-browser.md)
· **Charter:** Decision 48, Invariants 2 and 4, design language §11 (Browser)

The exit criterion, from the spec: a browser pane opens WebKit tabs in the canvas, with an address
field, navigation, find, zoom, downloads and the page's own prompts answered in place; each
organisation has its own profile, so a site signed in under one is signed out under another; the
tabs and their back/forward history survive a relaunch; Settings → Browser sets the search engine
and start page and clears the organisation's browsing data after asking; everything around the page
is a `browser_*` action the agent can also dispatch, and nothing inside the page is.

Nothing here is walked yet: the Walked column is empty until the operator ticks it.

## 0. Setup

Run this in the worktree root, on this Mac. It is safe to re-run.

```bash
make build && make app-bundle
./bin/wakil org list
```

The walk needs two organisations: **A** is `personal`, **B** any other the list prints (⌘⇧O creates
one if there is only one). Launch from the worktree root with
`WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`. Rows 1–3 need a GitHub account you can
sign in to; row 8 needs a camera.

## 1. The walk

Each row is one thing to do. **Wakil** rows happen in the app; **Terminal** rows run in any folder on
this Mac. Do them in order: each starts where the one before left off.

| # | Where | Do | Expect | Walked |
|---|---|---|---|---|
| 1 | Wakil | ⌘K → **New Browser pane**. Type `github.com`, Return. Click **Sign in**, then ⌘[ and ⌘] | The pane opens with one blank tab and the address field focused. `https://github.com/` loads: the strip's tab shows GitHub's title and favicon, the address row the whole URL with a padlock, the footer `GITHUB.COM · TLS`. ⌘[ goes back to the home page and ⌘] forward to the sign-in page, ‹ and › greying at each end | |
| 2 | Wakil | ⌘T, type `example.com`, Return. ⌘W, then ⌘⇧T. ⌘1, then ⌘9 | ⌘T opens a tab with the address field focused. ⌘W closes it and the GitHub tab is shown; ⌘⇧T brings `example.com` back with its page, not a blank tab. ⌘1 selects the first tab, ⌘9 the last | |
| 3 | Wakil | On the GitHub tab, sign in to GitHub. ⌘⇧O → switch to **B**, open a browser pane there and go to `github.com`. ⌘⇧O → back to **A** | In **A** you are signed in. In **B** GitHub shows **Sign in**: no cookie crossed. Back in **A**, the pane and its tabs are where you left them and you are still signed in, with no reload | |
| 4 | Wakil | Quit Wakil (⌘Q) and launch it again as in §0. Select the GitHub tab, press ‹ | Both tabs come back in their order, the selected one loaded, the other loading only when selected. ‹ goes back through the pages visited before the quit | |
| 5 | Wakil | Go to `vercel.com/login` → **Continue with GitHub** (or any site whose GitHub sign-in opens a pop-up) and authorise | The pop-up opens as a new tab in the same pane, already signed in to GitHub from row 3; when GitHub finishes, that tab closes itself and the first tab is signed in to the site | |
| 6 | Wakil | On `github.com`, ⌘F, type `the`, ⌘G, ⌘⇧G, Escape. ⌘+ twice; then open `example.com` in the other tab; back to GitHub | The find bar shows `1 of N` and moves through the matches, highlighted in the page; Escape closes it and the page has the keyboard. ⌘+ zooms GitHub to 125%; `example.com` stays at 100%; GitHub is still 125% when you come back, and after a relaunch | |
| 7 | Wakil, then Terminal | Go to `https://proof.ovh.net/files/1Gb.dat`. When the strip shows it, press its **Cancel**. Then `ls -l ~/Downloads/1Gb.dat*` | A download strip appears under the page: `1Gb.dat`, a size line counting up (`… of … MB` or `GB`) and **Cancel**. Cancel stops it and the row says so; Terminal shows no finished `1Gb.dat` | |
| 8 | Wakil | Go to `https://webrtc.github.io/samples/src/content/getusermedia/gum/` → **Open camera**. Press **Don't Allow**; reload and **Open camera** again → **Allow** | In the pane, over the page: `webrtc.github.io wants to use your camera` with **Allow** and **Don't Allow** (macOS asks once first, naming Wakil). Don't Allow: the page reports an error. Allow: the camera shows in the page | |
| 9 | Wakil | Right-click on the GitHub page → **Inspect Element** | Web Inspector opens, docked to the page, showing the element you right-clicked. Close it and the page keeps the keyboard | |
| 10 | Wakil | In **A**: ⌘, → **Browser** → **Clear this organisation's browsing data…** → **Keep it**; again → **Delete**. Back on the GitHub tab, ⌘R | The question names **A**: `Delete <A>'s browsing data? Every site signs you out, in every project.` with **Keep it** and **Delete**; Keep it changes nothing. After Delete GitHub shows **Sign in**, and GitHub's zoom is back to 100%. ⌘⇧O to **B** and back: nothing in **B** changed | |

## 2. Known and not fixed

- History, bookmarks, ⌘D and suggestions in the address field are 3c-iii; a link in the terminal
  or the editor still opens in the system browser.
- The agent reads the pane (tabs, URL, title) and dispatches its actions; it cannot read or act
  inside the page until 3c-ii.
- Tabs cannot be dragged to reorder; `browser_move_tab` (the agent's) is the only way.
- A favicon shows only when the page names a `data:` icon; every other tab shows the globe
  (no network fetch, Invariant 4).
- A load that times out (rather than being refused) shows its error only after WebKit's own
  timeout, a minute or more.

## 3. Residue: what the walk cannot establish

What no check reaches and no row above walks — try them at will:

- An HTTP sign-in prompt (basic auth): `Sign in to <host>`, answered for the session only.
- A page's file chooser (an `<input type=file>`), which opens the system panel.
- An untrusted certificate (`<host>'s certificate isn't trusted — <reason>` with **Visit Anyway**),
  e.g. `https://self-signed.badssl.com/`.
- A crashed page (`This page stopped.` with **Reload**): WebKit gives no way to crash one on purpose.
- Clicks and typing inside a page: the page is the operator's (Decision 48), and the harness
  drives only Wakil's own controls.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->
<!-- /machine-walk -->
