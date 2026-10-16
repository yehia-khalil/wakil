import AppKit
import Observation
import WakilKit
import SwiftUI
import WebKit

/// The editor pane (3b-i): a tab strip, the active tab's notice and disk lines, the scratch
/// save-as field, and Monaco — with, from 3b-ii, the left column (`EditorColumn`) beside them.
///
/// **It decides nothing.** What Monaco is told comes from `editorRenderSteps` (tested); every
/// click is an `editor_*` action through the window's dispatch, the same path the agent's calls
/// take. The operator's typing and view reports are the one non-action path
/// (`WindowModel.editorBufferDidChange` / `editorViewDidReport`). Its own state is the save-as
/// field's text and failure, and Compare's diff while it is open.
struct EditorPane: View {
    let snapshot: EditorSnapshot
    let viewOptions: EditorViewOptions
    let showIgnored: Bool
    let pane: Pane
    /// One `editor_*` action on THIS pane (Canvas folds `pane` in), awaited.
    let dispatch: (String, [String: JSONValue]) async -> Void
    /// The operator's text for a tab — by its subject, never its position (final review I1) — with
    /// the agent-edit serial the page had applied.
    let bufferChanged: (EditorTabSubject, String, Int) async -> Void
    let viewReported: (EditorTabSubject, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) async -> Void
    /// The path field's Save; `replace` is the inline "Replace <name>?" answered yes.
    let saveAs: (String, Bool) async -> EditorSaveAsResult
    let cancelSaveAs: () -> Void
    /// The saving tick's Cancel (Rule 4).
    let cancelSave: () -> Void
    /// The file's text on disk now, for Compare; nil when it could not be read.
    let diskText: (String) async -> String?
    let saveAsRequested: Bool
    /// The save-as fallback when no tree row is selected.
    let firstRoot: String
    /// The window's roots in order, for the tree (3b-ii).
    let roots: [String]
    /// The window's one file list per root (`WindowModel.editorFiles`).
    let files: EditorFileListsState
    /// The column a pane that never set its own starts from.
    let columnDefault: EditorColumnState
    /// Monaco's find bar reporting its query, switches and count (the view-report path).
    let findReported: (EditorFindReport) async -> Void
    /// The operator's ⌘B / ⌘⇧F asking THIS pane's column for the keyboard, and its acknowledgement.
    let columnFocusRequest: EditorColumnFocusRequest?
    let columnFocusTaken: () -> Void
    /// The reveal button's action (3b-ii-b): `WindowModel.revealActiveFileInTree` for this pane.
    let revealInTree: () async -> Void
    /// The operator's reveal asking THIS pane's tree to select a row, and its acknowledgement.
    let revealRequest: EditorTreeRevealRequest?
    let revealTaken: () -> Void
    /// The org, project and conversation on screen: a switch drops a reveal still waiting for its row.
    let scope: String
    /// A middle-click's close of one tab, by subject: ⌘W's rule (a dirty tab asks).
    let closeTab: (EditorTabSubject) async -> Void
    let isFocusedPane: Bool
    /// No plane, palette or window prompt is in front of the canvas (the terminal pane's test).
    let isKeyboardOwner: Bool
    /// The window's unsaved prompt, when it asks about one of THIS pane's tabs (`.closeTab`).
    let unsavedPrompt: UnsavedPrompt?
    /// Save / Don't Save / Cancel for that prompt.
    let resolveUnsaved: (UnsavedChoice) -> Void

    @State private var host = EditorHost()
    /// Compare's diff host: made the first time Compare opens, kept for the pane's life.
    @State private var compareHost = GitDiffHost()
    /// Compare, open: the path and the disk text it shows against the buffer.
    @State private var comparing: EditorComparing?
    /// Compare could not read the file: the reason, whole (Rule 8).
    @State private var compareFailure: String?
    @State private var saveAsPath = ""
    @State private var saveAsFailure: String?
    /// The path names a file that exists: the field asks "Replace <name>?" before writing (Rule 1).
    @State private var saveAsReplacing: String?
    @State private var saveAsInFlight = false
    @FocusState private var saveAsFocused: Bool
    /// The column's selected row and search result: the pane's, so they outlive the column (Rule 6).
    @State private var treeSelected: String?
    @State private var resultSelected: String?
    /// The column view the operator asked to type in, until it shows and takes the keyboard. Only the
    /// operator's own moves set it (⌘B / ⌘⇧F, the strip toggle, the column's header); an agent's
    /// `editor_tree` never moves the keyboard (Rule 6).
    @State private var columnFocusWanted: EditorColumnView?
    /// The column holds the keyboard: a focus change of the pane leaves it there (Rule 3).
    @State private var columnHasKeyboard = false
    /// The revealed file's row, until the column has drawn and selected it.
    @State private var pendingReveal: String?
    /// Each tab's horizontal span in the strip's space, reported by the tabs themselves.
    @State private var tabSpans: [Int: ClosedRange<Double>] = [:]
    /// Where a dragged tab would land now, while a drag is over the strip.
    @State private var drop: EditorTabDrop?
    /// The tabs' origin in the visible strip, for the middle-click monitor.
    @State private var tabsOrigin: CGPoint = .zero

    private var activeTab: EditorTab? {
        snapshot.active.flatMap { $0 < snapshot.tabs.count ? snapshot.tabs[$0] : nil }
    }

    private var column: EditorColumnState { snapshot.column ?? columnDefault }

    private var treeRows: [EditorTreeRow] {
        editorTreeRows(roots.compactMap { files.listings[$0] }, open: Set(column.open), dirs: files.dirs,
                       loading: files.loading, dirErrors: files.dirErrors, showIgnored: showIgnored)
    }

    /// Save-as starts in the selected row's folder, else the first root.
    private var saveAsBase: String {
        treeSelected.flatMap { id in treeRows.first { $0.id == id } }.map(editorFolder(of:)) ?? firstRoot
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if column.shown {
                    EditorColumn(column: column, rows: treeRows, pendingRoots: roots.filter { files.listings[$0] == nil },
                                 search: snapshot.search, paneWidth: geo.size.width, dispatch: dispatch,
                                 canReveal: activeTab?.path != nil,
                                 reveal: { Task { await revealInTree() } },
                                 selected: $treeSelected, selectedResult: $resultSelected,
                                 focusWanted: $columnFocusWanted, hasKeyboard: $columnHasKeyboard,
                                 pendingReveal: $pendingReveal)
                }
                editorStack
            }
        }
        .onChange(of: viewOptions, initial: true) { _, o in
            host.setOptions(o)
            // A nil renderer is fine: showCompare re-sends the font size when Compare opens.
            compareHost.renderer?.setFontSize(o.fontSize)
        }
        .task {
            host.bufferChanged = bufferChanged
            host.viewReported = viewReported
            host.findReported = findReported
            // Handed in first, so `start` applies the newest snapshot, never this one if a newer
            // one landed while the renderer was being made.
            host.apply(snapshot)
            await host.start()
            if isFocusedPane, !saveAsRequested, !columnOwnsKeyboard { host.focus() }
        }
        .onAppear { takeColumnFocusRequest(); takeRevealRequest() }
        .onChange(of: columnFocusRequest) { _, _ in takeColumnFocusRequest() }
        .onChange(of: revealRequest) { _, _ in takeRevealRequest() }
        // Final review T4r: a reveal whose row never appeared must not select a row later, in this
        // scope or the next one.
        .onChange(of: scope) { _, _ in pendingReveal = nil }
        .onChange(of: snapshot) { old, now in
            host.apply(now)
            // Compare shows one file's disk against its buffer; it closes when that tab goes.
            if let c = comparing, !now.tabs.contains(where: { $0.path == c.path }) { closeCompare() }
            // Rule 3: a tab that newly comes to the front of the focused pane (⌘T, ⌘P, a tab
            // click) takes the keyboard, as a new pane does. A preview tab is browsing (the tree's
            // or Search's single click, ↑↓ and Return): the keyboard stays in the column.
            let wasActive = old.active.flatMap { old.tabs.indices.contains($0) ? old.tabs[$0].subject : nil }
            let isActive = now.active.flatMap { now.tabs.indices.contains($0) ? now.tabs[$0].subject : nil }
            let preview = now.active.map { now.tabs.indices.contains($0) && now.tabs[$0].preview } ?? false
            if isActive != nil, isActive != wasActive, !preview, isFocusedPane, !saveAsRequested, comparing == nil {
                host.focus()
            }
        }
        .onChange(of: column.shown) { _, shown in
            guard !shown else { return }
            columnFocusWanted = nil
            // The column held the keyboard, and it is gone: the editor has it back. Anywhere else
            // (Monaco's find field), the keyboard stays where it is.
            guard columnHasKeyboard else { return }
            columnHasKeyboard = false
            if isFocusedPane, !saveAsRequested, comparing == nil { host.focus() }
        }
        // A click into this pane's column, or ⌘B from another pane, already put the keyboard there:
        // the pane being focused after it leaves it there.
        .onChange(of: isFocusedPane) { _, now in
            guard now else {
                // 3b-v PR 8: focus moved to another pane, so the keyboard leaves Monaco (or
                // Compare's diff) with it — keys typed after a click on the Settings tree were
                // going into the file. Only when one of them still holds it: a field the click
                // landed on has it already, and a pane that takes it is not overruled.
                host.resignKeyboard(alsoFrom: compareHost.renderer?.webView)
                return
            }
            if !saveAsRequested, !columnOwnsKeyboard { host.focus() }
        }
        // The prompt took the keyboard; whatever it resolved to, the editor has it back.
        .onChange(of: unsavedPrompt == nil) { _, gone in
            if gone, isFocusedPane, !saveAsRequested { host.focus() }
        }
        .onKeyPress(.escape) {
            guard comparing != nil else { return .ignored }
            closeCompare()
            return .handled
        }
        // A container: without it the pane's identifier overrides its children's, and Compare's
        // Close reads as `editor.pane` (measured: axresolve not_found on editor.compare.close).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.pane")
    }

    /// The 3b-i pane beside the column: tab strip, lines, save-as and Monaco.
    private var editorStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unsavedPrompt { UnsavedPromptBar(message: closeTabMessage(unsavedPrompt), resolve: resolveUnsaved) }
            // Drawn even with no tab: its toggle is how an empty pane shows the column without ⌘B.
            tabStrip
            if let tab = activeTab {
                if let notice = tab.notice { noticeLine(notice) }
                if tab.diskState == .changedOnDisk, comparing == nil { diskChangedLine(tab) }
            }
            if let compareFailure {
                lineText(compareFailure).accessibilityIdentifier("editor.compare.failure")
            }
            if saveAsRequested { saveAsField }
            ZStack {
                if let comparing {
                    compareView(comparing)
                } else {
                    GitDiffHostView(webView: host.renderer?.webView)
                        .accessibilityIdentifier("editor.monaco")
                    if snapshot.tabs.isEmpty { emptyState }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The column holds the keyboard, or the operator asked for it and it is on its way.
    private var columnOwnsKeyboard: Bool { column.shown && (columnHasKeyboard || columnFocusWanted != nil) }

    private func takeColumnFocusRequest() {
        guard let r = columnFocusRequest else { return }
        columnFocusWanted = r.view
        columnFocusTaken()
    }

    /// The reveal asked this pane's tree to select a file's row; the column selects it once drawn. A
    /// newer reveal replaces one still waiting for its row (final review T4r).
    private func takeRevealRequest() {
        guard let r = revealRequest else { return }
        pendingReveal = r.path
        revealTaken()
    }

    private func closeTabMessage(_ prompt: UnsavedPrompt) -> String {
        "Save changes to \(prompt.files.first ?? "this tab")?"
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        let titles = editorTabTitles(snapshot.tabs)
        return HStack(spacing: 0) {
            // The column's toggle, leading, so the column can always be shown again.
            Button {
                if !column.shown { columnFocusWanted = column.view }   // the operator's own toggle (Rule 3)
                Task { await dispatch("editor_tree", ["shown": .bool(!column.shown), "view": .string(column.view.rawValue)]) }
            }
                label: { Image(systemName: "sidebar.left").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(EditorPaneStyle.text)
                .opacity(column.shown ? 0.9 : 0.5)
                .padding(.leading, 10)
                .help("Files ⌘B · Search ⌘⇧F")
                .accessibilityIdentifier("editor.column.toggle")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(snapshot.tabs.enumerated()), id: \.offset) { index, tab in
                        tabView(tab, title: titles[index], index: index, on: index == snapshot.active)
                    }
                }
                .coordinateSpace(name: "editor.tabs")
                .onPreferenceChange(EditorTabSpansKey.self) { tabSpans = $0 }
                // Where the tabs sit in the visible strip (they move as it scrolls), for the middle-click.
                .background(GeometryReader { g in
                    Color.clear.preference(key: EditorTabStripOriginKey.self, value: g.frame(in: .named("editor.strip")).origin)
                })
                .onPreferenceChange(EditorTabStripOriginKey.self) { tabsOrigin = $0 }
                // Where the dragged tab would land: violet, on the side away from where it came from.
                .overlay(alignment: .topLeading) {
                    if let drop {
                        Rectangle().fill(EditorPaneStyle.violet).frame(width: 2, height: 22)
                            .offset(x: editorTabDropX(drop, spans: orderedSpans) - 1, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .coordinateSpace(name: "editor.strip")
            // A middle-click on a tab: ⌘W's path for it — a clean tab closes, a dirty one asks (3b-i's
            // prompt). One monitor for the strip, never a view over each tab.
            .background(EditorTabStripMiddleClick(
                spans: orderedSpans, contentOrigin: tabsOrigin, height: 30, enabled: isKeyboardOwner,
                onMiddleClick: { index in
                    guard snapshot.tabs.indices.contains(index) else { return }
                    let subject = snapshot.tabs[index].subject
                    Task { await closeTab(subject) }
                }))
        }
        .frame(height: 36)
    }

    private var orderedSpans: [ClosedRange<Double>] {
        snapshot.tabs.indices.map { tabSpans[$0] ?? 0...0 }
    }

    private func tabView(_ tab: EditorTab, title: String, index: Int, on: Bool) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1)
                .fill(on ? EditorPaneStyle.tick : .clear)
                .frame(width: 2, height: 15)
                .shadow(color: on ? EditorPaneStyle.tick.opacity(0.7) : .clear, radius: 3.5)
            Text(title)
                .font(.system(size: 11.5, design: .monospaced))
                .italic(tab.preview)
                .foregroundStyle(on ? EditorPaneStyle.text : EditorPaneStyle.text.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.dirty {
                Circle().fill(EditorPaneStyle.text.opacity(0.52)).frame(width: 5, height: 5)
                    .accessibilityLabel("unsaved")
            }
            switch tab.diskState {
            case .changedOnDisk:
                Text("changed on disk").font(.system(size: 10)).foregroundStyle(EditorPaneStyle.amber)
            case .deleted:
                Text("deleted").font(.system(size: 10)).foregroundStyle(EditorPaneStyle.text.opacity(0.45))
            case .inSync:
                EmptyView()
            }
            if tab.saving {
                EditorBusyTick()
                Button("Cancel", action: cancelSave)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saving.cancel")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 30)
        .background(on ? EditorPaneStyle.text.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .background(GeometryReader { g in
            let f = g.frame(in: .named("editor.tabs"))
            Color.clear.preference(key: EditorTabSpansKey.self, value: [index: Double(f.minX)...Double(f.maxX)])
        })
        .contentShape(Rectangle())
        // A drag needs 4 pt of movement, so a click stays a tab click (ruling 14). A drop anywhere over
        // a tab moves to that tab's index (pre-flight F4); off the strip or on its own place, nothing.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("editor.tabs"))
            .onChanged { g in
                drop = editorTabDropTarget(from: index, x: g.location.x, y: g.location.y, spans: orderedSpans, height: 30)
                    .map { EditorTabDrop(from: index, to: $0) }
            }
            .onEnded { g in
                defer { drop = nil }
                guard let to = editorTabDropTarget(from: index, x: g.location.x, y: g.location.y,
                                                   spans: orderedSpans, height: 30) else { return }
                Task { await dispatch("editor_move_tab", ["from": .integer(Int64(index)), "to": .integer(Int64(to))]) }
            })
        // A double-click keeps a preview tab (a file tab opened again without preview). One tap gesture
        // reading the click count: a `count: 2` gesture beside it would hold every single click for
        // the double-click interval.
        .onTapGesture {
            if NSApp.currentEvent?.clickCount ?? 1 >= 2, let path = tab.path {
                Task { await dispatch("editor_open", ["path": .string(path), "preview": .bool(false)]) }
            } else {
                focusTab(index)
            }
        }
        .help(tab.path ?? title)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.tab.\(index)")
        .accessibilityAction { focusTab(index) }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func focusTab(_ index: Int) {
        guard index != snapshot.active else { return }
        Task { await dispatch("editor_focus_tab", ["index": .integer(Int64(index))]) }
    }

    // MARK: - Lines

    /// Rule 8: whole, wrapping, never truncated.
    private func lineText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeLine(_ notice: String) -> some View {
        lineText(notice).accessibilityIdentifier("editor.notice")
    }

    private func diskChangedLine(_ tab: EditorTab) -> some View {
        let name = ((tab.path ?? "") as NSString).lastPathComponent
        return HStack(spacing: 12) {
            Text("\(name) changed on disk")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.amber)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reload") { Task { await dispatch("editor_reload", [:]) } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text)
                .accessibilityIdentifier("editor.reload")
            Button("Compare") { openCompare(tab) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorPaneStyle.text)
                .accessibilityIdentifier("editor.compare")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.diskChanged")
    }

    // MARK: - Compare

    private func openCompare(_ tab: EditorTab) {
        guard let path = tab.path else { return }
        compareFailure = nil
        Task {
            guard let disk = await diskText(path) else {
                compareFailure = "\((path as NSString).lastPathComponent) could not be read from disk to compare"
                return
            }
            comparing = EditorComparing(path: path, disk: disk)
            await compareHost.start()
            compareHost.onKey = { key in if key == "escape" { closeCompare() } }
            compareHost.captureKeys(true)
            showCompare()
        }
    }

    /// Disk on the original side, the buffer as it is now on the modified side.
    private func showCompare() {
        guard let c = comparing, let renderer = compareHost.renderer,
              let tab = snapshot.tabs.first(where: { $0.path == c.path }) else { return }
        renderer.show(original: c.disk, modified: tab.text, language: tab.language)
        renderer.setFontSize(viewOptions.fontSize)
    }

    private var ownsCompareEscape: Bool {
        isKeyboardOwner && isFocusedPane && unsavedPrompt == nil && !saveAsRequested
    }

    private func closeCompare() {
        comparing = nil
        compareHost.captureKeys(false)
        host.focus()
    }

    private func compareView(_ c: EditorComparing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("\((c.path as NSString).lastPathComponent) — on disk ↔ unsaved")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Esc is Close wherever the keyboard is in this window (a click on Compare leaves it
                // with the window, out of reach of the pane's onKeyPress and the page's own keys) —
                // but only while no plane, prompt or field claims Esc: a window holds one live
                // `.cancelAction` (`ConfirmationPlane.ownsEscape`).
                Button("Close", action: closeCompare)
                    .keyboardShortcut(ownsCompareEscape ? KeyboardShortcut.cancelAction : nil)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .accessibilityIdentifier("editor.compare.close")
            }
            .padding(.horizontal, 10)
            GitDiffHostView(webView: compareHost.renderer?.webView)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("editor.compare.diff")
        }
    }

    // MARK: - Save as

    private var saveAsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TextField("Save as (a path inside the project)", text: $saveAsPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text)
                    .focused($saveAsFocused)
                    .onSubmit { submitSaveAs() }
                    .onKeyPress(.escape) {
                        dismissSaveAs()
                        return .handled
                    }
                    .accessibilityIdentifier("editor.saveAs.field")
                if saveAsInFlight { EditorBusyTick() }
                Button("Save") { submitSaveAs() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EditorPaneStyle.text)
                    .disabled(saveAsInFlight)
                    .accessibilityIdentifier("editor.saveAs.save")
                Button("Cancel", action: dismissSaveAs)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saveAs.cancel")
            }
            // Rule 1: writing over an existing file destroys it, so the field asks first, inline.
            if let name = saveAsReplacing {
                HStack(spacing: 12) {
                    Text("Replace \(name)?")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorPaneStyle.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Replace") { submitSaveAs(replace: true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(EditorPaneStyle.text)
                        .disabled(saveAsInFlight)
                        .accessibilityIdentifier("editor.saveAs.replace")
                    Button("Cancel") {
                        saveAsReplacing = nil
                        saveAsFocused = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                    .accessibilityIdentifier("editor.saveAs.replaceCancel")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.saveAs.replacePrompt")
            }
            if let saveAsFailure {
                Text(saveAsFailure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("editor.saveAs.failure")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EditorPaneStyle.text.opacity(0.04))
        // Rule 3: the field takes the keyboard when it appears, prefilled with the selected tree row's
        // folder, else the first root (Rule 9: a suggestion, typed over freely).
        .onAppear {
            saveAsPath = saveAsBase.isEmpty ? "" : saveAsBase + "/"
            saveAsFailure = nil
            saveAsReplacing = nil
            saveAsFocused = true
        }
        // The roots can land after the field appears (just after a launch), and the selected row can
        // move: the prefill follows while the field still holds only the old prefill, never over what
        // was typed.
        .onChange(of: saveAsBase) { old, now in
            if saveAsPath == (old.isEmpty ? "" : old + "/") { saveAsPath = now.isEmpty ? "" : now + "/" }
        }
        // AppKit selects a field's whole text when it takes focus, so the first key typed would
        // replace the prefilled root (and a path being corrected): the caret goes to the end.
        .onChange(of: saveAsFocused) { _, now in if now { caretToEndOfFocusedField() } }
        // A different path is a different question: the Replace prompt was about the old one.
        .onChange(of: saveAsPath) { _, _ in saveAsReplacing = nil }
    }

    /// Once the field editor has the keyboard (the next turn), its caret goes after the text.
    private func caretToEndOfFocusedField() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func submitSaveAs(replace: Bool = false) {
        guard !saveAsInFlight else { return }   // Rule 5: one save at a time
        saveAsInFlight = true
        let path = saveAsPath
        Task {
            let result = await saveAs(path, replace)
            saveAsInFlight = false
            saveAsReplacing = nil
            saveAsFailure = nil
            switch result {
            case .saved: host.focus()
            case .exists(let name): saveAsReplacing = name
            case .failed(let text): saveAsFailure = text
            }
        }
    }

    private func dismissSaveAs() {
        saveAsFailure = nil
        saveAsReplacing = nil
        cancelSaveAs()
        host.focus()
    }

    // MARK: - Empty

    private var emptyState: some View {
        ZStack {
            EditorPaneStyle.slab
            Text("⌘P to open a file · ⌘T for a scratch tab")
                .font(.system(size: 12))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.46))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.empty")
    }
}

private struct EditorTabSpansKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<Double>] = [:]
    static func reduce(value: inout [Int: ClosedRange<Double>], nextValue: () -> [Int: ClosedRange<Double>]) {
        value.merge(nextValue()) { _, b in b }
    }
}

private struct EditorTabStripOriginKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct EditorComparing: Equatable {
    let path: String
    let disk: String
}

// MARK: - The Monaco host

/// The pane's one Monaco editor and what it was last told. A class held in `@State`, so it lives
/// exactly as long as the pane's view identity does.
@MainActor @Observable
final class EditorHost {
    private(set) var renderer: MonacoEditorRenderer?
    /// What the renderer holds, per tab key (`editorRenderedAfter`).
    @ObservationIgnored var rendered: [String: EditorRendered] = [:]
    /// The key the renderer shows.
    @ObservationIgnored var active: String?
    /// The pane's last opened find serial, beside `rendered` rather than on a tab's entry, so closing
    /// every tab never makes the next one replay the find. Nil until the first snapshot seeds it.
    @ObservationIgnored var findShown: Int?
    /// The pane's closures, handed in by the view.
    @ObservationIgnored var bufferChanged: ((EditorTabSubject, String, Int) async -> Void)?
    @ObservationIgnored var viewReported: ((EditorTabSubject, EditorPosition, EditorRange?, ClosedRange<Int>?, Double) async -> Void)?
    /// Monaco's find bar state, a view report like the cursor's (`PaneStore.editorFindDidReport`).
    @ObservationIgnored var findReported: ((EditorFindReport) async -> Void)?
    /// The last snapshot's tabs, subject by key: a post is addressed by the subject its key names,
    /// never by a position that a close or open may have moved (final review I1).
    @ObservationIgnored private var subjects: [String: EditorTabSubject] = [:]
    /// The operator's own text posts still on their way to the store, and the texts they carry:
    /// a snapshot behind them is held (`editorSnapshotToRender`). The write that lands last brings
    /// its own snapshot, which renders.
    @ObservationIgnored private var typingInFlight = 0
    @ObservationIgnored private var typed: [String: Set<String>] = [:]
    /// View reports in flight: they hold nothing back, but keep the rendered cursor.
    @ObservationIgnored private var viewsInFlight = 0
    /// The agent-edit serial last told to the page, per key.
    @ObservationIgnored private var basisSent: [String: Int] = [:]
    @ObservationIgnored private var starting = false
    /// The newest snapshot handed in. One that lands while the renderer is still being made
    /// (a new pane's first tab) is applied when it exists, not dropped.
    @ObservationIgnored private var latest: EditorSnapshot?

    /// The offline rule list, compiled once per launch and shared by every editor pane.
    private static var networkBlock: WKContentRuleList?

    func start() async {
        guard renderer == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let block: WKContentRuleList
        do {
            if let cached = Self.networkBlock {
                block = cached
            } else {
                block = try await MonacoDiffRenderer.compileNetworkBlock()
                Self.networkBlock = block
            }
        } catch {
            // No rule list, no renderer: Monaco never loads without its network block.
            FileHandle.standardError.write(Data("monaco: no network block, no editor: \(error)\n".utf8))
            return
        }
        let made = MonacoEditorRenderer(blockNetwork: block)
        made.onLog = { line in FileHandle.standardError.write(Data("monaco-editor: \(line)\n".utf8)) }
        // The operator's own text and view go into `rendered` BEFORE the store round-trip, so
        // the snapshot that brings them back renders as no step (Task 7's rule).
        made.onText = { [weak self] key, text, basis in
            guard let self else { return }
            let subject: EditorTabSubject
            switch editorTypingPost(key: key, basis: basis, subjects: self.subjects, rendered: self.rendered) {
            case .drop: return
            case .resync(let storeText, let serial):
                // Made before an agent edit reached the page: the store drops it, so the page goes
                // back to the store's text rather than keep text the store lacks (final review I2).
                self.renderer?.resetText(key: key, text: storeText, basis: serial)
                return
            case .send(let s): subject = s
            }
            self.rendered[key]?.text = text
            self.typed[key, default: []].insert(text)
            self.typingInFlight += 1
            let send = self.bufferChanged
            Task { @MainActor in
                await send?(subject, text, basis)
                self.typingInFlight -= 1
                if self.typingInFlight == 0 { self.typed = [:] }
            }
        }
        made.onView = { [weak self] key, cursor, selection, visible, top in
            guard let self, let subject = self.subjects[key] else { return }
            self.rendered[key]?.cursor = cursor
            self.rendered[key]?.selection = selection
            self.viewsInFlight += 1
            let send = self.viewReported
            Task { @MainActor in
                await send?(subject, cursor, selection, visible, top)
                self.viewsInFlight -= 1
            }
        }
        made.onFind = { [weak self] report in
            guard let send = self?.findReported else { return }
            Task { @MainActor in await send(report) }
        }
        renderer = made
        applyOptions()
        if let latest { apply(latest) }
    }

    /// The options last asked for, applied when the renderer exists and again whenever they change.
    private var wantedOptions: EditorViewOptions?
    private var appliedOptions: EditorViewOptions?

    func setOptions(_ o: EditorViewOptions) {
        wantedOptions = o
        applyOptions()
    }

    private func applyOptions() {
        guard let renderer, let o = wantedOptions, o != appliedOptions else { return }
        renderer.setOptions(o)
        appliedOptions = o
    }

    /// Renders `snapshot` — unless it is behind the operator's own typing (`editorSnapshotToRender`).
    func apply(_ snapshot: EditorSnapshot) {
        latest = snapshot
        subjects = Dictionary(snapshot.tabs.map { (editorTabKey($0), $0.subject) }, uniquingKeysWith: { a, _ in a })
        guard let renderer else { return }
        let activeKey = active
        guard let shown = editorSnapshotToRender(
            snapshot, rendered: rendered, active: activeKey, typed: activeKey.flatMap { typed[$0] } ?? [],
            typingInFlight: typingInFlight > 0, viewInFlight: viewsInFlight > 0) else { return }
        let found = findShown ?? editorFindShownSeed(shown)
        let steps = editorRenderSteps(rendered: rendered, active: activeKey, snapshot: shown, findShown: found)
        editorApply(steps, to: renderer)
        rendered = editorRenderedAfter(steps, rendered: rendered, snapshot: shown)
        findShown = editorFindShownAfter(steps, findShown: found, snapshot: shown)
        active = shown.active.flatMap { $0 < shown.tabs.count ? editorTabKey(shown.tabs[$0]) : nil }
        // The page learns each serial after the steps that applied it, in call order.
        basisSent = basisSent.filter { rendered[$0.key] != nil }
        if let key = active, let serial = rendered[key]?.agentSerial, basisSent[key] != serial {
            basisSent[key] = serial
            renderer.setBasis(key: key, serial: serial)
        }
    }

    /// The editor takes the keyboard: the web view first responder, then Monaco.
    ///
    /// A pane's first focus can arrive before SwiftUI has put the new web view in the window
    /// (the renderer was made this same turn), when there is no window to make it first
    /// responder of. It waits for one, briefly: twenty tries a frame apart, then gives up.
    func focus(tries: Int = 20) {
        guard let renderer else { return }
        guard let window = renderer.webView.window else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus(tries: tries - 1) }
            return
        }
        window.makeFirstResponder(renderer.webView)
        renderer.focus()
    }

    /// The editor gives the keyboard up, when its web view — or `other`, Compare's — holds
    /// it: the window's first responder becomes nil, as a field does on Escape
    /// (`ApiFieldEditor`), and no pane owns the keys until one takes them. Anything else
    /// holding the keyboard keeps it.
    func resignKeyboard(alsoFrom other: NSView?) {
        // Either may be out of the window: Compare takes Monaco's place in the pane, and the
        // view hosting Monaco is dismantled while it is open (`GitDiffHostView`).
        let owners = [renderer?.webView, other].compactMap { $0 }
        guard let window = owners.lazy.compactMap(\.window).first,
              let responder = window.firstResponder as? NSView else { return }
        for owner in owners where responder === owner || responder.isDescendant(of: owner) {
            window.makeFirstResponder(nil)
            return
        }
    }
}

// MARK: - The unsaved prompt

/// Save / Don't Save / Cancel before unsaved edits are dropped (3b-i Task 9) — over an editor's tab
/// strip for one tab, centred on the canvas for a pane, an organisation switch or a quit.
///
/// It takes the keyboard when it appears (Rule 3), so Monaco does not keep Return and Esc:
/// **Return is Save, Esc is Cancel.** The buttons also carry the default and cancel shortcuts.
/// Rule 1: dropping unsaved work destroys it, so this is a confirmation the rules allow.
///
/// **Save is left out when it could write nothing** (`UnsavedPrompt.canSave`): dirty scratch tabs or
/// other projects' files in a scope not on screen. Rule 6 forbids jumping there to save them, so the
/// prompt lists them with Don't Save and Cancel only, and Return is then Cancel's.
struct UnsavedPromptBar: View {
    let message: String
    var canSave = true
    let resolve: (UnsavedChoice) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(EditorPaneStyle.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("editor.unsaved.message")
            Spacer(minLength: 0)
            if canSave {
                Button("Save") { resolve(.save) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EditorPaneStyle.text)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("editor.unsaved.save")
            }
            Button("Don't Save") { resolve(.dontSave) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.amber)
                .accessibilityIdentifier("editor.unsaved.dontSave")
            Button("Cancel") { resolve(.cancel) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.72))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor.unsaved.cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(EditorPaneStyle.slab, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorPaneStyle.text.opacity(0.14)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) {
            resolve(canSave ? .save : .cancel)
            return .handled
        }
        .onKeyPress(.escape) {
            resolve(.cancel)
            return .handled
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.unsaved")
    }
}

// MARK: - Treatment

/// Rule 5's load mark, the rail's busy treatment — see `GitBusyTick`.
struct EditorBusyTick: View {
    var label = "saving"
    var identifier = "editor.saving"

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(RailTreatment.workingTickColour))
            .frame(width: 2, height: 12)
            .shadow(color: Color(RailTreatment.workingTickColour).opacity(0.85), radius: 5)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

enum EditorPaneStyle {
    static let text = Color(RailTreatment.textColour)
    static let slab = Color(red: 0x0b / 255, green: 0x0d / 255, blue: 0x14 / 255)
    /// The artboard's active-tab tick, `#9e82ff`.
    static let tick = Color(red: 0x9e / 255, green: 0x82 / 255, blue: 0xff / 255)
    static let amber = Color(TerminalPalette.amber)
    /// §5's violet `#7c5cff`: the column's selected row and a search switch that is on.
    static let violet = Color(VoidPalette.violet)
}
