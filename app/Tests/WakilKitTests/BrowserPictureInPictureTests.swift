import Testing
@testable import WakilKit

private let here = LayoutScope(organization: "initech", project: "p", environment: "e")
private let there = LayoutScope(organization: "initech", project: "q", environment: "e")

private func ref(_ tab: String) -> BrowserTabRef {
    BrowserTabRef(scope: here, pane: "browser-1", tab: tab)
}

private func ref(_ scope: LayoutScope, _ pane: String, _ tab: String) -> BrowserTabRef {
    BrowserTabRef(scope: scope, pane: pane, tab: tab)
}

/// A machine with `t1` shown in `here`'s browser-1.
private func showingT1(enabled: Bool = true) -> BrowserPictureInPicture {
    var pip = BrowserPictureInPicture(enabled: enabled)
    _ = pip.show(scope: here, pane: "browser-1", tab: "t1")
    return pip
}

@Test func leavingATabFloatsIt() {
    var pip = showingT1()
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t2") == [.float([ref("t1")])])
}

@Test func comingBackBringsTheFloatingTabInline() {
    var pip = showingT1()
    _ = pip.hide(scope: here, pane: "browser-1", closing: false)
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [.inline(ref("t1"))])
}

@Test func leavingTheTabYouCameBackFromFloatsItToo() {
    // Ruling 1: the tab that leaves floats, whatever else comes back.
    var pip = showingT1()
    _ = pip.show(scope: here, pane: "browser-1", tab: "t2")
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [.float([ref("t2")]), .inline(ref("t1"))])
}

@Test func comingBackToATabThatIsNotFloatingDoesNothing() {
    var pip = showingT1()
    _ = pip.hide(scope: here, pane: "browser-1", closing: false)
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [])
}

@Test func focusAloneFloatsNothing() {
    var pip = showingT1()
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [])
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [])
}

@Test func aPlaceSwitchFloatsTheTabsItHid() {
    var pip = showingT1()
    #expect(pip.hide(scope: here, pane: "browser-1", closing: false) == [.float([ref("t1")])])
}

@Test func aClosingPaneFloatsNothing() {
    var pip = showingT1()
    #expect(pip.hide(scope: here, pane: "browser-1", closing: true) == [])
}

@Test func aMaximisedPaneCoveringFloatsAndUncoveringReturns() {
    var pip = showingT1()
    #expect(pip.hide(scope: here, pane: "browser-1", closing: false) == [.float([ref("t1")])])
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [.inline(ref("t1"))])
}

@Test func nothingFloatsWhileDisabled() {
    var pip = showingT1(enabled: false)
    _ = pip.show(scope: here, pane: "browser-2", tab: "t3")
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t2") == [])
    #expect(pip.hide(scope: here, pane: "browser-2", closing: false) == [])
    #expect(pip.setMinimized(true) == [])
    // Coming back still happens for a video that floated on its own.
    _ = pip.didChange(ref("t2"), floating: true)
    #expect(pip.setMinimized(false) == [.inline(ref("t2"))])
}

@Test func minimisingOffersEveryShownTabAndRestoringBringsTheFloatingOneBack() {
    var pip = BrowserPictureInPicture()
    _ = pip.show(scope: here, pane: "browser-2", tab: "t3")
    _ = pip.show(scope: here, pane: "browser-1", tab: "t1")
    #expect(pip.setMinimized(true) == [.float([ref("t1"), ref(here, "browser-2", "t3")])])
    _ = pip.didChange(ref(here, "browser-2", "t3"), floating: true)
    #expect(pip.setMinimized(false) == [.inline(ref(here, "browser-2", "t3"))])
}

@Test func nothingIsShownWhileMinimised() {
    var pip = BrowserPictureInPicture()
    _ = pip.setMinimized(true)
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t1") == [])
    #expect(pip.show(scope: here, pane: "browser-1", tab: "t2") == [])
    #expect(!pip.isShown(ref("t2")))
}

@Test func aVideoReplacedWhileItsTabIsAwayIsPaused() {
    var pip = showingT1()
    _ = pip.hide(scope: here, pane: "browser-1", closing: false)
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.didChange(ref("t1"), floating: false) == [.pause(ref("t1"))])
    #expect(pip.floating == nil)
}

@Test func aFloatThatEndsOnScreenIsNotPaused() {
    var pip = showingT1()
    _ = pip.show(scope: here, pane: "browser-1", tab: "t2")
    _ = pip.didChange(ref("t1"), floating: true)
    _ = pip.show(scope: here, pane: "browser-1", tab: "t1")
    #expect(pip.didChange(ref("t1"), floating: false) == [])
}

@Test func aRestoredVideoIsNotPaused() {
    var pip = showingT1()
    _ = pip.hide(scope: here, pane: "browser-1", closing: false)
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.restore(ref("t1")) == [.goTo(ref("t1"))])
    #expect(pip.didChange(ref("t1"), floating: false) == [])
}

@Test func aRestoreThatCannotArrivePausesIt() {
    var pip = showingT1()
    #expect(pip.restore(ref("t1")) == [.goTo(ref("t1"))])
    #expect(pip.restoreEnded(ref("t1"), reached: false) == [.pause(ref("t1"))])
    #expect(pip.restore(ref("t1")) == [.goTo(ref("t1"))])
    #expect(pip.restoreEnded(ref("t1"), reached: true) == [])
    #expect(pip.didChange(ref("t1"), floating: false) == [])
}

@Test func closingTheFloatingTabClearsIt() {
    var pip = showingT1()
    _ = pip.didChange(ref("t1"), floating: true)
    #expect(pip.closed(ref("t1")) == [])
    #expect(pip.floating == nil)
}

@Test func aRehomedPlaceKeepsItsFloatingTab() {
    var pip = showingT1()
    _ = pip.didChange(ref("t1"), floating: true)
    pip.rehome(from: here, to: there)
    #expect(pip.show(scope: there, pane: "browser-1", tab: "t2") == [.float([ref(there, "browser-1", "t1")])])
    #expect(pip.floating?.scope == there)
}

@Test func theUnavailableLineNamesWhatIsMissing() {
    #expect(BrowserPictureInPicture.unavailableLine(missing: []) == nil)
    #expect(BrowserPictureInPicture.unavailableLine(missing: ["a:", "b:"])
        == "Picture in picture is off: this Mac's WebKit has no a:, b: — Wakil floats a video only through them.")
}

@Test func deminiaturisingLeavesAnOffScreenFloatingTabFloating() {
    var pip = showingT1()
    _ = pip.hide(scope: here, pane: "browser-1", closing: false)
    _ = pip.didChange(ref("t1"), floating: true)
    _ = pip.setMinimized(true)
    #expect(pip.setMinimized(false) == [])
    #expect(pip.floating == ref("t1"))
}
