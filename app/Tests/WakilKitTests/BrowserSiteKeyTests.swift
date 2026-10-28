import Testing

@testable import WakilKit

@Suite("Browser site key")
struct BrowserSiteKeyTests {
    @Test("siteKeysFollowTheRule", arguments: [
        ("https://www.youtube.com/watch", "family:youtube"),
        ("https://youtu.be/x", "family:youtube"),
        ("https://initech.atlassian.net/browse/X-1", "family:atlassian"),
        ("https://initech.atlassian.net/wiki", "family:atlassian"),
        ("https://raw.githubusercontent.com/a", "family:github"),
        ("https://docs.google.com/spreadsheets/d/1", "family:google-docs"),
        ("https://www.google.com/search?q=x", "google.com"),
        ("https://www.amazon.co.uk/dp/1", "amazon.co.uk"),
        ("https://a.example.github.io", "example.github.io"),
        ("https://b.example.github.io", "example.github.io"),
        ("http://localhost:3000/x", "localhost:3000"),
        ("http://app.test:8080", "app.test:8080"),
        ("http://127.0.0.1:5173", "127.0.0.1:5173"),
    ])
    func siteKeysFollowTheRule(url: String, key: String) {
        #expect(BrowserSiteKey.of(url) == key)
    }

    @Test func privateSectionSitesDiffer() {
        #expect(BrowserSiteKey.of("https://a.github.io") != BrowserSiteKey.of("https://b.github.io"))
        #expect(BrowserSiteKey.of("https://x.a.github.io") == BrowserSiteKey.of("https://y.a.github.io"))
    }

    @Test func otherSchemesHaveNoKey() {
        #expect(BrowserSiteKey.of("file:///tmp/a.html") == nil)
        #expect(BrowserSiteKey.of("about:blank") == nil)
    }

    @Test func wildcardAndExceptionRulesApply() {
        // `*.ck` makes `bar.ck` a suffix; `!www.ck` makes `www.ck` registrable.
        #expect(BrowserSiteKey.registrableDomain("foo.bar.ck") == "foo.bar.ck")
        #expect(BrowserSiteKey.registrableDomain("a.foo.bar.ck") == "foo.bar.ck")
        #expect(BrowserSiteKey.registrableDomain("bar.ck") == "bar.ck")
        #expect(BrowserSiteKey.registrableDomain("www.ck") == "www.ck")
        #expect(BrowserSiteKey.registrableDomain("a.www.ck") == "www.ck")
        #expect(BrowserSiteKey.registrableDomain("x.city.kawasaki.jp") == "city.kawasaki.jp")
        #expect(BrowserSiteKey.registrableDomain("x.other.kawasaki.jp") == "x.other.kawasaki.jp")
        #expect(BrowserSiteKey.registrableDomain("com") == "com")
        #expect(BrowserSiteKey.registrableDomain("co.uk") == "co.uk")
        #expect(BrowserSiteKey.registrableDomain("unknownsuffix") == "unknownsuffix")
    }

    @Test func namesUseTheFamilyElseTheFirstLabel() {
        #expect(BrowserSiteKey.name("family:github") == "GitHub")
        #expect(BrowserSiteKey.name("amazon.co.uk") == "Amazon")
        #expect(BrowserSiteKey.name("localhost:3000") == "localhost:3000")
        #expect(BrowserSiteKey.name("127.0.0.1:5173") == "127.0.0.1:5173")
    }
}
