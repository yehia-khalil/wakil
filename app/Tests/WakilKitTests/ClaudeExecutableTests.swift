import Testing
import Foundation
@testable import WakilKit

/// **#322: an organisation with no accounts could not register one.** The
/// login binary was only ever read off this organisation's own rows — #271
/// rightly stopped it borrowing another organisation's — so zero rows meant
/// no path at all. The operator's ruling: look it up on this machine, and let
/// them override what the lookup found.

// MARK: - Which path wins

@Test func theOperatorsOverrideWinsOverEverything() {
    #expect(resolveLoginBinary(
        override: "/opt/custom/claude", ownBinaries: ["/Users/x/.local/bin/claude"],
        located: "/opt/homebrew/bin/claude") == "/opt/custom/claude")
}

@Test func thisOrganisationsOwnRecordWinsOverTheLookup() {
    #expect(resolveLoginBinary(
        override: "", ownBinaries: ["", "/Users/x/.local/bin/claude"],
        located: "/opt/homebrew/bin/claude") == "/Users/x/.local/bin/claude")
}

/// The case #322 is about: no account here records a path.
@Test func anOrganisationWithNoAccountsUsesTheLookup() {
    #expect(resolveLoginBinary(override: "", ownBinaries: [], located: "/opt/homebrew/bin/claude")
            == "/opt/homebrew/bin/claude")
}

@Test func aBlankOverrideIsNoOverride() {
    #expect(resolveLoginBinary(override: "   ", ownBinaries: [], located: "/usr/local/bin/claude")
            == "/usr/local/bin/claude")
}

@Test func nothingFoundAnywhereIsEmpty() {
    #expect(resolveLoginBinary(override: "", ownBinaries: [], located: "") == "")
}

// MARK: - The lookup

@Test func theLoginShellsAnswerIsTakenWhenItIsExecutable() {
    let locator = ClaudeExecutableLocator(
        home: "/Users/x",
        shellLookup: { "/Users/x/.volta/bin/claude" },
        isExecutable: { $0 == "/Users/x/.volta/bin/claude" })
    #expect(locator.locate() == "/Users/x/.volta/bin/claude")
}

/// A shell's rc files can print anything; only an absolute, executable path
/// is an answer.
@Test func aShellAnswerThatIsNotAnExecutablePathIsIgnored() {
    let locator = ClaudeExecutableLocator(
        home: "/Users/x",
        shellLookup: { "claude: aliased to claude --verbose" },
        isExecutable: { $0 == "/opt/homebrew/bin/claude" })
    #expect(locator.locate() == "/opt/homebrew/bin/claude")
}

@Test func theStandardLocationsAreTriedInOrder() {
    let locator = ClaudeExecutableLocator(
        home: "/Users/x", shellLookup: { nil },
        isExecutable: { ["/Users/x/.local/bin/claude", "/usr/local/bin/claude"].contains($0) })
    #expect(locator.locate() == "/Users/x/.local/bin/claude")
}

@Test func noClaudeAnywhereLocatesNothing() {
    let locator = ClaudeExecutableLocator(home: "/Users/x", shellLookup: { nil }, isExecutable: { _ in false })
    #expect(locator.locate() == "")
}

// MARK: - Through the window model

/// The #322 case end to end at the model: an organisation with no accounts
/// (`forTesting` has no account listing at all) finds `claude` through the
/// machine lookup, and the operator's override beats it.
@Test @MainActor func aModelWithNoAccountsSignsInWithTheLocatedClaudeUnlessOverridden() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
    #expect(model.loginBinaryForTesting() == "", "nothing is located before the lookup runs")

    model.useClaudeLocatorForTesting(ClaudeExecutableLocator(
        home: "/Users/x", shellLookup: { nil },
        isExecutable: { $0 == "/opt/homebrew/bin/claude" }))
    await model.locateClaudeIfNeeded()
    #expect(model.resolvedClaudePath() == "/opt/homebrew/bin/claude")
    #expect(model.loginBinaryForTesting() == "/opt/homebrew/bin/claude")

    model.claudePathOverride = "/opt/custom/claude"
    #expect(model.loginBinaryForTesting() == "/opt/custom/claude")
    #expect(model.resolvedClaudePath() == "/opt/homebrew/bin/claude",
            "the prefill shows what Wakil found by itself, not what was typed")
}
