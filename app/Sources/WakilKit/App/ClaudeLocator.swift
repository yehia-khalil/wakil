import Foundation
import Observation

/// Which `claude` a provider login spawns (#322; extracted from `WindowModel`
/// in PR 6 of the split). Order: an injected binary (tests), the path the
/// operator typed, this organisation's own record, the machine lookup.
@MainActor
@Observable
final class ClaudeLocator {
    /// The `claude` path the operator typed on the register form, which wins
    /// over every lookup. Empty means "use what Wakil found".
    var override: String = ""
    /// The machine lookup's answer, read once and off the main actor.
    private(set) var located: String?
    @ObservationIgnored private var locator: ClaudeExecutableLocator?
    /// A binary pinned by the caller (a test's fake); wins when non-empty.
    @ObservationIgnored private let injected: String

    init(locator: ClaudeExecutableLocator?, injected: String) {
        self.locator = locator
        self.injected = injected
    }

    func loginBinary(ownBinaries: [String]) -> String {
        if !injected.isEmpty { return injected }
        return resolveLoginBinary(override: override, ownBinaries: ownBinaries, located: located ?? "")
    }

    /// What the register form prefills: never the override.
    func resolvedPath(ownBinaries: [String]) -> String {
        if !injected.isEmpty { return injected }
        return resolveLoginBinary(override: "", ownBinaries: ownBinaries, located: located ?? "")
    }

    func locateIfNeeded() async {
        guard located == nil, let locator else { return }
        located = await Task.detached { locator.locate() }.value
    }

    func use(_ locator: ClaudeExecutableLocator) {
        self.locator = locator
        located = nil
    }
}
