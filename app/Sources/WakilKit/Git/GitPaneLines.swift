import Foundation

// The git pane's text and the choices behind it, pure, because WakilApp has no test target.
// `GitPane` draws what these answer and decides nothing of its own.

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

/// A root's groups as the list draws them: staged, changes, untracked, each in step order,
/// and an empty group not drawn at all.
public func gitListSections(_ r: GitRootState) -> [GitListSection] {
    let order = gitRows([r])
    return GitGroup.allCases.compactMap { group in
        let rows = order.filter { $0.group == group }.compactMap { gitFileRow($0, in: [r]) }
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

/// The spine's marks: one array per root in project order (an empty root included, so a
/// separator can sit between roots), each in step order — `gitRows`, cut by root.
public func gitSpineMarks(_ roots: [GitRootState]) -> [[GitSelection]] {
    roots.map { gitRows([$0]) }
}

/// What the folded pane draws left of the diff: the 26 pt **spine** of status marks, or — once
/// the pane is wide enough to spare it — a **names** column of the same rows, so a wide pane
/// shows which file each mark is. The spine is the default; §1's "no sidebars" bends only
/// where there is room (design-language §11, Git).
public enum GitFoldedListStyle: Sendable, Equatable {
    case spine
    case names

    /// The column's width in points.
    public var width: Double {
        switch self {
        case .spine: gitSpineWidth
        case .names: gitNamesColumnWidth
        }
    }
}

/// The spine's width, as 3a-i drew it.
public let gitSpineWidth: Double = 26
/// The names column's width.
public let gitNamesColumnWidth: Double = 240
/// The narrowest folded pane that trades the spine for the names column. Below it the diff
/// keeps every point it can get; at it the diff still has ~640 pt beside a 240 pt column.
public let gitNamesColumnMinPaneWidth: Double = 900

/// Which column the folded pane draws at `width` points wide.
public func gitFoldedListStyle(width: Double) -> GitFoldedListStyle {
    width >= gitNamesColumnMinPaneWidth ? .names : .spine
}

/// The row a selection or a mark names, for its status letter. nil when it is gone.
public func gitFileRow(_ s: GitSelection, in roots: [GitRootState]) -> GitFileRow? {
    roots.first { $0.root == s.root }?.files.first { $0.path == s.path && $0.group == s.group }
}

/// The row in the unfolded list that draws the loading mark (Rule 5), or nil for none.
///
/// **The row the operator clicked, while its select is running.** `git_select` returns only
/// once the diff has landed and the window reads the snapshot after it, so until then the
/// list the operator clicked in is all they see; without this the click looked ignored.
/// `opening` is the pane's own select still in flight. Failing that, **the selection while
/// its diff loads** — an agent's select or a refresh's re-read seen with the list unfolded.
public func gitListLoadingRow(_ s: GitSnapshot, opening: GitSelection?) -> GitSelection? {
    if let opening { return opening }
    if s.diff?.loading == true { return s.selection }
    return nil
}

/// Where the selection sits in step order: `index` from 0, of `count`.
public struct GitPosition: Sendable, Equatable {
    public var index: Int
    public var count: Int
}

public func gitPosition(_ s: GitSnapshot) -> GitPosition? {
    guard let selection = s.selection else { return nil }
    let rows = gitRows(s.roots)
    guard let i = rows.firstIndex(of: selection) else { return nil }
    return GitPosition(index: i, count: rows.count)
}

/// The line above the diff: `api / BookingController.php · 1 of 3 · ↑↓`. A selection the
/// list no longer holds names its file and no position.
public func gitDiffHeader(_ s: GitSnapshot) -> String? {
    guard let selection = s.selection else { return nil }
    let name = s.roots.first { $0.root == selection.root }?.name
        ?? (selection.root as NSString).lastPathComponent
    let head = "\(name) / \(selection.path)"
    guard let p = gitPosition(s) else { return head }
    return "\(head) · \(p.index + 1) of \(p.count) · ↑↓"
}

/// What the diff cannot show by itself: `binary · 2.1 MB`, or `file is 3.0 MB · first 2 MB
/// shown` — `git_show` cuts each side at 2 MB (`GitFileByteCap`), and `bytes` is the larger
/// side's true size. nil when the diff is whole.
public func gitDiffBanner(_ d: GitDiffState) -> String? {
    if d.binary { return "binary · \(gitByteSize(d.bytes))" }
    if d.truncated { return "file is \(gitByteSize(d.bytes)) · first 2 MB shown" }
    return nil
}

/// A size in 1,024s — `512 bytes`, `20 KB`, `2.1 MB` — formatted here rather than by
/// `ByteCountFormatter`, whose output follows the Mac's locale.
func gitByteSize(_ bytes: Int) -> String {
    let kb = 1024.0, value = Double(bytes)
    if value < kb { return "\(bytes) bytes" }
    if value < kb * kb { return "\(Int((value / kb).rounded())) KB" }
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.minimumFractionDigits = 1
    f.maximumFractionDigits = 1
    if value < kb * kb * kb { return "\(f.string(from: NSNumber(value: value / (kb * kb))) ?? "") MB" }
    return "\(f.string(from: NSNumber(value: value / (kb * kb * kb))) ?? "") GB"
}

// MARK: - Keys

/// The keys the git pane answers.
public enum GitPaneKey: Sendable, Equatable { case up, down, escape, `return` }

/// The modifiers a key arrives with — SwiftUI's `EventModifiers`, mirrored so the decision
/// below is testable here.
public struct GitKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = GitKeyModifiers(rawValue: 1 << 0)
    public static let control = GitKeyModifiers(rawValue: 1 << 1)
    public static let option = GitKeyModifiers(rawValue: 1 << 2)
    public static let command = GitKeyModifiers(rawValue: 1 << 3)
    public static let capsLock = GitKeyModifiers(rawValue: 1 << 4)
    public static let numericPad = GitKeyModifiers(rawValue: 1 << 5)
    public static let function = GitKeyModifiers(rawValue: 1 << 6)
}

/// Whether a key is a chord the pane leaves alone. **D1:** AppKit marks every arrow key with
/// `numericPad` and `function`, so "any modifier is a chord" ignored ↑↓ outright while Esc
/// and Return worked. Caps Lock is a state, not a hold.
public func gitPaneKeyIsChord(_ modifiers: GitKeyModifiers) -> Bool {
    !modifiers.subtracting([.capsLock, .numericPad, .function]).isEmpty
}

/// What a key does in the git pane.
public enum GitPaneKeyAction: Sendable, Equatable {
    /// `git_step` by this delta (folded).
    case step(Int)
    /// `git_unfold` (folded).
    case unfold
    /// Move the unfolded list's highlight by this delta.
    case moveHighlight(Int)
    /// `git_select` the highlighted row (unfolded).
    case selectHighlight
}

/// What `key` does, or nil when the pane must leave it alone — always while it does not own
/// the keyboard (an org plane, no organisation, or a confirmation over the canvas).
public func gitPaneKeyAction(_ key: GitPaneKey, folded: Bool, owner: Bool) -> GitPaneKeyAction? {
    guard owner else { return nil }
    switch (key, folded) {
    case (.up, true): return .step(-1)
    case (.down, true): return .step(1)
    case (.escape, true): return .unfold
    case (.up, false): return .moveHighlight(-1)
    case (.down, false): return .moveHighlight(1)
    case (.return, false): return .selectHighlight
    default: return nil
    }
}

/// Whether the diff host takes ↑↓ and Esc from Monaco: only while the pane can act on them.
public func gitDiffCapturesKeys(folded: Bool, owner: Bool) -> Bool { folded && owner }
