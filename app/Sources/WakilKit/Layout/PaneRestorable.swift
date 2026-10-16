import Foundation

/// The action a restored pane of this kind dispatches (launch, an org switch loaded from disk).
/// A kind without it restores nothing. It lives in `Layout/` beside `Pane`, so `Panes/` need not use it.
public protocol PaneRestorable {
    static func restoreStep(for pane: Pane) -> PaneRestoreStep?
}

/// What `WindowModel.restorePaneContents` dispatches for one restored pane. `recordsFailure` writes a
/// refusal into the pane (`setFailure`), as a db pane's refetch always has; a git pane's errors land
/// root by root instead.
public struct PaneRestoreStep: Sendable, Equatable {
    public var action: String
    public var params: JSONValue
    public var recordsFailure: Bool

    public init(action: String, params: JSONValue, recordsFailure: Bool) {
        self.action = action
        self.params = params
        self.recordsFailure = recordsFailure
    }
}
