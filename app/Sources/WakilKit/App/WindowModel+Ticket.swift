import Foundation

/// The Ticket view's reads the window starts (spec, *When it reads*). No timer: a root's branch
/// changing (or first seen) while an editor pane is open, and Wakil becoming the active app with
/// the Ticket view showing and its read over 60 s old. ↻, a push and Send or Resolve read through
/// their own actions. Reads are Wakil's cache, not operator state: they go to the store, which the
/// panes' readable state follows; the default branch reads In flight too.
extension WindowModel {
    private var editorPaneIds: [String] {
        layoutSnapshot.panes.filter { PaneKinds.is($0.kind, EditorPaneKind.self) }.map(\.id)
    }

    /// Reads every root whose branch is not the one it was at the last status read, while an editor
    /// pane is open. Started, not awaited: a read can take 15 s and the status must not wait for it.
    func ticketBranchesChanged(_ roots: [GitRootState]) async {
        guard let ticket, !editorPaneIds.isEmpty else { return }
        for r in roots where r.error == nil && !r.loading {
            let branch = r.branch.isEmpty ? r.detached : r.branch
            guard ticketBranches[r.root] != branch else { continue }
            ticketBranches[r.root] = branch
            await ticket.follow(root: r.root, branch: r.branch)
            ticketRead(r.root)
        }
    }

    /// Wakil became the active app: each root an editor pane shows on its Ticket view is read again
    /// when its last read is over 60 s old.
    func ticketActivated() async {
        guard let ticket else { return }
        let roots = gitRootPaths
        var wanted: [String] = []
        for pane in editorPaneIds {
            let s = await editorSnapshot(pane: pane)
            guard let c = s.column, c.shown, c.view == EditorColumnView.ticket, c.ticketShown == nil,
                  let root = ticketFollowedRoot(front: editorFrontRoot(s), roots: roots), !wanted.contains(root) else { continue }
            wanted.append(root)
        }
        let now = Date()
        for root in wanted where ticketStale(lastRead: await ticket.lastRead(root: root), now: now) {
            ticketRead(root)
        }
    }

    /// Reads the head texts each editor pane's front file needs to place its review boxes
    /// (`git_show` rev `commit:<sha>`), once each: started, not awaited. A commit that is not local,
    /// or a file not in it, lands with no text, and its boxes draw at GitHub's line ("line may differ").
    func readReviewHeads() async {
        guard let git = gitStatus?.git else { return }
        var wanted: [EditorReviewHead] = []
        for pane in editorPaneIds {
            let s = await editorSnapshot(pane: pane)
            guard let i = s.active, i < s.tabs.count else { continue }
            wanted += editorReviewHeadsWanted(s.tabs[i], editorReviews)
        }
        guard !wanted.isEmpty else { return }
        for head in await claimReviewHeads(wanted) {
            Task { [self] in await landReviewHead(head, text: await Self.reviewHeadText(git, head)) }
        }
    }

    /// The file's text at the head commit; nil when git cannot show it there.
    private static func reviewHeadText(_ git: any ToolCaller, _ h: EditorReviewHead) async -> String? {
        let args: JSONValue = .object(["root": .string(h.root), "path": .string(h.path), "rev": .string("commit:\(h.sha)")])
        guard case .object(let o)? = try? await git.callTool(name: "git_show", arguments: args, timeout: MCPClient.readReplyTimeout),
              o["isError"] != .bool(true), case .object(let c)? = o["structuredContent"],
              c["binary"] != .bool(true), c["truncated"] != .bool(true), c["absent"] != .bool(true),
              case .string(let text)? = c["text"] else { return nil }
        return text
    }

    /// One read of `root`, joined to one in flight; the default branch reads In flight too. A
    /// failure is kept in the store, whole, where the view reads it (Rule 8).
    private func ticketRead(_ root: String) {
        guard let ticket else { return }
        Task {
            guard let state = try? await ticket.read(root: root) else { return }
            if state.longLived { _ = try? await ticket.inFlight() }
        }
    }
}
