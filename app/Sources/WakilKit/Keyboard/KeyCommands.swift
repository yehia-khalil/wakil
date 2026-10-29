import Foundation

/// Where a command's chord is live: in every pane, or only while a pane of one kind has focus.
/// The pane kind is the string `layoutSnapshot.panes[].kind` holds (`"browser"`).
public enum KeyPlace: Hashable, Sendable {
    case anywhere
    case pane(String)

    /// The words Settings → Keyboard puts after a command's chord.
    public var placeTitle: String {
        switch self {
        case .anywhere: return "anywhere"
        case .pane("browser"): return "in a browser pane"
        case .pane(let kind): return "in a \(kind) pane"
        }
    }
}

/// The menu group a command sits under, in display order.
public enum KeyGroup: CaseIterable, Sendable {
    case conversation, pane, editor, window, browser

    public var title: String {
        switch self {
        case .conversation: return "Conversation"
        case .pane: return "Pane"
        case .editor: return "Editor"
        case .window: return "Window"
        case .browser: return "Browser"
        }
    }
}

/// One rebindable command: its id (the key in `settings.json`), its default chord, and where it is live.
public struct KeyCommand: Sendable {
    public let id: String
    public let title: String
    public let group: KeyGroup
    public let place: KeyPlace
    public let defaultChord: KeyChord

    private init(_ id: String, _ title: String, _ group: KeyGroup, _ place: KeyPlace, _ chord: String) {
        guard let parsed = KeyChord(chord) else { preconditionFailure("bad default chord \(chord) for \(id)") }
        self.id = id
        self.title = title
        self.group = group
        self.place = place
        self.defaultChord = parsed
    }

    /// Table order is the tie-break when two stored chords collide: the first one wins.
    public static let all: [KeyCommand] = {
        let a = KeyPlace.anywhere, b = KeyPlace.pane("browser")
        var rows: [KeyCommand] = [
            KeyCommand("conversation.new", "New Conversation", .conversation, a, "⌘N"),
            KeyCommand("conversation.close", "Close Conversation", .conversation, a, "⇧⌘W"),
            KeyCommand("pane.maximize", "Maximize Pane", .pane, a, "⌘↩"),
            KeyCommand("pane.close", "Close Pane", .pane, a, "⌘W"),
            KeyCommand("pane.toggleDensity", "Toggle Density", .pane, a, "⇧⌘D"),
            KeyCommand("editor.newScratch", "New Scratch Tab", .editor, a, "⌘T"),
            KeyCommand("editor.showFiles", "Show Files", .editor, a, "⌘B"),
            KeyCommand("editor.searchFiles", "Search Files", .editor, a, "⇧⌘F"),
            KeyCommand("editor.showChanges", "Show Changes", .editor, a, "⇧⌘G"),
            KeyCommand("editor.save", "Save", .editor, a, "⌘S"),
            KeyCommand("window.organisation", "Organisation…", .window, a, "⇧⌘O"),
            KeyCommand("window.open", "Open…", .window, a, "⌘P"),
            KeyCommand("window.commands", "Run a Command…", .window, a, "⌘K"),
            KeyCommand("window.settings", "Settings…", .window, a, "⌘,"),
            KeyCommand("window.toggleRail", "Toggle Rail", .window, a, "⌃⌘R"),
            KeyCommand("browser.newTab", "New Tab", .browser, b, "⌘T"),
            KeyCommand("browser.closeTab", "Close Tab", .browser, b, "⌘W"),
            KeyCommand("browser.findPrevious", "Find Previous", .browser, b, "⇧⌘G"),
            KeyCommand("browser.reopenTab", "Reopen Closed Tab", .browser, b, "⇧⌘T"),
            KeyCommand("browser.focusAddress", "Open Location", .browser, b, "⌘L"),
            KeyCommand("browser.reload", "Reload Page", .browser, b, "⌘R"),
            KeyCommand("browser.back", "Back", .browser, b, "⌘["),
            KeyCommand("browser.forward", "Forward", .browser, b, "⌘]"),
            KeyCommand("browser.bookmark", "Add Bookmark", .browser, b, "⌘D"),
            KeyCommand("browser.copyURL", "Copy Page Address", .browser, b, "⇧⌘C"),
            KeyCommand("browser.find", "Find…", .browser, b, "⌘F"),
            KeyCommand("browser.findNext", "Find Next", .browser, b, "⌘G"),
            KeyCommand("browser.zoomIn", "Zoom In", .browser, b, "⌘="),
            KeyCommand("browser.zoomOut", "Zoom Out", .browser, b, "⌘-"),
            KeyCommand("browser.zoomReset", "Actual Size", .browser, b, "⌘0"),
            KeyCommand("browser.showNextTab", "Show Next Tab", .browser, b, "⌃Tab"),
            KeyCommand("browser.showPreviousTab", "Show Previous Tab", .browser, b, "⌃⇧Tab"),
            KeyCommand("browser.nextTab", "Next Tab", .browser, b, "⇧⌘]"),
            KeyCommand("browser.previousTab", "Previous Tab", .browser, b, "⇧⌘["),
        ]
        for n in 1...8 {
            rows.append(KeyCommand("browser.tab\(n)", "Tab \(n)", .browser, b, "⌘\(n)"))
        }
        rows.append(KeyCommand("browser.lastTab", "Last Tab", .browser, b, "⌘9"))
        rows.append(KeyCommand("browser.toggleTabColumn", "Toggle Tab Column", .browser, b, "⌃⌘S"))
        return rows
    }()

    static let byID: [String: KeyCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Settings → Keyboard's search: the commands whose title or chord in force contains `query`,
    /// ignoring case, in table order. A blank query matches every command.
    public static func matching(_ query: String, keymap: Keymap) -> [KeyCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { command in
            command.title.localizedCaseInsensitiveContains(needle)
                || keymap.chord(command.id)?.text.localizedCaseInsensitiveContains(needle) == true
        }
    }
}

/// A key that works a fixed way and cannot be rebound; Settings → Keyboard lists them read-only.
public struct FixedKey: Sendable {
    public let title: String
    public let place: String
    public let chord: String

    public static let all: [FixedKey] = [
        FixedKey(title: "Push to talk", place: "anywhere", chord: "⌥ held"),
        FixedKey(title: "Copy row", place: "in a db grid", chord: "⌘C"),
        FixedKey(title: "Toggle row detail", place: "in a db grid", chord: "Space"),
        FixedKey(title: "Move row", place: "in a db grid", chord: "↑ ↓"),
        FixedKey(title: "Close detail", place: "in a db grid", chord: "Esc"),
        FixedKey(title: "Copy", place: "in a terminal", chord: "⌘C"),
        FixedKey(title: "Select next match", place: "in the editor, when no command has ⌘D", chord: "⌘D"),
        FixedKey(title: "Cancel", place: "in a prompt", chord: "Esc"),
    ]

    /// Settings → Keyboard's search over the fixed keys: `KeyCommand.matching`'s rule, title or chord.
    public static func matching(_ query: String) -> [FixedKey] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.chord.localizedCaseInsensitiveContains(needle)
        }
    }
}
