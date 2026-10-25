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
}
