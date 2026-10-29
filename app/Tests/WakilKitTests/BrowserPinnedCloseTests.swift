import Foundation
import Testing
@testable import WakilKit

@Suite struct BrowserPinnedCloseTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aFirstPressArmsASecondWithinTwoSecondsCloses() {
        #expect(BrowserPinnedClose.press(nil, pane: "browser-1", tab: "t1", now: t0) == .arm)
        let arm = BrowserCloseArm(pane: "browser-1", tab: "t1", at: t0)
        #expect(BrowserPinnedClose.press(arm, pane: "browser-1", tab: "t1", now: t0.addingTimeInterval(1.9)) == .close)
    }

    @Test func aPressAfterTwoSecondsArmsAgain() {
        let arm = BrowserCloseArm(pane: "browser-1", tab: "t1", at: t0)
        #expect(BrowserPinnedClose.press(arm, pane: "browser-1", tab: "t1", now: t0.addingTimeInterval(2.1)) == .arm)
    }

    @Test func aSecondPressOnAnotherTabArmsAgain() {
        let arm = BrowserCloseArm(pane: "browser-1", tab: "t1", at: t0)
        #expect(BrowserPinnedClose.press(arm, pane: "browser-1", tab: "t2", now: t0.addingTimeInterval(0.5)) == .arm)
        #expect(BrowserPinnedClose.press(arm, pane: "browser-2", tab: "t1", now: t0.addingTimeInterval(0.5)) == .arm)
    }

    /// The tip names Close Tab's chord in force, so a rebinding reaches it.
    @Test func tipNamesTheChordInForce() {
        #expect(BrowserPinnedClose.tip(KeyChord("⌘W")) == "Press ⌘W again to close")
        #expect(BrowserPinnedClose.tip(KeyChord("⌃⌘W")) == "Press ⌃⌘W again to close")
        #expect(BrowserPinnedClose.tip(nil) == "Choose Close Tab again to close")
    }
}
