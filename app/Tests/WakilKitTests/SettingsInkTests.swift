import Foundation
import Testing
@testable import WakilKit

/// The settings pane's four ink steps (settings revamp): cool white at an opacity, measured
/// against the void's lightest stop. Read text must reach WCAG's 4.5:1.

@Test func fullCoolWhiteOnTheVoidIsAboutSeventeenToOne() {
    // #e8ecf6 on #070812 by WCAG relative luminance: 16.87.
    #expect(abs(SettingsInk.contrast(opacity: 1) - 16.87) < 0.05)
    // Half cool white composites to 4.66 — just over the line, which is why secondary is above it.
    #expect(abs(SettingsInk.contrast(opacity: 0.5) - 4.66) < 0.05)
}

@Test func secondaryInkIsReadable() {
    #expect(SettingsInk.contrast(opacity: SettingsInk.secondary) >= 4.5)
}

@Test func primaryInkIsComfortablyReadable() {
    #expect(SettingsInk.contrast(opacity: SettingsInk.primary) >= 7)
}

@Test func theStepsDescend() {
    #expect(SettingsInk.primary > SettingsInk.secondary)
    #expect(SettingsInk.secondary > SettingsInk.tertiary)
    #expect(SettingsInk.tertiary > SettingsInk.disabled)
}
