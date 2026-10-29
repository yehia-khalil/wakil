import Foundation

/// Where an agent's write lands (workspaces, piece 1: "How a write finds its checkout").
///
/// Every write action asks it at its head, with the root or path it was given. For an agent's
/// dispatch the answer is that conversation's checkout of the repo — made, taken over or branched
/// off first, and the conversation moved into a workspace when it was in Main (step 0). For the
/// operator's dispatch (call 12: the operator is never a holder) the answer is what was given.
/// A path inside another workspace's checkout is refused, naming it (call 13).
///
/// A protocol in `Core/` so the folders that own the write actions (`Editor/`) need not know the
/// folder that carries it out (`Workspace/`); `WakilWiring` hands the one `WorkspaceRouter` to both.
public protocol WorkspaceWriteRouting: Sendable {
    /// The root (Main's folder or a checkout) a write named, as the caller's write must use it.
    func routeRoot(_ root: String, action: String) async throws -> String
    /// An absolute path a write named, translated into the caller's checkout when it is in Main's
    /// folder of a repo (call 2).
    func routePath(_ path: String, action: String) async throws -> String
    /// A branch switch or create: the root to run it in and the branch to ask for — a new branch off
    /// the target's tip when a working conversation holds the target.
    func routeSwitch(root: String, branch: String, action: String) async throws -> RoutedSwitch
    /// The made checkouts of the calling agent's workspace; nil for the operator's dispatch.
    func callerCheckouts() async -> [String]?
}

/// A switch as the write rule lets it run.
public struct RoutedSwitch: Sendable, Equatable {
    public var root: String
    public var branch: String
    /// The branch was renamed to a new one off `from`'s tip: create it.
    public var create: Bool
    public var from: String?
    public init(root: String, branch: String, create: Bool = false, from: String? = nil) {
        self.root = root
        self.branch = branch
        self.create = create
        self.from = from
    }
}
