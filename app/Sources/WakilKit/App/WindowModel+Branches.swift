import Foundation

/// What a switch from the picker came to (3a-iv): done (with a sentence when the changes stayed in a
/// stash), refused by changes in the way — the picker then offers Stash and Switch or Bring Them
/// Along — or refused outright, in git's words.
public enum ChangesSwitchOutcome: Sendable, Equatable {
    case switched(note: String)
    case blocked(paths: [String])
    case refused(String)
}

/// 3a-iv: branches and stash, through the `editor_changes_*` actions (Invariant 2). Writes go through
/// `changesWrite`, so a root runs one write at a time and its error shows under its box.
extension WindowModel {
    private func decoded<T: Decodable>(_ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func read(_ name: String, root: String) async -> JSONValue? {
        let reply = try? await registry.dispatch(name: name, params: .object(["root": .string(root)]), origin: .ui,
                                                 caller: DispatchCaller(place: place, session: nil), confirmation: nil)
        if case .object(let o)? = reply, let s = o["structuredContent"] { return s }
        return reply
    }

    public func changesBranches(root: String) async -> GitBranchesInfo? {
        decoded(await read("editor_changes_branches", root: root))
    }

    /// ⌘K Switch branch…'s choices: the active root's local branches, the current one marked.
    func branchPaletteItems() async -> (items: [PaletteItem], note: String?) {
        guard let root = activeBranchRoot?.root else { return ([], nil) }
        guard let b = await changesBranches(root: root) else { return ([], "the branches could not be read") }
        return (b.local.map {
            PaletteItem(id: "branch:\($0.name)", kind: .action, title: $0.name,
                        subtitle: $0.current ? "current" : $0.upstream, payload: $0.name)
        }, nil)
    }

    public func changesStashes(root: String) async -> [GitStashInfo] {
        guard case .object(let o)? = await read("editor_changes_stashes", root: root) else { return [] }
        return decoded(o["stashes"]) ?? []
    }

    private func switchOutcome(_ root: String, _ reply: JSONValue?) -> ChangesSwitchOutcome {
        guard case .object(let o)? = reply else { return .refused(changesErrors[root] ?? "") }
        if case .array(let paths)? = o["blocked"], !paths.isEmpty {
            return .blocked(paths: paths.compactMap { if case .string(let p) = $0 { p } else { nil } })
        }
        let note: String = { if case .string(let n)? = o["note"] { n } else { "" } }()
        if !note.isEmpty { changesErrors[root] = note }
        return .switched(note: note)
    }

    /// Switches `root` to `branch` (`track`: a remote branch to create it from). `carry` is nil (refuse
    /// changes in the way), "stash" or "bring".
    public func changesSwitch(root: String, branch: String, carry: String? = nil, track: String? = nil) async -> ChangesSwitchOutcome {
        var params: [String: JSONValue] = ["root": .string(root), "branch": .string(branch)]
        if let carry { params["carry"] = .string(carry) }
        if let track { params["track"] = .string(track) }
        return switchOutcome(root, await changesWrite(root, "editor_changes_switch", params))
    }

    public func changesBranchCreate(root: String, name: String, from: String? = nil) async -> ChangesSwitchOutcome {
        var params: [String: JSONValue] = ["root": .string(root), "name": .string(name)]
        if let from { params["from"] = .string(from) }
        return switchOutcome(root, await changesWrite(root, "editor_changes_branch_create", params))
    }

    /// The writes that answer nothing but a refusal: nil on success, else its sentence.
    private func plainWrite(_ root: String, _ name: String, _ params: [String: JSONValue]) async -> String? {
        var p = params
        p["root"] = .string(root)
        return await changesWrite(root, name, p) == nil ? (changesErrors[root] ?? "") : nil
    }

    public func changesBranchRename(root: String, to: String) async -> String? {
        await plainWrite(root, "editor_changes_branch_rename", ["to": .string(to)])
    }

    public func changesBranchDelete(root: String, branch: String, force: Bool) async -> String? {
        await plainWrite(root, "editor_changes_branch_delete", ["branch": .string(branch), "force": .bool(force)])
    }

    public func changesStash(root: String, message: String = "", mode: String = "default") async -> String? {
        await plainWrite(root, "editor_changes_stash", ["message": .string(message), "mode": .string(mode)])
    }

    /// Applies (or pops) a stash; a clash's sentence is left under the box.
    public func changesStashApply(root: String, stash: GitStashInfo, pop: Bool) async -> String? {
        let reply = await changesWrite(root, pop ? "editor_changes_stash_pop" : "editor_changes_stash_apply",
                                       ["root": .string(root), "index": .integer(Int64(stash.index)), "id": .string(stash.id)])
        guard case .object(let o)? = reply else { return changesErrors[root] ?? "" }
        if case .string(let note)? = o["note"], !note.isEmpty { changesErrors[root] = note }
        return nil
    }

    public func changesStashDrop(root: String, stash: GitStashInfo) async -> String? {
        await plainWrite(root, "editor_changes_stash_drop", ["index": .integer(Int64(stash.index)), "id": .string(stash.id)])
    }

    /// Drops the stashes the operator was shown, and none pushed since.
    public func changesStashDropAll(root: String, stashes: [GitStashInfo]) async -> String? {
        await plainWrite(root, "editor_changes_stash_drop_all", ["ids": .array(stashes.map { .string($0.id) })])
    }
}
