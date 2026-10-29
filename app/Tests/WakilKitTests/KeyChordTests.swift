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

    private func keyDown(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code))
    }

    /// A Latin layout's letter is the letter it types, wherever the key sits: AZERTY's A is on
    /// ANSI Q (12), its W on ANSI Z (6), Dvorak's T on ANSI K (40).
    @Test func testChordFromEventUsesTheCharacterOnLatinLayouts() throws {
        #expect(KeyChord(event: try keyDown("a", code: 12))?.text == "⌘A")
        #expect(KeyChord(event: try keyDown("w", code: 6))?.text == "⌘W")
        #expect(KeyChord(event: try keyDown("t", code: 40))?.text == "⌘T")
        #expect(KeyChord(event: try keyDown("r", code: 15)) == KeyChord("⌘R"), "⌘r and ⌘R are one chord")
    }

    /// Shift's own character is not the key: ⇧⌘} is ⇧⌘], and ⇧⌘G stays ⇧⌘G. The digit row is
    /// the digit on every Latin layout (AZERTY types & there, and ⌘& is ⌘1).
    @Test func testChordFromEventShiftAndDigits() throws {
        #expect(KeyChord(event: try keyDown("}", code: 30, [.command, .shift]))?.text == "⇧⌘]")
        #expect(KeyChord(event: try keyDown("G", code: 5, [.command, .shift]))?.text == "⇧⌘G")
        #expect(KeyChord(event: try keyDown("&", code: 18))?.text == "⌘1")
    }

    /// Named keys and F-keys come by key code: their characters are private-use or control codes.
    @Test func testChordFromEventNamedKeys() throws {
        #expect(KeyChord(event: try keyDown("\r", code: 36))?.text == "⌘↩")
        #expect(KeyChord(event: try keyDown("\u{F708}", code: 96, []))?.text == "F5")
        #expect(KeyChord(event: try keyDown("\t", code: 48, [.control, .shift]))?.text == "⌃⇧Tab")
    }

    /// A menu item's click has a mouse event as the current event: no chord, and no AppKit raise.
    @Test func testMouseEventGivesNoChord() throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(KeyChord(event: event) == nil)
    }
}
