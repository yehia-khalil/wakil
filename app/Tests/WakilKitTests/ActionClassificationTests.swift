import Testing
import Foundation
@testable import WakilKit

/// **The classification is total, and this file is what makes it so.**
///
/// `operatorOnlyActions` (`MCP/PermissionPrompt.swift`) is an enumerated
/// denylist, and every test that guards it — in `PermissionPromptTests`,
/// `ProviderSwitchTests`, `WindowModelTests` — guards it against
/// **removal**: each asserts that a particular name is still in the set,
/// or still absent from it. None guards **omission**. So an action added
/// to the registry without a thought about the agent did not fail
/// anything; it simply became agent-reachable, because being reachable is
/// what not being named means.
///
/// 2e adds actions that must never be agent-reachable — a browser login, a
/// credential mint, an organisation's own boundary — on four separate
/// reasons. The classification has to be total *before* they arrive rather
/// than after, which is why this is a prefactor and changes no behaviour:
/// every action registered today keeps exactly the reachability it has
/// today.
///
/// **Why `audience` is optional and a test enforces it, rather than a
/// required initialiser parameter that the compiler enforces.** The
/// compiler's version is stricter and was rejected for one reason: an
/// `Action` is constructed in dozens of places that are not registrations
/// at all — test doubles, fixtures, `DebugDispatch`'s own stand-ins — and
/// making each of them state an audience would spread the declaration
/// across code where it means nothing and is read by nobody. What matters
/// is not that every `Action` value in the process carries a
/// classification; it is that every action **an assembly actually
/// registers** does. That is exactly what the first test below asks, of
/// exactly the assembly that ships.
///
/// **Why there is a second test pinning agreement with the denylist.**
/// Two places now answer "may the agent reach this?" — the audience on the
/// action, and `operatorOnlyActions`, which `permissionDecision` consults
/// and which has no registry to read an audience out of. Retrofitting the
/// denylist away is explicitly out of 2e's scope (it needs its own
/// argument about which reasons for membership a test could check), so the
/// two coexist, and a second answer nobody checks is a second answer that
/// drifts. This test is the check.

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Builds the assembly that ships, with no Go binaries reachable —
/// `registerStandardActions` registers every action regardless of whether
/// its client started, so the registry this returns holds the full set.
private func wiringWithNoBinaries() async throws -> WakilWiring {
    let journal = try scratch()
    let emptyBin = try scratch()
    return await WakilWiring.build(
        journalDirectory: journal,
        sessionId: "classification",
        executableDirectory: emptyBin,
        environment: ["HOME": journal.path, "WAKIL_BIN_DIR": emptyBin.path]
    )
}

/// The omission guard. An action registered with no audience fails **here**,
/// named, rather than quietly becoming something the agent can call.
@Test func everyRegisteredActionDeclaresAnAudience() async throws {
    let wiring = try await wiringWithNoBinaries()
    await wiring.shutdown()

    let unclassified = await wiring.registry.all()
        .filter { $0.audience == nil }
        .map(\.name)
        .sorted()

    #expect(
        unclassified.isEmpty,
        """
        \(unclassified.count) registered action(s) carry no audience: \(unclassified.joined(separator: ", ")).
        Every action must say whether the agent may reach it. Add `audience: .agentReachable` or \
        `audience: .operatorOnly` to its registration — and if it is operator-only, add its name to \
        `operatorOnlyActions` in MCP/PermissionPrompt.swift too, which is what actually refuses it.
        """)
}

/// The two answers must agree. `operatorOnlyActions` is what
/// `permissionDecision` refuses on and what `agentAllowedTools` filters by;
/// the audience is what this file counts. A name in one and not the other
/// is a classification that does not describe what ships.
@Test func theAudienceAgreesWithTheOperatorOnlyDenylist() async throws {
    let wiring = try await wiringWithNoBinaries()
    await wiring.shutdown()

    let classifiedOperatorOnly = Set(
        await wiring.registry.all()
            .filter { $0.audience == .operatorOnly }
            .map(\.name))

    #expect(
        classifiedOperatorOnly == operatorOnlyActions,
        """
        classified operator-only but not in operatorOnlyActions: \
        \(classifiedOperatorOnly.subtracting(operatorOnlyActions).sorted()); \
        in operatorOnlyActions but not classified operator-only: \
        \(operatorOnlyActions.subtracting(classifiedOperatorOnly).sorted())
        """)
}

/// The behavioural half of the classification: the names the agent cannot
/// reach are exactly the ones listed below, and every other registered action
/// stays reachable. Adding an operator-only action means adding it here.
@Test func theClassificationLeavesTodaysReachabilityExactlyAsItWas() async throws {
    let wiring = try await wiringWithNoBinaries()
    await wiring.shutdown()

    let operatorOnly = await wiring.registry.all()
        .filter { $0.audience == .operatorOnly }
        .map(\.name)
        .sorted()

    #expect(
        operatorOnly == [
            // 2e-iii. An API token travels in `api_set_entry`'s parameters; the rest edit beside it.
            "api_remove_entry", "api_set_entry", "api_update_entry",
            // 3c-i: the window's own relaunch step for a browser pane's saved tabs.
            "browser_restore",
            // Provider capacity: the agent may not forge a reading.
            "capacity_record",
            "ctx_add_provider", "ctx_adopt_provider", "ctx_create_environment", "ctx_create_org",
            "ctx_create_project",
            // 3a-iii-a (Decision 44): an organisation's git accounts and their secrets are the operator's.
            "ctx_git_account_add", "ctx_git_account_remove", "ctx_git_account_test", "ctx_git_device_poll",
            "ctx_git_device_start", "ctx_git_gh_import", "ctx_git_gh_logins", "ctx_git_host_suggestions",
            "ctx_git_key_generate", "ctx_git_key_passphrase_set", "ctx_git_ssh_keys", "ctx_git_token_set",
            "ctx_list_accounts",
            "ctx_list_machine_providers", "ctx_list_orgs",
            // 2e (#199). `defaultProvider` names which account this
            // organisation's projects fall back to, so setting it chooses
            // which credentials Wakil reaches for — Invariant 4's own
            // boundary.
            // 2e (#202). The strongest case in this set: it opens a
            // browser on the operator's machine and authenticates as
            // them.
            "ctx_provider_login",
            // 2e-ii. Adding, renaming and removing a project or environment: the operator's.
            "ctx_remove_environment", "ctx_remove_project", "ctx_rename_environment",
            "ctx_rename_project",
            // 3b-v (Decision 38): Decision 30 kept — the agent reads editor settings, never writes them.
            "ctx_set_browser_settings", "ctx_set_editor_settings", "ctx_set_environment",
            // 3b-viii (Decision 42): which model reads the operator's code is theirs to choose.
            "ctx_set_local_provider", "ctx_set_project", "ctx_set_project_agent_instructions",
            "ctx_set_project_editor_settings",
            "ctx_set_provider", "ctx_unlink_provider", "ctx_update_org",
            // 2e (#207). The reason NEW to this set: every other member
            // objects to what the agent could REACH, and these two object
            // to what it would CARRY.
            "db_remove_database", "db_set_connection", "db_set_dsn",
            // 2e-iii. `db_update_database` edits beside them.
            "db_update_database",
            // Conversations 2 of 3: an agent must not push aside the operator's conversation.
            // Conversations 3 of 3: nor end it.
            "session_close", "session_new", "session_set_provider", "session_switch",
            // 2e (#198). The eighth, and the weakest on its own merits:
            // opening a pane damages nothing. It is here because every
            // OTHER settings action is operator-only on a reason that
            // does hold, and an agent able to open a surface it may drive
            // no part of holds a handle to nothing.
            "settings_open", "term_run",
        ])

    let reachable = await wiring.registry.all()
        .filter { $0.audience == .agentReachable }
        .map(\.name)
    #expect(!reachable.contains { operatorOnlyActions.contains($0) })
}

/// An `Action` built without an audience reports `nil` rather than
/// defaulting to either answer. This is the property the first test relies
/// on: unclassified has to be *distinguishable* from classified-reachable,
/// or the omission guard has nothing to catch.
@Test func anUnclassifiedActionIsNotSilentlyAgentReachable() async throws {
    let action = Action(
        name: "test.unclassified", description: "test", kind: .control,
        schema: .object([:])) { _ in .null }
    #expect(action.audience == nil)

    let registry = ActionRegistry(
        journalDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sessionId: "s1")
    await registry.register(action)
    let descriptor = await registry.all().first { $0.name == "test.unclassified" }
    #expect(descriptor?.audience == nil)
}
