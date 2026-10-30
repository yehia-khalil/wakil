import Foundation

// Workspaces, piece 3: where a send from the home screen goes (decisions 19, 23). The composer
// names the place; with several projects it is a picker, pre-set to the current place (Rule 9).
// Choosing is a place switch, as the context line's; the draft stays.

/// One row of the composer's *Start in* picker.
public struct HomeStartChoice: Sendable, Equatable, Identifiable {
    public var id: String { "\(project)/\(environment)" }
    public let project: String
    /// Empty: the project's own landing environment (the one a project switch lands on).
    public let environment: String
    public let current: Bool
    public let isProduction: Bool
    public var label: String { environment.isEmpty ? project : "\(project) · \(environment)" }
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

/// The composer's placeholder on the home screen (amendment 2026-10-30): it names no place — the
/// *Start in* picker beside it already shows where a send goes.
public let homeComposerPlaceholder = "Ask, or name what to open"
