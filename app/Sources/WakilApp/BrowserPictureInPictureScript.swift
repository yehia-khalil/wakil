import Foundation
import WebKit

/// Picture in picture's page script (3d-iii): Wakil's own JavaScript, in its own content world.
///
/// **`wakil.pip` is a world of its own**, as `wakil.agent` and `wakil.find` are: the page's script
/// never sees the script, its expandos on the page's videos, or the message handler. It is added to
/// every tab's configuration at document end **in every frame**, so a video in a cross-origin iframe
/// floats through its own frame (probe b). Configured only when
/// `BrowserPictureInPictureSupport.available`.
///
/// **Each document gives itself a token** (`crypto.randomUUID()`, or 16 random bytes in hex where the
/// page is not a secure context and has no `randomUUID`) and posts
/// `{frame: token, playing: Bool, since: Number}` to `wakilPictureInPicture` for its newest
/// qualifying video, on `play`, `playing`, `pause`, `ended`, `emptied`, `visibilitychange`,
/// `enterpictureinpicture`, `leavepictureinpicture` and `webkitpresentationmodechanged` (all caught
/// in the capture phase on `document`, since media events do not bubble), once at injection (a video
/// already playing), with `playing: false` on `pagehide`, so the host drops the token, and again on a
/// `pageshow` from the back-forward cache (the same document, so the same token).
///
/// **A qualifying video** (the candidate rule, as amended 2026-10-27) is `!paused`, or was playing
/// by its own events when the page went hidden while the page stays hidden; and `!ended &&
/// readyState > 2 && !disablePictureInPicture`. WebKit pauses a muted or silent video the moment
/// its view leaves the window (probe h), and `paused` is already true when `visibilitychange`
/// fires, so "playing" is read from the events: seen `playing`, then no `pause`, `ended` or
/// `emptied`. That is snapshotted when the page goes hidden, and cleared when it is visible again,
/// when the video enters or leaves picture in picture, and by `enter` and `pause`. `since` is the
/// video's last `playing` stamp (`Date.now()`), so the host floats the newest across frames
/// (ruling 3).
///
/// `enter`, `inline` and `pause` are `callAsyncJavaScript` bodies, run in a frame and this world.
enum BrowserPictureInPictureScript {
    @MainActor static let world = WKContentWorld.world(name: "wakil.pip")
    static let handlerName = "wakilPictureInPicture"

    /// Added to each tab's configuration: the script installs itself as each document ends, in every
    /// frame. A pop-up's configuration is WebKit's copy of its opener's, so it carries the script too.
    @MainActor static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world)
    }

    /// Floats the frame's newest qualifying video with `webkitSetPresentationMode` (WebKit's prefixed
    /// web API; never `requestPictureInPicture()`), then plays it if it is paused. Answers whether
    /// it did.
    static let enter = "return globalThis.wakilPip ? globalThis.wakilPip.enter() : false;"
    /// Sends every floating video of the frame back inline. Answers how many.
    static let inline = "return globalThis.wakilPip ? globalThis.wakilPip.inline() : 0;"
    /// Pauses every playing video of the frame, and forgets the hidden-time snapshot. Answers how many.
    static let pause = "return globalThis.wakilPip ? globalThis.wakilPip.pause() : 0;"

    static let source: String = #"""
        (() => {
          'use strict';
          if (globalThis.wakilPip) return;
          // `randomUUID` exists only in a secure context; a plain `http:` page (or a blank frame in one)
          // has only `getRandomValues`.
          const token = typeof crypto.randomUUID === 'function' ? crypto.randomUUID()
            : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
          // Expandos on the video's wrapper in this world: the page's own wrapper never has them.
          const SINCE = 'wakilPipSince', PLAYING = 'wakilPipPlaying', HIDDEN = 'wakilPipHidden';
          const videos = () => Array.from(document.querySelectorAll('video'));
          const qualifies = v => (!v.paused || (document.hidden && v[HIDDEN] === true))
            && !v.ended && v.readyState > 2 && !v.disablePictureInPicture;
          const newest = () => {
            let best = null;
            for (const v of videos()) {
              if (qualifies(v) && (best === null || (v[SINCE] || 0) > (best[SINCE] || 0))) best = v;
            }
            return best;
          };
          const send = (playing, since) => {
            try {
              window.webkit.messageHandlers.\#(handlerName).postMessage({ frame: token, playing, since });
            } catch (_) {}
          };
          const report = () => {
            const v = newest();
            send(v !== null, v !== null ? (v[SINCE] || 0) : 0);
          };
          const on = (type, handle) => document.addEventListener(type, e => {
            if (e.target instanceof HTMLVideoElement) handle(e.target);
            report();
          }, true);
          on('playing', v => { v[SINCE] = Date.now(); v[PLAYING] = true; });
          on('play', () => {});
          on('pause', v => { v[PLAYING] = false; });
          on('ended', v => { v[PLAYING] = false; v[HIDDEN] = false; });
          on('emptied', v => { v[PLAYING] = false; v[HIDDEN] = false; });
          for (const type of ['enterpictureinpicture', 'leavepictureinpicture', 'webkitpresentationmodechanged']) {
            on(type, v => { v[HIDDEN] = false; });
          }
          document.addEventListener('visibilitychange', () => {
            // Hidden: `paused` may already be true for a muted or silent video, but its `pause`
            // event has not been dispatched, so its events still say it plays.
            for (const v of videos()) v[HIDDEN] = document.hidden && v[PLAYING] === true;
            report();
          }, true);
          window.addEventListener('pagehide', () => send(false, 0), true);
          // Back from the back-forward cache: the same document, so the same token, said again.
          window.addEventListener('pageshow', e => { if (e.persisted) report(); }, true);
          // A video already playing when the script arrives.
          for (const v of videos()) {
            if (!v.paused && !v.ended && v.readyState > 2) {
              v[PLAYING] = true;
              if (!v[SINCE]) v[SINCE] = Date.now();
            }
          }
          report();
          globalThis.wakilPip = {
            enter() {
              const v = newest();
              if (v === null || typeof v.webkitSetPresentationMode !== 'function') return false;
              v[HIDDEN] = false;
              v.webkitSetPresentationMode('picture-in-picture');
              if (v.paused) v.play().catch(() => {});
              return true;
            },
            inline() {
              let n = 0;
              for (const v of videos()) {
                if (v.webkitPresentationMode === 'picture-in-picture') {
                  v.webkitSetPresentationMode('inline');
                  n++;
                }
              }
              return n;
            },
            pause() {
              let n = 0;
              for (const v of videos()) {
                v[HIDDEN] = false;
                if (!v.paused) { v.pause(); n++; }
              }
              report();
              return n;
            },
          };
        })();
        """#
}

/// The `wakilPictureInPicture` handler each configuration registers: it holds the window's
/// `BrowserPictureInPictureHost` weakly, so a user content controller (kept by its web views,
/// pop-ups included) never keeps the host alive.
@MainActor
final class BrowserPictureInPictureMessages: NSObject, WKScriptMessageHandler {
    private weak var target: BrowserPictureInPictureHost?

    init(to target: BrowserPictureInPictureHost) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
