import Foundation
import Testing
@testable import WakilKit

/// Settings → Connections reads the organisation's connections from the tree Go draws
/// (`ConfigTreeConnection`): everything the page needs, and never a secret value.
@Test func settingsTreeDecodesConnections() throws {
    let json = """
    {"id":"initech","jiraTokenStored":true,"connections":[
      {"name":"datadog","kind":"datadog","title":"Datadog","transport":"http",
       "url":"https://mcp.{site}/api/unstable/mcp-server/mcp","command":"","args":[],"signIn":"fields",
       "values":{"site":"datadoghq.eu"},
       "fields":[{"id":"site","label":"Datadog site","secret":false},{"id":"apiKey","label":"API key","secret":true}],
       "allow":{"search_logs":true},"hints":{"search_logs":"readOnly","mute":"destructive"},
       "signedIn":true,"secretKeys":["apiKey"]},
      {"name":"wiki","kind":"custom","title":"custom","transport":"stdio","command":"wiki-mcp","args":["--serve"],
       "signIn":"none","secretKeys":["env:WIKI_TOKEN"]}
    ]}
    """
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.jiraTokenStored)
    #expect(org.connections.count == 2)
    let dd = org.connections[0]
    #expect(dd.displayTitle == "Datadog")
    #expect(dd.signIn == "fields" && dd.signedIn)
    #expect(dd.values["site"] == "datadoghq.eu")
    #expect(dd.fields == [SettingsConnectionField(id: "site", label: "Datadog site"),
                          SettingsConnectionField(id: "apiKey", label: "API key", secret: true)])
    #expect(dd.allow == ["search_logs": true])
    #expect(dd.hints["mute"] == "destructive")
    #expect(dd.secretKeys == ["apiKey"])
    let wiki = org.connections[1]
    #expect(wiki.displayTitle == "wiki")
    #expect(wiki.command == "wiki-mcp" && wiki.args == ["--serve"])
    #expect(wiki.secretKeys == ["env:WIKI_TOKEN"])
    #expect(wiki.hints.isEmpty && wiki.allow.isEmpty && !wiki.signedIn)
}

@Test func anOrganisationWithNoConnectionsDecodesToNone() throws {
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(#"{"id":"umbrella"}"#.utf8))
    #expect(org.connections == [])
    #expect(!org.jiraTokenStored)
    let empty = try JSONDecoder().decode(SettingsOrg.self, from: Data(#"{"id":"umbrella","connections":[]}"#.utf8))
    #expect(empty.connections == [])
}

/// A malformed field drops that field only: the connection, and the one beside it, still decode.
@Test func aMalformedFieldDropsOnlyThatField() throws {
    let json = """
    {"id":"initech","connections":[
      {"name":"datadog","kind":"datadog","fields":[{"label":"no id"},{"id":"apiKey","label":"API key","secret":true}]},
      {"name":"wiki"},
      {"kind":"no name"}
    ]}
    """
    let org = try JSONDecoder().decode(SettingsOrg.self, from: Data(json.utf8))
    #expect(org.connections.map(\.name) == ["datadog", "wiki"])
    #expect(org.connections[0].fields == [SettingsConnectionField(id: "apiKey", label: "API key", secret: true)])
}
