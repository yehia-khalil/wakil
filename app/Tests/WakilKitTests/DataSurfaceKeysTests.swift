import Foundation
import Testing
@testable import WakilKit

struct DataSurfaceKeysTests {
    @Test func commandCCopies() {
        #expect(dataSurfaceKeyClaim(key: "c", command: true, editing: false, detailOpen: false) == .copy)
        #expect(dataSurfaceKeyClaim(key: "c", command: false, editing: false, detailOpen: false) == nil)
    }

    @Test func spaceTogglesTheStrip() {
        #expect(dataSurfaceKeyClaim(key: " ", command: false, editing: false, detailOpen: false) == .toggleDetail)
        #expect(dataSurfaceKeyClaim(key: " ", command: false, editing: false, detailOpen: true) == .toggleDetail)
    }

    @Test func arrowsMoveTheAnchorRow() {
        #expect(dataSurfaceKeyClaim(key: "up", command: false, editing: false, detailOpen: true) == .move(-1))
        #expect(dataSurfaceKeyClaim(key: "down", command: false, editing: false, detailOpen: false) == .move(1))
    }

    @Test func escapeClosesTheStripOnlyWhenOpen() {
        #expect(dataSurfaceKeyClaim(key: "escape", command: false, editing: false, detailOpen: true) == .closeDetail)
        #expect(dataSurfaceKeyClaim(key: "escape", command: false, editing: false, detailOpen: false) == nil)
    }

    @Test func aCellBeingEditedOwnsEveryKey() {
        for key in ["c", " ", "up", "down", "escape"] {
            #expect(dataSurfaceKeyClaim(key: key, command: key == "c", editing: true, detailOpen: true) == nil)
        }
    }

    @Test func theFooterCountsWhileRunningAndThenSaysCancelled() {
        let since = Date(timeIntervalSince1970: 1000)
        #expect(dbFlightLine(runningSince: since, cancelledAfterMs: nil, now: since.addingTimeInterval(3.24)) == "running · 3.2 s")
        #expect(dbFlightLine(runningSince: nil, cancelledAfterMs: 4000, now: since) == "cancelled after 4.0 s")
        #expect(dbFlightLine(runningSince: nil, cancelledAfterMs: nil, now: since) == nil)
    }
}
