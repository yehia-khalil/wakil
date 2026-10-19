import Testing
@testable import WakilKit

private func schemaIDs() -> [Identifier] {
    func t(_ s: String) -> Identifier { Identifier(text: s, kind: .table, origin: "staging · core db", source: .schema) }
    func c(_ s: String) -> Identifier { Identifier(text: s, kind: .column, origin: "staging · core db", source: .schema) }
    return [t("bookings"), c("id"), c("status"), c("confirmed_at"), t("guests"), c("id"), c("email"),
            t("booking_items"), c("id"), t("audit_logs"), c("id")]
}

private actor GhostCounter { var value = 0; func bump() { value += 1 } }

/// Per-key gate: `wait` parks until `open`; `waitUntilWaiting` lets a test know the call is parked.
private actor Gate {
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<String> = []

    func wait(_ key: String) async {
        if opened.contains(key) { return }
        await withCheckedContinuation { waiting[key] = $0 }
    }

    func waitUntilWaiting(_ key: String) async {
        while waiting[key] == nil { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func open(_ key: String) {
        opened.insert(key)
        waiting.removeValue(forKey: key)?.resume()
    }
}

private func req(_ prefix: String) -> InfillRequest {
    InfillRequest(prefix: prefix, suffix: "", path: "", language: "", extras: [], multiline: false)
}

@Suite struct GhostTextTests {
    @Test func tablesRegroupTheFlatList() {
        let ts = GhostSchema.tables(from: schemaIDs())
        #expect(ts.map(\.name) == ["bookings", "guests", "booking_items", "audit_logs"])
        #expect(ts[0].columns == ["id", "status", "confirmed_at"])
    }

    @Test func matchingTakesSingularPluralSnakeAndCamel() {
        let ts = GhostSchema.tables(from: schemaIDs())
        #expect(GhostSchema.matching(ts, in: "func confirm(b *Booking) {").map(\.name) == ["bookings"])
        #expect(GhostSchema.matching(ts, in: "$item = BookingItem::find($id);").map(\.name) == ["booking_items"])
        #expect(GhostSchema.matching(ts, in: "SELECT guest_id FROM x").map(\.name) == ["guests"])
        #expect(GhostSchema.matching(ts, in: "AuditLog.create()").map(\.name) == ["audit_logs"])
        #expect(GhostSchema.matching(ts, in: "const x = 1").isEmpty)
        #expect(GhostSchema.extra([]) == nil)
    }

    @Test func matchingHandlesSesPluralsAndTrailingParts() {
        func match(_ names: [String], _ text: String) -> [String] {
            GhostSchema.matching(names.map { GhostTable(name: $0, columns: ["id"]) }, in: text).map(\.name)
        }
        #expect(match(["databases"], "Database") == ["databases"])
        #expect(match(["responses"], "Response") == ["responses"])
        #expect(match(["statuses"], "Status") == ["statuses"])
        #expect(match(["purchases"], "Purchase") == ["purchases"])
        #expect(match(["boxes"], "Box") == ["boxes"])
        let both = ["bookings", "booking_items"]
        #expect(match(both, "booking_item_id") == ["booking_items"])
        #expect(match(both, "BookingItemId") == ["booking_items"])
        #expect(match(both, "booking_id") == ["bookings"])
    }

    @Test func matchingStopsAtFive() {
        let many = (0..<8).map { GhostTable(name: "t\($0)s", columns: ["id"]) }
        let text = (0..<8).map { "t\($0)" }.joined(separator: " ")
        #expect(GhostSchema.matching(many, in: text).count == 5)
    }

    @Test func extraIsCreateTableLines() {
        #expect(GhostSchema.extra([GhostTable(name: "bookings", columns: ["id", "status"])]) ==
                QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id, status);\n"))
    }

    @Test func windowsCutAtLinesAndFlagEmptyLines() {
        let body = String(repeating: "x\n", count: 4_000)
        let text = body + "b.\n}\n"
        let caret = text.index(text.startIndex, offsetBy: body.count + 2)
        let r = ghostRequest(text: text, caret: caret, path: "a.go", language: "go", schema: [])
        #expect(r.prefix.hasSuffix("b."))
        #expect(r.prefix.count <= 6_000 && (r.prefix.first == "x"))
        #expect(r.suffix == "\n}\n")
        #expect(!r.multiline)
        let blank = "func f() {\n    \n}"
        let at = blank.index(blank.startIndex, offsetBy: 15)
        #expect(ghostRequest(text: blank, caret: at, path: "a.go", language: "go", schema: []).multiline)
    }

    @Test func windowsKeepALineWhenTheCutIsAlreadyOnABoundary() {
        // 6,000 chars of "xxxxxxxxx\n" lines: the window starts exactly at a line start.
        let line = "xxxxxxxxx\n"
        let text = String(repeating: line, count: 700)
        let r = ghostRequest(text: text, caret: text.endIndex, path: "", language: "", schema: [])
        #expect(r.prefix.count == 6_000 && r.prefix.hasPrefix(line))
        let tailText = "a\n" + String(repeating: "y", count: 1_998) + "\nnext\n"
        let s = ghostRequest(text: tailText, caret: tailText.startIndex, path: "", language: "", schema: [])
        #expect(s.suffix.count == 2_000)
    }

    @Test func windowsKeepCRLFAndEmoji() {
        let text = "a = \"🙂\"\r\nb."
        let r = ghostRequest(text: text, caret: text.endIndex, path: "a.go", language: "go", schema: [])
        #expect(r.prefix == text && r.suffix.isEmpty)
    }

    @Test func requestCarriesMatchedSchemaOnly() {
        let ts = GhostSchema.tables(from: schemaIDs())
        let text = "b := Booking{}\nb."
        let r = ghostRequest(text: text, caret: text.endIndex, path: "a.go", language: "go", schema: ts)
        #expect(r.extras == [QuickExtra(name: "schema.sql", text: "CREATE TABLE bookings (id, status, confirmed_at);\n")])
    }

    @Test func cleanTrimsSuffixEchoWhitespaceAndLines() {
        #expect(ghostClean("guest_id, status FROM bookings WHERE guest_id = ?\", gid)", suffix: " FROM bookings WHERE guest_id = ?\", gid)", multiline: false) == "guest_id, status")
        #expect(ghostClean("i++ {  \n", suffix: "", multiline: false) == "i++ {")
        #expect(ghostClean("a\nb", suffix: "", multiline: false) == "a")
        #expect(ghostClean((1...9).map(String.init).joined(separator: "\n"), suffix: "", multiline: true).split(separator: "\n").count == 6)
        #expect(ghostClean("   ", suffix: "", multiline: false) == "")
        #expect(ghostClean("\nstatus", suffix: "", multiline: false) == "status")
        #expect(ghostClean("x FROM y  ", suffix: " FROM y", multiline: false) == "x")
    }

    @Test func staleReplyIsDropped() async {
        let gate = Gate()
        let s = GhostTextSession(suggest: { r in await gate.wait(r.prefix); return r.prefix + "!" }, debounce: { .zero })
        async let first = s.request(req("a"))
        await gate.waitUntilWaiting("a")
        async let second = s.request(req("ab"))
        await gate.open("a"); await gate.open("ab")
        #expect(await first == nil)
        #expect(await second == "ab!")
    }

    @Test func supersededCallerReturnsWhileItsSuggestIsStillRunning() async {
        let gate = Gate()
        let s = GhostTextSession(suggest: { r in await gate.wait(r.prefix); return r.prefix + "!" }, debounce: { .zero })
        async let first = s.request(req("a"))
        await gate.waitUntilWaiting("a")
        async let second = s.request(req("ab"))
        #expect(await first == nil)   // "a" is still parked in the gate
        await gate.open("a"); await gate.open("ab")
        #expect(await second == "ab!")
    }

    @Test func cancelReleasesTheWaiter() async {
        let gate = Gate()
        let s = GhostTextSession(suggest: { r in await gate.wait(r.prefix); return "x" }, debounce: { .zero })
        async let first = s.request(req("a"))
        await gate.waitUntilWaiting("a")
        await s.cancel()
        #expect(await first == nil)
        await gate.open("a")
    }

    @Test func failureReturnsNil() async {
        struct Boom: Error {}
        let s = GhostTextSession(suggest: { _ in throw Boom() }, debounce: { .zero })
        #expect(await s.request(req("a")) == nil)
    }

    @Test func debounceSupersedesWithoutAsking() async {
        let asked = GhostCounter()
        let s = GhostTextSession(suggest: { _ in await asked.bump(); return "x" }, debounce: { .milliseconds(300) })
        async let a = s.request(req("a"))
        try? await Task.sleep(for: .milliseconds(5))
        async let b = s.request(req("ab"))
        #expect(await a == nil)
        #expect(await b == "x")
        #expect(await asked.value == 1)
    }
}
