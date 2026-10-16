import AppKit
import Observation
import WakilKit
import SwiftUI
import WebKit

/// The git pane (3a-i): every root of the active project with its staged, changed and
/// untracked files; a click or Return folds the list into the **spine** — a 26 pt column of
/// status marks, or a 240 pt column of names when the pane is ≥ 900 pt wide — and fills the
/// pane with the file's Monaco diff.
///
/// **It decides nothing.** What it draws comes from `GitSnapshot` through the pure functions
/// in `WakilKit/Git/GitPaneLines.swift` and `DiffRenderer.swift`, which are tested; every
/// click and key dispatches the same `git_*` action the agent calls, so what the operator
/// did and what the agent did are one journal. The only state of its own is the keyboard
/// highlight in the unfolded list, the count of its own selects in flight, the row its latest
/// select is opening, and the diff host.
struct GitPane: View {
    let snapshot: GitSnapshot
    let pane: Pane
    /// One `git_*` action on THIS pane (Canvas folds `pane` in), awaited.
    let dispatch: (String, [String: JSONValue]) async -> Void
    let isKeyboardOwner: Bool
    let isFocusedPane: Bool
    let keyboardFocusRequests: Int
    /// `WindowModel.keyboardReturns`: the palette closed over this pane and hands it back.
    let keyboardReturns: Int
    /// The editor font size from the settings (3b-v); the diff reads at it.
    var fontSize: Int = 12

    /// Owned by the pane: made on first fold and kept while the pane lives (spec, "The
    /// Monaco host"), so unfolding and folding again does not reload Monaco.
    @State private var host = GitDiffHost()
    /// Where ↑↓ sit in the unfolded list before Return selects. Starts on the selection.
    @State private var highlight: GitSelection?
    /// This pane's own selects and steps still running — each opens a diff. `git_select`
    /// and `git_step` return only once that diff has landed, so the snapshot never shows it
    /// loading for the operator's own click or key; this is what lets the load mark show it
    /// (Rule 5).
    @State private var diffOpensInFlight = 0
    /// The row this pane's latest select is opening, until that select returns — what the
    /// unfolded list marks as loading (`gitListLoadingRow`, Rule 5).
    @State private var opening: GitSelection?
    @FocusState private var focused: Bool

    var body: some View {
        // D1: ONE container, not a `Group`. A `Group` hands every modifier below to
        // whichever branch is showing, so `.focusable()`/`.onKeyPress` sat on the list's
        // ScrollView, then on a brand-new HStack after a fold: each fold or unfold swapped the
        // focused view out from under `@FocusState`, and no key ever reached `handleKey`. A
        // `ZStack` keeps one focusable view for the pane's whole life, as `TerminalPane`'s
        // `VStack` does.
        ZStack(alignment: .topLeading) {
            if snapshot.folded { folded } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        // The system focus ring is a colour Wakil does not choose — see `TerminalPane`.
        .focusEffectDisabled()
        .onAppear { if isFocusedPane { focused = true } }
        .onChange(of: isFocusedPane) { _, now in if now { focused = true } }
        // The diff host's key handler is a closure over THIS value of the pane; re-handed on
        // every change of what it reads, so it never acts on a stale fold or ownership.
        .onChange(of: isKeyboardOwner) { _, _ in syncDiffKeys() }
        .onChange(of: fontSize) { _, n in host.renderer?.setFontSize(n) }
        .onChange(of: keyboardFocusRequests) { _, _ in if isFocusedPane { focused = true } }
        .onChange(of: keyboardReturns) { _, _ in if isFocusedPane { focused = true } }
        .onKeyPress(phases: .down, action: handleKey)
        .task(id: snapshot.folded) {
            guard snapshot.folded else { return }
            await host.start()
            host.renderer?.setFontSize(fontSize)
            syncDiffKeys()
            applyDiff()
        }
        .onChange(of: snapshot) { _, _ in
            syncDiffKeys()
            applyDiff()
        }
        .accessibilityIdentifier("git.pane")
    }

    // MARK: - The list (unfolded)

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if snapshot.roots.isEmpty {
                        Text("No project roots to read")
                            .font(.system(size: 12))
                            .foregroundStyle(GitPaneStyle.text.opacity(0.46))
                    }
                    ForEach(snapshot.roots, id: \.root) { root in
                        rootHeader(root)
                        ForEach(gitListSections(root), id: \.group) { section in
                            Text(gitGroupLabel(section.group))
                                .font(.system(size: 9, weight: .medium))
                                .tracking(1.7)
                                .foregroundStyle(GitPaneStyle.text.opacity(0.45))
                                .padding(.top, 6)
                                .padding(.leading, 6)
                            ForEach(section.rows, id: \.self) { row in
                                fileRow(row, root: root)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Rule 6: Esc unfolds with the same file selected and in view. The list is
            // built fresh on every unfold, so appearing is the moment to scroll.
            .onAppear {
                highlight = snapshot.selection
                if let selection = snapshot.selection {
                    proxy.scrollTo(selection, anchor: .center)
                } else if let root = snapshot.inView {
                    // Rule 6: the selected file's root lost its last file; that root in view.
                    proxy.scrollTo(root, anchor: .top)
                }
            }
            .onChange(of: highlight) { _, now in
                if let now { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(now) } }
            }
        }
    }

    @ViewBuilder
    private func rootHeader(_ root: GitRootState) -> some View {
        HStack(spacing: 6) {
            if root.loading { GitBusyTick() }
            Text(gitRootLine(root))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(GitPaneStyle.text.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.top, 10)
        .padding(.leading, root.loading ? 0 : 8)
        .id(root.root)
        .accessibilityIdentifier("git.root:\(root.name)")
        if let detail = gitRootErrorDetail(root) {
            // §8's data register: the error is read, so it is whole, opaque and legible.
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(GitPaneStyle.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 8)
                .accessibilityIdentifier("git.rootError:\(root.name)")
        }
    }

    private func fileRow(_ row: GitFileRow, root: GitRootState) -> some View {
        let selection = GitSelection(root: root.root, path: row.path, group: row.group)
        let isAnchor = selection == (highlight ?? snapshot.selection)
        let isLoading = gitListLoadingRow(snapshot, opening: opening) == selection
        return HStack(spacing: 0) {
            Text(row.status)
                .foregroundStyle(GitPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: 18, alignment: .leading)
            Text(gitRowLabel(row))
                .foregroundStyle(GitPaneStyle.text.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            if isLoading {
                Spacer(minLength: 6)
                GitBusyTick()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // §8: a lifted, opaque background, and the anchor's left edge the one luminous mark.
        .background(isAnchor ? GitPaneStyle.lifted : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            if isAnchor { Rectangle().fill(GitPaneStyle.violet).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { press(selection) }
        .id(selection)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git.row:\(root.name)/\(row.path):\(row.group.rawValue)")
        // D2: `onTapGesture` carries no accessibility action, so `AXPress` (VoiceOver, the
        // harness) reported success and did nothing. The default action is the same press.
        .accessibilityAction { press(selection) }
        // The action alone makes SwiftUI publish the row as a button, whose `?, notes` no
        // longer reads as the row's text (measured: 3a-i-git-list.jsonl went red on it).
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(isAnchor ? [.isStaticText, .isSelected] : .isStaticText)
    }

    // MARK: - Folded: the spine and the diff

    /// The spine, or at `gitNamesColumnMinPaneWidth` and wider the names column
    /// (`gitFoldedListStyle`). The GeometryReader reads only the width it is offered, which
    /// nothing inside it changes, so the choice cannot loop. The diff host sits at the same
    /// place in the HStack either way, and the web view is the host's, so switching never
    /// reloads Monaco.
    private var folded: some View {
        GeometryReader { geometry in
            foldedRow(gitFoldedListStyle(width: Double(geometry.size.width)))
        }
    }

    private func foldedRow(_ style: GitFoldedListStyle) -> some View {
        HStack(spacing: 0) {
            Group {
                switch style {
                case .spine: spine
                case .names: namesColumn
                }
            }
            .frame(width: CGFloat(style.width))
            Rectangle().fill(GitPaneStyle.separator).frame(width: 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if diffLoading { GitBusyTick() }
                    Text(gitDiffHeader(snapshot) ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(GitPaneStyle.text.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("git.diffHeader")
                }
                if let banner = snapshot.diff.flatMap(gitDiffBanner) {
                    Text(banner)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(GitPaneStyle.text.opacity(0.62))
                        .accessibilityIdentifier("git.diffBanner")
                }
                if let error = snapshot.diff?.error {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(GitPaneStyle.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("git.diffError")
                }
                GitDiffHostView(webView: host.renderer?.webView)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("git.diff")
            }
            .padding(.leading, 8)
        }
    }

    private var spine: some View {
        let marks = gitSpineMarks(snapshot.roots).filter { !$0.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { index, rootMarks in
                        if index > 0 {
                            Rectangle().fill(GitPaneStyle.markSeparator).frame(width: 12, height: 1)
                                .padding(.vertical, 3)
                        }
                        ForEach(rootMarks, id: \.self) { mark in spineMark(mark) }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
            }
            .onAppear { if let s = snapshot.selection { proxy.scrollTo(s, anchor: .center) } }
            .onChange(of: snapshot.selection) { _, now in if let now { proxy.scrollTo(now) } }
        }
    }

    private func spineMark(_ mark: GitSelection) -> some View {
        let row = gitFileRow(mark, in: snapshot.roots)
        let status = row?.status ?? ""
        let isSelected = mark == snapshot.selection
        // Hoisted so the identifier's interpolations are plain reads: the e2e
        // harvester reads `\(…)` up to the first `)`, and a cast inside one
        // made the family unmatchable by any concrete name.
        let rootName = (mark.root as NSString).lastPathComponent
        return RoundedRectangle(cornerRadius: 3)
            .fill(GitPaneStyle.tone(gitStatusTone(status)))
            .frame(width: 16, height: 16)
            .overlay {
                Text(status)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GitPaneStyle.slab)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(GitPaneStyle.violet, lineWidth: 2)
                        .padding(-3)
                }
            }
            .padding(3)
            .contentShape(Rectangle())
            .onTapGesture { press(mark) }
            .id(mark)
            .help(row.map(gitRowLabel) ?? mark.path)
            .accessibilityElement()
            .accessibilityLabel("\(status) \(mark.path)")
            .accessibilityIdentifier("git.mark:\(rootName)/\(mark.path):\(mark.group.rawValue)")
            // D2: see `fileRow` — the AX default action is the click.
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { press(mark) }
    }

    /// The wide pane's column (§11, Git): the unfolded list's roots, group labels and rows,
    /// narrowed to 240 pt — names truncate in the middle — with the selection outlined in
    /// violet as the spine outlines its mark. A row is the list row's press and identifier
    /// (`git.row:…`); the list and this column are never drawn together.
    private var namesColumn: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.roots, id: \.root) { root in
                        Text(gitRootLine(root))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(GitPaneStyle.text.opacity(0.62))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                        ForEach(gitListSections(root), id: \.group) { section in
                            Text(gitGroupLabel(section.group))
                                .font(.system(size: 9, weight: .medium))
                                .tracking(1.7)
                                .foregroundStyle(GitPaneStyle.text.opacity(0.45))
                                .padding(.top, 4)
                                .padding(.leading, 6)
                            ForEach(section.rows, id: \.self) { row in
                                nameRow(row, root: root)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let s = snapshot.selection { proxy.scrollTo(s, anchor: .center) } }
            .onChange(of: snapshot.selection) { _, now in if let now { proxy.scrollTo(now) } }
        }
    }

    private func nameRow(_ row: GitFileRow, root: GitRootState) -> some View {
        let selection = GitSelection(root: root.root, path: row.path, group: row.group)
        let isSelected = selection == snapshot.selection
        return HStack(spacing: 0) {
            Text(row.status)
                .foregroundStyle(GitPaneStyle.tone(gitStatusTone(row.status)))
                .frame(width: 16, alignment: .leading)
            Text(gitRowLabel(row))
                .foregroundStyle(GitPaneStyle.text.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4).stroke(GitPaneStyle.violet, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { press(selection) }
        .id(selection)
        .help(gitRowLabel(row))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git.row:\(root.name)/\(row.path):\(row.group.rawValue)")
        // D2: see `fileRow` — the AX default action is the click; the row stays text.
        .accessibilityAction { press(selection) }
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isStaticText, .isSelected] : .isStaticText)
    }

    private var diffLoading: Bool { snapshot.diff?.loading == true || diffOpensInFlight > 0 }

    // MARK: - Actions

    /// A click or an `AXPress` on a row or a spine mark: the pane takes the keyboard, the
    /// highlight moves there, and the file opens.
    private func press(_ s: GitSelection) {
        focused = true
        highlight = s
        select(s)
    }

    private func select(_ s: GitSelection) {
        opening = s
        run("git_select", ["root": .string(s.root), "path": .string(s.path), "group": .string(s.group.rawValue)]) {
            if opening == s { opening = nil }
        }
    }

    private func step(_ delta: Int) {
        run("git_step", ["delta": .integer(Int64(delta))])
    }

    private func run(_ name: String, _ params: [String: JSONValue], then done: @escaping () -> Void = {}) {
        diffOpensInFlight += 1
        Task {
            await dispatch(name, params)
            diffOpensInFlight -= 1
            done()
        }
    }

    private func unfold() {
        focused = true
        Task { await dispatch("git_unfold", [:]) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !gitPaneKeyIsChord(GitKeyModifiers(press.modifiers)) else { return .ignored }
        let key: GitPaneKey
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .escape: key = .escape
        case .return: key = .return
        default: return .ignored
        }
        return perform(key) ? .handled : .ignored
    }

    /// ↑↓ and Esc pressed while the diff itself has the keyboard (the page hands them over).
    private func handleMonacoKey(_ key: String) {
        switch key {
        case "up": _ = perform(.up)
        case "down": _ = perform(.down)
        case "escape": _ = perform(.escape)
        default: break
        }
    }

    /// Does what `gitPaneKeyAction` says, answering whether the key was the pane's.
    private func perform(_ key: GitPaneKey) -> Bool {
        guard let action = gitPaneKeyAction(key, folded: snapshot.folded, owner: isKeyboardOwner) else {
            return false
        }
        switch action {
        case .step(let delta):
            step(delta)
        case .unfold:
            unfold()
        case .moveHighlight(let delta):
            highlight = gitStep(snapshot.roots, from: highlight ?? snapshot.selection, by: delta)
        case .selectHighlight:
            guard let target = highlight ?? snapshot.selection else { return false }
            select(target)
        }
        return true
    }

    /// Hands the diff host a key handler over the pane as it is now, and lets the page take
    /// ↑↓/Esc from Monaco only while the pane can act on them.
    private func syncDiffKeys() {
        host.onKey = { key in handleMonacoKey(key) }
        host.captureKeys(gitDiffCapturesKeys(folded: snapshot.folded, owner: isKeyboardOwner))
    }

    private func applyDiff() {
        guard let renderer = host.renderer else { return }
        host.shown = gitApply(gitDiffUpdate(shown: host.shown, snapshot: snapshot), to: renderer, shown: host.shown)
    }
}

// MARK: - The diff host

/// The pane's one Monaco web view and what it last showed. A class held in `@State`, so it
/// lives exactly as long as the pane's view identity does.
@MainActor @Observable
final class GitDiffHost {
    private(set) var renderer: MonacoDiffRenderer?
    @ObservationIgnored var shown: GitDiffShown?
    @ObservationIgnored private var starting = false
    /// The pane's key handler, re-handed by the pane whenever what it reads changes.
    @ObservationIgnored var onKey: ((String) -> Void)?
    /// What the page was last told about taking keys; nil before the renderer exists.
    @ObservationIgnored private var capturing: Bool?

    /// The offline rule list, compiled once per launch and shared by every git pane.
    private static var networkBlock: WKContentRuleList?

    /// Makes the renderer the first time the pane folds; a no-op after.
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
            FileHandle.standardError.write(Data("monaco: no network block, no diff: \(error)\n".utf8))
            return
        }
        let made = MonacoDiffRenderer(blockNetwork: block)
        made.onLog = { line in FileHandle.standardError.write(Data("monaco: \(line)\n".utf8)) }
        made.onKey = { [weak self] key in self?.onKey?(key) }
        renderer = made
    }
}

extension GitDiffHost {
    /// Whether the page takes ↑↓/Esc from Monaco. Told only on a change.
    func captureKeys(_ on: Bool) {
        guard let renderer, capturing != on else { return }
        capturing = on
        renderer.captureKeys(on)
    }
}

/// Hosts the renderer's web view in a container the pane owns. The web view outlives this
/// view — unfolding removes it, folding again puts the same one back — so dismantling
/// detaches it and nothing more. The editor pane hosts its Monaco web views with it too.
struct GitDiffHostView: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(GitPaneStyle.slab).cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard let webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

// MARK: - Treatment

/// Rule 5's load mark, the rail's own busy treatment (`Rail.tick`): a 2 pt tick in §5's
/// green with its glow — no spinner (§9).
private struct GitBusyTick: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(RailTreatment.workingTickColour))
            .frame(width: 2, height: 12)
            .shadow(color: Color(RailTreatment.workingTickColour).opacity(0.85), radius: 5)
            .accessibilityLabel("loading")
            .accessibilityIdentifier("git.loading")
    }
}

private enum GitPaneStyle {
    static let text = Color(RailTreatment.textColour)
    static let slab = Color(red: 0x0b / 255, green: 0x0d / 255, blue: 0x14 / 255)
    static let lifted = Color(red: 0x1c / 255, green: 0x20 / 255, blue: 0x30 / 255)
    static let separator = Color(red: 0x16 / 255, green: 0x1a / 255, blue: 0x26 / 255)
    static let markSeparator = Color(red: 0x2a / 255, green: 0x2f / 255, blue: 0x40 / 255)
    /// §5's violet `#7c5cff`, the selected mark's outline and the anchor row's edge.
    static let violet = Color(VoidPalette.violet)

    /// §5: amber `#e8b45a` for a change, green `#8be0c8` for an addition, and a deletion
    /// muted — never red, which is production's and destruction's.
    static func tone(_ t: GitStatusTone) -> Color {
        switch t {
        case .modified: Color(TerminalPalette.amber)
        case .added: Color(TerminalPalette.green)
        case .muted: text.opacity(0.45)
        }
    }
}

private extension GitKeyModifiers {
    init(_ m: EventModifiers) {
        self = []
        if m.contains(.shift) { insert(.shift) }
        if m.contains(.control) { insert(.control) }
        if m.contains(.option) { insert(.option) }
        if m.contains(.command) { insert(.command) }
        if m.contains(.capsLock) { insert(.capsLock) }
        if m.contains(.numericPad) { insert(.numericPad) }
        if m.contains(.function) { insert(.function) }
    }
}
