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
