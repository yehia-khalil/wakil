import Foundation

/// The Changes view's one remote button (3a-iii): what it does for a root's branch now.
public enum ChangesRemoteButton: String, Sendable, Equatable {
    case publish, push, pull, sync, none

    /// The action the button dispatches; nil for `.none`.
    public var action: String? { self == .none ? nil : "editor_changes_\(rawValue)" }
    public var title: String {
        switch self {
        case .publish: "Publish"
        case .push: "Push"
        case .pull: "Pull"
        case .sync: "Sync"
        case .none: ""
        }
    }
}

/// Publish with no upstream; Sync when both sides moved; Push when only this side did; Pull when only
/// the remote did; nothing on a detached HEAD or when even.
public func changesRemoteButton(_ root: GitRootState) -> ChangesRemoteButton {
    if root.branch.isEmpty { return .none }
    if root.upstream.isEmpty { return .publish }
    switch (root.ahead > 0, root.behind > 0) {
    case (true, true): return .sync
    case (true, false): return .push
    case (false, true): return .pull
    case (false, false): return .none
    }
}
