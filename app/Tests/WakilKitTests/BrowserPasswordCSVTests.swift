import Foundation
import Testing
@testable import WakilKit

@Suite struct BrowserPasswordCSVTests {
    private func parse(_ text: String) throws -> [BrowserImportRow] {
        try BrowserPasswordCSV.parse(Data(text.utf8))
    }

    @Test func readsThePasswordsAppsColumns() throws {
        let rows = try parse("""
        Title,URL,Username,Password,Notes,OTPAuth
        GitHub,https://github.com/login,jo,walk-test-pass-1,a note,
        """)
        #expect(rows.count == 1)
        #expect(rows[0].title == "GitHub")
        #expect(rows[0].site == "github.com")
        #expect(rows[0].url == "https://github.com/login")
        #expect(rows[0].username == "jo")
        #expect(rows[0].password == "walk-test-pass-1")
        #expect(rows[0].skipped == nil)
        #expect(rows[0].id == 2)
    }

    @Test func headersMatchAnyCaseAndOrderAndExtraColumnsAreIgnored() throws {
        let rows = try parse("password,Extra,USERNAME,url\nwalk-test-pass-1,x,jo,https://github.com\n")
        #expect(rows.count == 1)
        #expect(rows[0].username == "jo" && rows[0].password == "walk-test-pass-1")
        #expect(rows[0].title == "")
        #expect(rows[0].site == "github.com")
    }

    @Test func quotedFieldsKeepCommasQuotesAndNewlines() throws {
        let rows = try parse("Title,URL,Username,Password\n\"a,b\",https://github.com,\"say \"\"hi\"\"\",\"line1\nline2\"\n")
        #expect(rows.count == 1)
        #expect(rows[0].title == "a,b")
        #expect(rows[0].username == "say \"hi\"")
        #expect(rows[0].password == "line1\nline2")
    }

    @Test func crlfAndABomAreRead() throws {
        let rows = try parse("\u{FEFF}URL,Username,Password\r\nhttps://github.com,jo,walk-test-pass-1\r\nhttps://gitlab.com,al,walk-test-pass-2\r\n")
        #expect(rows.map(\.username) == ["jo", "al"])
        #expect(rows.map(\.id) == [2, 3])
        #expect(rows[1].password == "walk-test-pass-2")
    }

    @Test func aRowWithNoUrlOrNoPasswordIsSkippedNotRefused() throws {
        let rows = try parse("URL,Username,Password\n,jo,walk-test-pass-1\nhttps://github.com,jo,\n")
        #expect(rows.map(\.skipped) == ["no URL", "no password"])
    }

    @Test func aBareHostGetsHttps() throws {
        let rows = try parse("URL,Username,Password\ngithub.com,jo,walk-test-pass-1\n")
        #expect(rows[0].site == "github.com")
        #expect(rows[0].url == "https://github.com")
        #expect(rows[0].skipped == nil)
    }

    @Test func anAppEntryIsNotAWebAddress() throws {
        let rows = try parse("URL,Username,Password\nandroid://abc@com.example.app,jo,walk-test-pass-1\n")
        #expect(rows[0].site == nil)
        #expect(rows[0].skipped == "not a web address")
    }

    @Test func theLaterOfTwoRowsForOneLoginWins() throws {
        let rows = try parse("""
        URL,Username,Password
        https://github.com/a,jo,walk-test-pass-1
        https://gitlab.com,jo,walk-test-pass-3
        https://www.github.com/b,jo,walk-test-pass-2
        """)
        #expect(rows[0].skipped == "a later row for the same login replaces this one")
        #expect(rows[1].skipped == nil)
        #expect(rows[2].skipped == nil)
    }

    @Test func aFileWithNoHeaderIsRefused() {
        #expect(throws: BrowserPasswordCSVError.noHeader) { try parse("Title,Username\nx,y\n") }
        #expect(throws: BrowserPasswordCSVError.noHeader) { try parse("") }
        #expect(throws: BrowserPasswordCSVError.noHeader) { try parse("https://github.com,jo,walk-test-pass-1\n") }
    }

    @Test func theParserTakesBytesAndWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("export.csv")
        try Data("URL,Username,Password\nhttps://github.com,jo,walk-test-pass-1\n".utf8).write(to: file)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let rows = try BrowserPasswordCSV.parse(Data(contentsOf: file))
        #expect(rows.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
    }
}
