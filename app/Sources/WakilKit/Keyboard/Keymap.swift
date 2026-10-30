/// A chord `assign` will not take. The message is the sentence the UI shows.
public struct KeymapRefusal: Error, Equatable, Sendable {
    public let message: String
}

/// The keymap in force: each command's default, changed by the `"keys"` overrides in
/// `settings.json`. A stored chord that is refused (Decision 50) or collides with an earlier
/// command's chord in the same place is ignored, and `problem` says why. So is a default another
/// command's chord already holds there: that command keeps it, and this one has none. Pure value;
/// no I/O.
public struct Keymap: Sendable, Equatable {
    public struct Assignment: Equatable, Sendable {
        public let overrides: [String: String]
        /// The id that held the chord and lost it, if any.
        public let tookFrom: String?
    }

    /// The raw map as stored, unknown ids included.
    public let overrides: [String: String]
    private var chords: [String: KeyChord] = [:]
    private var problems: [String: String] = [:]
    private var inForce: [KeyPlace: [KeyChord: String]] = [:]

    public init(overrides: [String: String]) {
        self.overrides = overrides
        for command in KeyCommand.all {
            var chord: KeyChord? = command.defaultChord
            if let stored = overrides[command.id] {
                if stored.isEmpty {
                    chord = nil
                } else if let parsed = KeyChord(stored) {
                    if parsed.isRefused {
                        problems[command.id] = "\(stored) was ignored. \(KeyChord.refusedReason)"
                    } else if let winner = inForce[command.place]?[parsed] {
                        problems[command.id] = "\(parsed.text) was ignored: \(Self.title(winner)) has it."
                    } else {
                        chord = parsed
                    }
                } else {
                    problems[command.id] = "\(stored) is not a shortcut, so it was ignored."
                }
            }
            guard let chord else { continue }
            if let winner = inForce[command.place]?[chord] {
                let shadowed = "Its default, \(chord.text), is \(Self.title(winner))'s, so it has none."
                problems[command.id] = problems[command.id].map { "\($0) \(shadowed)" } ?? shadowed
                continue
            }
            chords[command.id] = chord
            inForce[command.place, default: [:]][chord] = command.id
        }
    }

    private static func title(_ id: String) -> String { KeyCommand.byID[id]?.title ?? id }

    /// The chord a command has now; nil means none.
    public func chord(_ id: String) -> KeyChord? { chords[id] }

    public func isDefault(_ id: String) -> Bool {
        guard let command = KeyCommand.byID[id] else { return false }
        return chords[id] == command.defaultChord && problems[id] == nil
    }

    /// Why a stored chord for this command was ignored, if it was.
    public func problem(_ id: String) -> String? { problems[id] }

    /// The commands a press runs, the focused pane kind's first, then the anywhere ones.
    /// A chord shadowed by an earlier command in the same place is not in force.
    public func resolve(_ chord: KeyChord, paneKind: String?) -> [String] {
        var places: [KeyPlace] = []
        if let paneKind { places.append(.pane(paneKind)) }
        places.append(.anywhere)
        return places.compactMap { inForce[$0]?[chord] }
    }

    /// Whether a press of `chord` belongs to Wakil: some command holds it in the focused pane's
    /// kind or anywhere. A key no command holds stays with whatever has the keyboard.
    public func claims(_ chord: KeyChord, paneKind: String?) -> Bool {
        !resolve(chord, paneKind: paneKind).isEmpty
    }

    /// The commands that are always Wakil's, even in a focused web page: their chords in force are
    /// offered to the menu bar before the page sees them, so ⌘K opens the palette on a page that
    /// listens for ⌘K. Every other chord is the page's first, as Safari does it, so ⌘F or ⌘B
    /// still reach a web app that handles them.
    public static let beforePage: Set<String> = {
        var ids: Set<String> = [
            "window.commands", "window.open", "conversation.new", "conversation.close", "window.home",
            "editor.newScratch", "browser.newTab", "pane.close", "browser.closeTab",
            "browser.focusAddress", "window.settings", "browser.bookmark", "browser.copyURL",
            "window.toggleRail", "browser.lastTab", "browser.toggleTabColumn",
        ]
        for n in 1...8 { ids.insert("browser.tab\(n)") }
        return ids
    }()

    /// Whether a focused web page's press of `chord` goes to the menu bar first: some `beforePage`
    /// command holds it in a browser pane. Toggle Tab Column counts only with the tabs vertical
    /// (`tabColumn`); with them horizontal it does nothing there, so the page keeps the chord.
    public func takesBeforePage(_ chord: KeyChord, tabColumn: Bool) -> Bool {
        resolve(chord, paneKind: "browser").contains { id in
            Self.beforePage.contains(id) && (id != "browser.toggleTabColumn" || tabColumn)
        }
    }

    /// The command whose menu item carries `chord` as its shortcut, since SwiftUI gives a chord to
    /// one menu item only: the one in force anywhere, else the first in table order in force in
    /// its pane. Nil when no command holds it.
    public func menuHolder(of chord: KeyChord) -> String? {
        if let id = inForce[.anywhere]?[chord] { return id }
        return KeyCommand.all.first { inForce[$0.place]?[chord] == $0.id }?.id
    }

    /// The overrides after giving `chord` (nil clears) to `id`. A command in the same place that
    /// held the chord loses it. The map stays minimal: entries equal to a default are dropped.
    public func assign(_ id: String, _ chord: KeyChord?) -> Result<Assignment, KeymapRefusal> {
        guard let command = KeyCommand.byID[id] else {
            return .failure(KeymapRefusal(message: "\(id) is not a command this build knows."))
        }
        var next = overrides
        guard let chord else {
            next[id] = ""
            return .success(Assignment(overrides: next, tookFrom: nil))
        }
        if chord.isRefused { return .failure(KeymapRefusal(message: KeyChord.refusedReason)) }
        var tookFrom: String?
        if let holder = inForce[command.place]?[chord], holder != id {
            next[holder] = ""
            tookFrom = holder
        }
        if chord == command.defaultChord { next[id] = nil } else { next[id] = chord.text }
        return .success(Assignment(overrides: next, tookFrom: tookFrom))
    }

    /// Restore All's map: every command this build knows back to its default. Ids it doesn't know
    /// are kept, so an older build can't wipe a newer one's binding.
    public func restoringAll() -> [String: String] {
        overrides.filter { KeyCommand.byID[$0.key] == nil }
    }
}
