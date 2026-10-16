import Testing
import Foundation
@testable import WakilKit

@Test func settingsOrgDecodesSpeechProvider() throws {
    let json = #"{"id":"acme","displayName":"","jiraBase":"","defaultProvider":"","speechProvider":"apple"}"#
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.speechProvider == "apple")
}

/// A tree from a `wakil-ctx` built before 2d-ii has no key at all.
@Test func settingsOrgWithoutSpeechProviderDecodesAsEmpty() throws {
    let json = #"{"id":"acme"}"#
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.speechProvider == "")
}
