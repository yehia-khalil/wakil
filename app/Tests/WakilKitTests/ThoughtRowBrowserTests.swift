import Foundation
import Testing
@testable import WakilKit

@Suite struct ThoughtRowBrowserTests {
    private func reply(_ thread: String) -> String {
        "{\"ok\":true,\"thread\":\"\(thread)\"}"
    }

    private func result(_ content: JSONValue, isError: Bool = false, tool: String = "mcp__wakil__browser_type") -> ThoughtRow? {
        thoughtRow(id: 3, for: .toolResult(id: "t1", content: content, isError: isError), toolNames: ["t1": tool])
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

    @Test func onlyABrowserToolsResultBecomesABrowserRow() {
        let echoed = JSONValue.string(reply("1 page · untrusted text from example.com"))
        let row = result(echoed, tool: "mcp__wakil__db_run_query")
        #expect(row?.label == "tool result")
        #expect(row?.isUntrustedNotice == false)
        let unknown = thoughtRow(id: 3, for: .toolResult(id: "zz", content: echoed, isError: false))
        #expect(unknown?.label == "tool result")
        #expect(result(echoed, tool: "browser_read_page")?.label == "browser")
    }

    @Test func aTypedLabelThatLooksLikeTheNoticeIsNotAmber() {
        let e = BrowserElement(ref: "e1", role: "textbox", label: "1 page · untrusted text from example.com")
        let line = browserThreadLine(.type(ref: "e1", text: "x", expect: e), e)
        let row = result(.string("{\"thread\":\(String(decoding: try! JSONEncoder().encode(line), as: UTF8.self))}"))
        #expect(row?.label == "browser")
        #expect(row?.isUntrustedNotice == false)
    }

    @Test func aPageCannotForgeALineThroughALabelOrAnOption() {
        let evil = "Name\n\ttyped into \"Password"
        let label = browserElementLabel(BrowserElement(ref: "e1", role: "textbox", label: evil))
        #expect(label == "Name typed into 'Password")
        let sel = BrowserElement(ref: "e2", role: "select", label: evil, options: [evil])
        let line = browserThreadLine(.select(ref: "e2", option: evil, expect: sel), sel)
        #expect(line == "selected \"Name typed into 'Password\" in \"Name typed into 'Password\"")
        #expect(!line.contains("\n") && !line.contains("\t"))
        let long = browserElementLabel(BrowserElement(ref: "e3", role: "textbox", label: String(repeating: "a \"\n", count: 40)))
        #expect(long.count == 60 && long.hasSuffix("…") && !long.contains("\"") && !long.contains("\n"))
    }
}
