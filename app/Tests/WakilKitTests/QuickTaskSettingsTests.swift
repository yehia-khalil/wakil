import Testing
import Foundation
@testable import WakilKit

private func tree(quick: String = "", _ providers: [SettingsProvider]) -> SettingsTree {
    SettingsTree(org: SettingsOrg(id: "acme", quickProvider: quick), providers: providers)
}

@Test func quickTaskOptionsListServingProvidersAndOmitACodexOne() {
    let t = tree([
        SettingsProvider(id: "local", kind: "local", label: "Qwen", baseURL: "http://127.0.0.1:8012", serves: ["infill"]),
        SettingsProvider(id: "claude-code", kind: "claude-code", serves: ["infill", "respond"]),
        SettingsProvider(id: "codex", kind: "codex", serves: []),
    ])
    let options = quickTaskOptions(t)
    #expect(options.map(\.id) == ["", "local", "claude-code"])
    #expect(options.map(\.label) == ["Same as agent", "Qwen", "claude-code"])
}

@Test func quickTaskNoteAppearsWhenNothingServesInfillAndClearsOnceALocalOneIsChosen() {
    let codexOnly = tree([SettingsProvider(id: "codex", kind: "codex", serves: [])])
    #expect(quickTaskNote(codexOnly, activeProvider: "codex") == "Ghost-text needs a Claude or local provider")
    let withLocal = tree(quick: "local", [
        SettingsProvider(id: "codex", kind: "codex", serves: []),
        SettingsProvider(id: "local", kind: "local", baseURL: "http://127.0.0.1:8012", serves: ["infill"]),
    ])
    #expect(quickTaskNote(withLocal, activeProvider: "codex") == nil)
}

@Test func localProviderStatusReturnsTheErrorWholeReachableOrNotTriedYet() {
    let long = String(repeating: "connection refused ", count: 16)
    #expect(long.count > 250)
    #expect(localProviderStatus(id: "local", errors: ["local": long], answered: ["local"]) == long)
    #expect(localProviderStatus(id: "local", errors: ["other": "x"], answered: ["local"]) == "reachable")
    // Nothing has been asked of it yet: no claim that it answers.
    #expect(localProviderStatus(id: "local", errors: [:], answered: []) == "not tried yet")
    #expect(localProviderStatus(id: "local", errors: ["other": "x"], answered: ["other"]) == "not tried yet")
}

@Test func aNewLocalProviderServesCodeCompletionOnly() {
    #expect(newLocalProviderServes() == ["infill"])
}

@Test func quickTaskChoicesStayDistinctWhenLabelsCollide() {
    let t = tree([
        SettingsProvider(id: "a", kind: "local", label: "Qwen", serves: ["infill"]),
        SettingsProvider(id: "b", kind: "local", label: "Qwen", serves: ["infill"]),
        SettingsProvider(id: "c", kind: "local", label: "Same as agent", serves: ["infill"]),
        SettingsProvider(id: "d", kind: "claude-code", serves: ["infill"]),
    ])
    let choices = quickTaskChoices(t)
    #expect(Set(choices.map(\.display)).count == choices.count)
    #expect(choices.map(\.id) == ["", "a", "b", "c", "d"])
    #expect(choices.first?.display == "Same as agent")
    #expect(choices.last?.display == "d")
}

@Test func quickTaskRouteLineNamesTheProviderCodeCompletionGoesTo() {
    let t = tree(quick: "local", [
        SettingsProvider(id: "local", kind: "local", label: "Qwen", baseURL: "http://127.0.0.1:8012", serves: ["infill"]),
        SettingsProvider(id: "work", kind: "claude-code", serves: ["infill", "respond"]),
    ])
    #expect(quickTaskRouteLine(t, routed: "local") == "Code completion goes to Qwen")
    #expect(quickTaskRouteLine(t, routed: "work") == "Code completion goes to work")
    #expect(quickTaskRouteLine(t, routed: nil) == nil)
}

@Test func anOrgWithoutTheSwitchesDecodesTheirDefaults() throws {
    let json = #"{"id":"acme"}"#.data(using: .utf8)!
    let org = try JSONDecoder().decode(SettingsOrg.self, from: json)
    #expect(org.ghostText == true)
    #expect(org.fastPath == false)
}

@Test func fastPathHintNamesTheModelActuallyChosen() {
    let providers = [
        SettingsProvider(id: "main", kind: "claude-code", label: "Work", serves: ["infill", "respond"]),
        SettingsProvider(id: "qwen", kind: "local", baseURL: "http://127.0.0.1:8012", serves: ["infill", "respond"]),
    ]
    func hint(quick: String, on: Bool) -> String {
        fastPathHint(SettingsTree(org: SettingsOrg(id: "acme", quickProvider: quick, fastPath: on), providers: providers))
    }
    #expect(hint(quick: "", on: false) == "one-line commands without the agent · off: on Same as agent each line would wait for Claude first")
    #expect(hint(quick: "main", on: false) == "one-line commands without the agent · off: on Work each line would wait for Claude first")
    #expect(hint(quick: "qwen", on: true) == "one-line commands without the agent · on: the model is local")
    #expect(hint(quick: "main", on: true) == "one-line commands without the agent", "a value the operator changed needs no why")
}

/// The ⓘ's text names the deadlines the fast path runs under, so raising one cannot leave the
/// text promising the old one; and it says what the fast path won't do.
@Test func theAboutTextNamesTheDeadlinesAndWhatTheFastPathWontDo() {
    #expect(quickTasksAbout.contains("longer than 0.4 s (2.5 s for a model that isn't local)"))
    #expect(quickTasksAbout.contains("It never edits a file, changes data or a setting, or runs a command or a query."))
    #expect(quickTasksAbout.contains("Press Tab to accept it."))
    #expect((try? AttributedString(markdown: quickTasksAbout,
                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) != nil)
}
