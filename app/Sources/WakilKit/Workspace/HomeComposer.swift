import Foundation

// Workspaces, piece 3: where a send from the home screen goes (decisions 19, 23). The composer
// names the place; with several projects it is a picker, pre-set to the current place (Rule 9).
// Choosing sets where the next send goes and nothing else (piece 3 walk): the screen stays on the
// home, and the send goes there (`WindowModel.enterStartIn`). The draft stays.

/// One row of the composer's *Start in* picker.
public struct HomeStartChoice: Sendable, Equatable, Identifiable {
    public var id: String { "\(project)/\(environment)" }
    public let project: String
    /// Empty: the project's own landing environment (the one a project switch lands on).
    public let environment: String
    public let current: Bool
    public let isProduction: Bool
    public var label: String { environment.isEmpty ? project : "\(project) · \(environment)" }
    /// The row's tag in Start in's plane: *now* for where the window is, *production* (red,
    /// Invariant 8) for a production environment; nil otherwise.
    public var tag: String? { current ? "now" : isProduction ? "production" : nil }
}

/// Start in's rows, one group per project in the order given: the plane draws a hairline between.
public func homeStartGroups(_ choices: [HomeStartChoice]) -> [[HomeStartChoice]] {
    var out: [[HomeStartChoice]] = []
    for c in choices {
        if let last = out.last?.last, last.project == c.project { out[out.count - 1].append(c) } else { out.append([c]) }
    }
    return out
}

/// The row ↑ or ↓ moves to in Start in's plane: stops at either end, never wraps.
public func homeStartMove(_ index: Int, by step: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + step, 0), count - 1)
}

/// The picker's rows: the current place first, then the current project's other environments, then
/// every other project at the environment it was last in (else the one a switch lands on).
public func homeStartChoices(
    projects: [String], current: Place, environments: [String], lastEnvironment: [String: String] = [:],
    isProduction: (String, String) -> Bool = { _, e in e.lowercased() == "production" }
) -> [HomeStartChoice] {
    var out = [HomeStartChoice(project: current.project, environment: current.environment, current: true,
                               isProduction: isProduction(current.project, current.environment))]
    for e in environments where e != current.environment {
        out.append(HomeStartChoice(project: current.project, environment: e, current: false,
                                   isProduction: isProduction(current.project, e)))
    }
    for p in projects where p != current.project {
        let e = lastEnvironment[p] ?? ""
        out.append(HomeStartChoice(project: p, environment: e, current: false, isProduction: isProduction(p, e)))
    }
    return out
}

/// The row *Start in* shows: the one `chosen` names (`WindowModel.homeStartIn`), else the first —
/// the window's place. A choice no longer offered falls back to the first.
public func homeStartSelected(_ choices: [HomeStartChoice], chosen: Place?) -> HomeStartChoice? {
    guard let chosen else { return choices.first }
    return choices.first { $0.project == chosen.project && $0.environment == chosen.environment } ?? choices.first
}

/// The composer's placeholder on the home screen (amendment 2026-10-30): it names no place — the
/// *Start in* picker beside it already shows where a send goes.
public let homeComposerPlaceholder = "Ask, or name what to open"
