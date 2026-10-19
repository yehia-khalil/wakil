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
