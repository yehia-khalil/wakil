import Foundation

/// 3c browser spec, call 11: **the one path a link from elsewhere in Wakil opens by.** The blame
/// hover's Open on GitHub uses it now (3c-i); 3c-iii routes the terminal's, the editor's and an API
/// entry's links through it too. It is `browser_open` as the operator (`origin: .ui`, Invariant 2),
/// so the pane it picks is that action's: a new tab in the place's focused browser pane, else the one
/// most recently focused, else a new browser pane — opened with `focus`, so that pane comes forward
/// with the keyboard and the operator sees the page they asked for (3c-iii walk: "it doesnt focus on
/// browser, but the tabs open"; this overturns spec call 11's "the editor keeps the keyboard", which
/// Rule 6 allows: the click was a request to go to the page). An app's link (`mailto:`) is refused there, whole.
/// ⌥-click, the system browser instead, is the caller's: the app knows the modifier (`WakilLinks`).
extension WindowModel {
    public func openLinkInWakil(_ url: String) async {
        await dispatchFromSurface("browser_open", .object(["url": .string(url), "newTab": .bool(true), "focus": .bool(true)]))
    }
}
