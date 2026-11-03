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

/// The environment page's Production row (Rule 9): No / Yes / From the name.
@Test func theChoiceReadsTheDeclaration() {
    #expect(SettingsProductionChoice.current(declared: nil) == .fromName)
    #expect(SettingsProductionChoice.current(declared: true) == .yes)
    #expect(SettingsProductionChoice.current(declared: false) == .no)
    #expect(SettingsProductionChoice.allCases.map(\.rawValue) == ["No", "Yes", "From the name"])
}

@Test func eachChoiceDeclaresWhatItSays() {
    #expect(SettingsProductionChoice.fromName.declared == nil)
    #expect(SettingsProductionChoice.yes.declared == true)
    #expect(SettingsProductionChoice.no.declared == false)
}

@Test func theHintSaysWhatTheNameDecided() {
    #expect(SettingsProductionChoice.hint(declared: nil, production: true) == "From the name: production.")
    #expect(SettingsProductionChoice.hint(declared: nil, production: false) == "From the name: not production.")
    #expect(SettingsProductionChoice.hint(declared: false, production: false) == nil)
    #expect(SettingsProductionChoice.hint(declared: nil, production: nil) == nil)
}

@Test func anUndeclaredFlagDecodesNil() throws {
    let env = try decodeEnvironment(#"{"name":"production","production":true,"databases":[],"api":[]}"#)
    #expect(env.productionDeclared == nil)
    #expect(env.production == true)
}
