import Foundation
import Testing
@testable import WakilKit

// The workspaces record's read (workspaces, piece 1): a read cut short is not a record that could
// not be read.

private actor Reads {
    var count = 0
    func next() -> Int { count += 1; return count }
}

@Test("A read cancelled under the caller is not kept as the record's failure: the next ensure reads again")
func cancelledReadIsRetried() async throws {
    let store = WorkspaceStore()
    let reads = Reads()
    await store.use(load: {
        if await reads.next() == 1 { throw CancellationError() }
        return WorkspacesFile()
    }, save: { _ in })

    await store.ensure(org: "initech")
    #expect(await store.loadFailure == nil)

    await store.ensure(org: "initech")
    #expect(await reads.count == 2)
    #expect(await store.loadFailure == nil)
    try await store.save()
}

@Test("A record that truly cannot be read stays a failure, and nothing is saved over it")
func unreadableRecordStaysAFailure() async {
    let store = WorkspaceStore()
    await store.use(load: { throw WorkspaceWriteError(description: "workspaces.json is not readable") },
                    save: { _ in })
    await store.ensure(org: "initech")
    #expect(await store.loadFailure?.contains("is not readable") == true)
    await #expect(throws: WorkspaceWriteError.self) { try await store.save() }
}
