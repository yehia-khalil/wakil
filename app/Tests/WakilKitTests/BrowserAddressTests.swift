import Testing
import Foundation
@testable import WakilKit

/// **The browser's address rule** (3c-i): what the address field does with typed text.
@Suite struct BrowserAddressTests {
    @Test func typedTextBecomesAURLOrASearch() {
        let google = "https://www.google.com/search?q="
        let table: [(String, String?)] = [
            ("api.initech.dev/docs", "https://api.initech.dev/docs"),
            ("localhost:3000", "http://localhost:3000"),
            ("localhost", "http://localhost"),
            ("127.0.0.1:8080/x", "http://127.0.0.1:8080/x"),
            ("[::1]:8080", "http://[::1]:8080"),
            ("10.0.0.5", "http://10.0.0.5"),
            ("foo.test", "https://foo.test"),
            ("http://example.com", "http://example.com"),
            ("mailto:a@b.c", "mailto:a@b.c"),
            ("file:///tmp/a.html", "file:///tmp/a.html"),
            ("  api.initech.dev  ", "https://api.initech.dev"),
            ("confirm booking 409", google + "confirm%20booking%20409"),
            ("swift.org is great", google + "swift.org%20is%20great"),
            ("swift", google + "swift"),
            ("a&b=c+d#e?f", google + "a%26b%3Dc%2Bd%23e%3Ff"),
            ("  ", nil),
            ("", nil),
        ]
        for (typed, expected) in table {
            #expect(BrowserAddress.resolve(typed, searchEngine: "google")?.absoluteString == expected,
                    "typed: \(typed)")
            // looksLikeAddress is exactly "resolve would not search" (3c-iii).
            let searches = expected == nil || expected!.hasPrefix(google)
            #expect(BrowserAddress.looksLikeAddress(typed) == !searches, "looksLikeAddress: \(typed)")
        }
    }

    @Test func eachEngineHasItsOwnPrefixAndAnUnknownOneFallsBackToGoogle() {
        let expected = [
            "duckduckgo": "https://duckduckgo.com/?q=hi",
            "bing": "https://www.bing.com/search?q=hi",
            "kagi": "https://kagi.com/search?q=hi",
            "google": "https://www.google.com/search?q=hi",
            "nonsense": "https://www.google.com/search?q=hi",
        ]
        for (engine, url) in expected {
            #expect(BrowserAddress.resolve("hi", searchEngine: engine)?.absoluteString == url, "\(engine)")
        }
    }

    @Test func isSecureIsHTTPSFileAndLoopbackHTTP() {
        #expect(BrowserAddress.isSecure(URL(string: "https://example.com")!))
        #expect(BrowserAddress.isSecure(URL(string: "file:///tmp/a.html")!))
        #expect(!BrowserAddress.isSecure(URL(string: "http://example.com")!))
        #expect(BrowserAddress.isSecure(URL(string: "http://localhost:3000")!))
        #expect(BrowserAddress.isSecure(URL(string: "http://127.0.0.1:8080")!))
        #expect(BrowserAddress.isSecure(URL(string: "http://[::1]:8080")!))
    }

    @Test func displayHostDropsWwwAndNamesAFileByItsName() {
        #expect(BrowserAddress.displayHost(URL(string: "https://www.github.com/x")!) == "github.com")
        #expect(BrowserAddress.displayHost(URL(string: "http://localhost:3000/a")!) == "localhost")
        #expect(BrowserAddress.displayHost(URL(string: "file:///tmp/a.html")!) == "a.html")
    }

    /// The padlock's hover (the footer's host and transport, moved into the address field): the
    /// host and how the page came — loopback http is not called Not Secure, as the padlock is drawn
    /// there; http anywhere else is — and the certificate's reason when it was not trusted.
    @Test func theLockNamesTheHostAndHowThePageCame() {
        let https = BrowserAddress.lockDetail(URL(string: "https://example.com/")!)
        #expect(https == "example.com over TLS. The certificate is trusted.")
        let loopback = BrowserAddress.lockDetail(URL(string: "http://localhost:3000/a")!)
        #expect(loopback?.hasPrefix("localhost over plain HTTP") == true)
        #expect(loopback?.contains("Not Secure") == false)
        #expect(BrowserAddress.lockDetail(URL(string: "http://127.0.0.1:8080")!)?.contains("Not Secure") == false)
        #expect(BrowserAddress.lockDetail(URL(string: "http://example.com/")!)?.hasPrefix("Not Secure: example.com over plain HTTP") == true)
        #expect(BrowserAddress.lockDetail(URL(string: "file:///tmp/a.html")!) == "A file on this Mac.")
        #expect(BrowserAddress.lockDetail(URL(string: "about:blank")!) == nil, "a blank page: no padlock")
        let refused = BrowserAddress.lockDetail(
            URL(string: "https://self-signed.example/")!,
            certificate: "self-signed.example's certificate isn't trusted — it is self-signed")
        #expect(refused == "self-signed.example over TLS.\nself-signed.example's certificate isn't trusted — it is self-signed",
                "the reason, whole, and no claim that the certificate is trusted")
    }
}
