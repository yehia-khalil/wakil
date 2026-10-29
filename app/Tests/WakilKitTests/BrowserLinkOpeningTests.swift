import Testing
@testable import WakilKit

@Suite("Browser link opening")
struct BrowserLinkOpeningTests {
    @Test func aCommandClickOpensInTheBackground() {
        #expect(BrowserLinkOpening.opensInBackground(command: true, buttonNumber: 1))
        #expect(BrowserLinkOpening.opensInBackground(command: true, buttonNumber: 0))
    }

    @Test func aMiddleClickDoesUnderWebKitsNumberAndAppKits() {
        #expect(BrowserLinkOpening.opensInBackground(command: false, buttonNumber: 4), "WebKit's middle button")
        #expect(BrowserLinkOpening.opensInBackground(command: false, buttonNumber: 2), "AppKit's number for it")
    }

    @Test func anOrdinaryClickLoadsInPlace() {
        #expect(!BrowserLinkOpening.opensInBackground(command: false, buttonNumber: 1))
        #expect(!BrowserLinkOpening.opensInBackground(command: false, buttonNumber: 0))
    }
}
