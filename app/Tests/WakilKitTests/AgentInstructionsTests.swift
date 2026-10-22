import Foundation
import Testing
@testable import WakilKit

@Suite struct AgentInstructionsTests {
    @Test func composesOrgThenProjectUnderTheirHeadings() {
        let text = agentInstructions(
            org: "initech", orgTexts: AgentTexts(general: "Ask first", commits: "Imperative", pullRequests: "What / How"),
            project: "api", projectTexts: AgentTexts(general: "No staging migrations", commits: "Ticket key", pullRequests: ""))
        #expect(text == """
            ## Organisation initech — general
            Ask first

            ## Organisation initech — commits
            Imperative

            ## Organisation initech — pull requests
            What / How

            ## Project api — general
            No staging migrations

            ## Project api — commits
            Ticket key
            """)
    }

    @Test func emptyTextsAndTheirHeadingsAreOmitted() {
        let text = agentInstructions(org: "initech", orgTexts: AgentTexts(general: "  ", commits: "C", pullRequests: ""),
                                     project: nil, projectTexts: nil)
        #expect(text == "## Organisation initech — commits\nC")
    }

    @Test func nothingAtAllComposesEmpty() {
        #expect(agentInstructions(org: "initech", orgTexts: AgentTexts(), project: "api", projectTexts: AgentTexts()) == "")
    }

    @Test func theLaunchAppendsAfterWakilsOwnRules() {
        let launch = buildLaunch(claudePath: "/c", sessionId: "s", configDir: "/d", oauthToken: "t", mcpConfigJSON: "{}",
                                 allowedTools: [], workingDirectory: "/w", appendedInstructions: "## Organisation o — general\nX")
        guard let i = launch.arguments.firstIndex(of: "--append-system-prompt") else {
            Issue.record("no --append-system-prompt"); return
        }
        let value = launch.arguments[i + 1]
        #expect(value.hasPrefix(agentSystemPrompt))
        #expect(value.hasSuffix("\n\n## Organisation o — general\nX"))
        let plain = buildLaunch(claudePath: "/c", sessionId: "s", configDir: "/d", oauthToken: "t", mcpConfigJSON: "{}",
                                allowedTools: [], workingDirectory: "/w")
        #expect(plain.arguments[plain.arguments.firstIndex(of: "--append-system-prompt")! + 1] == agentSystemPrompt)
    }

    @Test func theBoxAnswersByOrgAndProject() {
        let box = AgentInstructionsBox()
        box.set(org: "initech", project: "api", text: "P")
        box.set(org: "initech", project: nil, text: "O")
        #expect(box.text(org: "initech", project: "api") == "P")
        #expect(box.text(org: "initech", project: "web") == "O")
        #expect(box.text(org: "umbrella", project: "api") == "")
    }

    @Test func theDraftCarriesTheCommitRules() {
        let r = CommitDraft.request(diff: "", truncated: false, files: ["a.go"], untracked: [], examples: [],
                                    commitInstructions: "Reference the ticket key")
        #expect(r.instructions.contains("Follow these commit rules:\nReference the ticket key"))
        let none = CommitDraft.request(diff: "", truncated: false, files: ["a.go"], untracked: [], examples: [])
        #expect(!none.instructions.contains("Follow these commit rules"))
    }
}

/// 3a-iii-b, Task 5: past 2,000 words a box says what length costs; nothing is refused.
@Test func aBoxPastTwoThousandWordsHintsAtTheCost() {
    #expect(agentInstructionsSizeHint(String(repeating: "word ", count: 2_000)) == nil)
    #expect(agentInstructionsSizeHint(String(repeating: "word ", count: 2_001))
            == "Long instructions ride on every turn the agent takes")
    #expect(agentInstructionsSizeHint("") == nil)
}
