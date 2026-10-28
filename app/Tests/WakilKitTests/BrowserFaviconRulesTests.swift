import Foundation
import Testing
@testable import WakilKit

@Suite("Favicon rules (3d-i walk)")
struct BrowserFaviconRulesTests {
    @Test func theNamedIconIsResolvedAgainstThePage() {
        #expect(BrowserFaviconRules.url(href: "https://cdn.test/i.png", pageURL: "https://a.test/x")?.absoluteString
                == "https://cdn.test/i.png")
        #expect(BrowserFaviconRules.url(href: "/static/i.png", pageURL: "https://a.test/x/y")?.absoluteString
                == "https://a.test/static/i.png")
        #expect(BrowserFaviconRules.url(href: "i.png", pageURL: "https://a.test/x/y")?.absoluteString
                == "https://a.test/x/i.png")
    }

    @Test func aPageNamingNoIconAsksForFaviconIco() {
        #expect(BrowserFaviconRules.url(href: nil, pageURL: "https://a.test/deep/page?q=1")?.absoluteString
                == "https://a.test/favicon.ico")
        #expect(BrowserFaviconRules.url(href: "  ", pageURL: "http://localhost:3000/x")?.absoluteString
                == "http://localhost:3000/favicon.ico")
    }

    @Test func onlyHttpAndHttpsAreFetched() {
        #expect(BrowserFaviconRules.url(href: "file:///etc/passwd", pageURL: "https://a.test/") == nil)
        #expect(BrowserFaviconRules.url(href: "ftp://a.test/i.ico", pageURL: "https://a.test/") == nil)
        #expect(BrowserFaviconRules.url(href: "javascript:alert(1)", pageURL: "https://a.test/") == nil)
        // A data icon is decoded elsewhere, never fetched; a page that is not web has no origin.
        #expect(BrowserFaviconRules.url(href: "data:image/png;base64,AAAA", pageURL: "https://a.test/") == nil)
        #expect(BrowserFaviconRules.isData("DATA:image/png,x"))
        #expect(BrowserFaviconRules.url(href: nil, pageURL: "about:blank") == nil)
        #expect(BrowserFaviconRules.url(href: nil, pageURL: "file:///tmp/a.html") == nil)
    }

    @Test func theSizeAndTypeRule() {
        #expect(BrowserFaviconRules.accepts(status: 200, mimeType: "image/png", byteCount: 1000))
        #expect(BrowserFaviconRules.accepts(status: 200, mimeType: "image/x-icon; charset=binary", byteCount: 64 * 1024))
        #expect(BrowserFaviconRules.accepts(status: 200, mimeType: nil, byteCount: 10))
        #expect(BrowserFaviconRules.accepts(status: 200, mimeType: "application/octet-stream", byteCount: 10))
        #expect(!BrowserFaviconRules.accepts(status: 200, mimeType: "image/png", byteCount: 64 * 1024 + 1))
        #expect(!BrowserFaviconRules.accepts(status: 200, mimeType: "image/png", byteCount: 0))
        #expect(!BrowserFaviconRules.accepts(status: 404, mimeType: "image/png", byteCount: 10))
        #expect(!BrowserFaviconRules.accepts(status: 200, mimeType: "text/html", byteCount: 10))
    }
}
