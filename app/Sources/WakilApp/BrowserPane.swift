import AppKit
import SwiftUI
import WakilKit
import WebKit

/// The browser pane (3c-i): a header with ‹ › ↻ and the address field, the vertical tab list, and
/// the active tab's page.
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
    let keyboardFocusRequests: Int
    let keyboardReturns: Int
    /// Whether the pane has been closed (not merely taken off the canvas by a switch), asked a
    /// moment after it leaves the screen: a closed pane's web views are released.
    let isClosed: @MainActor () -> Bool

    @FocusState private var addressFocused: Bool
    /// What the address field shows: the host while it is not focused, the whole URL — or what is
    /// being typed — while it is.
    @State private var draft = ""

    private var active: BrowserTab? { snapshot.activeTab }
    private var listMode: BrowserTabListMode { BrowserTabListMode(paneWidth: width) }

    var body: some View {
        VStack(spacing: 0) {
            BrowserHeader(tab: active, tabs: snapshot.tabs, listMode: listMode, dispatch: send) { addressField }
            progressLine
            HStack(spacing: 0) {
                if listMode != .hidden {
                    BrowserTabList(
                        snapshot: snapshot, mode: listMode,
                        favicon: { host.favicons[BrowserTabHost.Key(scope: scope, pane: pane.id, tab: $0)] },
                        dispatch: send)
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                }
                pageArea
            }
        }
        .onAppear {
            draft = unfocusedText(active)
            sync(old: nil, now: snapshot)
            // What its web views said while this place was off screen was dropped (the seam's
            // place rule); they say it again now.
            host.reportAll(scope: scope, pane: pane.id)
            if isFocusedPane { takeKeyboard() }
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
                draft = active?.url ?? ""
                // The whole URL selected, so typing replaces it (⌘L's promise). Next turn, once the
                // field's editor holds the keyboard — and only if it is still this field's.
                DispatchQueue.main.async { selectAddress() }
            } else {
                // Rule 2's stated exception: leaving without Return puts the address back.
                draft = unfocusedText(active)
            }
        }
        .onDisappear {
            let pane = pane.id, scope = scope, host = host, isClosed = isClosed
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if isClosed() { host.release(scope: scope, pane: pane) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.pane")
    }

    // MARK: The address field

    private var addressField: some View {
        HStack(spacing: 5) {
            if !addressFocused, let url = active.flatMap({ URL(string: $0.url) }), !(active?.url.isEmpty ?? true),
               url.scheme?.lowercased() != "about" {
                let secure = BrowserAddress.isSecure(url)
                Image(systemName: secure ? "lock.fill" : "lock.open")
                    .font(.system(size: 9))
                    .foregroundStyle(EditorPaneStyle.text.opacity(secure ? 0.55 : 0.8))
                    .accessibilityLabel(secure ? "Secure" : "Not Secure")
                if !secure {
                    Text("Not Secure")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorPaneStyle.amber)
                }
            }
            TextField("Search or enter address", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.9))
                .focused($addressFocused)
                .onSubmit { submit() }
                .onExitCommand {
                    addressFocused = false
                    focusPage()
                }
                .accessibilityIdentifier("browser.address")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(addressFocused ? 0.09 : 0.05)))
        .frame(maxWidth: .infinity)
    }

    /// Selects the address field's whole text, in that field's own editor: the window's first
    /// responder when it is the field editor of an `NSTextField` named `browser.address` and this
    /// pane's field still has focus. Anything else holding the keyboard by then is left alone.
    private func selectAddress() {
        guard addressFocused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField, field.accessibilityIdentifier() == "browser.address"
        else { return }
        editor.selectAll(nil)
    }

    private func unfocusedText(_ tab: BrowserTab?) -> String {
        guard let tab, !tab.url.isEmpty, let url = URL(string: tab.url) else { return "" }
        if url.scheme?.lowercased() == "about" { return "" }
        return BrowserAddress.displayHost(url)
    }

    /// Return: the typed text goes to `browser_navigate`, which holds it to the address rule, and the
    /// page takes the keyboard. A second Return replaces the load (Rule 5): it is one more command.
    private func submit() {
        let typed = draft
        addressFocused = false
        Task {
            await dispatch("browser_navigate", ["input": .string(typed)])
            focusPage()
        }
    }

    // MARK: The page

    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(EditorPaneStyle.tick)
                .frame(width: geometry.size.width * CGFloat(max(0.05, min(1, active?.progress ?? 0))))
                .opacity(active?.isLoading == true ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: active?.progress)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pageArea: some View {
        ZStack {
            if let tab = active {
                // `rebuilds` is read so a data clear that dropped this page draws a new one.
                let _ = host.rebuilds
                if let page = host.page(scope: scope, pane: pane.id, tab: tab) {
                    BrowserPageHost(webView: page)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("browser.page")
                } else {
                    Color(nsColor: .textBackgroundColor)
                }
                if let failure = tab.failure {
                    BrowserLoadError(text: failure) { send("browser_reload", ["tab": .string(tab.id)]) }
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
            // field was the other tab's, and is put back.
            addressFocused = false
            focusPage()
        }
        if !addressFocused { draft = unfocusedText(now.activeTab) }
    }

    // MARK: Keyboard

    /// The focused pane's keyboard: the address field on a blank tab, else the page.
    private func takeKeyboard() {
        // A click into the address field focused the pane; the field keeps what it was given.
        guard let tab = active, !addressFocused else { return }
        if tab.url.isEmpty { focusAddress() } else { focusPage() }
    }

    private func focusAddress() {
        guard isFocusedPane, isKeyboardOwner, !keyboardHeld(), active != nil else { return }
        addressFocused = true
    }

    private func focusPage() {
        guard isFocusedPane, isKeyboardOwner, !keyboardHeld(), let tab = active else { return }
        host.focusPage(scope: scope, pane: pane.id, tab: tab.id)
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

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// A page that did not load, drawn whole over the page area (Rule 8) with Try Again.
struct BrowserLoadError: View {
    let text: String
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(EditorPaneStyle.text.opacity(0.85))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityIdentifier("browser.loadError")
            Button("Try Again", action: tryAgain)
                .accessibilityIdentifier("browser.tryAgain")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EditorPaneStyle.slab)
    }
}
