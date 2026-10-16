import Testing
@testable import WakilKit

// Final review, item 4: ⌥⇧F is matched by key position (kVK_ANSI_F = 3), not by character,
// so it works on Arabic, Cyrillic and other non-Latin layouts.

@Test func formatIsTheFKeyWithExactlyOptionShift() {
    #expect(QueryLineKeys.isFormat(keyCode: 3, option: true, shift: true, command: false, control: false))
    #expect(!QueryLineKeys.isFormat(keyCode: 3, option: true, shift: false, command: false, control: false))
    #expect(!QueryLineKeys.isFormat(keyCode: 3, option: false, shift: true, command: false, control: false))
    #expect(!QueryLineKeys.isFormat(keyCode: 3, option: true, shift: true, command: true, control: false))
    #expect(!QueryLineKeys.isFormat(keyCode: 3, option: true, shift: true, command: false, control: true))
    // kVK_ANSI_G is 5: another key with the same modifiers is not Format.
    #expect(!QueryLineKeys.isFormat(keyCode: 5, option: true, shift: true, command: false, control: false))
}
