import Foundation
import Testing
@testable import WakilKit

private func locator(answer: String, calls: LockedCounter) -> ClaudeExecutableLocator {
    ClaudeExecutableLocator(
        home: "/Users/x",
        shellLookup: { calls.increment(); return answer },
        isExecutable: { _ in true })
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor
@Test func anInjectedBinaryWinsOverEverything() {
    let claude = ClaudeLocator(locator: nil, injected: "/fake/claude")
    claude.override = "/typed/claude"
    #expect(claude.loginBinary(ownBinaries: ["/own/claude"]) == "/fake/claude")
    #expect(claude.resolvedPath(ownBinaries: ["/own/claude"]) == "/fake/claude")
}

@MainActor
@Test func theTypedOverrideWinsForALoginButNotForTheFormsPrefill() {
    let claude = ClaudeLocator(locator: nil, injected: "")
    claude.override = "/typed/claude"
    #expect(claude.loginBinary(ownBinaries: ["/own/claude"]) == "/typed/claude")
    #expect(claude.resolvedPath(ownBinaries: ["/own/claude"]) == "/own/claude")
}

@MainActor
@Test func theMachineLookupRunsOnce() async {
    let calls = LockedCounter()
    let claude = ClaudeLocator(locator: locator(answer: "/opt/homebrew/bin/claude", calls: calls), injected: "")
    await claude.locateIfNeeded()
    await claude.locateIfNeeded()
    #expect(calls.value == 1)
    #expect(claude.located == "/opt/homebrew/bin/claude")
    #expect(claude.resolvedPath(ownBinaries: []) == "/opt/homebrew/bin/claude")
}

@MainActor
@Test func aNewLocatorForgetsTheOldAnswer() async {
    let claude = ClaudeLocator(locator: locator(answer: "/a/claude", calls: LockedCounter()), injected: "")
    await claude.locateIfNeeded()
    claude.use(locator(answer: "/b/claude", calls: LockedCounter()))
    #expect(claude.located == nil)
    await claude.locateIfNeeded()
    #expect(claude.located == "/b/claude")
}

@MainActor
@Test func anOrgSwitchClearsTheTypedOverride() async {
    let model = WindowModel.forTesting(scratchRoot: testScratchRoot, organization: "alpha")
    model.claudePathOverride = "/typed/claude"
    await model.invalidateForOrgChange()
    #expect(model.claudePathOverride == "")
}
