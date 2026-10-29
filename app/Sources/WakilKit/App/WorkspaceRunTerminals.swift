import Foundation

/// Workspaces, piece 2: a run's processes in terminal panes of the workspace's own view (decision
/// 22), wherever the screen is — routed by `ScopeRouting.home`, as a background agent's panes are —
/// opened unfocused, so the operator stays where they were (Rule 6).
final class WorkspaceRunTerminals: RunTerminals {
    let layout: LayoutStore
    let terminals: TerminalStore
    let organization: @Sendable () async -> String?

    init(layout: LayoutStore, terminals: TerminalStore, organization: @escaping @Sendable () async -> String?) {
        self.layout = layout
        self.terminals = terminals
        self.organization = organization
    }

    private func scope(_ w: Workspace) async -> LayoutScope {
        LayoutScope(organization: await organization() ?? "", project: w.project, environment: w.environment,
                    lineageRoot: workspaceCanvasRoot(w))
    }

    func start(title: String, workspace w: Workspace, dir: String, environment: [String: String],
               command: String) async throws -> String {
        let org = await organization() ?? ""
        let env = terminalChildEnvironment(org: org, project: w.project, environment: w.environment)
            .merging(environment) { _, run in run }
        return try await ScopeRouting.$home.withValue(await scope(w)) {
            let pane = await layout.open(kind: "terminal", title: title, terminalPath: dir, focus: false)
            _ = try await terminals.open(paneId: pane.id, path: dir, environment: env)
            await terminals.write(paneId: pane.id, bytes: Array((command + "\n").utf8))
            return pane.id
        }
    }

    func stop(pane: String, workspace w: Workspace) async {
        await ScopeRouting.$home.withValue(await scope(w)) {
            await terminals.close(paneId: pane)
            try? await layout.close(id: pane)
        }
    }

    func output(pane: String, workspace w: Workspace) async -> String {
        await ScopeRouting.$home.withValue(await scope(w)) {
            await terminals.screenLines(pane).joined(separator: "\n")
        }
    }
}
