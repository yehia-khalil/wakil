import Foundation
import Testing
@testable import WakilKit

private func scratchHome() -> URL { testScratchRoot.appendingPathComponent(UUID().uuidString) }

@Test func eachOrgHasItsOwnIdentifier() throws {
    let home = scratchHome()
    let a = try BrowserOrgFiles(home: home, org: "acme")
    let b = try BrowserOrgFiles(home: home, org: "globex")
    #expect(try a.identifier() != b.identifier())
    #expect(a.directory.path == home.path + "/.wakil/orgs/acme/browser")
    #expect(a.directory != b.directory)
}

@Test func theIdentifierIsStableAcrossCalls() throws {
    let home = scratchHome()
    let first = try BrowserOrgFiles(home: home, org: "acme").identifier()
    #expect(try BrowserOrgFiles(home: home, org: "acme").identifier() == first)
    let json = try Data(contentsOf: BrowserOrgFiles(home: home, org: "acme").directory.appendingPathComponent("profile.json"))
    #expect(try JSONDecoder().decode([String: UUID].self, from: json) == ["identifier": first])
}

@Test func aMissingProfileIsCreatedNotRefused() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    _ = try files.identifier()
    #expect(FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("profile.json").path))
}

@Test func aCorruptProfileGetsANewIdentifier() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let old = try files.identifier()
    try Data("not json".utf8).write(to: files.directory.appendingPathComponent("profile.json"))
    let new = try files.identifier()
    #expect(new != old)
    #expect(try files.identifier() == new)
}

@Test func zoomIsPerHost() throws {
    let home = scratchHome()
    let files = try BrowserOrgFiles(home: home, org: "acme")
    #expect(files.zoom(host: "a.test") == 1.0)
    try files.setZoom(1.5, host: "a.test")
    try files.setZoom(0.8, host: "b.test")
    #expect(files.zoom(host: "a.test") == 1.5)
    #expect(files.zoom(host: "b.test") == 0.8)
    #expect(try BrowserOrgFiles(home: home, org: "globex").zoom(host: "a.test") == 1.0)
    try Data("garbage".utf8).write(to: files.directory.appendingPathComponent("zoom.json"))
    #expect(files.zoom(host: "a.test") == 1.0)
}

@Test func tabStateLivesUnderTabsAndGoesWhenRemoved() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let url = files.stateURL(tab: "t1")
    #expect(url.deletingLastPathComponent().lastPathComponent == "tabs")
    #expect(url.lastPathComponent == "t1.state")
    #expect(files.stateURL(tab: "../x").deletingLastPathComponent().lastPathComponent == "tabs")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: url)
    files.removeState(tab: "t1")
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func anOrgThatIsNotOneDirectoryNameIsRefusedNotFlattened() {
    for bad in ["a/b", "..", ".", "", "/etc"] {
        #expect(throws: BrowserOrgFilesError.self) { try BrowserOrgFiles(home: scratchHome(), org: bad) }
    }
}

@Test func anUnreadableProfileThrowsAndIsNotOverwritten() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let id = try files.identifier()
    let profile = files.directory.appendingPathComponent("profile.json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: profile.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.path) }
    #expect(throws: (any Error).self) { try files.identifier() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.path)
    #expect(try files.identifier() == id, "the id survived the failed read")
}

@Test func aTabsStateIsNamedByItsPlaceNotOnlyItsIds() throws {
    let staging = LayoutScope(organization: "acme", project: "api", environment: "staging")
    let key = BrowserOrgFiles.stateKey(scope: staging, pane: "browser-1", tab: "t1")
    #expect(key == BrowserOrgFiles.stateKey(scope: staging, pane: "browser-1", tab: "t1"), "stable for one place")
    #expect(key.hasSuffix(".browser-1.t1"))
    let others = [
        LayoutScope(organization: "acme", project: "api", environment: "production"),
        LayoutScope(organization: "acme", project: "web", environment: "staging"),
        LayoutScope(organization: "acme", project: "api", environment: "staging", lineageRoot: "conv-1"),
    ]
    for other in others {
        #expect(BrowserOrgFiles.stateKey(scope: other, pane: "browser-1", tab: "t1") != key,
                "another place's browser-1/t1 is another file")
    }
    // The organisation is the directory, not part of the name.
    #expect(BrowserOrgFiles.stateKey(scope: LayoutScope(organization: "globex", project: "api", environment: "staging"),
                                     pane: "browser-1", tab: "t1") == key)
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    #expect(files.stateURL(tab: key).deletingLastPathComponent().lastPathComponent == "tabs")
}

// MARK: - Final fix wave: states move with their place, and a closed pane takes all of its own

private func writeState(_ files: BrowserOrgFiles, _ scope: LayoutScope, _ pane: String, _ tab: String) throws -> URL {
    let url = files.stateURL(tab: BrowserOrgFiles.stateKey(scope: scope, pane: pane, tab: tab))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(tab.utf8).write(to: url)
    return url
}

/// I1: a conversation taking the canvas (or a rename) carries each tab's state to the new place's
/// name, so the rebuilt page keeps its ‹ › history; another place's states stay where they were.
@Test func aPlacesTabStatesMoveToItsNewName() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let seed = LayoutScope(organization: "acme", project: "api", environment: "staging")
    let adopted = LayoutScope(organization: "acme", project: "api", environment: "staging", lineageRoot: "conv-1")
    let other = LayoutScope(organization: "acme", project: "web", environment: "staging")
    let t1 = try writeState(files, seed, "browser-1", "t1")
    let t2 = try writeState(files, seed, "browser-2", "t2")
    let elsewhere = try writeState(files, other, "browser-1", "t1")

    files.moveStates(from: seed, to: adopted)

    #expect(!FileManager.default.fileExists(atPath: t1.path))
    #expect(!FileManager.default.fileExists(atPath: t2.path))
    let moved = files.stateURL(tab: BrowserOrgFiles.stateKey(scope: adopted, pane: "browser-1", tab: "t1"))
    #expect(try Data(contentsOf: moved) == Data("t1".utf8))
    #expect(FileManager.default.fileExists(atPath:
        files.stateURL(tab: BrowserOrgFiles.stateKey(scope: adopted, pane: "browser-2", tab: "t2")).path))
    #expect(FileManager.default.fileExists(atPath: elsewhere.path), "another place's state is not touched")
}

/// I2: a closed pane takes every tab's state with it — the ones never shown this launch too —
/// and leaves a pane whose id starts the same (`browser-10`) alone.
@Test func aClosedPaneTakesEveryTabsStateAndOnlyItsOwn() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let scope = LayoutScope(organization: "acme", project: "api", environment: "staging")
    let t1 = try writeState(files, scope, "browser-1", "t1")
    let t2 = try writeState(files, scope, "browser-1", "t2")
    let ten = try writeState(files, scope, "browser-10", "t1")
    let elsewhere = try writeState(files, LayoutScope(organization: "acme", project: "web", environment: "staging"),
                                   "browser-1", "t1")

    files.removeStates(scope: scope, pane: "browser-1")

    #expect(!FileManager.default.fileExists(atPath: t1.path))
    #expect(!FileManager.default.fileExists(atPath: t2.path))
    #expect(FileManager.default.fileExists(atPath: ten.path))
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
}

@Test func clearingRemovesHistoryAndKeepsBookmarksAndProfile() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "acme")
    let id = try files.identifier()
    try files.history.record(url: "https://example.com/", title: "Example", at: Date(), newVisit: true)
    try files.setZoom(1.5, host: "example.com")
    let bookmarks = files.directory.appendingPathComponent("bookmarks.json")
    try Data("[]".utf8).write(to: bookmarks)
    let dbPath = files.directory.appendingPathComponent("history.sqlite").path
    #expect(FileManager.default.fileExists(atPath: dbPath))
    // stray WAL and SHM files from a crashed writer go too
    try Data("x".utf8).write(to: URL(fileURLWithPath: dbPath + "-wal"))
    try Data("x".utf8).write(to: URL(fileURLWithPath: dbPath + "-shm"))

    try files.removeEverythingButTheProfile()

    for suffix in ["", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: dbPath + suffix)) }
    #expect(try files.history.matching(["example"], limit: 5).isEmpty)
    #expect(FileManager.default.fileExists(atPath: bookmarks.path))
    #expect(files.zoom(host: "example.com") == 1.0)
    #expect(try files.identifier() == id)
}

@Test func theClearQuestionSaysHistoryGoesAndBookmarksStay() {
    #expect(BrowserClearDataQuestion.text(org: "initech")
        == "Delete initech's browsing data? Every site signs you out, in every project, and its history is deleted. Bookmarks stay.")
}

// MARK: - Bookmarks (3c-iii Task 3)

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func aBookmarkTogglesOnAndOff() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    #expect(try files.bookmarks() == [])
    #expect(try files.setBookmark(url: "https://example.com/", title: "Example", on: nil, now: t0) == true)
    #expect(try files.bookmarks() == [BrowserBookmark(url: "https://example.com/", title: "Example", added: t0)])
    #expect(try files.setBookmark(url: "https://example.com/", title: "Example", on: nil, now: t0) == false)
    #expect(try files.bookmarks() == [])
    #expect(try files.setBookmark(url: "https://example.com/", title: "Example", on: false, now: t0) == false)
}

@Test func onTrueTwiceKeepsOneBookmark() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    try files.setBookmark(url: "https://example.com/", title: "Example", on: true, now: t0)
    #expect(try files.setBookmark(url: "https://example.com/", title: "Example", on: true, now: t0 + 5) == true)
    #expect(try files.bookmarks().count == 1)
    #expect(try files.bookmarks()[0].added == t0)
}

@Test func bookmarksKeepTheOrderTheyWereAdded() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    for (i, u) in ["https://b.example.com/", "https://a.example.com/", "https://c.example.com/"].enumerated() {
        try files.setBookmark(url: u, title: "T\(i)", on: true, now: t0 + Double(i))
    }
    #expect(try files.bookmarks().map(\.url) == ["https://b.example.com/", "https://a.example.com/", "https://c.example.com/"])
    try files.setBookmark(url: "https://a.example.com/", title: "", on: false, now: t0)
    #expect(try files.bookmarks().map(\.url) == ["https://b.example.com/", "https://c.example.com/"])
}

@Test func aBookmarkFileThatDoesNotParseIsNeverWrittenOver() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
    let path = files.directory.appendingPathComponent("bookmarks.json")
    let bytes = Data("{not json".utf8)
    try bytes.write(to: path)
    #expect(throws: BrowserBookmarksUnreadable.self) { try files.bookmarks() }
    #expect(throws: BrowserBookmarksUnreadable.self) {
        try files.setBookmark(url: "https://example.com/", title: "E", on: true, now: t0)
    }
    #expect(try Data(contentsOf: path) == bytes)
}

@Test func clearingBrowsingDataKeepsTheBookmarks() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    try files.setBookmark(url: "https://example.com/", title: "E", on: true, now: t0)
    try files.removeEverythingButTheProfile()
    #expect(try files.bookmarks().count == 1)
}

// MARK: - Pins (3d-i Task 8)

private let pinnedTab = BrowserPin(id: "p0000000a", kind: .tab, url: "https://example.com/a", title: "A")
private let pinnedGroup = BrowserPin(
    id: "p0000000b", kind: .group, name: "Docs", colour: .teal,
    tabs: [BrowserPinTab(url: "https://example.com/1", title: "One"), BrowserPinTab(url: "https://example.com/2", title: "Two")])

@Test func pinsFileRoundTripsInOrder() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    let prs = BrowserPin(id: "p0000000c", kind: .pullRequests)
    try files.setPins([pinnedGroup, pinnedTab, prs], project: "web")
    #expect(try files.pins(project: "web") == [pinnedGroup, pinnedTab, prs])
    let url = files.directory.appendingPathComponent("pins/web.json")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let items = try #require(json["items"] as? [[String: Any]])
    #expect(items.map { $0["kind"] as? String } == ["group", "tab", "pullRequests"])
    #expect(Set(items[1].keys) == ["id", "kind", "url", "title"])
    #expect(Set(items[0].keys) == ["id", "kind", "name", "colour", "tabs"])
    #expect(try files.pins(project: "other") == [])
}

@Test func aMissingPinsFileReadsEmpty() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    #expect(try files.pins(project: "web") == [])
    #expect(!FileManager.default.fileExists(atPath: files.directory.path))
}

@Test func anUnreadablePinsFileIsNeverWrittenOverByTheFiles() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    let url = files.pinsURL(project: "web")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("{\"items\": [oops".utf8)
    try bytes.write(to: url)
    #expect(throws: BrowserPinsUnreadable.self) { try files.pins(project: "web") }
    #expect(throws: BrowserPinsUnreadable.self) { try files.setPins([pinnedTab], project: "web") }
    #expect(try Data(contentsOf: url) == bytes)
}

@Test func aProjectKeyWithASlashIsOneFileName() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    try files.setPins([pinnedTab], project: "initech/web")
    let pins = files.directory.appendingPathComponent("pins")
    #expect(try FileManager.default.contentsOfDirectory(atPath: pins.path) == ["initech%2Fweb.json"])
    #expect(try files.pins(project: "initech/web") == [pinnedTab])
    #expect(BrowserOrgFiles.pinsName(project: "initech/web") == "pins/initech%2Fweb.json")
}

@Test func clearingBrowsingDataKeepsPins() throws {
    let files = try BrowserOrgFiles(home: scratchHome(), org: "initech")
    try files.setPins([pinnedTab], project: "web")
    try files.removeEverythingButTheProfile()
    #expect(try files.pins(project: "web") == [pinnedTab])
}
