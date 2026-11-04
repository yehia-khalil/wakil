import Foundation
import Testing
@testable import WakilKit

/// The settings tree grouped by scope (settings revamp, 2026-11-02): WAKIL, the organisation,
/// PROJECTS. Identifier fragments never move, so every e2e check keeps reaching its node.

@Test func everyExistingNodeKeepsItsIdentifierFragment() {
    let pinned: [(SettingsNode, String)] = [
        (.organisation, "organisation"), (.providers, "providers"), (.projects, "projects"),
        (.editor, "editor"), (.browser, "browser"), (.keyboard, "keyboard"),
        (.projectEditor("x"), "projectEditor.x"), (.project("x"), "project.x"),
        (.environment(project: "x", environment: "y"), "environment.x.y"),
        (.databases(project: "x", environment: "y"), "databases.x.y"),
        (.api(project: "x", environment: "y"), "api.x.y"),
    ]
    for (node, fragment) in pinned { #expect(node.identifierFragment == fragment) }
}

@Test func theNewOrganisationPagesHaveTheirOwnFragments() {
    #expect(SettingsNode.quickTasks.identifierFragment == "quickTasks")
    #expect(SettingsNode.browsingData.identifierFragment == "browsingData")
    #expect(SettingsNode.speech.identifierFragment == "speech")
}

@Test func eachScopeListsItsPagesInOrder() {
    #expect(SettingsNode.topLevel(.wakil) == [.editor, .browser, .keyboard])
    #expect(SettingsNode.topLevel(.organisation)
            == [.organisation, .providers, .quickTasks, .browsingData, .speech])
}

@Test func providersIsLabelledAccounts() {
    #expect(SettingsNode.providers.label == "Accounts")
    #expect(SettingsNode.organisation.label == "Organisation")
    #expect(SettingsNode.quickTasks.label == "Quick tasks")
    #expect(SettingsNode.browsingData.label == "Browsing data")
    #expect(SettingsNode.speech.label == "Speech")
}

@Test func breadcrumbsNameTheScopeThenThePage() {
    let org = "Organisation"   // no tree: the fallback label
    #expect(SettingsNode.organisation.breadcrumb(in: nil) == [org, "Organisation"])
    #expect(SettingsNode.providers.breadcrumb(in: nil) == [org, "Accounts"])
    #expect(SettingsNode.quickTasks.breadcrumb(in: nil) == [org, "Quick tasks"])
    #expect(SettingsNode.browsingData.breadcrumb(in: nil) == [org, "Browsing data"])
    #expect(SettingsNode.speech.breadcrumb(in: nil) == [org, "Speech"])
    #expect(SettingsNode.browser.breadcrumb(in: nil) == ["Wakil", "Browser"])
    #expect(SettingsNode.api(project: "p", environment: "e").breadcrumb(in: nil)
            == [org, "Projects", "p", "e", "API"])
}

@Test func aRenameKeepsTheOperatorOnTheSamePlace() {
    #expect(SettingsNode.databases(project: "a", environment: "e").renaming(project: "a", to: "b")
            == .databases(project: "b", environment: "e"))
    #expect(SettingsNode.api(project: "a", environment: "e").renaming(project: "a", environment: "e", to: "f")
            == .api(project: "a", environment: "f"))
    #expect(SettingsNode.speech.renaming(project: "a", to: "b") == .speech)
}
