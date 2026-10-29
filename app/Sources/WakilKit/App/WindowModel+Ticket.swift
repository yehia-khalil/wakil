import Foundation

/// The Ticket view's reads the window starts (spec, *When it reads*): a root's branch changing (or
/// first seen) while an editor pane is open, and Wakil becoming the active app with the Ticket view
/// showing and its read over 60 s old; the 2-minute read is `WindowModel+TicketNoticing`'s. ↻, a push and Send or Resolve read through
/// their own actions. Reads are Wakil's cache, not operator state: they go to the store, which the
/// panes' readable state follows; the default branch reads In flight too.
extension WindowModel {
    private var editorPaneIds: [String] {
        layoutSnapshot.panes.filter { PaneKinds.is($0.kind, EditorPaneKind.self) }.map(\.id)
    }

    /// A rail row pressed: the pane focused, and an editor row with the needs-you tick shows its
    /// Ticket view (the count's home) as it was left — a ticket picked from In flight still shown,
    /// the column scrolled where it was (spec, Rule 6). `editor_tree`, not `ticket_show` with no key,
    /// which is ← Back to this branch and dropped the pick (walk 2026-10-29).
    public func railRowPressed(pane: String) async {
        _ = await focusPane(id: pane)
        guard layoutSnapshot.panes.contains(where: { $0.id == pane && PaneKinds.is($0.kind, EditorPaneKind.self) }),
              ticketNeedsCount(ticketNeeds) > 0 else { return }
        await dispatchFromSurface("editor_tree", .object([
            "pane": .string(pane), "view": .string(EditorColumnView.ticket.rawValue), "shown": .bool(true)]))
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
    /// when its last read is over 60 s old, and so is each ticket picked into one (walk 2026-10-29).
    func ticketActivated() async {
        guard let ticket else { return }
        let now = Date()
        for root in await ticketViewRoots() where ticketStale(lastRead: await ticket.lastRead(root: root), now: now) {
            ticketRead(root)
        }
        for key in await ticketShownKeys() where await ticket.shownStale(key: key) {
            Task { await ticket.refreshShown(key: key) }
        }
    }

    /// The roots the editor panes showing their Ticket view on the branch's own ticket follow, once each.
    func ticketViewRoots() async -> [String] {
        let roots = gitRootPaths
        var wanted: [String] = []
        for pane in editorPaneIds {
            let s = await editorSnapshot(pane: pane)
            guard let c = s.column, c.shown, c.view == EditorColumnView.ticket, c.ticketShown == nil,
                  let root = ticketFollowedRoot(front: editorFrontRoot(s), roots: roots), !wanted.contains(root) else { continue }
            wanted.append(root)
        }
        return wanted
    }

    /// The tickets the editor panes' Ticket views show picked from In flight or the Landing — a key,
    /// or a keyless row on a root — once each: what ↻ reads again beside the branch's own.
    func ticketShownKeys() async -> [String] {
        var keys: [String] = []
        for pane in editorPaneIds {
            guard let c = await editorSnapshot(pane: pane).column, c.shown, c.view == EditorColumnView.ticket,
                  let key = c.ticketShown ?? c.ticketShownAt.flatMap({ $0.root.isEmpty ? nil : $0.id }),
                  !key.isEmpty, !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
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
            Task { [self] in await landReviewHead(head, text: await editorReadReviewHead(git, head)) }
        }
    }

    /// Reads the organisation's reply drafts from its file (`ticket_drafts`), so a draft written
    /// before a quit, or by a handed agent in the background, is in its box. The window being ready
    /// and an org switch both end in `refreshContext`, which calls this; the store drops a load from
    /// before a switch. Started, not awaited.
    func ticketLoadDrafts() {
        guard let ticket else { return }
        Task { try? await ticket.loadDrafts() }
    }

    /// One read of `root`, joined to one in flight; the default branch reads In flight too. A
    /// failure is kept in the store, whole, where the view reads it (Rule 8).
    func ticketRead(_ root: String) {
        guard let ticket else { return }
        Task {
            guard let state = try? await ticket.read(root: root) else { return }
            if state.longLived { _ = try? await ticket.inFlight() }
        }
    }
}
