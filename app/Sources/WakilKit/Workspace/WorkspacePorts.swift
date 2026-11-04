import Foundation

/// The key a checkout's port block is handed out under: workspace id and repo folder.
func portKey(_ w: Workspace, _ co: WorkspaceCheckout) -> String { "\(w.id)/\(co.repoName)" }

/// Ten ports per checkout (spec, piece 2: `WAKIL_PORT`, `WAKIL_PORT_1` … `_9`).
public let portBlockSize = 10

extension WorkspaceRouter {
    /// Gives every made checkout of workspace `id` a port block (call 7: from 41200, ten each,
    /// stable across runs), through wakil-ctx's `ports_allocate`, with every block the
    /// organisation's record already holds kept; recorded in `workspaces.json`. Main gets none.
    /// The refusal when no block is free is Go's sentence, whole.
    public func ensurePorts(_ id: String) async throws -> Workspace {
        let ctx = self.ctx
        return try await serially {
            guard let w = await self.store.workspace(id) else {
                throw WorkspaceWriteError(description: "There is no workspace \(id)")
            }
            let want = w.checkouts.filter { $0.path != nil && $0.ports == nil }.map { portKey(w, $0) }
            guard !want.isEmpty else { return w }
            guard let ctx else { throw WorkspaceWriteError(description: "ports_allocate: wakil-ctx is not running") }
            var existing: [String: JSONValue] = [:]
            for other in await self.store.all() {
                for co in other.checkouts {
                    if let p = co.ports { existing[portKey(other, co)] = .integer(Int64(p.first)) }
                }
            }
            let r = try await callCheckedTool(
                ctx, tool: "ports_allocate",
                arguments: .object(["existing": .object(existing), "want": .array(want.map { .string($0) })]),
                action: "ports_allocate", timeout: MCPClient.readReplyTimeout)
            var value = r
            if case .object(let o) = r, let s = o["structuredContent"] { value = s }
            var blocks: [String: Int] = [:]
            if case .object(let o) = value, case .object(let b)? = o["blocks"] {
                for (k, v) in b {
                    switch v {
                    case .integer(let n): blocks[k] = Int(n)
                    case .number(let n): blocks[k] = Int(n)
                    default: break
                    }
                }
            }
            await self.store.update(id) { ws in
                for i in ws.checkouts.indices where ws.checkouts[i].ports == nil {
                    if let first = blocks[portKey(ws, ws.checkouts[i])] {
                        ws.checkouts[i].ports = PortBlock(first: first, count: portBlockSize)
                    }
                }
            }
            try await self.store.save()
            return await self.store.workspace(id) ?? w
        }
    }

    /// Records that a checkout's copy, clone and setup ran.
    public func markSetUp(_ id: String, repo: String) async {
        await store.update(id) { ws in
            if let i = ws.checkouts.firstIndex(where: { $0.repo == repo }) { ws.checkouts[i].setUp = true }
        }
        try? await store.save()
    }
}
