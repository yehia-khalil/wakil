import Foundation

/// The two sides of a diff tab's diff (3a-i's, moved here with the Git pane in 3b-iii). The texts
/// are large, so `read_pane` publishes only the facts about them.
public struct GitDiffState: Sendable, Equatable {
    public var original: String
    public var modified: String
    public var language: String
    public var binary: Bool
    public var bytes: Int
    public var lines: Int
    public var truncated: Bool
    public var error: String?
    public var loading: Bool
    /// A diff tab's file is no longer in its group (committed, staged, discarded): the tab says so
    /// and stays open until closed, its last texts kept (3b-iii, Rule 7).
    public var noLongerChanged: Bool

    public init(original: String, modified: String, language: String, binary: Bool, bytes: Int,
                lines: Int, truncated: Bool, error: String?, loading: Bool, noLongerChanged: Bool = false) {
        self.original = original
        self.modified = modified
        self.language = language
        self.binary = binary
        self.bytes = bytes
        self.lines = lines
        self.truncated = truncated
        self.error = error
        self.loading = loading
        self.noLongerChanged = noLongerChanged
    }

    static func loading(_ language: String) -> GitDiffState {
        GitDiffState(original: "", modified: "", language: language, binary: false, bytes: 0, lines: 0,
                     truncated: false, error: nil, loading: true)
    }
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

/// The revisions a diff compares, by group (3a-i's, with deletions):
/// - Staged: HEAD against the index.
/// - Changes: the index against the working tree.
/// - Untracked: nothing against the working tree.
/// - Deleted (`D`): the original against nothing on the right, since nothing is left to read.
/// - Merge Changes (3a-v-b): HEAD against the working tree, because mid-merge the index holds stages,
///   not one version.
public func editorDiffRevs(_ group: GitGroup, status: String?) -> (original: String?, modified: String?) {
    let deleted = status == "D"
    switch group {
    case .conflicts: return ("HEAD", "worktree")
    case .staged: return ("HEAD", deleted ? nil : "index")
    case .changed: return ("index", deleted ? nil : "worktree")
    case .untracked: return (nil, "worktree")
    }
}

/// Whether ⌘⏎ (`editor_open_file`) may open a diff's file. No for a deleted file's diff, or for a
/// Staged diff whose file is gone from the working tree (a `D` in Changes).
public func editorDiffOpensFile(root: String, path: String, group: GitGroup, roots: [GitRootState]) -> Bool {
    guard let r = roots.first(where: { $0.root == root }) else { return true }
    let rows = r.files.filter { $0.path == path }
    if rows.contains(where: { $0.group == .changed && $0.status == "D" }) { return false }
    if rows.first(where: { $0.group == group })?.status == "D" { return false }
    return true
}

/// ⌘⏎ in a focused editor pane (R10): open the file when the active tab is a diff that may, else
/// it is Maximize Pane as everywhere else.
public func editorCommandReturnOpensFile(_ s: EditorSnapshot?, roots: [GitRootState]) -> Bool {
    guard let s, let i = s.active, i < s.tabs.count,
          case .diff(let root, let path, let group, nil) = s.tabs[i].subject else { return false }
    return editorDiffOpensFile(root: root, path: path, group: group, roots: roots)
}

/// A diff tab's own name for its group, in its title.
func editorDiffGroupTitle(_ g: GitGroup) -> String {
    switch g {
    case .conflicts: "Merge Changes"
    case .staged: "Staged"
    case .changed: "Changes"
    case .untracked: "Untracked"
    }
}

/// Which baseline fetch for a (pane, path) is the newest: a reply applies only if its generation is
/// still the latest, so an older reply landing late never overwrites a newer one. Synchronous, behind
/// a lock, taken when the fetch starts, before any await.
final class EditorBaselineGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: Int] = [:]
    private var counter = 0

    func next(_ pane: String, _ path: String) -> Int {
        lock.withLock { counter += 1; latest["\(pane)\u{0}\(path)"] = counter; return counter }
    }
    func isLatest(_ pane: String, _ path: String, _ gen: Int) -> Bool {
        lock.withLock { latest["\(pane)\u{0}\(path)"] == gen }
    }
}

/// One diff fetch per diff tab of each pane: a new fetch for a tab cancels its last, and a tab's
/// fetch is cancelled when its tab is replaced (Rules 4, 5), or every one of a pane's when the pane
/// is dropped (`PaneStore.onDrop`).
///
/// **Synchronous, behind a lock, so it can be called inside `PaneStore.updateEditor`** — the turn
/// that writes the tab also starts the fetch that owns it (as 3a-i's Git pane did, for the same reason).
final class EditorDiffFlights: @unchecked Sendable {
    private let lock = NSLock()
    private var flights: [String: [String: Task<Void, Never>]] = [:]   // pane -> tab key -> fetch

    func start(_ pane: String, key: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            flights[pane]?[key]?.cancel()
            let task = Task { await body() }
            flights[pane, default: [:]][key] = task
            return task
        }
    }

    func cancel(_ pane: String, key: String) {
        lock.withLock { _ = flights[pane]?.removeValue(forKey: key).map { $0.cancel() } }
    }

    func drop(_ pane: String) {
        lock.withLock { flights.removeValue(forKey: pane)?.values.forEach { $0.cancel() } }
    }
}
