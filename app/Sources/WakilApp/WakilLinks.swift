import AppKit
import WakilKit

/// Where a link the operator clicked in Wakil opens (3c browser spec, call 11): in Wakil's browser
/// pane through `WindowModel.openLinkInWakil`, or in the system browser while ⌥ is held. The modifier
/// is read at the click's message, not carried by it: a Monaco command link hands its command no event.
@MainActor
enum WakilLinks {
    static func open(_ url: String, model: WindowModel) {
        if NSEvent.modifierFlags.contains(.option), let u = URL(string: url),
           ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(u)
            return
        }
        Task { await model.openLinkInWakil(url) }
    }
}
