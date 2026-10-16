import Foundation
import Testing
@testable import WakilKit

@Test func accessorsReadTodaysNumberCase() {
    #expect(JSONValue.number(42).doubleValue == 42)
    #expect(JSONValue.number(42).int64Value == 42)
    #expect(JSONValue.number(42).intValue == 42)
    #expect(JSONValue.number(1.5).doubleValue == 1.5)
}

/// The guards `safeInt`/`safeInt64` already enforce must survive being
/// moved behind an accessor: these values trap if converted with a bare
/// `Int(_:)`, which is the whole reason those functions exist.
@Test func accessorsRefuseWhatSafeIntRefuses() {
    #expect(JSONValue.number(1.5).int64Value == nil)
    #expect(JSONValue.number(1.5).intValue == nil)
    #expect(JSONValue.number(1e300).intValue == nil)
    #expect(JSONValue.number(.nan).intValue == nil)
    #expect(JSONValue.number(.infinity).int64Value == nil)
    // 1e15 is where a Double stops representing every integer exactly.
    #expect(JSONValue.number(1e15).int64Value == nil)
}

@Test func accessorsAreNilForNonNumbers() {
    #expect(JSONValue.string("42").doubleValue == nil)
    #expect(JSONValue.string("42").intValue == nil)
    #expect(JSONValue.bool(true).int64Value == nil)
    #expect(JSONValue.null.doubleValue == nil)
}

@Test func aWholeNumberDecodesExactlyAndReEncodesUnchanged() throws {
    let wire = #"[9007199254740993,1.5,42]"#
    let decoded = try JSONDecoder().decode([JSONValue].self, from: Data(wire.utf8))

    #expect(decoded[0] == .integer(9007199254740993))
    #expect(decoded[0].int64Value == 9007199254740993)
    #expect(decoded[1] == .number(1.5))
    #expect(decoded[2] == .integer(42))

    let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)
    #expect(reencoded == wire)
}

/// `18446744073709551615` is `UInt64.max`, past `Int64.max`
/// (`9223372036854775807`) by more than double — the decoder's `Int64`
/// attempt must fail for it, same as it does for a fraction, and fall
/// back to `.number` rather than trap or silently wrap. Nothing else in
/// this file exercises that fallback; every other case here is well
/// within `Int64`'s range.
@Test func aMagnitudePastInt64FallsBackToDouble() throws {
    let decoded = try JSONDecoder().decode(
        [JSONValue].self, from: Data("[18446744073709551615]".utf8))
    guard case .number = decoded[0] else {
        return #expect(Bool(false), "expected .number, got \(decoded[0])")
    }
}

@Test func accessorsReadTheIntegerCase() {
    #expect(JSONValue.integer(9007199254740993).int64Value == 9007199254740993)
    #expect(JSONValue.integer(42).intValue == 42)
    #expect(JSONValue.integer(42).doubleValue == 42)
    // An Int64 needs no narrowing, so no bound applies to it — unlike the
    // .number path, where 1e15 is where a Double stops being exact.
    #expect(JSONValue.integer(9007199254740993).intValue == 9007199254740993)
}

@Test func twoRepresentationsOfOneValueAreEqual() {
    #expect(JSONValue.integer(5) == .number(5))
    #expect(JSONValue.number(5) == .integer(5))
    #expect(JSONValue.integer(0) == .number(0))
    #expect(JSONValue.integer(-7) == .number(-7))
    // Nested, because this is how the test suite actually compares things.
    #expect(JSONValue.object(["n": .integer(5)]) == .object(["n": .number(5)]))
    #expect(JSONValue.array([.integer(1)]) == .array([.number(1)]))
}

/// The pair that must be UNEQUAL, and the reason the whole fix exists.
/// `Double(9007199254740993)` IS `9007199254740992.0`, so a comparison that
/// converts the integer to a Double would call these equal and reintroduce
/// the bug inside the equality operator.
@Test func twoDistinctLargeIntegersAreNotEqual() {
    #expect(JSONValue.integer(9007199254740993) != .number(9007199254740992))
    #expect(JSONValue.integer(9007199254740993) != .integer(9007199254740992))
}

@Test func aFractionIsNeverEqualToAnInteger() {
    #expect(JSONValue.integer(5) != .number(5.5))
    #expect(JSONValue.number(.nan) != .integer(0))
    #expect(JSONValue.number(.infinity) != .integer(Int64.max))
}

@Test func nonNumericEqualityIsUnchanged() {
    #expect(JSONValue.string("5") != .integer(5))
    #expect(JSONValue.bool(true) != .integer(1))
    #expect(JSONValue.null != .integer(0))
    #expect(JSONValue.string("a") == .string("a"))
}

@Test func aLargeKeyDrawsItsOwnDigits() {
    #expect(PaneCell(.integer(9007199254740993)).text == "9007199254740993")
    #expect(PaneCell(.integer(42)).text == "42")
    #expect(PaneCell(.integer(-1)).text == "-1")
    #expect(PaneCell(.integer(Int64.max)).text == "9223372036854775807")
    #expect(PaneCell(.integer(0)).isNull == false)
}

/// The .number path keeps its 1e15 guard, because a Double is still a
/// Double — this is what the fix REPLACES, not what it changes.
@Test func theDoublePathIsUnchanged() {
    #expect(PaneCell(.number(42)).text == "42")
    #expect(PaneCell(.number(1.5)).text == "1.5")
}

/// Documents intent, but does not by itself discriminate the fix: these
/// three keys tie or differ under `Double` in a way that happens to make
/// `localizedStandardCompare`'s fallthrough land on the same order the
/// exact-integer branch produces, for both digit runs of this length and
/// sign. `negativeLargeKeysSortByMagnitudeNotSignedText` below is the case
/// that actually fails without the branch.
@Test func twoDistinctLargeKeysDoNotTieInTheSort() {
    let rows: [[JSONValue]] = [
        [.integer(9007199254740993)],
        [.integer(9007199254740992)],
        [.integer(9007199254740994)],
    ]
    let sorted = sortedRows(
        rows, by: [PaneSort(column: "id", direction: .ascending)], columns: ["id"])
    #expect(sorted.map { PaneCell($0[0]).text } == [
        "9007199254740992", "9007199254740993", "9007199254740994",
    ])
}

/// `localizedStandardCompare` does not treat `-` as part of the digit run,
/// so it compares the two keys' magnitudes rather than their signed
/// values. `-9007199254740992` and `-9007199254740993` tie as `Double`
/// (both round to the same value past 2^53), so without the exact-integer
/// branch the comparator falls through to text and orders them by
/// magnitude — 993 > 992 — putting the more-negative key LAST:
/// `["-9007199254740992", "-9007199254740993"]`, backwards in both
/// directions. This is the case that actually fails without the fix.
@Test func negativeLargeKeysSortByMagnitudeNotSignedText() {
    let rows: [[JSONValue]] = [
        [.integer(-9007199254740992)],
        [.integer(-9007199254740993)],
    ]
    let ascending = sortedRows(
        rows, by: [PaneSort(column: "id", direction: .ascending)], columns: ["id"])
    #expect(ascending.map { PaneCell($0[0]).text } == [
        "-9007199254740993", "-9007199254740992",
    ])
    let descending = sortedRows(
        rows, by: [PaneSort(column: "id", direction: .descending)], columns: ["id"])
    #expect(descending.map { PaneCell($0[0]).text } == [
        "-9007199254740992", "-9007199254740993",
    ])
}

@Test func integersAndFractionsSortTogetherByValue() {
    let rows: [[JSONValue]] = [[.integer(10)], [.number(2.5)], [.integer(1)]]
    let sorted = sortedRows(
        rows, by: [PaneSort(column: "n", direction: .ascending)], columns: ["n"])
    #expect(sorted.map { PaneCell($0[0]).text } == ["1", "2.5", "10"])
}
