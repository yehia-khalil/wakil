import Foundation
import Testing
@testable import WakilKit

/// Task 2 of the names phase: the quick-task prompt that names a conversation, and the parser that reads its reply.
@Suite struct ConversationNamesTests {
    @Test func theRequestSendsTheMessageAndTheReplyCut() {
        let r = ConversationNames.request(firstMessage: String(repeating: "m", count: 1200), replyStart: String(repeating: "r", count: 900))
        #expect(r.instructions.hasPrefix("Name this conversation"))
        #expect(r.input == "MESSAGE: " + String(repeating: "m", count: 1000) + "\n\nREPLY: " + String(repeating: "r", count: 600))
        #expect(r.maxTokens == 24)
        #expect(r.jsonSchema == ConversationNames.replySchema)
    }

    @Test func anEmptyReplyIsSentEmpty() {
        #expect(ConversationNames.request(firstMessage: "hi", replyStart: "").input == "MESSAGE: hi\n\nREPLY: ")
    }

    @Test(arguments: [
        (#"{"name":"Fix the flaky login test"}"#, "Fix the flaky login test"),
        (#"{"name":"\"Staging deploy migration failure.\""}"#, "Staging deploy migration failure"),
        (#"{"name":"one two three four five six seven"}"#, "one two three four five"),
        ("```json\n{\"name\":\"Fix C++ build\"}\n```", "Fix C++ build"),
        (#"{"name":"Supercalifragilisticexpialidocious antidisestablishmentarianism words"}"#, "Supercalifragilisticexpialidocious"),
    ])
    func theReplyIsReadAsAName(_ reply: String, _ name: String) throws {
        #expect(try ConversationNames.parse(reply) == name)
    }

    @Test(arguments: ["not json", #"{"name":"  "}"#, #"{"title":"x"}"#])
    func aReplyThatIsNotANameThrowsItWhole(_ reply: String) {
        #expect(throws: QuickModelError.invalidReply("the model's reply was not a conversation name: \(reply)")) {
            try ConversationNames.parse(reply)
        }
    }
}
