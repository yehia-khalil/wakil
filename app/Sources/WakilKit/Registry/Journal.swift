import Foundation

/// One line of the append-only audit journal that `ActionRegistry.dispatch`
/// writes for every dispatch it handles — allowed, gated-and-refused, or
/// blocked alike. The journal exists so that "what changed, who asked for
/// it, and what happened" is reconstructable after the fact regardless of
/// whether the request came from the UI, the agent, or a debug script.
///
/// `paneId` identifies which UI pane (if any) the request is associated
/// with. Nothing in this task's `dispatch` signature accepts a pane id, so
/// every entry written here carries `paneId == nil`; a later task that adds
/// pane-scoped dispatch is expected to populate it without changing this
/// type's shape.
///
/// `environment` is the environment of the caller's place that `dispatch`
/// handed to `writeGate` — the value at the moment the decision was made,
/// not at the moment the action was proposed. The two differ, and deliberately so: a
/// mutation that parks at the confirmation plane is re-judged against the
/// environment as it stands when the operator confirms, because ⌘K still
/// works while the plane is up (`WindowModel`'s confirm path and
/// `MCPServer.parkForConfirmation` both re-read it for exactly that
/// reason). So the environment at decision time is not recoverable from
/// the proposal, and recording anything else would be recording a
/// different fact than the one the gate acted on.
///
/// **It is optional because every line written before 2026-09-10 omits
/// it.** `journalEntries()` decodes the whole file or throws, so a
/// required field would make one pre-existing line hide every entry after
/// it. `nil` reads as "not recorded", which is true of that history and of
/// nothing written since.
///
/// `organization`, `project` and `session` complete the place the dispatch
/// acted in and name the agent session that asked (nil for the operator's own
/// dispatches). They are optional for the same reason `environment` is: lines
/// written before they existed omit them, and `nil` there means "not recorded".
///
/// `reason` is the sentence a failed handler threw, on `"error"` lines only
/// (Decision 35, #323): each marked parameter's value replaced, capped at
/// 300 characters. Optional for the same reason `environment` is.
public struct JournalEntry: Codable, Sendable, Equatable {
    public var id: String
    public var ts: Date
    public var action: String
    public var params: JSONValue
    public var origin: ActionOrigin
    public var paneId: String?
    public var organization: String?
    public var project: String?
    public var environment: String?
    public var session: String?
    public var outcome: String
    public var reason: String?
    /// The route a dispatch took when it was not the default (3b-ix: `"fastPath"`).
    /// Optional for the same reason `environment` is: lines written before it existed omit it,
    /// and synthesized Codable omits a nil one rather than writing `null`.
    public var via: String?
    /// The conversation within the place that asked (agent dispatches only). Optional and
    /// omitted when nil, as `via` is.
    public var conversation: String?

    public init(
        id: String,
        ts: Date,
        action: String,
        params: JSONValue,
        origin: ActionOrigin,
        paneId: String? = nil,
        organization: String? = nil,
        project: String? = nil,
        environment: String? = nil,
        session: String? = nil,
        outcome: String,
        reason: String? = nil,
        via: String? = nil,
        conversation: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.action = action
        self.params = params
        self.origin = origin
        self.paneId = paneId
        self.organization = organization
        self.project = project
        self.environment = environment
        self.session = session
        self.outcome = outcome
        self.reason = reason
        self.via = via
        self.conversation = conversation
    }
}
