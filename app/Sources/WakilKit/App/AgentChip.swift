import Foundation

/// One live conversation not on screen, as the chips in the window's top right draw it
/// (background agents 4 of 4; conversations 2 of 3). `WindowModel.chips` derives one per
/// conversation that is not the screen's — in another place or backgrounded in this one; one
/// that is idle and seen has none. A click switches to it (`session_switch`).
public struct AgentChip: Identifiable, Equatable, Sendable {
    /// What the agent is doing. When more than one is true, `waiting` beats `failed`, which
    /// beats `working`, which beats `done`.
    public enum State: Sendable, Equatable {
        /// A turn in flight.
        case working
        /// Its place has a proposal parked for the operator.
        case waiting
        /// A turn finished while its place was off screen, not yet seen.
        case done
        /// The session failed while its place was off screen, not yet seen.
        case failed

        /// Higher wins: `waiting`, then `failed`, `working` and `done` (`AgentChip.state`).
        var precedence: Int {
            switch self {
            case .waiting: 3
            case .failed: 2
            case .working: 1
            case .done: 0
            }
        }

        /// What the chip's text ends with: nothing while working.
        public var suffix: String {
            switch self {
            case .working: ""
            case .waiting: " — waiting"
            case .done: " — done"
            case .failed: " — failed"
            }
        }
    }

    public let place: Place
    public let state: State
    /// The conversation's title (`PlaceAgent.title`): its first message, cut, or
    /// "New conversation" before one.
    public let title: String
    /// 1-based, the conversation's place among its place's live ones by creation (ruling 2).
    public let ordinal: Int
    /// `<org> · <project> · <environment> — <title>`, empty members left out (ruling 9).
    public let label: String
    /// Whether the place's environment is production, so its segment is drawn in production red
    /// (Invariant 8) whatever the state's hue.
    public let productionEnvironment: Bool
    /// The conversation the chip stands for, by its id: the one its click returns to.
    public let conversation: String
    /// The conversation: several chips can stand for one place.
    public var id: String { conversation }

    /// What a check presses (ruling 2): `window.agentChip.<org>/<project>/<env>` for the place's
    /// first live conversation, so every check written before conversations stays green, and
    /// `…#<ordinal>` for a later one. A check cannot know a conversation's id.
    public var identifier: String {
        let base = "window.agentChip.\(place.organization)/\(place.project)/\(place.environment)"
        return ordinal == 1 ? base : base + "#\(ordinal)"
    }

    init(
        place: Place, state: State, productionEnvironment: Bool, conversation: String,
        title: String = newConversationTitle, ordinal: Int = 1
    ) {
        self.place = place
        self.conversation = conversation
        self.state = state
        self.title = title
        self.ordinal = ordinal
        self.label = [place.organization, place.project, place.environment]
            .filter { !$0.isEmpty }.joined(separator: " · ") + " — " + title
        self.productionEnvironment = productionEnvironment
    }

    /// Its state, or nil for an agent with nothing to show.
    static func state(waiting: Bool, failed: Bool, working: Bool, done: Bool) -> State? {
        if waiting { return .waiting }
        if failed { return .failed }
        if working { return .working }
        if done { return .done }
        return nil
    }
}

/// The chips as the window's top right draws them: at most `limit` in full, and the rest folded
/// into one "+N more" chip, so a pile of agents never covers the rail or the canvas beneath.
/// The folded chip carries the strongest state among those it hides, so an agent waiting on the
/// operator is never hidden behind a quieter hue.
public struct AgentChipTray: Equatable, Sendable {
    /// How many chips are drawn in full before the rest fold.
    public static let limit = 2

    /// Drawn in full, in `WindowModel.chips`' order.
    public let shown: [AgentChip]
    /// Folded into the "+N more" chip, in the same order.
    public let hidden: [AgentChip]

    public init(_ chips: [AgentChip]) {
        if chips.count <= Self.limit {
            shown = chips
            hidden = []
        } else {
            shown = Array(chips.prefix(Self.limit))
            hidden = Array(chips.dropFirst(Self.limit))
        }
    }

    /// The folded chip's state: the strongest among `hidden`, or nil when nothing is folded.
    public var hiddenState: AgentChip.State? {
        hidden.map(\.state).max { $0.precedence < $1.precedence }
    }

    /// The folded chip's text.
    public var moreLabel: String { "+\(hidden.count) more" }
}
