import AppKit
import SwiftUI
import WakilKit

/// 3a-v-a: what the Timeline reads and opens, handed in from the window.
struct EditorTimelineControls {
    /// One page of (root, relative path)'s commits from `skip`; nil when git could not read them.
    var load: (_ root: String, _ path: String, _ skip: Int) async -> [GitCommitInfo]? = { _, _, _ in nil }
    var openCommit: (_ root: String, _ ref: GitCommitRef) -> Void = { _, _ in }
}

/// The Timeline under the Files tree (VS Code's under the Explorer): the focused tab's file, newest
/// commit first, `Uncommitted changes` on top when it differs from HEAD, `Load more` at the end.
/// Collapsible; whether it is open is the viewer's own (R4).
struct EditorTimelineSection: View {
    /// (root, path relative to it), or nil: no file, a scratch tab.
    let subject: (root: String, path: String)?
    /// The Changes diff `Uncommitted changes` opens, or nil when the file matches HEAD.
    let uncommitted: GitGroup?
    /// Changes when the root's status does, so a commit made since shows.
    let refreshKey: String
    let controls: EditorTimelineControls
    let dispatch: (String, [String: JSONValue]) async -> Void

    @AppStorage("editor.timeline.open") private var open = true
    @State private var commits: [GitCommitInfo] = []
    @State private var more = false
    @State private var loading = false
    @State private var loadingMore = false

    private var subjectKey: String { subject.map { "\($0.root)|\($0.path)" } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(EditorPaneStyle.text.opacity(0.08)).frame(height: 1)
            header
            if open { list }
        }
        .accessibilityIdentifier("editor.timeline")
        // A new file cancels the old load (Rules 4, 5); a status change reloads the same file.
        .task(id: subjectKey + "#" + refreshKey) { await reload() }
    }

    private var header: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                Text("Timeline").font(.system(size: 10.5, weight: .semibold))
                if let subject {
                    Text("· " + (subject.path as NSString).lastPathComponent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(EditorPaneStyle.text.opacity(0.75))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("editor.timeline.toggle")
    }

    @ViewBuilder private var list: some View {
        let rows = editorTimelineRows(commits, uncommitted: uncommitted != nil, more: more)
        if subject == nil || (rows.isEmpty && !loading) {
            Text("No history for this file.")
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                .padding(.horizontal, 12).padding(.bottom, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in rowView(row, at: i, in: rows) }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    @ViewBuilder private func rowView(_ row: EditorTimelineRow, at i: Int, in rows: [EditorTimelineRow]) -> some View {
        switch row {
        case .uncommitted:
            line(title: "Uncommitted changes", detail: "", id: "editor.timeline.uncommitted") {
                guard let subject, let group = uncommitted else { return }
                Task { await dispatch("editor_changes_select", ["root": .string(subject.root), "path": .string(subject.path),
                                                                "group": .string(group.rawValue)]) }
            }
        case .commit(let c):
            // The short id in a `let`: the identifier harvest reads one plain interpolation per name.
            let short = String(c.id.prefix(7))
            line(title: c.subject, detail: "\(c.author) · \(editorRelativeAge(c.date))", id: "editor.timeline.row.\(short)") {
                guard let subject else { return }
                let older: GitCommitInfo? = { if i + 1 < rows.count, case .commit(let o) = rows[i + 1] { o } else { nil } }()
                controls.openCommit(subject.root, editorTimelineCommitRef(c, older: older))
            }
            .help([c.subject, c.body, "\(c.author) <\(c.email)>", c.date, c.id].filter { !$0.isEmpty }.joined(separator: "\n"))
            .contextMenu {
                Button("Copy Commit ID") { copy(c.id) }
                Button("Copy Commit Message") { copy(c.body.isEmpty ? c.subject : c.subject + "\n\n" + c.body) }
            }
        case .more:
            line(title: loadingMore ? "Loading…" : "Load more", detail: "", id: "editor.timeline.more") {
                Task { await loadMore() }
            }
            .disabled(loadingMore)
        }
    }

    private func line(title: String, detail: String, id: String, _ press: @escaping () -> Void) -> some View {
        Button(action: press) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11)).foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 10)).foregroundStyle(EditorPaneStyle.text.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func reload() async {
        guard let subject else { commits = []; more = false; return }
        loading = true
        defer { loading = false }
        let page = await controls.load(subject.root, subject.path, 0)
        guard !Task.isCancelled else { return }
        commits = page ?? []
        more = editorTimelineHasMore(pageCount: page?.count ?? 0)
    }

    private func loadMore() async {
        guard let subject, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let key = subjectKey
        let page = await controls.load(subject.root, subject.path, commits.count) ?? []
        guard key == subjectKey else { return }
        commits += page
        more = editorTimelineHasMore(pageCount: page.count)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
