import Foundation

/// Errors the browser actions raise for reasons of their own. Each reads whole (Rule 8).
public enum BrowserActionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No pane was named and no browser pane is open (every action but `browser_open` and
    /// `browser_new_tab`, which open one).
    case noBrowserPane
    /// The address resolved to nothing: it was empty or only whitespace.
    case nothingToOpen
    /// A `javascript:` address would run script in the page, which no one is given through the
    /// address field (3c-ii forbids the agent script).
    case javascript
    case notABrowser(action: String, pane: String)
    case noTab(action: String, tab: String?)
    case nothingToReopen
    case findClosed
    case noDownload(id: String)
    case unknownZoomStep(String)
    case noOrganisation
    case clearOnlyFromTheApp
    /// `browser_clear_data`'s `org` — the organisation the operator's question named — is not the
    /// active one: the yes was for another organisation's data.
    case organisationChanged

    public var description: String {
        switch self {
        case .noBrowserPane: "No browser pane is open."
        case .nothingToOpen: "Type an address or words to search."
        case .javascript: "javascript: addresses don't run here — open the page and use Inspect Element."
        case .notABrowser(let action, let pane): "\(action): \(pane) is not a browser pane"
        case .noTab(let action, let tab):
            tab.map { "\(action): the browser pane has no tab \($0)" } ?? "\(action): the browser pane has no open tab"
        case .nothingToReopen: "browser_reopen_tab: no closed tab to reopen in this pane"
        case .findClosed: "browser_find_step: the find bar is closed; open it with browser_find (⌘F)"
        case .noDownload(let id): "browser_download_cancel: this pane has no download \(id)"
        case .unknownZoomStep(let step): "browser_zoom: step is in, out or reset, not \(step)"
        case .noOrganisation: "No organisation is active."
        case .clearOnlyFromTheApp: "Browsing data can only be cleared from the app."
        case .organisationChanged: "The organisation changed; ask again."
        }
    }
}

/// The zoom ladder (global constraints): `in` and `out` move one rung; reset is 1.0.
let browserZoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

/// The zoom one rung `in` (or `out`) from `zoom`; the end of the ladder stays where it is.
func browserZoom(_ zoom: Double, stepIn: Bool) -> Double {
    if stepIn { return browserZoomSteps.first { $0 > zoom + 0.0001 } ?? zoom }
    return browserZoomSteps.last { $0 < zoom - 0.0001 } ?? zoom
}

/// What a browser pane saves in the layout: each tab's id, URL and title, in order.
func browserSavedTabs(_ s: BrowserSnapshot) -> [BrowserSavedTab] {
    s.tabs.map { BrowserSavedTab(id: $0.id, url: $0.url, title: $0.title) }
}

/// The ⌘⇧T stack's depth.
let browserClosedLimit = 20

extension BrowserTab {
    /// Issues `verb` as the tab's next command. Seqs are per tab and only rise: `browserRestore`
    /// gives a restored tab seq 1, so each command after it is the tab's current seq + 1.
    mutating func issue(_ verb: BrowserCommand.Verb) {
        command = BrowserCommand(seq: (command?.seq ?? 0) + 1, verb: verb)
    }
}

extension BrowserSnapshot {
    /// A new tab id, `t<n>`.
    mutating func takeTabId() -> String {
        defer { nextTab += 1 }
        return "t\(nextTab)"
    }

    /// The index of tab `id`, else the active tab's.
    func tabIndex(_ id: String?) -> Int? {
        let wanted = id ?? active
        return tabs.firstIndex { $0.id == wanted }
    }

    /// Selects `i`, loading it if it has never fetched (a restored tab loads when shown).
    mutating func select(_ i: Int) {
        active = tabs[i].id
        let t = tabs[i]
        guard !t.loaded, !t.url.isEmpty else { return }
        if case .load? = t.command?.verb { return }   // its load is already waiting for the view
        tabs[i].issue(.load(t.url))
    }
}

/// Deletes an organisation's WebKit store by id (`browser_clear_data`), which only the app can. It
/// is handed `deleteFiles` — the organisation's tab states and zoom — to call once no web view on the
/// store is left to write one, and before the store goes.
public typealias BrowserDataRemover = @Sendable (_ store: UUID, _ deleteFiles: @Sendable () throws -> Void) async throws -> Void

/// Registers the browser pane's actions (3c-i).
///
/// **One path for the operator and the agent** (Invariant 2): the pane's header, its tab list and
/// the window's keys dispatch these. A tab's web view reports back through the seam
/// (`PaneStore.browserPageDidReport`), never through an action. Each answers the pane's
/// `read_pane` plus its `pane` id. `pane` defaults to the focused browser pane, else the most
/// recently opened one; `tab` to the active tab.
public func registerBrowserActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    settings: @escaping @Sendable () async -> SettingsBrowser,
    orgFiles: @escaping @Sendable () async throws -> BrowserOrgFiles? = { nil },
    removeData: BrowserDataRemover? = nil
) async {
    for action in browserActions(panes: panes, layout: layout, settings: settings, orgFiles: orgFiles,
                                 removeData: removeData) {
        await registry.register(action)
    }
}

/// The browser's actions, unregistered — `terminalActions`' shape, so `pane_open` can run
/// `browser_new_tab`'s handler for a new browser pane's first tab before the registry holds them.
func browserActions(
    panes: PaneStore,
    layout: LayoutStore?,
    settings: @escaping @Sendable () async -> SettingsBrowser,
    orgFiles: @escaping @Sendable () async throws -> BrowserOrgFiles? = { nil },
    removeData: BrowserDataRemover? = nil
) -> [Action] {
    var actions: [Action] = []
    let kind = BrowserPaneKind.names[0]

    /// The named pane, else the focused browser pane, else the last one opened. With none open,
    /// `open` opens one (`browser_open`, `browser_new_tab`); otherwise this refuses.
    @Sendable func browserPane(_ params: JSONValue, action: String, open: Bool = false) async throws -> (id: String, opened: Bool) {
        if let pane = optionalString(params, "pane"), !pane.isEmpty {
            try await requireOpenPane(pane, action: action, layout: layout)
            if let p = await layout?.snapshot().panes.first(where: { $0.id == pane }), p.kind != kind {
                throw BrowserActionError.notABrowser(action: action, pane: pane)
            }
            return (pane, false)
        }
        guard let layout else { throw StandardActionError.missingParam(action: action, param: "pane") }
        let snap = await layout.snapshot()
        let browsers = snap.panes.filter { $0.kind == kind }
        if let focused = snap.focusedId, browsers.contains(where: { $0.id == focused }) { return (focused, false) }
        if let last = browsers.last { return (last.id, false) }
        guard open else { throw BrowserActionError.noBrowserPane }
        return (await layout.open(kind: kind, title: Pane.defaultTitle(kind: kind)).id, true)
    }

    @Sendable func reply(_ pane: String) async -> JSONValue {
        guard case .object(var o) = await panes.readPane(paneId: pane, kind: kind) else { return .null }
        o["pane"] = .string(pane)
        return .object(o)
    }

    @Sendable func persist(_ pane: String) async {
        let s = await panes.browserSnapshot(paneId: pane)
        await layout?.setBrowserTabs(id: pane, to: browserSavedTabs(s), active: s.active)
    }

    /// `typed` by the address rule, refused when it resolves to nothing or to a `javascript:` URL.
    @Sendable func address(_ typed: String) async throws -> String {
        guard let url = BrowserAddress.resolve(typed, searchEngine: await settings().searchEngine) else {
            throw BrowserActionError.nothingToOpen
        }
        if url.scheme?.lowercased() == "javascript" { throw BrowserActionError.javascript }
        return url.absoluteString
    }

    /// A new tab at the end, made active: `url` loads; none opens the start page, and a blank start
    /// page loads nothing and puts the keyboard in the address field.
    @Sendable func addTab(_ pane: String, url: String?) async {
        var target = url
        if target == nil {
            let start = await settings().startPage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !start.isEmpty { target = start }
        }
        let load = target
        await panes.updateBrowser(paneId: pane, create: true) { s in
            var tab = BrowserTab(id: s.takeTabId(), url: load ?? "", title: "")
            if let load { tab.issue(.load(load)) } else { tab.issue(.focusAddress) }
            s.tabs.append(tab)
            s.active = tab.id
        }
    }

    /// Issues `verb` to the named or active tab; nil `verb` lets `make` decide from the tab.
    @Sendable func command(_ params: JSONValue, action: String,
                           _ make: @escaping @Sendable (BrowserTab) -> BrowserCommand.Verb?) async throws -> JSONValue {
        let pane = try await browserPane(params, action: action).id
        let tab = optionalString(params, "tab")
        let found = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
            guard let i = s.tabIndex(tab) else { return false }
            if let verb = make(s.tabs[i]) { s.tabs[i].issue(verb) }
            return true
        }
        guard found else { throw BrowserActionError.noTab(action: action, tab: tab) }
        return await reply(pane)
    }

    func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var props = properties
        props["pane"] = .object(["type": .string("string")])
        return .object(["type": .string("object"), "properties": .object(props),
                        "required": .array(required.map { .string($0) })])
    }
    let string: JSONValue = .object(["type": .string("string")])
    let tabSchema: [String: JSONValue] = ["tab": string]

    actions.append(Action(
        name: "browser_open",
        description: "Open url in the browser: a new tab (newTab, default true) in the focused or most "
            + "recently opened browser pane, or in the active tab with newTab false. Opens a browser "
            + "pane when none is open. url follows the address bar's rule: a host or URL loads, words search.",
        kind: .control, audience: .agentReachable,
        schema: schema(["url": string, "newTab": .object(["type": .string("boolean")])], required: ["url"]),
        handler: { params in
            let url = try await address(try requireString(params, "url", action: "browser_open"))
            let newTab: Bool = { if case .object(let o) = params, case .bool(let b)? = o["newTab"] { b } else { true } }()
            let pane = try await browserPane(params, action: "browser_open", open: true).id
            let loaded = newTab ? false : await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let i = s.tabIndex(nil) else { return false }
                s.tabs[i].url = url
                s.tabs[i].issue(.load(url))
                return true
            }
            if !loaded { await addTab(pane, url: url) }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_navigate",
        description: "Go to input in a tab (tab, default the active one), as typing it into the address "
            + "bar: a URL or host loads, anything else searches with the search engine in force.",
        kind: .control, audience: .agentReachable,
        schema: schema(["input": string, "tab": string], required: ["input"]),
        handler: { params in
            let url = try await address(try requireString(params, "input", action: "browser_navigate"))
            let pane = try await browserPane(params, action: "browser_navigate").id
            let tab = optionalString(params, "tab")
            let found = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let i = s.tabIndex(tab) else { return false }
                s.tabs[i].url = url
                s.tabs[i].issue(.load(url))
                return true
            }
            guard found else { throw BrowserActionError.noTab(action: "browser_navigate", tab: tab) }
            await persist(pane)
            return await reply(pane)
        }))

    for (name, words, verb) in [
        ("browser_back", "Go back one page in a tab (tab, default the active one).", BrowserCommand.Verb.back),
        ("browser_forward", "Go forward one page in a tab (tab, default the active one).", .forward),
        ("browser_stop", "Stop a tab's page loading (tab, default the active one).", .stop),
    ] {
        actions.append(Action(
            name: name, description: words, kind: .control, audience: .agentReachable,
            schema: schema(tabSchema),
            handler: { params in try await command(params, action: name) { _ in verb } }))
    }

    actions.append(Action(
        name: "browser_reload",
        description: "Reload a tab's page (tab, default the active one). A tab that has not loaded yet loads its address.",
        kind: .control, audience: .agentReachable,
        schema: schema(tabSchema),
        handler: { params in
            try await command(params, action: "browser_reload") { t in t.loaded || t.url.isEmpty ? .reload : .load(t.url) }
        }))

    actions.append(Action(
        name: "browser_focus_address",
        description: "Put the keyboard in a tab's address field (tab, default the active one), as ⌘L.",
        kind: .control, audience: .agentReachable,
        schema: schema(tabSchema),
        handler: { params in try await command(params, action: "browser_focus_address") { _ in .focusAddress } }))

    actions.append(Action(
        name: "browser_new_tab",
        description: "Open a new tab at the end of a browser pane's tabs and select it: url when given, "
            + "else (url left out) the start page; a blank start page leaves the address field focused. Opens a browser "
            + "pane when none is open.",
        kind: .control, audience: .agentReachable,
        schema: schema(["url": string]),
        handler: { params in
            var url: String?
            // A url given is held to the address rule, blank included; leave it out for the start page.
            if let typed = optionalString(params, "url") { url = try await address(typed) }
            let pane = try await browserPane(params, action: "browser_new_tab", open: true).id
            await addTab(pane, url: url)
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_close_tab",
        description: "Close a tab (tab, default the active one). The tab to its right is selected, else "
            + "the one to its left; closing the last tab closes the pane. browser_reopen_tab brings it back.",
        kind: .control, audience: .agentReachable,
        schema: schema(tabSchema),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_close_tab").id
            let tab = optionalString(params, "tab")
            let left = await panes.updateBrowser(paneId: pane, create: true) { s -> Int? in
                guard let i = s.tabIndex(tab) else { return nil }
                let gone = s.tabs.remove(at: i)
                s.closed.append(BrowserSavedTab(id: gone.id, url: gone.url, title: gone.title))
                if s.closed.count > browserClosedLimit { s.closed.removeFirst(s.closed.count - browserClosedLimit) }
                if s.active == gone.id {
                    s.active = nil
                    if !s.tabs.isEmpty { s.select(min(i, s.tabs.count - 1)) }
                }
                return s.tabs.count
            }
            guard let left else { throw BrowserActionError.noTab(action: "browser_close_tab", tab: tab) }
            if left == 0 {
                try await layout?.close(id: pane)
                await panes.drop(paneId: pane)
                return .object(["pane": .string(pane), "closed": .bool(true)])
            }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_reopen_tab",
        description: "Reopen the tab closed most recently in a browser pane, at the end of its tabs, and select it.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_reopen_tab").id
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let saved = s.closed.popLast() else { return false }
                var tab = BrowserTab(id: s.takeTabId(), url: saved.url, title: saved.title)
                if saved.url.isEmpty { tab.issue(.focusAddress) } else { tab.issue(.load(saved.url)) }
                s.tabs.append(tab)
                s.active = tab.id
                return true
            }
            guard ok else { throw BrowserActionError.nothingToReopen }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_select_tab",
        description: "Select a tab, by id (tab) or by position (index, 0 first, -1 the last). A tab that "
            + "has not loaded yet loads when selected.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "index": .object(["type": .string("integer")])]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_select_tab").id
            let tab = optionalString(params, "tab")
            let index: Int? = { if case .object(let o) = params { o["index"]?.intValue } else { nil } }()
            guard tab != nil || index != nil else {
                throw StandardActionError.missingParam(action: "browser_select_tab", param: "tab")
            }
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                var i: Int?
                if let tab { i = s.tabs.firstIndex { $0.id == tab } }
                else if let index { i = index < 0 ? s.tabs.count + index : index }
                guard let i, s.tabs.indices.contains(i) else { return false }
                s.select(i)
                return true
            }
            guard ok else { throw BrowserActionError.noTab(action: "browser_select_tab", tab: tab ?? index.map { "at \($0)" }) }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_move_tab",
        description: "Move a tab to position to (0 first; past the end is the end).",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "to": .object(["type": .string("integer")])], required: ["tab", "to"]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_move_tab").id
            let tab = try requireString(params, "tab", action: "browser_move_tab")
            guard case .object(let o) = params, let to = o["to"]?.intValue else {
                throw StandardActionError.missingParam(action: "browser_move_tab", param: "to")
            }
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else { return false }
                let moved = s.tabs.remove(at: i)
                s.tabs.insert(moved, at: max(0, min(to, s.tabs.count)))
                return true
            }
            guard ok else { throw BrowserActionError.noTab(action: "browser_move_tab", tab: tab) }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_find",
        description: "Open the find bar on the active tab's page and look for query (empty opens the bar "
            + "with nothing to find). read_pane's find answers the match count.",
        kind: .control, audience: .agentReachable,
        schema: schema(["query": string], required: ["query"]),
        handler: { params in
            let query = try requireString(params, "query", action: "browser_find")
            let pane = try await browserPane(params, action: "browser_find").id
            await panes.updateBrowser(paneId: pane, create: true) { s in
                s.find = BrowserFind(query: query, current: 0, total: 0, seq: (s.find?.seq ?? 0) + 1, forward: true)
            }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_find_step",
        description: "Move to the next match of the find bar's query (forward true, the default) or the previous one.",
        kind: .control, audience: .agentReachable,
        schema: schema(["forward": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_find_step").id
            let forward: Bool = { if case .object(let o) = params, case .bool(let b)? = o["forward"] { b } else { true } }()
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard s.find != nil else { return false }
                s.find?.seq += 1
                s.find?.forward = forward
                return true
            }
            guard ok else { throw BrowserActionError.findClosed }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_find_close",
        description: "Close the find bar.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_find_close").id
            await panes.updateBrowser(paneId: pane, create: true) { s in s.find = nil }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_zoom",
        description: "Zoom the active tab's page one step in or out, or reset it to 100%. Steps: "
            + browserZoomSteps.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: ", ") + ".",
        kind: .control, audience: .agentReachable,
        schema: schema(["step": .object(["type": .string("string"),
                                         "enum": .array([.string("in"), .string("out"), .string("reset")])])],
                       required: ["step"]),
        handler: { params in
            let step = try requireString(params, "step", action: "browser_zoom")
            guard ["in", "out", "reset"].contains(step) else { throw BrowserActionError.unknownZoomStep(step) }
            let pane = try await browserPane(params, action: "browser_zoom").id
            let zoomed = await panes.updateBrowser(paneId: pane, create: true) { s -> (factor: Double, url: String)? in
                guard let i = s.tabIndex(nil) else { return nil }
                let before = s.tabs[i].zoom
                let after = step == "reset" ? 1.0 : browserZoom(before, stepIn: step == "in")
                if after != before {
                    s.tabs[i].zoom = after
                    s.tabs[i].issue(.zoom(after))
                }
                return (after, s.tabs[i].url)
            }
            guard let zoomed else { throw BrowserActionError.noTab(action: "browser_zoom", tab: nil) }
            // Kept per host (zoom.json) here, not by the web view: a tab with no live view, or the
            // agent's zoom, is remembered the same (Invariant 2). A blank tab has no host to keep.
            if let site = URL(string: zoomed.url).flatMap(BrowserOrgFiles.zoomHost(of:)),
               let files = try await orgFiles() {
                try files.setZoom(zoomed.factor, host: site)
            }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_download_cancel",
        description: "Ask a running download to stop (download, its id in read_pane's downloads); its state "
            + "reads cancelled once the page has stopped it. One that already ended is left as it is.",
        kind: .control, audience: .agentReachable,
        schema: schema(["download": string], required: ["download"]),
        handler: { params in
            let id = try requireString(params, "download", action: "browser_download_cancel")
            let pane = try await browserPane(params, action: "browser_download_cancel").id
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let i = s.downloads.firstIndex(where: { $0.id == id }) else { return false }
                if s.downloads[i].state == .running { s.downloads[i].cancelRequested = true }
                return true
            }
            guard ok else { throw BrowserActionError.noDownload(id: id) }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_downloads_clear",
        description: "Clear the downloads that have ended from the pane's download strip; running ones stay. "
            + "The files stay where they were saved.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_downloads_clear").id
            await panes.updateBrowser(paneId: pane, create: true) { s in s.downloads.removeAll { $0.state != .running } }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_restore",
        description: "Reopen a browser pane's saved tabs after a relaunch. Only the selected tab loads; "
            + "the rest load when selected.",
        kind: .control, audience: .operatorOnly,
        schema: schema([:], required: ["pane"]),
        handler: { params in
            let pane = try requireString(params, "pane", action: "browser_restore")
            _ = try await browserPane(params, action: "browser_restore")
            if let saved = await layout?.browserTabs(id: pane), !saved.tabs.isEmpty {
                await panes.browserRestore(paneId: pane, tabs: saved.tabs, active: saved.active)
            }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_clear_data",
        description: "Delete the active organisation's browsing data: every site's cookies, logins and storage, "
            + "in every project, and the saved zoom. `org` is the organisation the operator was asked "
            + "about; refused when it is no longer the active one. Asks the operator first. Operator-only.",
        kind: .mutate, audience: .operatorOnly,
        schema: schema(["org": string], required: ["org"]),
        handler: { params in
            guard let removeData else { throw BrowserActionError.clearOnlyFromTheApp }
            guard let files = try await orgFiles() else { throw BrowserActionError.noOrganisation }
            // The question named an organisation; a switch between the question and the yes must
            // not turn that yes into another organisation's deletion.
            guard case .object(let o) = params, case .string(let asked)? = o["org"], asked == files.org else {
                throw BrowserActionError.organisationChanged
            }
            let id = try files.identifier()
            // The window drops the store's web views, then deletes the files, then removes the
            // store: no page left alive can write a tab state after the deletion. Deleted only
            // there — a second deletion after the remover could take a rebuilt page's new state.
            try await removeData(id) { try files.removeEverythingButTheProfile() }
            return .object(["cleared": .string(files.org)])
        },
        // Signs out of every site in every project, in production and out of it.
        price: (production: .gate, otherwise: .gate)))
    return actions
}

/// The browser settings the actions read. The window refreshes it (`WindowModel.refreshBrowserSettings`)
/// at launch and after every save, so a new tab or a search reads memory, not a `ctx_browser_settings`
/// dispatch with its journal line. Empty until the first refresh; `value(orRead:)` then reads once and keeps it.
public final class BrowserSettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SettingsBrowser?
    public init() {}
    public var current: SettingsBrowser? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func value(orRead read: @Sendable () async -> SettingsBrowser?) async -> SettingsBrowser {
        if let current { return current }
        guard let read = await read() else { return .defaults }
        current = read
        return read
    }
}

/// `ctx_browser_settings`' reply, or nil when it is not one (`decodeEditorSettings`' twin).
public func decodeBrowserSettings(fromResult result: JSONValue?) -> SettingsBrowser? {
    guard case .object(let object)? = result, let structured = object["structuredContent"],
          let data = try? JSONEncoder().encode(structured) else { return nil }
    return try? JSONDecoder().decode(SettingsBrowser.self, from: data)
}

/// The keys a focused browser pane takes over (global constraints); `WindowModel.browserKey` acts
/// on them. Elsewhere each keeps today's meaning.
public enum BrowserKey: Sendable, Equatable {
    case newTab, closeTab, reopenTab, focusAddress, reload, back, forward, find, findNext, findPrevious
    case zoomIn, zoomOut, zoomReset, nextTab, previousTab
    /// ⌘1–8 tab N; ⌘9 the last tab.
    case tab(Int)
}
