import Foundation
import Testing
@testable import WakilKit

/// 3a-ii-b: the commit draft's prompt and parser (Decision 42: a prompt and a parser over `respond`).
@Suite struct CommitDraftTests {
    private func diff(file: String, added: Int) -> String {
        "diff --git a/\(file) b/\(file)\n--- a/\(file)\n+++ b/\(file)\n@@ -1,0 +1,\(added) @@\n"
            + (1...added).map { "+line \($0)\n" }.joined()
    }

    @Test func theDiffIsCutAtFifteenHundredLinesAndEveryFileStillNamed() {
        let text = diff(file: "a.go", added: 1_000) + diff(file: "b.go", added: 990) + diff(file: "c.go", added: 5)
        let r = CommitDraft.request(diff: text, truncated: false, files: [], untracked: [], examples: [])
        let diffLines = r.input.components(separatedBy: "\n").filter { $0.hasPrefix("+line") }
        #expect(diffLines.count <= CommitDraft.lineCap)
        for stat in ["a.go +1000 −0", "b.go +990 −0", "c.go +5 −0"] { #expect(r.input.contains(stat), "\(stat)") }
        #expect(r.input.contains("cut"))
        #expect(r.jsonSchema == CommitDraft.replySchema)
        #expect(r.maxTokens == 300)
    }

    @Test func aWholeDiffIsNotSaidToBeCut() {
        let r = CommitDraft.request(diff: diff(file: "a.go", added: 3), truncated: false, files: [], untracked: [], examples: [])
        #expect(!r.input.contains("cut"))
        #expect(r.input.contains("+line 3"))
    }

    @Test func examplesAreTheLastFiveFromHistory() {
        let r = CommitDraft.request(diff: diff(file: "a.go", added: 1), truncated: false, files: [], untracked: [],
                                    examples: ["one", "two", "three", "four", "five", "six"])
        for m in ["one", "two", "three", "four", "five"] { #expect(r.instructions.contains(m)) }
        #expect(!r.instructions.contains("six"))
    }

    @Test func noExamplesAsksForAnImperativeSubject() {
        let r = CommitDraft.request(diff: diff(file: "a.go", added: 1), truncated: false, files: [], untracked: [], examples: [])
        #expect(r.instructions.contains("imperative"))
    }

    @Test func untrackedFilesAreNamedWithoutTheirContents() {
        let r = CommitDraft.request(diff: "", truncated: false, files: [], untracked: ["new.go"], examples: [])
        #expect(r.input.contains("new.go"))
    }

    @Test func onlyBinaryFilesStillProduceANonEmptyInput() {
        let bin = "diff --git a/p.png b/p.png\nnew file mode 100644\nindex 0000000..e69de29\nBinary files /dev/null and b/p.png differ\n"
        let r = CommitDraft.request(diff: bin, truncated: false, files: [], untracked: [], examples: [])
        #expect(r.input.contains("p.png binary"))
    }

    @Test func aRenameKeepsBothNames() {
        let mv = "diff --git a/old.go b/new.go\nsimilarity index 100%\nrename from old.go\nrename to new.go\n"
        let r = CommitDraft.request(diff: mv, truncated: false, files: [], untracked: [], examples: [])
        #expect(r.input.contains("old.go → new.go"))
    }

    @Test func parseTakesTheMessageTrimmed() throws {
        #expect(try CommitDraft.parse(#"{"message":"  Fix login\n"}"#) == "Fix login")
        #expect(try CommitDraft.parse("```json\n{\"message\":\"Add x\"}\n```") == "Add x")
    }

    @Test func parseRefusesAnEmptyMessage() {
        #expect(throws: QuickModelError.failed("the model returned no message")) { try CommitDraft.parse(#"{"message":"  "}"#) }
        #expect(throws: (any Error).self) { try CommitDraft.parse("not json") }
    }

    // Final review I5: the file list is git status's, so a file past git_diff's cut is still named,
    // and a diff that came back empty still names what is staged.
    @Test func everyStatusFileIsNamedEvenWhenTheDiffMissesIt() {
        let r = CommitDraft.request(diff: diff(file: "a.go", added: 2), truncated: true, files: ["a.go", "z.go"],
                                    untracked: [], examples: [])
        #expect(r.input.contains("a.go +2 −0"))
        #expect(r.input.contains("\nz.go\n") || r.input.hasSuffix("\nz.go"))
        let empty = CommitDraft.request(diff: "", truncated: false, files: ["s.go"], untracked: [], examples: [])
        #expect(empty.input.contains("s.go"))
    }
}
