# 3d-iii Task 1: the picture-in-picture probe

The spike (2026-10-27) left edges untested. This probe answers them before Tasks 5 and 6 build on
them. Each answer is **confirmed** (the plan's assumption holds) or **changed to …**.

## How it ran

- macOS 27.0.1, Swift 6.4, an unsigned throwaway `.app` (not committed): one window, one `WKWebView`
  per tab with its own configuration, swapped in and out of an opaque container the way
  `BrowserPageHost` does. "Leaving" a tab is emptying the container, as a pane does.
- Every configuration: the KVC preference `allowsPictureInPictureMediaPlayback`, Task 5's user script
  at document end in every frame in `WKContentWorld.world(name: "wakil.pip")`, the handler
  `wakilPictureInPicture` in that world, and the two private delegate methods logging.
- Pages: `video.html`, `video-frame.html`, `two-videos.html` and `clip.mp4` from `e2e/fixtures/pages`,
  served by `python3 -m http.server` on 127.0.0.1. One extra page with an audible clip was served
  from the scratch folder only to tell muted from audible behaviour.
- Nothing touched the mouse or keyboard. Floats ran through `callAsyncJavaScript` in the frame and
  world; the system window's buttons were pressed with `AXUIElementPerformAction(kAXPressAction)`
  on the `Picture in Picture` process's window (identifiers `close`, `restore`, `skip-back`,
  `pause`/`play`, `skip-forward`). The window is that process's, at layer 19; the app also gets an
  invisible `PIPPanel`.

## Answers

| # | Question | Answer |
|---|---|---|
| a | Closing a tab whose video floats | Window goes: **confirmed**. `false` never arrives: **changed to** the host ends the float itself |
| b | Cross-origin iframe floated by frame | **Confirmed** |
| c | Newest stamp; a second tab's float | Stamp picks `second`: **confirmed**. First gets `false`: **confirmed**. Goes on playing: **changed to** WebKit pauses it |
| d | `webkitSetPresentationMode` from `wakil.pip` | **Confirmed** |
| e | The KVC setter and the protocol | **Recorded**: `_setAllowsPictureInPictureMediaPlayback:`; both selectors optional |
| f | Restore with no window, docked | **Confirmed**: below siblings, unseen, plays inline, no blank box |
| g | A page's own `requestPictureInPicture()` | **Confirmed**: the same delegate methods, Restore the same |
| h | (found) A muted or silent video when its view leaves | **Changed to** the amended candidate rule (spec amendment) |

### a. Closing a tab whose video floats

The tab's view was out of the window and floating. Then `stopLoading()`, `removeFromSuperview()`,
dropped. The delegate object was kept alive to hear any callback.

- The system window went at once: no layer-19 window, no `PIPPanel` a second later.
- The view was deallocated (a weak reference was nil 2 s later).
- **`_webView:hasVideoInPictureInPictureDidChange:` with `false` never arrived**, nor
  `_webViewDidExitFullscreen:`.
- The same with `webkitSetPresentationMode('inline')` run and awaited first: the window went and no
  `false` arrived. The inline call returns before the exit, and the drop ends it first.

So the drop does not need to wait for `inline`. It cannot learn the end from WebKit either.
`closed(key)` clears the floating tab itself, synchronously, and the drop follows.
**Ruling 11 changed.**

### b. A cross-origin iframe

`video-frame.html` was loaded from `127.0.0.1` with its iframe on `localhost`. The handler's message
came from a `WKFrameInfo` with `isMainFrame == false` and origin `localhost:<port>`.
`callAsyncJavaScript(enter, in: thatFrame, in: wakil.pip)` floated the iframe's video: the delegate
said `true`, and the frame's `webkitPresentationMode` was `picture-in-picture`. No gesture was used
beyond what `callAsyncJavaScript` carries. **Confirmed.**

Notes for Task 6:

- The iframe's first document (`about:blank`) also ran the script. It posted `scan` under its own
  token with the parent's origin, then `pagehide`.
- A `WKFrameInfo` addresses the **frame**, not the document. Calling with the stale token's frame
  info ran in the frame's current document.
- So the frame table should drop a token on its `pagehide` (`playing: false`), or the same frame is
  asked twice.

### c. Two videos, and a second tab

- `two-videos.html`: `first` was stamped on its `playing`, then `second` 1 s later. `enter` floated
  `second`, and the title became `Floating: second`. **Confirmed.**
- A loop does not re-stamp: after both clips looped twice, the stamps were unchanged.
- Entering picture-in-picture does re-stamp. The floated video fires `pause`, `play` and `playing`,
  so it becomes the newest, which is true.
- Tab T's `second` floated with T away. Then tab U's video floated with U away. T got
  `hasVideoInPictureInPictureDidChange: false` 0.55 s later and went inline: **confirmed**.
- **It did not go on playing.** WebKit paused it (`paused: true`, `currentTime` frozen). It stayed
  paused when its tab was shown again. The same happened with a muted video and with an audible one.

So ruling 4's outcome holds, but WebKit already does it. The host's `.pause` stays as a guard,
because it costs nothing and does not depend on this WebKit. **Ruling 4's rationale changed.**

### d. The isolated world

Every float in this probe ran `webkitSetPresentationMode('picture-in-picture')` from a script in
`wakil.pip`, through `callAsyncJavaScript(…, contentWorld: wakil.pip)`. Every one floated. Globals the
user script set in that world (`globalThis.wakilPip`) were visible to later `callAsyncJavaScript`
calls in the same world and frame. **Confirmed**; `.defaultClient` is not needed.

### e. The setter and the protocol (ruling 7, verbatim)

```
WKPreferences responds(to: setAllowsPictureInPictureMediaPlayback:)  = false
WKPreferences responds(to: _setAllowsPictureInPictureMediaPlayback:) = true
WKPreferences responds(to: _allowsPictureInPictureMediaPlayback)     = true
KVC value(forKey: "allowsPictureInPictureMediaPlayback") after set   = 1
NSProtocolFromString("WKUIDelegatePrivate") = WKUIDelegatePrivate (conforms to WKUIDelegate)
  _webView:hasVideoInPictureInPictureDidChange:  optional instance, types v28@0:8@16B24
  _webViewFullscreenMayReturnToInline:           optional instance, types v24@0:8@16
  (neither is a required method)
```

KVC's `setValue(_:forKey:)` looks for `set<Key>:` and then `_set<Key>:`. On macOS only the second
exists, so the key resolves to **`_setAllowsPictureInPictureMediaPlayback:`**. Ruling 7 checks that
selector. The protocol checks use `protocol_getMethodDescription(p, sel, false, true)`.

### f. Restore while the view has no window

The tab's view was out of the window and floating. Restore was pressed by AXPress. Inside
`_webViewFullscreenMayReturnToInline:` the harness did the following:

1. `contentView.addSubview(view, positioned: .below, relativeTo: nil)` at the last page frame.
2. 0.5 s later, it moved the view into the container (`attach`).

- `hasVideoInPictureInPictureDidChange: false` arrived about 0.55 s after the press, while the view
  was still docked.
- After the move, the video was `inline`, playing and advancing. `requestVideoFrameCallback` counted
  10 presented frames in 1 s, which is the clip's rate.
- A window capture showed the clip's colour in the page: no blank box.
- With the move delayed to 3 s, a capture taken while docked showed only the container's opaque
  background. The docked view was not seen.

**Confirmed.** No `alphaValue = 0` is needed. In Wakil the content view is SwiftUI's hosting view, so
the Cover rung's check still sees this once, in the real window.

### g. A page's own picture-in-picture

`video.html` has a Float button whose click calls `v.requestPictureInPicture()`. The click was
triggered with `evaluateJavaScript("document.getElementById('float').click()")`, in the page world.
`evaluateJavaScript` carries user activation as `callAsyncJavaScript` does. The page floated
(`enterpictureinpicture`, title `Video · floating`), and the same
`_webView:hasVideoInPictureInPictureDidChange: true` and `_webViewDidEnterFullscreen:` arrived.
Restore with the view out of the window called `_webViewFullscreenMayReturnToInline:`. The dock
brought it back inline and playing, and the title returned to `Video`. **Confirmed.**

### h. Found: WebKit pauses a muted or silent video when its view leaves

Not asked, but it decides whether anything floats:

- A playing video that is **muted, or has no audio track** (the fixture clip, a muted video with
  sound), is paused by WebKit the moment its web view leaves the window. The `pause` event lands
  1–2 ms after `removeFromSuperview`.
- Minimising the window does the same. The `pause` event lands 2 ms after
  `NSWindowDidMiniaturizeNotification`.
- WebKit resumes it when the view returns (`play`, `playing`).
- A video playing with sound keeps playing.
- `document.visibilitychange` (to `hidden`) fires first. At that moment `paused` is already `true`,
  but the `pause` event has not yet been dispatched.

With the spec's rule (`!paused && …`), a float works only if `enter` reaches the page before that
pause. It did when `enter` ran in the same run-loop turn as the removal, and also straight from the
`didMiniaturize` observer. It failed every time it ran 0.5 s after the removal, or 1 s after a
minimise: no candidate, nothing floats. Nothing in SwiftUI or AppKit guarantees the earlier timing,
and the e2e fixture clip is silent.

**Changed to** this candidate rule, tested here:

- A `<video>` counts if it is `!paused`, or if it was playing when the page went hidden and the
  page is still hidden. In both cases it must also be `!ended && readyState > 2 &&
  !disablePictureInPicture`.
- "Was playing" is taken from the video's own events: seen `playing`, then no `pause`, `ended` or
  `emptied`. It is snapshotted on `visibilitychange` to hidden, cleared when the page is visible
  again, and cleared on `enterpictureinpicture` and `leavepictureinpicture`.
- `enter` sets the mode and then calls `play()` on a paused candidate.

What the new rule did in the harness:

- A video hidden 0.8 s before `enter` floated and played.
- A video floated 1.5 s after a minimise floated and played.
- A video the page had paused itself (`?paused=1`) was not a candidate.

Closing or pausing from the system window pauses while the mode is still `picture-in-picture`. A video
replaced in the window is paused after it leaves picture-in-picture (c). In the harness such a video
was still in the snapshot while its page stayed hidden. Clearing the snapshot on
`enterpictureinpicture` and `leavepictureinpicture` keeps it from floating again. That clearing is
the rule's, but it was not run here; Task 5 writes it and the Cover rung's checks exercise it.

This contradicts the spec's verbatim rule and its claim that the video keeps playing with the view
removed. The spec carries a dated amendment.

## What it changed

- Spec `docs/superpowers/specs/2026-10-27-3d-browser-you-live-in-design.md`: amendment 2026-10-27
  (the candidate rule; a muted or silent video is paused when its view leaves; closing ends the
  float with no callback). The body is edited to match.
- Plan `docs/superpowers/plans/2026-10-27-3d-iii-picture-in-picture.md`:
  - ruling 4 (WebKit already pauses the replaced video; the effect stays as a guard);
  - ruling 7 (the setter is `_setAllowsPictureInPictureMediaPlayback:`);
  - ruling 11 (release clears the float itself; the drop does not wait);
  - Global Constraints' candidate rule and Task 5's script events (`visibilitychange`,
    `enter`'s `play()`).
