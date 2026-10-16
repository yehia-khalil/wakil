import Foundation
import Testing
@testable import WakilKit

@Test func decodesTheCredentialsJSON() throws {
    let json = #"{"configDir":"/tmp/cfg","claudePath":"/opt/claude","oauthToken":"sk-x"}"#
    let got = try decodeProviderCredentials(Data(json.utf8))
    #expect(got.configDir == "/tmp/cfg")
    #expect(got.claudePath == "/opt/claude")
    #expect(got.oauthToken == "sk-x")
}

@Test func refusesCredentialsWithAnEmptyField() {
    let json = #"{"configDir":"/tmp/cfg","claudePath":"","oauthToken":"sk-x"}"#
    #expect(throws: ProviderCredentialsLookupError.refused(
        "the provider record is missing claudePath")) {
        try decodeProviderCredentials(Data(json.utf8))
    }
}
