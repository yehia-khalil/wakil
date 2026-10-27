import Foundation

/// One browser tab, anywhere: the place it lives in, its pane, and its id. Pane and tab ids repeat from
/// place to place, so the scope is part of the identity.
public struct BrowserTabRef: Hashable, Sendable {
    public let scope: LayoutScope
    public let pane: String
    public let tab: String

    public init(scope: LayoutScope, pane: String, tab: String) {
        self.scope = scope
        self.pane = pane
        self.tab = tab
    }
}

/// When a playing video floats, comes back inline, is paused, or goes back to its tab (3d-iii). Pure: the
/// host (WakilApp) says what is on screen and what WebKit reported, and carries out the effects returned.
/// Rulings 1-4, 6 and 11 of the 3d-iii plan are the rules.
public struct BrowserPictureInPicture: Sendable, Equatable {
    public enum Effect: Sendable, Equatable {
        /// Candidates, sorted by pane id; the host floats the newest-playing video among them.
        case float([BrowserTabRef])
        case inline(BrowserTabRef)
        case pause(BrowserTabRef)
        case goTo(BrowserTabRef)
    }

    private struct PaneKey: Hashable, Sendable {
        let scope: LayoutScope
        let pane: String
    }

    /// The setting and WebKit's support, set by the host before each call. Off floats nothing; coming
    /// back inline still happens.
    public var enabled: Bool
    public private(set) var floating: BrowserTabRef?
    public private(set) var minimized = false
    private var shown: [PaneKey: String] = [:]
    private var restoring: Set<BrowserTabRef> = []

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public func isShown(_ ref: BrowserTabRef) -> Bool {
        !minimized && shown[PaneKey(scope: ref.scope, pane: ref.pane)] == ref.tab
    }

    /// The pane is on screen showing `tab` (nil: none). Called on every sync, so the same tab again is `[]`.
    public mutating func show(scope: LayoutScope, pane: String, tab: String?) -> [Effect] {
        let key = PaneKey(scope: scope, pane: pane)
        let before = shown[key]
        shown[key] = tab
        // Recorded while minimised so that deminiaturising sees it, but nothing floats or returns now.
        guard !minimized, before != tab else { return [] }
        var effects: [Effect] = []
        if let before, enabled {
            effects.append(.float([BrowserTabRef(scope: scope, pane: pane, tab: before)]))
        }
        if let tab {
            let ref = BrowserTabRef(scope: scope, pane: pane, tab: tab)
            if ref == floating { effects.append(.inline(ref)) }
        }
        return effects
    }

    /// The pane is no longer drawn. `closing`: it is being closed, so its tabs are about to be released and
    /// floating one would last a second (ruling 2).
    public mutating func hide(scope: LayoutScope, pane: String, closing: Bool) -> [Effect] {
        guard let tab = shown.removeValue(forKey: PaneKey(scope: scope, pane: pane)) else { return [] }
        guard !closing, enabled, !minimized else { return [] }
        return [.float([BrowserTabRef(scope: scope, pane: pane, tab: tab)])]
    }

    public mutating func setMinimized(_ on: Bool) -> [Effect] {
        guard on != minimized else { return [] }
        minimized = on
        if on {
            let candidates = shown
                .sorted { ($0.key.pane, $0.key.scope.description) < ($1.key.pane, $1.key.scope.description) }
                .map { BrowserTabRef(scope: $0.key.scope, pane: $0.key.pane, tab: $0.value) }
            return enabled && !candidates.isEmpty ? [.float(candidates)] : []
        }
        // Only a tab that is on screen again comes back; one floating from a place switched away or a
        // covered pane stays floating.
        guard let floating, shown[PaneKey(scope: floating.scope, pane: floating.pane)] == floating.tab else { return [] }
        return [.inline(floating)]
    }

    /// WebKit reported that `ref`'s video entered or left picture-in-picture.
    public mutating func didChange(_ ref: BrowserTabRef, floating on: Bool) -> [Effect] {
        if on {
            floating = ref
            return []
        }
        if floating == ref { floating = nil }
        let fromRestore = restoring.remove(ref) != nil
        return fromRestore || isShown(ref) ? [] : [.pause(ref)]
    }

    /// The operator pressed Restore on the floating window.
    public mutating func restore(_ ref: BrowserTabRef) -> [Effect] {
        restoring.insert(ref)
        return [.goTo(ref)]
    }

    public mutating func restoreEnded(_ ref: BrowserTabRef, reached: Bool) -> [Effect] {
        // On arrival the token stays: WebKit's end-of-float report consumes it, however early or late
        // the pane's `show` runs.
        guard !reached else { return [] }
        restoring.remove(ref)
        return [.pause(ref)]
    }

    /// The tab was closed; releasing its view ends the float without WebKit saying so (ruling 11).
    public mutating func closed(_ ref: BrowserTabRef) -> [Effect] {
        if floating == ref { floating = nil }
        restoring.remove(ref)
        let key = PaneKey(scope: ref.scope, pane: ref.pane)
        if shown[key] == ref.tab { shown[key] = nil }
        return []
    }

    /// A place's scope changed (a conversation's canvas adopted); its panes and floating tab go with it.
    public mutating func rehome(from: LayoutScope, to: LayoutScope) {
        func moved(_ ref: BrowserTabRef) -> BrowserTabRef {
            ref.scope == from ? BrowserTabRef(scope: to, pane: ref.pane, tab: ref.tab) : ref
        }
        floating = floating.map(moved)
        restoring = Set(restoring.map(moved))
        var next: [PaneKey: String] = [:]
        for (key, tab) in shown {
            next[key.scope == from ? PaneKey(scope: to, pane: key.pane) : key] = tab
        }
        shown = next
    }

    /// The Settings line when WebKit lacks what floating needs; nil when nothing is missing (ruling 7).
    public static func unavailableLine(missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        return "Picture in picture is off: this Mac's WebKit has no \(missing.joined(separator: ", ")) — Wakil floats a video only through them."
    }
}
