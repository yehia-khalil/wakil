import Testing
@testable import WakilKit

struct HunkCase: Sendable, CustomStringConvertible {
    let name: String, base: String, text: String, hunks: [EditorHunk]
    var description: String { name }
}
private func h(_ k: EditorHunk.Kind, _ start: Int, _ count: Int, _ old: [String] = []) -> EditorHunk {
    EditorHunk(kind: k, newStart: start, newCount: count, oldLines: old)
}

private let cases: [HunkCase] = [
    HunkCase(name: "an added line", base: "a\nc\n", text: "a\nb\nc\n", hunks: [h(.added, 2, 1)]),
    HunkCase(name: "a changed line", base: "a\nb\nc\n", text: "a\nB\nc\n", hunks: [h(.changed, 2, 1, ["b"])]),
    HunkCase(name: "a deleted line", base: "a\nb\nc\n", text: "a\nc\n", hunks: [h(.deleted, 2, 0, ["b"])]),
    HunkCase(name: "a deletion at the end", base: "a\nb\n", text: "a\n", hunks: [h(.deleted, 2, 0, ["b"])]),
    HunkCase(name: "a deletion at the start", base: "a\nb\n", text: "b\n", hunks: [h(.deleted, 1, 0, ["a"])]),
    HunkCase(name: "a missing final newline (R9)", base: "a\nb\n", text: "a\nb", hunks: []),
    HunkCase(name: "CRLF", base: "a\r\nb\r\n", text: "a\r\nB\r\n", hunks: [h(.changed, 2, 1, ["b\r"])]),
    HunkCase(name: "an empty base", base: "", text: "x\ny\n", hunks: [h(.added, 1, 2)]),
    HunkCase(name: "an empty text", base: "x\ny\n", text: "", hunks: [h(.deleted, 1, 0, ["x", "y"])]),
    HunkCase(name: "identical texts", base: "a\nb\n", text: "a\nb\n", hunks: []),
    HunkCase(name: "two hunks, one unchanged line apart", base: "a\nb\nc\n", text: "A\nb\nC\nd\n",
         hunks: [h(.changed, 1, 1, ["a"]), h(.changed, 3, 2, ["c"])]),
    HunkCase(name: "added at the end with no final newline", base: "a", text: "a\nb", hunks: [h(.added, 2, 1)]),
    HunkCase(name: "deleted at the end with no final newline", base: "a\nb", text: "a", hunks: [h(.deleted, 2, 0, ["b"])]),
]

@Suite struct EditorHunksTests {
    @Test(arguments: cases) func hunksAreGroupedAsTheSpecReadsThem(_ c: HunkCase) {
        #expect(editorHunks(base: c.base, text: c.text) == c.hunks)
    }

    // Review Focus 3: Revert puts the exact base text back — every hunk, last first.
    @Test(arguments: cases) func revertRestoresTheBaseText(_ c: HunkCase) {
        guard !c.hunks.isEmpty else { return }
        var text = c.text
        for hunk in editorHunks(base: c.base, text: c.text).reversed() {
            let e = editorRevertEdit(hunk, text: text)
            text = editorReplacing(text, e.range, with: e.text)
        }
        #expect(text == c.base)
    }

    @Test func marksSitOnTheirLinesAndADeletionBetweenTwo() {
        let hunks = [h(.added, 2, 2), h(.changed, 5, 1, ["x"]), h(.deleted, 7, 0, ["y"]), h(.deleted, 1, 0, ["z"])]
        #expect(editorGutterMarks(hunks) == [
            EditorGutterMark(kind: .added, start: 2, end: 3), EditorGutterMark(kind: .changed, start: 5, end: 5),
            EditorGutterMark(kind: .deletedBelow, start: 6, end: 6), EditorGutterMark(kind: .deletedAbove, start: 1, end: 1)])
    }

    @Test func aLineFindsTheHunkWhoseMarkItCarries() {
        let hunks = [h(.added, 2, 2), h(.deleted, 7, 0, ["y"])]
        #expect(editorHunkIndex(at: 3, in: hunks) == 0)
        #expect(editorHunkIndex(at: 6, in: hunks) == 1, "a deletion's triangle sits on the line above it")
        #expect(editorHunkIndex(at: 5, in: hunks) == nil)
    }

    @Test func aSideOverTheLineCapGivesNoHunks() {
        let long = (0...editorHunksLineCap).map { "l\($0)" }.joined(separator: "\n") + "\n"   // 10,001 lines
        #expect(editorHunkLines(long).count == editorHunksLineCap + 1)
        #expect(editorHunks(base: "x\n", text: long).isEmpty)
        #expect(editorHunks(base: long, text: "x\n").isEmpty)
        let atCap = (1...editorHunksLineCap).map { "l\($0)" }.joined(separator: "\n") + "\n"
        #expect(!editorHunks(base: "x\n", text: atCap).isEmpty)
    }
}

// Final review 5: one render asks for the active tab's hunks several times (the peek's view, its
// captured keys, what was rendered). The memo diffs a (baseline, text) pair once.
@Test func theHunksMemoDiffsAPairOnceAndAgainOnlyWhenItChanges() {
    let memo = EditorHunksMemo()
    var runs = 0
    func hunks(_ base: String, _ text: String) -> [EditorHunk] {
        memo.hunks(base: base, text: text) { b, t in runs += 1; return editorHunksUncached(base: b, text: t) }
    }
    let first = hunks("a\nb\nc\n", "a\nB\nc\n")
    #expect(hunks("a\nb\nc\n", "a\nB\nc\n") == first)
    #expect(runs == 1)
    #expect(first == [EditorHunk(kind: .changed, newStart: 2, newCount: 1, oldLines: ["b"])])
    let other = hunks("a\nb\nc\n", "a\nb\nc\nd\n")
    #expect(runs == 2 && other == [EditorHunk(kind: .added, newStart: 4, newCount: 1, oldLines: [])])
}

@Test func theSharedHunksAreTheUncachedOnesEveryTime() {
    let base = "a\nb\nc\nd\n", text = "a\nX\nc\n"
    #expect(editorHunks(base: base, text: text) == editorHunksUncached(base: base, text: text))
    #expect(editorHunks(base: base, text: text) == editorHunksUncached(base: base, text: text))
    #expect(editorHunks(base: base, text: "a\nb\nc\nd\n").isEmpty)
}

@Suite struct EditorStagedTextTests {
    @Test func stagedTextAppliesOnlyTheChosenHunk() {
        let base = "a\nb\nc\nd\n"
        let text = "a\nB\nc\nD\n"           // two changed hunks: line 2 and line 4
        #expect(editorStagedText(base: base, text: text, hunk: 0) == "a\nB\nc\nd\n")
        #expect(editorStagedText(base: base, text: text, hunk: 1) == "a\nb\nc\nD\n")
        #expect(editorStagedText(base: base, text: text, hunk: 2) == nil)
    }

    @Test func stagedTextHandlesAnAddedAndADeletedHunk() {
        #expect(editorStagedText(base: "a\nc\n", text: "a\nb\nc\n", hunk: 0) == "a\nb\nc\n")
        #expect(editorStagedText(base: "a\nb\nc\n", text: "a\nc\n", hunk: 0) == "a\nc\n")
    }
}

@Suite struct GitBlobIdTests {
    @Test func gitBlobIdMatchesGitHashObject() {
        #expect(gitBlobId("hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(gitBlobId("") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }
}
