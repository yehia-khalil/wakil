/// The (organization, project, environment) an agent session works in. Fixed when the
/// session's harness starts and exported to its servers as `WAKIL_ORG`, `WAKIL_PROJECT`
/// and `WAKIL_ENVIRONMENT`, so the session stays there when the operator moves elsewhere.
/// `project` is the project's registry key — what `WAKIL_PROJECT` is looked up by — not
/// `project.json`'s `name`, which is written separately and can differ, and not an id.
public struct Place: Sendable, Hashable, Codable {
    public let organization: String
    public let project: String
    public let environment: String

    public init(organization: String, project: String, environment: String) {
        self.organization = organization
        self.project = project
        self.environment = environment
    }
}

/// Who a dispatch is made for: the place it acts in, and the agent session that asked.
/// The write gate prices by `place.environment`; the journal records the whole value.
/// `session` is nil for the operator's own dispatches, which no agent session made.
/// `via` names the route a dispatch took when it was not the default one (3b-ix: `"fastPath"`,
/// the composer's one-line command); the journal records it, and nil is not written.
public struct DispatchCaller: Sendable {
    public let place: Place
    public let session: String?
    public let via: String?
    /// The conversation within the place that made the dispatch; nil for the operator's own
    /// dispatches and for any caller that names none. The journal records it, and nil is not written.
    public let conversation: String?

    public init(place: Place, session: String?, via: String? = nil, conversation: String? = nil) {
        self.place = place
        self.session = session
        self.via = via
        self.conversation = conversation
    }
}

/// The place a dispatch made for `caller` is answered for by clients and values of its own:
/// the caller's place, when an agent session made it (`session` set) in a known organisation.
/// Nil for anything else, which takes the window's own clients and values — the operator's
/// dispatches among them, whose place is the window's as it was when they were made and can be
/// stale by the time a client is reached.
///
/// **The project and the environment may be empty** (final review C1). An agent started in an
/// organisation with no project is still pinned to that organisation: its clients carry
/// `WAKIL_ORG` alone (`WakilWiring.pinnedEnvironment`), so they read its own org's `active.json`,
/// and its canvas is the organisation's own (`LayoutScope(organization:project:environment:)`
/// with both empty). Left to the window's, it would act in whichever organisation the operator
/// switched to. Within its organisation it follows the operator's project, as it always did.
///
/// **Who is calling decides, never whether the place is the screen's.** `setProject` and
/// `switchEnvironment` rewrite `active.json` before the window's `place` moves; in between, an
/// agent still on the old place would read as on screen while the window's clients already
/// answer for the new one — a staging mutation run against production.
func pinnedPlace(of caller: DispatchCaller?) -> Place? {
    guard let caller, let session = caller.session, !session.isEmpty,
          !caller.place.organization.isEmpty
    else { return nil }
    return caller.place
}
