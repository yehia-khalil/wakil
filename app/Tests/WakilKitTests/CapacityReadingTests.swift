import Testing
import Foundation
@testable import WakilKit

private let cairo: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Africa/Cairo")!   // UTC+3 on these dates
    return c
}()
private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

@Test func decodesTheCapacityToolsAnswer() throws {
    let result: JSONValue = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("read"),
                 "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
                 "asOf": .string("2026-10-10T16:18:00Z")]),
        .object(["account": .string("ollama"), "kind": .string("local"), "state": .string("noLimits")]),
    ])])])
    let listing = try #require(decodeCapacityListing(fromResult: result))
    #expect(listing.readings.map(\.account) == ["main", "ollama"])
    #expect(listing.readings[0].fiveHour?.percentLeft == 28)
    #expect(listing.readings[0].fiveHour?.resetsAt == at("2026-10-10T17:20:00Z"))
    #expect(listing.readings[0].sevenDay == nil)
    #expect(listing.readings[1].state == .noLimits)
}

@Test func lowIsTwentyOrLess() {
    let reset = at("2026-10-10T17:20:00Z")
    #expect(CapacityDisplay.isLow(CapacityWindow(percentLeft: 20, resetsAt: reset)))
    #expect(!CapacityDisplay.isLow(CapacityWindow(percentLeft: 21, resetsAt: reset)))
}

@Test func resetLabelIsTimeTodayAndWeekdayLater() {
    let now = at("2026-10-10T10:00:00Z")
    #expect(CapacityDisplay.resetLabel(at("2026-10-10T17:20:00Z"), now: now, calendar: cairo) == "20:20")
    #expect(CapacityDisplay.resetLabel(at("2026-10-16T06:00:00Z"), now: now, calendar: cairo) == "Fri 09:00")
}

@Test func paletteTextNamesBothWindowsAndFlagsLow() {
    let now = at("2026-10-10T16:30:00Z")
    let r = CapacityReading(account: "work", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 50, resetsAt: at("2026-10-10T18:05:00Z")),
        sevenDay: CapacityWindow(percentLeft: 12, resetsAt: at("2026-10-13T11:00:00Z")),
        asOf: at("2026-10-10T16:18:00Z"), error: nil)
    let shown = CapacityDisplay.paletteText(r, now: now, calendar: cairo)
    #expect(shown.text == "5h 50% · week 12%")
    #expect(shown.low)
}

@Test func paletteTextSaysWhenAWindowHasResetAndWhenItIsOld() {
    let now = at("2026-10-10T19:00:00Z")
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read,
        fiveHour: CapacityWindow(percentLeft: 28, resetsAt: at("2026-10-10T17:20:00Z")),
        sevenDay: CapacityWindow(percentLeft: 59, resetsAt: at("2026-10-16T06:00:00Z")),
        asOf: at("2026-10-10T16:18:00Z"), error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now, calendar: cairo).text == "5h reset · week 59% · as of 19:18")
}

@Test func paletteTextForTheOtherStates() {
    func reading(_ s: CapacityReading.State) -> CapacityReading {
        CapacityReading(account: "x", kind: "claude-code", state: s, fiveHour: nil, sevenDay: nil, asOf: nil, error: "boom")
    }
    let now = Date()
    #expect(CapacityDisplay.paletteText(reading(.notRead), now: now, calendar: cairo).text == "not read yet")
    #expect(CapacityDisplay.paletteText(reading(.noLimits), now: now, calendar: cairo).text == "no limits")
    #expect(CapacityDisplay.paletteText(reading(.error), now: now, calendar: cairo).text == "capacity unreadable")
}

@Test func recordParamsAreWholeSecondUTC() {
    let w = CapacityWindows(fiveHour: CapacityWindow(percentLeft: 28, resetsAt: at("2026-10-10T17:20:00Z")), sevenDay: nil)
    let p = capacityRecordParams(provider: "main", windows: w, asOf: at("2026-10-10T16:18:00Z"))
    #expect(p == .object([
        "provider": .string("main"),
        "fiveHour": .object(["percentLeft": .integer(28), "resetsAt": .string("2026-10-10T17:20:00Z")]),
        "asOf": .string("2026-10-10T16:18:00Z"),
    ]))
}

@Test func monthOnlyReadingReadsAsMonth() {
    let now = Date(timeIntervalSince1970: 1_791_712_000)
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read, fiveHour: nil, sevenDay: nil,
                            month: CapacityWindow(percentLeft: 95, resetsAt: now.addingTimeInterval(20 * 86_400)),
                            asOf: now, error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now).text == "month 95%")
}

@Test func monthAtTwentyIsLow() {
    let now = Date(timeIntervalSince1970: 1_791_712_000)
    let r = CapacityReading(account: "main", kind: "claude-code", state: .read, fiveHour: nil, sevenDay: nil,
                            month: CapacityWindow(percentLeft: 20, resetsAt: now.addingTimeInterval(86_400)),
                            asOf: now, error: nil)
    #expect(CapacityDisplay.paletteText(r, now: now).low)
}

@Test func listingDecodesMonth() throws {
    let result: JSONValue = .object(["structuredContent": .object(["readings": .array([
        .object(["account": .string("main"), "kind": .string("claude-code"), "state": .string("read"),
                 "month": .object(["percentLeft": .integer(95), "resetsAt": .string("2026-11-01T00:00:00Z")]),
                 "asOf": .string("2026-10-10T16:18:00Z")]),
    ])])])
    let listing = try #require(decodeCapacityListing(fromResult: result))
    #expect(listing.readings[0].fiveHour == nil)
    #expect(listing.readings[0].month?.percentLeft == 95)
    #expect(listing.readings[0].month?.resetsAt == at("2026-11-01T00:00:00Z"))
}
