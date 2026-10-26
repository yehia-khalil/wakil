import Foundation

/// 3c browser spec, call 11: **the one path a link from elsewhere in Wakil opens by.** The blame
/// hover's Open on GitHub uses it now (3c-i); 3c-iii routes the terminal's, the editor's and an API
/// entry's links through it too. It is `browser_open` as the operator (`origin: .ui`, Invariant 2),
/// so the pane it picks is that action's: a new tab in the place's focused browser pane, else the one
/// most recently focused, else a new browser pane — opened with `keepFocus`, so the pane the operator
/// clicked in keeps focus and the keyboard (Rule 6). An app's link (`mailto:`) is refused there, whole.
/// ⌥-click, the system browser instead, is the caller's: the app knows the modifier (`WakilLinks`).
extension WindowModel {
    public func openLinkInWakil(_ url: String) async {
        await dispatchFromSurface("browser_open", .object(["url": .string(url), "newTab": .bool(true), "keepFocus": .bool(true)]))
    }
}
