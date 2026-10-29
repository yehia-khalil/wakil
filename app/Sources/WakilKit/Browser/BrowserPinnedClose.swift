import Foundation

/// A first ⌘W on a pinned tab, waiting for its second (ruling 15). The view draws
/// `BrowserPinnedClose.tip(_:)` while one is set.
public struct BrowserCloseArm: Sendable, Equatable {
    public var pane: String
    public var tab: String
    public var at: Date

    public init(pane: String, tab: String, at: Date) {
        self.pane = pane
        self.tab = tab
        self.at = at
    }
}

/// ⌘W on a pinned tab closes on the second press within `window`, on the same tab. A press on another
/// tab, or after the window, arms again instead.
public enum BrowserPinnedClose {
    public static let window: TimeInterval = 2
    /// The tip under an armed pinned tab, naming Close Tab's chord in force (`chord`, its text).
    public static func tip(_ chord: String?) -> String {
        chord.map { "Press \($0) again to close" } ?? "Choose Close Tab again to close"
    }

    public enum Outcome: Sendable, Equatable { case arm, close }

    public static func press(_ armed: BrowserCloseArm?, pane: String, tab: String, now: Date) -> Outcome {
        guard let armed, armed.pane == pane, armed.tab == tab,
              now.timeIntervalSince(armed.at) <= window else { return .arm }
        return .close
    }
}
