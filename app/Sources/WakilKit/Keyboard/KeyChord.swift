import AppKit

/// One keyboard shortcut: modifiers plus a key. Its text form (`⌃⌘R`, `⌘↩`, `⌃⇧Tab`, `F5`) is
/// what `settings.json` stores; the Go side accepts exactly this vocabulary.
public struct KeyChord: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public enum KeyName: Hashable, Sendable {
        /// A single printing character, lowercased.
        case character(Character)
        case returnKey, tab, space, escape, delete, up, down, left, right
        case function(Int)
    }

    public var modifiers: Modifiers
    public var key: KeyName

    public init(modifiers: Modifiers, key: KeyName) {
        self.modifiers = modifiers
        self.key = key.normalized
    }

    /// Decision 50's sentence, for the row that shows a refused chord.
    public static let refusedReason =
        "Decision 50: a shortcut needs ⌘ or ⌃ (F-keys excepted), and may not be one of the system's or the editing chords."

    // MARK: Text

    /// Modifier glyphs in macOS print order.
    private static let modifierGlyphs: [(Modifiers, Character)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    private static let namedKeys: [(KeyName, String)] = [
        (.returnKey, "↩"), (.tab, "Tab"), (.space, "Space"), (.escape, "Esc"), (.delete, "⌫"),
        (.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→"),
    ]

    public init?(_ text: String) {
        var modifiers: Modifiers = []
        var rest = Substring(text)
        while let first = rest.first, let glyph = Self.modifierGlyphs.first(where: { $0.1 == first }) {
            guard !modifiers.contains(glyph.0) else { return nil }
            modifiers.insert(glyph.0)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        if let named = Self.namedKeys.first(where: { $0.1 == rest }) {
            self.init(modifiers: modifiers, key: named.0)
        } else if rest.count == 1, let c = rest.first, !Self.modifierGlyphs.contains(where: { $0.1 == c }) {
            self.init(modifiers: modifiers, key: .character(c))
        } else if rest.first == "F", let n = Int(rest.dropFirst()), (1...19).contains(n),
                  rest.dropFirst().allSatisfy(\.isASCII), !rest.dropFirst().hasPrefix("0") {
            self.init(modifiers: modifiers, key: .function(n))
        } else {
            return nil
        }
    }

    public var text: String {
        var out = ""
        for (flag, glyph) in Self.modifierGlyphs where modifiers.contains(flag) { out.append(glyph) }
        switch key {
        case .character(let c): out += String(c).uppercased()
        case .function(let n): out += "F\(n)"
        default: out += Self.namedKeys.first(where: { $0.0 == key })?.1 ?? ""
        }
        return out
    }

    // MARK: Events

    /// The chord an event is: the key by its ANSI key code first, so ⌘R is ⌘R on every layout
    /// (as `QueryLineKeys` does), then by character for keys the table doesn't hold.
    /// Nil for anything but a key event: AppKit raises on a mouse event's key code.
    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if let key = Self.keysByCode[event.keyCode] {
            self.init(modifiers: modifiers, key: key)
        } else if let c = event.charactersIgnoringModifiers, c.count == 1, let ch = c.first,
                  !ch.isWhitespace, !ch.isNewline, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) {
            self.init(modifiers: modifiers, key: .character(ch))
        } else {
            return nil
        }
    }

    private static let keysByCode: [UInt16: KeyName] = {
        var table: [UInt16: KeyName] = [
            36: .returnKey, 48: .tab, 49: .space, 51: .delete, 53: .escape,
            123: .left, 124: .right, 125: .down, 126: .up,
        ]
        let ansi: [(UInt16, Character)] = [
            (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"),
            (9, "v"), (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"),
            (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"),
            (26, "7"), (27, "-"), (28, "8"), (29, "0"), (30, "]"), (31, "o"), (32, "u"), (33, "["),
            (34, "i"), (35, "p"), (37, "l"), (38, "j"), (39, "'"), (40, "k"), (41, ";"), (42, "\\"),
            (43, ","), (44, "/"), (45, "n"), (46, "m"), (47, "."), (50, "`"),
        ]
        for (code, c) in ansi { table[code] = .character(c) }
        let fKeys: [(UInt16, Int)] = [
            (122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8), (101, 9),
            (109, 10), (103, 11), (111, 12), (105, 13), (107, 14), (113, 15), (106, 16), (64, 17),
            (79, 18), (80, 19),
        ]
        for (code, n) in fKeys { table[code] = .function(n) }
        return table
    }()

    // MARK: Decision 50

    private static let refusedChords: Set<KeyChord> = Set(
        ["⌘Q", "⌘H", "⌥⌘H", "⌘M", "⌘Tab", "⌘`", "⌘Space", "⌃Space", "⌘C", "⌘V", "⌘X", "⌘Z", "⇧⌘Z", "⌘A"]
            .compactMap { KeyChord($0) })

    /// True for a chord Decision 50 does not allow: no ⌘ or ⌃ (unless an F-key), or one of the
    /// system's or the editing chords.
    public var isRefused: Bool {
        if case .function = key {} else if modifiers.isDisjoint(with: [.command, .control]) { return true }
        return Self.refusedChords.contains(self)
    }
}

private extension KeyChord.KeyName {
    var normalized: KeyChord.KeyName {
        if case .character(let c) = self { return .character(Character(c.lowercased())) }
        return self
    }
}
