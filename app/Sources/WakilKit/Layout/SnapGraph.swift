import Foundation

/// One coordinated edge: `paneId`'s `edge` is snapped against
/// `otherPaneId`.
///
/// Stored in a canonical direction so that a link added as
/// `("b", .left, "a")` and one added as `("a", .right, "b")` are the same
/// value and cannot both exist. See `SnapGraph.link`.
public struct SnapLink: Sendable, Equatable, Hashable, Codable {
    public let paneId: String
    public let edge: SnapEdge
    public let otherPaneId: String

    public init(paneId: String, edge: SnapEdge, otherPaneId: String) {
        self.paneId = paneId
        self.edge = edge
        self.otherPaneId = otherPaneId
    }
}

/// Which panes have coordinated edges with which others.
///
/// **Stored, not derived, and that is the point.** Two panes that happen
/// to be flush are not the same as two panes that were snapped: snapping
/// matches their extent once, and a later independent resize may leave
/// them flush-but-unrelated or related-but-not-flush. Re-deriving
/// adjacency from geometry every frame would silently re-couple panes the
/// user deliberately pulled apart, and the failure would read as "feels
/// wrong" rather than as a crash.
///
/// Undirected: linking a's right to b implies b's left is linked to a, and
/// `neighbours(of:along:)` answers from either side. Storage canonicalises
/// each link to one direction so the pair cannot be recorded twice.
public struct SnapGraph: Sendable, Equatable, Codable {
    /// Canonical form only: `edge` is always `.right` or `.bottom`, so
    /// every link is stored from the pane on the left or above.
    private var stored: Set<SnapLink>

    public init() {
        stored = []
    }

    /// Records that `paneId`'s `edge` is coordinated with `otherPaneId`.
    /// Idempotent, and order-independent — see `canonical`.
    public mutating func link(_ paneId: String, _ edge: SnapEdge, to otherPaneId: String) {
        stored.insert(Self.canonical(paneId, edge, otherPaneId))
    }

    /// Drops every link on `paneId`'s `edge` — what happens when a pane is
    /// dragged away from a side it was snapped on. Links on its *other*
    /// edges survive: pulling a pane out of a row to the right should not
    /// unstick it from the pane above.
    public mutating func unlink(_ paneId: String, _ edge: SnapEdge) {
        stored = stored.filter { link in
            !(link.paneId == paneId && link.edge == edge)
                && !(link.otherPaneId == paneId && link.edge == edge.opposite)
        }
    }

    /// Drops every link `paneId` holds, on every edge. Called when a pane
    /// closes — a link to a pane that no longer exists would make the
    /// border-drag code resize a ghost.
    public mutating func removeAll(for paneId: String) {
        stored = stored.filter { $0.paneId != paneId && $0.otherPaneId != paneId }
    }

    /// Every link `old` holds, held by `new` instead (workspaces, piece 1: a terminal step 0 leaves
    /// in Main's view is replaced where it stood by a new one in the copy).
    public mutating func rename(_ old: String, to new: String) {
        stored = Set(stored.map { link in
            SnapLink(paneId: link.paneId == old ? new : link.paneId, edge: link.edge,
                     otherPaneId: link.otherPaneId == old ? new : link.otherPaneId)
        })
    }

    /// Every pane coordinated with `paneId` along `edge`, in sorted order.
    public func neighbours(of paneId: String, along edge: SnapEdge) -> [String] {
        var result: [String] = []
        for link in stored {
            if link.paneId == paneId, link.edge == edge {
                result.append(link.otherPaneId)
            } else if link.otherPaneId == paneId, link.edge == edge.opposite {
                result.append(link.paneId)
            }
        }
        return result.sorted()
    }

    /// Every link, in a deterministic order.
    ///
    /// Sorted rather than in `Set` order because this is what
    /// `LayoutPersistence` encodes: a set's iteration order varies between
    /// runs, and an unsorted encoding would rewrite the layout file with
    /// different bytes for an unchanged arrangement on every launch.
    public var links: [SnapLink] {
        stored.sorted {
            ($0.paneId, $0.edge.rawValue, $0.otherPaneId)
                < ($1.paneId, $1.edge.rawValue, $1.otherPaneId)
        }
    }

    /// Rewrites a link so that it is always stored from the left/upper
    /// pane's point of view. `("b", .left, "a")` becomes
    /// `("a", .right, "b")`, so the two spellings of one relationship
    /// cannot both be inserted.
    private static func canonical(
        _ paneId: String, _ edge: SnapEdge, _ otherPaneId: String
    ) -> SnapLink {
        switch edge {
        case .right, .bottom:
            return SnapLink(paneId: paneId, edge: edge, otherPaneId: otherPaneId)
        case .left, .top:
            return SnapLink(paneId: otherPaneId, edge: edge.opposite, otherPaneId: paneId)
        }
    }

    // Codable over the sorted array, not the set, for the reason `links`
    // gives.
    private enum CodingKeys: String, CodingKey { case links }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stored = Set(try container.decode([SnapLink].self, forKey: .links))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(links, forKey: .links)
    }
}
