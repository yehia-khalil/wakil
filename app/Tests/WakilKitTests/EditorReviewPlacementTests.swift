import Foundation
import Testing
@testable import WakilKit

/// `n` numbered lines, "l1\n…ln\n".
private func lines(_ n: Int, _ prefix: String = "l") -> [String] { (1...n).map { "\(prefix)\($0)" } }
private func text(_ ls: [String]) -> String { ls.joined(separator: "\n") + "\n" }

private func thread(_ id: String, _ path: String, _ line: Int, sha: String = "abc", outdated: Bool = false,
                    resolved: Bool = false, root: String = "/p/api",
                    comments: [ReviewCommentState] = [ReviewCommentState(author: "lena", body: "Nit", createdAt: "2026-10-24T09:00:00Z")]) -> ReviewThreadState {
    ReviewThreadState(id: id, path: path, line: line, outdated: outdated, resolved: resolved, comments: comments,
                      number: 212, headSHA: sha, repo: "github.com/initech/api", root: root)
}

@Suite struct EditorReviewPlacementTests {
    @Test func anUnchangedLineMapsThroughAnInsertAbove() {
        let head = lines(20)
        var buffer = head
        buffer.insert(contentsOf: ["new1", "new2", "new3"], at: 4)   // above line 10
        let p = reviewPlacement(headText: text(head), buffer: text(buffer), line: 10)
        #expect(p == ReviewPlacement(line: 13, note: nil))
    }

    @Test func anEditedLineDrawsAtTheNearestSurvivingLine() {
        let head = lines(20)
        var buffer = head
        buffer[9] = "l10 edited"
        buffer[10] = "l11 edited"
        #expect(reviewPlacement(headText: text(head), buffer: text(buffer), line: 11)
            == ReviewPlacement(line: 9, note: "line changed since"))
        // Deleted lines draw at the line above them too.
        var deleted = head
        deleted.removeSubrange(4...6)   // l5…l7
        #expect(reviewPlacement(headText: text(head), buffer: text(deleted), line: 6)
            == ReviewPlacement(line: 4, note: "line changed since"))
        // With nothing above, the nearest surviving line below.
        var top = head
        top[0] = "l1 edited"
        #expect(reviewPlacement(headText: text(head), buffer: text(top), line: 1)
            == ReviewPlacement(line: 2, note: "line changed since"))
    }

    @Test func aMissingHeadDrawsRawWithLineMayDiffer() {
        #expect(reviewPlacement(headText: nil, buffer: text(lines(50)), line: 41)
            == ReviewPlacement(line: 41, note: "line may differ"))
    }

    @Test func aLinePastTheBufferEndDrawsAtTheLastLine() {
        // GitHub's line is past what the head itself holds: nothing maps it.
        #expect(reviewPlacement(headText: text(lines(10)), buffer: text(lines(10)), line: 30)
            == ReviewPlacement(line: 10, note: "line changed since"))
        // The head's last lines were cut from the buffer.
        #expect(reviewPlacement(headText: text(lines(20)), buffer: text(lines(12)), line: 18)
            == ReviewPlacement(line: 12, note: "line changed since"))
        // And with no head, a raw line is still drawn inside the buffer.
        #expect(reviewPlacement(headText: nil, buffer: text(lines(5)), line: 9)
            == ReviewPlacement(line: 5, note: "line may differ"))
    }

    @Test func boxesOnlyForThisFilesOpenDrawnThreads() {
        let head = text(lines(60))
        let threads = [
            thread("T1", "src/auth/token.go", 41),
            thread("T2", "src/auth/session.go", 12),
            thread("T3", "src/auth/token.go", 7, outdated: true),
            thread("T4", "src/auth/token.go", 50, resolved: true),
            thread("T5", "src/auth/token.go", 3, root: "/p/web"),
        ]
        let boxes = reviewBoxes(threads: threads, path: "/p/api/src/auth/token.go", root: "/p/api",
                                headTexts: ["abc": head], buffer: head, drafts: [:], sending: [], viewer: "lena")
        #expect(boxes.map(\.thread) == ["T1", "T4"])
        // "1 of 2": the branch's open threads (T1, T2) in file order, then line order.
        #expect(boxes[0].position == "2 of 2")
        #expect(boxes[0].line == 41 && boxes[0].note == nil)
        #expect(boxes[1].resolved && boxes[1].position == "")
    }

    /// A box waits on the viewer while it is open and its last word is someone else's: the card's
    /// amber edge. A thread the viewer answered last, a resolved one, and any with no viewer known
    /// do not.
    @Test func boxWaitsOnTheViewerUntilTheyAnswer() {
        let head = text(lines(60))
        let mine = [ReviewCommentState(author: "lena", body: "Nit", createdAt: ""), ReviewCommentState(author: "me", body: "Done", createdAt: "")]
        let threads = [thread("T1", "a.go", 4), thread("T2", "a.go", 8, comments: mine), thread("T3", "a.go", 9, resolved: true)]
        let boxes = reviewBoxes(threads: threads, path: "/p/api/a.go", root: "/p/api", headTexts: ["abc": head],
                                buffer: head, drafts: [:], sending: [], viewer: "me")
        #expect(boxes.map(\.waiting) == [true, false, false])
        let unknown = reviewBoxes(threads: threads, path: "/p/api/a.go", root: "/p/api", headTexts: ["abc": head],
                                  buffer: head, drafts: [:], sending: [])
        #expect(unknown.map(\.waiting) == [false, false, false])
    }

    @Test func boxCarriesTheDraftAndSending() {
        let head = text(lines(60))
        let threads = [thread("T1", "a.go", 41), thread("T2", "a.go", 44)]
        let boxes = reviewBoxes(threads: threads, path: "/p/api/a.go", root: "/p/api", headTexts: ["abc": head],
                                buffer: head, drafts: ["T1": "Thanks, fixed."], sending: ["T2"])
        #expect(boxes[0].draft == "Thanks, fixed." && !boxes[0].sending)
        #expect(boxes[1].draft == nil && boxes[1].sending)
    }

    /// GitHub's errors beside a reply it posted are drawn on the thread's box, whole.
    @Test func boxCarriesWhatGitHubAnsweredBesideAPostedReply() {
        let head = text(lines(60))
        let threads = [thread("T1", "a.go", 41), thread("T2", "a.go", 44)]
        let said = "Posted. GitHub also answered: Could not notify subscribers"
        let boxes = reviewBoxes(threads: threads, path: "/p/api/a.go", root: "/p/api", headTexts: ["abc": head],
                                buffer: head, drafts: [:], sending: [], answers: ["T1": said])
        #expect(boxes[0].answer == said)
        #expect(boxes[1].answer == nil)
    }

    @Test func boxTextIsTheCommentVerbatim() throws {
        let body = "<img src=x onerror=alert(1)>"
        let t = thread("T1", "a.go", 2, comments: [
            ReviewCommentState(author: "lena", body: body, createdAt: "2026-10-24T09:00:00Z"),
            ReviewCommentState(author: "sam", body: "<b>also</b>", createdAt: "2026-10-24T10:00:00Z"),
        ])
        let boxes = reviewBoxes(threads: [t], path: "/p/api/a.go", root: "/p/api", headTexts: [:],
                                buffer: "x\ny\n", drafts: [:], sending: [])
        let box = try #require(boxes.first)
        #expect(box.text == body)
        #expect(box.author == "lena")
        #expect(box.replies.map(\.body) == ["<b>also</b>"])
        // The payload the page is handed carries the text as data, unchanged.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(boxes)) as? [[String: Any]]
        #expect(json?.first?["text"] as? String == body)
    }

    /// The thread whose box is on the cursor's line, as placed — `read_pane`'s `cursorThread`.
    @Test func theCursorThreadIsTheBoxOnTheCursorsLine() {
        let head = lines(20)
        var buffer = head
        buffer.insert("new", at: 0)
        var tab = EditorTab.file(path: "/p/api/a.go", root: "/p/api", text: text(buffer), mtime: 1, language: "go")
        let key = EditorReviewHead(root: "/p/api", path: "a.go", sha: "abc")
        var reviews = EditorReviewsState.empty
        reviews.reads.byRoot["/p/api"] = .init(viewer: "", threads: [thread("T1", "a.go", 10)])
        // Before the head is read, nothing is placed.
        tab.cursor = EditorPosition(line: 11, column: 1)
        #expect(editorReviewHeadsWanted(tab, reviews) == [key])
        #expect(editorCursorThread(tab, reviews) == nil)
        reviews.heads[key] = text(head)
        reviews.fetched.insert(key)
        #expect(editorReviewHeadsWanted(tab, reviews).isEmpty)
        #expect(editorCursorThread(tab, reviews) == "T1")
        tab.cursor = EditorPosition(line: 10, column: 1)
        #expect(editorCursorThread(tab, reviews) == nil)
    }
}
