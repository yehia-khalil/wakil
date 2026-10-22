import Testing
@testable import WakilKit

private func s(_ a: Int, _ b: Int) -> EditorLineSpan { EditorLineSpan(start: a, end: b) }
private func r(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> EditorRange {
    EditorRange(start: EditorPosition(line: l1, column: c1), end: EditorPosition(line: l2, column: c2))
}

/// 3a-ii-b: Stage and Unstage Selected Ranges, pure.
@Suite struct EditorRangesTests {
    @Test func stagesOnlyTheSelectedLinesOfAnAddedHunk() {
        #expect(editorStagedText(base: "a\nd\n", text: "a\nb\nc\nx\nd\n", ranges: [s(2, 3)]) == "a\nb\nc\nd\n")
    }

    // Amended 2026-10-22 (Cover): a changed block pairs its old and new lines one to one.
    @Test func aChangedHunkPairsItsLines() {
        #expect(editorStagedText(base: "a\nold1\nold2\nz\n", text: "a\nnew1\nnew2\nz\n", ranges: [s(2, 2)])
            == "a\nnew1\nold2\nz\n")
        // A selected new line past the old ones is an addition; an unselected one is left out.
        #expect(editorStagedText(base: "alpha\nbeta\n", text: "alpha\nBETA\ngamma\n", ranges: [s(3, 3)])
            == "alpha\nbeta\ngamma\n")
        #expect(editorStagedText(base: "alpha\nbeta\n", text: "alpha\nBETA\ngamma\n", ranges: [s(2, 2)])
            == "alpha\nBETA\n")
        // Old lines past the new ones go only when the whole block is selected.
        #expect(editorStagedText(base: "a\nb\nc\nz\n", text: "a\nB\nz\n", ranges: [s(2, 2)]) == "a\nB\nz\n")
    }

    @Test func aDeletionIsStagedFromTheLineItsMarkSitsOn() {
        #expect(editorStagedText(base: "a\nb\nc\n", text: "a\nc\n", ranges: [s(1, 1)]) == "a\nc\n")
        #expect(editorStagedText(base: "a\nb\nc\n", text: "a\nc\n", ranges: [s(2, 2)]) == nil)
    }

    @Test func aCaretStagesTheHunkUnderIt() {
        #expect(editorLineSpans([r(3, 4, 3, 4)]) == [s(3, 3)])
    }

    @Test func aWholeLineDragDoesNotTakeTheNextLine() {
        #expect(editorLineSpans([r(2, 1, 4, 1)]) == [s(2, 3)])
        // A drag ending at column 1 of the line it started on is still that line.
        #expect(editorLineSpans([r(2, 1, 2, 1)]) == [s(2, 2)])
    }

    @Test func twoRangesStageTheirUnion() {
        let base = "a\nb\nc\nd\n", text = "a\nX\nb\nc\nY\nd\n"
        #expect(editorStagedText(base: base, text: text, ranges: [s(2, 2), s(5, 5)]) == text)
        #expect(editorStagedText(base: base, text: text, ranges: [s(5, 5)]) == "a\nb\nc\nY\nd\n")
    }

    @Test func contextOnlyIsNil() {
        let base = "a\nb\nc\n", text = "a\nb\nc\nd\n"
        #expect(editorStagedText(base: base, text: text, ranges: [s(1, 2)]) == nil)
        #expect(!editorRangesTouchChange(base: base, text: text, ranges: [s(1, 2)]))
        #expect(editorRangesTouchChange(base: base, text: text, ranges: [s(3, 4)]))
    }

    @Test func theLastLineWithoutANewlineKeepsItsEnding() {
        #expect(editorStagedText(base: "a\nb", text: "a\nb\nc", ranges: [s(3, 3)]) == "a\nb\nc")
        // Staging a line above leaves the index's own missing final newline alone.
        #expect(editorStagedText(base: "a\nb", text: "X\na\nb\n", ranges: [s(1, 1)]) == "X\na\nb")
    }

    @Test func crlfLinesKeepTheirEndings() {
        #expect(editorStagedText(base: "a\r\nb\r\n", text: "a\r\nX\r\nb\r\n", ranges: [s(2, 2)]) == "a\r\nX\r\nb\r\n")
    }

    @Test func stageRoundTripLeavesOnlyTheUnselectedChanges() {
        let base = "a\nb\nc\nd\ne\n", text = "A\nb\nC\nd\nE\n"
        let staged = editorStagedText(base: base, text: text, ranges: [s(3, 3)])
        #expect(staged == "a\nb\nC\nd\ne\n")
        #expect(editorHunks(base: staged ?? "", text: text).count == 2)
    }

    @Test func unstageRevertsOnlyTheSelectedPart() {
        #expect(editorUnstagedText(base: "a\nb\n", text: "a\nX\nY\nb\n", ranges: [s(2, 2)]) == "a\nY\nb\n")
        #expect(editorUnstagedText(base: "", text: "p\nq\n", ranges: [s(1, 2)]) == "")
        // Amended 2026-10-22 (Cover): paired line by line — n1 goes back to old, n2 stays an addition.
        #expect(editorUnstagedText(base: "a\nold\nz\n", text: "a\nn1\nn2\nz\n", ranges: [s(2, 2)]) == "a\nold\nn2\nz\n")
        #expect(editorUnstagedText(base: "a\nold\nz\n", text: "a\nn1\nn2\nz\n", ranges: [s(2, 3)]) == "a\nold\nz\n")
        #expect(editorUnstagedText(base: "a\nb\n", text: "a\nb\nc\n", ranges: [s(1, 1)]) == nil)
    }

    @Test func unstageRoundTripLeavesOnlyTheUnselectedChangesStaged() {
        let head = "a\nb\nc\nd\ne\n", index = "A\nb\nC\nd\nE\n"
        let left = editorUnstagedText(base: head, text: index, ranges: [s(3, 3)])
        #expect(left == "A\nb\nc\nd\nE\n")
        #expect(editorHunks(base: head, text: left ?? "").count == 2)
    }

    // Final review I1: the last line emitted is not its side's last line, so it ends with "\n".
    @Test func aPartialSelectionBeforeAnUnterminatedLastLineKeepsItsNewline() {
        #expect(editorStagedText(base: "x\n", text: "x\na\nb", ranges: [s(2, 2)]) == "x\na\n")
        #expect(editorUnstagedText(base: "x\n", text: "x\na\nb", ranges: [s(3, 3)]) == "x\na\n")
    }

    // The e2e fixture's app.txt: "line two" changed and "line three" added, one hunk against HEAD.
    @Test func unstagingTheAddedLineOfAChangedHunkKeepsTheChangeStaged() {
        let head = "line one\nline two\n", index = "line one\nline two, staged\nline three, unstaged\n"
        #expect(editorUnstagedText(base: head, text: index, ranges: [s(3, 3)]) == "line one\nline two, staged\n")
        #expect(editorUnstagedText(base: head, text: index, ranges: [s(2, 3)]) == head)
    }
}
