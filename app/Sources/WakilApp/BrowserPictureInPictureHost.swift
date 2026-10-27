import Foundation
import WebKit

/// The window's automatic picture in picture (3d-iii): carries out `BrowserPictureInPicture`'s effects
/// through each tab's frames. Task 6 fills it; until then every entry point does nothing.
@MainActor
final class BrowserPictureInPictureHost: NSObject, WKScriptMessageHandler {
    private weak var host: BrowserTabHost?

    init(host: BrowserTabHost) {
        self.host = host
    }

    /// WebKit said the tab's video entered (`on`) or left picture in picture.
    func didChange(_ key: BrowserTabHost.Key, _ on: Bool) {}

    /// Restore was pressed on the floating window; `view` must be in a window before this returns.
    func restore(_ key: BrowserTabHost.Key, view: WKWebView) {}

    /// The tab's main frame committed a new page: its frames' tokens are gone.
    func forgetFrames(_ key: BrowserTabHost.Key) {}

    /// A frame's `wakilPictureInPicture` message, through `BrowserPictureInPictureMessages`.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
