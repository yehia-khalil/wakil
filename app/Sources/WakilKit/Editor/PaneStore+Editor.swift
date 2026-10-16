import Foundation

// The editor kind's store methods (3b-i).
extension PaneStore {
    public func editorSnapshot(paneId: String) -> EditorSnapshot { contents(EditorPaneKind.self, paneId) }

    /// Reads, changes and writes an editor pane's snapshot in one actor turn — the in-place update
    /// the pane-kinds work deferred to the editor. Same terms as `updateGit`: a pane this store holds
    /// nothing for gets an entry only when `create` says so.
    @discardableResult
    public func updateEditor<T: Sendable>(
        paneId: String, create: Bool = false, _ change: @Sendable (inout EditorSnapshot) -> T
    ) -> T {
        var s = editorSnapshot(paneId: paneId)
        let before = (column: s.column, inFlight: s.search.inFlight, replacing: s.search.replace.inFlight,
                      undoing: s.search.replace.undoing)
        let result = change(&s)
        if holdsContents(paneId: paneId) || create {
            setContents(EditorPaneKind.self, paneId, s)
            // A replace or its undo starting and ending inside its own dispatch too (the tick and
            // Cancel, Rule 5), as for search.
            if s.column != before.column || s.search.inFlight != before.inFlight
                || s.search.replace.inFlight != before.replacing
                || s.search.replace.undoing != before.undoing { publishEditorChange(paneId) }
        }
        return result
    }

    /// The id of every editor pane whose column or search-in-flight changes (final review C1).
    ///
    /// **Why the store, as `apiFlights()`.** The window redraws when a dispatch finishes, and
    /// `editor_search`, `editor_tree_expand` and `editor_tree` set their state, then await a tool
    /// call inside their own dispatch. No dispatch boundary falls while they wait, so the tick,
    /// Cancel, an opening folder and a just-shown column would never be drawn until it was over.
    /// `bufferingNewest(1)`: a wake-up, not a log.
    public func editorChanges() -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            var shared = kindState(EditorPaneKind.self)
            shared.changeSubscribers[key] = continuation
            setKindState(EditorPaneKind.self, shared)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribeEditorChanges(key) }
            }
        }
    }

    func unsubscribeEditorChanges(_ key: UUID) {
        var shared = kindState(EditorPaneKind.self)
        shared.changeSubscribers[key] = nil
        setKindState(EditorPaneKind.self, shared)
    }

    private func publishEditorChange(_ paneId: String) {
        for continuation in kindState(EditorPaneKind.self).changeSubscribers.values { continuation.yield(paneId) }
    }

    /// `updateEditor` in `scope`, which need not be the active one — the unsaved prompt's Save of a
    /// tab left in a scope that is not on screen. One actor turn, like `updateEditor`.
    @discardableResult
    public func updateEditor<T: Sendable>(
        in scope: LayoutScope, paneId: String, _ change: @Sendable (inout EditorSnapshot) -> T
    ) -> T {
        inScope(scope) { updateEditor(paneId: paneId, change) }
    }

    /// `updateEditor` in the active scope, answering that scope with the result in the same actor
    /// turn: a run that claims a pane and then awaits (a replace, its undo) finishes in the scope it
    /// claimed in, even if the operator switches project or conversation meanwhile (as Api's
    /// `flightScope`).
    public func updateEditorNamingScope<T: Sendable>(
        paneId: String, create: Bool = false, _ change: @Sendable (inout EditorSnapshot) -> T
    ) -> (scope: LayoutScope, result: T) {
        (activeScope, updateEditor(paneId: paneId, create: create, change))
    }

    /// Every editor pane the store holds, in the active scope and in every other, with the file paths of
    /// its tabs: `editor_replace` skips all of those paths on disk and edits their buffers instead
    /// (3b-ii-b pre-flight F2: a project or conversation switch keeps a scope's panes in memory).
    public func editorPanesInEveryScope() -> [EditorPaneRef] {
        var out: [EditorPaneRef] = []
        for entry in everyScope(EditorPaneKind.self) {
            var paths: [String] = []
            for t in entry.contents.tabs { if let path = t.path { paths.append(path) } }
            out.append(EditorPaneRef(scope: entry.scope, paneId: entry.paneId, paths: paths))
        }
        return out
    }

    /// `readPane` of an editor pane in `scope`, which need not be the active one.
    public func editorReadPane(in scope: LayoutScope, paneId: String) -> JSONValue {
        inScope(scope) { readPane(paneId: paneId, kind: "editor") }
    }

    /// `editorSnapshot` in `scope`, which need not be the active one.
    public func editorSnapshot(in scope: LayoutScope, paneId: String) -> EditorSnapshot {
        inScope(scope) { editorSnapshot(paneId: paneId) }
    }

    /// Every dirty editor tab in a scope that is **not** on screen (final review I3): a project or
    /// conversation switch keeps them in memory, so quitting or switching organisation would drop
    /// them. `place` says where each one is for the prompt: the other project's name, or "another
    /// conversation" in this project.
    public func editorDirtyTabsInHiddenScopes() -> [EditorHiddenDirtyTab] {
        let here = activeScope
        var out: [EditorHiddenDirtyTab] = []
        for entry in everyScope(EditorPaneKind.self) where !entry.active {
            let titles = editorTabTitles(entry.contents.tabs)
            for (i, t) in entry.contents.tabs.enumerated() where t.dirty {
                let place = entry.scope.project != here.project ? entry.scope.project : "another conversation"
                out.append(EditorHiddenDirtyTab(scope: entry.scope, paneId: entry.paneId, subject: t.subject,
                                                title: titles[i], place: place, text: t.text))
            }
        }
        return out
    }

    /// **The one non-action path** (design-language §11: the editor's text surface is the one
    /// partial exception to dual-drive). The operator's keystrokes land here, debounced by the view;
    /// nothing else may call it. A tab gone or read-only is left alone.
    ///
    /// **By subject, never by position.** The view's post crosses actor hops; a tab closed or
    /// opened meanwhile moves every position after it, and a post addressed by index would write
    /// one file's buffer into another's. The subject is resolved inside this turn; a post whose tab
    /// is gone is dropped.
    ///
    /// **`basis` is the agent-edit serial the page had applied when it posted `text`.** The page
    /// posts the whole model, so a post made before an agent edit reached it would write that edit
    /// away; such a post (basis older than the tab's `lastAgentEdit`) is dropped, and the view resets
    /// the page to the store's text (`editorTypingPost`).
    public func editorBufferDidChange(paneId: String, subject: EditorTabSubject, text: String, basis: Int) {
        updateEditor(paneId: paneId) { s in
            guard let i = s.tabs.firstIndex(where: { $0.subject == subject }), !s.tabs[i].readOnly,
                  s.tabs[i].text != text, basis >= (s.tabs[i].lastAgentEdit?.serial ?? 0) else { return }
            s.tabs[i].text = text
            s.tabs[i].edits += 1
            s.tabs[i].preview = false   // an edit keeps a preview tab (spec)
            s.tabs[i].peek = nil        // typing closes the peek (spec); the marks stay
        }
    }

    /// What Monaco's find bar says now — query, switches, count, shown. A view report like the
    /// cursor's (`editorViewDidReport`), never a text change.
    public func editorFindDidReport(paneId: String, report: EditorFindReport) {
        updateEditor(paneId: paneId) { s in s.findReport = report }
    }

    /// Cursor, selection, visible lines and scroll as Monaco last reported them. Not a text change.
    /// By subject, for `editorBufferDidChange`'s reason.
    public func editorViewDidReport(
        paneId: String, subject: EditorTabSubject, cursor: EditorPosition, selection: EditorRange?,
        visibleRange: ClosedRange<Int>?, scrollTop: Double
    ) {
        updateEditor(paneId: paneId) { s in
            guard let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
            s.tabs[i].cursor = cursor
            s.tabs[i].selection = selection
            // No visible lines means Monaco has no layout (its web view is detached or not sized
            // yet), so its scroll is not one: the last real view stands until the next report.
            guard let visibleRange else { return }
            s.tabs[i].visibleRange = visibleRange
            s.tabs[i].scrollTop = scrollTop
        }
    }
}

/// A dirty editor tab in a scope that is not on screen (`PaneStore.editorDirtyTabsInHiddenScopes`).
public struct EditorHiddenDirtyTab: Sendable, Equatable {
    public let scope: LayoutScope
    public let paneId: String
    public let subject: EditorTabSubject
    public let title: String
    /// Where it is: the other project's name, or "another conversation".
    public let place: String
    public let text: String
}

/// An editor pane in some scope (`PaneStore.editorPanesInEveryScope`).
public struct EditorPaneRef: Sendable {
    public let scope: LayoutScope
    public let paneId: String
    public let paths: [String]
}
