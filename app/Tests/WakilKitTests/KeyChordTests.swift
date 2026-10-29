import AppKit
import Testing
@testable import WakilKit

// Keyboard, Task 2: KeyChord, the type for one shortcut.

@Suite struct KeyChordTests {
    @Test func testRoundTripsEveryDefaultChord() {
        for s in ["⌘N", "⇧⌘W", "⌘↩", "⌃⌘R", "⌃Tab", "⌃⇧Tab", "⇧⌘]", "⌘=", "⌘,", "F5"] {
            #expect(KeyChord(s)?.text == s, "\(s)")
        }
    }

    @Test func testPrintsModifiersInMacOrder() {
        let chord = KeyChord(modifiers: [.command, .shift, .control], key: .character("r"))
        #expect(chord.text == "⌃⇧⌘R")
    }

    @Test func testRejectsMalformed() {
        #expect(KeyChord("R") != nil)
        for s in ["", "⌘", "⌘⌘R", "⌘RR", "F0", "F20", "⌘F05"] {
            #expect(KeyChord(s) == nil, "\(s)")
        }
    }

    @Test func testRefusesDecision50() {
        let refused = ["⌘Q", "⌘H", "⌥⌘H", "⌘M", "⌘Tab", "⌘`", "⌘Space", "⌃Space",
                       "⌘C", "⌘V", "⌘X", "⌘Z", "⇧⌘Z", "⌘A", "R", "⇧R", "⌥R"]
        for s in refused { #expect(KeyChord(s)!.isRefused, "\(s)") }
        for s in ["F5", "⌃R", "⌘T", "⌃⌘S"] { #expect(!KeyChord(s)!.isRefused, "\(s)") }
    }

    @Test func testChordFromEventUsesKeyCodeOnNonLatinLayout() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "к", charactersIgnoringModifiers: "к",
            isARepeat: false, keyCode: 15))
        #expect(KeyChord(event: event)?.text == "⌘R")
    }
}
