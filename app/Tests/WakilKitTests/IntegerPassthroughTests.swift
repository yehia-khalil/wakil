import Testing
@testable import WakilKit

/// Drives the sites that read a number out of a `JSONValue` through an
/// `if case` / `guard case` pattern. None of them would fail to COMPILE if
/// a numeric case stopped matching, so each asserts the value arrived.
///
/// Inputs here are built as `.integer(…)`, not `.number(…)`: an integer
/// arriving over the wire decodes as `.integer` now, and a site reverted to
/// `if case .number(let n)? = …` would take the `else` branch for every one
/// of these and never notice — `.number(…)` inputs would still pass such a
/// revert, which is exactly the gap this file exists to close.
///
/// **`paneSnapshotProjectionReadsItsNumbers` is gone (2c-iii).** It drove
/// `paneTable(from: JSONValue)`, which read the agent-facing wire JSON
/// back into a `PaneTable` at the window layer — exactly the round trip
/// Decision 24 deletes. `PaneTable(dataSurface:)` is built from a `DataSurfaceSnapshot`
/// whose `millis`, `offset`, `scrollTarget` and `selection` are already
/// `Int64`/`Int`/`PaneSelection`, never `JSONValue`, so there is no
/// `if case .integer`/`.number` site left here to guard.
@Test func optionalIntParamReadsAnInteger() {
    #expect(optionalIntParam(.object(["limit": .integer(250)]), "limit") == 250)
    #expect(optionalIntParam(.object(["limit": .integer(250)]), "absent") == nil)
    #expect(optionalIntParam(.object(["limit": .integer(-1)]), "limit") == nil)
}
