import Testing
@testable import WakilKit

@Test func landingInAnEmptyDraftIsJustTheWords() {
    let r = ComposerText.insert("show tables", into: "", at: 0)
    #expect(r.draft == "show tables")
    #expect(r.caret == 11)
}

@Test func landingAtTheEndAddsASpace() {
    let r = ComposerText.insert("in staging", into: "show tables", at: 11)
    #expect(r.draft == "show tables in staging")
    #expect(r.caret == 22)
}

@Test func landingMidDraftPadsBothSidesAndReplacesNothing() {
    let r = ComposerText.insert("all", into: "show tables", at: 5)
    #expect(r.draft == "show all tables")
    #expect(r.caret == 8)
}

@Test func existingWhitespaceIsNotDoubled() {
    let r = ComposerText.insert("all", into: "show  tables", at: 5)
    #expect(r.draft == "show all tables")
    #expect(!r.draft.contains("   "))
}

/// Review focus 5.
@Test func aCaretPastTheEndIsClamped() {
    let r = ComposerText.insert("x", into: "ab", at: 99)
    #expect(r.draft == "ab x")
}

@Test func theCaretCountsUTF16LikeNSTextView() {
    // "👍" is two UTF-16 units; the caret after it is 2.
    let r = ComposerText.insert("ok", into: "👍", at: 2)
    #expect(r.draft == "👍 ok")
    #expect(r.caret == 5)
}

@Test func theBarShowsTheKeysWhenIdle() {
    #expect(ComposerBarContent.make(machine: ListeningMachine(), landedUnsent: false)
            == .draft(hint: "Hold ⌥ to speak · ⌘P open · ⌘K actions"))
}

@Test func theBarSaysHeardAfterALanding() {
    #expect(ComposerBarContent.make(machine: ListeningMachine(), landedUnsent: true)
            == .draft(hint: "heard · Return sends · edit first"))
}

@Test func theBarShowsTheTranscriptWhileListening() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    _ = m.receive(.partial(settled: "open the", volatile: "book"))
    #expect(ComposerBarContent.make(machine: m, landedUnsent: false)
            == .hearing(before: "", settled: "open the", volatile: "book", after: "",
                        hint: "release to put it in the line"))
}

@Test func theBarSaysTheNoticesInWords() {
    #expect(ComposerBarContent.sentence(for: .heardNothing(device: "MacBook Pro Microphone"))
            == "Hearing nothing from MacBook Pro Microphone")
    #expect(ComposerBarContent.sentence(for: .denied)
            == "Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone")
    #expect(ComposerBarContent.sentence(for: .downloading(fraction: 0.42, totalBytes: 0))
            == "Downloading the English speech model — 42% · Esc cancels")
    #expect(ComposerBarContent.sentence(for: .downloading(fraction: 0.5, totalBytes: 120_000_000))
            .hasPrefix("Downloading the English speech model — 50% of "))
}

@Test func aCaretInsideAnEmojiSnapsToItsStart() {
    let r = ComposerText.insert("ok", into: "👍", at: 1)
    #expect(r.draft == "ok 👍")
    #expect(r.caret == 2)
}

@Test func aCaretInsideACRLFKeepsItIntact() {
    let r = ComposerText.insert("x", into: "a\r\nb", at: 2)
    #expect(r.draft == "a x\r\nb")
    #expect(r.caret == 3)
}

@Test func theBarKeepsAStandingPermissionNoticeWhenIdle() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    _ = m.receive(.permissionPending)
    _ = m.optionUp(at: 1); _ = m.tick(at: 4)
    #expect(ComposerBarContent.make(machine: m, landedUnsent: false)
            == .notice("Allow Wakil to use the microphone in the macOS prompt, then hold ⌥ again", draft: "",
                       hint: ComposerBarContent.keysHint(Keymap(overrides: [:]))))
}

// 3a-ii walk: a second hold hid what the first had landed, so the operator said it all again and it
// landed twice. The line stays in view and the words grow where they will land.

@Test func aHoldKeepsTheLineInViewAndDrawsTheWordsWhereTheyWillLand() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    _ = m.receive(.partial(settled: "say hello", volatile: "from the"))
    let draft = "please say hello from the microphone"
    #expect(ComposerBarContent.make(machine: m, landedUnsent: true, draft: draft, caret: draft.utf16.count)
            == .hearing(before: draft + " ", settled: "say hello", volatile: "from the", after: "",
                        hint: ComposerBarContent.releaseHint))
}

@Test func aHoldWithNothingHeardYetStillDrawsTheLine() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    #expect(ComposerBarContent.make(machine: m, landedUnsent: false, draft: "please", caret: 6)
            == .hearing(before: "please", settled: "", volatile: "", after: "", hint: ComposerBarContent.releaseHint))
}

@Test func aNoticeMidHoldKeepsTheLineInView() {
    var m = ListeningMachine()
    _ = m.optionDown(at: 0); _ = m.tick(at: 0.2)
    _ = m.receive(.started(device: "E2E Microphone"), at: 0.2)
    _ = m.tick(at: 5)
    guard case .notice(_, let draft, _) = ComposerBarContent.make(machine: m, landedUnsent: false,
                                                                  draft: "please", caret: 6) else {
        Issue.record("expected the silence notice"); return
    }
    #expect(draft == "please")
}

@Test func theWordsAroundTheCaretArePaddedAsTheLandingPadsThem() {
    let around = ComposerText.around("all", in: "showtables", at: 4)
    #expect(around.before == "show ")
    #expect(around.after == " tables")
    let landed = ComposerText.insert("all", into: "showtables", at: 4)
    #expect(around.before + "all" + around.after == landed.draft)
}

@Test func nothingHeardSplitsTheLineAtTheCaretUnpadded() {
    let around = ComposerText.around("", in: "a\r\nb", at: 2)
    #expect(around.before == "a")
    #expect(around.after == "\r\nb")
}

// Shortcuts are rebindable (Decision 50): the idle hint names the chords in force, not ⌘P and ⌘K.

@Test func theIdleHintNamesTheDefaultChords() {
    #expect(ComposerBarContent.keysHint(Keymap(overrides: [:])) == "Hold ⌥ to speak · ⌘P open · ⌘K actions")
}

@Test func theIdleHintFollowsARebind() {
    let keymap = Keymap(overrides: ["window.open": "⌃⌘O", "window.commands": "⌃⌘K"])
    #expect(ComposerBarContent.keysHint(keymap) == "Hold ⌥ to speak · ⌃⌘O open · ⌃⌘K actions")
    #expect(ComposerBarContent.make(machine: ListeningMachine(), landedUnsent: false, keymap: keymap)
            == .draft(hint: "Hold ⌥ to speak · ⌃⌘O open · ⌃⌘K actions"))
}

@Test func theIdleHintDropsACommandWithNoChord() {
    let keymap = Keymap(overrides: ["window.open": ""])
    #expect(ComposerBarContent.keysHint(keymap) == "Hold ⌥ to speak · ⌘K actions")
}
