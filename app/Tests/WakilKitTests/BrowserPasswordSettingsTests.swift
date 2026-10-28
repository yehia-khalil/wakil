import Foundation
import Testing
@testable import WakilKit

@Suite struct BrowserPasswordSettingsTests {
    private func login(_ site: String, _ username: String) -> BrowserLogin {
        BrowserLogin(org: "initech", site: site, username: username, modified: nil)
    }

    // MARK: The authentication window

    @Test func oneAuthenticationHoldsForFiveMinutesAndNoLonger() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var unlock = BrowserPasswordUnlock()
        #expect(!unlock.isOpen(at: start))
        unlock.opened(at: start)
        #expect(unlock.isOpen(at: start))
        #expect(unlock.isOpen(at: start.addingTimeInterval(299.9)))
        #expect(!unlock.isOpen(at: start.addingTimeInterval(300)))
        #expect(unlock.expires == start.addingTimeInterval(300))
    }

    @Test func aClockThatWentBackLocksIt() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let unlock = BrowserPasswordUnlock(since: start)
        #expect(!unlock.isOpen(at: start.addingTimeInterval(-1)))
    }

    @Test func lockingClosesItAtOnce() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var unlock = BrowserPasswordUnlock(since: start)
        unlock.lock()
        #expect(!unlock.isOpen(at: start))
        #expect(unlock.expires == nil)
    }

    // MARK: The list by site

    @Test func loginsAreListedBySiteThenUsernameAndNumberedDownTheWholeList() {
        let groups = BrowserPasswordSettings.bySite([
            login("umbrella.test:8123", "zed"), login("example.com", "bob"),
            login("umbrella.test:8123", "ann"), login("example.com", ""),
        ])
        #expect(groups.map(\.site) == ["example.com", "umbrella.test:8123"])
        #expect(groups[0].rows.map(\.login.username) == ["", "bob"])
        #expect(groups[1].rows.map(\.login.username) == ["ann", "zed"])
        #expect(groups.flatMap(\.rows).map(\.index) == [0, 1, 2, 3])
        #expect(BrowserPasswordSettings.bySite([]).isEmpty)
    }

    // MARK: Which organisation a result is for

    @Test func aResultForAnotherOrganisationIsDropped() {
        #expect(BrowserPasswordSettings.stillShown(asked: "initech", shown: "initech"))
        #expect(!BrowserPasswordSettings.stillShown(asked: "initech", shown: "umbrella"))
        #expect(!BrowserPasswordSettings.stillShown(asked: "initech", shown: nil))
    }

    @Test func onlyTheShownOrganisationsLoginsAreDrawn() {
        let other = BrowserLogin(org: "umbrella", site: "example.com", username: "ann", modified: nil)
        let mine = login("example.com", "ann")
        #expect(BrowserPasswordSettings.visible([other, mine], org: "initech") == [mine])
    }

    @Test func aRowKeyNamesItsOrganisation() {
        let other = BrowserLogin(org: "umbrella", site: "example.com", username: "ann", modified: nil)
        #expect(BrowserPasswordSettings.rowKey(login("example.com", "ann")) == "initech example.com ann")
        #expect(BrowserPasswordSettings.rowKey(other) != BrowserPasswordSettings.rowKey(login("example.com", "ann")))
    }

    // MARK: Copy

    @Test func theSentencesAreTheSpecs() {
        #expect(BrowserPasswordSettings.hint == "Kept in the Keychain for this organisation. Wakil fills one "
            + "only when you press the key in a field, and the agent never sees them.")
        #expect(BrowserPasswordSettings.empty(org: "Initech") == "No passwords saved for Initech yet.")
        #expect(BrowserPasswordSettings.revealReason(username: "ann", site: "example.com")
            == "reveal the password for ann on example.com")
        #expect(BrowserPasswordSettings.deleteQuestion(username: "ann", site: "example.com")
            == "Delete the password for ann on example.com? It can't be brought back.")
        #expect(BrowserPasswordImportPlan.hint == "In Passwords, choose File → Export All Passwords…, then pick "
            + "the file here. Wakil reads it and keeps no copy.")
        #expect(BrowserPasswordImportPlan.progress(2, of: 5) == "Importing 2 of 5…")
        #expect(BrowserPasswordImportPlan.trashQuestion(file: "Passwords.csv")
            == "Move Passwords.csv to the Trash? It holds every password in plain text.")
    }

    @Test func aLoginWithNoUsernameIsWordedWithoutOne() {
        #expect(BrowserPasswordSettings.shown("") == "(no username)")
        #expect(BrowserPasswordSettings.revealReason(username: "", site: "example.com")
            == "reveal the password on example.com")
        #expect(BrowserPasswordSettings.deleteQuestion(username: "", site: "example.com")
            == "Delete the password on example.com? It can't be brought back.")
    }

    // MARK: Edit

    @Test func anEditRenamesFirstThenSavesThePasswordUnderTheNewName() {
        let saves = BrowserPasswordSettings.editSaves(org: "initech", site: "example.com", was: "ann",
                                                      username: "anne", password: "walk-test-pass-2")
        #expect(saves == [
            ["org": .string("initech"), "site": .string("example.com"), "username": .string("anne"),
             "previousUsername": .string("ann")],
            ["org": .string("initech"), "site": .string("example.com"), "username": .string("anne"),
             "password": .string("walk-test-pass-2")],
        ])
    }

    @Test func anUntouchedEditSavesNothingAndAnEmptyPasswordKeepsTheOld() {
        #expect(BrowserPasswordSettings.editSaves(org: "initech", site: "example.com", was: "ann",
                                                  username: "ann", password: "").isEmpty)
        let rename = BrowserPasswordSettings.editSaves(org: "initech", site: "example.com", was: "ann",
                                                       username: "anne", password: "")
        #expect(rename.count == 1)
        #expect(rename[0]["password"] == nil)
    }

    // MARK: The import

    private func row(_ id: Int, _ site: String?, _ username: String, skipped: String? = nil) -> BrowserImportRow {
        BrowserImportRow(id: id, title: "", site: site, url: site.map { "https://\($0)/" } ?? "",
                         username: username, password: "walk-test-pass-\(id)", skipped: skipped)
    }

    @Test func importRowsAreListedBySiteWithSitelessRowsLast() {
        let ordered = BrowserPasswordImportPlan.ordered([
            row(2, "umbrella.test:8123", "ann"), row(3, nil, "x", skipped: "no URL"),
            row(4, "example.com", "bob"), row(5, "example.com", "ann"),
        ])
        #expect(ordered.map(\.id) == [5, 4, 2, 3])
    }

    @Test func onlyRowsTheParserKeptAreImported() {
        let rows = [row(2, "example.com", "ann"), row(3, "example.com", "bob", skipped: "no password")]
        #expect(BrowserPasswordImportPlan.runnable(rows).map(\.id) == [2])
        #expect(BrowserPasswordImportPlan.save(rows[1], org: "initech") == nil)
        #expect(BrowserPasswordImportPlan.save(rows[0], org: "umbrella") == [
            "org": .string("umbrella"), "site": .string("example.com"), "username": .string("ann"),
            "password": .string("walk-test-pass-2")])
    }

    @Test func aRowSaysWhyItIsSkippedOrThatItReplacesASavedLogin() {
        #expect(BrowserPasswordImportPlan.note(row(2, "example.com", "ann", skipped: "no password"),
                                               saved: ["ann"]) == "no password")
        #expect(BrowserPasswordImportPlan.note(row(2, "example.com", "ann"), saved: ["ann"])
            == "replaces the saved password")
        #expect(BrowserPasswordImportPlan.note(row(2, "example.com", "ann"), saved: ["bob"]) == nil)
    }

    @Test func theReceiptCountsEveryRowNotImportedAsSkipped() {
        #expect(BrowserPasswordImportPlan.receipt(imported: 3, rows: 5) == "Imported 3 passwords. Skipped 2.")
        #expect(BrowserPasswordImportPlan.receipt(imported: 0, rows: 0) == "Imported 0 passwords. Skipped 0.")
    }
}
