import Foundation
import Testing
@testable import WakilKit

@Suite struct ThoughtRowBrowserTests {
    private func reply(_ thread: String) -> String {
        "{\"ok\":true,\"thread\":\"\(thread)\"}"
    }

    private func result(_ content: JSONValue, isError: Bool = false) -> ThoughtRow? {
        thoughtRow(id: 3, for: .toolResult(id: "t1", content: content, isError: isError))
    }

    @Test func aBrowserResultShowsItsThreadLine() {
        let content = JSONValue.array([.object(["type": .string("text"),
                                                "text": .string(reply("typed into \\\"Guest name\\\""))])])
        #expect(result(content) == ThoughtRow(id: 3, label: "browser", detail: "typed into \"Guest name\"", isError: false))
    }

    @Test func aStringResultIsReadToo() {
        let row = result(.string(reply("clicked \\\"Save\\\"")))
        #expect(row == ThoughtRow(id: 3, label: "browser", detail: "clicked \"Save\"", isError: false))
    }

    @Test func aResultWithoutAThreadKeepsTodaysRow() {
        let row = result(.string("{\"ok\":true}"))
        #expect(row == ThoughtRow(id: 3, label: "tool result", detail: PaneCell(.string("{\"ok\":true}")).text, isError: false))
        #expect(threadLine(fromToolResult: .string("plain words")) == nil)
        #expect(threadLine(fromToolResult: .string("{\"thread\":5}")) == nil)
    }

    @Test func aRefusedActKeepsItsError() {
        let text = "browser_click: the page changed since it was read — read it again (browser_read_page)."
        let row = result(.string(text), isError: true)
        #expect(row == ThoughtRow(id: 3, label: "tool result", detail: PaneCell(.string(text)).text, isError: true))
    }

    @Test func theUntrustedNoticeIsKnown() {
        let notice = result(.string(reply("1 page · untrusted text from example.com")))
        #expect(notice?.isUntrustedNotice == true)
        let typed = result(.string(reply("typed into \\\"Guest name\\\"")))
        #expect(typed?.isUntrustedNotice == false)
        #expect(ThoughtRow(id: 1, label: "tool", detail: "1 page · untrusted text from example.com", isError: false).isUntrustedNotice == false)
    }
}
