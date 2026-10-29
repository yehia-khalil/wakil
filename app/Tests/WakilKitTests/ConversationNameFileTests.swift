import Foundation
import Testing
@testable import WakilKit

/// A scratch `.wakil` directory holding the named organisations' directories.
private func scratchWakil(orgs: [String] = ["acme"]) throws -> URL {
    let home = testScratchRoot.appendingPathComponent(UUID().uuidString).appendingPathComponent(".wakil")
    for org in orgs {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("orgs").appendingPathComponent(org), withIntermediateDirectories: true)
    }
    return home
}

@Test func aNameIsKeptByLineageRootAndReadBack() throws {
    let file = ConversationNameFile(org: "acme", home: try scratchWakil())
    try file.set(root: "r1", operator: "Mine", ai: .none)
    #expect(try file.read()["r1"] == StoredConversationName(operator: "Mine", ai: nil))
}

@Test func settingTheModelsNameKeepsTheOperators() throws {
    let file = ConversationNameFile(org: "acme", home: try scratchWakil())
    try file.set(root: "r1", operator: "Mine", ai: .none)
    try file.set(root: "r1", operator: .none, ai: "Theirs")
    #expect(try file.read()["r1"] == StoredConversationName(operator: "Mine", ai: "Theirs"))
}

@Test func clearingBothRemovesTheEntry() throws {
    let file = ConversationNameFile(org: "acme", home: try scratchWakil())
    try file.set(root: "r1", operator: "Mine", ai: .none)
    try file.set(root: "r1", operator: .some(nil), ai: .some(nil))
    #expect(try file.read()["r1"] == nil)
    #expect(!(try String(contentsOfFile: file.path, encoding: .utf8)).contains("r1"))
}

@Test func anAbsentFileIsEmpty() throws {
    #expect(try ConversationNameFile(org: "acme", home: try scratchWakil()).read().isEmpty)
}

@Test func anOrganisationWithNoDirectoryIsRefused() throws {
    let home = try scratchWakil()
    let file = ConversationNameFile(org: "ghost", home: home)
    #expect(throws: (any Error).self) { try file.set(root: "r1", operator: "Mine", ai: .none) }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("orgs/ghost").path))
}

@Test func anUnreadableFileIsNeverOverwritten() throws {
    let file = ConversationNameFile(org: "acme", home: try scratchWakil())
    try Data("{nope".utf8).write(to: URL(fileURLWithPath: file.path))
    #expect(throws: ConversationNamesUnreadable.self) { try file.set(root: "r1", operator: "Mine", ai: .none) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == Data("{nope".utf8))
    #expect(throws: ConversationNamesUnreadable.self) { try file.read() }
    do { _ = try file.read() } catch {
        #expect("\(error)".hasPrefix("conversation names: \(file.path) is unreadable: "))
    }
}

@Test func twoOrganisationsNeverShareAFile() throws {
    let home = try scratchWakil(orgs: ["acme", "beta"])
    let acme = ConversationNameFile(org: "acme", home: home)
    let beta = ConversationNameFile(org: "beta", home: home)
    #expect(acme.path != beta.path)
    try acme.set(root: "r1", operator: "Mine", ai: .none)
    #expect(try beta.read().isEmpty)
}
