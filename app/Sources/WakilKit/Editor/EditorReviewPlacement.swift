import Foundation

// Review threads drawn in the file (Ticket view, piece 2 of Ticket work; spec, *Review comments in
// the file*). GitHub gives a thread's line on its PR's head commit; WakilKit maps it through the
// diff between that commit's text of the file (`git_show` rev `commit:<sha>`) and the buffer — the
// same `editorHunks` the gutter marks use. The page only draws the boxes it is handed.

/// Where a thread's box is drawn, and why it may not be on GitHub's line: nil when the line
/// survives, `"line changed since"` when it was edited or removed locally, `"line may differ"` when
/// the PR's head commit is not in the local repo.
public struct ReviewPlacement: Sendable, Equatable {
    public let line: Int
    public let note: String?
    public init(line: Int, note: String?) { self.line = line; self.note = note }
}

public let reviewLineChanged = "line changed since"
public let reviewLineMayDiffer = "line may differ"

/// Maps GitHub's `line` on the head commit's text into `buffer`. No head text: the raw line, kept
/// inside the buffer, "line may differ". A line in an unchanged run moves by the lines added and
/// removed above it; one inside a changed or deleted hunk draws at the nearest surviving line above
/// it (else below), and one past the buffer's end at its last line, both "line changed since".
public func reviewPlacement(headText: String?, buffer: String, line: Int) -> ReviewPlacement {
    let count = max(1, editorHunkLines(buffer).count)
    func inside(_ l: Int) -> Int { min(max(1, l), count) }
    guard let headText else { return ReviewPlacement(line: inside(line), note: reviewLineMayDiffer) }
    var offset = 0   // new line minus old line, for the unchanged run being walked
    for h in editorHunks(base: headText, text: buffer) {
        let oldStart = h.newStart - offset, oldCount = h.oldLines.count
        if line < oldStart { break }
        if line < oldStart + oldCount {
            // Inside the lines this hunk replaced or removed: the line above it survives.
            let above = h.newStart - 1
            let below = h.newStart + h.newCount
            let at = above >= 1 ? above : below
            return ReviewPlacement(line: inside(at), note: reviewLineChanged)
        }
        offset += h.newCount - oldCount
    }
    let mapped = line + offset
    if mapped > count || mapped < 1 { return ReviewPlacement(line: inside(mapped), note: reviewLineChanged) }
    return ReviewPlacement(line: mapped, note: nil)
}

/// One thread's box as the page draws it (`wakilSetReviews`). Every text is other people's and is
/// set with `textContent`. `replies` are the comments after the first, their `createdAt` already
/// as shown; `position` is "1 of 5" among the branch's open threads, empty for a resolved one.
public struct ReviewBox: Sendable, Equatable, Encodable {
    public let thread: String
    public let line: Int
    public let note: String?
    public let author: String
    public let time: String
    public let text: String
    public let replies: [ReviewCommentState]
    public let position: String
    public let resolved: Bool
    public let resolvedBy: String?
    public let draft: String?
    public let sending: Bool
}

/// When a comment was written, as a box shows it: "24 Oct 09:00", local time; the text GitHub gave
/// when it is not a date.
func reviewTime(_ iso: String) -> String {
    let parse = ISO8601DateFormatter()
    guard let date = parse.date(from: iso) else { return iso }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "d MMM HH:mm"
    return f.string(from: date)
}

/// The boxes of the file at `path` (a file tab's path, under `root`), in line order: each of its
/// threads GitHub does not call outdated, open or resolved, placed against `buffer` with its PR's
/// head text from `headTexts` (keyed by head SHA; a SHA absent from it is not local). `threads` is
/// the branch's whole read: "1 of 5" counts its open threads of `root`. A thread resolved by
/// `viewer` says "you".
public func reviewBoxes(threads: [ReviewThreadState], path: String, root: String,
                        headTexts: [String: String], buffer: String, drafts: [String: String],
                        sending: Set<String>, viewer: String = "") -> [ReviewBox] {
    let mine = threads.filter { $0.root == root }
    let open = reviewOpenThreads([PullRequestState(number: 0, threads: mine)])
    var seen: Set<String> = []
    let boxes = mine.filter { !$0.outdated && root + "/" + $0.path == path && seen.insert($0.id).inserted }.map { t in
        let p = reviewPlacement(headText: headTexts[t.headSHA], buffer: buffer, line: max(1, t.line))
        let first = t.comments.first
        let who = t.resolvedBy.map { !viewer.isEmpty && $0 == viewer ? "you" : $0 }
        return ReviewBox(
            thread: t.id, line: p.line, note: p.note, author: first?.author ?? "", time: first.map { reviewTime($0.createdAt) } ?? "",
            text: first?.body ?? "",
            replies: t.comments.dropFirst().map { ReviewCommentState(author: $0.author, body: $0.body, createdAt: reviewTime($0.createdAt)) },
            position: t.resolved ? "" : reviewPosition(open, id: t.id), resolved: t.resolved, resolvedBy: t.resolved ? who : nil,
            draft: drafts[t.id], sending: sending.contains(t.id))
    }
    return boxes.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
}

// MARK: - What the editor panes draw from

/// A file's text at a PR's head commit: `path` is relative to `root`.
public struct EditorReviewHead: Sendable, Hashable {
    public let root: String
    public let path: String
    public let sha: String
    public init(root: String, path: String, sha: String) { self.root = root; self.path = path; self.sha = sha }
}

/// What the editor panes draw review boxes from, store-wide (`EditorShared.reviews`): each root's
/// read threads and its viewer, the drafts and the sends (`registerTicketActions` mirrors them from
/// `EditorTicketStore`), and the head texts read so far (`WindowModel+Ticket`). Draft text is here
/// for the page and never reaches `read_pane`.
public struct EditorReviewsState: Sendable, Equatable {
    public struct Root: Sendable, Equatable {
        public var viewer: String
        public var threads: [ReviewThreadState]
        public init(viewer: String, threads: [ReviewThreadState]) { self.viewer = viewer; self.threads = threads }
    }
    /// What the ticket store holds.
    public struct Reads: Sendable, Equatable {
        public var byRoot: [String: Root]
        public var drafts: [String: String]
        public var sending: Set<String>
        public init(byRoot: [String: Root] = [:], drafts: [String: String] = [:], sending: Set<String> = []) {
            self.byRoot = byRoot; self.drafts = drafts; self.sending = sending
        }
    }
    public var reads: Reads
    /// Each head text read; a key in `fetched` with no text here is not local (or the file is not
    /// at that commit).
    public var heads: [EditorReviewHead: String]
    public var fetched: Set<EditorReviewHead>

    public init(reads: Reads = Reads(), heads: [EditorReviewHead: String] = [:], fetched: Set<EditorReviewHead> = []) {
        self.reads = reads; self.heads = heads; self.fetched = fetched
    }
    public static let empty = EditorReviewsState()

    /// The thread by its id, in any root's read.
    public func thread(_ id: String) -> ReviewThreadState? {
        for r in reads.byRoot.values { if let t = r.threads.first(where: { $0.id == id }) { return t } }
        return nil
    }

    /// Keeps only the head texts some read thread still needs: a push moves the head, and the old
    /// commit's texts go.
    mutating func pruneHeads() {
        let live = Set(reads.byRoot.values.flatMap { $0.threads.map { "\($0.root)\u{1F}\($0.headSHA)" } })
        func keep(_ h: EditorReviewHead) -> Bool { live.contains("\(h.root)\u{1F}\(h.sha)") }
        heads = heads.filter { keep($0.key) }
        fetched = fetched.filter(keep)
    }
}

/// A file tab's path relative to its root; nil for any other tab, or a path outside its root.
private func editorReviewFile(_ tab: EditorTab) -> (root: String, path: String, rel: String)? {
    guard tab.diffState == nil, case .file(let path, let root) = tab.subject, path.hasPrefix(root + "/") else { return nil }
    return (root, path, String(path.dropFirst(root.count + 1)))
}

/// The file's drawn threads: not outdated, in this file of this root.
private func editorReviewThreads(_ f: (root: String, path: String, rel: String), _ reviews: EditorReviewsState) -> [ReviewThreadState] {
    (reviews.reads.byRoot[f.root]?.threads ?? []).filter { $0.root == f.root && $0.path == f.rel && !$0.outdated }
}

/// The head texts a file tab's boxes still need read: one per head SHA of its drawn threads.
public func editorReviewHeadsWanted(_ tab: EditorTab, _ reviews: EditorReviewsState) -> [EditorReviewHead] {
    guard let f = editorReviewFile(tab) else { return [] }
    var out: [EditorReviewHead] = []
    for t in editorReviewThreads(f, reviews) where !t.headSHA.isEmpty {
        let h = EditorReviewHead(root: f.root, path: f.rel, sha: t.headSHA)
        if !reviews.fetched.contains(h), !out.contains(h) { out.append(h) }
    }
    return out
}

/// A file tab's boxes, placed against `buffer` (the tab's text when nil). Nil for a diff or scratch
/// tab, and while a head text its threads need is still being read — a box drawn raw first would
/// jump when it lands. A file with no drawn threads has none.
public func editorReviewBoxes(_ tab: EditorTab, buffer: String? = nil, _ reviews: EditorReviewsState) -> [ReviewBox]? {
    guard let f = editorReviewFile(tab) else { return nil }
    guard editorReviewHeadsWanted(tab, reviews).isEmpty else { return nil }
    let root = reviews.reads.byRoot[f.root]
    var heads: [String: String] = [:]
    for (h, text) in reviews.heads where h.root == f.root && h.path == f.rel { heads[h.sha] = text }
    return reviewBoxes(threads: root?.threads ?? [], path: f.path, root: f.root, headTexts: heads,
                       buffer: buffer ?? tab.text, drafts: reviews.reads.drafts, sending: reviews.reads.sending,
                       viewer: root?.viewer ?? "")
}

/// The thread whose box is on the tab's cursor line, as placed (`read_pane`'s `cursorThread`, and
/// where `review_step` steps from).
public func editorCursorThread(_ tab: EditorTab?, _ reviews: EditorReviewsState) -> String? {
    guard let tab, let boxes = editorReviewBoxes(tab, reviews) else { return nil }
    return boxes.first { $0.line == tab.cursor.line }?.thread
}

/// The line a thread's file opens at: its box's, when `tab` (the file's open tab, if any) has it
/// placed; GitHub's otherwise.
public func editorReviewLine(_ t: ReviewThreadState, tab: EditorTab?, _ reviews: EditorReviewsState) -> Int {
    tab.flatMap { editorReviewBoxes($0, reviews) }?.first { $0.thread == t.id }?.line ?? max(1, t.line)
}

/// Sends the shown tab's review boxes when they differ from what `sent` says the page holds for
/// that key: only for a file tab, placed against `buffer` (the text the page holds, typing
/// included). A diff or scratch tab is sent nothing, and a file whose head texts are still being
/// read keeps what it shows.
@MainActor public func editorShowReviews(_ snapshot: EditorSnapshot, buffer: String?, reviews: EditorReviewsState,
                                         sent: inout [String: [ReviewBox]], to renderer: any EditorRenderer) {
    guard let i = snapshot.active, i < snapshot.tabs.count else { return }
    let tab = snapshot.tabs[i], key = editorTabKey(tab)
    guard let boxes = editorReviewBoxes(tab, buffer: buffer, reviews), boxes != (sent[key] ?? []) else { return }
    sent[key] = boxes
    renderer.setReviews(key: key, boxes: boxes)
}
