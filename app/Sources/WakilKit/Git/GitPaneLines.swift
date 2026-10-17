import Foundation

// The text the Changes view draws for the window's git status (3a-i's Git pane's, kept in 3b-iii),
// pure, because WakilApp has no test target. `EditorColumn` draws what these answer.

/// A root's header: `api · main ↑2 ↓1`, `api · a1b2c3d` when detached, `api · main · clean`
/// with nothing changed, `api · <first line of its error>` when it could not be read, and
/// only `api` before any read has reached it — not "clean", which nobody knows yet.
public func gitRootLine(_ r: GitRootState) -> String {
    if let error = r.error {
        return "\(r.name) · " + (error.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
    }
    let ref = r.branch.isEmpty ? r.detached : r.branch
    guard !ref.isEmpty else { return r.name }
    var line = "\(r.name) · \(ref)"
    if r.ahead > 0 { line += " ↑\(r.ahead)" }
    if r.behind > 0 { line += " ↓\(r.behind)" }
    if r.files.isEmpty { line += " · clean" }
    return line
}

/// The rest of a root's error, after the first line its header carries — drawn whole beneath
/// the header (Rule 8). nil when the error is one line, or there is none.
public func gitRootErrorDetail(_ r: GitRootState) -> String? {
    guard let error = r.error, let newline = error.firstIndex(of: "\n") else { return nil }
    let rest = String(error[error.index(after: newline)...])
    return rest.isEmpty ? nil : rest
}

/// The micro-label over a group.
public func gitGroupLabel(_ g: GitGroup) -> String {
    switch g {
    case .staged: "STAGED"
    case .changed: "CHANGES"
    case .untracked: "UNTRACKED"
    }
}

/// One group's rows under a root header.
public struct GitListSection: Sendable, Equatable {
    public var group: GitGroup
    public var rows: [GitFileRow]
}

/// A root's groups as the list draws them: staged, changes, untracked, each in path (byte) order,
/// and an empty group not drawn at all.
public func gitListSections(_ r: GitRootState) -> [GitListSection] {
    GitGroup.allCases.compactMap { group in
        let rows = r.files.filter { $0.group == group }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return rows.isEmpty ? nil : GitListSection(group: group, rows: rows)
    }
}

/// A row's text: its path, or `old → new` for a rename or copy.
public func gitRowLabel(_ row: GitFileRow) -> String {
    guard let orig = row.origPath, !orig.isEmpty else { return row.path }
    return "\(orig) → \(row.path)"
}

/// The hue a status letter is drawn in. §5: amber is pending, green is an addition; a
/// deletion is muted because red is reserved for production and destruction.
public enum GitStatusTone: Sendable, Equatable { case modified, added, muted }

public func gitStatusTone(_ status: String) -> GitStatusTone {
    switch status {
    case "A", "?": .added
    case "D": .muted
    case "M", "R", "C", "T", "U": .modified
    default: .muted
    }
}
