import Foundation

/// Errors the editor actions raise for reasons of their own. Each reads whole (Rule 8).
public enum EditorActionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsavedEdits(path: String)
    case noScratchPath
    case noTab(action: String)
    case notAFile(action: String)
    case readOnly(action: String, path: String, notice: String?)
    /// Save-as onto a file that exists: written only with `replace` (Rule 1 — destroying asks).
    case targetExists(path: String)
    /// Save-as onto a path another tab of the pane already holds: two tabs never share a subject.
    case alreadyOpen(path: String, tab: String)
    /// `editor_replace_undo` with no replace to undo (the one refusal Rule 7 allows: nothing to override).
    case nothingToUndo
    /// `editor_open_file` from a tab that is not a Changes diff.
    case notADiff(action: String)
    /// `editor_open_file` on a diff whose file is gone from the working tree.
    case fileGone(path: String)
    /// The active tab has no change marks: untracked, outside a repository, scratch, read-only, or a diff.
    case noMarks(action: String)
    /// `editor_peek` on a line with no mark.
    case noChange(line: Int)
    /// `editor_peek_step` with no peek open.
    case noPeek(action: String)
    /// An action that reads a buffer, on a Changes diff tab, which has none (`editor_find`).
    case diffTab(action: String)
    /// `editor_replace_range` whose `expect` is no longer the text in its range: nothing is replaced.
    case staleRange(action: String, path: String)

    public var description: String {
        switch self {
        case .unsavedEdits(let path):
            "editor_close: \(path) has unsaved edits; save it, or close with discard true to drop them"
        case .noScratchPath:
            "editor_save: a scratch tab needs a path to save as (as, an absolute path inside a root)"
        case .noTab(let action): "\(action): the editor pane has no open tab"
        case .notAFile(let action): "\(action): the tab is a scratch buffer, not a file"
        case .readOnly(let action, let path, let notice):
            "\(action): \((path as NSString).lastPathComponent) is open read-only"
                + (notice.map { " (\($0))" } ?? "")
                + "; it cannot be \(action == "editor_save" ? "saved" : "changed") from the editor"
        case .targetExists(let path):
            "editor_save: \(path) already exists; save with replace true to write over it, or pick another path"
        case .alreadyOpen(let path, let tab):
            "editor_save: \(path) is already open in this pane as tab \(tab); save into that tab, or pick another path"
        case .notADiff(let action): "\(action): the active tab is not a Changes diff; it opens a diff's file"
        case .fileGone(let path):
            "editor_open_file: \(path) is deleted in the working tree, so there is no file to open"
        case .noMarks(let action):
            "\(action): the active tab has no change marks (it is untracked, outside a repository, a scratch or read-only tab, or a diff)"
        case .noChange(let line): "editor_peek: line \(line) has no change mark"
        case .noPeek(let action): "\(action): no peek is open; open one with editor_peek on a marked line"
        case .diffTab(let action):
            "\(action): the active tab is a Changes diff, which has no buffer to search; open its file "
                + "(editor_open_file, ⌘⏎) and find there"
        case .staleRange(let action, let path):
            "\(action): the text in range of \((path as NSString).lastPathComponent) is no longer what expect says "
                + "(the buffer changed since the range was read), so nothing was replaced; read the pane again "
                + "and retry against the text as it is now"
        case .nothingToUndo:
            "editor_replace_undo: this pane has no replace to undo; only its latest replace can be undone, "
                + "once, while the window is open"
        }
    }
}

private func jsonObject(_ v: JSONValue) -> [String: JSONValue]? {
    if case .object(let o) = v { return o }
    return nil
}

private enum FilesOutcome: Sendable { case ok([String: JSONValue]); case failed(String) }

/// One `editor_search` run per pane, ordered by the pane's search serial. It holds the task that
/// makes the tool call itself, so cancelling it stops `files_search` (Rule 4), not a wrapper waiting
/// on it. The serial is taken in the pane's store and the run registered here in a later hop, so
/// two calls (or a call and a cancel) may arrive out of order: a run or cancel never touches one
/// with a higher serial, and a start older than what is held never runs its body.
actor EditorSearchRuns<Value: Sendable> {
    private var held: [String: (serial: Int, task: Task<Value, Error>?)] = [:]

    /// Starts `pane`'s search `serial`, cancelling an older one. Already overtaken (a newer search
    /// or a cancel registered first): an already-cancelled task whose body never runs.
    func start(_ pane: String, serial: Int, _ body: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
        if let h = held[pane], h.serial >= serial { return Task { throw CancellationError() } }
        held[pane]?.task?.cancel()
        let t = Task { try await body() }
        held[pane] = (serial, t)
        return t
    }

    /// Cancels the run older than `serial`, and any that registers later with a serial up to it.
    func cancel(_ pane: String, serial: Int) {
        if let h = held[pane], h.serial > serial { return }
        held[pane]?.task?.cancel()
        held[pane] = (serial, nil)
    }

    /// Lets go of a finished run's task; its serial still orders what comes later.
    func finish(_ pane: String, serial: Int) {
        if held[pane]?.serial == serial { held[pane]?.task = nil }
    }
}

private func filesTool(_ files: any ToolCaller, _ name: String, _ args: [String: JSONValue],
                       timeout: TimeInterval = MCPClient.readReplyTimeout) async throws -> FilesOutcome {
    let result: JSONValue
    do {
        result = try await files.callTool(name: name, arguments: .object(args), timeout: timeout)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if Task.isCancelled { throw CancellationError() }
        return .failed(String(describing: error))
    }
    guard case .object(let obj) = result else { return .failed("\(name) answered with no object") }
    if case .bool(true)? = obj["isError"] { return .failed(mcpErrorText(from: obj) ?? "\(name) failed with no message") }
    guard case .object(let content)? = obj["structuredContent"] else { return .failed("\(name) answered with no structuredContent") }
    return .ok(content)
}

/// Thrown when wakil-files refused or failed: its text, whole.
struct EditorFilesError: Error, CustomStringConvertible { let description: String }

private func position(_ v: JSONValue?) -> EditorPosition? {
    guard case .object(let o)? = v, let line = o["line"]?.intValue else { return nil }
    return EditorPosition(line: line, column: o["column"]?.intValue ?? 1)
}

private func editorRange(_ v: JSONValue?) -> EditorRange? {
    guard case .object(let o)? = v, let s = position(o["start"]), let e = position(o["end"]) else { return nil }
    return EditorRange(start: s, end: e)
}

private func megabytes(_ bytes: Int) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }

/// A tab from a `files_read` reply. Over the cap, binary or not UTF-8 opens read-only with a notice.
func editorTab(fromRead o: [String: JSONValue], path: String, root: String) -> EditorTab {
    let name = (path as NSString).lastPathComponent
    let text: String = { if case .string(let s)? = o["text"] { s } else { "" } }()
    var tab = EditorTab.file(path: path, root: root, text: text, mtime: Int64(o["mtime"]?.intValue ?? 0),
                             language: editorLanguage(forPath: path))
    if o["exists"] == .bool(false) { tab.diskState = .deleted }
    if o["over_cap"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is \(megabytes(o["size"]?.intValue ?? 0)); files over 2 MB open in 3b-v"
    } else if o["binary"] == .bool(true) {
        tab.readOnly = true
        tab.notice = "\(name) is a binary file"
    } else if o["utf8"] == .bool(false) {
        tab.readOnly = true
        tab.notice = "\(name) is not UTF-8; it opens read-only"
    }
    return tab
}

/// What a tab becomes after re-reading its file (spec, Data flow: disk changes). `read` is the tab
/// a fresh `files_read` made. The operator's cursor, scroll, language and view are always kept.
func editorAfterDiskRead(_ tab: EditorTab, read: EditorTab) -> EditorTab {
    var out = editorAfterDiskReadRaw(tab, read: read)
    out.peek = editorPeekClamped(out.peek, baseline: out.baseline, text: out.text)   // R12; nil when read-only
    return out
}

private func editorAfterDiskReadRaw(_ tab: EditorTab, read: EditorTab) -> EditorTab {
    var t = tab        // keeps `baseline` (the index text is not the disk's)
    if read.diskState == .deleted {
        t.diskState = .deleted
        return t
    }
    if read.mtime == tab.mtime && tab.diskState != .deleted { return tab }
    t.mtime = read.mtime
    t.readOnly = read.readOnly
    if t.readOnly { t.baseline = nil }       // a read-only tab has no marks
    t.notice = read.notice ?? (tab.notice == nil ? nil : tab.notice)
    if read.text == tab.text {
        t.savedText = read.text
        t.diskState = .inSync
    } else if !tab.dirty {
        t.text = read.text
        t.savedText = read.text
        t.edits += 1
        t.diskState = .inSync
    } else {
        t.diskState = .changedOnDisk
    }
    return t
}

/// Registers the editor pane's actions (3b-i).
///
/// **One path for the operator and the agent** (Invariant 2): ⌘P, ⌘T, ⌘S, ⌘W and the pane's buttons
/// dispatch these. The operator's typing is the one exception (`PaneStore.editorBufferDidChange`).
/// Each answers the pane's `read_pane` plus its `pane` id.
public func registerEditorActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    files: (any ToolCaller)?,
    fileLists: EditorFileLists?,
    gitStatus: GitStatus?,
    roots: @escaping @Sendable () async -> [String]
) async {
    @Sendable func requireFiles(_ action: String) throws -> any ToolCaller {
        guard let files else { throw StandardActionError.missingClient(action: action, role: "files") }
        return files
    }

    /// The named pane, else the focused editor pane, else the first, else a new one.
    @Sendable func editorPane(_ params: JSONValue, action: String) async throws -> String {
        if let pane = optionalString(params, "pane"), !pane.isEmpty {
            try await requireOpenPane(pane, action: action, layout: layout)
            return pane
        }
        guard let layout else { throw StandardActionError.missingParam(action: action, param: "pane") }
        let snap = await layout.snapshot()
        let editors = snap.panes.filter { $0.kind == "editor" }
        if let focused = snap.focusedId, editors.contains(where: { $0.id == focused }) { return focused }
        if let first = editors.first { return first.id }
        return await layout.open(kind: "editor", title: Pane.defaultTitle(kind: "editor")).id
    }

    /// The pane's `read_pane` plus its id — in `scope` when given (a run that claimed the pane there).
    @Sendable func reply(_ pane: String, in scope: LayoutScope? = nil) async -> JSONValue {
        let read = if let scope { await panes.editorReadPane(in: scope, paneId: pane) }
                   else { await panes.readPane(paneId: pane, kind: "editor") }
        guard case .object(var o) = read else { return .null }
        o["pane"] = .string(pane)
        return .object(o)
    }

    @Sendable func persist(_ pane: String) async {
        await layout?.setEditorTabs(id: pane, to: editorSavedTabs(panes.editorSnapshot(paneId: pane)))
    }

    /// The standardized `path` and the root holding it, or the refusal Rule 7 allows (an invariant
    /// forbids it). Standardized first, so `/p/api/../web/x` is `/p/web/x`, in root `/p/web`.
    @Sendable func confine(_ path: String, action: String) async throws -> (path: String, root: String) {
        let clean = (path as NSString).standardizingPath
        for r in await roots() where clean == r || clean.hasPrefix(r + "/") { return (clean, r) }
        throw EditorFilesError(description: "\(action): \(clean) is outside the active project's roots; "
            + "editor reads and writes are confined to them (Invariant 6, Decision 36)")
    }

    /// The pane's column, else the layout's copy of it, else the one last left in any editor pane
    /// (without its open folders).
    @Sendable func column(_ pane: String) async -> EditorColumnState {
        if let c = await panes.editorSnapshot(paneId: pane).column { return c }
        // The layout's own copy for the pane (a relaunch before `editor_restore` has put it back).
        if let c = await layout?.editorColumn(id: pane) { return c }
        return await layout?.editorColumnDefault() ?? .initial
    }

    @Sendable func setColumn(_ pane: String, _ c: EditorColumnState, asDefault: Bool = true) async {
        await panes.updateEditor(paneId: pane, create: true) { s in s.column = c }
        await layout?.setEditorColumn(id: pane, to: c, asDefault: asDefault)
    }

    let columnWrites = EditorColumnWrites()

    /// The one way a column changes (final review I2): read, `change`, then write the pane store and
    /// the layout, one pane's writes at a time — so tree actions in flight together never drop each
    /// other's open folders or view, and both stores end on the same copy. `onlyIfChanged` leaves a
    /// pane whose column `change` kept as it was unwritten.
    @Sendable @discardableResult
    func updateColumn(_ pane: String, onlyIfChanged: Bool = false, asDefault: Bool = true,
                      _ change: @escaping @Sendable (inout EditorColumnState) -> Void) async -> EditorColumnState {
        await columnWrites.serially(pane) {
            let before = await column(pane)
            var c = before
            change(&c)
            if !onlyIfChanged || c != before { await setColumn(pane, c, asDefault: asDefault) }
            return c
        }
    }

    /// `root`, `path` and `group` as a Changes row, refused as 3a-i refused them: a missing param, a
    /// group that is not staged, changed or untracked, or a root outside the project (naming the roots).
    @Sendable func changesRow(_ params: JSONValue, action: String) async throws -> EditorChangesRow {
        for key in ["root", "path", "group"] where optionalString(params, key) == nil {
            throw StandardActionError.missingParam(action: action, param: key)
        }
        let root = optionalString(params, "root")!, path = optionalString(params, "path")!
        let group = optionalString(params, "group")!
        guard GitGroup(rawValue: group) != nil else { throw GitActionError.unknownGroup(action: action, group: group) }
        let all = await roots()
        guard all.contains(root) else { throw GitActionError.notAProjectRoot(action: action, root: root, roots: all) }
        return EditorChangesRow(root: root, path: path, group: group)
    }

    @Sendable func projectRoot(_ params: JSONValue, action: String) async throws -> String {
        guard let root = optionalString(params, "root") else { throw StandardActionError.missingParam(action: action, param: "root") }
        let all = await roots()
        guard all.contains(root) else { throw GitActionError.notAProjectRoot(action: action, root: root, roots: all) }
        return root
    }

    /// The root holding `path`, and `path` relative to it; refused outside the roots (Rule 7's one refusal).
    @Sendable func treePath(_ raw: String, action: String) async throws -> (path: String, root: String, rel: String) {
        let c = try await confine(raw, action: action)
        return (c.path, c.root, c.path == c.root ? "" : String(c.path.dropFirst(c.root.count + 1)))
    }

    @Sendable func read(_ path: String, action: String) async throws -> EditorTab {
        let c = try await confine(path, action: action)
        switch try await filesTool(try requireFiles(action), "files_read", ["path": .string(c.path)]) {
        case .failed(let text): throw EditorFilesError(description: text)
        case .ok(let o): return editorTab(fromRead: o, path: c.path, root: c.root)
        }
    }

    /// The optional `path` param, standardized: which tab an action means (else the active one).
    @Sendable func tabPath(_ params: JSONValue) -> String? {
        optionalString(params, "path").map { ($0 as NSString).standardizingPath }
    }

    /// The optional `scratch` param: a scratch tab by its number (Untitled-N).
    @Sendable func tabScratch(_ params: JSONValue) -> Int? { jsonObject(params)?["scratch"]?.intValue }

    /// The optional `diff` param ({root, path, group}): a diff tab by its subject.
    @Sendable func tabDiff(_ params: JSONValue) -> EditorTabSubject? {
        guard case .object(let d)? = jsonObject(params)?["diff"], case .string(let r)? = d["root"],
              case .string(let p)? = d["path"], case .string(let g)? = d["group"], let group = GitGroup(rawValue: g)
        else { return nil }
        return .diff(root: r, path: p, group: group)
    }

    // The diff tabs (3b-iii). Local functions are visible only to what is declared after them, so these
    // sit above every action that uses them.
    let diffFlights = EditorDiffFlights()
    let baselineGenerations = EditorBaselineGenerations()
    await panes.onDrop { pane in diffFlights.drop(pane) }

    /// Fetches `subject`'s two sides into its tab, as that tab's one flight. Called only inside the
    /// `updateEditor` turn that wrote the tab (see `EditorDiffFlights`). A reply that lands after its
    /// tab is gone, or after a newer fetch for it began, writes nothing.
    @Sendable func fetchDiff(_ pane: String, _ subject: EditorTabSubject, status: String?) -> Task<Void, Never>? {
        guard case .diff(let root, let path, let group) = subject else { return nil }
        let language = editorLanguage(forPath: path)
        let key = "diff:\(group.rawValue):\(root)/\(path)"
        guard let git = gitStatus?.git else {
            // No git client: Loading must still resolve (Rules 4, 8), into the error that names what is missing.
            let text = StandardActionError.missingClient(action: "git_show", role: "git").description
            return diffFlights.start(pane, key: key) {
                await panes.updateEditor(paneId: pane) { s in
                    guard let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
                    s.tabs[i].diffState = GitDiffState(
                        original: "", modified: "", language: language, binary: false, bytes: 0, lines: 0,
                        truncated: false, error: text, loading: false,
                        noLongerChanged: s.tabs[i].diffState?.noLongerChanged ?? false)
                }
            }
        }
        let revs = editorDiffRevs(group, status: status)
        @Sendable func side(_ rev: String?) async throws -> FilesOutcome {
            guard let rev else { return .ok([:]) }
            return try await filesTool(git, "git_show", ["root": .string(root), "path": .string(path), "rev": .string(rev)])
        }
        return diffFlights.start(pane, key: key) {
            let outcome: (FilesOutcome, FilesOutcome)
            do {
                async let o = side(revs.original)
                async let m = side(revs.modified)
                outcome = try await (o, m)
            } catch {
                return   // cancelled: the fetch that replaced this one owns the tab now
            }
            if Task.isCancelled { return }
            await panes.updateEditor(paneId: pane) { s in
                guard !Task.isCancelled, let i = s.tabs.firstIndex(where: { $0.subject == subject }) else { return }
                let gone = s.tabs[i].diffState?.noLongerChanged ?? false
                switch outcome {
                case (.failed(let text), _), (_, .failed(let text)):
                    s.tabs[i].diffState = GitDiffState(original: "", modified: "", language: language, binary: false,
                                                       bytes: 0, lines: 0, truncated: false, error: text, loading: false,
                                                       noLongerChanged: gone)
                case (.ok(let o), .ok(let m)):
                    func text(_ x: [String: JSONValue]) -> String { if case .string(let t)? = x["text"] { t } else { "" } }
                    func lines(_ t: String) -> Int { t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count }
                    let original = text(o), modified = text(m)
                    s.tabs[i].diffState = GitDiffState(
                        original: original, modified: modified, language: language,
                        binary: o["binary"] == .bool(true) || m["binary"] == .bool(true),
                        bytes: max(o["bytes"]?.intValue ?? 0, m["bytes"]?.intValue ?? 0),   // a deletion's size is its original's
                        lines: max(lines(original), lines(modified)),
                        truncated: o["truncated"] == .bool(true) || m["truncated"] == .bool(true),
                        error: nil, loading: false, noLongerChanged: gone)
                }
            }
        }
    }

    /// Starts fetching the index text of `path` (in `root`) into every tab of `pane` showing it, or nil
    /// there when git cannot show it (untracked, not a repository, binary, cut at the cap). A tab gone
    /// or read-only by the time it lands is left alone.
    ///
    /// **Started, not awaited, by the actions that open or reload a tab** (final review 2): a baseline
    /// is best-effort, and a `git_show` that takes its 10 s timeout must not hold up the open (Rule 8).
    /// The generation is taken here, synchronously, so call order is still start order and a late
    /// reply never overwrites a newer one; the write wakes the window (`PaneStore.updateEditor`).
    @discardableResult
    @Sendable func startBaseline(_ pane: String, path: String, root: String) -> Task<Void, Never>? {
        guard let git = gitStatus?.git, path.hasPrefix(root + "/") else { return nil }
        let gen = baselineGenerations.next(pane, path)
        let rel = String(path.dropFirst(root.count + 1))
        return Task {
            let base: String?
            switch try? await filesTool(git, "git_show", ["root": .string(root), "path": .string(rel), "rev": .string("index")]) {
            case .ok(let o)? where o["binary"] != .bool(true) && o["truncated"] != .bool(true)
                                   && o["absent"] != .bool(true):   // untracked: no baseline, not an empty one
                if case .string(let t)? = o["text"] { base = t } else { base = nil }
            default:
                base = nil
            }
            if Task.isCancelled { return }
            await panes.updateEditor(paneId: pane) { s in
                guard baselineGenerations.isLatest(pane, path, gen) else { return }
                for i in s.tabs.indices where s.tabs[i].path == path && !s.tabs[i].readOnly {
                    s.tabs[i].baseline = base
                    s.tabs[i].peek = editorPeekClamped(s.tabs[i].peek, baseline: base, text: s.tabs[i].text)
                }
            }
        }
    }

    /// Opens `path` in `pane` — focusing its tab if open — with the cursor at `at` and `selection`, as a
    /// preview when asked (3b-ii). `editor_open`'s body, shared with `editor_open_file`.
    @Sendable func openFile(_ pane: String, path: String, at line: EditorPosition?, selection: EditorRange?,
                            preview: Bool, action: String) async throws {
        @Sendable func place(_ t: inout EditorTab) {
            guard let line else { return }
            t.cursor = selection?.end ?? line
            if let selection { t.selection = selection }
        }
        let keep = !preview
        let focused = await panes.updateEditor(paneId: pane, create: true) { s -> Bool in
            guard let i = s.tabs.firstIndex(where: { $0.path == path }) else { return false }
            s.active = i
            place(&s.tabs[i])
            if keep { s.tabs[i].preview = false }
            return true
        }
        if !focused {
            var fresh = try await read(path, action: action)
            place(&fresh)
            let tab = fresh
            await panes.updateEditor(paneId: pane, create: true) { s in
                if let i = s.tabs.firstIndex(where: { $0.path == path }) {
                    s.active = i
                } else if preview, let p = s.tabs.firstIndex(where: { $0.preview && !$0.dirty }) {
                    diffFlights.cancel(pane, key: editorTabKey(s.tabs[p]))
                    var t = tab; t.preview = true
                    s.tabs[p] = t
                    s.active = p
                } else {
                    var t = tab; t.preview = preview
                    s.tabs.append(t)
                    s.active = s.tabs.count - 1
                }
            }
            if !tab.readOnly, case .file(_, let root) = tab.subject {
                startBaseline(pane, path: tab.path ?? path, root: root)
            }
        }
        await persist(pane)
    }

    /// Opens `row`'s diff tab under the preview rule (3b-ii): a tab already open is focused (and
    /// pinned by `pin`) and not fetched again (Rule 5); otherwise a preview takes the pane's clean
    /// preview slot, cancelling the fetch of what it held, and a pinned one is added. A row no longer
    /// in its group opens reading "No longer changed" (Rule 7), fetching nothing.
    @Sendable func openDiff(_ pane: String, _ row: EditorChangesRow, pin: Bool) async {
        let group = GitGroup(rawValue: row.group)!
        let subject = EditorTabSubject.diff(root: row.root, path: row.path, group: group)
        let status = await gitStatus?.roots ?? []
        let file = editorChangesFile(row, in: status)
        let listed = status.first { $0.root == row.root }.map(editorRootIsKnown) ?? false
        let gone = listed && file == nil
        let flight: Task<Void, Never>? = await panes.updateEditor(paneId: pane, create: true) { s in
            if let i = s.tabs.firstIndex(where: { $0.subject == subject }) {
                s.active = i
                if pin { s.tabs[i].preview = false }
                return nil
            }
            var tab = EditorTab.diff(root: row.root, path: row.path, group: group)
            tab.preview = !pin
            if gone { tab.diffState?.loading = false; tab.diffState?.noLongerChanged = true }
            if !pin, let p = s.tabs.firstIndex(where: { $0.preview && !$0.dirty }) {
                diffFlights.cancel(pane, key: editorTabKey(s.tabs[p]))
                s.tabs[p] = tab
                s.active = p
            } else {
                s.tabs.append(tab)
                s.active = s.tabs.count - 1
            }
            return gone ? nil : fetchDiff(pane, subject, status: file?.status)
        }
        await updateColumn(pane, asDefault: false) { c in c.changesHighlight = row }
        await persist(pane)     // a preview file tab may have been replaced
        await flight?.value
    }

    /// The pane's git state after the window's status changed under `root` (or every root): the
    /// Changes highlight moves per Rule 6, and every diff tab under the root re-reads. Every file tab
    /// under it re-fetches its baseline (3b-iii).
    @Sendable func refreshGit(_ pane: String, root: String?) async {
        let status = await gitStatus?.roots ?? []
        await updateColumn(pane, onlyIfChanged: true, asDefault: false) { c in
            c.changesHighlight = editorChangesResolve(c.changesHighlight, roots: status)
        }
        // Every open diff tab under the root re-reads, keeping its texts while it loads (no blank flash).
        // One whose file left its group says so, keeps its texts, and is not fetched (spec, Rule 7).
        let flights: [Task<Void, Never>] = await panes.updateEditor(paneId: pane) { s in
            var started: [Task<Void, Never>] = []
            for i in s.tabs.indices {
                guard case .diff(let r, let p, let g) = s.tabs[i].subject, root == nil || r == root,
                      status.contains(where: { $0.root == r && editorRootIsKnown($0) }) else { continue }
                let row = EditorChangesRow(root: r, path: p, group: g.rawValue)
                guard let file = editorChangesFile(row, in: status) else {
                    s.tabs[i].diffState?.noLongerChanged = true
                    s.tabs[i].diffState?.loading = false
                    continue
                }
                s.tabs[i].diffState?.noLongerChanged = false
                s.tabs[i].diffState?.loading = true
                if let t = fetchDiff(pane, s.tabs[i].subject, status: file.status) { started.append(t) }
            }
            return started
        }
        for f in flights { await f.value }
        let fileTabs: [(path: String, root: String)] = await panes.editorSnapshot(paneId: pane).tabs.compactMap { t in
            guard case .file(let p, let r) = t.subject, root == nil || r == root, !t.readOnly else { return nil }
            return (p, r)
        }
        // The git refresh's own work: awaited here, unlike an open's (the action IS the git state).
        let baselines = fileTabs.compactMap { startBaseline(pane, path: $0.path, root: $0.root) }
        for b in baselines { await b.value }
    }

    func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var props = properties
        props["pane"] = .object(["type": .string("string")])
        return .object(["type": .string("object"), "properties": .object(props),
                        "required": .array(required.map { .string($0) })])
    }
    let positionSchema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "line": .object(["type": .string("integer")]), "column": .object(["type": .string("integer")])])])
    let rangeSchema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "start": positionSchema, "end": positionSchema])])

    await registry.register(Action(
        name: "editor_open",
        description: "Open a file (path, absolute, inside one of the active project's roots) in an editor "
            + "pane — a new tab, or its tab if already open — and reveal line (1-based) and column; with end_column too, select line from column to "
            + "end_column (exclusive, UTF-16) in the same step. With preview true, a file not yet open takes the pane's clean preview tab (replacing the file it "
            + "showed) rather than adding a tab; opening a preview tab without preview true keeps it. With no "
            + "pane, the focused or first editor pane, or a new one. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "line": .object(["type": .string("integer")]),
                        "column": .object(["type": .string("integer")]), "end_column": .object(["type": .string("integer")]),
                        "preview": .object(["type": .string("boolean")])],
                       required: ["path"]),
        handler: { params in
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_open", param: "path")
            }
            let path = try await confine(raw, action: "editor_open").path
            let pane = try await editorPane(params, action: "editor_open")
            let line = (jsonObject(params)?["line"]?.intValue).map {
                EditorPosition(line: $0, column: jsonObject(params)?["column"]?.intValue ?? 1)
            }
            // One write with the open, not a following editor_select: the view's report of the
            // opened tab's cursor would land between the two and drop the selection.
            let selection = line.flatMap { at in
                (jsonObject(params)?["end_column"]?.intValue).map {
                    EditorRange(start: at, end: EditorPosition(line: at.line, column: $0))
                }
            }
            let preview = jsonObject(params)?["preview"] == .bool(true)
            try await openFile(pane, path: path, at: line, selection: selection, preview: preview, action: "editor_open")
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_open_file",
        description: "From the editor pane's active diff tab (a Changes diff), open its file as a file tab at "
            + "the line under the diff's cursor; the diff tab stays open. Refused on a deleted file's diff and "
            + "on a Staged diff whose file is gone from the working tree. ⌘⏎ in a diff tab. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_open_file")
            let snap = await panes.editorSnapshot(paneId: pane)
            guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_open_file") }
            guard case .diff(let root, let path, let group) = snap.tabs[i].subject else {
                throw EditorActionError.notADiff(action: "editor_open_file")
            }
            let full = root + "/" + path
            guard editorDiffOpensFile(root: root, path: path, group: group, roots: await gitStatus?.roots ?? []) else {
                throw EditorActionError.fileGone(path: full)
            }
            try await openFile(pane, path: full, at: EditorPosition(line: snap.tabs[i].cursor.line, column: 1),
                               selection: nil, preview: false, action: "editor_open_file")
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_new_scratch",
        description: "Open an empty scratch tab (Untitled-N) in an editor pane, in language (a Monaco "
            + "language id; plaintext by default). Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["language": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_new_scratch")
            let language = optionalString(params, "language") ?? "plaintext"
            await panes.updateEditor(paneId: pane, create: true) { s in
                s.tabs.append(.scratch(number: editorNextScratchNumber(s.tabs), language: language))
                s.active = s.tabs.count - 1
            }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_focus_tab",
        description: "Make tab index (0-based, in tab-strip order) the editor pane's active tab.",
        kind: .control, audience: .agentReachable,
        schema: schema(["index": .object(["type": .string("integer")])], required: ["index"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_focus_tab")
            guard let index = jsonObject(params)?["index"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_focus_tab", param: "index")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                guard index >= 0, index < s.tabs.count else { return false }
                s.active = index
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_focus_tab") }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_close",
        description: "Close a tab (path, or scratch: the N of an Untitled-N tab, or diff: {root, path, group}, a Changes diff tab, or the active tab). A tab "
            + "with unsaved edits closes only with discard true; otherwise this answers that it has unsaved "
            + "edits. Focus moves to a neighbour.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "scratch": .object(["type": .string("integer")]),
                        "diff": .object(["type": .string("object")]),
                        "discard": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_close")
            let path = tabPath(params), scratch = tabScratch(params), diff = tabDiff(params)
            let discard = jsonObject(params)?["discard"] == .bool(true)
            // Found, checked for unsaved edits and removed in one turn: typing cannot land between.
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorCloseOutcome in
                guard let i = editorTabIndex(s, path: path, scratch: scratch, diff: diff) else { return .noTab }
                if s.tabs[i].dirty, !discard { return .unsaved(s.tabs[i].path ?? editorTabTitles([s.tabs[i]])[0]) }
                let count = s.tabs.count
                s.tabs.remove(at: i)
                s.active = editorTabAfterClosing(i, count: count)
                return .closed
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_close")
            case .unsaved(let p): throw EditorActionError.unsavedEdits(path: p)
            case .closed: break
            }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_goto",
        description: "Move the active tab's cursor to line (1-based) and column, revealing it.",
        kind: .control, audience: .agentReachable,
        schema: schema(["line": .object(["type": .string("integer")]), "column": .object(["type": .string("integer")])], required: ["line"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_goto")
            guard let line = jsonObject(params)?["line"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_goto", param: "line")
            }
            let column = jsonObject(params)?["column"]?.intValue ?? 1
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                guard let i = editorTabIndex(s, path: nil) else { return false }
                s.tabs[i].cursor = EditorPosition(line: line, column: column)
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_goto") }
            await persist(pane)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_select",
        description: "Select range ({start:{line,column}, end:{line,column}}, 1-based) in the active tab.",
        kind: .control, audience: .agentReachable,
        schema: schema(["range": rangeSchema], required: ["range"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_select")
            guard let r = editorRange(jsonObject(params)?["range"]) else {
                throw StandardActionError.missingParam(action: "editor_select", param: "range")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                guard let i = editorTabIndex(s, path: nil) else { return false }
                s.tabs[i].selection = r
                s.tabs[i].cursor = r.end
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_select") }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_set_language",
        description: "Set the active tab's language (a Monaco language id: sql, json, go, …).",
        kind: .control, audience: .agentReachable,
        schema: schema(["language": .object(["type": .string("string")])], required: ["language"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_set_language")
            guard let language = optionalString(params, "language") else {
                throw StandardActionError.missingParam(action: "editor_set_language", param: "language")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                guard let i = editorTabIndex(s, path: nil) else { return false }
                s.tabs[i].language = language
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_set_language") }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_replace_range",
        description: "Replace range ({start,end}, 1-based) of a tab's buffer (path, or the active tab) with "
            + "text. The change is unsaved; editor_save writes it. Undoable with ⌘Z in the pane. expect, "
            + "optional, is the text range holds now: when the buffer no longer has it there (it changed "
            + "since the range was read), nothing is replaced and the call is refused. The peek's Revert "
            + "always passes it.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "range": rangeSchema,
                        "text": .object(["type": .string("string")]),
                        "expect": .object(["type": .string("string")])], required: ["range", "text"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace_range")
            guard let r = editorRange(jsonObject(params)?["range"]) else {
                throw StandardActionError.missingParam(action: "editor_replace_range", param: "range")
            }
            guard let text = optionalString(params, "text") else {
                throw StandardActionError.missingParam(action: "editor_replace_range", param: "text")
            }
            let path = tabPath(params)
            let expect = optionalString(params, "expect")
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorReplaceOutcome in
                guard let i = editorTabIndex(s, path: path) else { return .noTab }
                if s.tabs[i].readOnly { return .readOnly(s.tabs[i].path ?? editorTabTitles([s.tabs[i]])[0], s.tabs[i].notice) }
                // Checked in the same turn as the write, so nothing can change the range in between.
                if let expect, editorText(s.tabs[i].text, in: r) != expect {
                    return .stale(s.tabs[i].path ?? editorTabTitles([s.tabs[i]])[0])
                }
                s.tabs[i].text = editorReplacing(s.tabs[i].text, r, with: text)
                if s.tabs[i].peek != nil {
                    // The peek moves with the cursor, as editor_peek_step does (R12).
                    let p = editorPeekClamped(s.tabs[i].peek, baseline: s.tabs[i].baseline, text: s.tabs[i].text)
                    s.tabs[i].peek = p
                    if let p, let base = s.tabs[i].baseline {
                        let marks = editorGutterMarks(editorHunks(base: base, text: s.tabs[i].text))
                        s.tabs[i].cursor = EditorPosition(line: marks[p].start, column: 1)
                        s.tabs[i].selection = nil
                    }
                }
                s.tabs[i].edits += 1
                s.tabs[i].preview = false   // an edit keeps a preview tab (spec)
                let serial = (s.tabs[i].lastAgentEdit?.serial ?? 0) + 1
                s.tabs[i].lastAgentEdit = EditorAgentEdit(serial: serial, range: r, text: text)
                return .replaced
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_replace_range")
            case .readOnly(let p, let n): throw EditorActionError.readOnly(action: "editor_replace_range", path: p, notice: n)
            case .stale(let p): throw EditorActionError.staleRange(action: "editor_replace_range", path: p)
            case .replaced: break
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_peek",
        description: "Open the peek on the change marked at line (1-based) of the editor pane's active file tab: "
            + "the hunk's old lines over its new ones, under it in the file, with previous / next and Revert. The "
            + "cursor moves to the hunk. Marks compare the buffer with the file's index text. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["line": .object(["type": .string("integer")])], required: ["line"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek")
            guard let line = jsonObject(params)?["line"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_peek", param: "line")
            }
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorPeekOutcome in
                guard let i = editorTabIndex(s, path: nil) else { return .noTab }
                guard let base = s.tabs[i].baseline, !s.tabs[i].readOnly else { return .noMarks }
                let hunks = editorHunks(base: base, text: s.tabs[i].text)
                guard let h = editorHunkIndex(at: line, in: hunks) else { return .noChange }
                s.tabs[i].peek = h
                s.tabs[i].cursor = EditorPosition(line: editorGutterMarks(hunks)[h].start, column: 1)
                s.tabs[i].selection = nil
                return .ok
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_peek")
            case .noMarks: throw EditorActionError.noMarks(action: "editor_peek")
            case .noChange: throw EditorActionError.noChange(line: line)
            case .noPeek, .ok: break
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_peek_step",
        description: "Move the open peek delta changes (1 next, -1 previous) through the active tab's changes, "
            + "stopping at either end; the cursor moves with it. Returns the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["delta": .object(["type": .string("integer")])], required: ["delta"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek_step")
            guard let delta = jsonObject(params)?["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_peek_step", param: "delta")
            }
            let outcome = await panes.updateEditor(paneId: pane) { s -> EditorPeekOutcome in
                guard let i = editorTabIndex(s, path: nil) else { return .noTab }
                guard let p = s.tabs[i].peek, let base = s.tabs[i].baseline else { return .noPeek }
                let hunks = editorHunks(base: base, text: s.tabs[i].text)
                guard !hunks.isEmpty else { s.tabs[i].peek = nil; return .noPeek }
                let next = min(max(p + delta, 0), hunks.count - 1)
                s.tabs[i].peek = next
                s.tabs[i].cursor = EditorPosition(line: editorGutterMarks(hunks)[next].start, column: 1)
                s.tabs[i].selection = nil
                return .ok
            }
            switch outcome {
            case .noTab: throw EditorActionError.noTab(action: "editor_peek_step")
            case .noPeek, .noMarks, .noChange: throw EditorActionError.noPeek(action: "editor_peek_step")
            case .ok: break
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_peek_close",
        description: "Close the active tab's peek; the cursor stays where it is. Nothing to close is not an error.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_peek_close")
            await panes.updateEditor(paneId: pane) { s in
                if let i = editorTabIndex(s, path: nil) { s.tabs[i].peek = nil }
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_save",
        description: "Write a tab's buffer to disk (path, or the active tab). A scratch tab needs as (an "
            + "absolute path inside a root) and becomes that file; onto a file that exists it needs replace "
            + "true, and onto a path already open in the pane it is refused. A read-only tab cannot be saved. "
            + "Writes over a file changed on disk. Confined to the active project's roots (Invariant 6, "
            + "Decision 36). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "as": .object(["type": .string("string")]),
                        "replace": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_save")
            let files = try requireFiles("editor_save")
            let path = tabPath(params)
            let saveAs = try await optionalString(params, "as").flatMap { $0.isEmpty ? nil : $0 }
                .asyncMap { try await confine($0, action: "editor_save") }
            let replace = jsonObject(params)?["replace"] == .bool(true)
            // Found, checked and claimed in one turn, by subject: nothing between the check and the
            // claim, and the claim names the tab, not a position that may move.
            let claim = await panes.updateEditor(paneId: pane) { s -> EditorSaveClaim in
                guard let i = editorTabIndex(s, path: path) else { return .noTab }
                let tab = s.tabs[i]
                if tab.readOnly { return .readOnly(tab.path ?? editorTabTitles([tab])[0], tab.notice) }
                if tab.saving { return .busy }
                if tab.isScratch, saveAs == nil { return .noScratchPath }
                // Two tabs never share a subject: a scratch saved onto a path the pane holds is refused.
                if tab.isScratch, let target = saveAs, let j = s.tabs.firstIndex(where: { $0.path == target.path }) {
                    return .alreadyOpen(target.path, editorTabTitles(s.tabs)[j])
                }
                s.tabs[i].saving = true
                return .claimed(subject: tab.subject, text: tab.text, create: tab.isScratch || tab.diskState == .deleted)
            }
            guard case .claimed(let subject, let text, let create) = claim else {
                switch claim {
                case .noTab: throw EditorActionError.noTab(action: "editor_save")
                case .readOnly(let p, let n): throw EditorActionError.readOnly(action: "editor_save", path: p, notice: n)
                case .noScratchPath: throw EditorActionError.noScratchPath
                case .alreadyOpen(let p, let t): throw EditorActionError.alreadyOpen(path: p, tab: t)
                default: return await reply(pane)   // Rule 5: one already in flight
                }
            }
            // The tab after the await: by the claimed subject, or a file tab editor_rename re-pointed
            // from it meanwhile (its former keys hold the claimed one), so `saving` never sticks.
            let claimedKey = editorTabKey(subject)
            @Sendable func savedTab(_ s: EditorSnapshot) -> Int? {
                s.tabs.firstIndex(where: { $0.subject == subject })
                    ?? s.tabs.firstIndex(where: { if case .file = $0.subject { $0.formerKeys.contains(claimedKey) } else { false } })
            }
            @Sendable func release() async {
                await panes.updateEditor(paneId: pane) { s in
                    if let i = savedTab(s) { s.tabs[i].saving = false }
                }
            }
            let target: (path: String, root: String)
            let outcome: FilesOutcome
            do {
                switch subject {
                case .file(let p, let r): target = (p, r)
                case .scratch: target = saveAs!
                case .diff: throw EditorActionError.noTab(action: "editor_save")   // read-only: claimed never
                }
                _ = try await confine(target.path, action: "editor_save")
                // Rule 1: a save-as never writes over an existing file unasked.
                if case .scratch = subject, !replace {
                    switch try await filesTool(files, "files_read", ["path": .string(target.path)]) {
                    case .failed(let text): throw EditorFilesError(description: text)
                    case .ok(let o): if o["exists"] != .bool(false) { throw EditorActionError.targetExists(path: target.path) }
                    }
                }
                outcome = try await filesTool(files, "files_write", [
                    "path": .string(target.path), "text": .string(text), "create": .bool(create),
                ])
            } catch {
                await release()
                throw error
            }
            await panes.updateEditor(paneId: pane) { s in
                guard let i = savedTab(s) else { return }
                s.tabs[i].saving = false
                switch outcome {
                case .failed(let message):
                    s.tabs[i].notice = message
                case .ok(let o):
                    s.tabs[i].savedText = text
                    s.tabs[i].mtime = Int64(o["mtime"]?.intValue ?? 0)
                    s.tabs[i].diskState = .inSync
                    s.tabs[i].notice = nil
                    if case .scratch = subject {
                        if let j = s.tabs.firstIndex(where: { $0.path == target.path }) {
                            // Opened while the write ran: the scratch stays a scratch, so no two tabs
                            // share a subject, and says where its text went (Rule 8).
                            s.tabs[i].savedText = ""
                            s.tabs[i].notice = "saved to \(target.path), which is also open as tab "
                                + editorTabTitles(s.tabs)[j] + "; that tab may need Reload"
                        } else {
                            s.tabs[i].subject = .file(path: target.path, root: target.root)
                        }
                    }
                }
            }
            if case .failed(let message) = outcome { throw EditorFilesError(description: message) }
            await persist(pane)
            return await reply(pane)
        },
        price: (production: .allow, otherwise: .allow)))

    /// Every editor pane in every scope gets `change` applied to its tabs, its active tab kept or
    /// moved to a neighbour (Rule 6), and its saved tabs written back (3b-iv: the tree is the
    /// project's, in every pane — Decision 37).
    @Sendable func retab(_ change: @escaping @Sendable ([EditorTab]) -> [EditorTab]) async {
        for target in await panes.editorPanesInEveryScope() {
            await panes.updateEditor(in: target.scope, paneId: target.paneId) { s in
                let new = change(s.tabs)
                guard new != s.tabs else { return }
                s.active = editorActiveAfter(s.tabs, active: s.active, new: new)
                s.tabs = new
            }
            if target.scope == (await panes.activeScope) { await persist(target.paneId) }
        }
    }

    await registry.register(Action(
        name: "editor_create",
        description: "Make an empty file or a folder (kind file or dir) at path (absolute, inside a root), and "
            + "missing folders above it. A file opens as a pinned tab; a folder is opened in the tree. An "
            + "existing name is refused, never overwritten. Confined to the active project's roots (Invariant 6, "
            + "Decision 41). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]),
                        "kind": .object(["type": .string("string"), "enum": .array([.string("file"), .string("dir")])])],
                       required: ["path", "kind"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_create")
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_create", param: "path")
            }
            let kind = optionalString(params, "kind") ?? "file"
            let c = try await confine(raw, action: "editor_create")
            switch try await filesTool(try requireFiles("editor_create"), "files_create",
                                       ["path": .string(c.path), "kind": .string(kind)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            _ = await fileLists?.invalidate(root: c.root)
            if kind == "file" {
                try await openFile(pane, path: c.path, at: nil, selection: nil, preview: false, action: "editor_create")
            } else {
                // The new folder shows: every folder above it, up to its root, is open.
                await updateColumn(pane) { col in
                    var p = (c.path as NSString).deletingLastPathComponent
                    while p.count >= c.root.count {
                        if !col.open.contains(p) { col.open.append(p) }
                        p = (p as NSString).deletingLastPathComponent
                    }
                }
            }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["made"] = .string(c.path)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_rename",
        description: "Rename or move a file or folder: path to to (both absolute, inside the roots; another root "
            + "is allowed). Open tabs on it, or under a moved folder, follow in every editor pane with their "
            + "unsaved edits; its diff tabs close. An existing to is refused; a root is never moved; a move "
            + "across volumes is refused. Confined to the active project's roots (Invariant 6, Decision 41). "
            + "Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")]), "to": .object(["type": .string("string")])],
                       required: ["path", "to"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_rename")
            guard let rawFrom = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_rename", param: "path")
            }
            guard let rawTo = optionalString(params, "to") else {
                throw StandardActionError.missingParam(action: "editor_rename", param: "to")
            }
            let from = try await confine(rawFrom, action: "editor_rename")
            let to = try await confine(rawTo, action: "editor_rename")
            // Ruling R4: the same name changes nothing — no move, no tab re-pointed, no diff tab closed.
            @Sendable func answer() async -> JSONValue {
                guard case .object(var o) = await reply(pane) else { return .null }
                o["from"] = .string(from.path)
                o["to"] = .string(to.path)
                return .object(o)
            }
            if from.path == to.path { return await answer() }
            switch try await filesTool(try requireFiles("editor_rename"), "files_move",
                                       ["from": .string(from.path), "to": .string(to.path)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            await retab { editorRepointTabs($0, from: from.path, to: to.path, root: to.root) }
            // An open folder that moved stays open under its new name.
            await updateColumn(pane, onlyIfChanged: true) { col in
                col.open = col.open.map { p in
                    p == from.path || p.hasPrefix(from.path + "/") ? to.path + p.dropFirst(from.path.count) : p
                }
            }
            _ = await fileLists?.invalidate(root: from.root)
            if to.root != from.root { _ = await fileLists?.invalidate(root: to.root) }
            return await answer()
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_trash",
        description: "Move a file or folder at path (absolute, inside a root) to the Trash, where Finder's Put "
            + "Back restores it; no dialog (Rule 1). Its clean tabs close in every editor pane; a tab with "
            + "unsaved edits stays open, marked deleted, and saving it recreates the file. A root is never "
            + "trashed. Needs macOS 15. Confined to the active project's roots (Invariant 6, Decision 41). "
            + "Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])], required: ["path"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_trash")
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_trash", param: "path")
            }
            let c = try await confine(raw, action: "editor_trash")
            switch try await filesTool(try requireFiles("editor_trash"), "files_trash", ["path": .string(c.path)]) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok: break
            }
            await retab { editorTabsAfterTrash($0, path: c.path) }
            _ = await fileLists?.invalidate(root: c.root)
            guard case .object(var o) = await reply(pane) else { return .null }
            o["trashed"] = .string(c.path)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_reload",
        description: "Replace a tab's buffer (path, or the active tab) with the file on disk, dropping "
            + "unsaved edits. Keeps cursor and scroll.",
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_reload")
            let snap = await panes.editorSnapshot(paneId: pane)
            guard let at = editorTabIndex(snap, path: tabPath(params)) else { throw EditorActionError.noTab(action: "editor_reload") }
            guard let path = snap.tabs[at].path else { throw EditorActionError.notAFile(action: "editor_reload") }
            let reread = try await read(path, action: "editor_reload")
            let wasReadOnly = snap.tabs[at].readOnly
            await panes.updateEditor(paneId: pane) { s in
                guard let i = s.tabs.firstIndex(where: { $0.path == path }) else { return }
                var fresh = reread
                fresh.cursor = s.tabs[i].cursor
                fresh.scrollTop = s.tabs[i].scrollTop
                fresh.visibleRange = s.tabs[i].visibleRange
                fresh.language = s.tabs[i].language
                fresh.edits = s.tabs[i].edits + 1
                // The agent-edit serial never goes back: a page post made before the last agent edit
                // must still be dropped after a reload (`editorBufferDidChange`'s basis).
                fresh.lastAgentEdit = s.tabs[i].lastAgentEdit
                fresh.baseline = fresh.readOnly ? nil : s.tabs[i].baseline
                s.tabs[i] = fresh
            }
            if wasReadOnly, !reread.readOnly, case .file(_, let root) = snap.tabs[at].subject {
                startBaseline(pane, path: path, root: root)     // now writable: it can have marks
            }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_refresh",
        description: "Re-read an editor pane's open files (under root, if given) from disk: a tab with no "
            + "unsaved edits reloads in place; one with edits keeps them and is marked changed on disk; a "
            + "missing file is marked deleted. Search results are marked changed since when paths (absolute: "
            + "files, or folders holding them) names one of their files; without paths, any under root. "
            + "The file watcher dispatches this with the paths that changed. "
            + "what: all (the default) also re-reads git status first, then the pane's git state (the Changes "
            + "highlight, its diff tabs and its tabs' gutter baselines); files only the files (the file "
            + "watcher's); git only the pane's git state, against the status as it is (the git watcher's, "
            + "which has just read it).",
        kind: .read, audience: .agentReachable,
        schema: schema(["root": .object(["type": .string("string")]),
                        "paths": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "what": .object(["type": .string("string"),
                                         "enum": .array([.string("all"), .string("files"), .string("git")])])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_refresh")
            let only = optionalString(params, "root")
            let what = optionalString(params, "what") ?? "all"
            guard ["all", "files", "git"].contains(what) else {
                throw EditorFilesError(description: "editor_refresh: what must be all, files or git, not \"\(what)\"")
            }
            if what == "all" { await gitStatus?.refresh(only: only) }
            let changedPaths: [String]? = {
                guard case .array(let items)? = jsonObject(params)?["paths"] else { return nil }
                return items.compactMap { if case .string(let p) = $0 { (p as NSString).standardizingPath } else { nil } }
            }()
            if what != "git" {
                let tabs = await panes.editorSnapshot(paneId: pane).tabs
                // Each read is kept with the mtime the tab had when it began: a save that lands while
                // the read is in flight leaves the read stale, and applying it would rewind the tab.
                var reads: [String: (fresh: EditorTab, basis: Int64)] = [:]
                for tab in tabs {
                    guard case .file(let path, let r) = tab.subject, only == nil || r == only else { continue }
                    if let fresh = try? await read(path, action: "editor_refresh") { reads[path] = (fresh, tab.mtime) }
                }
                let collected = reads
                let wasReadOnly = Set(tabs.filter(\.readOnly).compactMap(\.path))
                await panes.updateEditor(paneId: pane) { s in
                    for i in s.tabs.indices {
                        guard let p = s.tabs[i].path, let (fresh, basis) = collected[p],
                              !s.tabs[i].saving, s.tabs[i].mtime == basis else { continue }
                        s.tabs[i] = editorAfterDiskRead(s.tabs[i], read: fresh)
                    }
                    // Spec: an event on a path in the results (final review I4). A path is a file or a
                    // folder FSEvents asks to rescan, so a result at or under it counts. Without paths
                    // (an agent's refresh), every result under the root counts, erring toward Re-run.
                    let hit = s.search.results.contains { r in
                        guard only == nil || r.root == only else { return false }
                        guard let changedPaths else { return true }
                        let file = r.root + "/" + r.path
                        return changedPaths.contains { file == $0 || file.hasPrefix($0 + "/") }
                    }
                    if hit { s.search.changedSince = true }
                }
                // A tab that turned writable (it was over the cap) gets its baseline now.
                for t in await panes.editorSnapshot(paneId: pane).tabs where !t.readOnly {
                    if case .file(let p, let r) = t.subject, wasReadOnly.contains(p) { startBaseline(pane, path: p, root: r) }
                }
            }
            if what != "files" { await refreshGit(pane, root: only) }
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_restore",
        description: "Reopen an editor pane's saved tabs (its files, cursors and scroll) after a relaunch. "
            + "Tabs already open are kept as they are; a saved file not yet open is added. A file that no "
            + "longer exists comes back marked deleted; one that cannot be read comes back read-only with "
            + "the reason as its notice.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_restore")
            let saved = await layout?.editorTabs(id: pane) ?? []
            var restored: [EditorTab] = []
            for s in saved {
                var tab: EditorTab
                do {
                    tab = try await read(s.path, action: "editor_restore")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let c = try? await confine(s.path, action: "editor_restore")
                    tab = .file(path: c?.path ?? s.path, root: c?.root ?? "", text: "", mtime: 0,
                                language: editorLanguage(forPath: s.path))
                    tab.readOnly = true
                    tab.notice = String(describing: error)
                }
                tab.cursor = s.cursor
                tab.scrollTop = s.scrollTop
                restored.append(tab)
            }
            let additions = restored
            await panes.updateEditor(paneId: pane, create: true) { s in
                let hadActive = s.active != nil && s.active! < s.tabs.count
                let firstNew = s.tabs.count
                for tab in additions where !s.tabs.contains(where: { $0.path == tab.path }) { s.tabs.append(tab) }
                if !hadActive, s.tabs.count > firstNew { s.active = firstNew }
            }
            for tab in additions where !tab.readOnly {
                if case .file(let p, let r) = tab.subject { startBaseline(pane, path: p, root: r) }
            }
            if await layout?.editorColumn(id: pane) != nil {
                // Pruned only against listings that succeeded: a root whose listing failed keeps
                // its open folders, since nothing says they are gone.
                var listings: [EditorRootListing] = []
                if let fileLists { for r in await roots() { listings.append(await fileLists.listing(root: r)) } }
                let ok = listings.filter { $0.error == nil }
                let failed = listings.filter { $0.error != nil }.map(\.root)
                let listed = !listings.isEmpty
                // The layout's copy as it is now, not as it was before the listings were awaited: a
                // tree action that landed meanwhile is kept (final review I2). Not the default: a
                // restore is not a column the operator left.
                await updateColumn(pane, asDefault: false) { c in
                    guard listed else { return }
                    let kept = Set(editorPruneOpen(c.open, listings: ok))
                    c.open = c.open.filter { p in
                        kept.contains(p) || failed.contains { p == $0 || p.hasPrefix($0 + "/") }
                    }
                }
            }
            return await reply(pane)
        }))

    let treeRefusal = "A path outside the active project's roots is refused (Invariant 6, Decision 36)."

    await registry.register(Action(
        name: "editor_tree",
        description: "Show or hide an editor pane's left column (shown), switch its view (files, search or changes — the project's git changes, 3b-iii), "
            + "or set its width (points; clamped by the view). With no pane, the focused or first editor pane, or "
            + "a new one. A pane that never set its column starts from the one last left in any editor pane. "
            + "Shown on files, it lists every root.",
        kind: .control, audience: .agentReachable,
        schema: schema(["shown": .object(["type": .string("boolean")]),
                        "view": .object(["type": .string("string"), "enum": .array([.string("files"), .string("search"), .string("changes")])]),
                        "width": .object(["type": .string("number")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree")
            let o = jsonObject(params) ?? [:]
            let view = optionalString(params, "view").flatMap(EditorColumnView.init(rawValue:))
            let c = await updateColumn(pane) { c in
                if case .bool(let shown)? = o["shown"] { c.shown = shown }
                if let view {
                    c.view = view
                    if o["shown"] == nil { c.shown = true }   // switching the view shows the column
                }
                if let w = o["width"]?.doubleValue { c.width = max(160, w) }
            }
            if c.shown, c.view == .files, let fileLists { for r in await roots() { _ = await fileLists.listing(root: r) } }
            return await reply(pane)
        }))

    /// Opens `rel` under `root` in the pane's tree, with every folder above it, loading heavy ones
    /// on the way (3b-ii's `editor_tree_expand`, shared with `editor_tree_reveal`).
    @Sendable func openChain(_ pane: String, root: String, rel: String) async {
        var chain = [root]
        var acc = root
        for part in rel.split(separator: "/") { acc += "/\(part)"; chain.append(acc) }
        let opening = chain
        await updateColumn(pane) { c in for p in opening where !c.open.contains(p) { c.open.append(p) } }
        if let fileLists {
            let l = await fileLists.listing(root: root)
            if let heavy = l.heavy.first(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                // Each heavy ancestor not yet loaded, then the folder itself: the subtree above it draws.
                let loaded = await fileLists.state()
                var walk = heavy
                for part in rel.dropFirst(heavy.count).split(separator: "/") {
                    let key = "\(root)/\(walk)"
                    if loaded.dirs[key] == nil, !loaded.loading.contains(key) {
                        await fileLists.loadDir(root: root, dir: walk)
                    }
                    walk += "/\(part)"
                }
                await fileLists.loadDir(root: root, dir: rel)
            }
        }
    }

    await registry.register(Action(
        name: "editor_tree_expand",
        description: "Open a folder (path, absolute) in an editor pane's file tree, with every folder above it "
            + "up to its root. A folder at or under a heavy folder (node_modules, vendor, …) is loaded on "
            + "opening. " + treeRefusal,
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])], required: ["path"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree_expand")
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_tree_expand", param: "path")
            }
            let t = try await treePath(raw, action: "editor_tree_expand")
            await openChain(pane, root: t.root, rel: t.rel)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_tree_collapse",
        description: "Close a folder (path, absolute) in an editor pane's file tree; the folders inside it keep "
            + "whether they were open. A load still in flight for it is cancelled. " + treeRefusal,
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])], required: ["path"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree_collapse")
            guard let raw = optionalString(params, "path") else {
                throw StandardActionError.missingParam(action: "editor_tree_collapse", param: "path")
            }
            let t = try await treePath(raw, action: "editor_tree_collapse")
            let closing = t.path
            await updateColumn(pane) { c in c.open.removeAll { $0 == closing } }
            await fileLists?.cancelDir(t.path)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_tree_reveal",
        description: "Open every folder above path (absolute; default: the pane's active file) in an editor "
            + "pane's file tree. It opens folders only: the tree's selection and scroll are the operator's, "
            + "which the reveal button and ⌘K's Reveal Active File in Tree move. " + treeRefusal,
        kind: .control, audience: .agentReachable,
        schema: schema(["path": .object(["type": .string("string")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_tree_reveal")
            let raw: String
            if let p = optionalString(params, "path"), !p.isEmpty {
                raw = p
            } else {
                let snap = await panes.editorSnapshot(paneId: pane)
                guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_tree_reveal") }
                guard let p = snap.tabs[i].path else { throw EditorActionError.notAFile(action: "editor_tree_reveal") }
                raw = p
            }
            let t = try await treePath(raw, action: "editor_tree_reveal")
            await openChain(pane, root: t.root, rel: (t.rel as NSString).deletingLastPathComponent)
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_move_tab",
        description: "Move an editor pane's tab from index from to index to (0-based, strip order); the active "
            + "tab stays the same tab. The order is the pane's saved tab order, kept across a relaunch.",
        kind: .control, audience: .agentReachable,
        schema: schema(["from": .object(["type": .string("integer")]), "to": .object(["type": .string("integer")])],
                       required: ["from", "to"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_move_tab")
            guard let from = jsonObject(params)?["from"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_move_tab", param: "from")
            }
            guard let to = jsonObject(params)?["to"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_move_tab", param: "to")
            }
            let ok = await panes.updateEditor(paneId: pane) { s -> Bool in
                if from == to { return s.tabs.indices.contains(from) }
                guard let moved = editorMovingTab(s, from: from, to: to) else { return false }
                s = moved
                return true
            }
            guard ok else { throw EditorActionError.noTab(action: "editor_move_tab") }
            await persist(pane)
            return await reply(pane)
        }))

    let groupSchema: JSONValue = .object(["type": .string("string"),
                                          "enum": .array(GitGroup.allCases.map { .string($0.rawValue) })])

    await registry.register(Action(
        name: "editor_changes_select",
        description: "Open one changed file's diff in an editor pane, as a read-only diff tab titled `name (Changes)`, "
            + "`(Staged)` or `(Untracked)`: root (absolute, one of the active project's roots), path (relative to "
            + "root), group (staged, changed or untracked — a partly staged file is in two). Staged compares HEAD "
            + "with the index, changed the index with the working tree (a conflicted file HEAD with the working "
            + "tree), untracked nothing with the working tree; a deleted file is compared with nothing. A preview "
            + "tab, replaced by the next one, unless pin is true. A file no longer in that group opens reading "
            + "No longer changed. The Changes highlight moves to it. Returns the pane's state; the diff's texts "
            + "are not in it — read them with git_show.",
        kind: .control, audience: .agentReachable,
        schema: schema(["root": .object(["type": .string("string")]), "path": .object(["type": .string("string")]),
                        "group": groupSchema, "pin": .object(["type": .string("boolean")])],
                       required: ["root", "path", "group"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_changes_select")
            let row = try await changesRow(params, action: "editor_changes_select")
            await openDiff(pane, row, pin: jsonObject(params)?["pin"] == .bool(true))
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "editor_changes_step",
        description: "Move an editor pane's Changes highlight delta rows (1 next, -1 previous) through every "
            + "root's changed files in order — roots in project order, a collapsed root skipped, then staged, "
            + "changed, untracked — stopping at either end. With nothing highlighted, the first row. It "
            + "moves the highlight and opens its diff as a preview tab, as editor_changes_select does. Returns "
            + "the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(["delta": .object(["type": .string("integer")])], required: ["delta"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_changes_step")
            guard let delta = jsonObject(params)?["delta"]?.intValue else {
                throw StandardActionError.missingParam(action: "editor_changes_step", param: "delta")
            }
            let status = await gitStatus?.roots ?? []
            let c = await updateColumn(pane, asDefault: false) { c in
                c.changesHighlight = editorChangesStep(status, closed: c.changesClosed,
                                                       from: editorChangesResolve(c.changesHighlight, roots: status), by: delta)
            }
            if let h = c.changesHighlight { await openDiff(pane, h, pin: false) }
            return await reply(pane)
        }))

    for (name, closing) in [("editor_changes_collapse", true), ("editor_changes_expand", false)] {
        await registry.register(Action(
            name: name,
            description: (closing ? "Collapse" : "Expand") + " one root (root, absolute) in an editor pane's "
                + "Changes view. Kept per pane, apart from the Files tree's open folders, and saved with the "
                + "layout. Returns the pane's state.",
            kind: .control, audience: .agentReachable,
            schema: schema(["root": .object(["type": .string("string")])], required: ["root"]),
            handler: { params in
                let pane = try await editorPane(params, action: name)
                let root = try await projectRoot(params, action: name)
                await updateColumn(pane, asDefault: false) { c in
                    if closing { c.changesClosed.insert(root) } else { c.changesClosed.remove(root) }
                }
                return await reply(pane)
            }))
    }

    let flags: [String: JSONValue] = ["query": .object(["type": .string("string")]),
                                      "case": .object(["type": .string("boolean")]),
                                      "word": .object(["type": .string("boolean")]),
                                      "regex": .object(["type": .string("boolean")])]
    @Sendable func flag(_ params: JSONValue, _ k: String) -> Bool { jsonObject(params)?[k] == .bool(true) }

    await registry.register(Action(
        name: "editor_find",
        description: "Find query in the active tab — literal unless regex; case-insensitive unless case; whole "
            + "words with word — opening the pane's find bar on it. Returns every match's range (1-based lines, "
            + "UTF-16 columns) as matches, with the pane's state.",
        kind: .control, audience: .agentReachable,
        schema: schema(flags, required: ["query"]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_find")
            guard let query = optionalString(params, "query") else {
                throw StandardActionError.missingParam(action: "editor_find", param: "query")
            }
            let snap = await panes.editorSnapshot(paneId: pane)
            guard let i = editorTabIndex(snap, path: nil) else { throw EditorActionError.noTab(action: "editor_find") }
            if case .diff = snap.tabs[i].subject { throw EditorActionError.diffTab(action: "editor_find") }
            let c = flag(params, "case"), w = flag(params, "word"), r = flag(params, "regex")
            let matches = try editorFindMatches(snap.tabs[i].text, query: query, caseSensitive: c, wholeWord: w, regex: r)
            await panes.updateEditor(paneId: pane) { s in
                s.find = EditorFindRequest(query: query, caseSensitive: c, wholeWord: w, regex: r, serial: (s.find?.serial ?? 0) + 1)
                s.findReport = nil   // the bar's last count was for the old query; Monaco reports the new one
            }
            guard case .object(var o) = await reply(pane) else { return .null }
            o["matches"] = .array(matches.map { m in .object([
                "start": .object(["line": .integer(Int64(m.start.line)), "column": .integer(Int64(m.start.column))]),
                "end": .object(["line": .integer(Int64(m.end.line)), "column": .integer(Int64(m.end.column))])]) })
            return .object(o)
        }))

    let runs = EditorSearchRuns<FilesOutcome>()

    @Sendable func searchArgs(_ params: JSONValue) -> [String: JSONValue] {
        ["query": .string(optionalString(params, "query") ?? ""), "case": .bool(flag(params, "case")),
         "word": .bool(flag(params, "word")), "regex": .bool(flag(params, "regex"))]
    }

    /// The matches, `truncated` (the match cap) and `files_truncated` (the file cap) of a reply.
    @Sendable func matches(from content: [String: JSONValue]) -> (results: [EditorSearchMatch], truncated: Bool, filesTruncated: Bool) {
        let filesTruncated = content["files_truncated"] == .bool(true)
        guard case .array(let list)? = content["matches"] else { return ([], false, filesTruncated) }
        let ms: [EditorSearchMatch] = list.compactMap { v in
            guard case .object(let m) = v, case .string(let root)? = m["root"], case .string(let path)? = m["path"] else { return nil }
            let preview: String = { if case .string(let p)? = m["preview"] { p } else { "" } }()
            return EditorSearchMatch(root: root, path: path, line: m["line"]?.intValue ?? 1,
                                     column: m["column"]?.intValue ?? 1, preview: preview)
        }
        return (ms, content["truncated"] == .bool(true), filesTruncated)
    }

    @Sendable func replaceArgs(_ s: EditorSearchState, _ replacement: String) -> [String: JSONValue] {
        ["query": .string(s.query), "case": .bool(s.caseSensitive), "word": .bool(s.wholeWord),
         "regex": .bool(s.regex), "replacement": .string(replacement)]
    }

    /// `files_replace_text` over `texts`, answered in order (3b-ii-b).
    @Sendable func replaceTexts(_ files: any ToolCaller, _ texts: [String], _ s: EditorSearchState,
                                _ replacement: String) async throws -> [EditorReplacedText] {
        var args = replaceArgs(s, replacement)
        args["texts"] = .array(texts.map { .string($0) })
        switch try await filesTool(files, "files_replace_text", args) {
        case .failed(let text): throw EditorFilesError(description: text)
        case .ok(let o): return editorReplacedTexts(from: o)
        }
    }

    /// The preview: every shown line in one `files_replace_text` call, drawn from its answer. Cleared
    /// when the toggle is closed, the search failed or found nothing. A newer preview wins.
    @Sendable func refreshReplacePreview(_ pane: String) async {
        let s = await panes.editorSnapshot(paneId: pane).search
        guard let files, s.replace.shown, s.error == nil, !s.results.isEmpty else {
            await panes.updateEditor(paneId: pane) { st in st.search.replace.preview = [:] }
            return
        }
        let serial = await panes.updateEditor(paneId: pane) { st -> Int in
            st.search.replace.previewSerial += 1
            return st.search.replace.previewSerial
        }
        let texts = editorReplacePreviewTexts(s.results)
        let answer = try? await replaceTexts(files, texts, s, s.replace.text)
        await panes.updateEditor(paneId: pane) { st in
            guard st.search.replace.previewSerial == serial else { return }
            var preview: [String: [EditorReplaceEdit]] = [:]
            if let answer { for (t, r) in zip(texts, answer) { preview[t] = r.edits } }
            st.search.replace.preview = preview
        }
    }

    /// The search `editor_search` runs for a non-empty query (3b-ii), shared with a replace's and an
    /// undo's re-run (3b-ii-b), then the preview over what it found.
    @Sendable func runSearch(_ pane: String, query: String, caseSensitive c: Bool, wholeWord w: Bool,
                             regex r: Bool) async throws {
        let files = try requireFiles("editor_search")
        let args: [String: JSONValue] = ["query": .string(query), "case": .bool(c), "word": .bool(w), "regex": .bool(r)]
        let serial = await panes.updateEditor(paneId: pane, create: true) { s -> Int in
            s.search.serial += 1
            s.search.query = query
            s.search.caseSensitive = c; s.search.wholeWord = w; s.search.regex = r
            s.search.inFlight = true
            s.search.cancelled = false
            s.search.error = nil
            s.search.changedSince = false
            return s.search.serial
        }
        await updateColumn(pane, onlyIfChanged: true) { c in c.shown = true; c.view = .search }
        let task = await runs.start(pane, serial: serial) { try await filesTool(files, "files_search", args) }
        let outcome: Result<JSONValue, Error>
        do {
            // The handler's own cancellation reaches the tool call too.
            switch try await withTaskCancellationHandler(operation: { try await task.value },
                                                         onCancel: { task.cancel() }) {
            case .ok(let o): outcome = .success(.object(o))
            case .failed(let text): outcome = .failure(EditorFilesError(description: text))
            }
        } catch { outcome = .failure(error) }
        await runs.finish(pane, serial: serial)
        await panes.updateEditor(paneId: pane) { s in
            guard s.search.serial == serial else { return }        // superseded or cancelled: dropped
            s.search.inFlight = false
            switch outcome {
            case .success(.object(let o)):
                (s.search.results, s.search.truncated, s.search.filesTruncated) = matches(from: o)
            case .failure(let e) where !(e is CancellationError):
                s.search.results = []; s.search.truncated = false; s.search.filesTruncated = false
                s.search.error = String(describing: e)
            default: break
            }
        }
        await refreshReplacePreview(pane)
        if case .failure(let e) = outcome, !(e is CancellationError) { throw e }
    }

    await registry.register(Action(
        name: "editor_search",
        description: "Search the project's files for query into an editor pane's Search view (shown): literal "
            + "unless regex, case-insensitive unless case, whole words with word. Ignored files and the heavy "
            + "folders are skipped; at most 2,000 matches (truncated). A newer search, or cancel true, stops the "
            + "one in flight. An empty query searches nothing and keeps the switches for the next one. "
            + "replace (a string) opens the Search view's Replace field with that text, or null closes it "
            + "keeping the text; sent without query, it searches nothing, and with query it also searches. "
            + "While the field is open each result line's replacement is previewed. Returns the "
            + "pane's state with the results.",
        kind: .control, audience: .agentReachable,
        schema: schema(flags.merging(["cancel": .object(["type": .string("boolean")]),
                                      "replace": .object(["type": .array([.string("string"), .string("null")])])]) { a, _ in a }),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_search")
            if flag(params, "cancel") {
                let cancelled = await panes.updateEditor(paneId: pane, create: true) { s -> Int in
                    // Only a search in flight is stopped: a cancel with none says nothing happened.
                    if s.search.inFlight { s.search.cancelled = true }
                    s.search.serial += 1; s.search.inFlight = false; return s.search.serial
                }
                await runs.cancel(pane, serial: cancelled)
                return await reply(pane)
            }
            // 3b-ii-b ruling 3: the Replace field — its text opens the toggle; null closes it and keeps
            // the text (Rule 2). Applied whenever `replace` is present (pre-flight F1), before any search so
            // the preview uses it. With no query, nothing is searched; with one, `runSearch` below
            // refreshes the preview.
            if let o = jsonObject(params), let field = o["replace"] {
                await panes.updateEditor(paneId: pane, create: true) { s in
                    if case .string(let t) = field { s.search.replace.text = t; s.search.replace.shown = true }
                    else { s.search.replace.shown = false }
                }
                if o["query"] == nil {
                    await refreshReplacePreview(pane)
                    return await reply(pane)
                }
            }
            guard optionalString(params, "query") != nil else {
                throw StandardActionError.missingParam(action: "editor_search", param: "query")
            }
            // Task 8 ruling 4: a switch flipped while the query is empty is kept for the next query
            // (Rules 2 and 7). An empty query searches nothing: it stops any run in flight, records the
            // switches and clears what an older query found.
            if optionalString(params, "query") == "" {
                let serial = await panes.updateEditor(paneId: pane, create: true) { s -> Int in
                    s.search.serial += 1
                    s.search.query = ""
                    s.search.caseSensitive = flag(params, "case"); s.search.wholeWord = flag(params, "word"); s.search.regex = flag(params, "regex")
                    s.search.inFlight = false
                    s.search.cancelled = false
                    s.search.error = nil
                    s.search.changedSince = false
                    s.search.results = []; s.search.truncated = false; s.search.filesTruncated = false
                    s.search.replace.preview = [:]
                    return s.search.serial
                }
                await runs.cancel(pane, serial: serial)
                return await reply(pane)
            }
            try await runSearch(pane, query: optionalString(params, "query") ?? "", caseSensitive: flag(params, "case"),
                                wholeWord: flag(params, "word"), regex: flag(params, "regex"))
            return await reply(pane)
        }))

    await registry.register(Action(
        name: "files_search",
        description: "Search the project's files for query — the same search editor_search draws — returning "
            + "{matches: [{root, path, line, column, preview}], truncated, files_truncated} without touching any pane.",
        kind: .read, audience: .agentReachable,
        schema: .object(["type": .string("object"), "properties": .object(flags), "required": .array([.string("query")])]),
        handler: { params in
            switch try await filesTool(try requireFiles("files_search"), "files_search", searchArgs(params)) {
            case .failed(let text): throw EditorFilesError(description: text)
            case .ok(let o): return .object(o)
            }
        }))

    /// Each open tab `skipped` names, in every editor pane the store holds — the active scope's and
    /// the other conversations' (pre-flight F2) — the replacement applied to its buffer as one agent
    /// edit (3b-i's path, so ⌘Z takes it back whole). A tab typed in while its text was being replaced
    /// is replaced again from what it holds now, up to three times — the operator's typing is never
    /// written over (Review Focus 1). A file open in two panes counts once, by its path (pre-flight
    /// F7). Answers the matches replaced and the paths edited, and lists what it could not edit
    /// (Rule 8, final review M8): a read-only tab whose file the search found, and a tab still typed in
    /// after the third try — each left as it is.
    @Sendable func replaceInBuffers(_ files: any ToolCaller, targets: [EditorPaneRef], skipped: Set<String>,
                                    _ s: EditorSearchState, _ replacement: String) async throws
        -> (count: Int, paths: Set<String>, failures: [EditorReplaceFailure]) {
        var perPath: [String: Int] = [:]
        let found = Set(s.results.map { $0.root + "/" + $0.path })
        var readOnly: Set<String> = [], typedDuring: Set<String> = []
        for target in targets {
            for t in await panes.editorSnapshot(in: target.scope, paneId: target.paneId).tabs {
                if let path = t.path, t.readOnly, skipped.contains(path), found.contains(path) { readOnly.insert(path) }
            }
            var pending: Set<EditorTabSubject>?
            for attempt in 0..<3 {
                let tabs = await panes.editorSnapshot(in: target.scope, paneId: target.paneId).tabs.filter { t in
                    guard let path = t.path, skipped.contains(path), !t.readOnly else { return false }
                    return pending?.contains(t.subject) ?? true
                }
                if tabs.isEmpty { break }
                let answers = try await replaceTexts(files, tabs.map(\.text), s, replacement)
                let sent = Array(zip(tabs, answers))
                let outcome = await panes.updateEditor(in: target.scope, paneId: target.paneId) { snap -> (done: [String: Int], stale: [EditorTabSubject]) in
                    var done: [String: Int] = [:], stale: [EditorTabSubject] = []
                    for (tab, answer) in sent where answer.count > 0 {
                        guard let i = snap.tabs.firstIndex(where: { $0.subject == tab.subject }) else { continue }
                        guard snap.tabs[i].text == tab.text else { stale.append(tab.subject); continue }
                        guard let change = editorReplaceChange(old: tab.text, new: answer.text) else { continue }
                        snap.tabs[i].text = answer.text
                        snap.tabs[i].edits += 1
                        snap.tabs[i].preview = false   // an edit keeps a preview tab
                        let serial = (snap.tabs[i].lastAgentEdit?.serial ?? 0) + 1
                        snap.tabs[i].lastAgentEdit = EditorAgentEdit(serial: serial, range: change.range, text: change.text)
                        if let path = tab.path, done[path] == nil { done[path] = answer.count }
                    }
                    return (done, stale)
                }
                for (path, n) in outcome.done where perPath[path] == nil { perPath[path] = n }
                if outcome.stale.isEmpty { break }
                if attempt == 2 {
                    for tab in tabs where outcome.stale.contains(tab.subject) { if let p = tab.path { typedDuring.insert(p) } }
                }
                pending = Set(outcome.stale)
            }
        }
        var count = 0
        for n in perPath.values { count += n }
        var failures: [EditorReplaceFailure] = []
        for p in readOnly.sorted() where perPath[p] == nil {
            failures.append(EditorReplaceFailure(path: p, error: EditorReplaceFailure.readOnlyTab))
        }
        for p in typedDuring.subtracting(readOnly).sorted() where perPath[p] == nil {
            failures.append(EditorReplaceFailure(path: p, error: EditorReplaceFailure.typedDuring))
        }
        return (count, Set(perPath.keys), failures)
    }

    await registry.register(Action(
        name: "editor_replace",
        description: "Replace every match of an editor pane's Search view — its query and switches — with "
            + "replacement (may be empty; with regex, $1, ${name} and $$ expand as Go's regexp.Expand reads "
            + "them), across the files the search covers, searching again first. A file open in any editor "
            + "pane of the window, in any conversation of the project, is edited in its buffer (unsaved; ⌘Z "
            + "undoes it) and its file is left as it is; every other "
            + "file is written. file (absolute) limits it to one file. cancel true stops a replace in flight "
            + "between batches, or an undo between files; what was written stays. Answers replaced, files and failures with the pane's "
            + "state; editor_replace_undo puts back what it wrote. Confined to the active project's roots "
            + "(Invariant 6, Decision 36, Decision 39). Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema(["replacement": .object(["type": .string("string")]), "file": .object(["type": .string("string")]),
                        "cancel": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace")
            if flag(params, "cancel") {
                await panes.updateEditor(paneId: pane) { s in if s.search.replace.inFlight { s.search.replace.cancelRequested = true } }
                return await reply(pane)
            }
            guard let replacement = optionalString(params, "replacement") else {
                throw StandardActionError.missingParam(action: "editor_replace", param: "replacement")
            }
            let only = try await optionalString(params, "file").flatMap { $0.isEmpty ? nil : $0 }
                .asyncMap { try await confine($0, action: "editor_replace").path }
            let files = try requireFiles("editor_replace")
            // Claimed in one turn (Rule 5): one replace per pane. An empty query replaces nothing (ruling 9).
            // Claimed in its scope, which every later read and write names: a project or conversation
            // switch mid-run must not strand the pane in flight or lose the undo record (review I1).
            let (home, claim) = await panes.updateEditorNamingScope(paneId: pane, create: true) { s -> EditorSearchState? in
                guard !s.search.replace.inFlight, !s.search.query.isEmpty else { return nil }
                s.search.replace.text = replacement
                s.search.replace.shown = true
                s.search.replace.inFlight = true
                s.search.replace.cancelRequested = false
                return s.search
            }
            guard let search = claim else { return await reply(pane) }
            // Final review C1: the roots the run claimed, sent on every batch. Go resolves the active
            // project on each call, so after a project switch an unnamed call would walk the new
            // project's roots with this run's cursor; named, it is refused and the run stops there.
            let claimed = await roots()
            // Pre-flight F2: every editor pane the store holds, hidden scopes too, so no open tab's
            // file is written (spec, Open tabs; Decision 39).
            let targets = await panes.editorPanesInEveryScope()
            var open: [String] = []
            for t in targets { open += t.paths }
            var run = EditorReplaceRun()
            var failure: Error?
            var after = ""
            repeat {
                let cancelRequested = await panes.editorSnapshot(in: home, paneId: pane).search.replace.cancelRequested
                if Task.isCancelled || cancelRequested {
                    run.cancelled = true
                    break
                }
                var args = replaceArgs(search, replacement)
                args["roots"] = .array(claimed.map { .string($0) })
                args["skip"] = .array(open.map { .string($0) })
                if let only { args["only"] = .string(only) }
                if !after.isEmpty { args["after"] = .string(after) }
                args["max_files"] = .integer(Int64(editorReplaceBatchFiles))
                let sent = args
                // Its own task (ruling 1): cancelling this handler never cancels a call in flight, whose
                // reply names files already written — the undo needs every one.
                let batch = Task { try await filesTool(files, "files_replace", sent, timeout: MCPClient.mutationReplyTimeout) }
                do {
                    switch try await batch.value {
                    case .failed(let text): failure = EditorFilesError(description: text)
                    case .ok(let o):
                        let b = editorReplaceBatch(from: o)
                        run.add(b)
                        after = b.next
                    }
                } catch { failure = error }
            } while failure == nil && !after.isEmpty
            if failure == nil, !run.cancelled {
                do {
                    let edited = try await replaceInBuffers(files, targets: targets, skipped: run.skipped, search, replacement)
                    run.addBuffers(count: edited.count, paths: edited.paths)
                    run.failures += edited.failures
                } catch { failure = error }
            }
            // A failure after a batch landed is listed with the run (Rule 8): what was written stays
            // undoable, and the result line says why the rest was not (final review C1).
            if let failure, !run.undo.isEmpty || run.replaced > 0 {
                run.failures.append(EditorReplaceFailure(path: "", error: String(describing: failure)))
            }
            let result = run.result
            let recorded = failure == nil || !result.undo.isEmpty || result.replaced > 0
            // Final review I2: a run that wrote no file, edited no buffer and listed nothing (a press
            // with nothing left, a cancel before the first batch) never wipes a replace still undoable.
            let changedNothing = result.undo.isEmpty && result.replaced == 0 && result.failures.isEmpty
            await panes.updateEditor(in: home, paneId: pane) { s in
                s.search.replace.inFlight = false
                s.search.replace.cancelRequested = false
                if recorded, !(changedNothing && s.search.replace.last?.undoable == true) { s.search.replace.last = result }
            }
            // The search runs again to show what is left (spec); its own error lands in the view. Not
            // once the operator has left the scope: it would plant a search in another scope's pane.
            // Nor once the pane searches something else: the operator's newer search stands (final
            // review M4).
            let now = await panes.editorSnapshot(in: home, paneId: pane).search
            let same = now.query == search.query && now.caseSensitive == search.caseSensitive
                && now.wholeWord == search.wholeWord && now.regex == search.regex
            if same, await panes.activeScope == home {
                try? await runSearch(pane, query: search.query, caseSensitive: search.caseSensitive,
                                     wholeWord: search.wholeWord, regex: search.regex)
            }
            if let failure { throw failure }
            guard case .object(var o) = await reply(pane, in: home) else { return .null }
            o["replaced"] = .number(Double(result.replaced))
            o["files"] = .number(Double(result.files))
            o["failures"] = editorReplaceFailuresJSON(result.failures)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))

    await registry.register(Action(
        name: "editor_replace_undo",
        description: "Undo an editor pane's latest editor_replace: each file it wrote is put back, only while "
            + "that file is exactly as the replace left it (its modification time unchanged); a file changed "
            + "or deleted since, or open in a tab of any editor pane, is left as it is and listed. Buffer edits are not part of it (⌘Z in their tab). "
            + "One undo is kept, the latest replace's, while the window is open; refused when there is none. "
            + "Answers restored and failures with the pane's state. Allowed everywhere.",
        kind: .mutate, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await editorPane(params, action: "editor_replace_undo")
            let files = try requireFiles("editor_replace_undo")
            let (home, claim) = await panes.updateEditorNamingScope(paneId: pane, create: true) { s -> EditorUndoClaim in
                if s.search.replace.inFlight { return .busy }
                guard let last = s.search.replace.last, last.undoable else { return .nothing }
                s.search.replace.inFlight = true
                s.search.replace.undoing = true           // pre-flight F6: the view says "undoing"
                s.search.replace.cancelRequested = false
                return .claimed(last.undo)
            }
            let records: [EditorReplaceUndoRecord]
            switch claim {
            case .busy: return await reply(pane)               // Rule 5
            case .nothing: throw EditorActionError.nothingToUndo
            case .claimed(let r): records = r
            }
            var restored = 0
            var failures: [EditorReplaceFailure] = []
            var stopped = false
            for r in records {
                // Pre-flight F6: the Cancel the view draws (`editor_replace {cancel}`) lands before the
                // next file; the rest are left as they are and listed.
                if !stopped {
                    let cancelRequested = await panes.editorSnapshot(in: home, paneId: pane).search.replace.cancelRequested
                    stopped = Task.isCancelled || cancelRequested
                }
                if stopped { failures.append(EditorReplaceFailure(path: r.path, error: EditorReplaceFailure.stopped)); continue }
                // Decision 39 (final review M5): a file open in a tab — in any editor pane of any scope,
                // opened since the replace — is never written; its tab is the operator's to undo.
                if await panes.editorPanesInEveryScope().contains(where: { $0.paths.contains(r.path) }) {
                    failures.append(EditorReplaceFailure(path: r.path, error: EditorReplaceFailure.openInTab))
                    continue
                }
                do {
                    switch try await filesTool(files, "files_read", ["path": .string(r.path)]) {
                    case .failed(let text):
                        failures.append(EditorReplaceFailure(path: r.path, error: text))
                        continue
                    case .ok(let o):
                        guard o["exists"] == .bool(true), Int64(o["mtime"]?.intValue ?? 0) == r.mtime else {
                            failures.append(EditorReplaceFailure(path: r.path, error: EditorReplaceFailure.changedSince))
                            continue
                        }
                    }
                    switch try await filesTool(files, "files_write", ["path": .string(r.path), "text": .string(r.original),
                                                                      "create": .bool(false)]) {
                    case .failed(let text): failures.append(EditorReplaceFailure(path: r.path, error: text))
                    case .ok: restored += 1
                    }
                } catch {
                    failures.append(EditorReplaceFailure(path: r.path, error: error is CancellationError
                                                         ? EditorReplaceFailure.stopped : String(describing: error)))
                }
            }
            let done = (restored: restored, failures: failures)
            await panes.updateEditor(in: home, paneId: pane) { s in
                s.search.replace.inFlight = false
                s.search.replace.undoing = false
                s.search.replace.cancelRequested = false
                s.search.replace.last?.undone = true
                s.search.replace.last?.restored = done.restored
                s.search.replace.last?.failures = done.failures
            }
            let q = await panes.editorSnapshot(in: home, paneId: pane).search
            if !q.query.isEmpty, await panes.activeScope == home {
                try? await runSearch(pane, query: q.query, caseSensitive: q.caseSensitive, wholeWord: q.wholeWord, regex: q.regex)
            }
            guard case .object(var o) = await reply(pane, in: home) else { return .null }
            o["restored"] = .number(Double(restored))
            o["failures"] = editorReplaceFailuresJSON(failures)
            return .object(o)
        },
        price: (production: .allow, otherwise: .allow)))
}

/// One pane's column writes at a time (final review I2): each runs after the one before it for the
/// same pane has finished, read through both stores' writes.
private actor EditorColumnWrites {
    private var tails: [String: Task<Void, Never>] = [:]

    func serially(_ pane: String, _ op: @escaping @Sendable () async -> EditorColumnState) async -> EditorColumnState {
        let previous = tails[pane]
        let task = Task { await previous?.value; return await op() }
        tails[pane] = Task { _ = await task.value }
        return await task.value
    }
}

private enum EditorCloseOutcome: Sendable { case noTab, unsaved(String), closed }
private enum EditorPeekOutcome: Sendable { case ok, noTab, noMarks, noChange, noPeek }
private enum EditorReplaceOutcome: Sendable { case noTab, readOnly(String, String?), stale(String), replaced }
private enum EditorUndoClaim: Sendable { case busy, nothing, claimed([EditorReplaceUndoRecord]) }
private enum EditorSaveClaim: Sendable {
    case noTab, busy, noScratchPath
    case readOnly(String, String?)
    case alreadyOpen(String, String)
    case claimed(subject: EditorTabSubject, text: String, create: Bool)
}

/// The tab `path` (or `scratch`, an Untitled-N number) names, else the active tab. Always called
/// inside the closure that then uses it.
private func editorTabIndex(_ s: EditorSnapshot, path: String?, scratch: Int? = nil, diff: EditorTabSubject? = nil) -> Int? {
    if let diff { return s.tabs.firstIndex { $0.subject == diff } }
    if let path { return s.tabs.firstIndex { $0.path == path } }
    if let scratch { return s.tabs.firstIndex { $0.subject == .scratch(number: scratch) } }
    guard let i = s.active, i < s.tabs.count else { return nil }
    return i
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await f(self)
    }
}

/// Whether a root's status says what is changed in it. An errored root, or one still loading its
/// first read, says nothing: a file missing from it is unknown, not "no longer changed".
private func editorRootIsKnown(_ r: GitRootState) -> Bool {
    r.error == nil && !(r.loading && r.files.isEmpty)
}
