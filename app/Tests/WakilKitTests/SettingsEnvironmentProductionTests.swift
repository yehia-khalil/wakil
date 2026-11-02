import Foundation
import Testing
@testable import WakilKit

/// The config tree says which environments are production, so the agent's per-site price can
/// follow the org's own rule. A `wakil-ctx` built before the field decodes to nil, not an error.

private func decodeEnvironment(_ json: String) throws -> SettingsEnvironment {
    try JSONDecoder().decode(SettingsEnvironment.self, from: Data(json.utf8))
}

@Test func anEnvironmentDecodesItsProductionFlag() throws {
    let env = try decodeEnvironment(#"{"name":"live","production":true,"databases":[],"api":[]}"#)
    #expect(env.production == true)
}

@Test func aTreeWithoutTheFlagDecodesNil() throws {
    let env = try decodeEnvironment(#"{"name":"live","databases":[],"api":[]}"#)
    #expect(env.production == nil)
    #expect(env.name == "live")
}

/// The raw flag behind `production`, so the page can say whether the name decided (Rule 9).
@Test func anEnvironmentDecodesItsDeclaredFlag() throws {
    let env = try decodeEnvironment(#"{"name":"production","production":false,"productionDeclared":false,"databases":[],"api":[]}"#)
    #expect(env.productionDeclared == false)
    #expect(env.production == false)
}

@Test func anUndeclaredFlagDecodesNil() throws {
    let env = try decodeEnvironment(#"{"name":"production","production":true,"databases":[],"api":[]}"#)
    #expect(env.productionDeclared == nil)
    #expect(env.production == true)
}
