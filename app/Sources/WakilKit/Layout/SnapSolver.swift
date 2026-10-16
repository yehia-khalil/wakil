import Foundation

/// How close a dragged edge must come before it snaps, in canvas points.
///
/// One constant, in one place. §10 says "within a few pixels"; 8 is the
/// value that number became, and it is exported so the view can draw the
/// snap line using the same figure the solver decides with rather than a
/// second one that drifts.
public let snapThreshold: Double = 8.0

/// One way a dragged pane could snap: which of *its* edges is involved,
/// what it snaps to, and the frame it would take.
///
/// `toPaneId` is `nil` for the void's own edge, which is a snap target
/// like any other but has no pane behind it.
public struct SnapCandidate: Sendable, Equatable {
    public let edge: SnapEdge
    public let toPaneId: String?
    public let frame: PaneFrame

    public init(edge: SnapEdge, toPaneId: String?, frame: PaneFrame) {
        self.edge = edge
        self.toPaneId = toPaneId
        self.frame = frame
    }
}

/// The best snap for `proposed`, or `nil` if nothing is within `threshold`.
///
/// Pure: no state, no framework, no dependency on `LayoutStore`. This is
/// the one piece of 2b-i with real algorithmic content, and keeping it a
/// free function over plain values is what lets it be tested exhaustively
/// instead of through a view.
///
/// **The caller excludes the dragged pane from `neighbours`.** A pane
/// overlaps itself perfectly, so leaving it in would make every drag snap
/// to where it already was.
///
/// **Two rules decide a candidate.**
///
/// 1. *Proximity.* The dragged pane's edge must land within `threshold` of
///    the target edge. The comparison is `<=`, so a drag that lands
///    exactly on the threshold snaps — a boundary that excluded it would
///    make the last point of the range unreachable in practice.
/// 2. *Overlap along the shared edge.* Two panes only snap if they
///    actually face each other: a pane 4pt from another's left edge but
///    600pt below it shares no edge, and snapping them would teleport one
///    across the canvas. Checked on the perpendicular axis.
///
/// Among the candidates that pass both, the **nearest** wins, and a
/// neighbour beats the void at equal distance because it is the more
/// specific relationship.
///
/// **Snapping to a pane matches extent; snapping to the void does not.**
/// §10 says releasing against another pane "locks it flush and matches
/// height" — so a `left`/`right` snap takes the neighbour's `y` and
/// `height`, and a `top`/`bottom` snap takes its `x` and `width`. The void
/// has no extent worth matching (matching it would maximise the pane), so
/// a void snap only moves.
public func snapCandidate(
    for proposed: PaneFrame,
    neighbours: [(id: String, frame: PaneFrame)],
    void: PaneFrame,
    threshold: Double = snapThreshold
) -> SnapCandidate? {
    var best: (distance: Double, candidate: SnapCandidate)?

    func consider(_ distance: Double, _ candidate: SnapCandidate, neighbourWins: Bool) {
        guard distance <= threshold else { return }
        guard let current = best else {
            best = (distance, candidate)
            return
        }
        if distance < current.distance || (distance == current.distance && neighbourWins) {
            best = (distance, candidate)
        }
    }

    // Pane-to-pane.
    for neighbour in neighbours {
        for edge in SnapEdge.allCases {
            guard sharesAnEdge(proposed, neighbour.frame, along: edge) else { continue }
            let target = edgeValue(neighbour.frame, edge.opposite)
            let distance = abs(edgeValue(proposed, edge) - target)
            let frame = flush(proposed, edge: edge, to: target, matching: neighbour.frame)
            consider(distance, SnapCandidate(edge: edge, toPaneId: neighbour.id, frame: frame),
                     neighbourWins: true)
        }
    }

    // Pane-to-void. The void's `left` is the target for a pane's `left`,
    // not its `right`: the pane sits *inside* the void, so like edges meet
    // rather than opposite ones.
    for edge in SnapEdge.allCases {
        let target = edgeValue(void, edge)
        let distance = abs(edgeValue(proposed, edge) - target)
        let frame = flush(proposed, edge: edge, to: target, matching: nil)
        consider(distance, SnapCandidate(edge: edge, toPaneId: nil, frame: frame),
                 neighbourWins: false)
    }

    return best?.candidate
}

/// The coordinate of one edge of a frame.
func edgeValue(_ frame: PaneFrame, _ edge: SnapEdge) -> Double {
    switch edge {
    case .left: return frame.minX
    case .right: return frame.maxX
    case .top: return frame.minY
    case .bottom: return frame.maxY
    }
}

/// Whether the two frames overlap on the axis *perpendicular* to `edge` —
/// i.e. whether they actually face each other across it.
///
/// Rule 2 of `snapCandidate`. Without it, any pane within 8pt of another's
/// x coordinate would snap to it regardless of how far apart they were
/// vertically.
private func sharesAnEdge(_ a: PaneFrame, _ b: PaneFrame, along edge: SnapEdge) -> Bool {
    if edge.isHorizontal {
        return a.minY < b.maxY && b.minY < a.maxY
    }
    return a.minX < b.maxX && b.minX < a.maxX
}

/// `frame` moved so that its `edge` sits exactly on `target`, and — when
/// `matching` is non-nil — resized to that neighbour's extent along the
/// shared edge.
func flush(
    _ frame: PaneFrame, edge: SnapEdge, to target: Double, matching neighbour: PaneFrame?
) -> PaneFrame {
    var result = frame
    switch edge {
    case .left: result.x = target
    case .right: result.x = target - result.width
    case .top: result.y = target
    case .bottom: result.y = target - result.height
    }
    if let neighbour {
        if edge.isHorizontal {
            result.y = neighbour.minY
            result.height = neighbour.height
        } else {
            result.x = neighbour.minX
            result.width = neighbour.width
        }
    }
    return result
}
