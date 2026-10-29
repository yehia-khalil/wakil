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

    /// The table is the menu bar now, so a typo silently changes a shortcut: every row pinned
    /// against the plan's table (id, title, place, default chord, menu group), in table order.
    @Test func tableMatchesThePlanRowForRow() {
        let plan: [(String, String, String, String, String)] = [
            ("conversation.new", "New Conversation", "A", "⌘N", "Conversation"),
            ("conversation.close", "Close Conversation", "A", "⇧⌘W", "Conversation"),
            ("pane.maximize", "Maximize Pane", "A", "⌘↩", "Pane"),
            ("pane.close", "Close Pane", "A", "⌘W", "Pane"),
            ("pane.toggleDensity", "Toggle Density", "A", "⇧⌘D", "Pane"),
            ("editor.newScratch", "New Scratch Tab", "A", "⌘T", "Editor"),
            ("editor.showFiles", "Show Files", "A", "⌘B", "Editor"),
            ("editor.searchFiles", "Search Files", "A", "⇧⌘F", "Editor"),
            ("editor.showChanges", "Show Changes", "A", "⇧⌘G", "Editor"),
            ("editor.save", "Save", "A", "⌘S", "Editor"),
            ("window.organisation", "Organisation…", "A", "⇧⌘O", "Window"),
            ("window.open", "Open…", "A", "⌘P", "Window"),
            ("window.commands", "Run a Command…", "A", "⌘K", "Window"),
            ("window.settings", "Settings…", "A", "⌘,", "Window"),
            ("window.toggleRail", "Toggle Rail", "A", "⌃⌘R", "Window"),
            ("browser.newTab", "New Tab", "B", "⌘T", "Browser"),
            ("browser.closeTab", "Close Tab", "B", "⌘W", "Browser"),
            ("browser.findPrevious", "Find Previous", "B", "⇧⌘G", "Browser"),
            ("browser.reopenTab", "Reopen Closed Tab", "B", "⇧⌘T", "Browser"),
            ("browser.focusAddress", "Open Location", "B", "⌘L", "Browser"),
            ("browser.reload", "Reload Page", "B", "⌘R", "Browser"),
            ("browser.back", "Back", "B", "⌘[", "Browser"),
            ("browser.forward", "Forward", "B", "⌘]", "Browser"),
            ("browser.bookmark", "Add Bookmark", "B", "⌘D", "Browser"),
            ("browser.copyURL", "Copy Page Address", "B", "⇧⌘C", "Browser"),
            ("browser.find", "Find…", "B", "⌘F", "Browser"),
            ("browser.findNext", "Find Next", "B", "⌘G", "Browser"),
            ("browser.zoomIn", "Zoom In", "B", "⌘=", "Browser"),
            ("browser.zoomOut", "Zoom Out", "B", "⌘-", "Browser"),
            ("browser.zoomReset", "Actual Size", "B", "⌘0", "Browser"),
            ("browser.showNextTab", "Show Next Tab", "B", "⌃Tab", "Browser"),
            ("browser.showPreviousTab", "Show Previous Tab", "B", "⌃⇧Tab", "Browser"),
            ("browser.nextTab", "Next Tab", "B", "⇧⌘]", "Browser"),
            ("browser.previousTab", "Previous Tab", "B", "⇧⌘[", "Browser"),
            ("browser.tab1", "Tab 1", "B", "⌘1", "Browser"),
            ("browser.tab2", "Tab 2", "B", "⌘2", "Browser"),
            ("browser.tab3", "Tab 3", "B", "⌘3", "Browser"),
            ("browser.tab4", "Tab 4", "B", "⌘4", "Browser"),
            ("browser.tab5", "Tab 5", "B", "⌘5", "Browser"),
            ("browser.tab6", "Tab 6", "B", "⌘6", "Browser"),
            ("browser.tab7", "Tab 7", "B", "⌘7", "Browser"),
            ("browser.tab8", "Tab 8", "B", "⌘8", "Browser"),
            ("browser.lastTab", "Last Tab", "B", "⌘9", "Browser"),
            ("browser.toggleTabColumn", "Toggle Tab Column", "B", "⌃⌘S", "Browser"),
        ]
        let rows = KeyCommand.all.map { command in
            (command.id, command.title, command.place == .anywhere ? "A" : command.place == .pane("browser") ? "B" : "?",
             command.defaultChord.text, command.group.title)
        }
        #expect(rows.count == plan.count)
        for (row, want) in zip(rows, plan) {
            #expect(row == want, "\(want.0)")
        }
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

    /// A focused web page is offered a key after the menu only for the always-Wakil commands, by
    /// their chords in force: a rebound one moves with its command, and the page keeps ⌘F or ⌘B.
    @Test func takesBeforePageFollowsTheChordsInForce() {
        for chord in ["⌘K", "⌘P", "⌘N", "⌘T", "⌘W", "⌘L", "⌘1", "⌘8", "⌘9", "⌘,", "⌘D", "⇧⌘W", "⇧⌘C", "⌃⌘R"] {
            #expect(plain.takesBeforePage(c(chord), tabColumn: false), "\(chord)")
        }
        for chord in ["⌘F", "⌘B", "⌘S", "⌘R", "⌘G", "⌃⌘J"] {
            #expect(!plain.takesBeforePage(c(chord), tabColumn: false), "\(chord) is the page's first")
        }
        #expect(!plain.takesBeforePage(c("⌃⌘S"), tabColumn: false), "horizontal tabs: the page's")
        #expect(plain.takesBeforePage(c("⌃⌘S"), tabColumn: true))
        let moved = Keymap(overrides: ["window.commands": "⌃⌘K", "conversation.new": "⌃⌘J"])
        #expect(moved.takesBeforePage(c("⌃⌘K"), tabColumn: false))
        #expect(moved.takesBeforePage(c("⌃⌘J"), tabColumn: false))
        #expect(!moved.takesBeforePage(c("⌘K"), tabColumn: false), "the old chord is the page's now")
        #expect(Keymap.beforePage.allSatisfy { KeyCommand.byID[$0] != nil })
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

    /// ↺ is `assign` of the default: the entry goes, and a command holding the default loses it.
    @Test func restoringTheDefaultTakesItFromItsHolder() throws {
        let map = Keymap(overrides: ["editor.save": "⌃⌘S", "conversation.new": "⌘S"])
        let done = try map.assign("editor.save", c("⌘S")).get()
        #expect(done.tookFrom == "conversation.new")
        #expect(done.overrides == ["conversation.new": ""])
        #expect(map.isDefault("editor.save") == false)
        #expect(plain.isDefault("editor.save"))
    }

    /// A default that an earlier command's stored chord already holds is not in force: the row
    /// shows none and says why, rather than a second, dead ⌘S.
    @Test func shadowedDefaultHasNoChordAndSaysWhy() {
        let map = Keymap(overrides: ["conversation.new": "⌘S"])
        #expect(map.chord("editor.save") == nil)
        #expect(map.problem("editor.save")?.contains("New Conversation") == true)
        #expect(map.isDefault("editor.save") == false)
        #expect(map.resolve(c("⌘S"), paneKind: nil) == ["conversation.new"])
        #expect(map.menuHolder(of: c("⌘S")) == "conversation.new")
        // Shadowed by a later command's stored chord: Save is earlier, so Open… loses ⌘P.
        let open = Keymap(overrides: ["editor.save": "⌘P"])
        #expect(open.chord("window.open") == nil)
        #expect(open.problem("window.open")?.contains("Save") == true)
    }

    @Test func unknownIdsSurviveAssign() throws {
        let map = Keymap(overrides: ["future.cmd": "⌃⌘J"])
        #expect(try map.assign("editor.save", c("⌃⌘K")).get().overrides["future.cmd"] == "⌃⌘J")
        #expect(try map.assign("editor.save", nil).get().overrides["future.cmd"] == "⌃⌘J")
        #expect(try map.assign("editor.save", c("⌘S")).get().overrides["future.cmd"] == "⌃⌘J")
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

    /// Restore All's map: every known command back to its default, ids this build doesn't know kept.
    @Test func restoringAllKeepsOnlyUnknownIds() {
        let map = Keymap(overrides: ["editor.save": "⌃⌘J", "window.open": "", "future.thing": "⌃⌘K"])
        #expect(map.restoringAll() == ["future.thing": "⌃⌘K"])
        #expect(plain.restoringAll() == [:])
    }

    /// The Fixed rows are searched by the same rule as the commands: title or chord, either case.
    @Test func fixedMatchingFindsByTitleOrChord() {
        #expect(FixedKey.matching("push").map(\.title) == ["Push to talk"])
        #expect(FixedKey.matching("⌘c").map(\.title) == ["Copy row", "Copy"])
        #expect(FixedKey.matching(" ").count == FixedKey.all.count)
        #expect(FixedKey.matching("⌃⌘J").isEmpty)
    }
}
