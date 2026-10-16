import AppKit
import Foundation
import WakilKit
import SwiftUI

// MARK: - Session

/// One window's worth of assembled Wakil: the shared wiring, the MCP socket
/// the agent's shim connects back to, and the model the view draws.
///
/// It builds no registry, pane store or MCP client of its own: all four come
/// from `WakilWiring.build`, which is also what `--dispatch` calls — so an
/// action name that works in a debug script works in this window, because
/// there is exactly one action set and one place it is registered. What this
/// type adds on top is the socket, the harness and the model.
@MainActor
final class WindowSession {
    let wiring: WakilWiring
    let model: WindowModel
    /// 2d-ii: the composer bar's model — typed and spoken text land in it.
    let composer: ComposerModel
    /// Anything that did not come up cleanly at launch, as plain text for
    /// the window to show: a missing Go binary, no active provider chosen
    /// for this org yet, a socket that would not bind. None of these is
    /// fatal — the window still opens, and each failure is visible rather
    /// than silent.
    let notes: [String]

    private let socketServer: MCPSocketServer?

    private init(wiring: WakilWiring, model: WindowModel, composer: ComposerModel, socketServer: MCPSocketServer?, notes: [String]) {
        self.wiring = wiring
        self.model = model
        self.composer = composer
        self.socketServer = socketServer
        self.notes = notes
    }

    static func start() async -> WindowSession {
        let environment = ProcessInfo.processInfo.environment
        let sessionId = UUID().uuidString
        var notes: [String] = []

        // Same `HOME` convention as `--dispatch` in main.swift and as
        // `buildLaunch`: read the variable, not
        // `FileManager.homeDirectoryForCurrentUser`, which ignores an
        // overridden `HOME`.
        let home = environment["HOME"] ?? NSHomeDirectory()
        let journalDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)

        let wiring = await WakilWiring.build(journalDirectory: journalDirectory, sessionId: sessionId)
        notes.append(contentsOf: wiring.diagnostics)

        // The socket path carries the session id (spec §10's stale-socket
        // risk) and lives in the per-user temporary directory, which is the
        // closest thing an unsandboxed app has to §2.2's "the app's
        // container" and is itself mode 0700; `MCPSocketServer.start`
        // additionally binds the socket at 0700 and unlinks any stale file
        // first.
        //
        // It has to fit `sockaddr_un`'s `sun_path`, which
        // `makeUnixSocketAddress` rejects rather than truncates. Measured on
        // this machine: the temporary directory is 48 characters and the
        // whole path 96, against a 104-byte buffer — comfortable, but not
        // unlimited, which is why `MCPServerTests` deliberately uses `/tmp`
        // for its own longer test names. A path that did not fit surfaces as
        // a note below rather than a crash.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakil-\(sessionId).sock").path

        let executableDirectory = WakilWiring.defaultExecutableDirectory()
        // The file that is actually running: `Contents/MacOS/Wakil` in a
        // bundle, `app/.build/<config>/WakilApp` in a dev checkout. The
        // `--mcp-config` below re-spawns this same binary with `--mcp-shim`,
        // so it must name the real path rather than assume the bundle's
        // filename — under `swift run` the two differ.
        let executableURL = Bundle.main.executableURL
            ?? executableDirectory.appendingPathComponent("Wakil")
        // The project's first declared root AND the active provider both
        // come off one `get_context` call, read here once rather than
        // twice: `ActiveContext.rootPaths` (order is the operator's
        // declaration, and "first" is what a fresh session launches into,
        // per spec §5.1 — Swift does not re-derive this; resolving a root
        // declared relative to the project directory is `ProjectRootPaths`'
        // job in Go) and `ActiveContext.activeProvider` (2b-vi Task 7's
        // fourth axis on `active.json` — the persisted, switchable pick,
        // NOT `WAKIL_PROVIDER`, a launch-time fact `ContextStore`'s own
        // doc comment warns is a different field entirely). `contextClient`
        // may be `nil` (no `wakil-ctx` binary) or `current()` may throw (no
        // active project selected yet — `Resolve()` in Go requires one
        // before it will even look at `active.Provider`), and either way
        // this resolves to `nil` rather than guessing at either value.
        var activeContext: ContextStore.ActiveContext?
        if let contextClient = wiring.contextClient {
            activeContext = try? await ContextStore(client: contextClient).current()
        }
        let providerId = activeContext?.activeProvider ?? ""

        // A factory rather than a built instance: `WindowModel` calls this
        // once for the window's first session, again for every resume, and
        // (2b-vi Task 8/9) again for every provider switch — each of those
        // runs on a brand-new `ClaudeCodeCLIHarness` (`stop()` makes an
        // instance spent, and `events()` refuses a second consumer).
        //
        // Unlike 2b-v, this does NOT resolve credentials once here and
        // capture them: it takes a `ProviderSelection` as a parameter and
        // asks `lookup` for fresh credentials only when `WindowModel`
        // actually needs a harness, which is what lets an account switch
        // change what the NEXT harness runs under without rebuilding this
        // closure or relaunching the window.
        //
        // Both take the org as a parameter too, as of 2b-viii: a closure
        // that captured `environment["WAKIL_ORG"]` at window-open would
        // keep building the launch org's MCP config JSON and credentials
        // lookup for every harness after a live org switch, rather than
        // the org actually running by then.
        let harnessFactory: @Sendable (String, ProviderSelection) -> AgentHarness?
        let lookupFactory: @Sendable (String) -> ProviderCredentialsLookup
        // 2e (#204). Built beside `lookupFactory` because it needs the
        // same `wakil` executable and the same per-org construction: the
        // mint writes the credential that lookup later reads.
        let mintFactory: (@Sendable (String) -> any ProviderMinting)?
        do {
            guard let wakilExecutable = WakilWiring.binaryURL(
                named: "wakil", executableDirectory: executableDirectory, environment: environment)
            else {
                throw ProviderCredentialsLookupError.refused("wakil binary not found")
            }
            // No active provider is a legitimate state — a fresh install,
            // or an org that has never run a switch — but it used to be
            // treated as equivalent to a broken lookup: this whole `do`
            // block used to throw right here when `providerId` was empty,
            // which meant `lookup` and `harnessFactory` below were NEVER
            // built for a fresh org, and the `catch` installed the
            // deliberately-always-refusing `FailingCredentialsLookup`
            // instead. That is a dead end. `ctx_list_providers` needs no
            // active provider, so ⌘P still listed every registered
            // account — the operator could pick one, but `setProvider`
            // then asked the fake lookup for credentials and got the
            // canned refusal below, no matter which id it was asked for.
            // `lookup` and `harnessFactory` describe how to resolve
            // credentials and build a harness for a GIVEN id; neither one
            // depends on `providerId` (this window's CURRENT pick, which
            // is legitimately empty here). So they are built below
            // unconditionally, and the empty-`providerId` case is instead
            // handled as a plain note (below, after this `do`/`catch`)
            // and by `WindowModel.startHarness()`'s own guard, which
            // already refuses an empty `providerId` for the window's
            // FIRST turn with its own legible message — this file no
            // longer needs to pre-empt that by throwing.
            let wakilExe = wakilExecutable
            lookupFactory = { org in
                WakilCLICredentialsLookup(executable: wakilExe, organization: org)
            }
            // 2e (#204). The credential WRITE path, mirroring the read one
            // immediately above and resolved from the same executable.
            mintFactory = { org in
                WakilCLIProviderMint(executable: wakilExe, organization: org)
            }
            var mutableBinaries: [String: URL] = [:]
            for name in agentFacingServers {
                if let url = WakilWiring.binaryURL(
                    named: name, executableDirectory: executableDirectory, environment: environment) {
                    mutableBinaries[name] = url
                } else {
                    notes.append("\(name): not found, so the agent has no \(name) tools this session")
                }
            }
            // Reassigned to an immutable `let` before the `@Sendable`
            // closure below captures it: a captured `var` is a compile
            // error under strict concurrency, and this dictionary is
            // finished being built by this point anyway.
            let binaries = mutableBinaries
            // Derived from the registry that was just built, not from a
            // list written down here: the session's `--allowedTools` is what
            // keeps the CLI's permission layer from auto-denying the very
            // tools this config publishes (probe §6), so the two have to
            // describe the same surface. See `agentAllowedTools`.
            let allowedTools = agentAllowedTools(actions: await wiring.registry.all())
            harnessFactory = { org, selection in
                // Rebuilt per selection, never captured: this JSON carries
                // WAKIL_PROVIDER (and, as of 2b-viii, WAKIL_ORG) to every
                // MCP server, so reusing JSON captured at window open
                // would run the new account's session — or a post-switch
                // session's servers — with the old provider id or org.
                let configJSON = agentMCPConfigJSON(
                    shimExecutable: executableURL,
                    socketPath: socketPath,
                    binaries: binaries,
                    organization: org,
                    provider: selection.id)
                return ClaudeCodeCLIHarness(
                    claudePath: selection.credentials.claudePath,
                    configDir: selection.credentials.configDir,
                    oauthToken: selection.credentials.oauthToken,
                    mcpConfigJSON: configJSON,
                    allowedTools: allowedTools)
            }
        } catch {
            // The window opens without an agent rather than not at all: the
            // pane, the context labels and the dispatching controls are all
            // still usable, and the reason the text field cannot send is on
            // screen.
            notes.append("\(error)")
            harnessFactory = { _, _ in nil }
            // No `wakil` binary means no mint either: the add-an-account
            // flow needs the same executable the credential lookup does.
            // `nil` rather than a stub that always fails, because
            // `offerProviderLogin` then leaves the band alone instead of
            // walking the operator through two browser trips toward a
            // step that cannot run.
            mintFactory = nil
            // `WindowModel`'s designated initialiser requires a
            // `lookupFactory` even in this degraded case — it has no
            // default, deliberately (a defaulted lookup on a production
            // initialiser is exactly the quiet path this whole sub-phase
            // removes). This one repeats the real cause on every call
            // rather than silently succeeding with credentials that do
            // not work, which a placeholder "no provider" lookup would.
            lookupFactory = { _ in FailingCredentialsLookup(reason: "\(error)") }
        }

        // The honest degrade for the INITIAL launch of a fresh org: no
        // agent until an account is chosen, and the reason is on screen
        // from the window's first frame rather than only surfacing the
        // first time the operator tries to send something
        // (`WindowModel.startHarness()`'s own guard produces the matching
        // in-window message on that first `send`). It is deliberately NOT a
        // `throw` into the `catch` above — `lookup` and `harnessFactory`
        // are already built for real above, so picking a provider from ⌘P
        // resolves credentials for THAT id and succeeds, rather than
        // hitting the always-refusing `FailingCredentialsLookup` a throw
        // here used to force on every subsequent call regardless of which
        // id was asked for.
        //
        // IT IS NO LONGER A `notes` APPEND, and that was a defect rather
        // than a style: `notes` is fixed at launch, so the sentence
        // survived the ⌘P switch that made it false and sat contradicting
        // the account indicator (`shared-accounts-acceptance.md` D3). It is
        // `WindowModel.noActiveProviderNote` now — derived from the same
        // `providerId` the indicator reads, so the two cannot disagree —
        // and `WakilWindow` draws it beside these notes.

        // `rootPath` falls back to `home`, the same real and stable
        // directory the journal itself uses, and says so in a note,
        // because a window launched with no readable project cannot know
        // where to run.
        // The sentence that used to be appended here when there was no
        // root is `WindowModel.noProjectRootNote` now, derived from the
        // model's live context so it cannot outlive the project being
        // opened (2d-ii walk).
        var rootPath = home
        if let first = activeContext?.rootPaths.first {
            rootPath = first
        }

        let model = WindowModel(
            registry: wiring.registry,
            panes: wiring.panes,
            layout: wiring.layout,
            // `~/.wakil/layouts`, derived from the same `home` the journal
            // is, so an overridden `HOME` moves both together. This is the
            // only place a `LayoutPersistence` is constructed against a
            // real home directory; every test builds its own scratch one.
            persistence: LayoutPersistence(
                directory: LayoutPersistence.defaultDirectory(home: home)),
            context: wiring.contextClient.map(ContextStore.init(client:)),
            harnessFactory: harnessFactory,
            // One broker per window, shared with the agent's `session_resume`
            // handler via `wiring.resumes` — the same reasoning as
            // `confirmations` below: a window with a broker of its own would
            // mean the agent's `session_resume` calls, which park into
            // `wiring.resumes`, never reach this window's swap at all.
            resumes: wiring.resumes,
            rootPath: rootPath,
            providerId: providerId,
            lookupFactory: lookupFactory,
            // The load-bearing line: the window and the agent must park
            // into the *same* broker, or an agent's proposal would refuse
            // and never show up in this window's plane at all.
            confirmations: wiring.confirmations,
            // Same reasoning as `resumes` above: the window and the agent
            // (and `--dispatch`) must park `session_set_provider` requests
            // into the *same* broker. Unlike `resumes`, the agent can
            // never actually reach this one — `operatorOnlyActions` in
            // `PermissionPrompt.swift` denies it at the permission layer
            // before a call gets anywhere near this broker — but the
            // broker itself does not know that, and does not need to.
            providerSwitches: wiring.providerSwitches,
            // The model cannot reach `wiring` itself — it lives in
            // WakilKit and WakilWiring's clients are handed to it
            // individually — so the switch is injected as a closure here,
            // which is also what lets a test drive it without spawning a
            // child process.
            orgSwitcher: { [wiring] org in await wiring.switchOrg(to: org) },
            // The same instance `WakilWiring.build` registered
            // `term_open`/`term_propose`/`term_run` against — the model's
            // own run pump has to drain THIS store's `completedRuns()`,
            // not some other one, or a run that actually happened would
            // never be journalled.
            terminals: wiring.terminals,
            // 2e (#204). **Without this the mint is `nil` and the add
            // flow stalls silently at "signed in"** — `advanceToMint`
            // guards on it and returns, so the band sits on a state that
            // never advances and the operator is told nothing.
            //
            // Caught by running the app rather than by a test: every test
            // that drives the mint constructs a `ProviderLoginSession`
            // directly and hands it a fake, so none of them exercises
            // this wiring at all. The same shape as the `useActiveContext`
            // line below, which was found the same way.
            //
            // It takes the same executable `lookupFactory` above takes,
            // and for the same reason — `wakil provider mint` is the
            // credential WRITE path mirroring `wakil provider
            // credentials`, the read one. Organisation baked in at
            // construction, exactly as `WakilCLICredentialsLookup` bakes
            // it: a switch rebuilds the window.
            providerMintFactory: mintFactory,
            // #322: an organisation with no accounts still finds `claude`,
            // from the operator's own shell or a standard install location.
            claudeLocator: .live(),
            // 9b W1: every api pane re-resolves its entry on a switch and at launch. Without
            // this a round trip staging → production → staging leaves "no origin" on an entry
            // both declare; the e2e check `api-env-roundtrip` is what fails if it goes missing.
            apiResolver: wiring.apiResolver,
            // 2d-i. Without this every turn goes out with no hint and no
            // test notices: the parameter defaults to nil
            // (`wakil-never-wired-parameters`). `AppWiringTests` pins that
            // the store itself is built; this line is the hand-off.
            vocabulary: wiring.vocabulary,
            // 3a-i. What keeps a git pane live. This initialiser takes it with no default,
            // so leaving it out does not compile — the other way it could be lost is this
            // line passing something other than the wiring's, which `AppWiringTests`'
            // `theWatcherIsActuallyPassedIn` pins from the other side.
            rootWatcher: wiring.rootWatcher,
            editorRootWatcher: wiring.editorRootWatcher,
            // 3b-ii. The one file list the editor actions were registered with; the trees draw
            // it and the watcher invalidates it. No default, for `rootWatcher`'s reason.
            fileLists: wiring.fileLists,
            // The palette reads tables, API entries and changed files straight from these
            // clients, drawing no pane. No default, for `rootWatcher`'s reason. ⌘P's files come
            // from the same list as the trees, so the two never disagree.
            paletteClients: PaletteClients(
                database: wiring.databaseClient, http: wiring.httpClient, git: wiring.gitClient,
                files: wiring.fileLists.map { $0 as any ToolCaller } ?? wiring.filesClient))

        // `term_open` now has a window to ask for the active organisation,
        // project and environment — the three `WAKIL_*` keys a shell in a
        // pane is launched with. Before this line they were never
        // exported at all (final review, Critical 3). Asked on every
        // open, never captured: see `ActiveShellContext`.
        wiring.useActiveContext(of: model)
        let composer = ComposerModel(window: model, speech: wiring.speech)

        var socketServer: MCPSocketServer?
        let server = MCPSocketServer(
            // The registry *and* the pane store the window itself draws
            // from, as one value: `read_pane` answers the agent from the
            // same `PaneStore` `WindowModel.refreshPanes` reads, so what the
            // agent is told is on screen is what is on screen (Invariant 3).
            surface: wiring.mcpSurface,
            socketPath: socketPath,
            // The gate judges the same environment string the window shows.
            environmentProvider: { await model.environment })
        do {
            try await server.start()
            socketServer = server
        } catch {
            notes.append("MCP socket \(socketPath): \(error) — the agent cannot reach Wakil's own tools this session")
        }

        return WindowSession(wiring: wiring, model: model, composer: composer, socketServer: socketServer, notes: notes)
    }

    /// Stops the agent session, the MCP socket and every Wakil-owned Go child, in that
    /// order: the `claude` child — and with it the shim `claude` spawned —
    /// is gone before the socket that shim connects to is closed and
    /// unlinked.
    ///
    /// `wiring.shutdown()` is called for determinism rather than because
    /// the children would otherwise survive indefinitely; see its own doc
    /// comment for the measurement. Quitting closes the pipe feeding their
    /// stdin and both binaries exit on that EOF, so the normal case
    /// self-reaps. What stopping explicitly buys is the case that does not:
    /// a child in the middle of a slow tool call would not read that EOF
    /// promptly.
    func shutdown() async {
        await model.shutdown()
        await socketServer?.stop()
        await wiring.shutdown()
    }
}

/// Always refuses with `reason` — the `lookup` a window falls back to when
/// `start()`'s own `catch` fires (the `wakil` binary is missing, or no
/// active provider is set): `WindowModel`'s designated initialiser still
/// needs SOME `ProviderCredentialsLookup` to hold in that case, and this one
/// repeats the actual, already-diagnosed cause on every call rather than a
/// generic message that would be true for a different reason, or — worse —
/// silently succeeding with credentials that were never real.
private struct FailingCredentialsLookup: ProviderCredentialsLookup {
    let reason: String
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        throw ProviderCredentialsLookupError.refused(reason)
    }
}
