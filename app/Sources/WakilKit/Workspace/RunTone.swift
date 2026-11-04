import Foundation

/// The colour a run's state reads in (design-language §5): violet while Wakil works on it, amber
/// while it waits for ready, green once it runs — green means healthy only — and red once it
/// failed. The walk drew "parkour-warriors failed" in the running green. Its colour: `RunTone.colour`
/// (App, where the palette is reachable).
public enum RunTone: Sendable, Equatable {
    case working, waiting, ready, failed

    /// Most urgent first: a card's tone is its most urgent repo's.
    fileprivate var urgency: Int {
        switch self {
        case .failed: 3
        case .waiting: 2
        case .working: 1
        case .ready: 0
        }
    }
}

extension RepoRunState {
    public var tone: RunTone {
        switch phase {
        case .failed: return .failed
        case .running: return .ready
        case .building: return .working
        case .starting(let what):
            return (step?.step ?? what) == "waiting for ready" ? .waiting : .working
        }
    }
}

/// A workspace's run tone: its most urgent repo's; nil while nothing runs.
public func runTone(_ states: [RepoRunState]) -> RunTone? {
    states.map(\.tone).max { $0.urgency < $1.urgency }
}
