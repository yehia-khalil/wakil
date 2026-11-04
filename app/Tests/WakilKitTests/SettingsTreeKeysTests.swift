import Foundation
import Testing
@testable import WakilKit

/// The settings tree's keyboard (settings revamp): ↑/↓ step through the visible rows and stop at
/// the ends; typed letters find the next row whose label starts with them.

@Test func stepMovesThroughRowsAndStopsAtTheEnds() {
    let rows = ["a", "b", "c"]
    #expect(SettingsTreeKeys.step(rows, from: "b", by: 1) == "c")
    #expect(SettingsTreeKeys.step(rows, from: "c", by: 1) == "c")
    #expect(SettingsTreeKeys.step(rows, from: "a", by: -1) == "a")
    #expect(SettingsTreeKeys.step(rows, from: nil, by: 1) == "a")
    #expect(SettingsTreeKeys.step(rows, from: "gone", by: -1) == "a")
    #expect(SettingsTreeKeys.step([String](), from: nil, by: 1) == nil)
}

@Test func findStartsAfterTheCurrentRowAndWrapsOnce() {
    let rows: [(node: Int, label: String)] = [
        (1, "Editor"), (2, "Browser"), (3, "Keyboard"), (4, "Browsing data"), (5, "Speech"),
    ]
    #expect(SettingsTreeKeys.find(rows, prefix: "b", after: 2) == 4)
    #expect(SettingsTreeKeys.find(rows, prefix: "b", after: 4) == 2)
    #expect(SettingsTreeKeys.find(rows, prefix: "ke", after: nil) == 3)
    #expect(SettingsTreeKeys.find(rows, prefix: "z", after: 1) == nil)
}

@Test func findIgnoresCaseAndDiacritics() {
    let rows: [(node: Int, label: String)] = [(1, "Café"), (2, "STAGING")]
    #expect(SettingsTreeKeys.find(rows, prefix: "cafe", after: nil) == 1)
    #expect(SettingsTreeKeys.find(rows, prefix: "sta", after: nil) == 2)
}

@Test func findAnswersTheCurrentRowWhenItIsTheOnlyMatch() {
    // Typing more letters of the selected row's name keeps it selected.
    let rows: [(node: Int, label: String)] = [(1, "Keyboard"), (2, "Editor")]
    #expect(SettingsTreeKeys.find(rows, prefix: "key", after: 1) == 1)
}

@Test func typeAheadJoinsLettersWithinASecond() {
    var typed = TypeAhead()
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(typed.append("s", at: t0) == "s")
    #expect(typed.append("t", at: t0.addingTimeInterval(0.5)) == "st")
    #expect(typed.append("t", at: t0.addingTimeInterval(1.6)) == "t")
}
