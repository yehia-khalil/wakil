import Foundation
import Testing
@testable import WakilKit

@Suite struct BrowserPasswordPageRulesTests {
    // MARK: Messages

    @Test func aFieldMessageCarriesItsRoleAndRect() {
        let body: [String: Any] = ["kind": "field", "role": "password",
                                   "rect": ["x": 10, "y": 20.5, "w": 200, "h": 24] as [String: Any]]
        #expect(BrowserPasswordPageMessage.parse(body)
            == .field(role: .password, rect: BrowserPasswordRect(x: 10, y: 20.5, width: 200, height: 24)))
    }

    @Test func aNewPasswordFieldIsItsOwnRole() {
        let body: [String: Any] = ["kind": "field", "role": "new", "rect": ["x": 0, "y": 0, "w": 1, "h": 1]]
        guard case .field(let role, _)? = BrowserPasswordPageMessage.parse(body) else {
            Issue.record("not a field")
            return
        }
        #expect(role == .new)
    }

    @Test func aSubmitCarriesTheLoginAndWhetherItIsNew() {
        let body: [String: Any] = ["kind": "submit", "username": "walker", "password": "walk-test-pass-1",
                                   "isNew": true]
        #expect(BrowserPasswordPageMessage.parse(body)
            == .submit(username: "walker", password: "walk-test-pass-1", isNew: true))
        #expect(BrowserPasswordPageMessage.parse(["kind": "blur"]) == .blur)
    }

    @Test func anythingElseIsNothing() {
        let bad: [Any] = [
            "submit", 42, ["kind": "fill"], ["kind": "field", "role": "card", "rect": ["x": 0, "y": 0, "w": 1, "h": 1]],
            ["kind": "field", "role": "password"],
            ["kind": "field", "role": "password", "rect": ["x": "0", "y": 0, "w": 1, "h": 1]],
            ["kind": "field", "role": "password", "rect": ["x": true, "y": 0, "w": 1, "h": 1]],
            ["kind": "field", "role": "password", "rect": ["x": 0, "y": 0, "w": -1, "h": 1]],
            ["kind": "field", "role": "password", "rect": ["x": Double.nan, "y": 0, "w": 1, "h": 1]],
            ["kind": "submit", "username": "walker"],
            ["kind": "submit", "username": "walker", "password": 7],
            ["kind": "submit", "username": "walker",
             "password": String(repeating: "x", count: BrowserPasswordPageMessage.maxValueLength + 1)],
        ]
        for body in bad { #expect(BrowserPasswordPageMessage.parse(body) == nil) }
    }

    @Test func theOriginIsRebuiltFromTheFramesSecurityOrigin() {
        #expect(BrowserPasswordPageMessage.origin(protocol: "http", host: "127.0.0.1", port: 8123)
            == "http://127.0.0.1:8123")
        #expect(BrowserPasswordPageMessage.origin(protocol: "https", host: "example.com", port: 0)
            == "https://example.com")
        #expect(BrowserPasswordPageMessage.origin(protocol: "file", host: "", port: 0) == nil)
        #expect(BrowserPasswordPageMessage.origin(protocol: "about", host: "", port: 0) == nil)
        #expect(BrowserPasswordPageMessage.origin(protocol: "javascript", host: "x", port: 0) == nil)
    }

    @Test func theOriginGivesTheLoginsSite() throws {
        let origin = try #require(BrowserPasswordPageMessage.origin(protocol: "http", host: "127.0.0.1", port: 8123))
        #expect(BrowserPasswords.siteKey(origin) == "127.0.0.1:8123")
    }

    // MARK: The key

    @Test func theKeySitsInsideTheFieldsRightEdgeAtTheZoom() {
        let field = BrowserPasswordRect(x: 100, y: 40, width: 200, height: 20)
        #expect(BrowserPasswordKeyLayout.frame(field: field, zoom: 1)
            == BrowserPasswordRect(x: 280, y: 42, width: 16, height: 16))
        #expect(BrowserPasswordKeyLayout.frame(field: field, zoom: 2)
            == BrowserPasswordRect(x: 580, y: 92, width: 16, height: 16))
        #expect(BrowserPasswordKeyLayout.frame(field: field, zoom: 0)
            == BrowserPasswordKeyLayout.frame(field: field, zoom: 1))
    }

    @Test func theKeyShowsOnANewPasswordFieldOrWhereALoginIsSaved() {
        #expect(BrowserPasswordKeyLayout.showsKey(role: .new, read: false, hasLogins: nil))
        #expect(BrowserPasswordKeyLayout.showsKey(role: .new, read: true, hasLogins: false))
        #expect(BrowserPasswordKeyLayout.showsKey(role: .password, read: true, hasLogins: true))
        #expect(!BrowserPasswordKeyLayout.showsKey(role: .password, read: true, hasLogins: false))
        #expect(!BrowserPasswordKeyLayout.showsKey(role: .username, read: true, hasLogins: false))
        // Not read yet: no key flashes on a site with no login.
        #expect(!BrowserPasswordKeyLayout.showsKey(role: .password, read: false, hasLogins: nil))
        // The list could not be read: the key shows, so its list can show the error whole.
        #expect(BrowserPasswordKeyLayout.showsKey(role: .username, read: true, hasLogins: nil))
    }

    // MARK: The page's answer

    @Test func thePagesAnswerMapsToTheSeamsErrors() {
        #expect(BrowserPasswordPageAnswer.error("ok", now: "x") == nil)
        #expect(BrowserPasswordPageAnswer.error("moved", now: "a.test") == .siteChanged(now: "a.test"))
        #expect(BrowserPasswordPageAnswer.error("nofield", now: "x") == .noField)
        #expect(BrowserPasswordPageAnswer.error(nil, now: "x") == .failed(BrowserPasswordPageAnswer.refusedReason))
    }

    @Test func anUnknownAnswerIsNeverEchoed() {
        let error = BrowserPasswordPageAnswer.error("walk-test-pass-1", now: "127.0.0.1:8123")
        #expect(error == .failed(BrowserPasswordPageAnswer.refusedReason))
        #expect(!String(describing: error!).contains("walk-test-pass-1"))
    }
}
