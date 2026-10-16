import Testing

@testable import WakilKit

@Test func driversAreReadFromTheListResult() {
    let result: JSONValue = .object(["structuredContent": .object(["databases": .array([
        .object(["name": .string("core"), "driver": .string("mysql")]),
        .object(["name": .string("docs"), "driver": .string("mongo")]),
        .object(["name": .string(""), "driver": .string("sqlite")]),
    ])])])
    #expect(databaseDriverMap(fromListResult: result) == ["core": "mysql", "docs": "mongo"])
    #expect(databaseDriverMap(fromListResult: nil).isEmpty)
}

@MainActor
@Test func aPaneOnAMongoDatabaseHasTheMongoDialect() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    model.seedForTesting(
        providerId: "acct", rootPath: "/a/core", thoughts: 0,
        databases: ["docs", "local"],
        databaseDrivers: ["docs": "mongo", "local": "sqlite"])
    let pane = Pane(
        id: "db-1", kind: "db", title: "db-1",
        frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))

    model.chooseDatabase("docs", pane: pane)
    #expect(model.queryDialect(pane: pane) == .mongo)

    model.chooseDatabase("local", pane: pane)
    #expect(model.queryDialect(pane: pane) == .sql)
}

@MainActor
@Test func aPaneWithNoDatabaseHasTheSQLDialect() {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    let pane = Pane(
        id: "db-1", kind: "db", title: "db-1",
        frame: PaneFrame(x: 0, y: 0, width: 640, height: 420))
    #expect(model.queryDialect(pane: pane) == .sql)
}
