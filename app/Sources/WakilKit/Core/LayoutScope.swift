import Foundation

/// What an arrangement is filed under.
///
/// `LayoutStore`, `PaneStore` and `LayoutPersistence` all key on this one
/// value, which is the whole point of it. They used to key on three
/// different things: both stores on a project **name** alone, persistence
/// on `(org, project)`. Disk was safe and memory was not — two
/// organisations each holding a project called `core`, which is
/// unremarkable, collided in memory and drew the first org's arrangement
/// under the second org's name with nothing anywhere failing. That hazard
/// was known and was carried by `LayoutStore.clearAllScopes`, whose whole
/// reason for existing was to paper over it on an org switch. Carrying the
/// organisation in the key subsumes the hazard rather than documenting it.
///
/// **Both stores treat it as an opaque key**, and that is what let the
/// scope widen from `(org, project)` to carry a conversation without
/// `LayoutStore` or `PaneStore` learning a new question to ask: they
/// hash it and compare it, and nothing else. Only `LayoutPersistence`
/// reads the fields — into a path, into the seed a conversation falls back
/// to, and into the note it hands the operator — and only
/// `WindowModel.persistLayout` asks one of them a question, which is
/// whether the organisation is known yet.
///
/// Not the `Scope` of the charter's §9 glossary, which is a project-level
/// narrowing of a *connection* — a Jira project key, a channel list. The
/// `Layout` prefix is load-bearing and should stay.
public struct LayoutScope: Sendable {
    /// The credential boundary the arrangement was made inside
    /// (Invariant 4). Present so that two organisations cannot collide on
    /// a shared project name.
    public let organization: String
    /// The project the arrangement belongs to, and **part of the identity
    /// whether or not a conversation is set** (#160).
    ///
    /// It also names the seed a conversation with no arrangement of its
    /// own *in this project* opens on, and the project whose own
    /// arrangement is kept fresh as work proceeds.
    public let project: String

    /// The conversation the arrangement belongs to — the **lineage root**
    /// of the session, which is the oldest ancestor reachable from it.
    ///
    /// `nil` means the project's arrangement: what every file written
    /// before #147 is, and what a conversation with none of its own falls
    /// back to. Non-`nil` means one conversation's own workspace.
    ///
    /// **The root, not the session id.** A resume is a fork — it mints a
    /// new id and records the old one as parent — so a conversation the
    /// operator thinks of as one thing is a chain of sessions. The root is
    /// the identity that chain keeps, and the same one ⌘P collapses it to
    /// when it draws one row for it. Keyed by session id instead, six
    /// forks would be six workspaces.
    ///
    /// **It must come from `wakilcore.LineageRootIn`, resolved against the
    /// whole org's parent map.** Walking `parent` links through a session
    /// *listing* gives a different answer depending on what happens to be
    /// listed, because the listing is filtered to the active project's
    /// roots. That is harmless for a display grouping and fatal here: an
    /// arrangement filed under one root and looked up under another is an
    /// arrangement silently lost.
    public let lineageRoot: String?

    /// `lineageRoot` defaults to `nil` — the project's arrangement — so
    /// that every caller that means "the project's panes" says so by
    /// saying nothing, and only the orchestrator names a conversation.
    public init(organization: String, project: String, lineageRoot: String? = nil) {
        self.organization = organization
        self.project = project
        self.lineageRoot = lineageRoot
    }

    /// The same scope with the conversation dropped: the project's
    /// arrangement, which is the seed a conversation opens on when it has
    /// none of its own.
    public var projectSeed: LayoutScope {
        LayoutScope(organization: organization, project: project)
    }
}

/// Whether a conversation minted this moment takes the canvas `outgoing` holds, rather than
/// reading its seed off disk (re-walk finding #4). Only the project's own arrangement — the same
/// organisation and project under no conversation — moving into a conversation: that is the
/// seed, already on screen with every pane's contents in memory, which the disk copy lacks
/// (drafts are never persisted). Another conversation, another project or another org keeps its
/// own arrangement.
public func conversationAdoptsCanvas(from outgoing: LayoutScope, to incoming: LayoutScope) -> Bool {
    outgoing.lineageRoot == nil && incoming.lineageRoot != nil
        && outgoing.projectSeed == incoming.projectSeed
}

/// **One conversation is one key per project it is visited from.**
///
/// Synthesised, which is the plain answer and was not always the one
/// here. #147 hand-wrote `==` and `hash` to EXCLUDE the project whenever a
/// lineage root was set — one conversation, one workspace, whichever
/// project you visited it from — on the strength of #142's user story 12.
/// The argument was sound given its premise: a conversation's file path
/// also dropped the project, so a key that kept it would let both stores
/// hold two entries for one conversation while both named one file, and
/// coming back to the first would restore a stale arrangement over the
/// other's.
///
/// **The premise is what changed, not the reasoning.** The operator walked
/// `conversation-layouts-acceptance.md` on 2026-09-20, switched to a
/// project with no sessions at all, and the canvas did not move — because
/// the project was not in the key. A window is in a conversation from its
/// first turn or first pane onward, so that was the ordinary case. #160
/// puts the project back into the key AND into the path, together, which
/// is the only way it may be done: memory and disk are keyed the same way
/// or they are not keyed at all, and that is this type's whole reason to
/// exist.
///
/// **What story 12 was really protecting still holds**, and never lived
/// here. Its harm is a fork chain resolving to a DIFFERENT root depending
/// on what a listing happened to show — an arrangement filed under one
/// root and looked up under another. That is prevented by resolving the
/// root in Go, against the organisation's complete parent map, which #160
/// leaves untouched. Read story 12 as: the same conversation in the same
/// project resolves to the same arrangement every time, whatever
/// `list_sessions` returns.
///
/// The organisation is in the key always: it is a credential boundary
/// (Invariant 4), the lineage store is per-org, and the same root under
/// two orgs is two conversations that merely share a name.
extension LayoutScope: Hashable {
    /// The scope both stores start on, before anything has told them
    /// which context is active.
    ///
    /// A real value rather than an optional so that `LayoutStore()` in a
    /// test, a `--dispatch` run, and a window before its first
    /// `refreshContext()` all write and read one consistent place rather
    /// than needing a context to exist first.
    ///
    /// **It is never written to disk.** Both its fields are empty, and
    /// `WindowModel.persistLayout` refuses a scope with no organisation —
    /// a layout filed under an empty org is filed where no later session
    /// will look for it. The empty strings are a starting point, not a
    /// name anything is saved under.
    public static let initial = LayoutScope(organization: "", project: "")
}

extension LayoutScope: CustomStringConvertible {
    /// How the scope is named to the operator — in the note an unreadable
    /// layout produces, and nowhere else. It mirrors the path
    /// `LayoutPersistence` writes to, so a note can be matched against a
    /// file by eye.
    public var description: String {
        guard let lineageRoot else { return "\(organization)/\(project)" }
        return "\(organization)/\(project) (conversation \(lineageRoot))"
    }
}
