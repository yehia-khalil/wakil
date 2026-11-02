import Testing
@testable import WakilKit

/// A field saved when it is left (Rule 2), by ANY route — focus moving on, Return, or the field
/// going from screen because the operator clicked elsewhere in the tree. A refusal stays under
/// the field with the text kept (Rule 8), or goes to the window's status when the field is gone.

@Test func leaveSaveWritesOnlyAChangedDraftWithNoWriteInFlight() {
    #expect(LeaveSave.value(draft: "review", stored: "new-environment", saving: false) == "review")
    #expect(LeaveSave.value(draft: nil, stored: "new-environment", saving: false) == nil)
    #expect(LeaveSave.value(draft: "new-environment", stored: "new-environment", saving: false) == nil)
    #expect(LeaveSave.value(draft: "review", stored: "new-environment", saving: true) == nil)
}

@MainActor @Test func aFieldGoneFromScreenWritesWhatWasTyped() {
    // 2e-ii on screen: typed "review", then a tree click swapped the page. The focus change never
    // reaches a view that is gone, so the disappearance is the leave.
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "review"
    #expect(field.disappeared(stored: "new-environment") == "review")
    #expect(field.saving)
    #expect(!field.onScreen)
}

@MainActor @Test func aFieldGoneWithNothingTypedWritesNothing() {
    let field = LeaveSavedField()
    field.appeared()
    #expect(field.disappeared(stored: "staging") == nil)
    #expect(!field.saving)
}

@MainActor @Test func leavingTwiceStartsOneWrite() {
    // Focus loss and the disappearance can both land for the same leave; Return then leaving too.
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "uat"
    #expect(field.leave(stored: "staging") == "uat")
    #expect(field.disappeared(stored: "staging") == nil)
}

@MainActor @Test func aSavedNameClearsTheDraftAndSaysNothing() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "uat"
    _ = field.leave(stored: "staging")
    #expect(field.landed(nil) == nil)
    #expect(field.draft == nil)
    #expect(field.refusal == nil)
    #expect(!field.saving)
}

@MainActor @Test func aRefusalOnScreenStaysUnderTheFieldWithTheTextKept() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "qa"
    _ = field.leave(stored: "staging")
    #expect(field.landed("an environment named qa already exists in project e2e-project") == nil)
    #expect(field.refusal == "an environment named qa already exists in project e2e-project")
    #expect(field.draft == "qa")
    #expect(!field.saving)
}

@MainActor @Test func aRefusalAfterTheFieldWentIsHandedToTheWindowStatus() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "x/y"
    _ = field.disappeared(stored: "staging")
    #expect(field.landed("a name is one segment") == "a name is one segment")
}

@MainActor @Test func aNewWriteClearsTheLastRefusal() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "qa"
    _ = field.leave(stored: "staging")
    _ = field.landed("taken")
    field.draft = "uat"
    #expect(field.leave(stored: "staging") == "uat")
    #expect(field.refusal == nil)
}

@Test func everyTypedOrganisationFieldSavesWhenLeft() {
    // Settings revamp (Rule 2): display name, Jira site and default account join Git and the agent
    // boxes — no field of the organisation needs Save. Speech, quick tasks and pull strategy are
    // choices, saved on their press.
    let leaving = WindowModel.OrganisationField.allCases.filter(\.savesOnLeave)
    #expect(leaving == [.displayName, .jiraBase, .defaultProvider, .gitName, .gitEmail,
                        .agentGeneral, .gitCommitInstructions, .gitPRInstructions])
}

@Test func leaveSaveDoesNotResendTheValueLastRefused() {
    #expect(LeaveSave.value(draft: "qa", stored: "staging", saving: false, refused: "qa") == nil)
    #expect(LeaveSave.value(draft: "qa2", stored: "staging", saving: false, refused: "qa") == "qa2")
}

@MainActor @Test func aRefusedDraftGoingFromScreenIsNotSentAgain() {
    // The operator saw the refusal under the field; the page going is not a second attempt, and a
    // second refusal in the status would read as new.
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "qa"
    _ = field.leave(stored: "staging")
    _ = field.landed("an environment named qa already exists in project e2e-project")
    #expect(field.leave(stored: "staging") == nil)
    #expect(field.disappeared(stored: "staging") == nil)
    #expect(!field.saving)
}

@MainActor @Test func aDraftEditedAfterARefusalIsSentOnLeaving() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "qa"
    _ = field.leave(stored: "staging")
    _ = field.landed("taken")
    field.draft = "uat"
    #expect(field.disappeared(stored: "staging") == "uat")
}

@MainActor @Test func returnSendsTheRefusedValueAgain() {
    // Return is the operator asking again — a rename refused while an agent ran saves once it stops.
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "review"
    _ = field.submit(stored: "staging")
    _ = field.landed("an agent is running in walk-2e-ii@review")
    #expect(field.submit(stored: "staging") == "review")
}

@MainActor @Test func aSaveAfterARefusalForgetsIt() {
    let field = LeaveSavedField()
    field.appeared()
    field.draft = "qa"
    _ = field.submit(stored: "staging")
    _ = field.landed("taken")
    _ = field.submit(stored: "staging")
    _ = field.landed(nil)
    field.draft = "qa"
    #expect(field.leave(stored: "uat") == "qa")
}

/// Autosave (3a-iii walk): text typed while a save is in flight survives it, and is the next save.
@MainActor @Test func typingDuringASaveIsKeptAndSavedNext() {
    let field = LeaveSavedField()
    field.draft = "a"
    #expect(field.leave(stored: "") == "a")
    field.draft = "ab"
    _ = field.landed(nil)
    #expect(field.draft == "ab")
    #expect(field.leave(stored: "a") == "ab")
    _ = field.landed(nil)
    #expect(field.draft == nil)
}
