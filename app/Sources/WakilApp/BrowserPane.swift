import AppKit
import SwiftUI
import WakilKit
import WebKit

/// The browser pane (3c-i): the tab strip, a header with ‹ › ↻ and the address field, and the
/// active tab's page.
///
/// **The pane holds no page state.** What it draws is the store's snapshot; every control is a
/// `browser_*` action (Invariant 2); the web views are the window's (`BrowserTabHost`), which applies
/// each tab's command and reports back through the seam. The page area is the one surface drawn as
/// the web draws it — not themed.
struct BrowserPane: View {
    let snapshot: BrowserSnapshot
    let pane: Pane
    /// The pane's width as drawn, which folds and hides the tab list.
    let width: Double
    /// The place this pane is in: its web views are filed under it (`BrowserTabHost`).
    let scope: LayoutScope
    let host: BrowserTabHost
    /// A `browser_*` action on this pane (`pane` already folded in).
    let dispatch: (String, [String: JSONValue]) async -> Void
    let isFocusedPane: Bool
    let isKeyboardOwner: Bool
    let keyboardHeld: () -> Bool
    /// `isFocusedPane && isKeyboardOwner && !keyboardHeld()` read from the window when asked — what a
    /// page focus run a turn later checks, rather than this view's values as it was built (Rule 6).
    let mayTakeKeyboard: @MainActor () -> Bool
    /// The pane's active tab as the window holds it now.
    let liveActiveTab: @MainActor () -> String?
    let keyboardFocusRequests: Int
    let keyboardReturns: Int
    /// Whether the pane has been closed (not merely taken off the canvas by a switch), asked a
    /// moment after it leaves the screen: a closed pane's web views are released.
    let isClosed: @MainActor () -> Bool
    /// Another pane is maximised in front of this one (3d-iii ruling 1): its active tab is not on
    /// screen, so a playing video there floats.
    let isCovered: Bool
    /// 3c-ii: the organisation's sites (the tags), the sites the on-screen conversation let the agent
    /// use (the mark), and the mark's ×.
    let sites: BrowserSites
    let agentAllowed: Set<String>
    let revokeSite: (String) -> Void
    /// 3c-iii: the drawn place's organisation's bookmarks (the ★ menu), the rows under the address
    /// field for what is typed (`search`, the engine's words, last), the engine's words, and a tab
    /// row chosen (`tab`, `url`).
    let bookmarks: [BrowserBookmark]
    let suggestions: (_ typed: String, _ search: [String]) async -> [BrowserSuggestion]
    let engineSuggestions: (_ typed: String) async -> [String]
    let chooseTab: (_ tab: String, _ url: String) async -> Void

    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool
    /// What the find field shows; each change is a `browser_find`.
    @State private var findDraft = ""
    /// The find field's sends, one after another, so a burst of keystrokes lands in typing order.
    @State private var findSends: Task<Void, Never>?
    /// What the address field holds while it is being edited: the whole URL as it opened, then what
    /// is typed.
    @State private var draft = ""
    /// Whether the address row is the editable field (`.fieldBox`) rather than the URL's line —
    /// from a click on the line, ⌘L, or a blank tab taking the keyboard, until the field lets go.
    @State private var editingAddress = false
    /// Raised when the pane takes the keyboard while its active tab's page is asking: the question
    /// takes it, not the page under it (`BrowserPromptCard`, Rule 6).
    @State private var promptFocusTurn = 0
    /// What was typed, the rows under the field, the highlight and the inline completion
    /// (rulings 8 and 9); `draft` is what it shows.
    @State private var input = BrowserAddressInput()
    /// While the field editor is being given a completion's text and selection: the selection it
    /// passes through on the way is not the caret leaving the end.
    @State private var placingCompletion = false

    private var active: BrowserTab? { snapshot.activeTab }
    private var listMode: BrowserTabListMode { BrowserTabListMode(paneWidth: width) }

    var body: some View {
        VStack(spacing: 0) {
            // Two 32 pt rows — the tab strip, then ‹ › ↻ and the address field — a hairline, and
            // the page edge to edge to the pane's border (the canvas pads no browser pane). The
            // find bar and the downloads take a row of their own, each across a hairline.
            tabStrip
            BrowserHeader(tab: active, dispatch: send) {
                addressField
                BrowserBookmarkMenu(
                    choices: BrowserBookmarkChoices(url: active?.url, bookmarks: bookmarks), dispatch: send)
                siteMarks
            }
            PaneHairline()
            if let find = snapshot.find {
                findBar(find)
                    .padding(.horizontal, BrowserPaneStyle.rowInset)
                    .frame(height: BrowserPaneStyle.rowHeight)
                PaneHairline()
            }
            pageArea
                .overlay(alignment: .top) { progressLine }
                // The page's bottom corners are the pane's, unless the downloads sit under it.
                .clipShape(UnevenRoundedRectangle(
                    bottomLeadingRadius: snapshot.downloads.isEmpty ? BrowserPaneStyle.paneRadius : 0,
                    bottomTrailingRadius: snapshot.downloads.isEmpty ? BrowserPaneStyle.paneRadius : 0,
                    style: .continuous))
            if !snapshot.downloads.isEmpty {
                PaneHairline()
                BrowserDownloadStrip(downloads: snapshot.downloads, dispatch: send)
                    .padding(.leading, BrowserPaneStyle.rowInset)
                    // Its × clear of the pane's resize handle, drawn over this corner.
                    .padding(.trailing, PaneStripStyle.resizeCorner)
                    .padding(.vertical, BrowserPaneStyle.rowPadding)
            }
        }
        // The rows under the address field, over the page: inside the pane, so the field keeps the
        // keyboard while they show (Rule 3).
        .overlayPreferenceValue(BrowserAddressAnchor.self) { anchor in
            GeometryReader { geometry in
                if editingAddress, !input.rows.isEmpty, let anchor {
                    let field = geometry[anchor]
                    BrowserSuggestionList(rows: input.rows, highlight: input.highlight, choose: choose)
                        .frame(width: field.width)
                        .offset(x: field.minX, y: field.maxY + 2)
                }
            }
        }
        .onAppear {
            sync(old: nil, now: snapshot)
            // What its web views said while this place was off screen was dropped (the seam's
            // place rule); they say it again now.
            host.reportAll(scope: scope, pane: pane.id)
            // A pane drawn again under its place's new name was on screen all along: the keyboard
            // stays where the operator had it (Rule 6).
            if !host.appearsRenamed(scope: scope, pane: pane.id), isFocusedPane { takeKeyboard() }
        }
        .onChange(of: snapshot) { old, now in sync(old: old, now: now) }
        // A data clear is done: commands held while the store went apply now.
        .onChange(of: host.rebuilds) { _, _ in sync(old: nil, now: snapshot) }
        .onChange(of: isFocusedPane) { _, now in
            if now { takeKeyboard() } else {
                addressFocused = false
                host.resignKeyboard(scope: scope, pane: pane.id)
            }
        }
        .onChange(of: keyboardFocusRequests) { _, _ in if isFocusedPane { takeKeyboard() } }
        .onChange(of: keyboardReturns) { _, _ in if isFocusedPane { takeKeyboard() } }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                // The whole URL selected, so typing replaces it (⌘L's promise), once the field's
                // editor holds the keyboard — and only if it is still this field's.
                selectAddress()
            } else {
                // Rule 2's stated exception: leaving without Return puts the address back — the
                // field goes, and the line shows the tab's URL; its rows go with it.
                editingAddress = false
                input = BrowserAddressInput()
            }
        }
        // Covered or uncovered by a maximised pane: the tab leaves the screen or comes back to it.
        .onChange(of: isCovered) { _, covered in
            if covered {
                host.pictureInPicture.hide(scope: scope, pane: pane.id, closing: false)
            } else {
                host.pictureInPicture.show(scope: scope, pane: pane.id, tab: snapshot.active)
            }
        }
        .onDisappear {
            let pane = pane.id, scope = scope, host = host, isClosed = isClosed
            // Read at once (ruling 2): a closed pane's tabs are released in a second, so none floats.
            host.pictureInPicture.hide(scope: scope, pane: pane, closing: isClosed())
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if isClosed() { host.release(scope: scope, pane: pane) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.pane")
    }

    // MARK: The tab strip

    /// The first row: the browser glyph (the pane's label, as its help and its accessibility
    /// name), then the tabs and their count; too narrow for the list, the ⌄ menu holds both.
    private var tabStrip: some View {
        PaneStripRow(glyph: "safari", name: "Browser") {
            if listMode != .hidden {
                BrowserTabList(
                    snapshot: snapshot, mode: listMode,
                    favicon: { host.favicons[BrowserTabHost.Key(scope: scope, pane: pane.id, tab: $0)] },
                    sites: sites, dispatch: send)
                BrowserTabCount(tabs: snapshot.tabs, listMode: listMode, dispatch: send)
                    .padding(.leading, BrowserPaneStyle.gap)
            } else {
                BrowserTabCount(tabs: snapshot.tabs, listMode: listMode, dispatch: send)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: The site's tag and the agent's allowance (3c-ii)

    /// At the address row's right, outside the field: the active tab's tag (ruling 4) and, while the
    /// on-screen conversation may act on its site, `agent allowed` with its ×. Fixed size, so the
    /// address field is what gives way in a narrow pane.
    @ViewBuilder private var siteMarks: some View {
        if let tab = active {
            if let tag = sites.tag(tab.url) { BrowserSiteTagChip(tag: tag) }
            if let site = BrowserSite.key(tab.url), agentAllowed.contains(site) {
                BrowserAgentAllowedMark(site: site) { revokeSite(site) }
            }
        }
    }

    // MARK: The address field

    /// The address field, always drawn as a field: rounded, the border token's 1 px edge, the
    /// padlock (or NOT SECURE) inside it at its left, and the tab's whole URL in mono. A click
    /// anywhere on it, or ⌘L, edits it with the whole URL selected; the edge takes the tick's
    /// colour while it is edited. The URL's line and the editor both carry `browser.address`.
    @ViewBuilder private var addressField: some View {
        HStack(spacing: BrowserPaneStyle.lockGap) {
            lock
            if editingAddress {
                TextField("Search or enter address", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: BrowserPaneStyle.addressSize, design: .monospaced))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.addressOpacity))
                    .focused($addressFocused)
                    .onSubmit { submit() }
                    // ↓ ↑ move through the rows (ruling 9); with none they keep their meaning.
                    .onKeyPress(.downArrow) { move(down: true) }
                    .onKeyPress(.upArrow) { move(down: false) }
                    .onChange(of: draft) { _, text in edited(text) }
                    .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) {
                        caretMoved($0)
                    }
                    // Local rows at once on each edit; the engine's 150 ms after the last keystroke,
                    // so a newer keystroke cancels an older ask (rulings 7 and 10).
                    .task(id: input.query) {
                        guard let typed = input.query else { return }
                        showRows(await suggestions(typed, []), for: typed)
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        let words = await engineSuggestions(typed)
                        guard !Task.isCancelled, !words.isEmpty else { return }
                        showRows(await suggestions(typed, words), for: typed)
                    }
                    .onExitCommand {
                        // Esc with rows showing hides them and puts back what was typed (ruling 9).
                        if input.escape() {
                            showInput()
                            return
                        }
                        // As a tab switch does (⌘1): the field lets the keyboard go to the window
                        // as this applies, so the page takes it a turn later — taken now, it
                        // would be taken straight back.
                        addressFocused = false
                        DispatchQueue.main.async { focusPage() }
                    }
                    // The field arrives to be typed in: it takes the keyboard once it is in the
                    // window — asked as it appears, SwiftUI drops the request.
                    // If the window drops the request (something else took the keyboard first),
                    // the field never had focus to lose: it goes back to the URL's line.
                    .onAppear {
                        DispatchQueue.main.async {
                            guard editingAddress else { return }
                            addressFocused = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if editingAddress, !addressFocused { editingAddress = false }
                            }
                        }
                    }
                    .accessibilityIdentifier("browser.address")
            } else {
                addressLine
            }
        }
        .padding(.horizontal, BrowserPaneStyle.fieldInsetX)
        .frame(maxWidth: .infinity, minHeight: BrowserPaneStyle.fieldHeight,
               maxHeight: BrowserPaneStyle.fieldHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BrowserPaneStyle.fieldRadius, style: .continuous)
                .fill(BrowserPaneStyle.text.opacity(BrowserPaneStyle.fieldFill)))
        .overlay(
            RoundedRectangle(cornerRadius: BrowserPaneStyle.fieldRadius, style: .continuous)
                .strokeBorder(
                    editingAddress ? BrowserPaneStyle.tick.opacity(BrowserPaneStyle.fieldEditingEdge)
                        : BrowserPaneStyle.text.opacity(BrowserPaneStyle.edge),
                    lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { beginEditingAddress() }
        .anchorPreference(key: BrowserAddressAnchor.self, value: .bounds) { $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.addressField")
    }

    /// The padlock, or the open lock and NOT SECURE, at the field's left: the page's host and how
    /// it came under the pointer — and, for a certificate the system did not trust, why
    /// (`BrowserAddress.lockDetail`). Nothing for a blank or `about:` page.
    @ViewBuilder private var lock: some View {
        if let tab = active, !tab.url.isEmpty, let url = URL(string: tab.url),
           let detail = BrowserAddress.lockDetail(url, certificate: certificateLine(tab, url)) {
            let secure = BrowserAddress.isSecure(url)
            HStack(spacing: BrowserPaneStyle.lockGap) {
                Image(systemName: secure ? "lock.fill" : "lock.open")
                    .font(.system(size: BrowserPaneStyle.lockSize))
                    .foregroundStyle(secure ? BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity) : BrowserPaneStyle.amber)
                if !secure { Text("NOT SECURE").browserMonoMicro(BrowserPaneStyle.amber) }
            }
            .fixedSize()
            .contentShape(Rectangle())
            .help(detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(secure ? "Secure" : "Not Secure")
            .accessibilityHint(detail)
            .accessibilityIdentifier("browser.lock")
        }
    }

    /// Why the tab's certificate was not trusted: the certificate page's own line while it is
    /// shown, or — once the operator chose Visit Anyway for this host — that choice.
    private func certificateLine(_ tab: BrowserTab, _ url: URL) -> String? {
        let key = BrowserTabHost.Key(scope: scope, pane: pane.id, tab: tab.id)
        if let text = host.certificates[key] { return text }
        guard url.scheme?.lowercased() == "https", let site = url.host?.lowercased(),
              host.certificateIsAllowed(org: scope.organization, host: site) else { return nil }
        return "\(site)'s certificate isn't trusted — you chose Visit Anyway for it until the window closes."
    }

    /// The URL as a line: what the field opens holding. A blank tab shows the field's placeholder.
    private var addressLine: some View {
        let url = lineText(active)
        return Button { beginEditingAddress() } label: {
            Text(url.isEmpty ? "Search or enter address" : url)
                .font(.system(size: BrowserPaneStyle.addressSize, design: .monospaced))
                .foregroundStyle(BrowserPaneStyle.text.opacity(
                    url.isEmpty ? BrowserPaneStyle.metaOpacity : BrowserPaneStyle.addressOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit the address (⌘L)")
        .accessibilityLabel("Address")
        .accessibilityValue(url)
        .accessibilityIdentifier("browser.address")
    }

    /// The line becomes the field, holding the tab's whole URL; the field takes the keyboard as it
    /// appears. Already the field, it takes the keyboard again.
    private func beginEditingAddress() {
        if editingAddress {
            if addressFocused { selectAddress() } else { addressFocused = true }
            return
        }
        let url = active?.url ?? ""
        input = BrowserAddressInput(url)
        draft = url
        editingAddress = true
    }

    /// Selects the address field's whole text, in that field's own editor: the window's first
    /// responder while this pane's field has focus. The editor is the field's a turn or two after
    /// focus moves, so this asks again briefly; anything else holding the keyboard by then is left
    /// alone.
    private func selectAddress(tries: Int = 10) {
        guard addressFocused else { return }
        guard let editor = addressEditor(), editor.string == draft else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { selectAddress(tries: tries - 1) }
            }
            return
        }
        editor.selectAll(nil)
    }

    /// The field editor of this pane's address field while it has the keyboard: the window's first
    /// responder, editing an `NSTextField`, while `addressFocused` says the field is this pane's.
    /// SwiftUI's `accessibilityIdentifier` never reaches the `NSTextField` itself (its own is
    /// empty), so the focus state is what names it; callers also match the editor's text.
    private func addressEditor() -> NSTextView? {
        guard addressFocused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.delegate is NSTextField
        else { return nil }
        return editor
    }

    // MARK: Rows and inline completion (rulings 7–9)

    /// The field's text changed: an edit of the operator's unless it is what `input` put there.
    private func edited(_ text: String) {
        let caretAtEnd = addressEditor().map { editor in
            let selection = editor.selectedRange()
            return selection.length == 0 && selection.location == (editor.string as NSString).length
        } ?? true
        let before = input
        input.fieldChanged(to: text, caretAtEnd: caretAtEnd)
        if input != before { showInput() }
    }

    private func showRows(_ rows: [BrowserSuggestion], for typed: String) {
        input.rowsArrived(rows, for: typed)
        showInput()
    }

    private func move(down: Bool) -> KeyPress.Result {
        guard input.move(down: down) else { return .ignored }
        showInput()
        return .handled
    }

    /// The field shows what `input` says; a completion is then selected in the field's editor, so
    /// the next keystroke replaces it (ruling 8). The editor takes the text a turn after `draft`
    /// changes, so the selection is asked again briefly.
    private func showInput() {
        let shown = input.shown
        guard draft != shown else { return }
        draft = shown
        guard let range = input.completionRange else { return }
        placingCompletion = true
        selectCompletion(range, shown: shown)
    }

    private func selectCompletion(_ range: NSRange, shown: String, tries: Int = 10) {
        guard input.shown == shown, input.completionRange == range else {
            placingCompletion = false
            return
        }
        guard let editor = addressEditor(), editor.string == shown else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    selectCompletion(range, shown: shown, tries: tries - 1)
                }
            } else {
                placingCompletion = false
            }
            return
        }
        editor.setSelectedRange(range)
        placingCompletion = false
    }

    /// The selection moved off the completion while it showed — left, or collapsed at the end: the
    /// completion is dropped, and what shows stays (ruling 8).
    private func caretMoved(_ note: Notification) {
        guard !placingCompletion, input.completionRange != nil, let editor = note.object as? NSTextView,
              editor === addressEditor() else { return }
        input.selectionChanged(editor.selectedRange(), in: editor.string)
    }

    /// A press on a row: the same as Return on it.
    private func choose(_ row: BrowserSuggestion) {
        guard !input.rows.isEmpty else { return }
        open(BrowserAddressInput.choice(row))
    }

    /// The tab's URL as the line shows it: whole, and nothing for a blank or `about:` page.
    private func lineText(_ tab: BrowserTab?) -> String {
        guard let tab, !tab.url.isEmpty, let url = URL(string: tab.url) else { return "" }
        if url.scheme?.lowercased() == "about" { return "" }
        return tab.url
    }

    /// Return: the highlighted row, else what the field shows — the typed text and any completion —
    /// to `browser_navigate`, which holds it to the address rule; the page takes the keyboard. A
    /// second Return replaces the load (Rule 5): it is one more command.
    private func submit() {
        open(input.highlight != nil ? input.choice : .navigate(draft))
    }

    /// A tab row selects that tab (in this pane, or brings its own pane forward); anything else is
    /// `browser_navigate`. The rows go, and the page takes the keyboard.
    private func open(_ choice: BrowserAddressInput.Choice) {
        input = BrowserAddressInput()
        addressFocused = false
        Task {
            switch choice {
            case .navigate(let text): await dispatch("browser_navigate", ["input": .string(text)])
            case .tab(let id, let url): await chooseTab(id, url)
            }
            focusPage()
        }
    }

    // MARK: The page

    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(BrowserPaneStyle.tick)
                .frame(width: geometry.size.width * CGFloat(max(0.05, min(1, active?.progress ?? 0))))
                .opacity(active?.isLoading == true ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: active?.progress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pageArea: some View {
        ZStack {
            if let tab = active {
                // `rebuilds` is read so a data clear that dropped this page draws a new one.
                let _ = host.rebuilds
                if let page = host.page(scope: scope, pane: pane.id, tab: tab) {
                    // `browser.page` is the web view's own identifier (`BrowserTabHost.prepare`),
                    // so a focus read and a frame read both resolve to the one element; the web
                    // view fills this host, so its frame is the page area's.
                    BrowserPageHost(webView: page) { [host] window in host.pictureInPicture.window = window }
                        .accessibilityElement(children: .contain)
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
                let key = BrowserTabHost.Key(scope: scope, pane: pane.id, tab: tab.id)
                if let certificate = host.certificates[key] {
                    BrowserCertificatePage(text: certificate) { host.visitAnyway(key: key) }
                } else if host.crashed.contains(key) {
                    BrowserCrashPage { send("browser_reload", ["tab": .string(tab.id)]) }
                } else if let failure = tab.failure {
                    BrowserLoadError(text: failure) { send("browser_reload", ["tab": .string(tab.id)]) }
                }
                // The page's own question, over this tab's page only; switching tabs keeps it.
                if let prompt = host.prompts[key]?.first {
                    BrowserPromptCard(
                        prompt: prompt, mayTakeKeyboard: mayTakeKeyboard,
                        mayTakeKeyboardOnArrival: { [scope, host] in
                            mayTakeKeyboard() && host.keyboardIsFreeFor(scope: scope, pane: pane.id)
                        },
                        focusTurn: promptFocusTurn) { answer in host.answer(prompt, answer, key: key) }
                        .id(prompt.id)
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: The find bar

    /// Above the page on ⌘F: the field, `2 of 3`, ↑ ↓ and ×. Each keystroke is a `browser_find`;
    /// Return and ⇧Return step; Esc closes it and gives the page the keyboard.
    private func findBar(_ find: BrowserFind) -> some View {
        HStack(spacing: BrowserPaneStyle.gap) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: BrowserPaneStyle.metaSize))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                TextField("Find in page", text: $findDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: BrowserPaneStyle.addressSize))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.addressOpacity))
                    .focused($findFocused)
                    .onSubmit {
                        let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                        sendInOrder("browser_find_step", ["forward": .bool(!back)])
                    }
                    .onExitCommand { closeFind() }
                    .onChange(of: findDraft) { _, typed in
                        if typed != snapshot.find?.query { sendInOrder("browser_find", ["query": .string(typed)]) }
                    }
                    .accessibilityIdentifier("browser.find.field")
            }
            .fieldBox(maxWidth: .infinity)
            Text(find.query.isEmpty ? "" : find.total == 0 ? "No matches" : "\(find.current) of \(find.total)")
                .font(.system(size: BrowserPaneStyle.metaSize, design: .monospaced))
                .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                .accessibilityIdentifier("browser.find.count")
            findButton("chevron.up", "browser.find.previous", "Previous Match", enabled: find.total > 0) {
                send("browser_find_step", ["forward": .bool(false)])
            }
            findButton("chevron.down", "browser.find.next", "Next Match", enabled: find.total > 0) {
                send("browser_find_step", ["forward": .bool(true)])
            }
            findButton("xmark", "browser.find.close", "Close Find", enabled: true) { closeFind() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.find")
    }

    private func findButton(_ symbol: String, _ id: String, _ label: String, enabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: BrowserPaneStyle.closeGlyph, weight: .semibold))
                .frame(width: BrowserPaneStyle.controlSize, height: BrowserPaneStyle.controlSize).contentShape(Rectangle())
        }
        .buttonStyle(ChangesIconButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : BrowserPaneStyle.disabledOpacity)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func sendInOrder(_ action: String, _ params: [String: JSONValue]) {
        let previous = findSends
        findSends = Task {
            await previous?.value
            await dispatch(action, params)
        }
    }

    private func closeFind() {
        findFocused = false
        let previous = findSends
        Task {
            await previous?.value
            await dispatch("browser_find_close", [:])
            focusPage()
        }
    }

    private func focusFind() {
        guard isFocusedPane, isKeyboardOwner, !keyboardHeld() else { return }
        findFocused = true
    }

    // MARK: Store → web views

    /// Applies every tab's new command, releases the web views of tabs that closed, and moves the
    /// keyboard when a tab arrives (Rule 3) or `.focusAddress` asks.
    private func sync(old: BrowserSnapshot?, now: BrowserSnapshot) {
        // A pane always has a tab (its last closing closes it), so an empty snapshot is one not read
        // yet, never a reason to drop every web view.
        if let old, !now.tabs.isEmpty {
            let kept = Set(now.tabs.map(\.id))
            for gone in old.tabs where !kept.contains(gone.id) { host.release(scope: scope, pane: pane.id, tab: gone.id) }
        }
        var wantsAddress = false
        for tab in now.tabs {
            guard let command = tab.command, host.apply(command, scope: scope, pane: pane.id, tab: tab) else { continue }
            if case .focusAddress = command.verb, tab.id == now.active { wantsAddress = true }
        }
        let switched = old != nil && old?.active != now.active
        // The tab leaving the front keeps its scroll and its last moves for a relaunch (I8).
        if switched, let left = old?.active { host.saveState(scope: scope, pane: pane.id, tab: left) }
        // An edit left in the field was the other tab's: the field holds this one's URL.
        if switched, editingAddress {
            let url = now.activeTab?.url ?? ""
            input = BrowserAddressInput(url)
            draft = url
        }
        // A new tab (⌘T, the agent's) takes the keyboard to its address field (Rule 3). Not one a
        // page opened, nor one ⌘⇧T brought back: those arrive with a page to read, as in Safari.
        if switched, let id = now.active, let old, !old.tabs.contains(where: { $0.id == id }),
           now.closed.count >= old.closed.count,
           !host.openedByPage.contains(BrowserTabHost.Key(scope: scope, pane: pane.id, tab: id)) {
            wantsAddress = true
        }
        if wantsAddress {
            focusAddress()
        } else if switched, isFocusedPane {
            // Another tab to the front: its page has the keyboard; an edit left in the address
            // field was the other tab's, and is put back. The field lets the keyboard go to the
            // window as this update applies, so the page takes it a turn later — taken now, it
            // would be taken straight back.
            addressFocused = false
            DispatchQueue.main.async { focusPage() }
        }
        syncFind(old: old, now: now)
        // `browser_download_cancel` asked: the host stops each, and reports it once WebKit has.
        host.cancelRequested(now.downloads, scope: scope, pane: pane.id)
        host.prune(now.downloads, scope: scope, pane: pane.id)
        // What the pane shows now: a tab that left floats, a floating tab that came back goes inline.
        if !isCovered { host.pictureInPicture.show(scope: scope, pane: pane.id, tab: now.active) }
    }

    /// The find bar's state to the active tab's page, and the keyboard: ⌘F (a `browser_find` —
    /// the store resets its count) puts it in the field; closing gives it back to the page.
    private func syncFind(old: BrowserSnapshot?, now: BrowserSnapshot) {
        host.applyFind(now.find, scope: scope, pane: pane.id, tab: now.active)
        guard let find = now.find else {
            if old?.find != nil, findFocused {
                findFocused = false
                focusPage()
            }
            return
        }
        if !findFocused, findDraft != find.query { findDraft = find.query }
        let asked = old?.find == nil || (old?.find?.seq != find.seq && find.current == 0 && find.total == 0)
        if asked, !findFocused { focusFind() }
    }

    // MARK: Keyboard

    /// The focused pane's keyboard: the address field on a blank tab, else the page.
    private func takeKeyboard() {
        // A click into the address field focused the pane; the field keeps what it was given.
        guard let tab = active, !addressFocused else { return }
        if tab.url.isEmpty { focusAddress() } else { focusPage() }
    }

    /// Whether the live active tab's page is asking a question: the keyboard is the question's.
    private func promptWaits() -> Bool {
        guard let tab = liveActiveTab() else { return false }
        return host.prompts[BrowserTabHost.Key(scope: scope, pane: pane.id, tab: tab)]?.isEmpty == false
    }

    private func focusAddress() {
        guard isFocusedPane, isKeyboardOwner, !keyboardHeld(), active != nil else { return }
        beginEditingAddress()
    }

    /// The page takes the keyboard — if, when this runs, the pane is still focused and nothing
    /// else holds the keyboard. Read live: this is often run a turn after it was asked.
    private func focusPage() {
        guard mayTakeKeyboard(), let tab = liveActiveTab() else { return }
        // A question over the page takes the keyboard rather than the page under it.
        if promptWaits() {
            promptFocusTurn += 1
            return
        }
        host.focusPage(scope: scope, pane: pane.id, tab: tab, mayTakeKeyboard: mayTakeKeyboard, activeTab: liveActiveTab)
    }

    private func send(_ action: String, _ params: [String: JSONValue]) {
        Task { await dispatch(action, params) }
    }
}

/// Puts the tab's web view in a container the pane owns. The web view outlives this view — a
/// SwiftUI rebuild removes it and puts the same one back — so dismantling detaches it and nothing
/// more (`GitDiffHostView`'s shape).
struct BrowserPageHost: NSViewRepresentable {
    let webView: WKWebView
    /// The window the container joined: picture in picture minimises with it and docks in it.
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = BrowserPageContainer()
        container.onWindow = onWindow
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        (container as? BrowserPageContainer)?.onWindow = onWindow
        attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        // A view docked for Restore is invisible (`BrowserPictureInPictureHost.dock`); taken, it shows.
        webView.alphaValue = 1
        container.addSubview(webView)
    }
}

/// `BrowserPageHost`'s container: says which window it joined, so picture in picture minimises with
/// that window and docks in it (3d-iii), with no pane reference.
final class BrowserPageContainer: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

/// A page that did not load, drawn whole over the page area (Rule 8) with Try Again: Wakil's own
/// error line (the API pane's, in caution amber) and a plain verb, on the slab.
struct BrowserLoadError: View {
    let text: String
    let tryAgain: () -> Void

    var body: some View {
        BrowserPageLine {
            Text(text)
                .browserErrorLine()
                .accessibilityIdentifier("browser.loadError")
            Button("Try Again", action: tryAgain)
                .browserLineButton(primary: true)
                .accessibilityIdentifier("browser.tryAgain")
        }
    }
}

/// What Wakil draws in the page's place — a load error, a stopped page, an untrusted certificate:
/// the slab, and its lines centred in it.
struct BrowserPageLine<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: BrowserPaneStyle.pageLineSpacing) { content() }
            .padding(BrowserPaneStyle.pageLinePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrowserPaneStyle.slab)
    }
}

extension Text {
    /// An error line in Wakil's voice, whole and selectable (Rule 8): the API pane's caution amber.
    func browserErrorLine() -> some View {
        font(.system(size: BrowserPaneStyle.lineSize))
            .foregroundStyle(BrowserPaneStyle.amber)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
