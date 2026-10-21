import Testing
@testable import WakilKit

/// The settings tree's open branches: defaults laid once, closed only by the operator, and
/// opened — never closed — when a node inside a closed parent is reached (Rule 6).

@Test func expansionDefaultsOpenTheHeadingTheActiveProjectAndItsEnvironment() {
    var expansion = SettingsTreeExpansion()
    expansion.seed(activeProject: "e2e-git", activeEnvironment: "staging")
    #expect(expansion.projectsOpen)
    #expect(expansion.isOpen(project: "e2e-git"))
    #expect(expansion.isOpen(project: "e2e-git", environment: "staging"))
    #expect(!expansion.isOpen(project: "e2e-git", environment: "qa"))
    #expect(!expansion.isOpen(project: "e2e-project"))
}

@Test func expansionSeedsOnceSoAnOperatorsClosingSurvivesARead() {
    var expansion = SettingsTreeExpansion()
    expansion.seed(activeProject: "e2e-git", activeEnvironment: "staging")
    expansion.setOpen(false, project: "e2e-git")
    expansion.projectsOpen = false
    expansion.seed(activeProject: "e2e-git", activeEnvironment: "staging")
    #expect(!expansion.isOpen(project: "e2e-git"))
    #expect(!expansion.projectsOpen)
}

@Test func expansionWaitsForAPlaceBeforeSeeding() {
    var expansion = SettingsTreeExpansion()
    expansion.seed(activeProject: "", activeEnvironment: "")
    #expect(!expansion.seeded)
    expansion.seed(activeProject: "p", activeEnvironment: "e")
    #expect(expansion.seeded)
    #expect(expansion.isOpen(project: "p", environment: "e"))
}

@Test func expansionRevealOpensAncestorsAndClosesNothing() {
    var expansion = SettingsTreeExpansion()
    expansion.seed(activeProject: "a", activeEnvironment: "staging")
    expansion.projectsOpen = false
    expansion.reveal(project: "b", environment: "qa")
    #expect(expansion.projectsOpen)
    #expect(expansion.isOpen(project: "b", environment: "qa"))
    #expect(expansion.isOpen(project: "a"), "revealing one branch never closes another")
    #expect(expansion.isOpen(project: "a", environment: "staging"))
}

@Test func expansionTogglesEachBranchOnItsOwn() {
    var expansion = SettingsTreeExpansion()
    expansion.setOpen(true, project: "p", environment: "qa")
    expansion.setOpen(true, project: "p", environment: "staging")
    expansion.setOpen(false, project: "p", environment: "qa")
    #expect(!expansion.isOpen(project: "p", environment: "qa"))
    #expect(expansion.isOpen(project: "p", environment: "staging"))
}

@Test func expansionResetForgetsTheOldOrganisation() {
    var expansion = SettingsTreeExpansion()
    expansion.seed(activeProject: "p", activeEnvironment: "e")
    expansion.reset()
    #expect(!expansion.seeded)
    #expect(!expansion.isOpen(project: "p"))
    #expect(expansion.projectsOpen)
}
