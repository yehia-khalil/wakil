import Foundation

/// The terminal pane's four actions, all `.control`.
///
/// **Why `.control` and not `.mutate`, which is the harder half.**
/// `.mutate` breaks twice. The gate `.gate`s it everywhere except
/// production, so every `ls` would cost a typed confirmation; and it
/// `.block`s in production regardless of origin, so the pane would die
/// exactly where an operator most wants a shell. Neither is survivable,
/// and the pane is not worth building under either.
///
/// **What that costs, stated rather than buried.** `.control` used to mean
/// *"the world outside Wakil is untouched"*, and for a shell run that is
/// false. It is redefined here as **"not gated by environment"**, and the
/// instrument protecting `term_run` is `operatorOnlyActions` plus the
/// in-pane `⏎`, **not** the write gate: a command typed by the operator
/// and submitted by hand is neither an unreviewed agent mutation nor an
/// unclassified statement, which is what the gate was built for. A fourth
/// `ActionKind` was the honest alternative and was rejected against the
/// code — two of `ActionKind`'s three consumers compare by equality rather
/// than switching, so `isMutation` would have gone silently false and the
/// confirmation plane would have stopped appearing.
///
/// `ActionKind`'s own doc comment was amended in Task 1 to say so.
public func registerTerminalActions(
    into registry: ActionRegistry,
    terminals: TerminalStore,
    panes: PaneStore,
    layout: LayoutStore?,
    activeContext: @escaping @Sendable () async
        -> (org: String, project: String, environment: String, rootPath: String)
        = { ("", "", "", "") }
) async {
    for action in terminalActions(
        terminals: terminals, panes: panes, layout: layout, activeContext: activeContext)
    {
        await registry.register(action)
    }
}

/// The terminal pane's four actions themselves, built synchronously so
/// `WindowModel.forTesting` — itself synchronous, for the reason
/// `ActionRegistry.init`'s `initialActions:` doc comment gives — can hand
/// them to that parameter without ever needing an `await`.
/// `registerTerminalActions` above is the async, production shape: it
/// registers each one into a live registry, which is the only thing a real
/// assembly (`WakilWiring.build`) or a test with its own registry needs.
func terminalActions(
    terminals: TerminalStore,
    panes: PaneStore,
    layout: LayoutStore?,
    // The active org, project and environment `term_open` folds into the
    // shell's own environment (`terminalChildEnvironment`) — three
    // variables, `WAKIL_ORG`/`WAKIL_PROJECT`/`WAKIL_ENVIRONMENT`, and
    // nothing else. **No secret is exported**: Keychain material stays
    // where it is until a later sub-phase says otherwise, and the prose
    // here said so wrongly until the two-axis review's Spec 2.
    //
    // `rootPath` rides alongside the three for a different reason
    // (walk-defects B1): it is `term_open`'s default `path` when the
    // caller names none, so ⌘K's param-less dispatch and the mouse's
    // "Open pane" precedent both have somewhere to open. Unlike the
    // three env vars, it is never actually empty when a window is wired —
    // `WindowModel.activeShellContext` already falls back to the
    // operator's home directory — but the handler falls back a second
    // time, to the same home, for the unwired default just below.
    //
    // **A closure, read at dispatch time, not a value captured here.**
    // These actions are registered once, before any window exists, and
    // the active context changes for the whole life of the app after
    // that; a captured value would pin every shell to the launch context.
    // `WakilWiring.build` passes `wiring.shellContext`'s own read and
    // `WindowSession.start` points that at the live window — see
    // `ActiveShellContext`.
    //
    // The always-empty default is what `--dispatch` and a test with no
    // window get: no org, project or environment folded in, and
    // `terminalChildEnvironment` leaves an empty member absent rather
    // than exporting it as an empty string. An empty `rootPath` here
    // means `term_open`'s own home-directory fallback applies instead.
    activeContext: @escaping @Sendable () async
        -> (org: String, project: String, environment: String, rootPath: String)
        = { ("", "", "", "") }
) -> [Action] {
    [
        Action(
            name: "term_open",
            description: "Open an interactive shell in a terminal pane, at a path. Names no pane "
                + "and one is opened and titled from the path — the same way a query opens a pane "
                + "and titles it by its database. path is OPTIONAL: omit it and the shell opens at "
                + "the active project's root, or the operator's home directory when no project is "
                + "active — the same default the operator gets opening a terminal from ⌘P or the "
                + "Landing, so a "
                + "call with no params still opens somewhere sensible. ANY path given is accepted, "
                + "including one outside every project root: this is a real PTY and `cd` walks out "
                + "of any fence, so refusing one would be theatre. The shell carries the active "
                + "organisation, project and environment — the context a credentialed command is "
                + "run against, and exactly why you may not run in it. It carries no secrets of its "
                + "own. Only zsh and bash are supported; anything else is refused here rather than "
                + "opened in a degraded mode. Opening on a pane that already has a shell kills that "
                + "shell and starts a new history. You can read this pane and propose into it; you "
                + "cannot run.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "pane": .object(["type": .string("string")]),
                    "shell": .object(["type": .string("string")]),
                ]),
                // No `required` key: `path` used to be the one required
                // param, and dropping it is B1's whole fix — a bare
                // `term_open {}` from ⌘K or the mouse must not fail the
                // way `pane_open {}` still correctly does for `kind`.
            ]),
            handler: { params in
                let context = await activeContext()
                // Omitted: the active project's root, else the operator's
                // home (walk-defects B1). `context.rootPath` already IS
                // that fallback when a window is wired
                // (`WindowModel.activeShellContext`); the `NSHomeDirectory()`
                // here only fires for the unwired default (`--dispatch`, a
                // bare registry in a test) where `context.rootPath` is `""`.
                let path = optionalString(params, "path")
                    ?? (context.rootPath.isEmpty ? NSHomeDirectory() : context.rootPath)
                let explicit = optionalString(params, "pane")
                try await requireOpenPane(explicit, action: "term_open", layout: layout)

                // The same helper `db_run_query` uses: name a pane and it is
                // retitled, name none and one is opened. The terminal titles
                // by the path rather than by a database.
                let title = terminalPaneTitle(forPath: path)
                let resolved = await resolveTerminalPane(
                    explicit: explicit, title: title, path: path, layout: layout)

                // `terminals.open` is the single writer of this pane's fresh
                // history — it already calls `panes.clearTerminal` and
                // `panes.setTerminalLiveState` itself once the shell spawns
                // (`TerminalStore.performOpen`). A second, redundant pair here
                // used to race the store's own publisher task: once `open()`
                // returns, that task can call `panes.recordTerminal` for the
                // new shell's first block concurrently with this handler's own
                // `clearTerminal`, which would wipe a block the store had just
                // recorded. Removed rather than reordered, so there is exactly
                // one writer.
                let opened = try await terminals.open(
                    paneId: resolved,
                    path: path,
                    shell: optionalString(params, "shell") ?? TerminalStore.defaultShell(),
                    environment: terminalChildEnvironment(
                        org: context.org, project: context.project,
                        environment: context.environment))
                return .object([
                    "pane": .string(resolved),
                    "shell": .string(opened.shell),
                    "cwd": .string(opened.cwd),
                ])
            }
        ),

        Action(
            name: "term_propose",
            description: "Propose a command into a terminal pane. It is drawn as a block that has "
                + "NOT run, at the tail of the history directly above the operator's prompt — where "
                + "its output would appear. The operator's Enter puts it in their own prompt UNRUN, "
                + "and a second Enter runs it: two keystrokes, deliberately. At most one proposal "
                + "is pending per pane; proposing again replaces it, and the replacement is "
                + "journalled, so you cannot silently swap the command under a hand already moving "
                + "to Enter. Read the pane to find out what happened to it: a block with origin "
                + "\"proposed\" is still waiting, one with origin \"operator\" carrying your command "
                + "was accepted and run, and neither means it was discarded.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pane": .object(["type": .string("string")]),
                    "command": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("pane"), .string("command")]),
            ]),
            handler: { params in
                let pane = try requireString(params, "pane", action: "term_propose")
                let command = try requireString(params, "command", action: "term_propose")
                try await requireOpenPane(pane, action: "term_propose", layout: layout)
                await panes.setTerminalProposal(paneId: pane, TerminalBlock(
                    id: "\(pane)-proposal", command: command, origin: .proposed,
                    exitCode: nil, durationMs: nil, output: [], heldTheGrid: false,
                    startedAt: Date()))
                return .object(["pane": .string(pane), "command": .string(command)])
            }
        ),

        Action(
            name: "term_run",
            description: "OPERATOR ONLY. Records that a command was submitted in a terminal pane "
                + "and how it ended. You cannot call this: the shell in that pane carries the "
                + "active organisation, project and environment, and running there would put you "
                + "inside the credential boundary that context establishes — not buy you reach, "
                + "since you already have a shell of your own outside Wakil. Use term_propose and "
                + "the operator's Enter.",
            kind: .control,
            audience: .operatorOnly,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pane": .object(["type": .string("string")]),
                    "command": .object(["type": .string("string")]),
                    "cwd": .object(["type": .string("string")]),
                    // The active organisation and project the run happened
                    // under. `environment`, the third member, is
                    // `JournalEntry`'s own column and is not repeated here;
                    // these two have no column and would otherwise be
                    // recorded nowhere (two-axis review, Spec 3).
                    "org": .object(["type": .string("string")]),
                    "project": .object(["type": .string("string")]),
                    // "proposed" (by the agent, accepted by the operator) or
                    // "typed". Materially different events, and after the
                    // fact the journal is the only place the difference
                    // survives.
                    "accepted": .object(["type": .string("string")]),
                    "exitCode": .object(["type": .string("number")]),
                    "durationMs": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("pane"), .string("command")]),
            ]),
            handler: { params in
                // The journal entry IS the work: `dispatch` writes it, and the
                // shell has already run the command. This handler exists so
                // that the run passes through the one chokepoint Invariant 2
                // names, and so ⌘K lists it as a thing that happened.
                let pane = try requireString(params, "pane", action: "term_run")
                return .object(["pane": .string(pane)])
            }
        ),

        Action(
            name: "term_scroll",
            description: "Bring one block of a terminal pane's history into view, by its id as "
                + "read_pane reports it. It takes a BLOCK ID and not a row index, deliberately: "
                + "`row` means a zero-based position in a displayed order that a sort changes, a "
                + "terminal has no sort, and a block id is stable while a position is not — the "
                + "block cap shifts every position each time it trims. Omit `block` to clear a "
                + "pending target; the pane does that itself once it has scrolled, so the same "
                + "block can be asked for again. This scrolls the block history; while a "
                + "full-screen program holds the screen the history is parked, and the target "
                + "waits for it.",
            kind: .control,
            audience: .agentReachable,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pane": .object(["type": .string("string")]),
                    "block": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("pane")]),
            ]),
            handler: { params in
                let pane = try requireString(params, "pane", action: "term_scroll")
                try await requireOpenPane(pane, action: "term_scroll", layout: layout)
                guard let block = optionalString(params, "block") else {
                    await panes.setTerminalScrollTarget(paneId: pane, blockId: nil)
                    return .object(["pane": .string(pane), "block": .null])
                }
                guard await panes.terminalBlocks(paneId: pane).contains(where: { $0.id == block })
                else {
                    throw LayoutActionError.badParam(
                        action: "term_scroll", param: "block", value: block)
                }
                await panes.setTerminalScrollTarget(paneId: pane, blockId: block)
                return .object(["pane": .string(pane), "block": .string(block)])
            }
        ),
    ]
}

/// The pane a terminal belongs in, opening one when none was named — and
/// retitling it when it was.
///
/// **The `resolvePane` analogue for a terminal pane, not `resolvePane`
/// itself**, because that helper's "open a new one" branch hardcodes
/// `kind: "db"` — `db_run_query`'s own pane kind. The rule it embodies —
/// name a pane and it is retitled, name none and one is opened — is what
/// this repeats for `"terminal"`.
///
/// Returns the literal `"terminal"` when there is no layout to open a
/// pane in — `--dispatch` and tests with no `LayoutStore` — which mirrors
/// `resolvePane`'s own fallback for the same case.
///
/// `path` is recorded on the pane alongside `title` — `Pane.terminalPath`,
/// walk-defects B2 — so a dead pane's Reopen control (`TerminalPane.swift`)
/// has somewhere to reopen at even after the shell that opened it is gone.
/// Named a pane is retitled AND repathed: `term_open` on an existing pane
/// with a new path means the pane now lives somewhere else, exactly as
/// its title already says so.
func resolveTerminalPane(
    explicit: String?, title: String, path: String, layout: LayoutStore?
) async -> String {
    if let named = queryTargetPane(explicit: explicit, layout: nil) {
        await layout?.retitle(id: named, to: title)
        await layout?.setTerminalPath(id: named, to: path)
        return named
    }
    guard let layout else { return "terminal" }
    return await layout.open(kind: "terminal", title: title, terminalPath: path).id
}

/// The last path component, or the path itself at the root. `~` for home,
/// because that is what the operator calls it.
///
/// **A name, not an inference.** Wakil never guesses what a pane is
/// showing from its contents — the rule `queryTargetPane` states in the
/// operator's own words about SQL — and a path is a name the caller
/// already supplied.
func terminalPaneTitle(forPath path: String) -> String {
    let standardized = (path as NSString).standardizingPath
    if standardized == NSHomeDirectory() { return "~" }
    let last = (standardized as NSString).lastPathComponent
    return last.isEmpty ? standardized : last
}
