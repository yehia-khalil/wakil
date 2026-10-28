import Testing

@testable import WakilKit

/// 3d-i, ruling 12: naming an automatic group with the `respond` quick task, pure.
@Suite("Browser group names")
struct BrowserGroupNamesTests {
    private func tab(_ id: String, _ title: String, group: String? = "g1") -> BrowserTab {
        BrowserTab(id: id, url: "https://example.com/\(id)", title: title, loaded: true, group: group)
    }

    private func pane(_ tabs: [BrowserTab], groups: [BrowserGroup]) -> BrowserSnapshot {
        BrowserSnapshot(tabs: tabs, active: tabs.first?.id, find: nil, downloads: [], closed: [],
                        nextTab: tabs.count + 1, groups: groups, nextGroup: 2)
    }

    private func group(_ id: String = "g1", kind: BrowserGroupKind = .automatic, named: Bool = false) -> BrowserGroup {
        BrowserGroup(id: id, name: "Site", colour: .blue, kind: kind, siteKey: "example.com", named: named)
    }

    @Test func requestCarriesTitlesOnly() {
        let r = BrowserGroupNames.request(titles: ["Rust docs", "Async book"])
        #expect(r.input == "Rust docs\nAsync book")
        #expect(!r.input.contains("http"))
        #expect(r.maxTokens == 20)
        #expect(r.jsonSchema == BrowserGroupNames.replySchema)
        #expect(r.instructions == #"Name this group of browser tabs from their titles. Answer with at most three words and no punctuation, as JSON: {"name": "..."}."#)
    }

    @Test func titlesAreTheFirstFiveInOpeningOrder() {
        let tabs = [tab("t12", "twelve"), tab("t3", "three"), tab("t5", ""), tab("t1", "one"), tab("t2", "two"),
                    tab("t4", "four"), tab("t9", "nine"), tab("t7", "other", group: "g2")]
        let s = pane(tabs, groups: [group()])
        #expect(BrowserGroupNames.titles(of: "g1", in: s) == ["one", "two", "three", "four", "nine"])
    }

    @Test func aNamedTabSendsItsNameAndCountsAsTitled() {
        var invoices = tab("t1", "")
        invoices.name = "Invoices"
        let tabs = [invoices, tab("t2", "Stripe")]
        let s = pane(tabs, groups: [group()])
        #expect(BrowserGroupNames.titles(of: "g1", in: s) == ["Invoices", "Stripe"])
        #expect(BrowserGroupNames.due(s) == ["g1"])
    }

    @Test func dueNeedsTwoTitledTabsAndAnUnnamedAutomaticGroup() {
        let tabs = [
            tab("t1", "a", group: "g1"), tab("t2", "b", group: "g1"),
            tab("t3", "a", group: "g2"), tab("t4", "", group: "g2"),
            tab("t5", "a", group: "g3"), tab("t6", "b", group: "g3"),
            tab("t7", "a", group: "pr"), tab("t8", "b", group: "pr"),
            tab("t9", "a", group: "g5"), tab("t10", "b", group: "g5"),
        ]
        let groups = [group("g1"), group("g2"), group("g3", kind: .own), group("pr", kind: .pullRequests),
                      group("g5", named: true)]
        #expect(BrowserGroupNames.due(pane(tabs, groups: groups)) == ["g1"])
    }

    @Test func parseKeepsThreeWordsWithoutQuotesOrPunctuation() throws {
        #expect(try BrowserGroupNames.parse(#"{"name":"\"Rust async docs, part 2.\""}"#) == "Rust async docs")
        #expect(try BrowserGroupNames.parse(#"{"name":"  Mail  "}"#) == "Mail")
    }

    @Test func parseReadsInsideACodeFence() throws {
        #expect(try BrowserGroupNames.parse("```json\n{\"name\": \"Travel plans\"}\n```") == "Travel plans")
    }

    @Test func parseRefusesAnEmptyName() {
        for reply in [#"{"name":"\"...\""}"#, #"{"name":""}"#, "not json", #"{"other":"x"}"#] {
            #expect(throws: QuickModelError.invalidReply("the model's reply was not a group name: \(reply)")) {
                try BrowserGroupNames.parse(reply)
            }
        }
    }
}
