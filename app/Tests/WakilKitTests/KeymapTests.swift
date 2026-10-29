import Testing
@testable import WakilKit

@Suite struct KeymapTests {
    private func c(_ text: String) -> KeyChord { KeyChord(text)! }
    private let plain = Keymap(overrides: [:])

    @Test func tableHasAllFortyFourCommands() {
        #expect(KeyCommand.all.count == 44)
        #expect(Set(KeyCommand.all.map(\.id)).count == 44)
        #expect(FixedKey.all.count == 8)
    }

    @Test func noTwoDefaultsShareAChordInOnePlace() {
        var seen = Set<String>()
        for command in KeyCommand.all {
            #expect(seen.insert("\(command.place)|\(command.defaultChord.text)").inserted, "\(command.id)")
            #expect(!command.defaultChord.isRefused, "\(command.id)")
        }
    }

    /// The F-key monitor's take-or-leave: a chord is Wakil's only where some command holds it.
    @Test func claimsOnlyAChordACommandHoldsThere() {
        let f5 = Keymap(overrides: ["browser.reload": "F5", "window.toggleRail": "F6"])
        #expect(f5.claims(c("F5"), paneKind: "browser"))
        #expect(!f5.claims(c("F5"), paneKind: "editor"), "a browser key outside a browser goes on")
        #expect(!f5.claims(c("F5"), paneKind: nil))
        #expect(f5.claims(c("F6"), paneKind: "editor"), "an anywhere key is taken in every pane")
        #expect(!f5.claims(c("F7"), paneKind: "browser"))
    }

    /// The menu bar's one item per chord: the anywhere command's, else the first pane command's.
    @Test func menuHolderPrefersTheAnywhereCommand() {
        #expect(plain.menuHolder(of: c("⌘T")) == "editor.newScratch")
        #expect(plain.menuHolder(of: c("⌘L")) == "browser.focusAddress", "no anywhere command holds ⌘L")
        #expect(plain.menuHolder(of: c("⌃⌘J")) == nil)
        let moved = Keymap(overrides: ["editor.newScratch": ""])
        #expect(moved.menuHolder(of: c("⌘T")) == "browser.newTab", "the browser item takes it back")
    }

    @Test func sharedChordResolvesPaneFirst() {
        #expect(plain.resolve(c("⌘T"), paneKind: "browser") == ["browser.newTab", "editor.newScratch"])
        #expect(plain.resolve(c("⌘T"), paneKind: "editor") == ["editor.newScratch"])
    }

    @Test func unboundChordResolvesEmpty() {
        #expect(plain.resolve(c("⌃⌘J"), paneKind: nil) == [])
    }

    @Test func assignTakesAndReports() throws {
        let done = try plain.assign("editor.save", c("⌘P")).get()
        #expect(done.tookFrom == "window.open")
        #expect(done.overrides == ["editor.save": "⌘P", "window.open": ""])
    }

    @Test func assignInOtherPlaceDoesNotTake() throws {
        let done = try plain.assign("browser.reload", c("⌘B")).get()
        #expect(done.tookFrom == nil)
        #expect(done.overrides == ["browser.reload": "⌘B"])
    }

    @Test func movingTheAnywhereHalfLeavesThePaneHalf() throws {
        let map = Keymap(overrides: try plain.assign("editor.newScratch", c("⌃⌘T")).get().overrides)
        #expect(map.resolve(c("⌘T"), paneKind: "browser") == ["browser.newTab"])
        #expect(map.resolve(c("⌘T"), paneKind: "editor") == [])
    }

    @Test func assignRefusesDecision50() {
        guard case .failure(let refusal) = plain.assign("pane.close", c("⌘Q")) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.message.contains("Decision 50"))
    }

    @Test func assignNilClears() throws {
        let done = try plain.assign("pane.close", nil).get()
        #expect(done.overrides == ["pane.close": ""])
        let map = Keymap(overrides: done.overrides)
        #expect(map.chord("pane.close") == nil)
        #expect(map.resolve(c("⌘W"), paneKind: nil) == [])
    }

    @Test func assigningTheDefaultDropsTheEntry() throws {
        let moved = Keymap(overrides: try plain.assign("pane.close", c("⌃⌘J")).get().overrides)
        #expect(try moved.assign("pane.close", c("⌘W")).get().overrides == [:])
    }

    @Test func restoringDefaultDropsTheEntry() {
        let map = Keymap(overrides: ["pane.close": "⌃⌘J", "window.open": ""])
        #expect(map.restoringDefault("pane.close") == ["window.open": ""])
        #expect(map.isDefault("pane.close") == false)
        #expect(plain.isDefault("pane.close"))
    }

    @Test func unknownIdsSurviveAssign() throws {
        let map = Keymap(overrides: ["future.cmd": "⌃⌘J"])
        #expect(try map.assign("editor.save", c("⌃⌘K")).get().overrides["future.cmd"] == "⌃⌘J")
        #expect(try map.assign("editor.save", nil).get().overrides["future.cmd"] == "⌃⌘J")
        #expect(map.restoringDefault("editor.save")["future.cmd"] == "⌃⌘J")
    }

    @Test func storedRefusedChordFallsBackToDefault() {
        let map = Keymap(overrides: ["pane.close": "⌘Q"])
        #expect(map.chord("pane.close") == c("⌘W"))
        #expect(map.problem("pane.close")?.contains("Decision 50") == true)
    }

    @Test func duplicateStoredChordFirstInTableWins() {
        let map = Keymap(overrides: ["conversation.new": "⌃⌘J", "pane.close": "⌃⌘J"])
        #expect(map.resolve(c("⌃⌘J"), paneKind: nil) == ["conversation.new"])
        #expect(map.problem("pane.close")?.contains("New Conversation") == true)
        #expect(map.problem("conversation.new") == nil)
    }

    /// Settings → Keyboard's search: "⌘T" and "tab" both find New Tab, in either case.
    @Test func matchingFindsByTitleOrChord() {
        let ids = { (q: String, map: Keymap) in KeyCommand.matching(q, keymap: map).map(\.id) }
        // A part of a chord matches, so ⇧⌘T's Reopen Closed Tab is found too.
        #expect(ids("⌘T", plain) == ["editor.newScratch", "browser.newTab", "browser.reopenTab"])
        #expect(ids("⌘t", plain) == ids("⌘T", plain), "a chord's letter in either case")
        #expect(ids("tab", plain).contains("browser.newTab"))
        #expect(ids("SAVE", plain) == ["editor.save"])
        #expect(ids("  ", plain).count == KeyCommand.all.count, "an empty search shows everything")
        #expect(ids("⌃⌘J", plain).isEmpty)
        // The chord in force, not the default: a moved chord is found where it went.
        let moved = Keymap(overrides: ["editor.save": "⌃⌘J"])
        #expect(ids("⌃⌘J", moved) == ["editor.save"])
        #expect(!ids("⌘S", moved).contains("editor.save"))
        #expect(ids("none", Keymap(overrides: ["editor.save": ""])).isEmpty, "no chord matches no text")
    }
}
