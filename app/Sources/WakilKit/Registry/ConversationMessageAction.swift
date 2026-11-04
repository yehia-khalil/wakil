import Foundation

/// `conversation_message`'s refusals (workspaces piece 4), each a whole sentence (Rule 8).
public struct ConversationMessageRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}

/// `conversation_message {to, text}` (workspaces piece 4): **`.control`** — a message changes
/// only Wakil's own state, two threads and an input — and **agent-reachable**: it is how an agent
/// tells another conversation something. Information only, never approval (decision 2): nothing the
/// gate or the permission plane reads carries it.
///
/// `to` is a live conversation's id, or its title when that names exactly one live conversation of
/// the sender's organisation (`session_list`'s live rows). The sender is the caller's conversation,
/// which must be live: the operator writes in the conversation itself. Refused, whole: an empty
/// text, one over 4,000 characters, no sending conversation, a past or unknown recipient, the
/// sender itself, another organisation's. Checked here, before parking, so the caller hears it.
///
/// A builder, as `conversationRenameAction` is, so a test can register it into a window's own
/// registry. `liveConversations` nil (no window) refuses every send: nothing is live.
public func conversationMessageAction(
    conversationRequests: ConversationBroker,
    liveConversations: (@Sendable (Place?) async -> [LiveConversation])?
) -> Action {
    Action(
        name: "conversation_message",
        description: "Send a message to another live conversation of this organization — one that "
            + "session_list lists under `live`, by its `conversation` id or its title. Information "
            + "only: the other agent is told it is not the operator and cannot approve anything. It "
            + "reads it at the head of its next input; an idle one is woken with it, within the "
            + "workspace's Agents woken by messages, or it waits for the operator. At most 4,000 characters.",
        kind: .control,
        audience: .agentReachable,
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "to": .object(["type": .string("string")]),
                "text": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("text")]),
        ]),
        handler: { params in
            guard case .object(let fields) = params, case .string(let to)? = fields["to"] else {
                throw StandardActionError.missingParam(action: "conversation_message", param: "to")
            }
            guard case .string(let text)? = fields["text"] else {
                throw StandardActionError.missingParam(action: "conversation_message", param: "text")
            }
            let recipient = try await checkConversationMessage(
                to: to, text: text, sender: ActionRegistry.dispatchCaller?.conversation,
                live: await liveConversations?(nil) ?? [])
            await conversationRequests.request(.message(
                from: ActionRegistry.dispatchCaller?.conversation ?? "", to: recipient.id, text: text))
            return .object(["to": .string(recipient.id), "title": .string(recipient.title)])
        })
}

/// The recipient `to` names, or the refusal, whole. Pure, so each refusal is tested alone.
public func checkConversationMessage(
    to: String, text: String, sender: String?, live: [LiveConversation]
) throws -> LiveConversation {
    func refuse(_ why: String) -> ConversationMessageRefusal {
        ConversationMessageRefusal(description: "conversation_message: " + why)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw refuse("the message is empty — write what the other conversation should know")
    }
    if text.count > conversationMessageLimit {
        throw refuse("the message is \(text.count) characters; at most 4,000 go — shorten it, or "
            + "send the rest in a second message")
    }
    guard let sender, let from = live.first(where: { $0.id == sender }) else {
        throw refuse("a message is sent from a live conversation, and this call names none — the "
            + "operator writes in the conversation itself")
    }
    let ownOrganisation = live.filter { $0.place.organization == from.place.organization }
    let recipient: LiveConversation
    if let byId = live.first(where: { $0.id == to }) {
        recipient = byId
    } else {
        let byTitle = ownOrganisation.filter { $0.title == to }
        if byTitle.count > 1 {
            throw refuse("‘\(to)’ is the title of \(byTitle.count) live conversations — name one by "
                + "its id, from session_list")
        }
        guard let only = byTitle.first else {
            throw refuse("no live conversation ‘\(to)’ — a past or unknown conversation cannot be "
                + "messaged; session_list's live rows can")
        }
        recipient = only
    }
    if recipient.id == from.id {
        throw refuse("‘\(recipient.title)’ is the sending conversation itself")
    }
    if recipient.place.organization != from.place.organization {
        // Its title is not said: another organisation's names stay behind its boundary.
        throw refuse("\(to) is a conversation of another organisation, and messages stay inside "
            + "one (Invariant 4)")
    }
    return recipient
}
