# 3d-iii: picture in picture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A video that is playing floats out by itself into macOS's picture-in-picture window when the
operator leaves its tab, its pane, the place or the organisation, or minimises the window. Coming back
brings it into the page. **Restore** in the floating window goes back to that tab. A setting turns it off.

**Architecture:** WebKit's own picture-in-picture, unlocked by one private `WKPreferences` key set by KVC
beside `developerExtrasEnabled`. Every decision is in WakilKit: `BrowserPictureInPicture`, a value-type
state machine. It is told which tab each browser pane shows, whether the window is minimised and which
tab floats. It answers with effects: float, back inline, pause, go to. WakilApp carries those effects out.
A user script in every frame reports which videos play to a message handler. A frame-targeted
`callAsyncJavaScript` calls `webkitSetPresentationMode`. Two private `WKUIDelegate` methods report
floating and Restore. The store learns which tab floats through the existing page report, so
`read_pane` can say it.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, WebKit (`WKUserScript`, `WKScriptMessageHandler`,
`WKContentWorld`, `WKFrameInfo`), the Objective-C runtime (`protocol_getMethodDescription`), Swift Testing;
Go (`internal/wakilcore/browsersettings.go`).

**Spec:** `docs/superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md`. This plan covers its
"Lane B, 3d-iii" section, "How (the spike…)", calls 11 and 14, Interaction rules 1, 6, 8 and 9, and the
picture-in-picture lines of Errors and edges, Testing and Charter changes. The spike's full findings are
in the operator's `.scratch/pip-spike/findings.md` (not committed). Task 1 writes what this plan relies
on into `docs/wakil/3d-iii-pip-probe.md`. Groups, pinning, vertical tabs, identities and passwords
(3d-i, 3d-ii, 3d-iv) are out of scope.

## Rulings

These settle what the spec left open or where it contradicts itself. Each is a **planner's call**.

1. **"Leaving" is a change in which tabs are on screen.** A tab is on screen when its pane is drawn,
   the tab is the pane's active one, the pane is not covered by another pane maximised, and the window
   is not minimised. A tab that leaves that set floats. A tab that enters it while floating comes back
   inline. Focus never enters into it (call 14). Hiding the app (⌘H), another app covering the window,
   and a pane partly overlapped by a floating pane are not leaving. The spec's list is exhaustive.
2. **Closing a pane is closing its tabs, so it floats nothing** (spec contradiction). Call 14 counts "its
   pane closed" as leaving, but Errors and edges says closing a tab whose video floats ends picture-in-
   picture. A closed pane's tabs are released a second later (`BrowserPane`'s `onDisappear`), so a float
   would last one second. The pane reads `isClosed()` when it disappears and passes `closing: true`. The
   floated video would end in a second anyway, so this only spares a flash. A pane whose place
   was switched away still floats.
3. **The newest-playing video floats, across frames and across panes.** Each frame's user script stamps
   a video with `Date.now()` on its `playing` event. On leaving, every candidate frame of every tab that
   left is compared, and only the newest is floated. Minimising with two panes on screen offers both
   panes' active tabs as candidates.
4. **A floating video replaced while its tab is away is paused.** WebKit keeps one picture-in-picture
   window, so when B floats, A goes back inline in a tab nobody sees. Task 1 found WebKit already
   pauses A then, muted or not; the pause stays as a guard that does not depend on it. A video whose
   float ends while its tab is not on screen is paused, unless that end came from Restore. Close in
   the system window already pauses.
5. **Restore puts the web view back synchronously by docking it.** The place may be off screen and the
   SwiftUI pane may not exist when `_webViewFullscreenMayReturnToInline:` arrives. So, inside that call,
   a web view with no window is added to the window's content view, below every sibling, at its last
   page frame. Then `WindowModel.browserReturn(to:)` goes to the place and selects the tab. The pane's
   `BrowserPageHost` moves the view into its own container when it draws (`attach` already removes
   from any superview). If the place cannot be reached, the dock is emptied and the video paused. Task 1
   confirms the dock leaves no blank box and is not seen. Its fallback is `alphaValue = 0`.
6. **Restore finds the place by its scope.** A scope with a `lineageRoot` is a conversation's canvas:
   the live conversation in that place with that `lineageRoot` is switched to
   (`switchToConversation`). Otherwise the place is gone to (`goTo`). Then `browser_select_tab {pane,
   tab, focus: true}`, so the page takes the keyboard. This is Rule 6's named exception. If the screen
   is not on that scope after the switch, nothing is selected, because pane and tab ids repeat from
   place to place.
7. **"Guarded with `responds(to:)`" means three checks**, made once per launch:
   `WKPreferences` instances respond to the setter the KVC key resolves to,
   `_setAllowsPictureInPictureMediaPlayback:` (Task 1: macOS has no `setAllows…:`). WebKit's
   `WKUIDelegatePrivate` protocol, if present, declares `_webView:hasVideoInPictureInPictureDidChange:`
   and `_webViewFullscreenMayReturnToInline:` as optional instance methods. A delegate callback cannot
   be checked with `responds(to:)` on our own object, because WebKit asks us. If any check fails, the
   preference is not set (a KVC set of an unknown key would raise), nothing floats, and Settings shows
   the line in Global Constraints with the missing names.
8. **The setting governs Wakil's automatic float only.** With it **Off**, Wakil floats nothing, but the
   preference stays set. A page's own picture-in-picture button (YouTube's) still works, as in Safari,
   and Restore and coming back behave the same for it. The hint says so.
9. **A float that WebKit refuses is not an error to show.** The operator has left the tab, so there is
   nowhere on screen to put it. The video keeps playing in the page, as before 3d-iii. A systemic
   refusal is ruling 7's line in Settings.
10. **`read_pane` gains `pictureInPicture`**: the id of the pane's tab whose video floats, else `null`.
    It arrives through `BrowserPageReport`, so `reportAll` re-sends it when a place is shown again. It
    is not saved.
11. **The floating tab's web view is never evicted** by the 20-view limit. It moves with
    `rehome`. Releasing it (its tab closed) ends the float: the system window goes with the view, but
    WebKit sends no `false` (Task 1), so `closed` clears the floating tab itself and the drop does not wait.

## Global Constraints

- Platform floor `macOS 14.4`. No new Swift package dependency. Go changes only in
  `internal/wakilcore/browsersettings.go`, its test, `configtree.go` if needed, and `cmd/wakil-ctx/main.go`'s
  args and tool text.
- **Private API, exactly this and no more:** the KVC key `allowsPictureInPictureMediaPlayback` on
  `WKPreferences`; the `WKUIDelegate` methods `_webView:hasVideoInPictureInPictureDidChange:` and
  `_webViewFullscreenMayReturnToInline:`. `webkitSetPresentationMode` is WebKit's prefixed web API,
  called from script. Each Swift use names it private in a comment.
- The candidate rule, verbatim from the spec as amended 2026-10-27: a `<video>` that is `!paused`, or
  was playing by its own events when the page went hidden while the page stays hidden, and `!ended &&
  readyState > 2 && !disablePictureInPicture`. Floated with `webkitSetPresentationMode('picture-in-picture')`,
  then `play()` if paused; brought back with `webkitSetPresentationMode('inline')`. Never `requestPictureInPicture()`.
- Script world `wakil.pip` (`WKContentWorld.world(name:)`); message handler name `wakilPictureInPicture`.
  The page's own script never sees either.
- Setting: `pictureInPicture` in `~/.wakil/settings.json` under `browser`, **on by default**.
- Copy, verbatim:
  - Settings → Browser: a section `Picture in picture`, choice row `Picture in picture` with `On` and `Off`.
    Hint: `A playing video floats in its own window when you leave its tab, its pane, the place or the
    organisation, or minimise the window. Off, Wakil floats nothing; a page's own picture-in-picture
    button still works.`
  - Unavailable (ruling 7): `Picture in picture is off: this Mac's WebKit has no <names, joined by ", ">
    — Wakil floats a video only through them.`
- Accessibility identifiers: `settings.browser.pictureInPicture` (the row), `settings.browser.pictureInPicture.on`,
  `settings.browser.pictureInPicture.off`, `settings.browser.pictureInPicture.refusal`,
  `settings.browser.pictureInPicture.unavailable`.
- No new action. `read_pane` gains `pictureInPicture` (ruling 10); `ctx_set_browser_settings` gains a field.
- **3d-i runs in parallel** and changes `BrowserSnapshot.swift`, `browsersettings.go`, `BrowserSettingsForm.swift`,
  the tab strip and the charter. Touch the first three only where this plan says, and never touch the tab
  strip (`BrowserPaneHeader.swift`'s strip, `PaneTabStrip`). Whoever lands second rebases. Task 8
  says how the charter text rebases.
- Fixture pages use loopback only. Nothing committed names a home path or a real organisation. Use
  `example.com` and `initech`.
- No `Co-Authored-By` or "Generated with" lines in commits.

## Review Focus

1. **Restore into a place that cannot be reached.** A refused organisation switch must not select a
   tab of the same id in the place on screen, since `browser-1`/`t1` repeat. Pinned in Task 4's
   `returnToAPlaceThatCannotBeReachedSelectsNothing`.
2. **A replaced video playing unseen.** When a second video floats, the first must be paused if its tab
   is away. Pinned in Task 3's `aVideoReplacedWhileItsTabIsAwayIsPaused` and
   `aRestoredVideoIsNotPaused`.
3. **Floating when it shouldn't.** Focus moving to another pane, the setting Off, or a pane closing
   must float nothing. Pinned in Task 3's `focusAloneFloatsNothing`, `nothingFloatsWhileDisabled` and
   `aClosingPaneFloatsNothing`. The Cover rung's check presses into another pane and expects
   `pictureInPicture` null (Task 8).
4. **A conversation adopting the canvas while a video floats.** The operator types to the agent while
   watching, so the place is renamed (`rehome`) and Restore and coming back must still find the tab.
   Pinned in Task 3's `aRehomedPlaceKeepsItsFloatingTab`.
5. **Minimise and back.** Every on-screen tab is a candidate on minimise, and the floating one comes
   back on deminiaturise even though no pane changed. Pinned in Task 3's
   `minimisingOffersEveryShownTabAndRestoringBringsTheFloatingOneBack`.

---

### Task 1: Probe — the spike's untested edges, before anything builds on them

**Files:**
- Modify: `e2e/driver/pagestub_test.go` (`TestPageStubServesTheClipAsVideo`)
- Create: `e2e/fixtures/pages/clip.mp4` (H.264, 320×180, 6 s, a different solid colour each second,
  made with `AVAssetWriter`), `e2e/fixtures/pages/video.html`, `e2e/fixtures/pages/video-frame.html`,
  `e2e/fixtures/pages/two-videos.html`
- Create: `docs/wakil/3d-iii-pip-probe.md` (findings)
- Scratch, never committed: `.scratch/pip-probe/` (the harness and the clip generator)

**Interfaces:**
- Produces fixture pages later checks use:
  - `video.html`: `<video id="v" src="clip.mp4" muted autoplay loop playsinline>`, title `Video`. `?paused=1`
    drops `autoplay`. The page's own script sets `document.title` to `Video · floating` on
    `enterpictureinpicture` and back to `Video` on `leavepictureinpicture`.
  - `video-frame.html`: title `Framed video`, an `<iframe>` of `video.html` on the **other** loopback name
    (`http://localhost:<same port>/video.html` from `127.0.0.1`, or the reverse), so it is cross-origin.
  - `two-videos.html`: videos `first` and `second`. `second` starts 1 s after `first`. The title becomes
    `Floating: <id>` on either's `enterpictureinpicture`.
- Produces findings Tasks 5–6 rely on, each recorded in the probe doc as **confirmed** or **changed to …**.

- [ ] **Step 1: Make the clip and the pages.** Generate `clip.mp4` with a throwaway Swift script in
  `.scratch/pip-probe/`. Check that it is under 200 KB. The e2e page stub (`e2e/driver/pagestub.go`, an
  `http.FileServer`) must answer `Content-Type: video/mp4` and honour `Range`. Check it with a 5-line Go
  test beside `pagestub.go`, `TestPageStubServesTheClipAsVideo`, which is committed.
- [ ] **Step 2: Build the harness** in `.scratch/pip-probe/`: a one-window AppKit app with one
  `WKWebView` per tab, swapped in and out of a container the way `BrowserPageHost` does. Give it the
  KVC preference, the `wakil.pip` user script and handler of Task 5, and the two private delegate methods
  logging. Serve the pages with `python3 -m http.server` from `e2e/fixtures/pages` on 127.0.0.1.
- [ ] **Step 3: Answer each question and record it.** Press the system window's buttons with AXPress,
  as the spike did. Expected answers are this plan's assumptions:

  | # | Question | Plan assumes |
  |---|---|---|
  | a | Closing a tab whose video floats: the view `stopLoading`, `removeFromSuperview`, released. Does the window go, and does `hasVideoInPictureInPictureDidChange:false` arrive? | Window goes. If it lingers, `release` must await the inline script before dropping (ruling 11) (answered: it does not linger; see ruling 11) |
  | b | `video-frame.html`: the handler's message carries the iframe's `WKFrameInfo`. Does `callAsyncJavaScript(…, in: thatFrame, in: wakil.pip)` float the cross-origin video with no gesture? | Yes |
  | c | `two-videos.html`: does the per-frame `Date.now()` stamp pick `second`? Then a second tab's video floats while the first's floats: does the first get `false` and go on playing inline? | Yes, and yes: hence ruling 4's pause |
  | d | Can a script in the isolated world `wakil.pip` call `webkitSetPresentationMode` (the spike's ran in another world)? | Yes. Fallback `.defaultClient` |
  | e | Which setter does the KVC key resolve to on `WKPreferences`? Does `NSProtocolFromString("WKUIDelegatePrivate")` declare both delegate selectors? | Recorded verbatim for ruling 7 |
  | f | Restore while the view has no window: added to the content view below every sibling, inside the hook, then moved into a container 0.5 s later. Does the video play inline, with no blank box, and is the docked view unseen? | Yes; else `alphaValue = 0` |
  | g | A page's own PiP (`requestPictureInPicture()` from a click in the page) reports through the same delegate methods | Yes |

- [ ] **Step 4: Rule on any changed answer.** An answer that contradicts the **spec** becomes a dated
  amendment section in the spec file, with its body edited (workflow.md's rule). An answer that only
  changes a **ruling** here is a one-line edit to that ruling in this plan, named in the commit body.
- [ ] **Step 5: Commit** the clip, the three pages, the probe doc and any spec or plan edit:
  `probe: 3d-iii picture in picture's untested edges`.

### Task 2: The `pictureInPicture` setting

**Files:**
- Modify: `internal/wakilcore/browsersettings.go`, `internal/wakilcore/browsersettings_test.go`
- Modify: `cmd/wakil-ctx/main.go` (`setBrowserSettingsArgs`, the `browser_settings` and
  `set_browser_settings` descriptions, the patch built in the handler)
- Modify: `app/Sources/WakilKit/Panes/SettingsTree.swift` (`SettingsBrowser`),
  `app/Sources/WakilKit/Registry/StandardActions.swift` (`ctx_set_browser_settings`'s schema and description),
  `app/Sources/WakilKit/MCP/PermissionPrompt.swift` (the refusal's sentence names picture in picture too)
- Test: `app/Tests/WakilKitTests/BrowserActionsTests.swift` (decode)

**Interfaces:**
- Produces: Go `BrowserAppSettings.PictureInPicture *bool \`json:"pictureInPicture,omitempty"\`` (nil is
  the default, on, as `EditorAppSettings.GhostText`), `BrowserSettings.PictureInPicture bool
  \`json:"pictureInPicture"\``, `BrowserSettingsPatch.PictureInPicture *bool`. Swift
  `SettingsBrowser.pictureInPicture: Bool` (default `true`, `decodeIfPresent`), with
  `init(searchEngine:startPage:searchSuggestions: Bool = false, pictureInPicture: Bool = true)`.

- [ ] **Step 1: Write the failing tests.** Go: `TestBrowserSettingsPictureInPictureDefaultsOn` (no key
  → `true`), `TestWriteBrowserSettingsPictureInPictureOffKeepsOtherKeys` (writing `false` keeps
  `searchEngine`, `searchSuggestions` and the `editor` key, and reads back `false`), and
  `TestWriteBrowserSettingsPictureInPictureOnlyIsNotANoOp` (a patch with only this field writes).
  Swift: `browserSettingsDecodePictureInPicture` (`{}` → `true`; `{"pictureInPicture": false}` → `false`).
- [ ] **Step 2: Run them to see them fail:** `go test ./internal/wakilcore -run PictureInPicture` and
  `make app-test`. Expected: they fail to compile.
- [ ] **Step 3: Implement** the field through resolve, patch, the no-op guard and write. Tool text:
  `pictureInPicture (true or false; on by default — a playing video floats when you leave its tab)`.
- [ ] **Step 4: Run them to see them pass:** `make build && go test ./internal/wakilcore && make app-test`.
- [ ] **Step 5: Commit** `browser: the picture-in-picture setting, on by default`.

### Task 3: The state machine (pure)

**Files:**
- Create: `app/Sources/WakilKit/Browser/BrowserPictureInPicture.swift`
- Test: `app/Tests/WakilKitTests/BrowserPictureInPictureTests.swift`

**Interfaces:**
- Produces:
  - `public struct BrowserTabRef: Hashable, Sendable { public let scope: LayoutScope; public let pane: String;
    public let tab: String; public init(scope:pane:tab:) }`
  - `public struct BrowserPictureInPicture: Sendable, Equatable` with
    - `public enum Effect: Sendable, Equatable { case float([BrowserTabRef]) /* candidates; the host floats
      the newest-playing among them */; case inline(BrowserTabRef); case pause(BrowserTabRef); case goTo(BrowserTabRef) }`
    - `public var enabled: Bool` (the setting and support, set by the host before each call)
    - `public private(set) var floating: BrowserTabRef?`, `public private(set) var minimized: Bool`
    - `public init(enabled: Bool = true)`
    - `public func isShown(_ ref: BrowserTabRef) -> Bool`
    - `public mutating func show(scope: LayoutScope, pane: String, tab: String?) -> [Effect]`: the pane is
      on screen showing `tab` (nil: none). It is called on every sync, so the same tab again yields `[]`.
    - `public mutating func hide(scope: LayoutScope, pane: String, closing: Bool) -> [Effect]`
    - `public mutating func setMinimized(_ on: Bool) -> [Effect]`
    - `public mutating func didChange(_ ref: BrowserTabRef, floating on: Bool) -> [Effect]`
    - `public mutating func restore(_ ref: BrowserTabRef) -> [Effect]`, which answers `[.goTo(ref)]`
    - `public mutating func restoreEnded(_ ref: BrowserTabRef, reached: Bool) -> [Effect]`
    - `public mutating func closed(_ ref: BrowserTabRef) -> [Effect]`, which clears `floating` when
      `ref` floats and answers `[]` (the released view ends the float; ruling 11)
    - `public mutating func rehome(from: LayoutScope, to: LayoutScope)`
    - `public static func unavailableLine(missing: [String]) -> String?`, which is nil for `[]` and
      otherwise the Global Constraints copy

- [ ] **Step 1: Write the failing tests** (two scopes `here`/`there` of org `initech`, panes `browser-1`,
  `browser-2`):
  `leavingATabFloatsIt` (show t1 → show t2 → `[.float([t1])]`);
  `comingBackBringsTheFloatingTabInline` (after `didChange(t1, true)`, show t1 → `[.inline(t1)]`);
  `comingBackToATabThatIsNotFloatingDoesNothing`;
  `focusAloneFloatsNothing` (show t1 twice → `[]`);
  `aPlaceSwitchFloatsTheTabsItHid` (hide `here`'s pane, closing false → `[.float([t1])]`);
  `aClosingPaneFloatsNothing` (closing true → `[]`);
  `aMaximisedPaneCoveringFloatsAndUncoveringReturns` (hide, then show again → `.inline` once floating);
  `nothingFloatsWhileDisabled` (enabled false: every call yields no `.float`, but `.inline` still comes);
  `minimisingOffersEveryShownTabAndRestoringBringsTheFloatingOneBack` (two panes shown →
  `setMinimized(true)` → `[.float([b1t1, b2t3])]` in pane order; `didChange(b2t3, true)`;
  `setMinimized(false)` → `[.inline(b2t3)]`);
  `nothingIsShownWhileMinimised` (show while minimised yields `[]`);
  `aVideoReplacedWhileItsTabIsAwayIsPaused` (t1 floats, t1 hidden, then `didChange(t1, false)` → `[.pause(t1)]`);
  `aFloatThatEndsOnScreenIsNotPaused`;
  `aRestoredVideoIsNotPaused` (`restore(t1)` → `[.goTo(t1)]`, then `didChange(t1, false)` → `[]`);
  `aRestoreThatCannotArrivePausesIt` (`restoreEnded(t1, reached: false)` → `[.pause(t1)]`; `true` → `[]`);
  `closingTheFloatingTabClearsIt` (`closed(t1)` → `[]`, then `floating == nil`);
  `aRehomedPlaceKeepsItsFloatingTab` (floating and shown under `here`, `rehome(here → there)`, then show
  `there`'s t2 → `[.float([there t1])]`, and `floating?.scope == there`);
  `theUnavailableLineNamesWhatIsMissing` (the exact copy for two names; nil for none).
- [ ] **Step 2: Run them to see them fail:** `make app-test`. Expected: `BrowserPictureInPicture` is undefined.
- [ ] **Step 3: Implement.** One map `[PaneKey: String]` (pane → shown tab) plus `floating`,
  `minimized` and a `restoring: Set<BrowserTabRef>`, cleared by its `didChange(…, false)` or
  `restoreEnded`. `.float` only when `enabled` and not minimised. A `.float` list is sorted by pane id
  for determinism.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: picture in picture's rules, as a state machine`.

### Task 4: The store reports the floating tab; Restore goes back

**Files:**
- Modify: `app/Sources/WakilKit/Browser/BrowserSnapshot.swift` (`BrowserPageReport.pictureInPicture`,
  `BrowserTab.pictureInPicture`, kept out of `CodingKeys`), `PaneStore+Browser.swift`
  (`browserPageDidReport` copies it), `BrowserPaneKind.swift` (`readPane`'s `pictureInPicture`)
- Modify: `app/Sources/WakilKit/App/WindowModel.swift` (`browserReturn(to:)`, beside `browserChooseTab`)
- Test: `app/Tests/WakilKitTests/BrowserStoreTests.swift`, `WindowModelBrowserTests.swift`

**Interfaces:**
- Consumes: `BrowserTabRef` (Task 3).
- Produces:
  - `BrowserPageReport.init(…, zoom: Double? = nil, pictureInPicture: Bool = false)`; `BrowserTab.pictureInPicture: Bool`
    (default false, not encoded, not in `BrowserSavedTab`).
  - `read_pane`'s top-level `"pictureInPicture"`: the id of the first tab with `pictureInPicture`, else `null`.
  - `@discardableResult public func browserReturn(to ref: BrowserTabRef) async -> Bool`. It answers
    whether the screen reached `ref.scope` and the tab was selected (ruling 6).

- [ ] **Step 1: Write the failing tests.** In `BrowserStoreTests`:
  `aReportCarriesPictureInPictureIntoReadPane` (a report with `true` → `pictureInPicture == "t1"`; one with
  `false` → `null`); `readPaneAlwaysCarriesPictureInPicture` (`null` on a fresh pane);
  `pictureInPictureIsNeverSaved` (encode a `BrowserTab` with it on → no `pictureInPicture` key; `browserSavedTabs`
  drops it). In `WindowModelBrowserTests`:
  `returnToATabInThisPlaceSelectsItAndFocusesItsPane` (two tabs, t2 active, another pane focused →
  `browserReturn(to: t1)` is true, `active == t1`, the browser pane focused);
  `returnToAPlaceThatCannotBeReachedSelectsNothing` (a ref under org `globex`, which the test context
  refuses → false, and the on-screen pane of the same id keeps its active tab).
- [ ] **Step 2: Run them to see them fail:** `make app-test`.
- [ ] **Step 3: Implement.** `browserReturn` does this: if `browserScope != ref.scope`, find the live
  conversation whose `place` is the ref's place and whose `lineageRoot == ref.scope.lineageRoot`. If
  there is one, `switchToConversation(id)`; otherwise `goTo(Place(organization:project:environment:))`.
  Then `guard browserScope == ref.scope`, else return false. Then `dispatchFromSurface("browser_select_tab",
  {pane, tab, focus: true})`.
- [ ] **Step 4: Run them to see them pass:** `make app-test`.
- [ ] **Step 5: Commit** `browser: read_pane names the floating tab; Restore goes back to it`.

### Task 5: WebKit — the preference, the frames' script and the private callbacks

**Files:**
- Create: `app/Sources/WakilApp/BrowserPictureInPictureSupport.swift`,
  `app/Sources/WakilApp/BrowserPictureInPictureScript.swift`
- Modify: `app/Sources/WakilApp/BrowserTabHost.swift` (`configuration(files:)` → `configuration(files:handler:)`),
  `app/Sources/WakilApp/BrowserWebView.swift` (`BrowserTabDelegate`)

**Interfaces:**
- Produces:
  - `enum BrowserPictureInPictureSupport { static let preferenceKey = "allowsPictureInPictureMediaPlayback";
    static let missing: [String] /* computed once, ruling 7, names as the selectors read */; static var available: Bool }`
  - `enum BrowserPictureInPictureScript { static let world: WKContentWorld /* "wakil.pip" */;
    static let handlerName = "wakilPictureInPicture"; static func userScript() -> WKUserScript /* at document
    end, every frame, in world */; static let enter: String; static let inline: String; static let pause: String }`
  - The user script assigns its frame a token (`crypto.randomUUID()`) and listens in the capture phase on
    `document` for `play`, `playing`, `pause`, `ended`, `emptied`, `visibilitychange` (the hidden-time
    snapshot, cleared on visible and on `enter`/`leavepictureinpicture`) and `pagehide`. It also scans once at
    injection, for a video already playing. On each it posts `{frame: String, playing: Bool, since:
    Number}` for the frame's newest qualifying video (`since` from its `playing` stamp, an expando set in
    this world). `enter` floats the frame's newest qualifying video (hidden-time snapshot candidates count, per the
    amended candidate rule), calls `play()` on it if it is paused, and returns whether it did. `inline`
    sends back every video whose `webkitPresentationMode` is `'picture-in-picture'`. `pause` pauses every
    playing video.
  - `BrowserTabDelegate` gains `var pictureInPicture = false`, carried in every report, and two private
    callbacks, each commented as private:
    `@objc(_webView:hasVideoInPictureInPictureDidChange:) func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange on: Bool)`
    sets the flag, reports, and tells `host?.pictureInPicture.didChange(key, on)`.
    `@objc(_webViewFullscreenMayReturnToInline:) func webViewFullscreenMayReturnToInline(_ webView: WKWebView)`
    calls `host?.pictureInPicture.restore(key, view:)`. It is synchronous (Task 6). Both ignore a tab of `""`.
  - A main-frame `didCommit` clears the tab's frame candidates (`host?.pictureInPicture.forgetFrames(key)`).

- [ ] **Step 1: Write the support check and the scripts** to the Interfaces and Global Constraints'
  candidate rule. In `configuration`, set the preference with `setValue(true, forKey:)`, add the user
  script and add the handler (`userContentController.add(_:contentWorld:name:)`), **only when
  `available`**. The handler is a weak proxy to the host, so the controller does not retain the host. A
  pop-up keeps WebKit's copy of its opener's configuration and is not configured again.
- [ ] **Step 2: Build:** `make build`. Expected: success. These are WebKit seams with no WakilKit logic.
  Task 1's harness proved them, and the Cover rung's checks exercise them (Task 8).
- [ ] **Step 3: Commit** `browser: WebKit's picture in picture, guarded — the preference, every frame's
  script, the private callbacks`.

### Task 6: The window carries out the effects

**Files:**
- Create: `app/Sources/WakilApp/BrowserPictureInPictureHost.swift`
- Modify: `app/Sources/WakilApp/BrowserTabHost.swift` (`let pictureInPicture`, `evictBeyondLimit`
  skips the floating key, `rehome` forwards, `release(scope:pane:tab:)` applies `closed` before `drop` without waiting,
  `key(of: WKWebView) -> Key?`), `app/Sources/WakilApp/BrowserPane.swift` (`isCovered`, show and hide
  calls, `BrowserPageHost`'s container records the window), `app/Sources/WakilApp/Canvas.swift` (passes
  `isCovered`)

**Interfaces:**
- Consumes: Task 3's machine and effects, Task 4's `browserReturn(to:)` and `browserSettings.pictureInPicture`,
  Task 5's scripts and callbacks.
- Produces `@MainActor final class BrowserPictureInPictureHost: NSObject, WKScriptMessageHandler`:
  - `init(host: BrowserTabHost)`; `weak var window: NSWindow?`. Setting it observes that window's
    `didMiniaturizeNotification` and `didDeminiaturizeNotification` and calls `setMinimized`.
  - `func show(scope: LayoutScope, pane: String, tab: String?)`, `func hide(scope: LayoutScope, pane: String, closing: Bool)`
  - `func didChange(_ key: BrowserTabHost.Key, _ on: Bool)`, `func restore(_ key: BrowserTabHost.Key, view: WKWebView)`
  - `func closed(_ key: BrowserTabHost.Key)` (synchronous), `func rehome(from: LayoutScope, to: LayoutScope)`, `func forgetFrames(_ key: BrowserTabHost.Key)`
  - `var floatingKey: BrowserTabHost.Key?`
  - Each entry point sets `machine.enabled = (model?.browserSettings.pictureInPicture ?? true) &&
    BrowserPictureInPictureSupport.available`, calls the machine and applies the effects.
    - `.float(refs)`: read each ref's live view's frame candidates (`[token: (WKFrameInfo, since)]`) and
      run `enter` in the newest. If that returns false or throws, try the next newest. Nothing playing
      means nothing happens (ruling 9).
    - `.inline(ref)`: run `inline` in every known frame of the view, and in its main frame.
    - `.pause(ref)`: run `pause` in the same frames.
    - `.goTo(ref)`: synchronously, if the view has no window, dock it (ruling 5). Then start a `Task`
      that awaits `model.browserReturn(to:)`. The task calls `restoreEnded(ref, reached:)`. If the view
      is still docked after it, it is taken out of the dock.

- [ ] **Step 1: Build the host class** to the Interfaces. Use Task 1's recorded answer for the dock
  (below siblings, or `alphaValue = 0`) and ruling 11 (`closed` runs before the drop, without awaiting).
- [ ] **Step 2: Wire the pane.** `BrowserPane` gains `let isCovered: Bool`.
  - At the end of `sync`, when `!isCovered`: `host.pictureInPicture.show(scope:pane:tab: now.active)`.
  - `onAppear` already syncs.
  - `onDisappear`: `hide(…, closing: isClosed())`, read at once (ruling 2), before the existing delayed release.
  - `.onChange(of: isCovered)`: when true, `hide(…, closing: false)`; when false, `show` with the active tab.
  - `Canvas` passes `isCovered: model.layoutSnapshot.maximizedId.map { $0 != pane.id } ?? false`.
  - `BrowserPageHost`'s container is a small `NSView` subclass whose `viewDidMoveToWindow` sets
    `pictureInPicture.window`. It takes a `onWindow: (NSWindow) -> Void` closure, so the host needs no
    pane reference.
- [ ] **Step 3: Build:** `make build`. Expected: success.
- [ ] **Step 4: Check the rules on paper** and write each in the commit body:
  - Rule 6: only Restore moves the operator. Coming back inline takes nothing, and a float keeps the
    keyboard where it was.
  - Rule 1: nothing asks.
  - Rule 9: on by default.
  - Call 14: nothing calls `show` or `hide` on a focus change.
- [ ] **Step 5: Commit** `browser: a playing video floats when you leave it and comes back when you return`.

### Task 7: Settings → Browser

**Files:**
- Modify: `app/Sources/WakilApp/BrowserSettingsForm.swift` (a `Picture in picture` section between Search
  and Browsing data), `app/Sources/WakilApp/SettingsPane.swift:1038` (passes the unavailable line)

**Interfaces:**
- Consumes: `SettingsBrowser.pictureInPicture`, `BrowserPictureInPicture.unavailableLine(missing:)`,
  `BrowserPictureInPictureSupport.missing`.
- `BrowserSettingsForm` gains `let pictureInPictureUnavailable: String?`.

- [ ] **Step 1: Add the row**, a `ChoiceSettingRow` shaped like `Search suggestions`, with the Global
  Constraints' label, options, hint and identifiers. Save with `save(["pictureInPicture": .bool(option == "On")])`.
  When `pictureInPictureUnavailable` is non-nil, draw it under the row in full, in `caution`, with
  `fixedSize(horizontal: false, vertical: true)` (Rule 8). The choice still saves, since the setting is
  the operator's.
- [ ] **Step 2: Build:** `make build`. Expected: success.
- [ ] **Step 3: Commit** `settings: picture in picture on or off, and why it is off when WebKit can't`.

### Task 8: Docs, the acceptance walk, and the hand-off to Cover

**Files:**
- Modify: `docs/architecture/wakilapp.md` (the browser paragraph: `BrowserPictureInPictureHost`, the
  script world, the private callbacks, the dock), `docs/architecture/wakilkit.md` (`### Browser/`:
  `BrowserPictureInPicture.swift`)
- Modify: `docs/wakil/north-star.md` §8, `docs/wakil/decisions.md`, `docs/wakil/design-language.md` §11's
  Browser row, each with only a short addition (Step 1)
- Create: `docs/wakil/phase-3d-iii-acceptance.md`

- [ ] **Step 1: Rebase, then the charter.** `git fetch origin && git rebase origin/main`.
  - **If 3d-i has merged**, its `3d` rows, Decision 49 and Browser row are on main. Then:
    - Mark the `3d-iii` row with what was built.
    - Add one sentence to Decision 49 naming what this plan settled: the KVC key, the two delegate
      selectors, the guard, the dock.
    - Add one sentence to the Browser row: *a playing video floats into the system's picture-in-picture
      window when you leave it, and Restore goes back*.
  - **If 3d-i has not merged**:
    - Add only a `| **3d-iii** | Picture in picture | — | 3c-i |` row after 3c-iii.
    - Add the same one sentence to today's Browser row.
    - Write no decision. Decision 49 is 3d-i's, and the PR description says so.
  - Keep north-star within its word budget (it already fails at 4334/4000): replace words, don't add.
- [ ] **Step 2: Write the acceptance doc**, shaped like `phase-3c-iii-acceptance.md`: Spec and Plan
  links, the exit criterion, `## 0. Setup` (`make build && make app-bundle`, then
  `WAKIL_ORG=personal app/Wakil.app/Contents/MacOS/Wakil`), `## 1. The walk` with the ten rows below and
  an empty Walked column, `## 2. Known and not fixed` (a video in a shadow root is not found; ⌘H does not
  float; any probe residue), and `## 3. The machine walk` with the two markers from `workflow.md`, empty.

  | # | Do | Expect |
  |---|---|---|
  | 1 | Play a YouTube video, then ⌘T | It floats with no click into the system window. Drag it to a corner and resize it; Play/Pause and ±10 s work |
  | 2 | Select the video's tab again | The video is back in the page, playing, with no blank box, and the system window is gone |
  | 3 | Pause it, then ⌘T; then let a short video end and ⌘T | Neither floats |
  | 4 | With it playing, switch environment, then project, then organisation (⌘⇧O) | It floats each time. **Restore** brings you back to that organisation, place, pane and tab, with the page taking the keyboard |
  | 5 | ⌘⏎ another pane to maximise it, then ⌘⏎ again. Then click into another pane while the video shows | It floats when covered and comes back when uncovered. A click elsewhere floats nothing |
  | 6 | ⌘M the window, then bring it back from the Dock | It floats on minimise and comes back on return |
  | 7 | Float it, press **Close** in the system window, and go back. Float another, ⌘W its tab. Close a pane whose video plays | The first is paused in its tab. The second's window goes. The pane's close shows no window, not even briefly |
  | 8 | A page with an embedded YouTube player (cross-origin), then a second tab's video started after the first's | The embedded one floats. When the second floats, the first is paused in its tab, not playing unseen |
  | 9 | ⌘, → Browser → **Picture in picture: Off**, then leave a playing video; use YouTube's own PiP button; set **On** again | Nothing floats on its own. The page's own button still works |
  | 10 | Float a video, then send the agent a first message in that place (the canvas becomes the conversation's), then **Restore** | Restore still lands on the tab |

- [ ] **Step 3: Run** `make build && make test && make app-test`. Expected: green except the known
  north-star word count, unchanged or lower.
- [ ] **Step 4: Commit** `docs: 3d-iii`.
- [ ] **Step 5: Hand the branch to the e2e auditor (Cover).** In `e2e/checks/seeded/`, it should check
  through `read_pane`'s `pictureInPicture` and the fixture titles:
  - `video.html`, ⌘T → `t1`; select t1 → `null`.
  - `?paused=1` → `null`.
  - The setting Off → `null`.
  - A click into another pane → `null`.
  - An environment switch (`staging` → `qa` → `staging`): `null` after the return.
  - `video-frame.html` floats.
  - `two-videos.html`'s title reads `Floating: second`.
  - The settings row's On/Off and focus kept.

  Restore, Close, drag and resize are the system window's and stay walk-only, so they belong in the
  residue. **Ask the operator before using the screen.**

---

## Self-review

- **Spec coverage:**
  - Lane B's bullets map to Tasks 3 (rules), 6 (wiring) and 7 (setting).
  - "How": the preference, every frame, no gesture, Restore synchronous, the callbacks, inline on
    return and the guard map to Tasks 5–6, with ruling 7 for the guard.
  - Call 11 is the whole plan. Call 14 is ruling 1 and Task 3's tests.
  - Rule 6's exception is ruling 6. Rule 8 is Task 7. Rule 9 is Task 2.
  - Errors and edges (tab closed, two videos, cross-origin frame) are Task 1, then rulings 3, 4 and 11.
  - Testing's e2e line is Task 8 Step 5. Its walk line is acceptance rows 1 and 4.
  - Charter is Task 8 Step 1.
- **Gaps found and ruled:** pane-close contradiction (ruling 2); `responds(to:)` cannot check a delegate
  callback (ruling 7); what Off means for a page's own PiP button (ruling 8); a refused float (ruling 9);
  the replaced video playing unseen (ruling 4); Restore into an off-screen place (rulings 5, 6).
- **Types:** `BrowserTabRef`, `BrowserPictureInPicture.Effect`, `browserReturn(to:)`,
  `BrowserPictureInPictureHost`, `BrowserPictureInPictureSupport.missing` and `available` are spelled
  the same in Tasks 3–7.
