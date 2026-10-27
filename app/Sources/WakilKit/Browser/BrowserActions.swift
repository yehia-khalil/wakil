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
    /// `browser_open` was handed an app's link (`zoommtg:`, `mailto:`): it opens web pages and files
    /// only, so no app on the Mac is launched from an action (final review I4).
    case notAWebPage(scheme: String)
    /// `browser_bookmark` was asked for a page that is not http, https or file.
    case notBookmarkable(scheme: String)
    case bookmarksUnreadable(String)
    /// 3d-i: the group named is not in the pane.
    case noGroup(action: String, group: String)
    /// 3d-i: the pull-request group is the read's; only collapse and expand change it. The word is
    /// the participle: `renamed`, `recoloured`, `ungrouped`, `closed`.
    case pullRequestGroupRefuses(String)
    case unknownColour
    case unknownGroupAction(String)
    /// 3d-i: pins are per project, and the place on screen has none.
    case noProject(action: String)
    /// 3d-i: `pins/<project>.json` is there but can't be read; it is never written over (ruling 13).
    case pinsUnreadable(action: String, file: String, reason: String)

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
        case .notBookmarkable(let scheme): "browser_bookmark: only a web page can be bookmarked, not \(scheme):"
        case .bookmarksUnreadable(let error):
            "browser_bookmark: bookmarks.json can't be read (\(error)) — fix or move it; Wakil won't write over it."
        case .noGroup(let action, let group): "\(action): this pane has no group \(group)"
        case .pullRequestGroupRefuses(let word): "browser_group: the pull-request group can't be \(word)"
        case .unknownColour:
            "browser_group: colour is one of " + BrowserGroupColour.allCases.map(\.rawValue).joined(separator: ", ")
        case .unknownGroupAction(let verb):
            "browser_group: action is create, rename, recolour, collapse, expand, ungroup or close, not \(verb)"
        case .noProject(let action): "\(action): no project is active"
        case .pinsUnreadable(let action, let file, let reason):
            "\(action): \(file) can't be read (\(reason)) — fix or move it; Wakil won't write over it."
        case .notAWebPage(let scheme):
            "browser_open opens web pages and files (http, https, file), not \(scheme): links — an app's "
                + "link opens from a page, after the operator allows it."
        }
    }
}

private func optionalBool(_ params: JSONValue, _ key: String) -> Bool? {
    guard case .object(let o) = params, case .bool(let b)? = o[key] else { return nil }
    return b
}

/// The zoom ladder (global constraints): `in` and `out` move one rung; reset is 1.0.
let browserZoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

/// The zoom one rung `in` (or `out`) from `zoom`; the end of the ladder stays where it is.
func browserZoom(_ zoom: Double, stepIn: Bool) -> Double {
    if stepIn { return browserZoomSteps.first { $0 > zoom + 0.0001 } ?? zoom }
    return browserZoomSteps.last { $0 < zoom - 0.0001 } ?? zoom
}

/// What a browser pane saves in the layout as its tabs: each tab's id, URL, title, group, opener, pin
/// and `keptLoose`, in order. A pull-request tab is skipped (ruling 18): the next refresh lists it
/// again. Its group is saved with the rest of `groups`, without tabs, so its `collapsed` is kept.
func browserSavedTabs(_ s: BrowserSnapshot) -> [BrowserSavedTab] {
    s.tabs.filter { $0.pullRequest == nil }.map {
        BrowserSavedTab(id: $0.id, url: $0.url, title: $0.title, group: $0.group, opener: $0.opener,
                        pin: $0.pin, keptLoose: $0.keptLoose)
    }
}

/// What `browser_pin` and `browser_unpin` act on: a tab or a group, by id.
private enum BrowserPinTarget: Sendable {
    case tab(String), group(String)
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

    /// Closes the tabs `ids` names (`browser_close_tab`, `browser_group`'s close): each goes on the
    /// ⌘⇧T stack with its group (ruling 22), and when the selection was among them the tab now where
    /// the first of them was is selected, else the last. Ends in `arrange()`. Answers how many closed.
    @discardableResult
    mutating func closeTabs(_ ids: Set<String>) -> Int {
        guard tabs.contains(where: { ids.contains($0.id) }) else { return 0 }
        let gone = tabs.filter { ids.contains($0.id) }
        for tab in gone {
            closed.append(BrowserSavedTab(id: tab.id, url: tab.url, title: tab.title, group: tab.group))
        }
        if closed.count > browserClosedLimit { closed.removeFirst(closed.count - browserClosedLimit) }
        removeTabs(ids)
        arrange()
        return gone.count
    }

    /// The opener rule (ruling 8) for a tab whose address may not be known yet: a pop-up made by
    /// `window.open()` is `about:blank` (or empty) until it loads. Such a tab still joins a grouped
    /// opener, but never starts a chain group with a loose one — its site is unknown, not another —
    /// and waits for the site rule.
    mutating func placeOpenedKnowingTheSite(tab: String, opener: String) {
        guard let t = tabs.firstIndex(where: { $0.id == tab }) else { return arrange() }
        let url = tabs[t].url.lowercased()
        let unknown = url.isEmpty || url.hasPrefix("about:")
        if unknown, tabs.first(where: { $0.id == opener })?.group == nil {
            tabs[t].opener = nil
            return arrange()
        }
        placeOpened(tab: tab, opener: opener)
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
/// is handed `deleteFiles` — the organisation's tab states, zoom and history (its bookmarks stay) —
/// to call once the store is gone (`browserRemoveStoreThenFiles`), with no web view left on it to
/// write one.
public typealias BrowserDataRemover = @Sendable (_ store: UUID, _ deleteFiles: @Sendable () throws -> Void) async throws -> Void

/// The clear's order (Task 10 fix round 1 ruling): the store first, then the files. A store that
/// will not go deletes nothing — cookies and zoom stay together — and its error is thrown as it came.
public func browserRemoveStoreThenFiles(
    _ store: UUID,
    removeStore: (UUID) async throws -> Void,
    deleteFiles: () throws -> Void
) async throws {
    try await removeStore(store)
    try deleteFiles()
}

/// Registers the browser pane's actions (3c-i).
///
/// **One path for the operator and the agent** (Invariant 2): the pane's header, its tab list and
/// the window's keys dispatch these. A tab's web view reports back through the seam
/// (`PaneStore.browserPageDidReport`), never through an action. Each answers the pane's
/// `read_pane` plus its `pane` id. `pane` defaults to the focused browser pane, else the one most
/// recently focused, else the last opened; `tab` to the active tab.
public func registerBrowserActions(
    into registry: ActionRegistry,
    panes: PaneStore,
    layout: LayoutStore?,
    settings: @escaping @Sendable () async -> SettingsBrowser,
    orgFiles: @escaping @Sendable () async throws -> BrowserOrgFiles? = { nil },
    removeData: BrowserDataRemover? = nil,
    driver: (any BrowserPageDriver)? = nil
) async {
    for action in browserActions(panes: panes, layout: layout, settings: settings, orgFiles: orgFiles,
                                 removeData: removeData, driver: driver) {
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
    removeData: BrowserDataRemover? = nil,
    driver: (any BrowserPageDriver)? = nil
) -> [Action] {
    var actions: [Action] = []
    let kind = BrowserPaneKind.names[0]

    /// The named pane, else the focused browser pane, else the one most recently focused, else the
    /// last one opened (the 3c spec's call 11: where a link from elsewhere in Wakil opens). With none
    /// open, `open` opens one (`browser_open`, `browser_new_tab`); otherwise this refuses.
    @Sendable func browserPane(_ params: JSONValue, action: String, open: Bool = false,
                               focus: Bool = true) async throws -> (id: String, opened: Bool) {
        if let pane = optionalString(params, "pane"), !pane.isEmpty {
            try await requireOpenPane(pane, action: action, layout: layout)
            if let p = await layout?.snapshot().panes.first(where: { $0.id == pane }), p.kind != kind {
                throw BrowserActionError.notABrowser(action: action, pane: pane)
            }
            return (pane, false)
        }
        guard let layout else { throw StandardActionError.missingParam(action: action, param: "pane") }
        if let pane = await layout.preferredPane(kind: kind) { return (pane, false) }
        guard open else { throw BrowserActionError.noBrowserPane }
        return (await layout.open(kind: kind, title: Pane.defaultTitle(kind: kind), focus: focus).id, true)
    }

    @Sendable func reply(_ pane: String) async -> JSONValue {
        guard case .object(var o) = await panes.readPane(paneId: pane, kind: kind) else { return .null }
        o["pane"] = .string(pane)
        return .object(o)
    }

    @Sendable func persist(_ pane: String) async {
        let s = await panes.browserSnapshot(paneId: pane)
        await layout?.setBrowserTabs(id: pane, to: browserSavedTabs(s), active: s.active, groups: s.groups,
                                     columnHidden: s.tabColumnHidden)
    }

    /// The place's pins file and project (ruling 13): refused when the place has no project, or the
    /// window no organisation.
    @Sendable func pinsPlace(_ action: String) async throws -> (files: BrowserOrgFiles, project: String) {
        let project = await panes.activeScope.project
        guard !project.isEmpty else { throw BrowserActionError.noProject(action: action) }
        guard let files = try await orgFiles() else { throw BrowserActionError.noOrganisation }
        return (files, project)
    }

    /// Reads or writes the place's pins, an unreadable file refused with its file name and reason.
    @Sendable func withPins<T>(_ action: String, _ place: (files: BrowserOrgFiles, project: String),
                               _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as BrowserPinsUnreadable {
            throw BrowserActionError.pinsUnreadable(
                action: action, file: BrowserOrgFiles.pinsName(project: place.project), reason: error.reason)
        }
    }

    /// Full reconcile (ruling 14) of `pane` with its project's pins, when a pane is opened or
    /// restored. Nothing without a project or an organisation.
    @Sendable func reconcile(_ pane: String) async {
        guard let place = try? await pinsPlace("browser_restore") else { return }
        let pins: Result<[BrowserPin], BrowserPinsUnreadable>
        do { pins = .success(try place.files.pins(project: place.project)) }
        catch let error as BrowserPinsUnreadable { pins = .failure(error) }
        catch { pins = .failure(BrowserPinsUnreadable(reason: error.localizedDescription)) }
        await panes.browserReconcilePins(paneId: pane, pins: pins)
    }

    /// Delta reconcile (ruling 14) of every other browser pane on the canvas — `layout.snapshot()`,
    /// the place on screen only — after a pin, unpin or *Update Pin* in `pane`. A pane left with no
    /// tab closes, as closing its last tab would.
    @Sendable func reconcileOthers(_ pane: String, add: BrowserPin?, remove: String?) async {
        guard let layout else { return }
        for other in await layout.snapshot().panes where other.kind == kind && other.id != pane {
            guard let left = await panes.browserApplyPin(paneId: other.id, add: add, remove: remove) else { continue }
            if left == 0 {
                try? await layout.close(id: other.id)
                await panes.drop(paneId: other.id)
            } else {
                await persist(other.id)
            }
        }
    }

    /// The group `group` names, else the tab `tab` names, else the active tab.
    @Sendable func pinTarget(_ s: BrowserSnapshot, _ params: JSONValue, action: String) throws -> BrowserPinTarget {
        if let group = optionalString(params, "group"), !group.isEmpty {
            guard s.group(group) != nil else { throw BrowserActionError.noGroup(action: action, group: group) }
            return .group(group)
        }
        let tab = optionalString(params, "tab")
        guard let i = s.tabIndex(tab) else { throw BrowserActionError.noTab(action: action, tab: tab) }
        return .tab(s.tabs[i].id)
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
    /// page loads nothing and puts the keyboard in the address field. With an `opener` the pane still
    /// has, the opener rule places it (ruling 8); an opener that has closed meanwhile is none.
    ///
    /// A pane this store holds nothing for is new — `browserPane(open:)` just opened it, or
    /// `pane_open` did — and first takes its project's pins (ruling 14's full reconcile), behind the
    /// new tab, which stays the selected one.
    @Sendable func addTab(_ pane: String, url: String?, opener: String? = nil) async {
        if !(await panes.holdsContents(paneId: pane)) { await reconcile(pane) }
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
            if let opener, s.tabs.contains(where: { $0.id == opener }) {
                s.placeOpenedKnowingTheSite(tab: tab.id, opener: opener)
            } else {
                s.arrange()
            }
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
        description: "Open url in the browser: a new tab (newTab, default true) in the focused browser "
            + "pane, else the one most recently focused, else the last opened, or in its active tab with newTab false. Opens a browser "
            + "pane, focused, when none is open; focus true focuses the pane it used either way (a link from another surface). url follows the address bar's rule: a host or URL loads, words search.",
        kind: .control, audience: .agentReachable,
        schema: schema(["url": string, "newTab": .object(["type": .string("boolean")]),
                        "focus": .object(["type": .string("boolean")])], required: ["url"]),
        handler: { params in
            let url = try await address(try requireString(params, "url", action: "browser_open"))
            let scheme = URL(string: url)?.scheme?.lowercased() ?? ""
            guard ["http", "https", "file"].contains(scheme) else { throw BrowserActionError.notAWebPage(scheme: scheme) }
            let newTab: Bool = { if case .object(let o) = params, case .bool(let b)? = o["newTab"] { b } else { true } }()
            let focus: Bool = { if case .object(let o) = params, case .bool(let b)? = o["focus"] { b } else { false } }()
            let pane = try await browserPane(params, action: "browser_open", open: true).id
            if focus { try await layout?.focus(id: pane) }
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
        name: "browser_print",
        description: "Print a tab's page (tab, default the active one) through the system's print panel, "
            + "as ⌘K → Print page.",
        kind: .control, audience: .operatorOnly,
        schema: schema(tabSchema),
        handler: { params in try await command(params, action: "browser_print") { _ in .print } }))

    actions.append(Action(
        name: "browser_new_tab",
        description: "Open a new tab at the end of a browser pane's tabs and select it: url when given, "
            + "else (url left out) the start page; a blank start page leaves the address field focused. Opens a browser "
            + "pane when none is open. opener, a tab id, is the tab it was opened from (a ⌘-click): it "
            + "joins the opener's group, or forms one with a loose opener of another site.",
        kind: .control, audience: .agentReachable,
        schema: schema(["url": string, "opener": string]),
        handler: { params in
            var url: String?
            // A url given is held to the address rule, blank included; leave it out for the start page.
            if let typed = optionalString(params, "url") { url = try await address(typed) }
            let pane = try await browserPane(params, action: "browser_new_tab", open: true).id
            await addTab(pane, url: url, opener: optionalString(params, "opener"))
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
                s.closeTabs([s.tabs[i].id])
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
        name: "browser_tab_column",
        description: "Hide or show the vertical tab column of a browser pane (hidden true or false; omitted "
            + "toggles). Saved with the pane.",
        kind: .control, audience: .agentReachable,
        schema: schema(["hidden": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_tab_column").id
            let hidden = optionalBool(params, "hidden")
            await panes.updateBrowser(paneId: pane, create: true) { s in
                s.tabColumnHidden = hidden ?? !s.tabColumnHidden
            }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_reopen_tab",
        description: "Reopen the tab closed most recently in a browser pane, at the end of its tabs (in its "
            + "group, if the pane still has it), and select it.",
        kind: .control, audience: .agentReachable,
        schema: schema([:]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_reopen_tab").id
            let ok = await panes.updateBrowser(paneId: pane, create: true) { s -> Bool in
                guard let saved = s.closed.popLast() else { return false }
                var tab = BrowserTab(id: s.takeTabId(), url: saved.url, title: saved.title)
                if saved.url.isEmpty { tab.issue(.focusAddress) } else { tab.issue(.load(saved.url)) }
                // Ruling 22: back to its group while the pane has it (never the pull-request group,
                // whose tabs are the read's); else loose, for the site rule when it loads.
                if let gid = saved.group, let g = s.group(gid), g.kind != .pullRequests {
                    tab.group = gid
                    if let last = s.tabs.lastIndex(where: { $0.group == gid }) {
                        s.tabs.insert(tab, at: last + 1)
                    } else {
                        s.tabs.append(tab)
                    }
                } else {
                    s.tabs.append(tab)
                }
                s.active = tab.id
                s.arrange()
                return true
            }
            guard ok else { throw BrowserActionError.nothingToReopen }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_select_tab",
        description: "Select a tab, by id (tab) or by position (index, 0 first, -1 the last). A tab that "
            + "has not loaded yet loads when selected. With focus true the pane takes the focus too.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "index": .object(["type": .string("integer")]),
                        "focus": .object(["type": .string("boolean")])]),
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
                s.arrange()   // a collapsed group shows the tab selected in it (ruling 21)
                return true
            }
            guard ok else { throw BrowserActionError.noTab(action: "browser_select_tab", tab: tab ?? index.map { "at \($0)" }) }
            if optionalBool(params, "focus") == true { try await layout?.focus(id: pane) }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_move_tab",
        description: "Move a tab to position to (0 first; past the end is the end), and/or into group (a group "
            + "id from read_pane's groups; \"\" takes it out of its group and keeps it out of automatic "
            + "groups). Into a group without to, it goes after the group's last tab. Tabs stay in drawn "
            + "order: pinned, groups, then loose tabs.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "to": .object(["type": .string("integer")]), "group": string],
                       required: ["tab"]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_move_tab").id
            let tab = try requireString(params, "tab", action: "browser_move_tab")
            let to: Int? = { if case .object(let o) = params { o["to"]?.intValue } else { nil } }()
            let group = optionalString(params, "group")
            guard to != nil || group != nil else {
                throw StandardActionError.missingParam(action: "browser_move_tab", param: "to")
            }
            let target = group.flatMap { $0.isEmpty ? nil : $0 }
            let outcome = await panes.updateBrowser(paneId: pane, create: true) { s -> BrowserActionError? in
                guard let i = s.tabs.firstIndex(where: { $0.id == tab }) else {
                    return .noTab(action: "browser_move_tab", tab: tab)
                }
                if let target, s.group(target) == nil { return .noGroup(action: "browser_move_tab", group: target) }
                if group != nil {
                    s.moveTab(tab, into: target, at: to)
                } else if let to {
                    let moved = s.tabs.remove(at: i)
                    s.tabs.insert(moved, at: max(0, min(to, s.tabs.count)))
                    s.arrange()
                }
                return nil
            }
            if let outcome { throw outcome }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_group",
        description: "Change a browser pane's tab groups (3d-i). action: create makes your group named name "
            + "(default New Group) of tabs (tab ids, default the active tab), coloured colour when given; "
            + "rename (name) and recolour (colour: blue, steel, teal, sand, stone or smoke) make an automatic "
            + "group yours; collapse and expand; ungroup leaves its tabs loose and out of automatic groups; "
            + "close closes its tabs (browser_reopen_tab brings each back), and the pane with the last. "
            + "group is a group id from read_pane's groups. The pull-request group (pr) only collapses and "
            + "expands. Never changes the selected tab.",
        kind: .control, audience: .agentReachable,
        schema: schema([
            "action": .object(["type": .string("string"), "enum": .array(
                ["create", "rename", "recolour", "collapse", "expand", "ungroup", "close"].map { .string($0) })]),
            "group": string, "name": string,
            "tabs": .object(["type": .string("array"), "items": string]),
            "colour": .object(["type": .string("string"), "enum": .array(
                BrowserGroupColour.allCases.map { .string($0.rawValue) })]),
        ], required: ["action"]),
        handler: { params in
            let action = "browser_group"
            let verb = try requireString(params, "action", action: action)
            guard ["create", "rename", "recolour", "collapse", "expand", "ungroup", "close"].contains(verb) else {
                throw BrowserActionError.unknownGroupAction(verb)
            }
            let pane = try await browserPane(params, action: action).id
            let name = optionalString(params, "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let typedColour = optionalString(params, "colour")
            let colour = typedColour.flatMap { typed in BrowserGroupColour.allCases.first { $0.rawValue == typed } }
            if typedColour != nil, colour == nil { throw BrowserActionError.unknownColour }

            if verb == "create" {
                let listed: [String]? = {
                    guard case .object(let o) = params, case .array(let items)? = o["tabs"] else { return nil }
                    return items.compactMap { if case .string(let id) = $0 { id } else { nil } }
                }()
                let made = await panes.updateBrowser(paneId: pane, create: true) { s -> Result<String, BrowserActionError> in
                    let members = listed ?? s.active.map { [$0] } ?? []
                    guard !members.isEmpty else { return .failure(.noTab(action: action, tab: nil)) }
                    if let missing = members.first(where: { id in !s.tabs.contains { $0.id == id } }) {
                        return .failure(.noTab(action: action, tab: missing))
                    }
                    let id = s.newGroup(tabs: members, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "New Group",
                                        kind: .own, siteKey: nil)
                    if let colour, let g = s.groups.firstIndex(where: { $0.id == id }) { s.groups[g].colour = colour }
                    return .success(id)
                }
                let id = try made.get()
                await persist(pane)
                guard case .object(var o) = await reply(pane) else { return .null }
                o["group"] = .string(id)
                return .object(o)
            }

            guard let group = optionalString(params, "group"), !group.isEmpty else {
                throw StandardActionError.missingParam(action: action, param: "group")
            }
            if verb == "rename", name?.isEmpty ?? true {
                throw StandardActionError.missingParam(action: action, param: "name")
            }
            if verb == "recolour", colour == nil {
                throw StandardActionError.missingParam(action: action, param: "colour")
            }
            let outcome = await panes.updateBrowser(paneId: pane, create: true) { s -> Result<Int, BrowserActionError> in
                guard let g = s.groups.firstIndex(where: { $0.id == group }) else {
                    return .failure(.noGroup(action: action, group: group))
                }
                if s.groups[g].kind == .pullRequests {
                    let words = ["rename": "renamed", "recolour": "recoloured", "ungroup": "ungrouped", "close": "closed"]
                    if let word = words[verb] { return .failure(.pullRequestGroupRefuses(word)) }
                }
                switch verb {
                case "rename":
                    s.groups[g].name = name ?? s.groups[g].name
                    s.groups[g].named = true
                    s.makeOwn(group)
                case "recolour":
                    s.groups[g].colour = colour ?? s.groups[g].colour
                    s.makeOwn(group)
                case "collapse", "expand":
                    s.groups[g].collapsed = verb == "collapse"
                    s.arrange()
                case "ungroup":
                    // Ruling 10: the operator ungrouped them, so the site rule never regroups them.
                    for i in s.tabs.indices where s.tabs[i].group == group {
                        s.tabs[i].group = nil
                        s.tabs[i].opener = nil
                        s.tabs[i].keptLoose = true
                    }
                    s.groups.remove(at: g)
                    s.arrange()
                default:   // close
                    s.closeTabs(Set(s.tabs.filter { $0.group == group }.map(\.id)))
                    s.groups.removeAll { $0.id == group }
                    s.arrange()
                }
                return .success(s.tabs.count)
            }
            let left = try outcome.get()
            if left == 0 {
                try await layout?.close(id: pane)
                await panes.drop(paneId: pane)
                return .object(["pane": .string(pane), "closed": .bool(true)])
            }
            await persist(pane)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_pin",
        description: "Pin a tab (tab, default the active one) or a group (group, a group id from read_pane's "
            + "groups; pr is the pull-request group) to the project: it is kept in the project's pins and "
            + "shows, unloaded, in every browser pane of the project; a closed pinned tab comes back when the "
            + "pane next opens. A pinned tab leaves its group; a pinned group becomes yours. update true on a "
            + "pinned tab keeps its page now as the pin (Pin Current Page), on a pinned group its name, colour "
            + "and tabs (Update Pin); other panes keep the pages they show.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "group": string, "update": .object(["type": .string("boolean")])]),
        handler: { params in
            let action = "browser_pin"
            let pane = try await browserPane(params, action: action).id
            let place = try await pinsPlace(action)
            let update = optionalBool(params, "update") == true
            let s = await panes.browserSnapshot(paneId: pane)
            let target = try pinTarget(s, params, action: action)
            var pins = try withPins(action, place) { try place.files.pins(project: place.project) }

            let entry: BrowserPin
            switch target {
            case .group(let gid):
                guard let g = s.group(gid) else { throw BrowserActionError.noGroup(action: action, group: gid) }
                let id = g.pin ?? BrowserPin.newId()
                entry = g.kind == .pullRequests
                    ? BrowserPin(id: id, kind: .pullRequests)
                    : BrowserPin(id: id, kind: .group, name: g.name, colour: g.colour,
                                 tabs: s.tabs.filter { $0.group == gid }.map { BrowserPinTab(url: $0.url, title: $0.title) })
            case .tab(let tid):
                guard let tab = s.tabs.first(where: { $0.id == tid }) else {
                    throw BrowserActionError.noTab(action: action, tab: tid)
                }
                // A tab of a pinned group is pinned with it.
                if tab.pin == nil, s.isPinned(tab) { return await reply(pane) }
                entry = BrowserPin(id: tab.pin ?? BrowserPin.newId(), kind: .tab, url: tab.url, title: tab.title)
            }
            let present = pins.firstIndex { $0.id == entry.id }
            guard present == nil || update else { return await reply(pane) }
            if let present { pins[present] = entry } else { pins.append(entry) }
            try withPins(action, place) { try place.files.setPins(pins, project: place.project) }

            await panes.updateBrowser(paneId: pane, create: true) { s in
                switch target {
                case .group(let gid):
                    guard let g = s.groups.firstIndex(where: { $0.id == gid }) else { return }
                    s.groups[g].pin = entry.id
                    s.makeOwn(gid)   // ruling 11
                case .tab(let tid):
                    guard let i = s.tabs.firstIndex(where: { $0.id == tid }) else { return }
                    s.tabs[i].pin = entry.id
                    s.tabs[i].group = nil
                    s.tabs[i].opener = nil
                    s.tabs[i].pullRequest = nil
                }
                s.arrange()
            }
            await persist(pane)
            await reconcileOthers(pane, add: entry, remove: nil)
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_unpin",
        description: "Unpin a tab (tab, default the active one; a tab of a pinned group unpins the group) or a "
            + "group (group): it leaves the project's pins and every other browser pane of the project, and "
            + "stays here, unpinned.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "group": string]),
        handler: { params in
            let action = "browser_unpin"
            let pane = try await browserPane(params, action: action).id
            let place = try await pinsPlace(action)
            let s = await panes.browserSnapshot(paneId: pane)
            let pin: String?
            switch try pinTarget(s, params, action: action) {
            case .group(let gid): pin = s.group(gid)?.pin
            case .tab(let tid):
                let tab = s.tabs.first { $0.id == tid }
                pin = tab?.pin ?? tab?.group.flatMap { s.group($0)?.pin }
            }
            guard let pin else { return await reply(pane) }
            var pins = try withPins(action, place) { try place.files.pins(project: place.project) }
            if pins.contains(where: { $0.id == pin }) {
                pins.removeAll { $0.id == pin }
                try withPins(action, place) { try place.files.setPins(pins, project: place.project) }
            }
            await panes.updateBrowser(paneId: pane, create: true) { s in
                for i in s.tabs.indices where s.tabs[i].pin == pin { s.tabs[i].pin = nil }
                for i in s.groups.indices where s.groups[i].pin == pin { s.groups[i].pin = nil }
                s.arrange()
            }
            await persist(pane)
            await reconcileOthers(pane, add: nil, remove: pin)
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
        name: "browser_bookmark",
        description: "Bookmark the active tab's page for the organisation, or remove its bookmark. With on "
            + "omitted it toggles; true adds, false removes. Only http, https and file pages can be "
            + "bookmarked. read_pane's bookmarked says where it stands.",
        kind: .control, audience: .agentReachable,
        schema: schema(["tab": string, "on": .object(["type": .string("boolean")])]),
        handler: { params in
            let pane = try await browserPane(params, action: "browser_bookmark").id
            let wanted = optionalBool(params, "on")
            let snapshot = await panes.browserSnapshot(paneId: pane)
            let target = snapshot.tabIndex(optionalString(params, "tab")).map { snapshot.tabs[$0] }
            guard let target else { throw BrowserActionError.noTab(action: "browser_bookmark", tab: optionalString(params, "tab")) }
            let scheme = URL(string: target.url)?.scheme?.lowercased() ?? "about"
            guard ["http", "https", "file"].contains(scheme) else { throw BrowserActionError.notBookmarkable(scheme: scheme) }
            guard let files = try await orgFiles() else { throw BrowserActionError.noOrganisation }
            do {
                try files.setBookmark(url: target.url, title: target.label, on: wanted, now: Date())
                await panes.browserSetBookmarks(org: files.org, try files.bookmarks())
            } catch let error as BrowserBookmarksUnreadable {
                throw BrowserActionError.bookmarksUnreadable(error.reason)
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
                await panes.browserRestore(paneId: pane, tabs: saved.tabs, active: saved.active,
                                           groups: saved.groups, columnHidden: saved.columnHidden)
            }
            // Ruling 14: a restored pane takes the pins added since and drops the ones gone.
            let before = await panes.browserSnapshot(paneId: pane)
            await reconcile(pane)
            if await panes.browserSnapshot(paneId: pane).tabs != before.tabs { await persist(pane) }
            return await reply(pane)
        }))

    actions.append(Action(
        name: "browser_clear_data",
        description: "Delete the active organisation's browsing data: every site's cookies, logins and storage, "
            + "in every project, the saved zoom and the organisation's browsing history; bookmarks are kept. `org` is the organisation the operator was asked "
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
            // The window drops the store's web views, then removes the store, then deletes the
            // files (`browserRemoveStoreThenFiles`): no page is left alive to write a tab state,
            // and a store that will not go leaves everything. Deleted only there — a second
            // deletion after the remover could take a rebuilt page's new state.
            try await removeData(id) { try files.removeEverythingButTheProfile() }
            return .object(["cleared": .string(files.org)])
        },
        // Signs out of every site in every project, in production and out of it.
        price: (production: .gate, otherwise: .gate)))

    // 3c-ii: the agent's reach into the page — read it, act in it by ref, priced per site.
    actions += browserReachActions(
        panes: panes, driver: driver,
        pane: { params, action in try await browserPane(params, action: action).id },
        schema: { properties, required in schema(properties, required: required) })
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
    case newTab, closeTab, toggleTabColumn, reopenTab, focusAddress, reload, back, forward, find, findNext, findPrevious
    case zoomIn, zoomOut, zoomReset, nextTab, previousTab, bookmark
    /// ⌘1–8 tab N; ⌘9 the last tab.
    case tab(Int)
}
