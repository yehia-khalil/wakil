import Foundation

// The walk: a run that is ready names its app as a link (design-language §5, "Blue means opens a
// web page"). The link is the app's root on the repo's own port, never the ready check's path (`/up`
// is a health route), and the same when the recipe's ready is an output line.

/// `http://localhost:41220/`: the app a repo runs on `port`.
public func runAppAddress(port: Int) -> String { "http://localhost:\(port)/" }

/// `:41220`: the link's words, before its ↗.
public func runAppLabel(port: Int) -> String { ":\(port)" }

/// The ports of the repos that are ready (running, with a port), in the workspace's order: each one
/// the card links. A repo still getting going, failed or building has none yet.
public func runAppPorts(_ states: [RepoRunState]) -> [Int] {
    states.compactMap { s in
        guard case .running = s.phase, !s.processes.isEmpty else { return nil }
        return s.port
    }
}
