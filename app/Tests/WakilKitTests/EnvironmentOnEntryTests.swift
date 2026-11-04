import Foundation
import Testing
@testable import WakilKit

// Workspaces, piece 3 walk: entering a project never leaves its environment empty when the project
// declares any (Invariant 8), and the context line's Environment segment offers them while none is.

private let declared = [
    EnvironmentListing(name: "production", isReadOnly: false, isProduction: true),
    EnvironmentListing(name: "staging", isReadOnly: false, isProduction: false),
]

struct EnvironmentOnEntryTests {
    @Test func theOneLastUsedInTheProjectComesFirst() {
        #expect(environmentOnEntry(declared: declared, current: "", remembered: "production") == "production")
        #expect(environmentOnEntry(declared: declared, current: "staging", remembered: "production") == "production",
                "an environment carried over from another project is not the one used here")
    }

    @Test func aRememberedOneTheProjectNoLongerDeclaresIsPassedOver() {
        #expect(environmentOnEntry(declared: declared, current: "", remembered: "qa") == "staging")
    }

    @Test func elseTheFirstDeclaredThatIsNotProduction() {
        #expect(environmentOnEntry(declared: declared, current: "", remembered: nil) == "staging", "Rule 9: defaults suggest")
        let onlyProduction = [EnvironmentListing(name: "production", isReadOnly: false, isProduction: true)]
        #expect(environmentOnEntry(declared: onlyProduction, current: "", remembered: nil) == "production",
                "the only one declared, red, rather than none")
    }

    @Test func anEnvironmentAlreadyChosenAndDeclaredStays() {
        #expect(environmentOnEntry(declared: declared, current: "staging", remembered: nil) == nil)
        #expect(environmentOnEntry(declared: declared, current: "staging", remembered: "staging") == nil)
    }

    @Test func aProjectDeclaringNoneHasNothingToChoose() {
        #expect(environmentOnEntry(declared: [], current: "", remembered: "staging") == nil)
    }

    @Test func theBadgeSaysNoneIsChosenWhileTheProjectDeclaresSome() {
        #expect(environmentBadgeLabel(environment: "staging", declaredCount: 2) == "staging")
        #expect(environmentBadgeLabel(environment: "", declaredCount: 2) == "none chosen")
        #expect(environmentBadgeLabel(environment: "", declaredCount: 0) == "unknown",
                "unknown only for a project that declares none")
    }

    @Test func thePickerIsOfferedWhileNoneIsChosen() {
        #expect(environmentHasChoice(environment: "", declaredCount: 1), "one to choose is a choice while none is chosen")
        #expect(environmentHasChoice(environment: "", declaredCount: 2))
        #expect(environmentHasChoice(environment: "staging", declaredCount: 2))
        #expect(!environmentHasChoice(environment: "staging", declaredCount: 1), "a choice of one is no choice")
        #expect(!environmentHasChoice(environment: "", declaredCount: 0))
    }
}
