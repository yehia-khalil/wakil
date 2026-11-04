import Foundation

// Workspaces piece 5: the one workspace a crew works in. A crew's conversations share it so they
// write different repos of one piece of work (one checkout each), not one workspace each.

extension WorkspaceRouter {
    /// The workspace a crew starts in: the ticket's — an unarchived workspace of the project and
    /// environment carrying `ticket`, not a branch-off — else a new one, a **record only** (no copies:
    /// each comes at its first write, from the repo's base; the umbrella's "Start on a ticket"),
    /// named `name`, its branch `branch` (a hand-off's: the ticket's own, so the first write takes it
    /// from Main when Main's folder is on it, decision 8), else the fallback name (`<KEY>-<slug>`).
    /// Saved when made.
    public func crewWorkspace(ticket: String?, name: String, organization: String, project: String,
                              environment: String, branch: String? = nil) async -> Workspace {
        await store.ensure(org: organization)
        let all = await store.all()
        if let ticket, !ticket.isEmpty, let found = all.last(where: {
            !$0.archived && $0.parent == nil && $0.project == project && $0.environment == environment
                && $0.tickets.contains(ticket)
        }) {
            return found
        }
        var title = name
        if let ticket, title.hasPrefix(ticket) {
            title = String(title.dropFirst(ticket.count)).trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("·") { title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        let branch = branch.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBranchName(key: ticket, title: title)
        let slug = uniqueSlug(branchSlug(branch), taken: Set(all.filter { $0.project == project }.map(\.slug)))
        let w = Workspace(
            id: newId(), name: name.isEmpty ? (ticket ?? "Work") : name, slug: slug, project: project,
            environment: environment, tickets: ticket.map { $0.isEmpty ? [] : [$0] } ?? [], branch: branch,
            created: ISO8601DateFormatter().string(from: Date()))
        await store.add(w)
        try? await store.save()
        return w
    }

    /// Puts `conversation` in workspace `id`, its lineage root recorded there when it has one: a
    /// crew member at its start (it holds nothing yet), or a proposer in Main whose teammate the
    /// operator started (it holds nothing in Main, so nothing is stranded — decision 6). Its thread
    /// says so and its view follows, once; joining again only records a root it has since got.
    ///
    /// `branchOff` (a Start another, item 8): it holds no copy, and its first write branches off into
    /// a child workspace whoever holds the copy — marked in the record by its lineage root, so a
    /// resume keeps it.
    public func join(_ conversation: String, workspace id: String, branchOff: Bool = false) async {
        guard let w = await store.workspace(id) else { return }
        let facts = await hooks?.conversation(conversation)
        let member = await store.isMember(conversation)
        let current = await store.workspaceId(ofConversation: conversation)
        let already = member && current == id
        await store.move(conversation, root: facts?.lineageRoot, to: id)
        if branchOff { await store.markBranchOff(conversation, root: facts?.lineageRoot) }
        try? await store.save()
        guard !already else { return }
        await hooks?.say(conversation, .moved(name: w.name))
        await hooks?.moved(conversation, nil, await store.workspace(id) ?? w)
    }
}
