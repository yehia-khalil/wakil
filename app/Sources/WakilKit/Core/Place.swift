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
public struct DispatchCaller: Sendable {
    public let place: Place
    public let session: String?

    public init(place: Place, session: String?) {
        self.place = place
        self.session = session
    }
}
