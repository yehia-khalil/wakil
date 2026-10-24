import Foundation

/// The editor pane (3b-i): tabs over the project's files and scratch buffers. Its contents are
/// its snapshot. The store owns every tab's text; Monaco mirrors it (`EditorRenderer`).
enum EditorPaneKind: PaneKind {
    static let names = ["editor"]
    static var emptyContents: EditorSnapshot { .empty }
    static var emptyShared: EditorShared { EditorShared() }
    static var emptySnapshot: EditorSnapshot? { .empty }
    static func snapshot(of contents: EditorSnapshot, in store: isolated PaneStore) -> EditorSnapshot { contents }

    /// Every key always present. Whole-file text is left out — the agent reads files itself — so
    /// "this line" resolves against what is on screen (Invariant 3). No key may be `kind` or `failure`.
    static func readPane(_ s: EditorSnapshot, in store: isolated PaneStore) -> [String: JSONValue] {
        func position(_ p: EditorPosition) -> JSONValue {
            .object(["line": .number(Double(p.line)), "column": .number(Double(p.column))])
        }
        var o: [String: JSONValue] = [:]
        o["tabs"] = .array(s.tabs.map { tab in
            var scratch: JSONValue = .null, path: JSONValue = .null, root: JSONValue = .null
            switch tab.subject {
            case .file(let p, let r): path = .string(p); root = .string(r)
            case .scratch(let n): scratch = .number(Double(n))
            case .diff: break
            }
            var diff: JSONValue = .null
            if case .diff(let r, let p, let g, let source) = tab.subject, let d = tab.diffState {
                diff = .object([
                    "root": .string(r), "path": .string(p), "group": .string(g.rawValue),
                    "stash": source?.stashID.map { .string($0) } ?? .null,
                    "commit": editorDiffSourceParams(source)["commit"] ?? .null,
                    "conflict": .bool(source == .conflict),
                    "loading": .bool(d.loading), "error": d.error.map { .string($0) } ?? .null,
                    "binary": .bool(d.binary), "bytes": .number(Double(d.bytes)), "lines": .number(Double(d.lines)),
                    "truncated": .bool(d.truncated), "no_longer_changed": .bool(d.noLongerChanged),
                    "language": .string(d.language)])
            }
            return .object([
                "path": path, "scratch": scratch, "root": root, "language": .string(tab.language),
                "dirty": .bool(tab.dirty), "disk_state": .string(tab.diskState.rawValue),
                "notice": tab.notice.map { .string($0) } ?? .null, "saving": .bool(tab.saving),
                "preview": .bool(tab.preview), "diff": diff,
            ])
        })
        o["active"] = s.active.map { .number(Double($0)) } ?? .null
        let tab = s.active.flatMap { $0 < s.tabs.count ? s.tabs[$0] : nil }
        o["cursor"] = tab.map { position($0.cursor) } ?? .null
        o["selection"] = tab?.selection.map { .object(["start": position($0.start), "end": position($0.end)]) } ?? .null
        o["visible_range"] = tab?.visibleRange.map {
            .object(["first": .number(Double($0.lowerBound)), "last": .number(Double($0.upperBound))])
        } ?? .null
        o["hunks"] = tab.flatMap { t in t.readOnly ? nil : t.baseline.map { base in
            .array(editorHunks(base: base, text: t.text).map { h in
                .object(["kind": .string(h.kind.rawValue), "line": .number(Double(h.newStart)),
                         "count": .number(Double(h.newCount))]) }) } } ?? .null
        o["peek"] = tab.flatMap(editorPeekView).map { v in
            .object(["index": .number(Double(v.index)), "count": .number(Double(v.count)),
                     "line": .number(Double(v.afterLine))]) } ?? .null
        o["visible_text"] = tab.flatMap { t in t.visibleRange.map { .string(editorLines(t.text, $0)) } } ?? .null
        o["selected_text"] = tab.flatMap { t in t.selection.map { .string(editorText(t.text, in: $0)) } } ?? .null
        o["column"] = s.column.map { c in .object([
            "shown": .bool(c.shown), "view": .string(c.view.rawValue), "width": .number(c.width),
            "open": .array(c.open.map { .string($0) }),
            "changes_closed": .array(c.changesClosed.sorted().map { .string($0) }),
            "changes_closed_groups": .array(editorChangesSortedGroups(c.changesClosedGroups).map { g in
                .object(["root": .string(g.root), "group": .string(g.group)]) }),
            "changes_highlight": c.changesHighlight.map { h in
                .object(["root": .string(h.root), "path": .string(h.path), "group": .string(h.group)]) } ?? .null,
        ]) } ?? .null
        let f = s.findReport.map { r in (r.query, r.caseSensitive, r.wholeWord, r.regex, JSONValue.number(Double(r.count)), r.shown) }
            ?? s.find.map { r in (r.query, r.caseSensitive, r.wholeWord, r.regex, JSONValue.null, true) }
        o["find"] = f.map { q, c, w, r, count, shown in .object([
            "query": .string(q), "case": .bool(c), "word": .bool(w), "regex": .bool(r), "count": count, "shown": .bool(shown)]) } ?? .null
        let q = s.search
        o["search"] = .object([
            "query": .string(q.query), "case": .bool(q.caseSensitive), "word": .bool(q.wholeWord), "regex": .bool(q.regex),
            "in_flight": .bool(q.inFlight), "truncated": .bool(q.truncated), "files_truncated": .bool(q.filesTruncated),
            "skipped_large": .array(q.skippedLarge.map { .string($0) }),
            "changed_since": .bool(q.changedSince), "cancelled": .bool(q.cancelled), "error": q.error.map { .string($0) } ?? .null,
            "results": .array(q.results.map { m in .object([
                "root": .string(m.root), "path": .string(m.path), "line": .number(Double(m.line)),
                "column": .number(Double(m.column)), "preview": .string(m.preview)]) }),
            "replace": q.replace.shown ? .string(q.replace.text) : .null,
            "replace_in_flight": .bool(q.replace.inFlight),
            "last_replace": q.replace.last.map(editorReplaceJSON) ?? .null,
        ])
        return o
    }
}

/// The editor kind's store-wide state: who listens for an editor pane's column or search to change
/// (`PaneStore.editorChanges()`).
struct EditorShared: Sendable {
    var changeSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]
}

extension PaneSnapshot {
    public var editor: EditorSnapshot? { contents as? EditorSnapshot }
}

extension EditorSnapshot: PaneKindSnapshot {}

extension EditorPaneKind: PaneRestorable {
    /// **An editor's subject is its saved tabs, not a fetch**: reopened by its own action, or a
    /// restored pane would be empty until the operator reopened every file. Nothing to restore
    /// when the layout saved neither tabs nor a column.
    static func restoreStep(for pane: Pane) -> PaneRestoreStep? {
        let hasTabs = !(pane.editorTabs ?? []).isEmpty
        guard hasTabs || pane.editorColumn != nil else { return nil }
        return PaneRestoreStep(action: "editor_restore", params: .object(["pane": .string(pane.id)]), recordsFailure: false)
    }
}
