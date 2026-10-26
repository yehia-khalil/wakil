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
| 2 | Wakil | ⌘T, type `example.com`, Return. ⌘W, then ⌘⇧T. ⌘1, then ⌘9. Drag the second tab onto the first | ⌘T opens a tab with the address field focused. ⌘W closes it and the GitHub tab is shown; ⌘⇧T brings `example.com` back with its page, not a blank tab. ⌘1 selects the first tab, ⌘9 the last. The drag shows a line where the tab will land and moves it there; the order stays | |
| 3 | Wakil | On the GitHub tab, sign in to GitHub. ⌘⇧O → switch to **B**, open a browser pane there and go to `github.com`. ⌘⇧O → back to **A** | In **A** you are signed in. In **B** GitHub shows **Sign in**: no cookie crossed. Back in **A**, the pane and its tabs are where you left them and you are still signed in, with no reload | |
| 4 | Wakil | Scroll the GitHub page halfway down. Quit Wakil (⌘Q) and launch it again as in §0. Before anything else, ⌘K → **New Terminal** (this starts a conversation). Select the GitHub tab, press ‹. Then ⌘T, close the browser pane, and open a new one from ⌘K | Both tabs come back in their order, the selected one loaded, the other loading only when selected. Opening the terminal reloads no page: the GitHub tab is still scrolled halfway. ‹ goes back through the pages visited before the quit. The new browser pane opens on a blank tab, never on a page from the pane you closed | |
| 5 | Wakil | Go to `vercel.com/login` → **Continue with GitHub** (or any site whose GitHub sign-in opens a pop-up) and authorise | The pop-up opens as a new tab in the same pane, already signed in to GitHub from row 3; when GitHub finishes, that tab closes itself and the first tab is signed in to the site | |
| 6 | Wakil | On `github.com`, ⌘F, type `the`, ⌘G, ⌘⇧G, Escape. ⌘+ twice; then open `example.com` in the other tab; back to GitHub. Then open a file of a project whose `origin` is on github.com in an editor pane, rest the pointer on the cursor line's blame and click **Open on GitHub**; ⌥-click it; then rest on a line you committed and have not pushed | The find bar shows `1 of N` and moves through the matches, highlighted in the page; Escape closes it and the page has the keyboard. ⌘+ zooms GitHub to 125%; `example.com` stays at 100%; GitHub is still 125% when you come back, and after a relaunch. The blame hover reads `Open Changes · Copy Commit ID · Open on GitHub`; the click opens the commit's page on github.com as a new tab in this browser pane, and the editor keeps the keyboard; ⌥-click opens it in the system browser instead. The unpushed line's hover has no Open on GitHub | |
| 7 | Wakil, then Terminal | Go to `https://proof.ovh.net/files/1Gb.dat`. When the strip shows it, press its **Cancel**. Then `ls -l ~/Downloads/1Gb.dat*` | A download strip appears under the page: `1Gb.dat`, a size line counting up (`… of … MB` or `GB`) and **Cancel**. Cancel stops it and the row says so; Terminal shows no finished `1Gb.dat` | |
| 8 | Wakil | Go to `https://webrtc.github.io/samples/src/content/getusermedia/gum/` → **Open camera**. Press **Don't Allow**; reload and **Open camera** again → **Allow** | In the pane, over the page: `webrtc.github.io wants to use your camera` with **Allow** and **Don't Allow** (macOS asks once first, naming Wakil). Don't Allow: the page reports an error. Allow: the camera shows in the page | |
| 9 | Wakil | Right-click on the GitHub page → **Inspect Element**. Close it, then ⌘K → **Print page** → **Cancel**. Go to `https://zoom.us/test` → **Launch Meeting** (or any page with a `mailto:` link, clicked) → **Cancel**; click it again → **Open** | Web Inspector opens, docked to the page, showing the element you right-clicked; closed, the page keeps the keyboard. Print page shows the system's print panel with the page in its preview. The link asks over the page, `Open in <app>?` with **Open** and **Cancel**: Cancel opens nothing; Open opens the app | |
| 10 | Wakil, then Terminal | In **A**: ⌘, → **Browser** → **Clear this organisation's browsing data…** → **Keep it**; again → **Delete**. Back on the GitHub tab, ⌘R. Then in Terminal, `./bin/wakil org create walk-rm`, in Wakil ⌘⇧O → **walk-rm**, open a browser pane, quit Wakil, and run `./bin/wakil org rm walk-rm` in the worktree root | The question names **A**: `Delete <A>'s browsing data? Every site signs you out, in every project.` with **Keep it** and **Delete**; Keep it changes nothing. After Delete GitHub shows **Sign in**, and GitHub's zoom is back to 100%. ⌘⇧O to **B** and back: nothing in **B** changed. `org rm` prints `removed org "walk-rm"` and a second line naming WebKit's store, its id and Settings → Browser | |

## 2. Known and not fixed

- History, bookmarks, ⌘D and suggestions in the address field are 3c-iii; a link in the terminal
  or the editor still opens in the system browser. The blame hover's Open on GitHub (GitLab,
  Bitbucket) is the one link that opens in the pane already, by the path 3c-iii will route those
  through (`WindowModel.openLinkInWakil`).
- The agent reads the pane (tabs, URL, title) and dispatches its actions; it cannot read or act
  inside the page until 3c-ii.
- A favicon shows only when the page names a `data:` icon; every other tab shows the globe
  (no network fetch, Invariant 4).
- A load that times out (rather than being refused) shows its error only after WebKit's own
  timeout, a minute or more.
- **A page's `beforeunload` question is not shown**: leaving a page with an unsent form leaves it
  without asking. `WKWebView` has no public hook for it — `WKUIDelegate` offers alert, confirm and
  prompt only; the before-unload panel exists only in the legacy `WebView` and WebKit's private API,
  which Wakil does not use. The spec's Interaction rule 1 is not met here until WebKit offers one.
- `wakil org rm` cannot delete the organisation's WebKit store (only the app can, by its id, and the
  id goes with the folder): it names the store it leaves and says to clear it in Settings → Browser
  first.
- The pages' own question in a pane you are not in waits shown, without the keyboard: click it (or
  move to its pane) to answer it from the keys.

## 3. Residue: what the walk cannot establish

What no check reaches and no row above walks — try them at will:

- An HTTP sign-in prompt (basic auth): `Sign in to <host>`, answered for the session only.
- A page's file chooser (an `<input type=file>`), which opens the system panel.
- An untrusted certificate (`<host>'s certificate isn't trusted — <reason>` with **Visit Anyway**),
  e.g. `https://self-signed.badssl.com/`.
- A crashed page (`This page stopped.` with **Reload**): WebKit gives no way to crash one on purpose.
- A download that fails (unplug the network mid-download): its row shows the whole reason, which
  wraps and can be selected and copied.
- A link to an app the Mac has no app for (`foo-nothing:x`): the tab says `No app on this Mac opens
  foo-nothing: links.` with **OK**.
- Clicks and typing inside a page: the page is the operator's (Decision 48), and the harness
  drives only Wakil's own controls.

## 4. The machine walk

<!-- machine-walk: generated by `make e2e-runbook`; everything between these markers is overwritten -->

**The machine walk is green for the checks this branch reaches:** the 35 `make e2e` selected ran green against this build, every check this branch added was seen to fail against the merge-base, and the surface it added carries checks. **223 check(s) are owed to `make e2e-full`**, which runs once, on the head that merges.

Changed files no check maps to, which only the full run covers:

- `app/Sources/WakilApp/AppScene.swift`
- `app/Sources/WakilApp/Canvas.swift`
- `app/Sources/WakilApp/EditorPane.swift`
- `app/Sources/WakilApp/Landing.swift`
- `app/Sources/WakilApp/Rail.swift`
- `app/Sources/WakilApp/SettingsPane.swift`
- `app/Sources/WakilApp/WakilWindow.swift`
- `app/Sources/WakilApp/WindowSession.swift`
- `app/Sources/WakilKit/App/PaneKinds.swift`
- `app/Sources/WakilKit/Browser/BrowserAddress.swift`
- `app/Sources/WakilKit/Browser/BrowserDownloadNames.swift`
- `app/Sources/WakilKit/Browser/BrowserFocusRetry.swift`
- `app/Sources/WakilKit/Browser/BrowserOrgFiles.swift`
- `app/Sources/WakilKit/Browser/BrowserSnapshot.swift`
- `app/Sources/WakilKit/Browser/PaneStore+Browser.swift`
- `app/Sources/WakilKit/Command/PaletteSources.swift`
- `app/Sources/WakilKit/Layout/LayoutActions.swift`
- `app/Sources/WakilKit/Layout/LayoutStore.swift`
- `app/Sources/WakilKit/Layout/Pane.swift`
- `app/Sources/WakilKit/MCP/MCPServer.swift`
- `app/Sources/WakilKit/Panes/SettingsTree.swift`
- `cmd/wakil-ctx/main.go`
- `e2e/checks/uncoverable.tsv`
- `e2e/driver/expand.go`
- `e2e/driver/identifiers.go`
- `e2e/driver/pagestub.go`
- `e2e/driver/run.go`
- `e2e/driver/session.go`
- `e2e/fixtures/pages/a.html`
- `e2e/fixtures/pages/alert.html`
- `e2e/fixtures/pages/b.html`
- `e2e/fixtures/pages/find.html`
- `e2e/fixtures/pages/keys.html`
- `e2e/fixtures/pages/popup.html`
- `e2e/fixtures/pages/prompt.html`
- `internal/wakilcore/browsersettings.go`
- `internal/wakilcore/configtree.go`
- `internal/wakilcore/editorsettings.go`
- `scripts/make-app-bundle.sh`

Walked by `make e2e` against e494634013fd, rendered 2026-10-25 22:34 UTC by `make e2e-runbook`. Re-render it with that target; edits between the markers are overwritten.

**The tree carried uncommitted changes**, so these checks ran against that tree rather than against the commit named above.

| Check | `make e2e` | Red against the base | Assertions | Evidence |
|---|---|---|---|---|
| `org-plane.jsonl` | ✓ exit 0 | not new on this branch | 3 | — |
| `2c-iii-1-bundle-path.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-2-block.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-3-live-prompt.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-4-interrupt.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-5-full-screen.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-6-no-orphan.jsonl` | owed to `make e2e-full` | — | — | — |
| `2c-iii-7-org-switch.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-composer-keeps-input.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-composer-return-sends.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-settings-speech.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-escape.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-lands-focused.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-lands-unsent.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-second-hold.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-silence.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-ii-environment-lifecycle.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-ii-git-name-leave-by-tree.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-ii-name-refusals.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-ii-project-lifecycle.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-ii-rename-active-environment.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-iii-api-entries.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-iii-database-edit.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-iv-database-edit.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-databases-dispatch.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-databases.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-doors.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-narrow-rows.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-organisation.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-pane.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-unlink-indicator.jsonl` | owed to `make e2e-full` | — | — | — |
| `2e-settings-unlink.jsonl` | owed to `make e2e-full` | — | — | — |
| `365-terminal-option-word.jsonl` | owed to `make e2e-full` | — | — | — |
| `365-terminal-paste.jsonl` | owed to `make e2e-full` | — | — | — |
| `365-terminal-select-backspace.jsonl` | owed to `make e2e-full` | — | — | — |
| `365-terminal-select-type.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-b-draft.jsonl` | ✓ exit 0 | ✓ red vs 91f64b7b89da, recorded 2026-10-22 | 19 | — |
| `3a-ii-b-message-box-wraps.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-b-ranges.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-commit-all.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-commit.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-discard.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-hook-fails.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-identity.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-message-box.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-settings-tree-collapse.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-stage-change.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-ii-undo.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-add-project-clone.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-git-account-actions.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-git-account-parity.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-git-accounts.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-git-author.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-instructions-boxes.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-remote-button.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-remote-conflict.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-remote-fetch-pull.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-remote-publish-push.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-remote-sync.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-settings-maximized.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-branch-blocked.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-branch-menu.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-branch-picker-arrows.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-branch-picker.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-branch-segment-first-git-root.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-stash-by-id.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-stash-menu.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-stash-rows.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iv-switch-branch-palette.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-a-inline-blame-setting.jsonl` | ✓ exit 0 | ✓ red vs c31d96c4ac7b, recorded 2026-10-23 | 6 | — |
| `3a-v-a-timeline-rename.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-a-timeline-toggle.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-a-timeline.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-b-conflict-reveal.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-b-merge.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-b-rebase.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-v-b-stash-clash.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-close-keys.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-disk-changed.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-files-palette.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-read-only.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-refusals.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-save-as-field.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-save-as-replace.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-scratch-save.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-tabs-language.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-unsaved-org-switch.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-unsaved-quit.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-i-editor-unsaved-save.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-replace-all.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-replace-cancel.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-replace-file.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-replace-undo.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-reveal.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-b-tab-move.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-find.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-palette-ignored.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-refusals.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-search-cancel.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-search-errors.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-search.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-tree-ignored-heavy.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-tree-live.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-tree-preview.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ii-tree-toggle.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-drill.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-keys.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-list.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-live.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-press.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-diff-open-file.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-diff-refusals.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-git-pane-migrates.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-palette-changed-file.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-peek.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-tree-letters.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-create-file.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-create-folder.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-name-refused.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-rename-tabs.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-trash-key.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-trash-selection.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-trash-tabs.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iv-tree-pinned-click.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-ix-fast-path-ask-agent.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 8 | — |
| `3b-ix-fast-path-names-database.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 8 | — |
| `3b-ix-fast-path-open-file.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 10 | — |
| `3b-ix-fast-path-refused.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 8 | — |
| `3b-ix-fast-path-runs.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 14 | — |
| `3b-ix-fast-path-switch.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 10 | — |
| `3b-ix-fast-path-to-agent.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 8 | — |
| `3b-ix-quick-tasks-about.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-click-focuses-pane.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-autosave-focus.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-autosave-pause.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-autosave-prompt-guard.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-indent-scratch.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-live-options.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-editor-settings-nodes.jsonl` | ✓ exit 0 | ✓ red vs b2dd35bfad70, recorded 2026-10-21 | 29 | — |
| `3b-v-heavy-folders-edit.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-v-heavy-folders-refusal.jsonl` | ✓ exit 0 | ✓ red vs b2dd35bfad70, recorded 2026-10-21 | 24 | — |
| `3b-v-heavy-folders.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 41 | — |
| `3b-v-project-editor-settings.jsonl` | ✓ exit 0 | ✓ red vs b2dd35bfad70, recorded 2026-10-21 | 20 | — |
| `3b-v-show-ignored.jsonl` | ✓ exit 0 | **proved red vs 5c38f72852bf on an earlier version — not re-proved** | 27 | — |
| `3b-vii-log-follow.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-vii-log-tail.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-ghost-text-setting.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-ghost-unreachable-editor.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-ghost-unreachable-query-line.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-local-provider-add-focused.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-local-provider-add.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-local-provider-dispatch.jsonl` | ✓ exit 0 | ✓ red vs 2a491bfe7b06, recorded 2026-10-21 | 25 | — |
| `3b-viii-local-provider-remove.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-viii-quick-provider-unlinked.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 8 | — |
| `3b-viii-quick-provider.jsonl` | ✓ exit 0 | ✓ red vs 8ebeb01dfcd2, recorded 2026-10-20 | 13 | — |
| `3c-i-agent-drives.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 43 | — |
| `3c-i-alert.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 16 | — |
| `3c-i-download.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 16 | — |
| `3c-i-editor-keys-unchanged.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 10 | — |
| `3c-i-find.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 19 | — |
| `3c-i-keys-reach-wakil.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 19 | — |
| `3c-i-load-error.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 8 | — |
| `3c-i-narrow.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 31 | — |
| `3c-i-new-tab-entry.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 5 | — |
| `3c-i-open-and-navigate.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 20 | — |
| `3c-i-prompt.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 11 | — |
| `3c-i-settings.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 19 | — |
| `3c-i-stop.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 9 | — |
| `3c-i-tabs.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 24 | — |
| `3c-i-zoom.jsonl` | ✓ exit 0 | ✓ red vs 8f7c616ab831 | 13 | — |
| `agent-pane-is-drawn.jsonl` | ✓ exit 0 | not new on this branch | 4 | — |
| `api-bind.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-body-editor.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-body-hole-cursor.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-bound-locks.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-cancel.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-chip-keys-second-chip.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-chip-keys-text-after.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-chip-keys.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-editor-copy-bound.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-editor-json-holes.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-editor-wrap.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-env-roundtrip.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-hole.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-one-author-focus.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-open.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-paste-curl-hotkey.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-paste-curl-refused.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-paste-curl-www.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-paste-curl.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-query-sync.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-recent-root.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-recent-shared.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-recent.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-reopen-cross-entry.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-rows.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-saved-as-typed.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-send-what-it-shows.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-send.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-set-request.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-surface.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-the-rest.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-type-keeps-holes.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-unbind.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-env-switch-own-canvas.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-org-switch-asks-nothing.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-org-switch-keeps-the-terminal.jsonl` | owed to `make e2e-full` | — | — | — |
| `capacity-low-reading.jsonl` | owed to `make e2e-full` | — | — | — |
| `capacity-passed-reset.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-cancel-click.jsonl` | ✓ exit 0 | **proved red vs e6c782b4f52f on an earlier version — not re-proved** | 23 | — |
| `db-cancel-escape.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-detail-big-cells.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-detail-strip.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-grid-copy.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-agent-replaces.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-format.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-long.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-not-formatted.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-return.jsonl` | owed to `make e2e-full` | — | — | — |
| `db-query-line-run.jsonl` | owed to `make e2e-full` | — | — | — |
| `dispatched-terminal-shell.jsonl` | owed to `make e2e-full` | — | — | — |
| `journal-error-reason.jsonl` | owed to `make e2e-full` | — | — | — |
| `landing.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-api-entry.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-api-send.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-command-step.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-escape.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-modes.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-open-kinds.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-run-error.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-switch-environment.jsonl` | owed to `make e2e-full` | — | — | — |
| `palette-table-row.jsonl` | owed to `make e2e-full` | — | — | — |
| `project-root-note.jsonl` | owed to `make e2e-full` | — | — | — |
| `vocabulary.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-code-hint.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-failed-source.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-hint-or-plain.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-over-limit.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-pane-hint.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-i-schema-hint.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-thread-earlier.jsonl` | owed to `make e2e-full` | — | — | — |
| `2d-ii-voice-turn.jsonl` | owed to `make e2e-full` | — | — | — |
| `3a-iii-instructions-reach-agent.jsonl` | owed to `make e2e-full` | — | — | — |
| `3b-iii-changes-voice-hint.jsonl` | owed to `make e2e-full` | — | — | — |
| `api-origin-after-account-switch.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-agent-chip-more.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-agent-chip-narrow.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-agent-chip-over-landing.jsonl` | owed to `make e2e-full` | — | — | — |
| `bg-agent-chip-return.jsonl` | owed to `make e2e-full` | — | — | — |
| `both-surfaces.jsonl` | owed to `make e2e-full` | — | — | — |
| `capacity-after-turn.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-background-chip.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-close-asks.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-close-idle.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-new-shows-running.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-palette-switch.jsonl` | owed to `make e2e-full` | — | — | — |
| `conversations-parity.jsonl` | owed to `make e2e-full` | — | — | — |
| `two-enter.jsonl` | owed to `make e2e-full` | — | — | — |
| `.scratch/3c-i/red.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3c-i-zz-capture.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/3c-i-zz-tmp.jsonl` | — | — | — | a record for a check the corpus no longer holds |
| `e2e/checks/seeded/zz-capture-browser.jsonl` | — | — | — | a record for a check the corpus no longer holds |

**`make e2e-new` saw every check this branch added go red against 8f7c616ab831.**

**Every action and control this branch added carries a check.** 22 action(s) and 54 control(s) are new on this branch.

- actions:  155 of 202 dispatched by a check
- writes:   55 of 165 carry a parity check
- controls: 278 of 463 exercised by a check

**241 piece(s) of surface no check can reach**, each with the reason given in `e2e/checks/uncoverable.tsv`:

- `api_undo_fill` — its parity: the Undo click forgets the fill it undoes, and api_undo_fill refuses a pane with nothing to undo, so the dispatch half cannot be given the same state after the click — and a second fill between the halves is not expressible inside one parity step. Both channels ARE covered by api-paste-curl.jsonl, the click after one fill and the dispatch after another, each asserting the same restored draft through read_pane; what no check can express is the comparison.
- `editor_peek` — its parity (3b-iii): the operator's channel is a click on a change mark in Monaco's gutter, inside the WKWebView — a web element with no accessibility identifier, which the resolver cannot address (editor_goto's case: inside Monaco, the one non-action path). The dispatch is covered by 3b-iii-peek.jsonl (opened on a mark, refused on an unmarked line, on an untracked file and on a diff tab in 3b-iii-diff-refusals.jsonl); the mark click is the runbook's row 8.
- `ctx_set_project_agent_instructions` — its parity (3a-iii): the operator's channel is typing in a project's Agent instructions box and leaving it (or a second's pause) — typing and a leave, not one click or drag, ctx_rename_project's case. Both channels ARE covered: the boxes by 3a-iii-instructions-boxes.jsonl and agent/3a-iii-instructions-reach-agent.jsonl, the dispatch by 3a-iii-instructions-boxes.jsonl, each asserting projects[1].agent through read_pane; what no check can express is the comparison.
- `ctx_remove_project` — its parity (2e-ii): the click removes the project, and removing one that is gone is refused, so the dispatch half cannot be given the same params (db_remove_database's case). Both channels ARE covered by 2e-ii-project-lifecycle.jsonl: settings.project.remove then .confirm (the node gone, the receipt read; .keep first leaves it) and the dispatch on the project added back and renamed (the node gone).
- `editor_restore` — its parity (3b-i): no operator control — it runs when a window relaunches onto saved tabs, and one check is one launch. The dispatch is covered by 3b-i-editor-disk-changed.jsonl (an open, dirty tab is kept as it is); restoring after a relaunch is the runbook's row 9.
- `ctx_git_device_start` — its parity (3a-iii): Sign in has no control in this build — it is hidden until Wakil's OAuth apps have client ids (operator-todo.md), and a device flow needs a provider on the network either way, so no UI half exists. The dispatch is covered by 3a-iii-git-account-actions.jsonl, refused without a client id (`Sign in is not set up for github in this build; use an SSH key or a token`), which reaches no network; Sign in is walk-only.
- `editor_changes_stash_drop` — its dispatch and its parity (3a-iv, Decision 46): priced gate for the agent, so a dispatch parks (`drop stash <id7> in <root>`) and holds its step open until the operator answers — editor_changes_branch_delete's case. The pane's channel IS covered: 3a-iv-stash-rows.jsonl presses a row's Drop, Keep it, then Drop, and asserts the row gone and `git stash list` one shorter.
- `browser_clear_data` — its dispatch and its parity (3c-i, Decision 48): priced gate in every environment, so a dispatch parks for the operator's confirmation and holds its step open until someone answers — editor_changes_branch_delete's case. The operator's channel IS covered: 3c-i-settings.jsonl asks, keeps, asks again, deletes and reads `Deleted E2E Fixture's browsing data.` and the journal; the refusal for another organisation is WakilKit's (clearDataRefusesWhenTheOrganisationTheQuestionNamedIsNotActive).
- `db_cancel` — its parity: the click (or Esc) cancels the read in flight, and db_cancel refuses a pane with nothing running (`nothing is running on pane …`), so the dispatch half cannot be given the same state — and a second slow read between the halves is not expressible inside one parity step, api_cancel's case. Both channels ARE covered: db-cancel-click.jsonl cancels one recursive-CTE read by db.<pane>.cancel and the next by dispatch, asserting the same state after each through read_pane (running false, cancelledAfterMs, the previous 2 rows kept, sort empty) and "cancelled after" in the tree; db-cancel-escape.jsonl cancels by Esc. What no check can express is the comparison.
- `editor_goto` — its parity (3b-i): there is no operator control for it — the operator moves the cursor inside Monaco, the one non-action path (design-language §11), so no UI half exists to compare. The dispatch is covered by 3b-i-editor-tabs-language.jsonl (cursor.line and cursor.column through read_pane) and refused on an empty pane in 3b-i-editor-refusals.jsonl.
- `editor_select` — its parity (3b-i): no operator control — the operator selects inside Monaco, the one non-action path, so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, which read selected_text back to prove what a save wrote.
- `editor_move_tab` — its parity (3b-ii-b): the drag moves a tab, and the same {from, to} dispatched on the moved strip moves a different tab, so the two halves cannot read back the same order. The drag and the dispatch are each 3b-ii-b-tab-move.jsonl's, each asserting the strip's order and the active tab through read_pane.
- `editor_changes_commit` — its parity (3a-ii): the click commits what is there, and the same dispatch after it finds nothing to commit and is refused by git, so the two halves cannot read back the same state (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the Commit button by 3a-ii-commit-all.jsonl and 3a-ii-identity.jsonl, ⌘⏎ in the box by 3a-ii-commit.jsonl and 3a-ii-undo.jsonl, and the dispatch by 3a-ii-commit-all.jsonl and 3a-ii-undo.jsonl, each asserting the root's rows gone or `· clean` in the tree, the message in the journal, and (3a-ii-commit, 3a-ii-identity) `git log` in a terminal; what no check can express is the comparison.
- `editor_changes_stash` — its parity (3a-iv): the click (the in-place field's Stash, or Return in it) stashes the root's changes, and the same dispatch after it finds nothing to stash and is refused (`No local changes to stash`), so the two halves cannot read back the same state — editor_changes_commit's case. Both channels ARE covered: ▾ → Stash → Stash, Stash Including Untracked and Stash Staged by 3a-iv-stash-menu.jsonl (the rows gone from the tree, `git stash list` and the stash's untracked parent read in a terminal), the dispatch in each mode there and by 3a-iv-stash-by-id.jsonl, and the refusal; what no check can express is the comparison.
- `ctx_remove_environment` — its parity (2e-ii): the click removes the environment, and removing one that is gone is refused, so the dispatch half cannot be given the same params (db_remove_database's case). Both channels ARE covered by 2e-ii-environment-lifecycle.jsonl: settings.environment.remove then .confirm (the node gone, the Trash receipt read; .keep first leaves it) and the dispatch on an environment made and renamed by dispatch (the node gone).
- `browser_restore` — its parity (3c-i): no operator control — the window runs it when it reopens a saved layout, and one check is one launch (editor_restore's case). The dispatch is 3c-i-agent-drives.jsonl's (the saved tabs and their ids kept); a relaunch is the runbook's row 4.
- `editor_changes_keep_file` — its parity (3a-v-b): the operator's channel is Keep File in a delete/modify row's context menu, and no arm opens a context menu (editor_rename's case), so no UI half of one click exists. The dispatch is covered by 3a-v-b-merge.jsonl: `gone, deleted by them` leaves Merge Changes, the reason drops to `Resolve 1 conflict first`, and after the merge `gone` still reads `old, mine`. The menu is the runbook's row 10's file and walk-only.
- `editor_replace_range` — its parity (3b-i): no operator control — the operator's own edits are typing in Monaco, the one non-action path (`editorBufferDidChange`), so no UI half exists. The dispatch is covered by most 3b-i-editor-* checks, and its read-only refusal by 3b-i-editor-read-only.jsonl.
- `editor_changes_stash_undo_apply` — its dispatch and its parity (3a-v-b, call 13): priced gate for the agent, and gated before it is refused, so even a dispatch with no clash parks and holds its step open until the operator answers — editor_changes_branch_delete's case. The pane's channel IS covered: 3a-iv-branch-blocked.jsonl presses Undo Apply and Undo after Bring Them Along (`· clean`, `theirs`, the stash kept); 3a-v-b-stash-clash.jsonl presses Keep it and then Undo over an edited file (`index.txt changed since the clash; Undo Apply would lose that — resolve it by hand`, the edit and the stash kept).
- `browser_reopen_tab` — its parity (3c-i): the operator's channels are ⌘⇧T and the Reopen Closed Tab menu item — a key and a menu, not a click or a drag — and each reopen consumes the closed stack, so the halves could not agree anyway. ⌘⇧T is 3c-i-tabs.jsonl's; the dispatch is 3c-i-agent-drives.jsonl's (t3, b.html).
- `editor_create` — its parity (3b-iv): the operator's channel is the root's + menu (New File / New Folder), a name typed into the field and Enter or a click away — a menu, typing and a key, not one click or drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the + by 3b-iv-create-file.jsonl and 3b-iv-create-folder.jsonl (a pinned tab with the cursor in it, a/b and a/b/c selected, a click away committing), the dispatch by the same two (a file opened pinned, a folder shown) and its refusals (an existing name, outside the roots, a bad kind); what no check can express is the comparison.
- `editor_changes_undo_commit` — its parity (3a-ii): the click undoes the last commit, and the same dispatch after it undoes the one before, or is refused on the root commit (`nothing to undo: this is the first commit`), so the two halves cannot read back the same state — api_undo_fill's case. Both channels ARE covered by 3a-ii-undo.jsonl: the ▾ menu's Undo Last Commit refills the box and puts the change back under Staged, and the dispatch after it is that refusal; what no check can express is the comparison.
- `ctx_rename_project` — its parity (2e-ii): the operator's channel is typing in settings.project.name and leaving it — typing and a leave, not one click or drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered by 2e-ii-project-lifecycle.jsonl, the field (left by a tree click) and the dispatch, each asserting the renamed node in the tree and the old one gone; its refusals by 2e-ii-name-refusals.jsonl. What no check can express is the comparison.
- `browser_close_tab` — its parity (3c-i): the click consumes its own subject — the dispatch after it closes another tab or is refused (`the browser pane has no tab …`), editor_close's case — and the tab's × is drawn only under the pointer (browser.tab.<…>.close). ⌘W is 3c-i-tabs.jsonl's; the dispatch is 3c-i-agent-drives.jsonl's.
- `browser_reload` — its parity (3c-i): every reload is another load, and the fixture pages are the same after each, so nothing read_pane or the tree carries differs before and after the click — the parity would refuse it as having changed nothing. The click is 3c-i-agent-drives.jsonl's (journal, title) and Try Again's 3c-i-load-error.jsonl's; the dispatch re-runs the page's own prompt in 3c-i-prompt.jsonl.
- `browser_find` — its parity (3c-i): the operator's channel is ⌘F and typing into the find field — keys, not a click or a drag. The keys are 3c-i-find.jsonl's (needle, 1 of 3); the dispatch is 3c-i-agent-drives.jsonl's, reading the query and count back.
- `editor_changes_step` — its parity (3b-iii): the operator's channel is ↑↓ in the Changes view — keys, not a click or a drag — and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case). Both channels ARE covered: the dispatch by 3b-iii-changes-drill.jsonl (across roots, both directions, clamped at the end, skipping a collapsed root, asserting the highlight and the diff tab through read_pane), the keys by 3b-iii-changes-keys.jsonl (↓ from nothing, ↑↓ across roots, after ⌘⇧G); what no check can express is the comparison.
- `editor_conflict_compare` — its parity (3a-v-b): the operator's channel is Compare Changes in the same in-page actions row, editor_conflict_accept's case. The dispatch is covered by 3a-v-b-merge.jsonl: a second tab with diff.conflict true and the title `doc (Current ↔ Incoming)`; the row's press is the runbook's row 3.
- `ctx_git_key_generate` — its parity (3a-iii): Generate key generates the key and records the account on it, and the same dispatch after it is refused (`a key for … already exists: Remove or Replace the account first`) — the click consumes its own subject. Both channels ARE covered: the sheet's Generate key by 3a-iii-git-accounts.jsonl (the public key shown, the account recorded as ssh, ~/.ssh untouched) and the dispatch by 3a-iii-git-account-actions.jsonl (the pair under the organisation's git/ssh folder, ~/.ssh untouched); what no check can express is the comparison.
- `db_remove_database` — its parity: the click removes the database, and removing one that is gone is refused (`no database … in environment …`), so the dispatch half cannot be given the same params. Dispatch is covered by 2e-settings-databases-dispatch.jsonl and the click by 2e-settings-databases.jsonl; what no check can express is the comparison.
- `ctx_git_device_poll` — its parity (3a-iii): the operator's channel is the sheet polling by itself while Sign in waits, which has no control in this build: Sign in is hidden until Wakil's OAuth apps have client ids (operator-todo.md), and a device flow needs a provider on the network either way. The dispatch is covered by 3a-iii-git-account-actions.jsonl, refused for an unknown provider (`no sign-in for e2e`), which reaches no network.
- `editor_peek_step` — its parity (3b-iii): the operator's channels are ↑↓ while the peek is open (keys Monaco hands back) and the peek's ↑ ↓ buttons, which are HTML inside the WKWebView with no accessibility identifier — neither is a click on a control the resolver can address. Both the dispatch and ↑↓ ARE covered by 3b-iii-peek.jsonl, each asserting peek.index and the cursor through read_pane; the buttons are walk-only (row 8 presses ↓, a key).
- `ctx_add_provider` — its parity: the click creates a binding under an id, so a dispatch with the same params collides with what the click just made. Covered by 2e-settings-doors.jsonl up to the browser leg.
- `ctx_provider_login` — #254. Opens a browser on the operator's machine and authenticates as them. No harness can drive it and none should: every run would leave a real credential behind.
- `api_reopen` — its dispatch: it needs a row id, which is minted per send and published only in read_pane — the same reason api_render_curl below is here. The operator's gesture IS covered: api-recent.jsonl presses api.recent.0.reopen and asserts the draft it rebuilds. Permanent, not blocked: nothing in the vocabulary carries a value from read_pane into a dispatch.
- `editor_changes_take` — its dispatch and its parity (3a-v-b, R1): priced gate for the agent, so a dispatch parks (`take the incoming <path> whole in <root>; edits made to it are lost`) and holds its step open until the operator answers — editor_changes_branch_delete's case. And the pane's channel is Accept All Current / Accept All Incoming / Delete File in a conflicted row's context menu, which no arm opens (editor_rename's case). So neither channel can be driven by a check; it is the runbook's rows 5 (the menu and its in-place confirm) and 10 (the agent's plane), and its Go half is pinned by gitresolve_test.go.
- `editor_changes_skip` — its dispatch and its parity (3a-v-b, Decision 46): priced gate for the agent, so a dispatch parks and holds its step open until the operator answers — editor_changes_branch_delete's case. The pane's channel IS covered by 3a-v-b-rebase.jsonl: ▾ → Skip Commit, `"rework 1"? Its changes are left out of the rebase.`, Keep it (still `rebasing 1/3`), then at step 3 Skip (`· clean`, `git log main..rework` reads `add readme|rework 1`).
- `browser_focus_address` — its parity (3c-i): what it changes is where the keyboard is — view focus, not pane state — and neither read_pane nor the tree text a parity compares carries it; focus is an expect, not a state read. ⌘L is 3c-i-keys-reach-wakil.jsonl's and the dispatch 3c-i-agent-drives.jsonl's, each followed by expect.focus browser.address.
- `editor_changes_stash_drop_all` — its dispatch and its parity (3a-iv, Decision 46): priced gate for the agent, so a dispatch parks (`drop N stashes in <root>`) and holds its step open until the operator answers — editor_changes_branch_delete's case. The pane's channel IS covered: 3a-iv-stash-rows.jsonl presses Drop All…, Keep it, then Drop, and asserts the list empty.
- `browser_download_cancel` — its parity (3c-i): before the click a running download's bytes change every tick, so the state a parity reads first never settles; and a dispatch after the click finds the download already ended and changes nothing (api_cancel's case). The click is 3c-i-download.jsonl's on d1, the dispatch the same check's on d2, each reading cancelled back; a real download's Cancel is the runbook's row 7.
- `editor_changes_unstage_ranges` — its parity (3a-ii-b): the click unstages the selected lines, and the same dispatch after it finds nothing staged there and is refused (`the selection holds no change`), so the two halves cannot read back the same state — editor_changes_commit's case. Both channels ARE covered by 3a-ii-b-ranges.jsonl: the header button (editor.diff.unstageRanges) unstages README.md's line and the dispatch unstages app.txt's added line while keeping its changed one staged, each asserted with `git diff` in a terminal; what no check can express is the comparison.
- `browser_find_step` — its parity (3c-i): each Next or Previous moves the match, so the dispatch after the click lands one further and the halves cannot read back the same count (editor_replace's case). The clicks and ⌘G are 3c-i-find.jsonl's; the dispatch, both ways and refused once the bar is closed, is 3c-i-agent-drives.jsonl's.
- `api_unbind` — its parity: the click returns the binding to its hole, and api_unbind refuses a position that holds no binding (`unbindNotABinding`), so the dispatch half cannot be given the same params — and a re-drag between the halves is not expressible. Both channels ARE covered by api-unbind.jsonl, each after its own drag, asserting the same hole back through read_pane; what no check can express is the comparison.
- `api_remove_entry` — its parity (2e-iii): the click removes the entry, and removing one that is gone is refused, so the dispatch half cannot be given the same params (db_remove_database's case). Both channels ARE covered by 2e-iii-api-entries.jsonl: settings.api.<name>.remove then .confirm (the entry gone; .keep first leaves it) and the dispatch on an entry added for it.
- `editor_peek_close` — its parity (3b-iii): the operator's channels are Esc in the peek (a key), typing (which closes it in the store), and the peek's × (HTML inside the WKWebView, no accessibility identifier). Esc, typing and the dispatch ARE each covered by 3b-iii-peek.jsonl, asserting peek null with the cursor and the marks kept; the × button is walk-only, in no runbook row.
- `ctx_create_environment` — its parity (2e-ii): a parity step compares the state each half leaves, and the two halves of this one cannot leave the same state — the tool picks the name, so whichever half runs second finds new-environment taken and creates a differently named environment, and the trees differ by construction (ctx_add_provider's case: the first half makes what the second collides with). Both channels ARE covered by 2e-ii-environment-lifecycle.jsonl: settings.tree.project.e2e-project.addEnvironment and the dispatch, each asserting environment.e2e-project.new-environment in the tree; what no check can express is the comparison.
- `editor_changes_stash_apply` — its parity (3a-iv): the click (a stash row's Apply) puts the stash's changes back, and the same {index, id} dispatched after it lands on a tree that already holds them, which git refuses or clashes on, so the two halves cannot read back the same state. The dispatch is covered by 3a-iv-stash-by-id.jsonl (the changes back, the stash kept, and the moved-list refusal `The stash list changed; look again`), ▾ → Stash → Apply Latest Stash by 3a-iv-stash-menu.jsonl; the row's Apply by 3a-iv-stash-rows.jsonl (on a clean tree: the changes back, the stash kept).
- `ctx_rename_environment` — its parity (2e-ii): the operator's channel is typing in settings.environment.name and leaving it — not one click or drag (ctx_rename_project's case). Both channels ARE covered: the field by 2e-ii-environment-lifecycle.jsonl (left by a tree click) and 2e-ii-rename-active-environment.jsonl (the active one, its chip following), the dispatch by 2e-ii-environment-lifecycle.jsonl, each asserting the renamed node and the old one gone; its refusals by 2e-ii-name-refusals.jsonl. What no check can express is the comparison.
- `editor_new_scratch` — its parity (3b-i): the operator's channel is ⌘T, a menu key equivalent — a key, not a click or a drag, and the UI half of a parity step is a click or a drag only (api_fill_from_curl's case); the empty pane only names the key. The dispatch is covered by most 3b-i-editor-* checks; ⌘T by 3b-i-editor-scratch-save.jsonl and 3b-i-editor-close-keys.jsonl, asserting the Untitled-N tab through read_pane.
- `editor_changes_merge` — its parity (3a-v-b): the click (a picker row in Merge Branch…) merges and stops on the conflicts, and the same dispatch after it is refused (`A merge is in progress in <root>; finish or abort it first`), so the two halves cannot read back the same state (editor_changes_commit's case: the click consumes its own subject). Both channels ARE covered by 3a-v-b-merge.jsonl: the picker row (`Merge stopped on conflicts in doc, gone; resolve them below`, `merging feature`, the two rows) and the dispatch after an Abort (`merging feature` again), plus the in-progress refusal.
- `editor_changes_stage_ranges` — its parity (3a-ii-b): the click stages the selected lines, and the same dispatch after it finds them already staged and is refused (`the selection holds no change`), so the two halves cannot read back the same state — editor_changes_commit's case. Both channels ARE covered by 3a-ii-b-ranges.jsonl: the dispatch stages line 3 of app.txt and the header button (editor.diff.stageRanges) stages README.md's changed line, each asserted with `git diff --cached --numstat` in a terminal, and the no-change refusal; what no check can express is the comparison.
- `api_update_entry` — its parity (2e-iii): the operator's channel is typing in a field of the entry's section and leaving it — not one click or drag (ctx_rename_project's case); Clear token is a click but sends only clearToken, a part of the action. Both channels ARE covered by 2e-iii-api-entries.jsonl: the base URL and the name left by a tree click, Clear token pressed, and the dispatch renaming an entry, changing its URL, and refused on authHeader Host.
- `editor_changes_branch_delete` — its dispatch and its parity (3a-iv, Decision 46): from the agent's channel it is priced gate, so a dispatch parks for the operator's confirmation (`delete branch X in <root>`) and the request is held open until someone answers — an agent's proposal has no timeout (MCPServer.parkForConfirmation, R1). A check's dispatch holds its step for that whole time and no later step can run to answer the plane, so the dispatch can never be asserted (measured: the tools/call blocks until the harness's own reply deadline). The scripted agent (agent/) could ask instead, but its params are fixed in e2e/stub/script.json and cannot name the per-run fixture root an absolute `root` needs. The pane's channel IS covered: 3a-iv-branch-menu.jsonl deletes an unmerged and a merged branch through Delete Branch… with Keep it and Delete; the agent's plane is the runbook's row 10.
- `browser_navigate` — its parity (3c-i): the operator's channel is the address field — typing and Return, keys and not a click or a drag (api_fill_from_curl's case). Both channels ARE covered: typing by 3c-i-open-and-navigate.jsonl (Page A, then ⌘L and Page B), the dispatch by 3c-i-agent-drives.jsonl and 3c-i-tabs.jsonl, each reading the url and title back.
- `editor_trash` — its parity (3b-iv): the operator's channels are ⌘⌫ with the tree focused (a key) and a row's context menu Move to Trash (no arm opens one), so no UI half of one click or drag exists. ⌘⌫ is 3b-iv-trash-key.jsonl and 3b-iv-name-refused.jsonl; the dispatch is 3b-iv-trash-selection.jsonl (selection to the next row, else the previous; a clean tab closed; its refusals) and 3b-iv-trash-tabs.jsonl (a dirty tab kept, marked deleted, not autosaved back, recreated by ⌘S).
- `browser_zoom` — its parity (3c-i): the operator's channel is ⌘+ / ⌘− / ⌘0, keys and not a click or a drag (editor_new_scratch's case); the pane draws no zoom control. The keys are 3c-i-zoom.jsonl's (1.1, 1.25, per host, reset); the dispatch is 3c-i-agent-drives.jsonl's (in, reset).
- `settings_open` — its parity: the only UI path is the `Settings…` MENU item, and a menu's buttons are not in the accessibility tree until the menu is open — the same rule that excuses every other menu control. Checks drive it by its real gesture, cmd+comma, and 2e-settings-pane.jsonl also dispatches it.
- `browser_new_tab` — its parity (3c-i): each press opens another tab, so the dispatch after the click opens a third and the two halves cannot read back the same pane (editor_new_scratch's case). The ＋ click and ⌘T are 3c-i-new-tab-entry.jsonl's and 3c-i-tabs.jsonl's; the dispatch is 3c-i-agent-drives.jsonl's and 3c-i-narrow.jsonl's, each reading the new tab's id and selection back.
- `editor_replace_undo` — its parity (3b-ii-b): the Undo click spends the pane's one undo, and the dispatch after it is then refused (`no replace to undo`) — api_undo_fill's case. The click is 3b-ii-b-replace-undo.jsonl's (undone, restored 2, and the changed-since line for the file changed on disk), and so is the refusal of the dispatch after it.
- `ctx_create_project` — its parity (2e-ii): the operator's channel is + Add a project → Open a folder (settings.projects.add.folder), which opens the macOS folder picker (NSOpenPanel) — a system panel no check can drive — so no UI half exists to compare. The dispatch is covered by 2e-ii-project-lifecycle.jsonl (a folder added, then added back whole under the name in its project.json); the picker is the runbook's rows 1, 2 and 6 (docs/wakil/phase-2e-ii-acceptance.md).
- `browser_open` — its parity (3c-i): no operator control opens a URL in the browser from outside the pane — that arrives with 3c-iii's links from the terminal and editor — so no UI half exists. The dispatch is 3c-i-agent-drives.jsonl's and 3c-i-settings.jsonl's: it opens the pane and reads Page A's title back.
- `ctx_git_gh_import` — its parity (3a-iii): the operator's channel is Use your GitHub CLI login, offered only when `gh auth status` on this Mac holds a login — and a fixture gh login would be the operator's real GitHub token. The dispatch is covered by 3a-iii-git-account-actions.jsonl, refused for a login gh does not hold (`gh has no token for e2e-nobody on github.com`); the import itself is walk-only.
- `editor_changes_stash_pop` — its parity (3a-iv): the click (a stash row's Pop) applies the stash and drops it, and the same {index, id} dispatched after it is refused (`The stash list changed; look again`), so the dispatch half cannot be given the same params — the click consumes its own subject. The dispatch is covered by 3a-iv-stash-by-id.jsonl (a pop by a moved position refused, then by its new position), ▾ → Stash → Pop Latest Stash by 3a-iv-stash-menu.jsonl.
- `editor_close` — its parity (3b-i): the operator's channels are ⌘W (a key) and the unsaved prompt's Don't Save, and the click consumes its own subject — the dispatch half after it would close a different tab or be refused (`the editor pane has no open tab`), api_cancel's case. Both channels ARE covered: 3b-i-editor-close-keys.jsonl (⌘W clean, ⌘W dirty → Esc / Cancel / Don't Save) and the dispatch with and without discard in 3b-i-editor-refusals.jsonl.
- `api_render_curl` — Two reasons, and the second is the one that lasts. A dispatch cannot hold the row id, which is minted per send and published only in read_pane; and the operator's own Copy as cURL puts its line on the PASTEBOARD, which no check can read — the act is real and its result leaves the window. `api_reopen`'s CLICK left this file when the recent strip gave it a button, because a reopen's effect lands in the draft where a check can see it; its dispatch half is still here, for the first of these reasons. Covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses.
- `editor_conflict_accept` — its parity (3a-v-b, R3): the operator's channel is Accept Current / Incoming / Both Change in the actions row over a block, an overlay widget in HTML inside the WKWebView with no accessibility identifier, which the resolver cannot address (editor_peek's case). The dispatch is covered by 3a-v-b-merge.jsonl (both: `top|main|feature|bottom` on disk after editor_save; refused on the Compare tab and on a stale line) and 3a-v-b-rebase.jsonl (incoming); the row is the runbook's rows 3–6.
- `api_cancel` — its parity: the click cancels the send in flight, and api_cancel refuses a pane with nothing in flight (`nothingInFlight`), so the dispatch half cannot be given the same state — and a second Send between the halves is not expressible. Both channels ARE covered by api-cancel.jsonl, each after its own Send, asserting the same cancelled response through read_pane; what no check can express is the comparison.
- `capacity_record` — its parity: the operator's channel is the agent's own stream — the window records a `rate_limit_event` frame from a turn on its own, with no click or drag — so the UI half of a parity step cannot be expressed: no click or drag of the operator's produces it, so there is no UI half to compare. Both channels ARE covered: the dispatch by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, the stream by agent/capacity-after-turn.jsonl, each asserting the reading it lands on the indicator; what no check can express is the comparison.
- `editor_changes_continue` — its parity (3a-v-b): the click (Commit Merge / Continue Rebase) finishes the operation or moves the rebase to its next stop, and the same dispatch after it is refused (`Nothing to continue`, or `Resolve the conflicts in notes first` at the next stop), so the two halves cannot read back the same state (editor_changes_commit's case). Both channels ARE covered: the clicks by 3a-v-b-merge.jsonl (`git log` reads `Merge branch 'feature'` with two parents) and 3a-v-b-rebase.jsonl (`rebasing 3/3 onto main`), the dispatch's three refusals by both.
- `ctx_git_account_remove` — its parity (3a-iii): the click removes the account, and removing one that is gone is refused (`no git account for … in …`), so the dispatch half cannot be given the same params (db_remove_database's case). Both channels ARE covered: Remove… → Remove in the card by 3a-iii-git-accounts.jsonl (Keep it first leaves it), and the dispatch and its refusal by 3a-iii-git-account-actions.jsonl.
- `editor_replace` — its parity (3b-ii-b): the click replaces, and the same dispatch after it finds nothing left to replace and answers a different last_replace, so the two halves cannot read back the same pane (api_cancel's case: the click consumes its own subject). Both channels ARE covered: the click (Replace All) by 3b-ii-b-replace-all.jsonl and the dispatch by 3b-ii-b-replace-undo.jsonl, each asserting last_replace's files and the Replaced … line; Replace in this file by 3b-ii-b-replace-file.jsonl, and Cancel by 3b-ii-b-replace-cancel.jsonl.
- `ctx_unlink_provider` — its parity: the click removes the binding, so the dispatch half cannot be given the same id. Dispatch and both channels' behaviour ARE covered by 2e-settings-unlink.jsonl; what no check can express is the comparison.
- `editor_clone` — its parity (3a-iii): the click consumes its own subject — Clone in + Add a project clones into <folder>/<name>, and the same {url, folder} dispatched after it finds the destination there and is refused (`the destination already exists`), api_cancel's case. Both channels ARE covered by 3a-iii-add-project-clone.jsonl: the sheet's Clone (a bare repository on this Mac, pasted into the link field; the project's page opens) and the agent's dispatch (refused outside the last clone folder, on an existing destination and on a non-link, then cloning into the last folder and adding no project); what no check can express is the comparison.
- `editor_changes_rebase` — its parity (3a-v-b): the click (a picker row in Rebase Branch…) rebases and stops at step 1, and the same dispatch after it is refused (`A rebase is in progress in`), editor_changes_merge's case. Both channels ARE covered by 3a-v-b-rebase.jsonl: the picker row (`Rebase stopped on conflicts in doc (step 1 of 3)`, `rebasing 1/3 onto main`) and the dispatch after an Abort, plus the in-progress refusal.
- `editor_changes_stage_hunk` — its parity (3a-ii): the operator's channel is the gutter peek's Stage, a button in HTML inside the WKWebView with no accessibility identifier, which the resolver cannot address (editor_peek's case). The dispatch is covered by 3a-ii-stage-change.jsonl: one of two changes staged, the other still marked, the file under Staged and Changes, and the untracked-file refusal; pressing Stage itself is walk-only (runbook row 9).
- `editor_rename` — its parity (3b-iv): the operator's channels are F2 and a row's context menu Rename, then typing — and neither can be driven: Orca's key table has no F-keys and no arm opens a context menu. So no UI half exists to compare, and the field's rename is walk-only (runbook rows 4–7). The dispatch is covered by 3b-iv-rename-tabs.jsonl: a folder and a file renamed under open tabs in two panes, unsaved edits and ⌘Z kept, typing across it, the open folder staying open, and its four refusals.
- `api_fill_from_curl` — its parity: the UI half of a parity step is a click or a drag, and the operator's channel is a paste (cmd+v into the path editor), so the comparison cannot be expressed. Both channels ARE covered: the dispatch by api-paste-curl.jsonl, the paste by api-paste-curl-hotkey.jsonl, each asserting the same draft and the Filled from cURL line; what no check can express is the comparison.
- `ctx_git_account_test` — its parity (3a-iii): a parity's dispatch half must succeed, and no fixture host can answer a test — a token on a host Wakil cannot test is refused (`Wakil cannot test a token on …`), and an ssh test needs a real host that knows the key. Both channels ARE covered for that refusal: the card's Test by 3a-iii-git-accounts.jsonl (the note) and the dispatch by 3a-iii-git-account-actions.jsonl; a test that answers is the runbook's row 8 (docs/wakil/phase-3a-iii-acceptance.md).
- `editor_changes_abort` — its dispatch and its parity (3a-v-b, Decision 46): priced gate for the agent, so a dispatch parks (`abort the <kind> in <root>`) and holds its step open until the operator answers — editor_changes_branch_delete's case. The pane's channel IS covered: 3a-v-b-merge.jsonl presses ▾ → Abort Merge, Keep it (nothing changes), then Abort (`· clean`, no MERGE_HEAD); 3a-v-b-rebase.jsonl the same for Abort Rebase.
- `editor_open_file` — its parity (3b-iii): the operator's channel is ⌘⏎ in a diff tab, a menu key equivalent (Maximize Pane's item, which a diff tab redirects) — a key, not a click or a drag — so no UI half can be expressed. Both channels ARE covered by 3b-iii-diff-open-file.jsonl, each opening app.txt at the diff's cursor line with the diff tab kept, and ⌘⏎ on a scratch tab maximizing; its refusal on a deleted file by 3b-iii-changes-live.jsonl.
- `api.recent.<…>.curl` — Its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read — the act is real and its result leaves the window, so a check could press it and assert nothing, which is the check-that-cannot-fail this file exists to prevent rather than permit. `TerminalPane`'s own Copy is silent for the same reason and carries no indicator. The line it copies is `apiRenderCurl`'s, covered by WakilKitTests: curlIsPastTenseOnly, curlOnlyMentionsACredentialThereWasOne, curlEmitsAndNeverParses. If this pane ever draws a "copied" acknowledgement, the act becomes observable and this line should go.
- `api.response.<…>` — the Body · Headers choice (W20) is drawn only over a reply, and no fixture host ever replies — every entry is `.invalid` or the never-answering `slow`, and wakil-http refuses http://. apiResponseOffersHeaders and apiResponseHeaderRows are pinned in ApiPaneLayoutTests; the drawn table is the runbook's check 5.
- `branch.picker.blocked` — a Text (3a-iv, spec call 5): what a refused switch would overwrite. Read, not pressed — 3a-iv-branch-blocked.jsonl asserts `Your changes to index.txt would be overwritten by other.` before Cancel, Bring Them Along and Stash and Switch.
- `branch.picker.delete.confirmation` — a Text (3a-iv, Rule 1): what deleting the picked branch loses. Read, not pressed — 3a-iv-branch-menu.jsonl asserts `Delete from-main? Its 1 commit not on main is kept only in git's reflog.` and `Delete from-topic? It is merged into main.`
- `branch.picker.message` — a Text (3a-iv, Rule 8): the picker's refusal, drawn whole under the list. Read, not pressed — 3a-iv-branch-picker.jsonl asserts `"bad..name" is not a valid branch name` with the typed name kept in the filter.
- `branch.picker.root.<…>` — the branch picker's root tabs (3a-iv): drawn only in the context line's picker (a Changes header's picker is for its one root), and that picker opens only from the hovered Branch segment — window.contextLine.branch's case. Switching roots is the runbook's.
- `browser.certificate` — a Text (3c-i): `<host>'s certificate isn't trusted — <reason>`. Drawn only over an https page whose certificate WebKit refuses, and the page stub is loopback http; walk-only (runbook §3, self-signed.badssl.com).
- `browser.crashReload` — Reload on the crashed page (3c-i): browser.crashed's case; walk-only.
- `browser.crashed` — a Text (3c-i): `This page stopped.`. Drawn only after WebKit's web content process for the tab ends, and nothing a check can do crashes it; walk-only (runbook §3).
- `browser.download.<…>` — one download's row (.contain, 3c-i). Read, not pressed — 3c-i-download.jsonl reads d1 and d2 through read_pane and presses d1's Cancel.
- `browser.download.<…>.name` — a Text (3c-i): the download's file name. Read, not pressed — 3c-i-download.jsonl reads it as downloads[0].filename (big.bin).
- `browser.download.<…>.show` — Show in Finder (3c-i): drawn only on a finished download, and pressing it reveals the file in Finder — the act's whole effect leaves the window (settings.org.git.account.add.openKeys' case). The fixture's big.bin takes minutes by design; a real download is the runbook's row 7.
- `browser.download.<…>.status` — a Text (3c-i): the size line or the ended state. Read, not pressed — 3c-i-download.jsonl asserts "of 10.5 MB" and "Cancelled".
- `browser.downloads` — the download strip's container (.contain, 3c-i): its rows and Clear. Read, not pressed — 3c-i-download.jsonl presses its Cancel and Clear.
- `browser.find` — the find bar's container (.contain, 3c-i): its field, count and buttons are pressed by 3c-i-find.jsonl. Read, not pressed.
- `browser.find.count` — a Text (3c-i): the find bar's `N of M`. Read, not pressed — 3c-i-find.jsonl asserts "1 of 3" and "2 of 3".
- `browser.footer` — the footer row's container (.contain, 3c-i): host and transport. Read, not pressed — 3c-i-open-and-navigate.jsonl holds it inside the pane; its rule is WakilKit's (theFooterNamesTheHostAndHowThePageCame).
- `browser.footer.host` — a Text (3c-i): the page's host in capitals. Read, not pressed — 3c-i-open-and-navigate.jsonl holds it inside the footer.
- `browser.loadError` — a Text (3c-i, Rule 8): `Couldn't reach <host> — …`. Read, not pressed — 3c-i-load-error.jsonl asserts it and its NSURLError name; its Try Again is pressed there.
- `browser.page` — the tab's web view (3c-i, Decision 48). Clicks and typing inside a page are the operator's and walk-only: the harness presses Wakil's own controls by identifier, and a page's links and fields carry none (runbook rows 1, 3 and 5 click in pages). Its focus is read, not pressed — 3c-i-keys-reach-wakil.jsonl asserts expect.focus browser.page after Return, ⌘K, ⌘P, ⌘1 and Escape, and a key typed there reaches the page.
- `browser.pane` — the browser pane's container (.contain, 3c-i), which takes no input itself. Every 3c-i check holds controls inside it with expect.frame (3c-i-narrow.jsonl at 1000, 560 and 400 wide).
- `browser.prompt` — a page's question's container (.contain, 3c-i): message, field and buttons. Read, not pressed — 3c-i-alert.jsonl and 3c-i-prompt.jsonl press its buttons and type into its field.
- `browser.prompt.allow` — the camera / microphone prompt's Allow (3c-i): drawn only when a page asks for a camera or microphone, and macOS first asks the operator itself (TCC), a system dialog no step kind answers; a fixture camera would also have to exist. Walk-only: runbook row 8.
- `browser.prompt.deny` — the camera / microphone prompt's Don't Allow (3c-i): browser.prompt.allow's case. Walk-only: runbook row 8.
- `browser.prompt.origin` — a Text (3c-i): the host that asked. Read, not pressed — shown with every prompt 3c-i-alert.jsonl and 3c-i-prompt.jsonl answer.
- `browser.prompt.password` — an HTTP sign-in's password (3c-i): browser.prompt.user's case — and a check typing a password is a credential in a check file; walk-only.
- `browser.prompt.text` — a Text (3c-i): the page's own message. Read, not pressed — 3c-i-alert.jsonl asserts "Hello from the page" and 3c-i-prompt.jsonl "What is your name?".
- `browser.prompt.user` — an HTTP sign-in's user name (3c-i): drawn only for a basic-auth challenge, which the page stub never sends; walk-only (runbook §3).
- `browser.tab.<…>.close` — a tab's × (3c-i): drawn only while the pointer is over the tab, and no step kind moves the pointer without clicking — a click on the tab selects it instead. Closing is ⌘W in 3c-i-tabs.jsonl and browser_close_tab in 3c-i-agent-drives.jsonl; the × itself is walk-only.
- `browser.tabCount` — a Text (3c-i): the tab count beside the strip. Read, not pressed — 3c-i-narrow.jsonl holds its frame inside the pane at 1000 wide.
- `browser.tabs` — the tab strip's container (.contain, 3c-i): its entries are pressed as browser.tab.<id>. Read, not pressed — 3c-i-narrow.jsonl holds it to one row (maxHeight 40) at 1000 and 560 wide and keeps it inside the pane.
- `browser.visitAnyway` — Visit Anyway (3c-i, operator only, for the session): drawn only on the certificate page (browser.certificate's case); walk-only.
- `db.<…>.detail` — the row detail strip's container (.contain, RowDetailStrip.swift): its labels and values, with no press action of its own. What it draws is read by db-detail-strip.jsonl and db-detail-big-cells.jsonl; its values are db.<pane>.detail.<i>, read.
- `db.<…>.flight` — a Text (db pane footer): the flight line, "running …" while a read is in flight and "cancelled after …" once one is cancelled. Read, not pressed — db-cancel-click.jsonl and db-cancel-escape.jsonl assert "cancelled after" in the tree, and db-cancel-click.jsonl its absence after the next read.
- `db.<…>.grid` — the db grid's surface (.contain): it has no press action and refuses AXFocused (measured: axresolve not_focusable), as a focusable SwiftUI surface with no AX focus attribute — its keyboard focus is SwiftUI's own, given when the pane is focused, which the checks do by clicking rail.db-<n>. Its keys are driven that way: ↑↓, Space and Esc by db-detail-strip.jsonl, ⌘C by db-grid-copy.jsonl; its rows' contents are read through read_pane.
- `db.<…>.notFormatted` — display text, not a control: a static `Text` (DBPane.swift) carrying Format's refusal reason, with no press action, and the vocabulary addresses only `click`/`focus` by identifier while `expect.tree` matches by text, so no step can "press" it. Its content IS asserted: db-query-line-not-formatted.jsonl expects `not formatted: a string opened at character 39 never closes` in the tree, then its absence after the next edit.
- `db.<…>.row.<…>.detail` — the row's ⓘ: drawn only while the pointer hovers inside a row whose children are ignored by accessibility (.accessibilityElement(children: .ignore)), so it is never in the tree, and the vocabulary has no hover step (window.capacity's case). The same toggle is the row's "Show details" accessibility action and Space on the grid, and db-detail-strip.jsonl drives Space (open, close, another row). Pressing the ⓘ itself is walk-only.
- `editor.changes.<…>.branch.create` — ▾ → Branch → Create Branch… (3a-iv): an item of a submenu, which the accessibility tree the resolver reads does not hold (measured: pressing the Branch item leaves `menu item (selected) Branch` and no child menu), so no click can name it. It is reached by keys instead — the submenu opened with Right, Return on its first item — by 3a-iv-branch-menu.jsonl, which asserts the field it opens (focused, `New branch name`) and the branch it creates.
- `editor.changes.<…>.branch.createFrom` — ▾ → Branch → Create Branch From… (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-branch-menu.jsonl, which asserts the picker it opens (`Choose the branch to start from`, then `Name the new branch (from main)`) and the branch made from main.
- `editor.changes.<…>.branch.delete` — ▾ → Branch → Delete Branch… (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-branch-menu.jsonl, which asserts the picker it opens (`Choose the branch to delete`), the in-place confirmation and both deletes.
- `editor.changes.<…>.branch.merge` — ▾ → Branch → Merge Branch… (3a-v-b): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys (Right, Return) by 3a-v-b-merge.jsonl, which asserts the picker it opens (`Choose the branch to merge in`, its filter focused, Escape closing it) and the merge it starts.
- `editor.changes.<…>.branch.rebase` — ▾ → Branch → Rebase Branch… (3a-v-b): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys (Right, Down, Return) by 3a-v-b-rebase.jsonl, which asserts the picker it opens (`Choose the branch to rebase onto`, its filter focused) and the rebase it starts.
- `editor.changes.<…>.branch.rename` — ▾ → Branch → Rename Branch… (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-branch-menu.jsonl, which asserts the field (`New name for the branch`, holding the current name) and the rename, by the field's button and by dispatch (parity).
- `editor.changes.<…>.conflictsReason` — a Text (3a-v-b): why Commit Merge / Continue Rebase / Commit All is disabled, beside it. Display text with no press action. Read, not pressed — 3a-v-b-merge.jsonl asserts `Resolve 2 conflicts first`, then `Resolve 1 conflict first` after Keep File and none once the last is staged; 3a-v-b-rebase.jsonl and 3a-v-b-stash-clash.jsonl `Resolve 1 conflict first`.
- `editor.changes.<…>.error` — a Text (3a-ii, Rule 8): the root's last git write error, drawn whole under its message box. Display text with no press action. Read, not pressed — 3a-ii-hook-fails.jsonl asserts the failing pre-commit hook's `e2e hook says no` with the message kept in the box, and that a cancelled slow commit clears it and shows no error of its own (no `CancellationError`).
- `editor.changes.<…>.hint` — a Text (3a-ii): the message box's placeholder, drawn while the box is empty, naming who a commit in that root is authored as and ⌘⏎. Display text with no press action. Read, not pressed — 3a-ii-identity.jsonl asserts `Message · as cfg@e2e.invalid (from git config) (⌘⏎)` after a repository-local user.email, then `Message · as org@e2e.invalid (⌘⏎)` once Settings → Organisation → Git is saved; 3a-ii-commit.jsonl asserts the organisation's form.
- `editor.changes.<…>.note` — a Text (3a-iii): the background fetch's quiet failure, drawn only after a fetch that runs every five minutes fails — longer than any assertion waits, and no step can start that timer. Display text with no press action either way. The ▾ Fetch it stands for is 3a-iii-remote-fetch-pull.jsonl's, whose failure (`no remote named origin`) is the root's error line, read.
- `editor.changes.<…>.stash.applyLatest` — ▾ → Stash → Apply Latest Stash (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-stash-menu.jsonl, which asserts the changes back and the stash kept.
- `editor.changes.<…>.stash.popLatest` — ▾ → Stash → Pop Latest Stash (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-stash-menu.jsonl, which asserts the change back and the stash list empty.
- `editor.changes.<…>.stash.push` — ▾ → Stash → Stash (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-stash-menu.jsonl, which asserts the field (focused, `Message (optional)`, kept with its text when focus leaves, closed by Escape) and the stash Return makes.
- `editor.changes.<…>.stash.pushStaged` — ▾ → Stash → Stash Staged (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-stash-menu.jsonl, which asserts the staged file gone, the untracked one kept, and `On main: staged only` in `git stash list`.
- `editor.changes.<…>.stash.pushUntracked` — ▾ → Stash → Stash Including Untracked (3a-iv): a submenu item, editor.changes.<…>.branch.create's case. Reached by keys by 3a-iv-stash-menu.jsonl, which asserts e2e-api clean, untracked files included, and one stash in `git stash list`.
- `editor.changes.<…>.state` — a Text (3a-v-b): the amber operation line under a root's header. Display text with no press action. Read, not pressed — 3a-v-b-merge.jsonl asserts `merging feature` and its absence after Abort and Commit Merge; 3a-v-b-rebase.jsonl `rebasing 1/3 onto main` and `rebasing 3/3 onto main`; 3a-v-b-stash-clash.jsonl that a stash clash draws none.
- `editor.changes.loading` — the Changes header's load tick (3b-iii, Rule 5): a shape drawn only while a root's git status is being read, which against the fixture's tiny repositories lasts milliseconds — never long enough for a tree read to see (editor.tree.loading's case). Seeing it is the walk's.
- `editor.changes.rootError:<…>` — a Text (3b-iii, Rule 8): the second and later lines of a root's error, drawn whole beneath its Changes header — and only when the error HAS a second line. The fixture's only failing root is not a git repository, which the Changes view does not draw at all (3b-iii-changes-list.jsonl asserts `not a git repository` absent), so it is never drawn; the split is pinned by WakilKitTests (gitRootErrorDetail), and a multi-line error is walk-only.
- `editor.changes.row:<…>/<…>:conflicts.delete` — Delete File in a delete/modify row's context menu (3a-v-b): editor.changes.row:<…>/<…>:conflicts.takeCurrent's case; walk-only.
- `editor.changes.row:<…>/<…>:conflicts.keep` — Keep File in a delete/modify row's context menu (3a-v-b): no arm opens a context menu. What it runs, editor_changes_keep_file, is dispatched by 3a-v-b-merge.jsonl; the menu is walk-only.
- `editor.changes.row:<…>/<…>:conflicts.take.confirm` — the whole-file take's Accept / Delete (3a-v-b, Rule 1): editor.changes.row:<…>/<…>:conflicts.take.keep's case — drawn only after a context-menu choice; walk-only, the runbook's row 5.
- `editor.changes.row:<…>/<…>:conflicts.take.keep` — the whole-file take's Keep it (3a-v-b, Rule 1): drawn only after a choice in a conflicted row's context menu, which no arm opens, and the agent's take parks rather than asking in place — so nothing a check can do ever draws it. The same ChangesConfirm's Keep it is pressed under Abort, Skip and Undo Apply by 3a-v-b-merge, 3a-v-b-rebase and 3a-v-b-stash-clash; this one is the runbook's row 5.
- `editor.changes.row:<…>/<…>:conflicts.takeCurrent` — Accept All Current in a conflicted row's context menu (3a-v-b): no arm opens a context menu (editor_rename's case), so no click can name it. editor_changes_take's dispatch is gated as well, so neither channel is driven; walk-only, the runbook's row 5.
- `editor.changes.row:<…>/<…>:conflicts.takeIncoming` — Accept All Incoming in a conflicted row's context menu (3a-v-b): editor.changes.row:<…>/<…>:conflicts.takeCurrent's case; walk-only, the runbook's row 5.
- `editor.column` — the editor's left column's container (.contain, 3b-ii): its header, the tree or the search view, and the edge, and it takes no input itself. What it draws is read by every 3b-ii-* check; its controls are editor.column.files / .search, pressed by 3b-ii-tree-toggle.jsonl, editor.column.edge, dragged there, and the tree's and search's own.
- `editor.compare.diff` — Compare's Monaco host (3b-i): a WKWebView container with no press action. 3b-i-editor-disk-changed.jsonl asserts Compare's header opens and closes (button and Esc); what the diff shows is the operator's ruling (runbook row 6).
- `editor.compare.failure` — a Text (3b-i, Rule 8): drawn only when the file cannot be read back for Compare. The fixture's files are always readable and no step can make one unreadable mid-launch; display text with no press action either way. The runbook walks Compare.
- `editor.diff.banner` — a Text (3b-iii): `binary · 3 bytes` or `file is … · first 2 MB shown` over a binary or oversized diff. Display text with no press action. Read, not pressed — 3b-iii-changes-live.jsonl writes an untracked binary and asserts `binary · 3 bytes` in the tree and diff.binary through read_pane.
- `editor.diff.error` — a Text (3b-iii, Rule 8): a diff tab's error, drawn whole — only when git_show fails, which no fixture file makes it do mid-launch. Display text with no press action; diff.error is asserted null by 3b-iii-changes-drill.jsonl, and the error path is pinned by WakilKitTests (EditorDiffTabsTests).
- `editor.diff.gone` — a Text (3b-iii, Rule 7): "No longer changed", over a diff tab whose file left its group. Display text with no press action. Read, not pressed — 3b-iii-changes-live.jsonl asserts it in the tree and diff.no_longer_changed through read_pane, after `git add`, `rm` and `git checkout` in a terminal.
- `editor.diff.loading` — a diff tab's Loading line (3b-iii, Rule 5): drawn only while git_show reads the two sides, milliseconds against the fixture; editor_changes_select returns after the fetch, so every check reads diff.loading false through read_pane (3b-iii-changes-drill.jsonl, 3b-iii-diff-refusals.jsonl). Display text with no press action.
- `editor.diskChanged` — the disk line's container (.contain, 3b-i): its text and two buttons. Read, not pressed — 3b-i-editor-disk-changed.jsonl asserts "disk.txt changed on disk" and its absence while comparing and after Reload; its buttons are editor.reload and editor.compare, pressed.
- `editor.empty` — the empty pane's hint (3b-i, .combine): "⌘P to open a file · ⌘T for a scratch tab", with no press action. Read, not pressed — 3b-i-editor-close-keys.jsonl asserts it after the last tab closes, and its absence after ⌘W closes the pane.
- `editor.monaco` — the Monaco host's container (3b-i): an NSViewRepresentable holding the WKWebView, with no press action of its own. Typing into it is driven by keys: 3b-i-editor-scratch-save.jsonl types after ⌘T and after a save, and asserts the text through read_pane.
- `editor.notice` — a Text (3b-i, Rule 8): a tab's notice, drawn whole. Read, not pressed — 3b-i-editor-read-only.jsonl asserts "ro.bin is a binary file" in the tree and through read_pane.
- `editor.replace.busy` — the replace tick (3b-ii-b, Rule 5): a shape with no press action, drawn while a replace or its undo is in flight (editor.search.busy's case). Read, not pressed — 3b-ii-b-replace-cancel.jsonl reads the tree for its label, "replacing", while the replace walks the 200 MiB haystack, then presses the Cancel beside it, editor.replace.cancel.
- `editor.replace.failure` — a Text (3b-ii-b, Rule 8): one file the replace or its undo could not write or put back, drawn whole. Read, not pressed — 3b-ii-b-replace-undo.jsonl asserts "changed since the replace — left as it is" in the tree for the file changed on disk after the replace.
- `editor.replace.result` — the replace's result line's container (.contain, 3b-ii-b): the summary Text, Undo replace (editor.replace.undo, pressed) and the failures under it. Read, not pressed — 3b-ii-b-replace-all.jsonl asserts "Replaced 3 in 3 files" in the tree and last_replace through read_pane; 3b-ii-b-replace-undo.jsonl asserts "Undid the replace in 2 files".
- `editor.saveAs.failure` — a Text (3b-i, Rule 8): the path field's failure, drawn whole. Read, not pressed — 3b-i-editor-save-as-field.jsonl asserts "is outside the active project's roots; editor reads and writes are confined to them (Invariant 6, Decision 36)" with the typed path still in the field.
- `editor.saveAs.replacePrompt` — the Save-As field's "Replace <name>?" line's container (.contain, 3b-i, Rule 1): its text and two buttons. Read, not pressed — 3b-i-editor-save-as-replace.jsonl asserts "Replace replace-me.txt?" and its absence after Cancel; its buttons editor.saveAs.replace / .replaceCancel are pressed there.
- `editor.saving` — the saving tick (3b-i, Rule 5): a 2 pt shape drawn only while a write is in flight, which against the fixture's tiny files lasts milliseconds — never long enough for a tree read to see. `saving` is asserted false after each save through read_pane; seeing the tick is the runbook's walk.
- `editor.saving.cancel` — the saving tick's Cancel (3b-i, Rule 4): a control that exists only while a write is in flight, which against the fixture lasts milliseconds — a press cannot land on it, and wakil-files writes through a temp file and a rename, so no fixture path can make a write wait. Cancelling a save is the runbook's walk.
- `editor.search.busy` — the search tick (3b-ii, Rule 5): a shape with no press action, drawn while a search is in flight. Read, not pressed — 3b-ii-search-cancel.jsonl reads the tree for its label, "searching", with no read_pane or other dispatch ending while the search runs (the regex switch is set on the empty query first, so typing starts the one search), so only the window's editor-flight redraw (final review C1) can draw it; it then presses the Cancel beside it, editor.search.cancel.
- `editor.search.cancelled` — the Search view's cancelled line's container (.contain, 3b-ii walk): the Text "search cancelled" and its Re-run, editor.search.rerunCancelled. Read, not pressed — 3b-ii-search-cancel.jsonl asserts "search cancelled" in the tree and search.cancelled through read_pane after Cancel, then presses Re-run and reads the search running again with cancelled cleared.
- `editor.search.error` — a Text (3b-ii, Rule 8): a search's error, drawn whole. Read, not pressed — 3b-ii-search-errors.jsonl asserts "missing closing )" in the tree and through read_pane, with the typed query kept.
- `editor.search.filesNote` — a Text (3b-ii): "only the first 50,000 files are searched", drawn only when a root's listing hit the cap. 50,000 files are not seeded (editor.tree.note:<…>'s reason); `files_truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests).
- `editor.search.largeNote` — a Text (3b-vii, Rule 8): "1 file over 2 MB not searched: big.log", drawn under the results when files_search skipped files over 2 MB. Display text with no press action. Read, not pressed — 3b-vii-log-tail.jsonl asserts it in the tree and search.skipped_large in the pane after searching beside a 3 MB log.
- `editor.search.noMatches` — a Text (3b-ii walk): "no matches", drawn under a finished search that found nothing. Display text with no press action. Read, not pressed — 3b-ii-search.jsonl asserts it in the tree after a search for a string no fixture file holds.
- `editor.search.note` — a Text (3b-ii): "only the first 2,000 matches are shown", drawn only over a search that hit the cap. 2,000 matches are not seeded; `truncated` is pinned by internal/wakilcore/files_test.go and WakilKitTests (EditorSearchActionsTests), and the note is the runbook's walk.
- `editor.strip` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.strip")`, the visible tab strip's, where the middle-click converts a click), not an accessibility identifier — editor.tabs's case. Nothing in the accessibility tree carries it. The middle-click itself is walk-only: the harness posts no middle button (runbook row 8).
- `editor.tabs` — not a control (3b-ii-b): the name of a SwiftUI coordinate space (`.coordinateSpace(name: "editor.tabs")`, the tab strip's, which the drop target and the middle-click measure in), not an accessibility identifier. The harvest reads any `editor.…` literal; nothing in the accessibility tree carries this name, so no check can press or read it. The strip's tabs are editor.tab.<…>, dragged by 3b-ii-b-tab-move.jsonl.
- `editor.timeline` — the Timeline section's container (3a-v-a, EditorTimeline.swift): its header and rows, and it takes no input itself. What it draws is read by 3a-v-a-timeline.jsonl, 3a-v-a-timeline-rename.jsonl and 3a-v-a-timeline-more.jsonl; its controls are editor.timeline.toggle, .uncommitted, .row.<…> and .more, each pressed there.
- `editor.timeline.more` — the Timeline's Load more (3a-v-a): the last row of a LazyVStack inside a ScrollView capped at 240pt, so it is built only once the list is scrolled to its end — after a full page of 50 rows. Measured 2026-10-23 with 51 commits on log.txt: the accessibility tree held 15 of the 50 rows, and editor.timeline.more matched no element; no step kind scrolls. The page size and the end of history are pinned by WakilKitTests (editorTimelineHasMore: a full page has more, a short one is the end); pressing it is the runbook's row 5.
- `editor.timeline.open` — not an identifier: the `@AppStorage("editor.timeline.open")` key that holds whether the Timeline is open (EditorTimeline.swift:25). The harvest reads every literal shaped like an identifier, so it counts a defaults key no element carries and no check can press. The open state it holds IS driven: 3a-v-a-timeline.jsonl presses editor.timeline.toggle closed and open again and asserts the rows go and come back.
- `editor.tree.error:<…>` — a Text (3b-ii, Rule 8): a root's or a heavy folder's listing error, drawn whole under its row. Every fixture root lists and vendor loads, and no step can make one unreadable mid-launch; display text with no press action either way. Pinned by WakilKitTests (EditorTreeTests), and an unreadable root is the runbook's walk.
- `editor.tree.loading` — the tree's load tick (3b-ii, Rule 5): a shape drawn only while a root lists or a heavy folder loads, which against the fixture's small roots lasts milliseconds — never long enough for a tree read to see. 3b-ii-tree-ignored-heavy.jsonl asserts what the load brings (autoload.php under vendor); seeing the tick is the runbook's walk.
- `editor.tree.name.error` — a Text (3b-iv, Rule 8): the tree's name field's refusal, drawn whole under it. Display text with no press action. Read, not pressed — 3b-iv-name-refused.jsonl asserts `/e2e-api/README.md already exists` in the tree, its frame inside editor.column, and its absence once the kept text, amended, commits.
- `editor.tree.note:<…>` — a Text (3b-ii): "only the first 50,000 files are listed", drawn only under a root whose listing hit the cap. The fixture's roots hold a few hundred files and seeding 50,000 per launch is not worth its minute; a note row is never selected or pressed. Its row is pinned by WakilKitTests (EditorTreeTests).
- `editor.tree.status:<…>` — a Text (3b-iii): a Files tree row's git status letter, `M` or `?`. Display text with no press action. Read, not pressed — 3b-iii-tree-letters.jsonl resolves it per row (app.txt, notes, BookingController.php, index.txt) and holds its frame inside its row and the column at the window's minimum; which letter and which tone is pinned by WakilKitTests (editorTreeStatus).
- `editor.unsaved` — the unsaved prompt's container (.contain, 3b-i): the message and three buttons. Read, not pressed — every prompt check asserts its message; its buttons editor.unsaved.save / .dontSave / .cancel are pressed by 3b-i-editor-close-keys.jsonl, 3b-i-editor-unsaved-save.jsonl and 3b-i-editor-unsaved-org-switch.jsonl.
- `editor.unsaved.message` — a Text (3b-i): the prompt's question. Read, not pressed — "Save changes to Untitled-2?" (3b-i-editor-close-keys.jsonl), "Save changes to kept.txt?" (3b-i-editor-unsaved-save.jsonl), "Unsaved changes in Untitled-1" (3b-i-editor-unsaved-org-switch.jsonl, 3b-i-editor-unsaved-quit.jsonl).
- `palette.error` — a Text (palette rework, rule 8): a run's error, drawn whole under the query line. Display text with no press action. Read, not pressed — palette-run-error.jsonl asserts "no entry in staging has that host" with the step and the typed line still there.
- `palette.plane` — the palette's container (.contain, palette rework): it holds the header, the query line, the rows and the footer, and takes no input itself — the dimmer around it takes the dismissing click. Its contents are read by every palette-*.jsonl check ("OPEN OR SWITCH TO", "RUN A COMMAND", the "N of M" count); the field inside it is palette.query, typed into, and its rows are palette.row.<id>, pressed.
- `palette.step` — a Text (palette rework): an input step's title, uppercased, where the mode's name was. Read, not pressed — palette-command-step.jsonl and palette-escape.jsonl assert "PANE KIND", palette-run-error.jsonl "CURL COMMAND", palette-switch-environment.jsonl "ENVIRONMENT", palette-table-row.jsonl a drill's "BOOKINGS"; palette-escape.jsonl asserts it gone after one Esc.
- `settings.breadcrumb` — a Text: the page's breadcrumb (E2E Fixture › Providers). Display text with no press action. Read by frame, not pressed — 2e-settings-pane.jsonl and 2e-settings-narrow-rows.jsonl hold it inside settings.pane on the Providers page.
- `settings.browser.clear.done` — a Text (3c-i): `Deleted <org>'s browsing data.`. Read, not pressed — 3c-i-settings.jsonl asserts it after Delete.
- `settings.browser.clear.question` — a Text (3c-i, Rule 1): `Delete <org>'s browsing data? …`. Read, not pressed — 3c-i-settings.jsonl asserts it before Keep it and before Delete.
- `settings.browser.clear.refusal` — a Text (3c-i, Rule 8): drawn only when Delete is refused — no organisation, no remover, or the organisation changed between the question and the yes — none of which a check can arrange around one click. Pinned by WakilKit: clearDataRefusesWhenTheOrganisationTheQuestionNamedIsNotActive and clearingBrowsingDataNamesTheOrganisationTheQuestionAsked.
- `settings.browser.searchEngine.refusal` — a Text (3c-i, Rule 8): drawn only when Go refuses an engine the pane itself offers, which it does only over a settings.json that does not parse — the fixture's parses (settings.editor.inlineBlame.refusal's case). The refusal is Go's (browsersettings_test.go).
- `settings.browser.startPage.refusal` — a Text (3c-i, Rule 8): the start page's refusal. Read, not pressed — 3c-i-settings.jsonl asserts `start page "not a url" is not an http or https URL — …`.
- `settings.capacity.strip` — the Settings capacity strip's scroll container (provider capacity), which takes no input. Its rows are read by capacity-low-reading.jsonl and capacity-passed-reset.jsonl, beside the accounts table's own CREDENTIAL and SIGN-IN headers.
- `settings.editor.autosave.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses an autosave mode the pane offers (off, pause, focus are each valid), which happens only over a settings.json that does not parse — no fixture or step can produce one (settings.editor.error's reason). Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives all three modes and asserts each on disk.
- `settings.editor.error` — a Text (3b-v, Rule 8): settings.json's read or parse error, drawn only when ~/.wakil/settings.json cannot be read. The seed never writes that file, and no step can write it mid-launch — editor writes are confined to the active project's roots (Invariant 6, Decision 36) and ~/.wakil is outside them; display text with no press action either way. Its wording and the defaults it leaves in force are pinned by internal/wakilcore/editorsettings_test.go and WakilKitTests EditorSettingsTests; the runbook walks it with a hand-broken file.
- `settings.editor.inlineBlame.refusal` — a Text (3a-v-a, Rule 8): drawn only when Go refuses an Inline blame write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.showIgnored.refusal, no fixture or step can produce. Display text with no press action. 3a-v-a-inline-blame-setting.jsonl drives both choices and asserts each write.
- `settings.editor.showIgnored.refusal` — a Text (3b-v part 2, Rule 8): drawn only when Go refuses a Show ignored files write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.error, no fixture or step can produce. Display text with no press action. 3b-v-show-ignored.jsonl drives both choices and asserts each write.
- `settings.editor.wordWrap.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses a word-wrap write the pane itself offers (On or Off), and Go refuses a boolean only when settings.json does not parse — which, as for settings.editor.error, no fixture or step can produce. Display text with no press action. 3b-v-editor-settings-nodes.jsonl drives both choices and asserts each write on disk.
- `settings.localProvider.<…>.refusal` — a Text (3b-viii, Rule 8): a refused URL or Serves save, drawn whole under the row. Display text with no press action. Read, not pressed — 3b-viii-local-provider-add.jsonl asserts `baseURL must be an http or https URL, e.g. http://127.0.0.1:8012; got "ftp://x"` with the typed ftp://x kept in the field, and its frame clear of the URL field at 1000×888.
- `settings.localProvider.<…>.status` — a Text (3b-viii, Rule 8): a local model's status line — "not tried yet", "reachable", or its last error whole. Display text with no press action. Read, not pressed — 3b-viii-local-provider-add.jsonl and 3b-viii-local-provider-dispatch.jsonl assert "not tried yet"; 3b-viii-ghost-unreachable-editor.jsonl and 3b-viii-ghost-unreachable-query-line.jsonl assert "Could not connect to the server." after a ghost request to http://127.0.0.1:1, and "not tried yet" gone.
- `settings.login.cancel` — #254. Only exists while a browser trip is in flight.
- `settings.login.dismiss` — #254. Drawn only by the states a finished trip reaches — added, refused, cancelled, timedOut, uncertain, failed.
- `settings.login.someoneElse` — #254. Starts a fresh trip, and only appears when the config dir is already signed in, which itself needs a real credential.
- `settings.login.start` — #254. The control that does the above.
- `settings.mint.stopWaiting` — #254. Only exists while waiting on a live mint.
- `settings.org.<…>.refusal` — a Text (3b-ix, Rule 8): the Ghost-text or Fast path switch's refusal, drawn only when Go refuses the ctx_update_org write the switch itself offers. Go refuses a boolean on the open organisation only when its org.json does not parse, and no fixture or step can corrupt it mid-launch — as for settings.editor.wordWrap.refusal. Display text with no press action.
- `settings.org.git.account.<…>.note` — a Text (3a-iii, Rule 8): an account card's Test result or Remove refusal. Read, not pressed — 3a-iii-git-accounts.jsonl asserts "Wakil cannot test a token on e2ehost; it is used on the next fetch" after the card's Test.
- `settings.org.git.account.<…>.test.cancel` — the card's Cancel while a Test runs (3a-iii, Rule 4): a control that exists only while a Test is in flight, and every Test the fixture can make ends at once — a token on a host Wakil cannot test is refused before any network, and an ssh account's host does not resolve. Holding a Test open would need an ssh host that accepts and never answers, which the fixture does not serve. The Test itself is 3a-iii-git-accounts.jsonl's; a slow Test against a real host is walk-only.
- `settings.org.git.account.add.connected` — a Text (3a-iii): the Connected step's title. Read, not pressed — 3a-iii-git-accounts.jsonl asserts the step's subtitle ("… now use this account on e2ehost.").
- `settings.org.git.account.add.copy` — Copy in the SSH step (3a-iii): its whole effect is a string on the SYSTEM PASTEBOARD, which no check can read, and its "Copied" title is a button label the tree does not carry — api.recent.<…>.curl's case. What it copies is the public key the step draws, which 3a-iii-git-accounts.jsonl reads (`ssh-ed25519`, the key's comment); pasting it into a host is the runbook's row 8.
- `settings.org.git.account.add.deviceCode` — a Text (3a-iii): Sign in's code, drawn only while Sign in waits, which has no control in this build (ctx_git_device_poll's case).
- `settings.org.git.account.add.gh.<…>` — the GitHub CLI login choice (3a-iii): drawn only when `gh auth status` on this Mac holds a login, which a fixture could hold only with the operator's real token (ctx_git_gh_import's case).
- `settings.org.git.account.add.hostTaken` — a Text (3a-iii): "<host> is connected already…". Read, not pressed — 3a-iii-git-accounts.jsonl asserts it for e2ehost.
- `settings.org.git.account.add.message` — a Text (3a-iii, Rule 8): the Connect sheet's message. Read, not pressed — 3a-iii-git-accounts.jsonl and 3a-iii-git-account-parity.jsonl assert "Wakil cannot test a token on …; the next fetch will."
- `settings.org.git.account.add.openDevice` — Open <host> in Sign in (3a-iii): drawn only while a device code is shown, and Sign in has no control in this build (ctx_git_device_poll's case); its effect would leave the window besides.
- `settings.org.git.account.add.openKeys` — Open <provider>'s SSH keys page (3a-iii): pressing it opens the operator's browser at the provider's settings page — the act's whole effect leaves the window, and nothing the check could read changes. Offered only for GitHub, GitLab and Bitbucket; the runbook's row 8 presses it.
- `settings.org.git.account.add.openTokens` — Create a token on <provider> (3a-iii): pressing it opens the operator's browser at the provider's token page — the act's whole effect leaves the window (settings.org.git.account.add.openKeys' case). The token step it sits in is 3a-iii-git-accounts.jsonl's (Bitbucket's username, a pasted token, Connect).
- `settings.org.git.account.add.publicKey` — a Text (3a-iii): the generated public key, selectable, with no press action. Read, not pressed — 3a-iii-git-accounts.jsonl asserts `ssh-ed25519` and the key's comment.
- `settings.org.quickProvider.configError` — a Text (3b-viii, Rule 8): why the configuration quick tasks are built from could not be read, drawn only when the config tree read fails. The seed writes a readable organisation and no step can corrupt it mid-launch. Display text with no press action; the error path is pinned by WindowModelQuickTasksTests.
- `settings.org.quickProvider.error` — a Text (3b-viii, Rule 8): the last error of the provider code completion routes to first, drawn whole under the Quick tasks row. Display text with no press action. Read, not pressed — 3b-viii-ghost-unreachable-editor.jsonl holds its frame on the Providers page after Quick tasks is set to a local model on http://127.0.0.1:1 and an editor tab asks.
- `settings.org.quickProvider.note` — a Text (3b-viii): "Ghost-text needs a Claude or local provider", drawn only when neither the chosen quick provider nor the window's running account serves infill. Every fixture launch runs as a claude-code account, which always serves infill, and no step can make a window run as another kind mid-launch. Display text with no press action; quickTaskNote is pinned by QuickTaskSettingsTests.
- `settings.org.quickProvider.refusal` — a Text (3b-viii, Rule 8): drawn only when Go refuses a Quick tasks segment the row itself offers, i.e. a provider gone between draw and press. Measured on this branch: an unlink (ctx_unlink_provider) re-reads the pane and the segment is gone before any press can reach it (3b-viii-quick-provider-unlinked.jsonl), so no step can press a stale one. The dispatch refusal of an unknown id is asserted by 3b-viii-quick-provider.jsonl.
- `settings.org.quickProvider.route` — a Text (3b-viii): "Code completion goes to <provider>", drawn under the Quick tasks row once quick tasks are built. Display text with no press action; its wording is pinned by QuickTaskSettingsTests.quickTaskRouteLineNamesTheProviderCodeCompletionGoesTo.
- `settings.org.speechProvider.note` — a Text: the Speech row's "unknown engine 'x', using Apple". Read, not pressed — 2d-ii-settings-speech.jsonl asserts it after a dispatched unknown id and a reload, and its absence after Apple is chosen.
- `settings.pane` — the settings pane's container (.contain, 2026-10-21): the tree, the subject column and its footer, and it takes no input itself. Framed to the width the pane is given, never its content's, so a layout check can hold the page inside it; read by frame, not pressed — 2e-settings-pane.jsonl and 2e-settings-narrow-rows.jsonl hold settings.tree.providers, settings.breadcrumb and settings.section.accounts inside it on the Providers page.
- `settings.projectEditor.heavy.git` — the heavy-folder list's fixed .git row (3b-v part 2): a Text pair (".git", "always") with no press action — .git is always heavy and cannot be edited or removed. Read, not pressed — 3b-v-heavy-folders-edit.jsonl asserts its "always" beside the list.
- `settings.projectEditor.heavy.refusal` — a Text (3b-v part 2, Rule 8): a refused heavy folder's sentence, drawn whole under the list. Display text with no press action. Read, not pressed — 3b-v-heavy-folders-refusal.jsonl asserts the .git, a/b and duplicate sentences in the pane and refuses the same names by dispatch.
- `settings.projectEditor.indent.refusal` — a Text (3b-v, Rule 8): drawn only when Go refuses Spaces or Tabs, which it does only for a project.json filed under another organisation or unreadable — and either one drops the project from the settings tree, so its Editor node draws `gone` instead of this form and the refusal has nowhere to appear. Display text with no press action. 3b-v-project-editor-settings.jsonl drives both choices (Tabs through parity) and asserts each on disk.
- `settings.projects.add.folder` — Open a folder in + Add a project (3a-iii; the tree row did this before 3a-iii): pressing it opens the macOS folder picker (NSOpenPanel), a system panel outside the app's accessibility tree that no step can choose a folder in or cancel — so a press could assert nothing but an open panel left over the run. What it adds is ctx_create_project's, dispatched with the folder as a param by 2e-ii-project-lifecycle.jsonl; the sheet around it (Cancel, Clone a repository, Back) is 3a-iii-add-project-clone.jsonl's; the picker itself is the runbook's rows 1, 2 and 6 (docs/wakil/phase-2e-ii-acceptance.md).
- `settings.projects.clone.change` — Change… in the clone sheet (3a-iii) opens the macOS folder picker (NSOpenPanel), the case of settings.projects.add.folder above: no step can choose a folder in it. The folder it would choose is the organisation's last clone folder by default, which 3a-iii-add-project-clone.jsonl's launch seeds (SeedSpec.CloneFolder) and asserts in the sheet; the picker is the runbook's row 9 (docs/wakil/phase-3a-iii-acceptance.md).
- `settings.projects.clone.error` — a Text (3a-iii, Rule 8): the clone sheet's refusal. Read, not pressed — 3a-iii-add-project-clone.jsonl asserts "No git account for e2ehost in e2e-fixture — add one in Settings → Organisation → Git" and its absence once the sheet closes.
- `settings.projects.clone.folder` — a Text (3a-iii): the folder a clone goes into. Read, not pressed — 3a-iii-add-project-clone.jsonl asserts the seeded `/e2e-clones` in it.
- `settings.quickTasks.about.text` — a Text (3b-ix): the quick tasks ⓘ popover's words, drawn whole. Display text with no press action. Read, not pressed — 3b-ix-quick-tasks-about.jsonl opens the popover from settings.quickTasks.about and asserts "Ask the agent instead", "It never edits, queries or runs commands" and "slower than 0.4 s", then that Esc closes it.
- `settings.receipt` — a Text (2e-ii): what a removal said, drawn on the page it landed on until the operator moves. Display text with no press action. Read, not pressed — 2e-ii-project-lifecycle.jsonl asserts "Removed e2e-renamed from this organisation" and 2e-ii-environment-lifecycle.jsonl "a copy of project.json is in the Trash".
- `settings.row.<…>.reauthenticate` — #254. Goes straight to the browser by design — no confirmation step — so pressing it IS starting a real trip.
- `settings.section.<…>` — a settings page section's hairline (2026-10-21): a Rectangle with no press action, named because it spans the subject column, so a page drawn wider than the pane shows on it. Read by frame, not pressed — 2e-settings-pane.jsonl and 2e-settings-narrow-rows.jsonl hold settings.section.accounts inside settings.pane on the Providers page.
- `window.capacity` — the capacity indicator beside ACCOUNT (provider capacity): it has no press action, and it refuses AXFocused (measured 2026-10-10: axresolve not_focusable), because `.focusable(interactions: .activate)` keeps a click from taking the composer's focus (Rule 6) and joins the key loop only with macOS Keyboard navigation on. Its card opens on hover or on that focus, and the vocabulary has no hover step, so opening the card is walk-only. What it draws is read by capacity-at-launch.jsonl (the launch probe, no turn), capacity-low-reading.jsonl, capacity-passed-reset.jsonl and agent/capacity-after-turn.jsonl.
- `window.closeConversation` — the Close Conversation prompt's container (.contain, conversations, Rule 1): the question and two buttons; it takes focus so Return and Escape keep. Read, not pressed — agent/conversations-close-asks.jsonl asserts its focus and its question; its buttons window.closeConversation.keep / .close are pressed there.
- `window.closeConversation.message` — a Text (conversations, Rule 1): the prompt's question. Read, not pressed — agent/conversations-close-asks.jsonl asserts "Close this conversation? The agent is still working; what it is doing now stops." and its absence after Keep it.
- `window.composer.bar` — the composer bar's container (.contain), which holds the field, the heard text and the hint and takes no input itself. Its contents are read by every 2d-ii voice check; the field inside it is `window.composer`, which they type into.
- `window.composer.heard` — a Text: the words heard while ⌥ is held, or the notice that replaces them. Read, not pressed — 2d-ii-voice-silence.jsonl asserts "Hearing nothing from E2E Microphone" and the words that clear it; 2d-ii-voice-lands-unsent.jsonl and 2d-ii-voice-escape.jsonl assert the words mid-hold.
- `window.composer.hint` — a Text: the bar's hint. Read, not pressed — the keys hint ("TO SPEAK"), the listening hint ("RELEASE TO PUT IT IN THE LINE") and the landed hint ("HEARD · RETURN SENDS · EDIT FIRST") are asserted by the 2d-ii voice checks.
- `window.composer.receipt` — a Text (3b-ix): the fast path's receipt, what ran or the refusal whole. Display text with no press action. Read, not pressed — 3b-ix-fast-path-runs.jsonl asserts "Ran: switch environment to qa" and its frame clear of Ask the agent instead at the window's minimum; 3b-ix-fast-path-refused.jsonl asserts the refusal whole.
- `window.contextLine` — the context line's container (.contain, background agents 4 of 4): it holds the organisation, project and environment segments and takes no input itself — a click lands on a segment. Named so a layout check can hold the agent chips clear of it; read by frame, not pressed — agent/bg-agent-chip-narrow.jsonl and agent/bg-agent-chip-over-landing.jsonl assert the chip `clear` of it at the window's minimum.
- `window.contextLine.branch` — the context line's Branch segment (3a-iv): drawn only while the line is promoted, which is while the pointer hovers it, and no step kind hovers — the resting line is one element whose text the checks read. Its reading IS asserted at rest, `STAGING e2e-portal: main`, then `: topic` after a switch, by 3a-iv-switch-branch-palette.jsonl; the picker it opens is the one the Changes header opens, pressed by 3a-iv-branch-picker.jsonl. Opening it from the line is the runbook's rows 1–2.
- `window.thread` — the thought thread's container (.contain), which takes hits only on its rows and the "earlier" line. Its rows are pressed by 2d-ii-thread-earlier.jsonl as window.thread.row.<id> and window.thread.earlier.

**This section knows nothing about what a machine cannot see.** The visual rulings and the live-provider question stay the operator's, permanently; they are the human section below.

<!-- /machine-walk -->
