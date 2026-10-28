import SwiftUI
import WakilKit

/// 3d-iv: the key in a login field, its list, and the save bar.
///
/// **Reads are direct calls; writes are actions** (ruling 10): the list reads the site's logins from
/// `BrowserPasswordStore` itself (attributes only, so it never asks for permission); filling,
/// suggesting, saving and *Never* are the operator-only `browser_password_*` actions, dispatched from
/// here and nowhere else — **no fill happens without a press on the key**.
///
/// **None takes the keyboard** (Rule 6): the key and the bar's buttons never become first responder,
/// and after a fill the page's field has it again (the script focuses it).

/// Over the active tab's page: the key at the focused field's right edge, inset 4 pt, 16 pt square, the
/// `key.fill` glyph, grey on a light chip so it reads on any page (ruling 11, 3d-iv walk). Pressing it opens the list.
struct BrowserPasswordKey: View {
    let host: BrowserTabHost
    let key: BrowserTabHost.Key
    let field: BrowserPasswordField
    /// The page's zoom: the field's CSS rect times it is its rect in the page area.
    let zoom: Double

    @State private var open = false

    var body: some View {
        GeometryReader { geometry in
            let f = BrowserPasswordKeyLayout.frame(field: field.rect, zoom: zoom)
            let frame = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
            // A field scrolled out of the page area keeps its report, not its key.
            let inside = CGRect(origin: .zero, size: geometry.size).contains(frame)
            Button { open = true } label: {
                // On a light chip with a grey glyph, so it reads on any page: Wakil's pale meta tone
                // vanished on a white field (3d-iv walk).
                Image(systemName: "key.fill")
                    .font(.system(size: BrowserPaneStyle.controlGlyph))
                    .foregroundStyle(Color(white: 0.38))
                    .frame(width: frame.width, height: frame.height)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.96)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Saved passwords for \(field.site)")
            .accessibilityLabel("Passwords")
            .accessibilityIdentifier("browser.password.key")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                BrowserPasswordList(host: host, key: key, field: field) { open = false }
            }
            .position(x: frame.midX, y: frame.midY)
            .opacity(inside ? 1 : 0)
            .allowsHitTesting(inside)
        }
        .onChange(of: open) { _, now in
            if now { host.passwordListOpened(key, origin: field.origin) } else { host.passwordListClosed(key) }
        }
        .onDisappear { host.passwordListClosed(key) }
    }
}

/// The key's list (ruling 12): a popover, not a menu, so it stays open while a fill runs (Rule 5) and
/// shows a Keychain error whole under the rows (Rule 8). Each saved login's username, or
/// `(no username)`; on a new-password field, `Suggest Strong Password`. It closes when a fill lands.
struct BrowserPasswordList: View {
    let host: BrowserTabHost
    let key: BrowserTabHost.Key
    let field: BrowserPasswordField
    let close: () -> Void

    @State private var logins: [BrowserLogin] = []
    @State private var error: String?
    /// The row whose dispatch runs (`-1`: the suggestion): every row is disabled until it ends.
    @State private var busy: Int?
    @State private var hovered: Int?

    private static let suggestRow = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if field.role != .new {
                ForEach(Array(logins.enumerated()), id: \.offset) { index, login in
                    row(login.username.isEmpty ? "(no username)" : login.username, index: index,
                        id: "browser.password.login.\(index)") { fill(login, index: index) }
                }
            } else {
                row("Suggest Strong Password", index: Self.suggestRow, id: "browser.password.suggest") { suggest() }
            }
            if let error {
                Text(error)
                    .font(.system(size: BrowserPaneStyle.metaSize))
                    .foregroundStyle(BrowserPaneStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("browser.password.error")
            }
        }
        .padding(4)
        .frame(width: 240, alignment: .leading)
        .task { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.password.list")
    }

    private func row(_ title: String, index: Int, id: String, _ action: @escaping () -> Void) -> some View {
        let running = busy == index
        return Button(action: action) {
            HStack(spacing: BrowserPaneStyle.gap) {
                Image(systemName: index == Self.suggestRow ? "key.horizontal" : "person.crop.circle")
                    .font(.system(size: BrowserPaneStyle.metaSize))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: SettingsScale.body))
                    .foregroundStyle(BrowserPaneStyle.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if running { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8)
            .frame(height: BrowserSuggestionList.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(BrowserPaneStyle.text.opacity(hovered == index && busy == nil ? RailTreatment.rowHoverTint : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(busy != nil)
        .opacity(busy != nil && !running ? BrowserPaneStyle.disabledOpacity : 1)
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// The site's logins in the place's organisation: a direct read (ruling 10), off the main actor.
    private func load() async {
        guard field.role != .new else { return }
        guard let store = host.passwordStore else {
            error = "No password store in this window."
            return
        }
        let org = key.scope.organization, site = field.site
        let result = await Task.detached { () -> Result<[BrowserLogin], Error> in
            Result { try store.logins(org: org, site: site) }
        }.value
        switch result {
        case .success(let found): logins = found
        case .failure(let failure): error = String(describing: failure)
        }
    }

    private func fill(_ login: BrowserLogin, index: Int) {
        run(index, "browser_password_fill", [
            "pane": .string(key.pane), "tab": .string(key.tab),
            "site": .string(login.site), "username": .string(login.username)])
    }

    private func suggest() {
        run(Self.suggestRow, "browser_password_suggest", ["pane": .string(key.pane), "tab": .string(key.tab)])
    }

    /// One dispatch at a time (Rule 5); on success the list closes, on a refusal it stays and says why.
    private func run(_ index: Int, _ action: String, _ params: [String: JSONValue]) {
        guard busy == nil, let model = host.model else { return }
        busy = index
        error = nil
        Task {
            do {
                try await model.dispatchFromSurfaceThrowing(action, .object(params))
                busy = nil
                close()
            } catch {
                busy = nil
                self.error = String(describing: error)
            }
        }
    }
}

/// A sent form's question at the pane's top, over the page and under the find bar (ruling 14):
/// `Save the password for <user> on <site>?` with **Save**, **Not Now**, **Never for This Site**, or
/// `Update the password for <user> on <site>?` with **Update** and **Not Now**. It never blocks the
/// page, asks nothing destructive (Rule 1: *Never* is undone in Settings), and each button clears it.
struct BrowserPasswordBar: View {
    let host: BrowserTabHost
    let key: BrowserTabHost.Key
    let offer: BrowserPasswordOfferState

    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: BrowserPaneStyle.gap) {
                Image(systemName: "key.fill")
                    .font(.system(size: BrowserPaneStyle.metaSize))
                    .foregroundStyle(BrowserPaneStyle.text.opacity(BrowserPaneStyle.metaOpacity))
                Text(offer.question)
                    .font(.system(size: BrowserPaneStyle.lineSize))
                    .foregroundStyle(BrowserPaneStyle.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(offer.question)
                    .accessibilityIdentifier("browser.password.bar.question")
                Spacer(minLength: BrowserPaneStyle.gap)
                if busy { ProgressView().controlSize(.mini) }
                buttons
            }
            if let error {
                Text(error)
                    .font(.system(size: BrowserPaneStyle.metaSize))
                    .foregroundStyle(BrowserPaneStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("browser.password.bar.error")
            }
        }
        .padding(.vertical, BrowserPaneStyle.rowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.password.bar")
        // Another sent form replaced the question: its own state starts clean.
        .id(offer.id)
    }

    @ViewBuilder private var buttons: some View {
        switch offer.offer {
        case .askUpdate:
            button("Update", "browser.password.bar.update", primary: true) { save() }
            button("Not Now", "browser.password.bar.notNow", primary: false) { notNow() }
        default:
            button("Save", "browser.password.bar.save", primary: true) { save() }
            button("Not Now", "browser.password.bar.notNow", primary: false) { notNow() }
            button("Never for This Site", "browser.password.bar.never", primary: false) { never() }
        }
    }

    private func button(_ title: String, _ id: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .browserLineButton(primary: primary)
            .focusable(false)
            .disabled(busy)
            .opacity(busy ? BrowserPaneStyle.disabledOpacity : 1)
            .fixedSize()
            .accessibilityIdentifier(id)
    }

    private func save() {
        run("browser_password_save", [
            "org": .string(offer.org), "site": .string(offer.site), "username": .string(offer.username),
            "password": .string(offer.password), "pane": .string(key.pane), "tab": .string(key.tab)])
    }

    /// Nothing is written: the question goes.
    private func notNow() {
        guard !busy else { return }
        host.passwordOfferAnswered(key, id: offer.id)
    }

    private func never() {
        run("browser_password_never", ["org": .string(offer.org), "site": .string(offer.site), "on": .bool(true)])
    }

    /// One answer at a time (Rule 5). A refusal stays on the bar, whole (Rule 8), and the bar with it.
    private func run(_ action: String, _ params: [String: JSONValue]) {
        guard !busy, let model = host.model else { return }
        busy = true
        error = nil
        let key = key, id = offer.id, host = host
        Task {
            do {
                try await model.dispatchFromSurfaceThrowing(action, .object(params))
                busy = false
                host.passwordOfferAnswered(key, id: id)
            } catch {
                busy = false
                self.error = String(describing: error)
            }
        }
    }
}
