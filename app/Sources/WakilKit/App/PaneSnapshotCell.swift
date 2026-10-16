import Foundation
import Observation

/// One pane's snapshot, observed on its own: a terminal tick writes only its own pane's cell, so it
/// invalidates only the views reading that pane. `refreshPanes`, which runs after every action,
/// still rewrites every pane's cell. `WindowModel.paneCells` changes only when a pane opens or
/// closes. (A single shared dictionary would make every terminal tick redraw every pane — see
/// `refreshTerminal`.)
@MainActor
@Observable
public final class PaneSnapshotCell {
    public internal(set) var snapshot: PaneSnapshot
    init(_ snapshot: PaneSnapshot) { self.snapshot = snapshot }
}
