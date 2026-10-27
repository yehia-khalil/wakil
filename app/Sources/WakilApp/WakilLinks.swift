import AppKit
import WakilKit

/// Where a link the operator clicked in Wakil opens (3c browser spec, call 11): in Wakil's browser
/// pane through `WindowModel.openLinkInWakil`, or in the system browser when the click was ⌥-click.
/// `systemBrowser` is the modifier as the click's own surface saw it at the press (the blame hover's
/// page records it from its mousedown), never the keyboard's state when the message arrives.
@MainActor
enum WakilLinks {
    static func open(_ url: String, systemBrowser: Bool, model: WindowModel) {
        if systemBrowser, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(u)
            return
        }
        Task { await model.openLinkInWakil(url) }
    }
}
