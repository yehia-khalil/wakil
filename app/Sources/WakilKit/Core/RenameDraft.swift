import Foundation

/// What a typed name does to the name shown (names, Calls made 4 and 10). The line is cleaned,
/// never refused (`cleanConversationName`): nothing left is a clear — never a blank title — and a
/// line that cleans to the shown name changes nothing.
public enum RenameDraft: Sendable, Equatable {
    case keep
    case set(String)
    case clear

    public static func decide(typed: String, shown: String) -> RenameDraft {
        guard let name = cleanConversationName(typed) else { return .clear }
        return name == shown || name == cleanConversationName(shown) ? .keep : .set(name)
    }

    /// The `name` the rename action is dispatched with: empty clears. `nil` for `.keep`.
    public var name: String? {
        switch self {
        case .keep: nil
        case .set(let name): name
        case .clear: ""
        }
    }
}
