import Foundation
import Testing
@testable import WakilKit

/// 3a-iii walk: a clone recorded at its real path (`/private/var/…`) — `standardizingPath` drops
/// the `/private` from a requested path, so a root spelled with it must be compared the same way.
@Test func aRootSpelledWithPrivateHoldsItsPaths() throws {
    let real = URL(fileURLWithPath: realpathString(NSTemporaryDirectory())).appendingPathComponent("confine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: real.appendingPathComponent("app"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: real) }
    let root = real.path
    #expect(root.hasPrefix("/private/"))
    let hit = try #require(confinedPath(root + "/app", roots: [root]))
    #expect(hit.root == root)
    #expect(hit.path == root + "/app")
    // Asked for in the short spelling, it is answered in the root's.
    let short = String(root.dropFirst("/private".count)) + "/app"
    #expect(confinedPath(short, roots: [root])?.path == root + "/app")
    #expect(confinedPath("/elsewhere/x", roots: [root]) == nil)
}

@Test func theInnermostRootStillWins() {
    #expect(confinedPath("/p/api/nested/x", roots: ["/p/api", "/p/api/nested"])?.root == "/p/api/nested")
    #expect(confinedPath("/p/api/../web/x", roots: ["/p/api", "/p/web"])?.path == "/p/web/x")
}

private func realpathString(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}
