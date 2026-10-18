import Foundation

/// One assembled Wakil: an `ActionRegistry` with the 2a action set and the
/// 2b-i layout actions registered into it, the `PaneStore` those actions
/// write to, the `LayoutStore` the layout actions arrange, and the
/// `MCPClient`s (`wakil-ctx`, `wakil-db`, `wakil-http`, `wakil-git`) their handlers call.
///
/// This exists because there are two entry points that need exactly the
/// same assembly and cannot share it any other way. `--dispatch` (the
/// debug hook, spec §4) exits before any AppKit code runs, so it can never
/// reach a registry the window builds; and the window cannot reach one
/// `--dispatch` builds, because by then the process has exited. Building
/// the registry separately in each place is what shipped in the first cut
/// of Task 10, and it is why `--dispatch` answered `unknown(...)` for
/// every real action name: the copy it built had nothing registered into
/// it. `build` is the single place either path gets a populated registry
/// from, and both callers now go through it: `runDispatchFile` in
/// main.swift, and `WindowSession.start` in WakilWindow.swift, which builds
/// no registry of its own.
///
/// A `MCPClient` is `nil` when its binary could not be found or refused to
/// start. That is deliberately not fatal: `registerStandardActions`
/// registers every action regardless and its handler throws
/// `StandardActionError.missingClient`, which names the action and the
/// role it needed. An operator running one `--dispatch` script against a
/// half-installed tree then gets a line saying which client is missing,
/// per line, rather than a crash on the first one — and the registry still
/// answers `tools/list` and `all()` honestly.
public struct WakilWiring: Sendable {
    public let registry: ActionRegistry
    public let panes: PaneStore
    public let layout: LayoutStore
    /// Every live PTY this assembly opened. One per assembly, same
    /// reasoning as `panes` and `layout`: `term_open`'s handler is closed
    /// over this instance, so a second one would leave the action set
    /// opening shells nothing here can tear down.
    public let terminals: TerminalStore
    /// What `term_open` asks for the active organisation, project and
    /// environment to fold into a shell's own environment. Created here
    /// and closed over by the action at registration, pointed at the live
    /// window by `useActiveContext(of:)` once there is one — the active
    /// context changes while the app runs, so this must be asked, never
    /// captured. See `ActiveShellContext`.
    public let shellContext: ActiveShellContext
    public let contextClient: MCPClient?
    public let databaseClient: MCPClient?
    /// `wakil-http`, in the window (#185).
    ///
    /// It ran only as a harness-spawned binary until 2c-iv, which is why
    /// the api pane had no client to send through: a pane's send is a
    /// registry action, and the registry reaches Go through the clients
    /// this assembly owns. There is no new actor to build — the terminal
    /// store was modelled on `MCPClient` precisely because a PTY is not
    /// one, and this IS one.
    ///
    /// Eager per window, like the other two, and `nil` when the binary
    /// cannot be found or refuses to start — `diagnostics` says which.
    public let httpClient: MCPClient?
    /// `wakil-git` (3a-i): the git reads behind the window's status (`GitStatus`) and the editor's
    /// Changes view and diff tabs (3b-iii).
    ///
    /// Eager per window like the other three, `nil` when the binary cannot be found or
    /// refuses to start — the actions stay registered and fail per call, naming it. Its
    /// roots come from the active project, which `wakil-git` resolves under the org this
    /// wiring runs, so it joins the org switch like every other client here.
    public let gitClient: MCPClient?
    /// `wakil-files` (3b-i): the editor pane's reads and writes of project files, confined to the
    /// active project's roots. Eager and optional like the others; it joins the org switch.
    public let filesClient: MCPClient?
    /// The window's one list per root over `filesClient` (3b-ii): ⌘P's files source, the editor
    /// actions and every editor pane's tree read it. Built whenever `filesClient` is; handed to the
    /// window by `WindowSession.start`, which also gives it to the palette.
    public let fileLists: EditorFileLists?
    /// What keeps the window's git status live (3a-i). One per assembly, as the window is;
    /// `WindowSession.start` hands it to the window, which starts and stops it as editor panes
    /// open and close, and `shutdown` stops it.
    public let rootWatcher: any RootWatcher
    /// The window's git status (3b-iii). One per assembly; the window, the actions and `GitSource`
    /// share it.
    public let gitStatus: GitStatus
    /// The editor panes' own watch (3b-i), separate from the git one so each starts and stops
    /// with its own panes. Handed to the window by `WindowSession.start`; `shutdown` stops it.
    public let editorRootWatcher: any RootWatcher
    /// The roots the window's status reads and the editor's git actions check against, asked live: pointed at the
    /// window by `useActiveContext(of:)`, and read from `wakil-ctx` until then — which is
    /// all `--dispatch`, with no window, ever has.
    let gitRoots: GitRootsSource
    /// Clients pinned to an agent session's own place, for every call it makes, wherever the
    /// screen is (background agents, 2 of 4). Every handler `build` registers reaches Go
    /// through a `PlaceRoutedCaller` over the window's client and this pool. Not in
    /// `wakilOwnedClients`: an org switch re-points the window's own clients only, and a pool
    /// client already belongs to its place's org. `WindowModel` retains the places in use;
    /// `shutdown` stops the rest.
    public let placeClients: PlaceClients

    /// Every client this assembly owns and must re-point on an org
    /// switch, as ONE collection.
    ///
    /// **This is the ticket, not a convenience** (#185). `switchOrg` used
    /// to restart a hard-coded pair, so adding a third client meant
    /// remembering to add a third name to a list — and the failure of
    /// forgetting is org A's credential reachable from org B's window,
    /// which is Invariant 4 and is silent. A new client now joins the
    /// switch by joining this property, and
    /// `everyWakilOwnedClientJoinsTheOrgSwitch` fails if one is declared
    /// on this type and left out of it.
    ///
    /// **Four Wakil-owned, three harness-spawned — never a bare total.**
    /// The agent's own MCP configuration carries `wakil-pm`,
    /// `wakil-recall` and `wakil-git` (`agentFacingServers`) plus the
    /// `wakil` shim, and those are the harness's children, not this
    /// assembly's: nothing here starts or stops them, and an org switch
    /// reaches them by restarting the harness instead. **`wakil-git` is
    /// on both lists** (3a-i): this assembly's copy serves the pane's
    /// actions, and the harness spawns its own for the agent's direct
    /// reads (Invariant 9) — two processes of one binary, each torn down
    /// by its own owner. Headless `--dispatch` runs the same binaries in
    /// a different arrangement, so a bare count reads as agreement
    /// between two things that are not the same.
    public var wakilOwnedClients: [(name: String, client: MCPClient?)] {
        [("wakil-ctx", contextClient),
         ("wakil-db", databaseClient),
         ("wakil-http", httpClient),
         ("wakil-git", gitClient),
         ("wakil-files", filesClient)]
    }
    /// Where a mutation refused by the gate waits for a human. One per
    /// assembly, shared by the agent's path (`MCPServer`) and the window's
    /// (`WindowModel`) — one confirmation mechanism, not two, for the same
    /// reason there is one action set behind both `--dispatch` and the
    /// window.
    public let confirmations: ConfirmationBroker
    /// Where a `session_resume` request parks for the window to act on.
    /// One per assembly, same reasoning as `confirmations`: one resume
    /// mechanism, not two, for the same action set served by both
    /// `--dispatch` and the window. Unlike `confirmations` it has exactly
    /// one subscriber for the assembly's whole life — see `ResumeBroker`'s
    /// own doc comment for that lifecycle contract.
    public let resumes: ResumeBroker
    /// Where a `session_set_provider` request parks for the window to act
    /// on. Same reasoning and lifecycle contract as `resumes`, for the
    /// same action-set-shared-by-`--dispatch`-and-the-window reason — see
    /// `ProviderSwitchBroker`'s own doc comment.
    public let providerSwitches: ProviderSwitchBroker
    /// Human-readable notes about anything that did not come up: a binary
    /// that was not found at any candidate path, or one that failed the
    /// MCP handshake. Empty on a fully successful build. A caller prints
    /// these (`--dispatch` writes them to stderr); nothing branches on
    /// them.
    public let diagnostics: [String]
    /// Re-resolves every api pane when the environment changes and at launch (9b W1), over
    /// THIS assembly's pane store and `wakil-http` — the window is handed it, never builds one.
    public let apiResolver: ApiPaneResolver?
    /// 2d-i: the names in scope a window's turns resolve against — Wakil's
    /// own and what is on screen read live, schema and code built per
    /// context. One per assembly, over THIS registry and these stores;
    /// `WindowSession.start` hands it to the window.
    public let vocabulary: VocabularyStore
    /// 2d-ii: the speech engines this build ships (Invariant 11). Built
    /// once per process; each hold of ⌥ makes a fresh provider from it.
    public let speech: SpeechRegistry
    /// The environment `build` was given, which `switchOrg` restarts the
    /// clients under.
    ///
    /// **Not `ProcessInfo.processInfo.environment`** (#321). `switchOrg`
    /// read the live process's environment, so a wiring built with a scratch
    /// `HOME` switched into the REAL one. Its own test had to write fixture
    /// organisations into the operator's `~/.wakil` to pass, and they leaked
    /// there. The HOME a wiring was built for is the one it switches within.
    let launchEnvironment: [String: String]

    /// What `MCPSocketServer` serves to the agent: this assembly's registry,
    /// *its* pane store and *its* layout store, paired here rather than at
    /// the call site.
    ///
    /// The pairing matters because `db_run_query`'s handler writes into
    /// `panes`, and the `pane_*` actions' handlers write into `layout` — so
    /// a server given this registry and some other assembly's stores would
    /// dispatch actions correctly while `read_pane` and `read_layout`
    /// reported an empty pane or an empty canvas forever, with nothing
    /// anywhere failing.
    ///
    /// This is also the *only* `public` way to obtain an `MCPSurface`:
    /// its memberwise initialiser is `internal`, so outside `WakilKit` — in
    /// `WakilApp`, which is where the window and the socket server meet —
    /// there is no way to name the two halves separately and therefore no
    /// way to mismatch them. See `MCPSurface`'s own doc comment for what
    /// that does and does not enforce.
    public var mcpSurface: MCPSurface {
        MCPSurface(
            registry: registry, panes: panes, layout: layout,
            confirmations: confirmations,
            // The same read `ctx_config_tree` performs, through the same
            // function — see `readConfigTree`'s doc comment for why
            // `read_pane` reaches it here rather than through `dispatch`.
            // Closed over THIS assembly's context client, for the reason
            // every other member of this struct is paired here rather than
            // at the call site.
            settings: { [contextClient] in try await readConfigTree(contextClient) })
    }

    /// Points `term_open`'s context at `model`, so a shell opened from now
    /// on carries the window's **live** organisation, project and
    /// environment, and defaults its path from the window's **live**
    /// project root (walk-defects B1).
    ///
    /// **This is the wiring final review's Critical 3 found missing.**
    /// `terminalActions`' `activeContext:` defaulted to always-empty and
    /// nothing anywhere overrode it, so `WAKIL_ORG`, `WAKIL_PROJECT` and
    /// `WAKIL_ENVIRONMENT` were never exported into a pane's shell —
    /// while `WAKIL_ORG` was still *inherited* from Wakil's own process
    /// environment, which is how a walk could see the org apparently
    /// correct and the other two empty and misdiagnose the cause.
    ///
    /// **A read of the window, not a copy of it.** `model` is asked on
    /// every `term_open`, so a pane opened after a project or environment
    /// switch carries the new one. (A pane opened *before* it keeps what
    /// its shell was launched with — an environment is handed to a process
    /// once, at `execve`, and nothing can reach back into a running
    /// shell's own copy. The runbook's Check 3 says so in as many words.)
    ///
    /// Weak, so the box does not keep a closed window alive; a released
    /// model answers as an unwired one does.
    @MainActor
    public func useActiveContext(of model: WindowModel) {
        // Both below are read for the dispatch they run in: an agent session gets its own
        // place's context and roots (`WindowModel.shellContext(forCaller:)`).
        shellContext.use { [weak model] in
            guard let model else { return ("", "", "", "") }
            return await model.shellContext(forCaller: ActionRegistry.dispatchCaller)
        }
        // 3a-i: the git actions' roots are the window's too, read on every call for the
        // same reason — a project switch changes them.
        gitRoots.use { [weak model] in
            await model?.gitRootPaths(forCaller: ActionRegistry.dispatchCaller) ?? []
        }
    }

    /// Stops every Wakil-owned MCP client, terminating their child
    /// processes.
    ///
    /// `--dispatch` calls it before returning, for determinism rather than
    /// because the children would otherwise survive indefinitely: exiting
    /// closes the pipe feeding their stdin, and the binaries quit on the
    /// EOF that produces (measured on
    /// this machine — `bin/wakil-ctx < /dev/null` and `bin/wakil-db <
    /// /dev/null` each exit 0 in well under a second), so in the normal
    /// case they self-reap. What stopping explicitly buys is that the
    /// window in which they might not is closed: a child in the middle of
    /// a slow tool call would not read that EOF promptly. Safe to call
    /// more than once: `MCPClient.stop()` single-flights its own teardown.
    ///
    /// **It iterates `wakilOwnedClients`, and #185 is why that matters
    /// here too.** This named the same hard-coded pair `switchOrg` did,
    /// two dozen lines above it, so a client could join the org switch and
    /// still never be torn down. `wakil-http` is the one that makes the
    /// gap bite: "in the middle of a slow tool call" — the window this
    /// doc says explicit stopping exists to close — is its ORDINARY
    /// state, an outbound request waiting on somebody else's server, and
    /// `main.swift`'s `exit()` would orphan it.
    public func shutdown() async {
        await rootWatcher.stop()
        await editorRootWatcher.stop()
        for (_, client) in wakilOwnedClients {
            await client?.stop()
        }
        await placeClients.stopAll()
        // No shell outlives the app. `--dispatch` can open one too.
        // `.finish`: this is the process ending, not an org switch, so the
        // run stream ends here as well (`TerminalRunStreamDisposition`).
        await terminals.shutdownAll(runStream: .finish)
    }

    /// Assembles everything, spawning whichever of `wakil-ctx`,
    /// `wakil-db`, `wakil-http` and `wakil-git` could be located from
    /// `executableDirectory` and `environment` (see `binaryURL(named:)`).
    ///
    /// `journalDirectory` and `sessionId` are the caller's to choose so
    /// that the debug hook, the window and a test can each journal where
    /// they mean to; nothing here reads `HOME` to derive them.
    public static func build(
        journalDirectory: URL,
        sessionId: String,
        executableDirectory: URL = WakilWiring.defaultExecutableDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> WakilWiring {
        var diagnostics: [String] = []
        // `environment["WAKIL_PROVIDER"]` here, not a live pick: every
        // client `build` spawns — `wakil-ctx`, `wakil-db` and, since
        // #185, `wakil-http` — reads the launch-time value only to fill
        // in `Resolved.Provider.Running`. **Re-checked when `wakil-http`
        // joined**, because that client spends a credential: an api
        // entry's `authRef` resolves against the Keychain by ORG
        // (`keychainService` puts the org in the service name) and never
        // by provider, and `switchOrg` re-points every client with
        // `provider: nil` deliberately. So a stale launch-time provider
        // cannot mis-scope a send. The launch-time
        // value is what `CurrentProvider()` (Go) still reads to fill in
        // `Resolved.Provider.Running`, the advisory Selected-vs-Running
        // comparison — a fact distinct from `Resolved.ActiveProvider`,
        // the switchable pick `WindowSession` resolves separately for the
        // harness. See `childProcessEnvironment`'s doc comment for why the
        // parameter exists at all.
        let childEnvironment = childProcessEnvironment(
            from: environment, org: environment["WAKIL_ORG"], provider: environment["WAKIL_PROVIDER"])

        func startClient(_ name: String) async -> MCPClient? {
            guard let url = binaryURL(named: name, executableDirectory: executableDirectory, environment: environment) else {
                diagnostics.append(
                    notFoundDiagnostic(for: name, executableDirectory: executableDirectory, environment: environment))
                return nil
            }
            let client = MCPClient(executable: url, arguments: [], environment: childEnvironment)
            do {
                try await client.start()
                return client
            } catch {
                // Stop it before dropping it: `start()` can fail after the
                // child was spawned (a handshake that times out, say), and
                // an un-stopped client leaves that child running.
                await client.stop()
                diagnostics.append("\(name): failed to start (\(url.path)): \(error)")
                return nil
            }
        }

        let contextClient = await startClient("wakil-ctx")
        let databaseClient = await startClient("wakil-db")
        // Eager, like the other two (#185). A pane's send must find a
        // client already up: starting one lazily on first use would put
        // a handshake, and its failure mode, inside the send.
        let httpClient = await startClient("wakil-http")
        // 3a-i, eager for the same reason: the window's first status read must find it up.
        let gitClient = await startClient("wakil-git")
        // 3b-i, eager for the git client's reason: an editor's first open must find it up.
        let filesClient = await startClient("wakil-files")

        // Background agents, 2 of 4: an agent session's call goes to a client of its own,
        // started for its place on first use. Each is a fresh process under
        // `pinnedEnvironment` — never a window client re-pointed (Invariant 4).
        let placeClients = PlaceClients(
            start: { role, place in
                guard let url = binaryURL(
                    named: role.rawValue, executableDirectory: executableDirectory, environment: environment)
                else {
                    throw PlaceClientError.notFound(
                        notFoundDiagnostic(for: role.rawValue, executableDirectory: executableDirectory,
                                           environment: environment))
                }
                let client = MCPClient(
                    executable: url, arguments: [],
                    environment: pinnedEnvironment(
                        for: place, from: environment, provider: pinnedProvider(for: place, launch: environment)))
                do {
                    try await client.start()
                } catch {
                    // `startClient`'s reason: a failed start can leave a child running.
                    await client.stop()
                    throw error
                }
                return client
            },
            stop: { client in await (client as? MCPClient)?.stop() })
        // Every handler below is handed one of these instead of the window's client. A role
        // whose window client is missing stays missing: its actions fail naming it, as before.
        func routed(_ role: ClientRole, _ client: MCPClient?) -> (any ToolCaller)? {
            client.map { PlaceRoutedCaller(role: role, window: $0, pool: placeClients) }
        }
        let routedFiles = routed(.files, filesClient)
        // The list wraps the routed client, so its pass-through reads route too. It keeps the
        // window's lists only: an agent's listing skips them.
        let fileLists = routedFiles.map { EditorFileLists(files: $0) }

        let panes = PaneStore(kinds: PaneKinds.standard)
        let layout = LayoutStore()
        let registry = ActionRegistry(journalDirectory: journalDirectory, sessionId: sessionId)
        let resumes = ResumeBroker()
        let providerSwitches = ProviderSwitchBroker()
        let terminals = TerminalStore(panes: panes)
        await registerStandardActions(
            into: registry, context: routed(.context, contextClient), panes: panes,
            db: routed(.database, databaseClient), resumes: resumes,
            providerSwitches: providerSwitches, layout: layout)
        await registerLayoutActions(
            into: registry, layout: layout, panes: panes, terminals: terminals,
            unsavedEditorTabs: unsavedEditorTabsProbe(panes: panes))
        await registerPaneContentActions(into: registry, panes: panes, layout: layout)
        // `activeContext:` is this box's own read, not a value: the
        // window does not exist yet, and the context it will report
        // changes for the rest of the app's life. `WindowSession.start`
        // calls `useActiveContext(of:)` the moment it has a window; until
        // then — and in `--dispatch`, which never has one — the box
        // answers empty and `terminalChildEnvironment` leaves the three
        // keys absent rather than exporting them blank.
        let shellContext = ActiveShellContext()
        await registerTerminalActions(
            into: registry, terminals: terminals, panes: panes, layout: layout,
            activeContext: { await shellContext.current() })
        // The api pane reads the same box for the environment it records
        // on a draft, and the third client for the entries it may be
        // pointed at (#188). `http` is optional here for the reason every
        // client is: a binary that could not be located leaves its
        // actions registered and failing honestly, rather than leaving
        // the window without them.
        let apiResolver = await registerApiActions(
            into: registry, panes: panes, layout: layout, http: routed(.http, httpClient),
            activeContext: { await shellContext.current() })
        // 3a-i. The roots are asked live, like the shell context above: the window's once
        // there is one, `wakil-ctx`'s until then.
        let gitRoots = GitRootsSource(context: contextClient)
        let gitStatus = GitStatus(git: routed(.git, gitClient), roots: { await gitRoots.current() })
        await registerEditorActions(
            into: registry, panes: panes, layout: layout,
            files: fileLists.map { $0 as any ToolCaller } ?? routedFiles, fileLists: fileLists,
            gitStatus: gitStatus, roots: { await gitRoots.current() })

        // Provider capacity: the record path and the one read every surface uses.
        await registerCapacityActions(into: registry, context: routed(.context, contextClient))

        // **The gate learns the project's production flags before its
        // first dispatch** (Decision 26, #182). A window re-reads them on
        // every `refreshContext`, so for it this is only a head start —
        // but `--dispatch` never builds a window, and without this read
        // its registry would price every environment by the name rule,
        // silently ignoring a `production: true` the operator wrote down.
        // That is the one path where the flag would have been configured
        // and then not consulted.
        //
        // Best-effort, and deliberately: a failure here is an org with no
        // context yet, or a `wakil-ctx` that will not start, and both are
        // already reported by the paths that need them. Failing the whole
        // wiring over it would turn a missing flag into a window that
        // does not open. `.undeclared` is the name rule, which is what
        // this build's predecessor did everywhere.
        if let contextClient,
           let active = try? await ContextStore(client: contextClient).current() {
            await registry.setEnvironmentProduction(active.environmentProduction)
        }

        // 2d-i. The code cache lives under the same HOME the window's
        // journal and layouts derive from, so an overridden HOME moves it too.
        let home = environment["HOME"] ?? NSHomeDirectory()
        var cachedSources: [any IdentifierSource] = [
            CodeSource(cacheDirectory: CodeSource.defaultCacheDirectory(home: home))
        ]
        if let databaseClient { cachedSources.insert(SchemaSource(db: databaseClient), at: 0) }
        let journalRegistry = registry
        // A failing source contributes nothing and is journalled whole;
        // nothing shows on screen (Interaction Rule 8).
        let vocabulary = VocabularyStore(
            live: [WakilSource(registry: registry), PaneSource(layout: layout, panes: panes),
                   GitSource(status: gitStatus)],
            cached: cachedSources,
            report: { source, message in
                try? await journalRegistry.journalIdentifierEvent(
                    action: "identifier_source_failed",
                    params: .object(["source": .string(source), "error": .string(message)]),
                    caller: DispatchCaller(
                        place: Place(organization: "", project: "", environment: ""), session: nil),
                    outcome: "error")
            })

        return WakilWiring(
            registry: registry,
            panes: panes,
            layout: layout,
            terminals: terminals,
            shellContext: shellContext,
            contextClient: contextClient,
            databaseClient: databaseClient,
            httpClient: httpClient,
            gitClient: gitClient,
            filesClient: filesClient,
            fileLists: fileLists,
            rootWatcher: FSEventsRootWatcher(),
            gitStatus: gitStatus,
            editorRootWatcher: FSEventsRootWatcher(),
            gitRoots: gitRoots,
            placeClients: placeClients,
            confirmations: ConfirmationBroker(),
            resumes: resumes,
            providerSwitches: providerSwitches,
            diagnostics: diagnostics,
            apiResolver: apiResolver,
            vocabulary: vocabulary,
            speech: SpeechRegistry.standard(environment: environment),
            launchEnvironment: environment
        )
    }

    /// The directory holding the running executable — `Bundle.main
    /// .executableURL`'s parent, which is the full path to the binary in
    /// both layouts below and is *not* symlink-resolved (verified on this
    /// machine: a binary run from `app/.build/debug`, itself a symlink to
    /// `app/.build/arm64-apple-macosx/debug`, reports the `.build/debug`
    /// path). Falls back to `argv[0]`'s parent, and finally to the current
    /// directory, neither of which is expected to be reached.
    public static func defaultExecutableDirectory() -> URL {
        if let exe = Bundle.main.executableURL {
            return exe.deletingLastPathComponent()
        }
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            return URL(fileURLWithPath: argv0).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Locates one bundled Go binary by name, returning `nil` when it is
    /// not where any of the supported layouts put it.
    ///
    /// Three layouts, checked in this order:
    ///
    /// 1. `WAKIL_BIN_DIR/<name>`, when that variable is set. This is
    ///    **exclusive**: if the variable is set and the binary is not
    ///    there, the answer is `nil` rather than a fallback to the layouts
    ///    below. A test points it at a scratch directory precisely so that
    ///    no real binary can be spawned, and a fallback would defeat that.
    ///    Set-but-empty (`WAKIL_BIN_DIR=""`) counts as set: it resolves to
    ///    `nil` without trying any path and without falling through, which
    ///    is the only reading consistent with exclusivity. A wrapper that
    ///    clears the variable to mean "no binaries" gets no binaries,
    ///    rather than the checkout's real ones.
    /// 2. `<executable dir>/../Resources/<name>` — the app bundle, where
    ///    `scripts/make-app-bundle.sh` copies every Go binary. The
    ///    executable lives in `Contents/MacOS`. There is no fallback out of
    ///    a bundle: layout 3 below stops at the first ancestor holding a
    ///    checkout marker, and an installed `Wakil.app` has none, so a
    ///    bundle missing a binary resolves to `nil` rather than reaching for
    ///    some other copy. That is why the bundle script must copy them.
    /// 3. `<checkout root>/bin/<name>`, where the checkout root is the
    ///    nearest ancestor of the executable directory (itself included)
    ///    holding a `go.mod` or an `app/Package.swift` — the dev checkout,
    ///    where the executable is at `app/.build/<config>/WakilApp` and
    ///    the binaries at `<repo>/bin`. An ancestor walk is used instead
    ///    of a fixed number of `..` hops because that number differs
    ///    between `swift build`'s symlinked and canonical output paths.
    ///
    ///    The marker is what bounds the walk. Only the first
    ///    marker-bearing ancestor's `bin/` is consulted, and the answer is
    ///    `nil` if that one lacks the binary or if `/` is reached without
    ///    finding a marker at all — the walk never tries a second `bin/`.
    ///    Unbounded, it ran past the checkout into `$HOME/bin`, so a
    ///    developer with a stale `~/bin/wakil-ctx` from an older install
    ///    got it spawned silently instead of a clean "not found".
    public static func binaryURL(
        named name: String,
        executableDirectory: URL,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        func executableAt(_ url: URL) -> URL? {
            fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }

        if let override = environment["WAKIL_BIN_DIR"] {
            guard !override.isEmpty else { return nil }
            return executableAt(URL(fileURLWithPath: override).appendingPathComponent(name))
        }

        if let bundled = executableAt(
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name))
        {
            return bundled
        }

        guard let root = checkoutRoot(above: executableDirectory, fileManager: fileManager) else { return nil }
        return executableAt(root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name))
    }

    /// The nearest ancestor of `directory` — `directory` itself counting
    /// as one — that holds a `go.mod` or an `app/Package.swift`, i.e. that
    /// looks like a Wakil checkout root. `nil` when the walk reaches `/`
    /// without finding one.
    ///
    /// This is the bound on layout 3 above. It is a marker rather than a
    /// depth limit or a stop at `$HOME` because the depth from the
    /// executable to the repo root is exactly what varies (symlinked vs.
    /// canonical `.build` paths), and because a checkout under `$HOME` has
    /// several unrelated ancestors below `$HOME` that a stop-at-home rule
    /// would still walk through.
    static func checkoutRoot(above directory: URL, fileManager: FileManager = .default) -> URL? {
        func holdsMarker(_ candidate: URL) -> Bool {
            fileManager.fileExists(atPath: candidate.appendingPathComponent("go.mod").path)
                || fileManager.fileExists(
                    atPath: candidate.appendingPathComponent("app", isDirectory: true)
                        .appendingPathComponent("Package.swift").path)
        }

        var candidate = directory.standardizedFileURL
        while candidate.path != "/" {
            if holdsMarker(candidate) { return candidate }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    /// The `diagnostics` line for a binary `binaryURL` could not resolve.
    ///
    /// Branched rather than one constant, because the layouts are not all
    /// consulted on every call and a message that names a path it did not
    /// try points the operator at the wrong fix. In particular, when
    /// `WAKIL_BIN_DIR` is set the lookup returns from that layer alone: the
    /// bundle and the checkout's `bin/` were not searched, and saying they
    /// were sends someone to check a directory whose contents are
    /// irrelevant instead of unsetting the override.
    static func notFoundDiagnostic(
        for name: String,
        executableDirectory: URL,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String {
        if let override = environment["WAKIL_BIN_DIR"] {
            let exclusivity =
                "WAKIL_BIN_DIR is exclusive — there is no fallback to the app bundle or a checkout's bin/; unset it to search those"
            guard !override.isEmpty else {
                return "\(name): not found (WAKIL_BIN_DIR is set and empty, so no path was tried at all; \(exclusivity))"
            }
            let tried = URL(fileURLWithPath: override).appendingPathComponent(name).path
            return "\(name): not found (\(tried) was the only path tried; \(exclusivity))"
        }

        let bundled = executableDirectory.deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name).path
        guard let root = checkoutRoot(above: executableDirectory, fileManager: fileManager) else {
            return """
                \(name): not found (tried \(bundled); no ancestor of \(executableDirectory.path) holds a go.mod or an \
                app/Package.swift, so no checkout bin/ was searched)
                """
        }
        let checkout = root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name).path
        return "\(name): not found (tried \(bundled), then \(checkout))"
    }

    /// The environment handed to a spawned Go binary, built key by key
    /// from `environment` rather than passed through wholesale — the same
    /// convention `buildLaunch` in `ClaudeCodeCLIHarness.swift` follows,
    /// for the same reason: what a child process sees should be a decision
    /// this code made, not whatever the launching shell happened to
    /// export.
    ///
    /// **`org` and `provider` are BOTH parameters, and for one reason.**
    /// Until 2b-vi neither was; that sub-phase made the provider a
    /// parameter because a live switch can change it mid-session, and
    /// 2b-viii does the same for the org for the same reason. Reading
    /// either from `environment` here would pin every spawned child to
    /// whatever the launching shell exported, stale the moment the
    /// operator switched. `HOME` and `PATH` are still read, because those
    /// genuinely are the launching process's to supply — an overridden
    /// `HOME` is what keeps a test's scratch tree effective across two
    /// process boundaries.
    ///
    /// Both are forwarded only when non-nil: absent means unset, never
    /// the empty string. An org-less window spawns org-less children,
    /// which `wakil-ctx` handles — it starts fine and fails only the
    /// calls that need an org (probe §3).
    static func childProcessEnvironment(
        from environment: [String: String], org: String?, provider: String?
    ) -> [String: String] {
        var childEnvironment: [String: String] = [
            "HOME": environment["HOME"] ?? NSHomeDirectory(),
            "PATH": environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        // **The window marker** (decisions.md, #187's amendment): `wakil-http`'s `send` refuses
        // every mutation unless this is exactly `1`, and this dictionary only ever reaches the
        // window's own children. #187 named it and left this line owed; until 2c-iv's walk sent
        // to a real server, every POST from a pane was refused. Always `1`, never forwarded.
        childEnvironment["WAKIL_IN_WINDOW"] = "1"
        if let org, !org.isEmpty { childEnvironment["WAKIL_ORG"] = org }
        if let provider, !provider.isEmpty { childEnvironment["WAKIL_PROVIDER"] = provider }
        // **`WAKIL_KEYCHAIN` is forwarded, not parameterised** — unlike the
        // org and the provider above, which are launch-time facts the window
        // can change mid-session and which therefore must not be read out of
        // this process. The keychain is the opposite: it is fixed for the
        // life of the process, nothing in the window can change it, and what
        // set it is the launcher. **So this is not an exception to 2b-vi's
        // ruling — it has a different subject.** That ruling is about facts
        // the window can change mid-session, which go stale the moment it
        // does; a keychain is not that kind of fact.
        //
        // **Why it has to be here at all (#301).** `wakilcore` reaches the
        // Keychain by invoking `/usr/bin/security` at its ABSOLUTE path,
        // because the item's ACL trusts that binary and no other — so a
        // `security` shim on PATH cannot redirect it and the keychain FILE
        // is named instead. This dictionary is built key by key, so a
        // variable not listed here is dropped at the process boundary. Left
        // out, the app's own Keychain calls would be isolated while every
        // server it spawns wrote to the operator's login keychain, and the
        // e2e isolation guard would pass, because PATH survives this
        // function and PATH is what it used to check.
        //
        // Absent means unset, never the empty string — the same rule the two
        // lines above hold themselves to. An empty value would be read
        // downstream as a keychain named "", where absent means the default.
        if let keychain = environment["WAKIL_KEYCHAIN"], !keychain.isEmpty {
            childEnvironment["WAKIL_KEYCHAIN"] = keychain
        }
        // Forwarded for the same reason as WAKIL_KEYCHAIN: fixed for the
        // life of the process and set by the launcher. Only tests and e2e
        // set it, to keep the capacity probe off the real API.
        if let base = environment["WAKIL_ANTHROPIC_BASE_URL"], !base.isEmpty {
            childEnvironment["WAKIL_ANTHROPIC_BASE_URL"] = base
        }
        return childEnvironment
    }

    /// The provider a client pinned to `place` is started with: the launch's, only when `place`
    /// is in the launch's org. Another org's gets none, as `switchOrg`'s restart does — a
    /// provider id from one org would mis-scope another's.
    static func pinnedProvider(for place: Place, launch environment: [String: String]) -> String? {
        guard let org = environment["WAKIL_ORG"], !org.isEmpty, place.organization == org else { return nil }
        return environment["WAKIL_PROVIDER"]
    }

    /// The environment a client pinned to `place` is started under: the window's own
    /// (`childProcessEnvironment`, with `place`'s organisation and the window marker) plus
    /// `WAKIL_PROJECT` — the registry key — and `WAKIL_ENVIRONMENT`, which the Go binaries
    /// honour over `active.json`. An empty member is left unset, never exported blank.
    public static func pinnedEnvironment(
        for place: Place, from environment: [String: String], provider: String?
    ) -> [String: String] {
        var pinned = childProcessEnvironment(from: environment, org: place.organization, provider: provider)
        if !place.project.isEmpty { pinned["WAKIL_PROJECT"] = place.project }
        if !place.environment.isEmpty { pinned["WAKIL_ENVIRONMENT"] = place.environment }
        return pinned
    }

    /// Re-points every Wakil-owned Go client at `org`, restarting their
    /// child processes in place.
    ///
    /// **In place, not replaced, and that is forced.**
    /// `registerStandardActions` closed every handler over THESE client
    /// instances, so a fresh `MCPClient` would leave the whole action set
    /// talking to a dead child. Restarting keeps the actor identity and
    /// swaps the process behind it.
    ///
    /// **This is stop-then-start, unlike `setProvider`'s start-then-swap,
    /// and spec §3.1 argues why.** In short: there is no new instance to
    /// prove healthy first, and a server start cannot fail *because of*
    /// the target org — probe §3 measured `wakil-ctx` handshaking with
    /// `WAKIL_ORG` unset entirely.
    ///
    /// **It iterates `wakilOwnedClients` rather than naming a pair**
    /// (#185). The hard-coded pair it used to loop over was a list that
    /// had to be kept in step by hand, and the cost of forgetting is not
    /// a stale read — it is org A's credential reachable from org B's
    /// window, which is Invariant 4 and which nothing would report.
    ///
    /// Returns one diagnostic line per client that did not come back.
    /// Empty means every one of them did.
    ///
    /// **A failed client is left stopped, not `nil`.** `stop()` clears the
    /// actor's own `process`; it does not — cannot — reach back into
    /// `registerStandardActions`'s captured `Optional<any ToolCaller>` and nil
    /// it out, so a subsequent action handler's `guard let client else {
    /// throw .missingClient }` still sees a client and does not fire.
    /// What actually throws is `MCPClient.call`'s own
    /// `guard let process, process.isRunning else { throw
    /// MCPClientError.notRunning }`. That is an honest signal, not a
    /// lesser one: `.notRunning` means the child process is dead, so
    /// nothing downstream of it can have executed — a firmer guarantee
    /// than the uncertain-mutation machinery (`mutationFateUnknown`,
    /// `recordUncertainMutation`) exists to express, and that machinery is
    /// not engaged here — `recordUncertainMutation` only acts on
    /// `mutationFateUnknown`, so `.notRunning` passes through it as a
    /// no-op, same as `.missingClient` would have.
    ///
    /// **THAT GUARANTEE INVERTS FOR `wakil-http`, and the paragraph above
    /// is true only of the other two** (#179, §*`wakil-http` in the
    /// window*; #185 put the third client in this loop). "Nothing
    /// downstream can have executed" holds for a database client killed
    /// mid-call because the statement never left the process. An HTTP
    /// send killed mid-flight may already have reached the server and
    /// changed something there — Wakil stopped waiting, it did not stop
    /// the request. #179 rules that an in-flight send **dies with the
    /// client and does not gate the switch, but is recorded
    /// fate-unknown**. Recording it is #187/#194's, not this function's;
    /// what is this function's is not claiming the stronger guarantee for
    /// a client it does not hold for.
    public func switchOrg(to org: String) async -> [String] {
        let childEnvironment = Self.childProcessEnvironment(
            from: launchEnvironment, org: org,
            // Deliberately nil: the new org's provider is not known yet.
            // refreshContext re-derives it (spec §5.3) and the next
            // harness carries it. A stale provider id from the outgoing
            // org would be worse than none.
            provider: nil)

        var diagnostics: [String] = []
        for (name, client) in wakilOwnedClients {
            guard let client else { continue }
            await client.stop()
            do {
                try await client.start(environment: childEnvironment)
            } catch {
                await client.stop()
                diagnostics.append("\(name) did not come back under \(org): \(error)")
            }
        }
        return diagnostics
    }
}

/// Why a pinned client did not start: its binary was not found, which `build`'s own
/// diagnostic for the same binary already names.
enum PlaceClientError: Error, CustomStringConvertible {
    case notFound(String)
    /// `PlaceClients.stopAll` has run: the window is closing and starts no more.
    case stopped(String)

    var description: String {
        switch self {
        case .notFound(let line): return line
        case .stopped(let binary): return "\(binary) was not started: this window's pinned clients are stopped"
        }
    }
}

/// Where the window's git status and the editor's git actions read the active project's roots: the window's `gitRootPaths` once
/// `WakilWiring.useActiveContext(of:)` has pointed it there, and `wakil-ctx`'s `get_context`
/// before that — the only source `--dispatch` ever has. `[]` when neither can answer, which
/// the actions treat as a project with no roots. The same lock-and-closure box as
/// `ActiveShellContext`, for the same reasons.
final class GitRootsSource: @unchecked Sendable {
    typealias Source = @Sendable () async -> [String]

    private let lock = NSLock()
    private var source: Source?
    private let context: MCPClient?

    init(context: MCPClient?) { self.context = context }

    func use(_ source: @escaping Source) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    func current() async -> [String] {
        if let source = installedSource() { return await source() }
        guard let context, let active = try? await ContextStore(client: context).current() else { return [] }
        return active.rootPaths
    }

    private func installedSource() -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return source
    }
}

/// What `pane_close` asks before it drops a pane: the titles of the pane's dirty editor tabs
/// (their path when they have one), empty for a pane that is not an editor. It lives here because
/// Layout may not know Editor; the assembly may.
func unsavedEditorTabsProbe(panes: PaneStore) -> @Sendable (String) async -> [String] {
    { id in
        let tabs = await panes.editorSnapshot(paneId: id).tabs
        let titles = editorTabTitles(tabs)
        return tabs.indices.filter { tabs[$0].dirty }.map { tabs[$0].path ?? titles[$0] }
    }
}
