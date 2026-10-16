import Foundation

/// `design-language.md` §3's three planes, and how far each one moves
/// against the cursor.
///
/// Depth is expressed through scale, opacity and blur **together** — never
/// one alone — which is why all three are properties of the same value
/// rather than three constants a view happens to apply in the same place.
public enum Plane: Sendable, CaseIterable {
    /// Ambient context: the rail, the status line. Blurred and dimmed, so
    /// it can move freely — nothing on it is being read.
    case far
    /// The active data surface. §1's second register: full contrast, crisp,
    /// and **still**.
    case mid
    /// The Core and the thought thread. Brightest, may overlap.
    case near

    public var scale: Double {
        switch self {
        case .far: return 0.94
        case .mid, .near: return 1.0
        }
    }

    public var opacity: Double {
        switch self {
        case .far: return 0.30
        case .mid, .near: return 1.0
        }
    }

    public var blur: Double {
        switch self {
        case .far: return 1.4
        case .mid, .near: return 0.0
        }
    }

    /// The furthest any plane moves from its resting position, in points.
    ///
    /// One number, deliberately, because it is the thing most likely to be
    /// wrong: the magnitude that reads as depth and the magnitude that
    /// reads as instability are close together, and only the operator can
    /// tell them apart. Tuning it must not be a code change anywhere else.
    public static let maximumOffset: Double = 8

    /// How much of `maximumOffset` this plane takes.
    ///
    /// **The mid plane is zero and that is a rule, not a tuning.** Spec §6:
    /// parallax moves the void and the far plane and never a pane. A data
    /// surface that shifts while it is being read fights §1's legibility
    /// register, and text sliding against the pixel grid shimmers.
    public var parallaxFactor: Double {
        switch self {
        case .far: return 1.0
        case .mid: return 0.0
        // The near plane moves opposite the far one, at half the distance.
        // Opposing directions are what makes two layers read as depth
        // rather than as one layer sliding.
        case .near: return -0.5
        }
    }

    /// Where this plane sits, given the cursor's position within a window
    /// of `size`. `(0, 0)` when the cursor is at the centre.
    ///
    /// Clamped, so a cursor dragged outside the window — which happens on
    /// every drag that leaves the frame — cannot send a plane arbitrarily
    /// far. A zero-sized window yields zero rather than NaN; a view reports
    /// one for a frame at launch, and a NaN in a transform blanks it.
    public func parallaxOffset(
        cursor: (x: Double, y: Double),
        in size: (width: Double, height: Double)
    ) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (x: 0, y: 0) }
        let nx = min(max((cursor.x / size.width) * 2 - 1, -1), 1)
        let ny = min(max((cursor.y / size.height) * 2 - 1, -1), 1)
        let d = Plane.maximumOffset * parallaxFactor
        return (x: nx * d, y: ny * d)
    }
}
