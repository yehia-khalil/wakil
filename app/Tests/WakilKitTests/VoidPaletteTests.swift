import Testing
@testable import WakilKit

@Test func aProductionEnvironmentTurnsTheVoidRed() {
    let palette = VoidPalette.forEnvironment("production", production: .undeclared)
    #expect(palette.isProduction)
    #expect(palette.bleedA == VoidPalette.red)
    #expect(palette.bleedB == VoidPalette.red)
}

/// `writeGate` matches production case-insensitively, and a treatment that
/// disagreed with the gate about what production is would be worse than no
/// treatment: the room would look safe while the gate refused.
@Test func productionIsMatchedRegardlessOfCase() {
    #expect(VoidPalette.forEnvironment("Production", production: .undeclared).isProduction)
    #expect(VoidPalette.forEnvironment("PRODUCTION", production: .undeclared).isProduction)
    #expect(VoidPalette.forEnvironment("  production  ", production: .undeclared).isProduction)
}

@Test func everyOtherEnvironmentKeepsTheVioletAndBlueBleeds() {
    for name in ["staging", "local", "development", "prod-like", "preproduction"] {
        let palette = VoidPalette.forEnvironment(name, production: .undeclared)
        #expect(!palette.isProduction, "\(name) is not production")
        #expect(palette.bleedA == VoidPalette.violet)
        #expect(palette.bleedB == VoidPalette.blue)
    }
}

/// The failure direction matters. An environment that has not resolved yet
/// is empty (`WindowModel.environment` before `refreshContext` answers), and
/// a treatment that failed *into* production would paint the room red on
/// every launch until the answer arrived — which is how a warning stops
/// being read.
@Test func anUnresolvedEnvironmentIsNotProduction() {
    #expect(!VoidPalette.forEnvironment("", production: .undeclared).isProduction)
    #expect(!VoidPalette.forEnvironment("unknown", production: .undeclared).isProduction)
}
