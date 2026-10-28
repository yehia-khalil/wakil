import Foundation

/// 3d-i walk: which link activations open in a new background tab (⌘-click, middle-click).
public enum BrowserLinkOpening {
    /// WebKit's `WKNavigationAction.buttonNumber` for the middle button is **4**, not AppKit's
    /// `NSEvent.buttonNumber` 2 (WebKit numbers its buttons 1 left, 2 right, 4 middle). 2 is kept too:
    /// a script's synthetic middle click, and a build whose WebKit passes AppKit's number, still open
    /// in the background, as they did before (a right click opens a menu, never a navigation).
    public static let middleButtons: Set<Int> = [2, 4]

    /// A link activation opens in the background when ⌘ was held or the middle button pressed.
    public static func opensInBackground(command: Bool, buttonNumber: Int) -> Bool {
        command || middleButtons.contains(buttonNumber)
    }
}
