import Foundation

/// 3d-i walk: ⌘⇧C copies the address of the page you are on. The rules here are pure; the pasteboard
/// is the app's (`BrowserTextCopier`), as `browser_clear_data`'s store removal is.
public enum BrowserCopyURL {
    /// The short tip drawn near the address field after a copy, and how long it stays (it fades
    /// over the end of it).
    public static let tip = "Copied"
    public static let tipDuration: TimeInterval = 1.5

    /// The address to copy: the tab's URL as it stands; nil for a tab with none yet (a blank start page).
    public static func copyable(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Puts text on the general pasteboard. Only the app can (AppKit's); nil leaves `browser_copy_url`
/// answering the address with `copied: false`, as `--dispatch` and tests want.
public typealias BrowserTextCopier = @Sendable (String) async -> Void

/// The `Copied` tip drawn under a browser pane's address field. `serial` tells a second copy from
/// the first, so the first's timer cannot end the second's tip.
public struct BrowserCopiedTip: Sendable, Equatable {
    public var pane: String
    public var serial: Int

    public init(pane: String, serial: Int) {
        self.pane = pane
        self.serial = serial
    }
}
