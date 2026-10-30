import Testing
import Foundation
@testable import WakilKit

/// `WakilWiring.binaryURL` decides where the bundled Go binaries are, and
/// it has to be right in two layouts that no single test run can exercise
/// at once: the app bundle Task 11's `make-app-bundle.sh` assembles, and
/// the dev checkout the suite itself runs from. Both are built here as
/// scratch directory trees, so neither depends on where this process
/// happens to live.

private func scratch() throws -> URL {
    let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Creates an executable stand-in file (contents irrelevant — nothing here
/// runs it; `binaryURL` only asks whether it is an executable file).
private func makeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func binaryResolutionFindsTheBundleLayout() throws {
    let root = try scratch()
    let macOS = root.appendingPathComponent("Wakil.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let bundled = root.appendingPathComponent("Wakil.app/Contents/Resources/wakil-ctx")
    try makeExecutable(at: bundled)

    let found = WakilWiring.binaryURL(named: "wakil-ctx", executableDirectory: macOS, environment: [:])
    #expect(found?.path == bundled.path)
}

/// Builds the dev-checkout shape: `app/.build/debug` for the executable,
/// `bin/` for the Go binaries, and the `go.mod` that marks the root as a
/// checkout (without which the ancestor walk will not consult that `bin/`
/// at all — see `binaryResolutionStopsTheAncestorWalkAtTheCheckoutRoot`).
private func makeCheckout(marker: String = "go.mod") throws -> (root: URL, exeDir: URL) {
    let root = try scratch()
    let exeDir = root.appendingPathComponent("app/.build/debug")
    try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
    let markerURL = root.appendingPathComponent(marker)
    try FileManager.default.createDirectory(
        at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("module example.com/wakil\n".utf8).write(to: markerURL)
    return (root, exeDir)
}

@Test func binaryResolutionFindsTheDevCheckoutLayout() throws {
    let (root, exeDir) = try makeCheckout()
    let devBinary = root.appendingPathComponent("bin/wakil-db")
    try makeExecutable(at: devBinary)

    let found = WakilWiring.binaryURL(named: "wakil-db", executableDirectory: exeDir, environment: [:])
    #expect(found?.path == devBinary.path)
}

/// `app/Package.swift` marks a checkout root as well as `go.mod` does —
/// this repo has both, and either alone is enough.
@Test func binaryResolutionAcceptsPackageSwiftAsTheCheckoutMarker() throws {
    let (root, exeDir) = try makeCheckout(marker: "app/Package.swift")
    let devBinary = root.appendingPathComponent("bin/wakil-ctx")
    try makeExecutable(at: devBinary)

    let found = WakilWiring.binaryURL(named: "wakil-ctx", executableDirectory: exeDir, environment: [:])
    #expect(found?.path == devBinary.path)
}

/// The bound on the ancestor walk. An unmarked directory tree with a
/// `bin/wakil-ctx` sitting above the executable is the shape of a stale
/// `~/bin/wakil-ctx` from an older install: the walk must not reach it,
/// because spawning it is a silent version mismatch where "not found" is
/// the honest answer. The marker one level down is what the walk stops at,
/// so the outer `bin/` is never consulted even though it is on the path to
/// `/`.
@Test func binaryResolutionStopsTheAncestorWalkAtTheCheckoutRoot() throws {
    let outer = try scratch()
    let strayBinary = outer.appendingPathComponent("bin/wakil-ctx")
    try makeExecutable(at: strayBinary)

    // No marker anywhere: the stray binary is above the executable and
    // still must not be found.
    let unmarkedExeDir = outer.appendingPathComponent("checkout/app/.build/debug")
    try FileManager.default.createDirectory(at: unmarkedExeDir, withIntermediateDirectories: true)
    #expect(WakilWiring.binaryURL(named: "wakil-ctx", executableDirectory: unmarkedExeDir, environment: [:]) == nil)

    // A marked checkout below it whose own `bin/` lacks the binary: the
    // walk stops there and answers nil rather than continuing outward and
    // returning the stray one.
    let marked = outer.appendingPathComponent("marked")
    let markedExeDir = marked.appendingPathComponent("app/.build/debug")
    try FileManager.default.createDirectory(at: markedExeDir, withIntermediateDirectories: true)
    try Data("module example.com/wakil\n".utf8).write(to: marked.appendingPathComponent("go.mod"))
    let found = WakilWiring.binaryURL(named: "wakil-ctx", executableDirectory: markedExeDir, environment: [:])
    #expect(found == nil, "the walk should stop at \(marked.path), not reach \(strayBinary.path)")
}

@Test func binaryResolutionReturnsNilRatherThanCrashingWhenNothingIsThere() throws {
    let root = try scratch()
    #expect(WakilWiring.binaryURL(named: "wakil-db", executableDirectory: root, environment: [:]) == nil)
}

/// `WAKIL_BIN_DIR` must be exclusive, not merely first: a test that points
/// it at an empty scratch directory is doing so to guarantee no real Go
/// binary gets spawned, and a fallback to the checkout's `bin/` would
/// spawn one anyway.
@Test func binaryResolutionTreatsTheEnvironmentOverrideAsExclusive() throws {
    let (root, exeDir) = try makeCheckout()
    try makeExecutable(at: root.appendingPathComponent("bin/wakil-db"))
    let emptyOverride = try scratch()

    // Without the override this resolves — so the nil below is the
    // override's exclusivity, not an unfindable checkout.
    #expect(WakilWiring.binaryURL(named: "wakil-db", executableDirectory: exeDir, environment: [:]) != nil)

    let found = WakilWiring.binaryURL(
        named: "wakil-db", executableDirectory: exeDir, environment: ["WAKIL_BIN_DIR": emptyOverride.path])
    #expect(found == nil)
}

/// `WAKIL_BIN_DIR=""` means "set, exclusive, and holding nothing" — not
/// "unset". A wrapper clearing the variable to disable the Go binaries
/// would otherwise get the checkout's real ones spawned.
@Test func binaryResolutionTreatsAnEmptyEnvironmentOverrideAsSet() throws {
    let (root, exeDir) = try makeCheckout()
    try makeExecutable(at: root.appendingPathComponent("bin/wakil-db"))

    #expect(WakilWiring.binaryURL(named: "wakil-db", executableDirectory: exeDir, environment: [:]) != nil)
    #expect(WakilWiring.binaryURL(
        named: "wakil-db", executableDirectory: exeDir, environment: ["WAKIL_BIN_DIR": ""]) == nil)
}

/// 2d-i: the wiring builds a vocabulary over ITS registry, so Wakil's own
/// action names resolve once a context is known — `pane move` finds
/// `pane_move`. A store built over some other registry, or none at all,
/// would answer nothing here.
@Test func wiringBuildsAVocabularyThatResolvesWakilsOwnActionNames() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path]
    )
    #expect(await wiring.vocabulary.current().names(folded: "panemove").isEmpty, "no context yet")

    await wiring.vocabulary.contextChanged(
        ContextStore.ActiveContext(org: "test-org", project: "p", environment: "staging"))
    await wiring.vocabulary.waitForAllBuilds()
    let names = await wiring.vocabulary.current().names(folded: "panemove")
    await wiring.shutdown()

    #expect(names.contains { $0.text == "pane_move" && $0.source == .wakil })
}

/// A wiring built with no binaries available still registers the full 2a
/// action set plus the 2b-i layout actions (Task 10 added
/// `registerLayoutActions` to `build`) — the property that turns a missing
/// binary into a per-action "no database MCP client was provided" instead
/// of "unknown action".
@Test func wiringRegistersEveryStandardActionEvenWithNoBinariesPresent() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path]
    )
    // Nothing was spawned (both clients are nil), so this stops nothing —
    // it is here because every `build` call should be paired with one.
    await wiring.shutdown()

    // db_run_mutation added by Phase 2b-iii — Wakil's first `.mutate` action.
    // session_set_provider added by Phase 2b-vi Task 8 (fix round 1).
    // ctx_set_provider added by Phase 2b-vi Task 9 — the persistence write
    // `WindowModel.setProvider` dispatches after a successful swap.
    // ctx_list_providers added by Phase 2b-vi Task 12 — the picker's own
    // source of what an org has registered to switch to.
    // pane_select_cell, pane_select_rows, pane_sort, pane_set_column_width
    // and pane_scroll_to_row added by Phase 2c-i Task 7 — the five actions
    // that drive a pane's contents, dual-driven the same as its geometry.
    // pane_scroll_clear added by Phase 2c-i Task 10 — the data surface's own
    // way of clearing the scroll target it just honoured, so the same row
    // can be asked for again.
    // db_list_tables, db_describe_table and db_read_table added by Phase
    // 2c-ii Task 10 — the schema browser drawn on the same grid, no new view.
    // db_refetch, db_page and db_classify_statement added by Phase 2c-ii
    // Task 11 — the one re-fetch path (`refetchPane`) and the two actions
    // that drive it, plus the classification action the query line needs.
    // ctx_list_orgs, ctx_create_org, ctx_list_machine_providers and
    // ctx_adopt_provider added by Phase 2b-viii Task 13 — the org plane's
    // four Go-side tools, registered here and made operator-only (see
    // `operatorOnlyActions` in `PermissionPrompt.swift`).
    // term_open added by Phase 2c-iii Task 10 — the terminal pane's first
    // action: a shell has to exist before anything else in the pane can
    // run.
    // term_propose and term_run added by Phase 2c-iii Task 11 — the
    // agent's way of handing the operator a command without running it,
    // and the journal entry a submitted command is recorded by.
    // term_scroll added by Phase 2c-iii Task 13 — the fourth and last
    // terminal action, bringing a block into view by its id rather than a
    // row index.
    // api_open added by Phase 2c-iv #188 — the api client pane's first
    // action, and the only one of its eight this ticket ships: a pane has
    // to exist, and be pointed at an entry, before a request can be built
    // in it.
    // api_set_request added by Phase 2c-iv #190 — the draft is written by
    // ONE action and not ten, every region optional and absent meaning
    // unchanged, so the operator's one-region edit and the agent's whole
    // request are literally the same call. This list is an EQUALITY
    // assertion on purpose — an entry that grants more than the registry
    // does is as much a drift as one that grants less — so a name joins it
    // by hand, deliberately, and `api_send` will not join it at all: a
    // `.mutate` action is structurally off the allow list and reaches the
    // gate instead.
    // ctx_config_tree and settings_open added by Phase 2e (#198) — the
    // settings pane's one read, and the one way that pane is opened.
    // `ctx_config_tree` is `.read` and agent-reachable, because Decision
    // 30 rules the agent may READ settings and drive nothing on it;
    // `settings_open` is `.control` and operator-only, which is the
    // driving half. This is the assembly that ships, so both appear.
    // api_bind and api_unbind added by Phase 1 of the 2c-iv send-path plan
    // (#192). Both are `.read` and agent-reachable: they take a row that is
    // already on screen and write it into a draft on the same screen —
    // nothing leaves the process and nothing is sent. They join the allow
    // list for the reason `api_set_request` does, and `api_send` still will
    // not: a `.mutate` action is structurally off it and reaches the gate.
    // api_fill_from_curl and api_undo_fill added by Amendment 11: `.control` and
    // agent-reachable on api_set_request's terms — they write a draft and send nothing.
    #expect(await wiring.registry.all().map(\.name).sorted() ==
            ["api_bind", "api_cancel", "api_fill_from_curl", "api_open", "api_remove_entry",
             "api_render_curl", "api_reopen", "api_request", "api_send", "api_set_entry",
             "api_set_request", "api_unbind", "api_undo_fill", "api_update_entry",
             // 3c-i: the browser's actions.
             // 3c-ii: the agent's reach into the page (read_page, click, press, revoke_site, scroll, select, type).
             "browser_back", "browser_bookmark", "browser_clear_data", "browser_click", "browser_close_tab", "browser_copy_url", "browser_download_cancel", "browser_downloads_clear", "browser_find", "browser_find_close", "browser_find_step", "browser_focus_address", "browser_forward", "browser_group", "browser_move_tab", "browser_navigate", "browser_new_tab", "browser_open", "browser_password_delete", "browser_password_fill", "browser_password_never", "browser_password_save", "browser_password_suggest", "browser_pin", "browser_press", "browser_print", "browser_pull_requests_refresh", "browser_read_page", "browser_reload", "browser_rename_tab", "browser_reopen_tab", "browser_restore", "browser_revoke_site", "browser_scroll", "browser_select", "browser_select_tab", "browser_stop", "browser_tab_column", "browser_type", "browser_unpin", "browser_zoom",
             "capacity_record", "conversation_move", "conversation_rename", "ctx_add_provider", "ctx_adopt_provider", "ctx_browser_settings", "ctx_capacity",
             "ctx_config_tree", "ctx_config_tree_for",
             "ctx_connection_add", "ctx_connection_allow_set", "ctx_connection_catalog", "ctx_connection_remove", "ctx_connection_secrets_set", "ctx_connection_signin_start", "ctx_connection_signin_wait", "ctx_connection_signout", "ctx_connection_update",
             "ctx_create_environment", "ctx_create_org", "ctx_create_project",
             "ctx_editor_settings", "ctx_git_account_add", "ctx_git_account_remove", "ctx_git_account_test", "ctx_git_api_access_remove",
            "ctx_git_api_access_test", "ctx_git_api_access_token_set", "ctx_git_device_poll",
             "ctx_git_device_start", "ctx_git_gh_import", "ctx_git_gh_logins", "ctx_git_host_suggestions",
             "ctx_git_key_generate", "ctx_git_key_passphrase_set", "ctx_git_ssh_keys", "ctx_git_token_set", "ctx_github_pull_requests", "ctx_jira_token_set", "ctx_keyboard", "ctx_list_accounts",
             "ctx_list_environments", "ctx_list_machine_providers", "ctx_list_orgs",
             "ctx_list_projects", "ctx_list_providers", "ctx_provider_login", "ctx_remove_environment",
             "ctx_remove_project", "ctx_rename_environment", "ctx_rename_project",
             "ctx_set_browser_settings", "ctx_set_editor_settings", "ctx_set_environment", "ctx_set_key", "ctx_set_keys", "ctx_set_local_provider", "ctx_set_project", "ctx_set_project_agent_instructions",
             "ctx_set_project_editor_settings", "ctx_set_project_pm_key", "ctx_set_provider",
             "ctx_unlink_provider", "ctx_update_org", "db_cancel", "db_classify_statement",
             "db_describe_table",
             "db_list_databases", "db_list_tables", "db_page", "db_read_table", "db_refetch",
             "db_remove_database",
             "db_render_update", "db_run_mutation", "db_run_query", "db_set_connection", "db_set_dsn", "db_update_database",
             "editor_blame", "editor_changes_abort", "editor_changes_amend", "editor_changes_branch_create", "editor_changes_branch_delete", "editor_changes_branch_rename", "editor_changes_branches", "editor_changes_collapse", "editor_changes_commit", "editor_changes_continue", "editor_changes_discard", "editor_changes_draft_message",
             "editor_changes_expand", "editor_changes_fetch", "editor_changes_group_collapse", "editor_changes_group_expand",
             "editor_changes_keep_file", "editor_changes_merge",
             "editor_changes_publish", "editor_changes_pull", "editor_changes_push", "editor_changes_rebase",
             "editor_changes_select", "editor_changes_skip", "editor_changes_stage", "editor_changes_stage_hunk", "editor_changes_stage_ranges",
             "editor_changes_stash", "editor_changes_stash_apply", "editor_changes_stash_drop", "editor_changes_stash_drop_all", "editor_changes_stash_pop", "editor_changes_stash_undo_apply", "editor_changes_stashes", "editor_changes_step", "editor_changes_switch", "editor_changes_sync", "editor_changes_take", "editor_changes_undo_commit", "editor_changes_unstage", "editor_changes_unstage_ranges",
             "editor_clone", "editor_close", "editor_conflict_accept", "editor_conflict_compare", "editor_conflict_next", "editor_conflict_previous", "editor_create", "editor_find", "editor_focus_tab", "editor_goto", "editor_move_tab", "editor_new_scratch", "editor_open", "editor_open_commit_diff", "editor_open_file",
             "editor_open_stash_diff", "editor_peek", "editor_peek_close", "editor_peek_step", "editor_refresh", "editor_reload", "editor_rename", "editor_replace", "editor_replace_range", "editor_replace_undo", "editor_restore", "editor_save",
             "editor_search", "editor_select", "editor_set_language", "editor_timeline", "editor_trash", "editor_tree", "editor_tree_collapse",
             "editor_tree_expand", "editor_tree_reveal", "files_search",
             "pane_close", "pane_focus", "pane_maximize", "pane_move",
             "pane_open", "pane_resize", "pane_restore", "pane_scroll_clear",
             "pane_scroll_to_row", "pane_select_cell", "pane_select_rows",
             "pane_set_column_width", "pane_set_density", "pane_snap", "pane_sort",
             "rail_set", "review_open", "review_reply_draft", "review_reply_draft_restore", "review_reply_send", "review_resolve", "review_step",
             "running_detect", "running_draft_all", "running_draft_propose", "running_read", "running_save", "running_secret_set",
             "running_try", "running_try_end",
             "session_close", "session_get", "session_list", "session_new", "session_read",
             "session_record_parent", "session_resume", "session_set_provider", "session_switch", "settings_open", "term_open",
             "term_propose", "term_run", "term_scroll",
             "ticket_hand_off", "ticket_hand_off_brief", "ticket_hand_off_cancel", "ticket_hand_off_close", "ticket_hand_off_open",
             "ticket_in_flight", "ticket_link", "ticket_open", "ticket_read", "ticket_record_update", "ticket_refresh", "ticket_show",
             "workspace_archive", "workspace_bring_home", "workspace_build", "workspace_list", "workspace_restore",
             "workspace_run", "workspace_running", "workspace_set_environment", "workspace_start", "workspace_stop"])
    #expect(wiring.contextClient == nil)
    #expect(wiring.databaseClient == nil)
    // #185 made `wakil-http` the third Wakil-owned client, so three
    // missing binaries are reported where two were. Derived from
    // `wakilOwnedClients` rather than hard-coded, so the next client to
    // join does not have to find this line: the property under test is
    // "every Wakil-owned binary that could not be found is NAMED", and
    // that is what is written.
    #expect(wiring.httpClient == nil)
    #expect(wiring.wakilOwnedClients.allSatisfy { $0.client == nil })
    #expect(wiring.diagnostics.count == wiring.wakilOwnedClients.count,
            "every missing binary should be reported: \(wiring.diagnostics)")
    for (name, _) in wiring.wakilOwnedClients {
        #expect(wiring.diagnostics.contains { $0.hasPrefix("\(name):") },
                "\(name) missing from \(wiring.diagnostics)")
    }
}

/// `WakilWiring.mcpSurface` must hand out *this* assembly's three halves,
/// and it is now the only way outside `WakilKit` to obtain an `MCPSurface`
/// at all: the memberwise initialiser is `internal`, so `MCPSocketServer`
/// can no longer be handed one assembly's registry beside another's pane
/// store or layout store. That mismatch is the silent one — `tools/call`
/// would dispatch correctly while `read_pane`/`read_layout` reported a
/// permanently empty pane or canvas — so what is asserted here is identity,
/// not equality: the same three actor instances, not three that merely look
/// alike.
///
/// This test cannot state the access-control half; `@testable import` lifts
/// `internal` to `public` for the test target by design, so the compiler is
/// what enforces it and only against code outside the module (`WakilApp`,
/// which builds as part of every `swift build`).
@Test func theMCPSurfaceIsThisAssemblysOwnRegistryAndPaneStore() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path]
    )
    await wiring.shutdown()

    let surface = wiring.mcpSurface
    #expect(surface.registry === wiring.registry)
    #expect(surface.panes === wiring.panes)
    #expect(surface.layout === wiring.layout)
}

/// The environment handed to a spawned Go binary is built key by key, so
/// an overridden `HOME` reaches `wakil-ctx` (which is what keeps a
/// scratch `HOME` effective across the process boundary) while unrelated
/// variables do not.
@Test func childEnvironmentForwardsOnlyTheKeysItMeansTo() {
    let child = WakilWiring.childProcessEnvironment(
        from: [
            "HOME": "/scratch/home",
            "PATH": "/usr/bin",
            "WAKIL_ORG": "stale",
            "ANTHROPIC_API_KEY": "should-not-be-forwarded",
        ], org: "acme", provider: nil)
    #expect(child["HOME"] == "/scratch/home")
    #expect(child["WAKIL_ORG"] == "acme")
    #expect(child["ANTHROPIC_API_KEY"] == nil)
    #expect(child["WAKIL_PROVIDER"] == nil)
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_ORG", "WAKIL_IN_WINDOW"])
}

/// The window marker (decisions.md, #187's amendment): `wakil-http`'s `send` refuses every
/// mutation unless `WAKIL_IN_WINDOW` is exactly `1`, and the window is the only process meant to
/// set it. #187 named the variable and left the setter owed; nothing added it, so every POST from
/// a pane was refused as "not started by the Wakil window" — found on 2c-iv's walk, the first
/// send to reach a real server. Set unconditionally, and to `1` rather than whatever the
/// launching process carried: a forwarded `0` must not survive into the child.
@Test func childEnvironmentMarksEveryChildAsTheWindows() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_IN_WINDOW": "0"], org: nil, provider: nil)
    #expect(child["WAKIL_IN_WINDOW"] == "1")
}

/// 2b-vi Task 6: the running provider can change mid-session, so this
/// process's own `WAKIL_PROVIDER` — a launch-time fact — must not decide
/// what a freshly spawned child sees. The caller passes the CURRENT
/// selection explicitly instead; this pins that the parameter wins even
/// when the environment carries a stale, different value.
@Test func childEnvironmentTakesTheProviderAsAParameterNotFromTheEnvironment() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "stale", "WAKIL_PROVIDER": "stale"],
        org: "acme", provider: "current")
    #expect(child["WAKIL_PROVIDER"] == "current")
    #expect(child["WAKIL_ORG"] == "acme")
}

@Test func childEnvironmentOmitsTheProviderWhenThereIsNone() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p"], org: nil, provider: nil)
    #expect(child["WAKIL_PROVIDER"] == nil)
}

/// 2b-viii: the org can also change mid-session, so this process's own
/// `WAKIL_ORG` must not decide what a freshly spawned child sees either.
/// The caller passes the CURRENT org explicitly; this pins that the
/// parameter wins even when the environment carries a stale value.
@Test func childEnvironmentTakesTheOrgAsAParameterNotFromTheProcess() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "stale"],
        org: "live", provider: "acct")
    #expect(child["WAKIL_ORG"] == "live")
    #expect(child["WAKIL_PROVIDER"] == "acct")
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_ORG", "WAKIL_PROVIDER", "WAKIL_IN_WINDOW"])
}

@Test func childEnvironmentOmitsTheOrgWhenThereIsNone() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ORG": "stale"],
        org: nil, provider: nil)
    #expect(child["WAKIL_ORG"] == nil)
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_IN_WINDOW"])
}

/// #301. `WAKIL_KEYCHAIN` is what scopes every Keychain call a Go child
/// makes, and this dictionary is built key by key — so a variable not
/// named here is dropped at the process boundary however carefully the
/// launcher set it.
///
/// That is what the e2e harness hit. `wakilcore` invokes
/// `/usr/bin/security` by absolute path (the item's ACL trusts that
/// binary and no other), so the fixture cannot redirect it with a shim on
/// PATH and names the keychain instead. Forwarded to the app and dropped
/// here, the app's own credential reads would have been isolated while
/// every server it spawns wrote to the operator's login keychain — with
/// the isolation guard passing, because PATH survives this function.
@Test func childEnvironmentForwardsTheKeychainSelector() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_KEYCHAIN": "/f/fixture.keychain-db"],
        org: "acme", provider: nil)
    #expect(child["WAKIL_KEYCHAIN"] == "/f/fixture.keychain-db")
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_ORG", "WAKIL_KEYCHAIN", "WAKIL_IN_WINDOW"])
}

/// Absent means unset, never the empty string — the rule this function
/// already holds itself to for the org and the provider it forwards. An
/// exported `WAKIL_KEYCHAIN=""` is how a shipped Wakil addresses the
/// default keychain, and passing it on as an empty string would have the
/// child read it as a keychain named "".
@Test func childEnvironmentOmitsTheKeychainSelectorWhenThereIsNone() {
    let child = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_KEYCHAIN": ""], org: nil, provider: nil)
    #expect(child["WAKIL_KEYCHAIN"] == nil)
    #expect(Set(child.keys) == ["HOME", "PATH", "WAKIL_IN_WINDOW"])
}

// MARK: - `WakilWiring.switchOrg`

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // app/Tests/WakilKitTests/AppWiringTests.swift
        .deletingLastPathComponent()          // WakilKitTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // app
        .deletingLastPathComponent()          // repo root
}

/// Writes a minimal `~/.wakil` project fixture for `org` directly under
/// `home`, one project named `project` and nothing else — enough for
/// `ctx_list_projects` to answer with exactly that name.
private func writeSwitchOrgFixture(home: URL, org: String, project: String) throws {
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)
    let projectDir = orgDir.appendingPathComponent("proj-\(project)")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let projectPath = projectDir.appendingPathComponent("project.json")
    let projectJSON = """
        {"name":"\(project)","org":"\(org)","roots":[{"path":"/tmp/\(project)"}],\
        "scopes":{},"environments":{"dev":{"databases":[]}}}
        """
    try projectJSON.write(to: projectPath, atomically: true, encoding: .utf8)
    let registryJSON = "{\"\(project)\":{\"path\":\"\(projectPath.path)\"}}"
    try registryJSON.write(to: orgDir.appendingPathComponent("projects.json"), atomically: true, encoding: .utf8)
}

/// Dispatches `ctx_list_projects` through `registry` and returns the set of
/// project names in `structuredContent.projects` — a JSON object keyed by
/// name (`wakilcore.ProjectListing.Projects`), the same shape
/// `WindowModelTests.swift`'s `paletteListsEveryProjectInTheActiveOrg`
/// parses.
private func listedProjectNames(_ registry: ActionRegistry) async throws -> Set<String> {
    let result = try await registry.dispatch(
        name: "ctx_list_projects", params: .object([:]), origin: .debug,
        caller: .test("dev"), confirmation: nil)
    guard case .object(let top) = result,
          case .object(let structured)? = top["structuredContent"],
          case .object(let projects)? = structured["projects"]
    else {
        return []
    }
    return Set(projects.keys)
}

/// `switchOrg` restarts both clients under the environment this wiring was
/// BUILT with, so a scratch `HOME` handed to `WakilWiring.build` rides across
/// the restart like everything else in it.
///
/// **This fixture used to live under the real `NSHomeDirectory()`** (#321),
/// because `switchOrg` read `ProcessInfo.processInfo.environment` and a
/// scratch `HOME` could not reach it. The directories leaked into the
/// operator's `~/.wakil`, forty of them, and a live Wakil read them
/// half-written during a walk. A scratch `HOME` makes this test prove the
/// fix as well: under the old `switchOrg`, org B is looked up in the real
/// home, is not there, and the second listing is not `beta-project`.
@Test func switchOrgRePointsTheClientToTheNewOrgsData() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")

    let home = try scratch()
    let orgA = "switch-org-test-a-\(UUID().uuidString)"
    let orgB = "switch-org-test-b-\(UUID().uuidString)"
    try writeSwitchOrgFixture(home: home, org: orgA, project: "alpha-project")
    try writeSwitchOrgFixture(home: home, org: orgB, project: "beta-project")

    let journal = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": orgA,
            "WAKIL_BIN_DIR": bin.deletingLastPathComponent().path,
        ])
    #expect(wiring.contextClient != nil, "\(wiring.diagnostics)")

    #expect(try await listedProjectNames(wiring.registry) == ["alpha-project"])

    let diagnostics = await wiring.switchOrg(to: orgB)
    #expect(diagnostics.isEmpty, "\(diagnostics)")

    // The whole point: a subsequent call answers for the NEW org, not the
    // old one and not neither — proving the restart re-pointed the client
    // rather than merely surviving it.
    #expect(try await listedProjectNames(wiring.registry) == ["beta-project"])

    await wiring.shutdown()
}

/// The failure half: a client whose restart cannot succeed is left
/// stopped, and `switchOrg` names it rather than staying silent.
///
/// Constructed without touching any production code: `wiring` is built
/// against a COPY of the real `wakil-ctx` binary in a scratch
/// `WAKIL_BIN_DIR`, so the first start succeeds exactly as normal. The
/// copy is then deleted before `switchOrg` runs, so the restart's
/// `Process.run()` fails the same way a binary that vanished mid-session
/// would — `switchOrg` never learns why a client cannot come back, only
/// that it didn't. No `wakil-db` binary is placed in the scratch
/// directory, so `databaseClient` is `nil` from the start and `switchOrg`
/// skips it (its `guard let client else { continue }`), leaving exactly
/// one client for the diagnostic to be about.
@Test func switchOrgNamesAClientThatDoesNotComeBackAndLeavesItStopped() async throws {
    let realCtx = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: realCtx.path), "run `make build` first")

    let scratchBin = try scratch()
    let copiedCtx = scratchBin.appendingPathComponent("wakil-ctx")
    try FileManager.default.copyItem(at: realCtx, to: copiedCtx)

    let journal = try scratch()
    let home = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": "acme",
            "WAKIL_BIN_DIR": scratchBin.path,
        ])
    #expect(wiring.contextClient != nil, "\(wiring.diagnostics)")
    #expect(wiring.databaseClient == nil)

    // The copy vanishes before the restart, so the next `start()` cannot
    // spawn anything at all.
    try FileManager.default.removeItem(at: copiedCtx)

    let diagnostics = await wiring.switchOrg(to: "beta")
    #expect(diagnostics.count == 1, "\(diagnostics)")
    #expect(diagnostics.first?.contains("wakil-ctx") == true, "\(diagnostics)")
    #expect(diagnostics.first?.contains("beta") == true, "\(diagnostics)")

    // Left stopped, not `nil`-equivalent through the action set (the
    // point of `switchOrg`'s corrected doc comment): the client instance
    // is still there, but a call against it throws `.notRunning` rather
    // than silently succeeding or throwing `.missingClient`.
    do {
        _ = try await wiring.contextClient!.listTools()
        Issue.record("expected .notRunning once switchOrg failed to restart the client")
    } catch MCPClientError.notRunning {
        // expected
    } catch {
        Issue.record("expected MCPClientError.notRunning, got \(error)")
    }
}

// MARK: - Every Wakil-owned client joins the org switch (#185)

/// **The list that had to be kept in step by hand, and now cannot be.**
///
/// `switchOrg` restarted a hard-coded pair of clients. `wakil-http` joins
/// them in 2c-iv, and the cost of forgetting a client is not a stale read
/// — it is org A's credential reachable from org B's window, Invariant 4,
/// and nothing anywhere would report it. So the switch iterates
/// `wakilOwnedClients`, and this test is what makes that collection the
/// single place a client can be forgotten.
///
/// It reflects over `WakilWiring`'s own stored properties rather than
/// naming the three: a fourth client declared on the type and left out of
/// `wakilOwnedClients` fails here, which is precisely the mistake the
/// hard-coded pair invited. The same construction as
/// `everyWindowModelPropertyIsClassifiedForTheOrgSwitch`, for the same
/// reason — a credential boundary must not depend on somebody remembering.
@Test func everyWakilOwnedClientJoinsTheOrgSwitch() async throws {
    let journal = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal, sessionId: "s1",
        environment: ["HOME": try scratch().path, "PATH": "/usr/bin:/bin"])
    defer { shutdownSynchronously(wiring) }

    let declared = declaredClientProperties(of: wiring)
    // Sanity: reflection must actually be finding them, or this test
    // passes by seeing nothing.
    #expect(declared == ["contextClient", "databaseClient", "filesClient", "gitClient", "httpClient", "ticketClient"],
            "WakilWiring's MCPClient properties are \(declared)")
    #expect(wiring.wakilOwnedClients.count == declared.count,
            "a client is declared on WakilWiring and missing from wakilOwnedClients, so an org switch would leave it pointed at the outgoing org and shutdown would orphan it")
    #expect(Set(wiring.wakilOwnedClients.map(\.name))
            == ["wakil-ctx", "wakil-db", "wakil-files", "wakil-git", "wakil-http", "wakil-ticket"])
}

/// Every `MCPClient?` stored property of `wiring`, by name, sorted.
///
/// **Matched on the property's TYPE, not on `is MCPClient?`.** `is T?`
/// returns true for ANY nil Optional whatever its element type (measured:
/// a nil `String?` satisfies `is A?`), so the obvious spelling would count
/// an unrelated `let something: String?` as a client — and the failure it
/// then produced would allege a credential-boundary hole that does not
/// exist. A tripwire that cries wolf on an unrelated edit is a tripwire
/// that gets widened. `type(of:)` is exact for both nil and non-nil.
private func declaredClientProperties(of wiring: WakilWiring) -> [String] {
    Mirror(reflecting: wiring).children.compactMap { child -> String? in
        guard var label = child.label else { return nil }
        if label.hasPrefix("_") { label.removeFirst() }
        guard type(of: child.value) == MCPClient?.self else { return nil }
        return label
    }.sorted()
}

/// `defer` cannot `await`, and `defer { Task { await … } }` is an
/// unstructured task nothing waits on — so teardown may simply never run.
private func shutdownSynchronously(_ wiring: WakilWiring) {
    let done = DispatchSemaphore(value: 0)
    Task { await wiring.shutdown(); done.signal() }
    done.wait()
}

/// **Four Wakil-owned, and the count is stated rather than left to be
/// inferred.** `agentFacingServers` holds the three the HARNESS spawns; this
/// assembly owns four. `wakil-git` is on both lists (3a-i): it answers and
/// never touches a pane, so the agent reads git directly (Invariant 9) while
/// the pane's own reads go through the registry and this assembly's copy.
@Test func theAgentReachesNoPaneAffectingServerDirectly() {
    // **This pin changed meaning in 2c-iv rather than changing value.** It
    // used to say "this is how the agent's MCP config is wired". It now
    // says: `wakil-http` is in the window, and a pane's send must stay a
    // registry action. Adding it here would let the agent put a POST on
    // the wire without passing the write gate — Invariant 2's single code
    // path for pane state, and Invariant 7's confirmation, both bypassed
    // in one edit that would look like enabling a feature.
    #expect(agentFacingServers == ["wakil-pm", "wakil-recall", "wakil-git"])
    for owned in ["wakil-ctx", "wakil-db", "wakil-http"] {
        #expect(!agentFacingServers.contains(owned),
                "\(owned) affects pane state; the registry must be its only caller")
    }
}

/// The pid half: after a switch, every Wakil-owned client is a NEW
/// process. "Restarted in place" is a claim about the process behind an
/// actor whose identity deliberately does not change, so nothing else
/// distinguishes a client that came back from one that was never stopped.
@Test func everyWakilOwnedClientIsANewProcessAfterAnOrgSwitch() async throws {
    let binDir = repoRoot().appendingPathComponent("bin")
    for name in ["wakil-ctx", "wakil-db", "wakil-files", "wakil-git", "wakil-http", "wakil-ticket"] {
        try #require(
            FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent(name).path),
            "run `make build` first — \(name) missing")
    }

    let home = try scratch()
    let orgA = "pid-switch-a-\(UUID().uuidString)"
    let orgB = "pid-switch-b-\(UUID().uuidString)"
    try writeSwitchOrgFixture(home: home, org: orgA, project: "alpha-project")
    try writeSwitchOrgFixture(home: home, org: orgB, project: "beta-project")

    let journal = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal, sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": orgA,
            "WAKIL_BIN_DIR": binDir.path,
        ])
    defer { shutdownSynchronously(wiring) }

    // The reflection check again, against a wiring whose clients are all
    // NON-nil — the cheap test above runs with three nils, so on its own
    // it could not tell a type match from the nil quirk it was written to
    // avoid.
    #expect(declaredClientProperties(of: wiring)
            == ["contextClient", "databaseClient", "filesClient", "gitClient", "httpClient", "ticketClient"])
    #expect(wiring.wakilOwnedClients.count == 6)

    var before: [String: Int32] = [:]
    for (name, client) in wiring.wakilOwnedClients {
        let pid = await client?.processIdentifier
        #expect(pid != nil, "\(name) did not start: \(wiring.diagnostics)")
        before[name] = pid
    }
    #expect(before.count == 6, "every Wakil-owned client starts eagerly")

    let diagnostics = await wiring.switchOrg(to: orgB)
    #expect(diagnostics.isEmpty, "\(diagnostics)")

    for (name, client) in wiring.wakilOwnedClients {
        let after = await client?.processIdentifier
        #expect(after != nil, "\(name) did not come back")
        #expect(after != before[name],
                "\(name) kept pid \(String(describing: before[name])) across the switch — it is still the outgoing org's process")
    }

    // And teardown reaches all of them. `shutdown()` named the same
    // hard-coded pair `switchOrg` did, so a client could join the org
    // switch and still be orphaned by `--dispatch`'s `exit()` — the
    // failure message above claims teardown is covered, and this is what
    // makes that claim true rather than asserted.
    await wiring.shutdown()
    for (name, client) in wiring.wakilOwnedClients {
        let pid = await client?.processIdentifier
        #expect(pid == nil, "\(name) survived shutdown() as pid \(String(describing: pid))")
    }
}

// MARK: - 3a-i: wakil-git, rootPaths and the watcher

/// `wakil-git` joins the clients this assembly owns — so an org switch restarts it and
/// `shutdown` stops it — and the editor's git actions (3b-iii) are registered whether or not its
/// binary was found, failing per action when it was not.
@Test func wakilGitIsAWakilOwnedClientAndItsActionsAreRegistered() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "s1",
        executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path]
    )
    await wiring.shutdown()

    #expect(wiring.wakilOwnedClients.map(\.name).contains("wakil-git"))
    #expect(wiring.gitClient == nil)
    #expect(wiring.diagnostics.contains { $0.hasPrefix("wakil-git:") }, "\(wiring.diagnostics)")
    let names = Set(await wiring.registry.all().map(\.name))
    for name in ["editor_changes_select", "editor_changes_step", "editor_changes_collapse",
                 "editor_changes_expand", "editor_changes_group_collapse", "editor_changes_group_expand",
                 "editor_open_file"] {
        #expect(names.contains(name), "\(name) is not registered")
    }
}

/// `rootPath` is `rootPaths.first`, so every consumer that predates 3a-i — `term_open`'s
/// default path, the harness's launch directory, the no-root note — sees what it saw before.
@MainActor
@Test func windowModelKeepsTheFirstRootForEveryExistingConsumer() async throws {
    let model = WindowModel.forTesting(
        scratchRoot: testScratchRoot,
        context: ContextStore(client: GitRootsContext(roots: ["/p/api", "/p/portal"])))
    await model.refreshContext()

    #expect(model.rootPaths == ["/p/api", "/p/portal"])
    #expect(model.rootPath == "/p/api")
    #expect(model.rootPathForTesting == "/p/api")
    #expect(model.activeShellContext.rootPath == "/p/api")
    #expect(model.gitRootPaths == ["/p/api", "/p/portal"])
    #expect(model.noProjectRootNote == nil)
}

/// The never-wired-injectable guard (`wakil-never-wired-parameters`). The wiring builds the
/// window's watcher — a real one — and the initialiser `WindowSession.start` calls takes it
/// with no default, so leaving it out does not compile; this pins that what is passed is what
/// the window holds.
@MainActor
@Test func theWatcherIsActuallyPassedIn() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal, sessionId: "s1", executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path])
    defer { shutdownSynchronously(wiring) }
    #expect(wiring.rootWatcher is FSEventsRootWatcher)

    let model = WindowModel(
        registry: wiring.registry, panes: wiring.panes, layout: wiring.layout,
        context: wiring.contextClient.map(ContextStore.init(client:)),
        harnessFactory: { _, _, _ in nil }, resumes: wiring.resumes,
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in FailingLookupForWiringTests() },
        rootWatcher: wiring.rootWatcher, editorRootWatcher: wiring.editorRootWatcher,
        fileLists: wiring.fileLists, gitStatus: wiring.gitStatus,
        paletteClients: PaletteClients(), placeClients: wiring.placeClients,
        agentSocketFactory: { _, _ in NoAgentSocket() }, quickModelFactory: nil)
    let held = try #require(model.rootWatcherForTesting as? FSEventsRootWatcher)
    #expect(held === (wiring.rootWatcher as? FSEventsRootWatcher))
}

/// 3b-iii: the status the window shows and the actions read is built over the wiring's own `wakil-git`,
/// routed by place.
@MainActor
@Test func theStatusIsTheOneTheActionsRead() async throws {
    let binDir = repoRoot().appendingPathComponent("bin")
    try #require(
        FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent("wakil-git").path),
        "run `make build` first — wakil-git missing")
    let wiring = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "s1",
        environment: ["HOME": try scratch().path, "PATH": "/usr/bin:/bin", "WAKIL_BIN_DIR": binDir.path])
    defer { shutdownSynchronously(wiring) }
    let client = try #require(wiring.gitClient, "\(wiring.diagnostics)")
    // Routed (background agents, 2 of 4): an agent's diff and baseline reads go to a client pinned
    // to its own place, and every other read to the window's — this one.
    let routed = try #require(wiring.gitStatus.git as? PlaceRoutedCaller)
    #expect(routed.role == .git)
    let held = try #require(routed.window as? MCPClient)
    #expect(held === client)
}

/// 3b-ii: the wiring builds one `EditorFileLists` over `wakil-files` whenever the client is up,
/// and the window holds that same list — the one its editor actions and ⌘P read — rather than
/// none, which would leave every tree empty with nothing failing (`wakil-never-wired-parameters`).
@MainActor
@Test func theFileListIsBuiltWithTheFilesClientAndPassedIn() async throws {
    let binDir = repoRoot().appendingPathComponent("bin")
    try #require(
        FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent("wakil-files").path),
        "run `make build` first — wakil-files missing")
    let journal = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal, sessionId: "s1",
        environment: ["HOME": try scratch().path, "PATH": "/usr/bin:/bin", "WAKIL_BIN_DIR": binDir.path])
    defer { shutdownSynchronously(wiring) }
    #expect(wiring.filesClient != nil, "\(wiring.diagnostics)")
    let lists = try #require(wiring.fileLists)

    let model = WindowModel(
        registry: wiring.registry, panes: wiring.panes, layout: wiring.layout,
        context: wiring.contextClient.map(ContextStore.init(client:)),
        harnessFactory: { _, _, _ in nil }, resumes: wiring.resumes,
        rootPath: "/tmp", providerId: "",
        lookupFactory: { _ in FailingLookupForWiringTests() },
        rootWatcher: wiring.rootWatcher, editorRootWatcher: wiring.editorRootWatcher,
        fileLists: wiring.fileLists, gitStatus: wiring.gitStatus,
        paletteClients: PaletteClients(), placeClients: wiring.placeClients,
        agentSocketFactory: { _, _ in NoAgentSocket() }, quickModelFactory: nil)
    #expect(model.fileListsForTesting === lists)

    let emptyBin = try scratch()
    let without = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "s2", executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path])
    defer { shutdownSynchronously(without) }
    #expect(without.filesClient == nil && without.fileLists == nil)
}

private struct FailingLookupForWiringTests: ProviderCredentialsLookup {
    func credentials(forProvider id: String) async throws -> ProviderCredentials {
        throw ProviderCredentialsLookupError.refused("wiring test")
    }
}

/// 3a-iii walk row 1: the launcher's switch for file remotes reaches wakil-git; only `1` is forwarded.
@Test func childEnvironmentForwardsTheFileRemoteSwitch() {
    let env = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_GIT_ALLOW_FILE": "1"], org: "initech", provider: "main")
    #expect(env["WAKIL_GIT_ALLOW_FILE"] == "1")
    let other = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_GIT_ALLOW_FILE": "yes"], org: "initech", provider: "main")
    #expect(other["WAKIL_GIT_ALLOW_FILE"] == nil)
}

@Test func childEnvironmentForwardsTheAnthropicBaseURL() {
    let env = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ANTHROPIC_BASE_URL": "http://127.0.0.1:4545"],
        org: "initech", provider: "main")
    #expect(env["WAKIL_ANTHROPIC_BASE_URL"] == "http://127.0.0.1:4545")
    let without = WakilWiring.childProcessEnvironment(from: ["HOME": "/h", "PATH": "/p"], org: "initech", provider: "main")
    #expect(without["WAKIL_ANTHROPIC_BASE_URL"] == nil)
    let empty = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_ANTHROPIC_BASE_URL": ""], org: "initech", provider: "main")
    #expect(empty["WAKIL_ANTHROPIC_BASE_URL"] == nil)
}

/// The e2e GitHub stub reaches the window's wakil-ticket only through this: set, it is forwarded;
/// unset or empty, it is absent and the child calls GitHub's own API.
@Test func childEnvironmentForwardsTheGitHubAPI() {
    let env = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_GITHUB_API": "http://127.0.0.1:4646/graphql"],
        org: "initech", provider: "main")
    #expect(env["WAKIL_GITHUB_API"] == "http://127.0.0.1:4646/graphql")
    let without = WakilWiring.childProcessEnvironment(from: ["HOME": "/h", "PATH": "/p"], org: "initech", provider: "main")
    #expect(without["WAKIL_GITHUB_API"] == nil)
    let empty = WakilWiring.childProcessEnvironment(
        from: ["HOME": "/h", "PATH": "/p", "WAKIL_GITHUB_API": ""], org: "initech", provider: "main")
    #expect(empty["WAKIL_GITHUB_API"] == nil)
}

/// Background agents, 2 of 4: an agent's dispatch reaches a client pinned to its own place,
/// through the registry `build` itself assembled. **The guard against a `register*` call in
/// `build` being handed a window client instead of a routed one**: every unit test of the router
/// builds its own `PlaceRoutedCaller`, so only a test through `build` notices that. The real
/// `wakil-ctx` behind both, two orgs in a scratch `HOME`: the window's client answers org A's
/// projects, and a pinned one org B's.
@Test func anAgentsDispatchThroughTheBuiltRegistryReachesTheClientPinnedToItsPlace() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")

    let home = try scratch()
    let orgA = "place-route-test-a-\(UUID().uuidString)"
    let orgB = "place-route-test-b-\(UUID().uuidString)"
    try writeSwitchOrgFixture(home: home, org: orgA, project: "alpha-project")
    try writeSwitchOrgFixture(home: home, org: orgB, project: "beta-project")

    let wiring = await WakilWiring.build(
        journalDirectory: try scratch(),
        sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": orgA,
            "WAKIL_BIN_DIR": bin.deletingLastPathComponent().path,
        ])
    #expect(wiring.contextClient != nil, "\(wiring.diagnostics)")
    let onScreen = Place(organization: orgA, project: "alpha-project", environment: "dev")
    let away = Place(organization: orgB, project: "beta-project", environment: "dev")

    func projects(as place: Place, session: String?) async throws -> Set<String> {
        let result = try await wiring.registry.dispatch(
            name: "ctx_list_projects", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: place, session: session), confirmation: nil)
        guard case .object(let top) = result,
              case .object(let structured)? = top["structuredContent"],
              case .object(let projects)? = structured["projects"]
        else { return [] }
        return Set(projects.keys)
    }

    #expect(try await projects(as: onScreen, session: nil) == ["alpha-project"])
    #expect(try await projects(as: away, session: "s1") == ["beta-project"])
    // And the window's own client was never re-pointed for it.
    #expect(try await projects(as: onScreen, session: nil) == ["alpha-project"])
    // The operator's dispatch stays on the window's client even when the place it carries is
    // another org's: it starts nothing.
    #expect(try await projects(as: away, session: nil) == ["alpha-project"])
    #expect(await wiring.placeClients.startedRoles(for: away) == [.context])

    await wiring.shutdown()
}

/// The switch race, end to end: `setProject` writes `active.json` before the window's `place`
/// moves. An agent pinned to the old project calling in between must get the old project's
/// answer from its pinned `wakil-ctx`, not the new one's from the window's, which already
/// reads the rewritten file.
@Test func anAgentCallingMidSwitchIsAnsweredForItsOwnPlace() async throws {
    let bin = repoRoot().appendingPathComponent("bin/wakil-ctx")
    try #require(FileManager.default.isExecutableFile(atPath: bin.path), "run `make build` first")

    let home = try scratch()
    let org = "place-race-test-\(UUID().uuidString)"
    let orgDir = home.appendingPathComponent(".wakil/orgs/\(org)")
    var registry: [String: JSONValue] = [:]
    var paths: [String: String] = [:]
    for (project, environment) in [("alpha", "staging"), ("beta", "production")] {
        let dir = orgDir.appendingPathComponent("proj-\(project)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("project.json")
        try """
            {"name":"\(project)","org":"\(org)","roots":[{"path":"/tmp/\(project)"}],\
            "scopes":{},"environments":{"\(environment)":{"databases":[]}}}
            """.write(to: path, atomically: true, encoding: .utf8)
        registry[project] = .object(["path": .string(path.path)])
        paths[project] = path.path
    }
    try JSONEncoder().encode(JSONValue.object(registry))
        .write(to: orgDir.appendingPathComponent("projects.json"))
    // `setProject` has already written the new project; the screen has not caught up.
    try #"{"project":"\#(paths["beta"]!)","environment":"production"}"#
        .write(to: orgDir.appendingPathComponent("active.json"), atomically: true, encoding: .utf8)

    let wiring = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": org,
            "WAKIL_BIN_DIR": bin.deletingLastPathComponent().path,
        ])
    #expect(wiring.contextClient != nil, "\(wiring.diagnostics)")
    let staging = Place(organization: org, project: "alpha", environment: "staging")

    func environments(session: String?) async throws -> Set<String> {
        let result = try await wiring.registry.dispatch(
            name: "ctx_list_environments", params: .object([:]), origin: .agent,
            caller: DispatchCaller(place: staging, session: session), confirmation: nil)
        guard case .object(let top) = result,
              case .object(let structured)? = top["structuredContent"],
              case .object(let environments)? = structured["environments"]
        else { return [] }
        return Set(environments.keys)
    }

    #expect(try await environments(session: "s1") == ["staging"])
    // The window's own client already answers for the new project.
    #expect(try await environments(session: nil) == ["production"])

    await wiring.shutdown()
}

/// Every role `build` registers is routed: an agent's cheap call through each reaches a client
/// pinned to its place, so a `register*` call regressing to a raw window client fails here.
@Test func everyRoleTheBuiltRegistryCallsIsRoutedForAnAgent() async throws {
    let binDir = repoRoot().appendingPathComponent("bin")
    for role in ClientRole.allCases {
        try #require(FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent(role.rawValue).path),
                     "run `make build` first")
    }
    let home = try scratch()
    let orgA = "place-roles-test-a-\(UUID().uuidString)"
    let orgB = "place-roles-test-b-\(UUID().uuidString)"
    try writeSwitchOrgFixture(home: home, org: orgA, project: "alpha-project")
    try writeSwitchOrgFixture(home: home, org: orgB, project: "beta-project")
    let wiring = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "s1",
        environment: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "WAKIL_ORG": orgA, "WAKIL_BIN_DIR": binDir.path,
        ])
    for role in ClientRole.allCases {
        #expect(wiring.wakilOwnedClients.first { $0.name == role.rawValue }?.client != nil, "\(wiring.diagnostics)")
    }
    let api = await wiring.layout.open(kind: "api", title: "api")
    let editor = await wiring.layout.open(kind: "editor", title: "editor")
    wiring.gitRoots.use { ["/tmp"] }
    let away = Place(organization: orgB, project: "beta-project", environment: "dev")

    // Each call may fail past the client — none of these is configured — but it has reached one.
    let calls: [(ClientRole, String, JSONValue)] = [
        (.context, "ctx_list_projects", .object([:])),
        (.database, "db_list_databases", .object([:])),
        (.http, "api_fill_from_curl", .object(["pane": .string(api.id), "text": .string("curl http://x")])),
        // 3b-iii: git is reached through the editor; a diff tab's fetch is its own flight, so the
        // check below waits for it.
        (.git, "editor_changes_select", .object([
            "pane": .string(editor.id), "root": .string("/tmp"), "path": .string("x"), "group": .string("changed"),
        ])),
        (.files, "files_search", .object(["query": .string("needle")])),
        // Ticket view: wakil-ticket is reached through the registry's ticket actions only.
        (.ticket, "ticket_in_flight", .object([:])),
    ]
    for (role, action, params) in calls {
        _ = try? await wiring.registry.dispatch(
            name: action, params: params, origin: .agent,
            caller: DispatchCaller(place: away, session: "s1"), confirmation: nil)
        #expect(await dbEventually(10) { await wiring.placeClients.startedRoles(for: away).contains(role) },
                "\(action)")
    }
    #expect(await wiring.placeClients.startedRoles(for: away) == Set(ClientRole.allCases))

    await wiring.shutdown()
}

/// Invariant 2 (3a-ii): only the window's own wakil-git copies register the writes. The agent's
/// copy, started from agentMCPConfigJSON, never carries the flag, so it has the reads alone.
@Test func onlyTheWindowsWakilGitIsStartedWithTheWritesFlag() throws {
    let base = ["HOME": "/h", "PATH": "/p"]
    #expect(WakilWiring.windowClientEnvironment(for: "wakil-git", base)[WakilWiring.gitWritesFlag] == "1")
    for other in ["wakil-ctx", "wakil-db", "wakil-http", "wakil-files"] {
        #expect(WakilWiring.windowClientEnvironment(for: other, base)[WakilWiring.gitWritesFlag] == nil, "\(other)")
    }
    let json = agentMCPConfigJSON(
        shimExecutable: URL(fileURLWithPath: "/bin/wakil"), socketPath: "/tmp/s",
        binaries: ["wakil-git": URL(fileURLWithPath: "/bin/wakil-git")],
        place: Place(organization: "initech", project: "p", environment: "e"), provider: "main")
    #expect(json.contains("wakil-git"))
    #expect(!json.contains(WakilWiring.gitWritesFlag), "\(json)")
}

/// The ruling: an org switch lets a running commit finish. `switchOrg` stops wakil-git, so it
/// waits for the window's git writes to end first.
@Test(.timeLimit(.minutes(1))) func anOrgSwitchWaitsForARunningGitWriteBeforeStoppingTheClients() async throws {
    let journal = try scratch()
    let emptyBin = try scratch()
    let wiring = await WakilWiring.build(
        journalDirectory: journal, sessionId: "s1", executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path])
    #expect(await wiring.gitWrites.begin("/p"))
    let done = ManagedAtomicFlag()
    let switching = Task {
        _ = await wiring.switchOrg(to: "umbrella")
        done.set()
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!done.isSet, "the switch went ahead while the commit ran")
    await wiring.gitWrites.end("/p")
    await switching.value
    #expect(done.isSet)
    await wiring.shutdown()
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 3d-iv: browser passwords

/// The wiring's password store is the one `WAKIL_KEYCHAIN` names, and the actions write through it.
/// Every write here is to the test's own temporary keychain, and only after the store is proved to be
/// scoped to it: a store that ignored the variable would write to the login keychain.
@Test func theStoreTakesWakilKeychainFromTheEnvironment() async throws {
    let home = try scratch()
    let emptyBin = try scratch()

    // A named file that is missing is refused, never the login keychain in its place.
    let missing = home.appendingPathComponent("missing.keychain-db").path
    let refused = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "kc-missing", executableDirectory: emptyBin,
        environment: ["HOME": home.path, "WAKIL_BIN_DIR": emptyBin.path, "WAKIL_KEYCHAIN": missing])
    await refused.shutdown()
    try #require(refused.browserPasswords.keychainFile == missing)
    #expect(throws: BrowserPasswordError.noKeychainFile(missing)) {
        try refused.browserPasswords.logins(org: "initech", site: nil)
    }

    let keychain = try TemporaryKeychain()
    defer { keychain.remove() }
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".wakil/orgs/initech"), withIntermediateDirectories: true)
    let wiring = await WakilWiring.build(
        journalDirectory: try scratch(), sessionId: "kc", executableDirectory: emptyBin,
        environment: ["HOME": home.path, "WAKIL_BIN_DIR": emptyBin.path, "WAKIL_KEYCHAIN": keychain.path])
    await wiring.shutdown()
    try #require(wiring.browserPasswords.keychainFile == keychain.path)

    // Through the registry's action, so the action's store is the wiring's too.
    _ = try await wiring.registry.dispatch(
        name: "browser_password_save",
        params: .object(["org": .string("initech"), "site": .string("example.com"),
                         "username": .string("ann"), "password": .string("walk-test-pass-1")]),
        origin: .ui, caller: DispatchCaller(place: Place(organization: "", project: "", environment: ""), session: nil),
        confirmation: nil)
    let onFile = BrowserPasswordStore(keychainFile: keychain.path)
    #expect(try onFile.logins(org: "initech", site: nil).map(\.username) == ["ann"])
}
