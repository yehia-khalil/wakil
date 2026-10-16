import Foundation
import Testing
@testable import WakilKit

@Test func orgListingsAndTheWindowModelForwarderAgree() {
    let rows: [JSONValue] = [.object(["id": .string("alpha"), "displayName": .string("Alpha")])]
    #expect(OrgListings.orgListings(from: rows) == WindowModel.orgListings(from: rows))
    #expect(OrgListings.orgListings(from: rows).first?.name == "alpha")
}

@Test func slugForOrgIdentifierLivesOnOrgListings() {
    #expect(OrgListings.slugForOrgIdentifier(from: "Umbrella Ops") == WindowModel.slugForOrgIdentifier(from: "Umbrella Ops"))
}

@Test func paletteAgeLivesOnPaletteItems() {
    let now = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!
    #expect(PaletteItems.age(ofRFC3339: "2026-10-10T11:00:00.000Z", now: now)
        == WindowModel.age(ofRFC3339: "2026-10-10T11:00:00.000Z", now: now))
}
