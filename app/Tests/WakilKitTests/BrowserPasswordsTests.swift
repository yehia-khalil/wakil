import Foundation
import Testing
@testable import WakilKit

@Suite struct BrowserPasswordsTests {
    @Test func serviceNamesTheOrganisationAndTheIdentity() throws {
        #expect(try BrowserPasswords.service(org: "initech") == "wakil:initech:browser-login:default")
    }

    @Test func anOrganisationWithAColonIsRefused() {
        for org in ["a:b", "", ".x", "-x"] {
            #expect(throws: BrowserPasswordError.badOrganisation(org)) { try BrowserPasswords.service(org: org) }
        }
        #expect(throws: BrowserPasswordError.badIdentity("a:b")) {
            try BrowserPasswords.service(org: "initech", identity: "a:b")
        }
    }

    @Test func accountSplitsAtTheFirstSpace() {
        let account = BrowserPasswords.account(site: "github.com", username: "jo smith")
        #expect(account == "github.com jo smith")
        let parsed = BrowserPasswords.parseAccount(account)
        #expect(parsed?.site == "github.com" && parsed?.username == "jo smith")
        let empty = BrowserPasswords.parseAccount(BrowserPasswords.account(site: "github.com", username: ""))
        #expect(empty?.site == "github.com" && empty?.username == "")
        #expect(BrowserPasswords.parseAccount("") == nil)
    }

    @Test func checkRefusesAnotherOrganisationsService() throws {
        let mine = try BrowserPasswords.service(org: "initech")
        let theirs = try BrowserPasswords.service(org: "umbrella")
        let account = BrowserPasswords.account(site: "github.com", username: "jo")
        try BrowserPasswords.check(service: mine, account: account, org: "initech", site: "github.com")
        try BrowserPasswords.check(service: mine, account: account, org: "initech", site: nil)
        #expect(throws: BrowserPasswordError.wrongOrganisation(expected: "initech")) {
            try BrowserPasswords.check(service: theirs, account: account, org: "initech", site: "github.com")
        }
        let other = BrowserPasswords.account(site: "gitlab.com", username: "jo")
        #expect(throws: BrowserPasswordError.wrongOrganisation(expected: "initech")) {
            try BrowserPasswords.check(service: mine, account: other, org: "initech", site: "github.com")
        }
    }

    @Test func siteKeyIsTheRegistrableDomainWithNoFamilies() {
        #expect(BrowserPasswords.siteKey("https://www.github.com/login") == "github.com")
        #expect(BrowserPasswords.siteKey("https://gist.githubusercontent.com/x") == "gist.githubusercontent.com")
        #expect(BrowserPasswords.siteKey("https://a.b.co.uk/") == "b.co.uk")
        #expect(BrowserPasswords.siteKey("http://127.0.0.1:8123/login.html") == "127.0.0.1:8123")
        #expect(BrowserPasswords.siteKey("http://localhost:8123/") == "localhost:8123")
        #expect(BrowserPasswords.siteKey("file:///x") == nil)
        #expect(BrowserPasswords.siteKey("about:blank") == nil)
    }

    @Test func aStrongPasswordHasFourGroupsOfFive() {
        let shape = try! Regex("^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){3}$")
        var seen = Set<String>()
        for _ in 0..<1000 {
            let p = BrowserPasswords.strongPassword()
            #expect(p.wholeMatch(of: shape) != nil)
            #expect(p.contains { $0.isUppercase } && p.contains { $0.isLowercase } && p.contains { $0.isNumber })
            seen.insert(p)
        }
        #expect(seen.count == 1000)
    }

    @Test func offerFollowsTheOrder() {
        func offer(_ password: String = "pw2", username: String = "jo", saved: [String] = [],
                   savedPassword: String? = nil, never: Set<String> = [], suggested: String? = nil)
            -> BrowserPasswordOffer {
            BrowserPasswords.offer(password: password, username: username, site: "github.com",
                                   savedUsernames: saved, savedPassword: savedPassword, never: never,
                                   suggested: suggested)
        }
        #expect(offer("") == .nothing)
        #expect(offer("", suggested: "") == .nothing)
        #expect(offer("pw2", suggested: "pw2") == .saveQuietly)
        #expect(offer("pw2", never: ["github.com"], suggested: "pw2") == .saveQuietly)
        #expect(offer(never: ["github.com"]) == .nothing)
        #expect(offer(saved: ["jo"], savedPassword: "pw2") == .nothing)
        #expect(offer(saved: ["jo"], savedPassword: "pw1") == .askUpdate(username: "jo"))
        #expect(offer(username: "", saved: ["jo"], savedPassword: "pw1") == .askUpdate(username: "jo"))
        #expect(offer(username: "", saved: ["jo", "al"]) == .askSave)
        #expect(offer(saved: ["al"]) == .askSave)
        #expect(offer() == .askSave)
    }

    @Test func onlyASecureOrLocalPageIsFilled() {
        #expect(BrowserPasswords.fillsOn("https://example.com/login"))
        #expect(BrowserPasswords.fillsOn("HTTPS://www.example.com:8443/"))
        #expect(!BrowserPasswords.fillsOn("http://example.com/login"))
        #expect(!BrowserPasswords.fillsOn("http://www.example.com:8080/"))
        #expect(BrowserPasswords.fillsOn("http://127.0.0.1:8123/login.html"))
        #expect(BrowserPasswords.fillsOn("http://localhost:8123/"))
        #expect(BrowserPasswords.fillsOn("http://app.localhost/"))
        #expect(BrowserPasswords.fillsOn("http://wakil.test/"))
        #expect(BrowserPasswords.fillsOn("http://[::1]:8123/"))
        #expect(BrowserPasswords.fillsOn("http://10.0.0.5/"))
        #expect(!BrowserPasswords.fillsOn("http://localhost.example.com/"))
        #expect(!BrowserPasswords.fillsOn("file:///x"))
        #expect(!BrowserPasswords.fillsOn("about:blank"))
        #expect(!BrowserPasswords.fillsOn(""))
    }

    @Test func aSentFormReadsTheSavedValueOnlyWhenTheOfferNeedsIt() {
        func read(_ password: String = "pw2", username: String = "jo", saved: [String] = ["jo"],
                  never: Set<String> = [], suggested: String? = nil) -> String? {
            BrowserPasswords.savedPasswordToRead(password: password, username: username, site: "github.com",
                                                 savedUsernames: saved, never: never, suggested: suggested)
        }
        #expect(read() == "jo")
        #expect(read("") == nil)
        #expect(read(never: ["github.com"]) == nil)
        #expect(read(suggested: "pw2") == nil)
        #expect(read(suggested: "other") == "jo")
        #expect(read(saved: []) == nil)
        #expect(read(saved: ["al"]) == nil)
        #expect(read(username: "", saved: ["al"]) == "al")
        #expect(read(username: "", saved: ["al", "bo"]) == nil)
    }

    @Test func aSiteLabelIsTheKeyOrAFixedPhrase() {
        #expect(BrowserPasswords.siteLabel("https://www.github.com/login") == "github.com")
        #expect(BrowserPasswords.siteLabel("") == "a blank tab")
        #expect(BrowserPasswords.siteLabel("data:text/html,secret") == "a page that is not a website")
        #expect(BrowserPasswords.siteLabel("file:///Users/x/secret.html") == "a page that is not a website")
    }

    @Test func barQuestionCopy() {
        #expect(BrowserPasswords.barQuestion(.askSave, username: "jo", site: "github.com")
                == "Save the password for jo on github.com?")
        #expect(BrowserPasswords.barQuestion(.askSave, username: "", site: "github.com")
                == "Save the password on github.com?")
        #expect(BrowserPasswords.barQuestion(.askUpdate(username: "jo"), username: "", site: "github.com")
                == "Update the password for jo on github.com?")
        #expect(BrowserPasswords.barQuestion(.nothing, username: "jo", site: "x.com") == nil)
        #expect(BrowserPasswords.barQuestion(.saveQuietly, username: "jo", site: "x.com") == nil)
    }

    @Test func errorsNeverCarryAPassword() {
        let e = BrowserPasswordError.keychain(operation: "add", status: -25299, message: "duplicate")
        #expect(!e.description.isEmpty)
        #expect(BrowserPasswordError.notFound(site: "a.com", username: "jo", org: "initech").description.contains("a.com"))
    }
}
