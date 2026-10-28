import Foundation

/// The window's quick tasks (3b-viii, Decision 42): one `QuickTasks` built from the organisation's
/// `config_tree`, and the ghost-text requests each pane makes of it.
extension WindowModel {
    /// Shuts the old quick tasks down, releases every pane's pending ghost request, and builds new
    /// ones from the configuration on disk (Ruling R4). With no factory, no organisation or no
    /// readable tree, none are built and every ghost request answers nil; an unreadable tree's
    /// reason is kept whole for Settings (`quickTaskStatus().configError`).
    public func rebuildQuickTasks() async {
        quickTasksGeneration += 1
        let mine = quickTasksGeneration
        await shutDownQuickTasks()
        fastPathEnabled = false
        commitDraftsEnabled = false
        conversationNamesEnabled = false
        let org = organization
        let active = providerId
        guard let factory = quickModelFactory, let context, !org.isEmpty else { return }
        let read: Result<SettingsTree, Error>
        do {
            let reply = try await context.configTree()
            if let tree = decodeSettingsTree(fromResult: reply) {
                read = .success(tree)
            } else {
                read = .failure(QuickModelError.failed("config_tree: the reply was not a configuration tree"))
            }
        } catch {
            read = .failure(error)
        }
        guard mine == quickTasksGeneration, org == organization else { return }
        let tree: SettingsTree
        switch read {
        case .success(let read):
            tree = read
            quickTasksConfigError = nil
        case .failure(let error):
            quickTasksConfigError = statusDescribingFailure("config_tree", error)
            return
        }
        let records = tree.providers.map { provider in
            QuickProviderRecord(
                id: provider.id, kind: provider.kind, baseURL: provider.baseURL,
                serves: Set(provider.serves.compactMap(QuickOperation.init(rawValue:))))
        }
        let quick = tree.org.quickProvider.isEmpty ? nil : records.first { $0.id == tree.org.quickProvider }
        let config = QuickTasksConfig(quickProvider: quick, active: records.first { $0.id == active })
        quickTasks = QuickTasks(config: config) { record in try await factory(record, org) }
        ghostTextEnabled = tree.org.ghostText
        fastPathEnabled = tree.org.fastPath
        commitDraftsEnabled = tree.org.commitDrafts
        conversationNamesEnabled = tree.org.conversationNames
        // Only a local server has a prompt cache to fill; a session-backed model would spend a turn.
        if fastPathEnabled, let tasks = quickTasks, await tasks.routedKind(.respond) == "local" {
            let schemas = await fastPathSchemas()
            guard mine == quickTasksGeneration else { return }
            let warm = RespondRequest(instructions: FastPath.instructions(actions: schemas),
                                      input: FastPath.input("open settings", scope: FastPathScope()),
                                      jsonSchema: FastPath.replySchema, maxTokens: 8)
            Task { _ = try? await tasks.respond(warm, fallback: false) }   // the reply is not used
        }
    }

    /// Releases every pane's pending request, then shuts the models down. Also the window's own
    /// shutdown.
    func shutDownQuickTasks() async {
        let old = quickTasks
        let sessions = Array(ghostSessions.values)
        quickTasks = nil
        ghostSessions = [:]
        for session in sessions { await session.cancel() }
        await old?.shutdown()
    }

    /// The suggestion for `pane` at `request`, or nil when ghost-text is off, nothing is built, the
    /// request was built in an earlier generation (`ghostSchema()`: another organisation's, or before
    /// a rebuild — Invariant 4), a newer request on the same pane superseded this one, or the model
    /// answered nothing.
    public func ghostSuggestion(pane: String, request: InfillRequest, generation: Int) async -> String? {
        guard generation == quickTasksGeneration, ghostTextEnabled, let tasks = quickTasks else { return nil }
        let session: GhostTextSession
        if let existing = ghostSessions[pane] {
            session = existing
        } else {
            session = GhostTextSession(
                suggest: { try await tasks.infill($0) },
                debounce: { await Self.ghostDebounce(for: tasks) })
            ghostSessions[pane] = session
        }
        return await session.request(request)
    }

    /// Releases `pane`'s pending request. The session is dropped at once, so a request the pane
    /// makes next starts a new one and the late cancel cannot reach it.
    public func ghostCancel(pane: String) {
        guard let session = ghostSessions.removeValue(forKey: pane) else { return }
        Task { await session.cancel() }
    }

    /// Releases the ghost session of every pane that was on the canvas in `before` and is gone now —
    /// closed by the operator or an agent — so none outlives its pane. Run wherever the canvas is
    /// read back. A pane the refresh never saw leave keeps its session: every dispatch triggers a
    /// refresh, and its request may be in flight.
    func pruneGhostSessions(before: LayoutSnapshot) {
        guard !ghostSessions.isEmpty else { return }
        let open = Set(layoutSnapshot.panes.map(\.id))
        let gone = before.panes.map(\.id).filter { !open.contains($0) }
        for pane in gone where ghostSessions[pane] != nil { ghostCancel(pane: pane) }
    }

    /// How long a pane waits after a keystroke before asking: a local endpoint answers in tens of
    /// milliseconds, a session-backed model in about a second.
    public func ghostDebounce() async -> Duration {
        guard let quickTasks else { return Self.sessionDebounce }
        return await Self.ghostDebounce(for: quickTasks)
    }

    /// What Settings draws for the quick tasks: each provider's last error whole and which have
    /// answered, the provider code completion goes to, and why the configuration the quick tasks are
    /// built from could not be read.
    public func quickTaskStatus() async -> QuickTaskStatus {
        guard let quickTasks else { return QuickTaskStatus(configError: quickTasksConfigError) }
        return QuickTaskStatus(
            errors: await quickTasks.endpointErrors(), answered: await quickTasks.answered(),
            routedInfill: await quickTasks.routedId(.infill), configError: quickTasksConfigError)
    }

    /// The schema tables in scope, from the vocabulary the window's turns already resolve against,
    /// and the quick-tasks generation they were read in — read before the await, so a request built
    /// across a rebuild carries the old one and is never asked.
    public func ghostSchema() async -> GhostScope {
        let generation = quickTasksGeneration
        guard let vocabulary else { return GhostScope(generation: generation, tables: []) }
        return GhostScope(generation: generation, tables: GhostSchema.tables(from: await vocabulary.current().names))
    }

    /// An org's quick-task switch (3b-ix): written with `ctx_update_org`, then re-read and rebuilt.
    public enum OrganisationSwitch: String, Sendable, CaseIterable { case ghostText, fastPath, commitDrafts, conversationNames }

    public func saveOrganisationSwitch(_ s: OrganisationSwitch, on: Bool) async -> String? {
        do {
            _ = try await registry.dispatch(
                name: "ctx_update_org",
                params: .object(["id": .string(organization), s.rawValue: .bool(on)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            await refreshSettings()
            return statusDescribingFailure("ctx_update_org", error)
        }
        await refreshSettings()
        await rebuildQuickTasks()
        return nil
    }

    /// Saves a local model endpoint, then re-reads Settings and rebuilds (Ruling R4). Answers the
    /// refusal's own sentence, or nil — `saveOrganisationField`'s shape.
    public func setLocalProvider(id: String, label: String, baseURL: String) async -> String? {
        let params: JSONValue = .object([
            "id": .string(id), "label": .string(label), "baseURL": .string(baseURL),
        ])
        do {
            _ = try await registry.dispatch(
                name: "ctx_set_local_provider", params: params, origin: .ui,
                caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            await refreshSettings()
            return statusDescribingFailure("ctx_set_local_provider", error)
        }
        await refreshSettings()
        await rebuildQuickTasks()
        return nil
    }

    /// Removes a local model from this organisation (Settings' REMOVE): `unlink_provider`, which
    /// also clears it from `quickProvider`, so quick tasks fall back to the agent's provider. No
    /// confirmation: a local model holds no credential, and adding it again restores it. Answers
    /// the refusal's own sentence, or nil.
    public func removeLocalProvider(id: String) async -> String? {
        do {
            _ = try await registry.dispatch(
                name: "ctx_unlink_provider", params: .object(["id": .string(id), "org": .string(organization)]),
                origin: .ui, caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        } catch {
            await refreshSettings()
            return statusDescribingFailure("ctx_unlink_provider", error)
        }
        await refreshSettings()
        await rebuildQuickTasks()
        return nil
    }

    private static let localDebounce: Duration = .milliseconds(250)
    private static let sessionDebounce: Duration = .milliseconds(500)

    private static func ghostDebounce(for tasks: QuickTasks) async -> Duration {
        await tasks.routedKind(.infill) == "local" ? localDebounce : sessionDebounce
    }
}
