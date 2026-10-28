import Foundation

/// What a conversation is doing, for its row and its dot: `AgentChip.state`'s precedence
/// (waiting, failed, working, done), and `idle` when none holds.
public enum ConversationState: String, Sendable, Equatable {
    case working, waiting, done, failed, idle

    public static func of(waiting: Bool, failed: Bool, working: Bool, done: Bool) -> ConversationState {
        if waiting { return .waiting }
        if failed { return .failed }
        if working { return .working }
        if done { return .done }
        return .idle
    }
}

/// A conversation with no first message yet.
public let newConversationTitle = "New conversation"

/// The longest a title runs.
private let conversationTitleLimit = 48

/// A conversation's title: its first message with whitespace collapsed; when longer than 48
/// characters, the first whole words that fit in 24, " … ", then the last whole words that fit
/// in 21. When no whole word fits either budget, the first 47 characters and "…".
/// "New conversation" when empty.
public func conversationTitle(_ firstMessage: String) -> String {
    let words = firstMessage.split(whereSeparator: \.isWhitespace).map(String.init)
    let text = words.joined(separator: " ")
    guard !text.isEmpty else { return newConversationTitle }
    guard text.count > conversationTitleLimit else { return text }
    let cut = String(text.prefix(conversationTitleLimit - 1)) + "…"
    var head: [String] = []
    var used = 0
    for word in words {
        let next = used + (head.isEmpty ? 0 : 1) + word.count
        guard next <= 24 else { break }
        head.append(word)
        used = next
    }
    guard !head.isEmpty else { return cut }
    var tail: [String] = []
    used = 0
    for word in words.dropFirst(head.count).reversed() {
        let next = used + (tail.isEmpty ? 0 : 1) + word.count
        guard next <= 21 else { break }
        tail.insert(word, at: 0)
        used = next
    }
    guard !tail.isEmpty else { return cut }
    return head.joined(separator: " ") + " … " + tail.joined(separator: " ")
}

/// The hand-off a handed conversation carries (ticket noticing, Task 9): the ticket key (nil for
/// a PR with no key), its PR, the thread it was handed from (nil from the header or ⌘P), the root
/// and branch it works on, and May push as the Start or the carried record said it.
public struct PlaceAgentHandoff: Sendable, Equatable {
    public let key: String?
    public let pr: Int?
    public let thread: String?
    public let root: String
    public let branch: String
    public let mayPush: Bool

    public init(key: String?, pr: Int?, thread: String?, root: String, branch: String, mayPush: Bool) {
        self.key = key
        self.pr = pr
        self.thread = thread
        self.root = root
        self.branch = branch
        self.mayPush = mayPush
    }

    /// The same hand-off with May push as the gate prices it now.
    func priced(mayPush: Bool) -> PlaceAgentHandoff {
        PlaceAgentHandoff(key: key, pr: pr, thread: thread, root: root, branch: branch, mayPush: mayPush)
    }
}

/// One live conversation as the window lists it.
public struct LiveConversation: Sendable, Equatable {
    public let id: String
    public let session: String?
    public let place: Place
    public let title: String
    public let state: ConversationState
    public let onScreen: Bool
    public let lastActivity: Date
    /// Whether its place's environment is production, so its row keeps production red
    /// (Invariant 8): the chip's own reading (`PlaceAgent.productionEnvironment`).
    public let isProduction: Bool
    /// The hand-off it was started by, when it is handed (ticket noticing): `session_list` says
    /// `handed`, and then its key and thread.
    public let handoff: PlaceAgentHandoff?

    public init(
        id: String, session: String?, place: Place, title: String, state: ConversationState,
        onScreen: Bool, lastActivity: Date, isProduction: Bool = false, handoff: PlaceAgentHandoff? = nil
    ) {
        self.id = id
        self.session = session
        self.place = place
        self.title = title
        self.state = state
        self.onScreen = onScreen
        self.lastActivity = lastActivity
        self.isProduction = isProduction
        self.handoff = handoff
    }

    /// `<org> · <project> · <environment>`, empty members left out: the chip's label.
    public var placeLabel: String {
        [place.organization, place.project, place.environment].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "conversation": .string(id),
            "session": session.map { .string($0) } ?? .null,
            "organization": .string(place.organization),
            "project": .string(place.project),
            "environment": .string(place.environment),
            "title": .string(title),
            "state": .string(state.rawValue),
            "onScreen": .bool(onScreen),
            "handed": .bool(handoff != nil),
        ]
        if let handoff {
            o["key"] = handoff.key.map { .string($0) } ?? .null
            o["thread"] = handoff.thread.map { .string($0) } ?? .null
        }
        return .object(o)
    }
}
