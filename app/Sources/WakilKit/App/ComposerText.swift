import Foundation

/// Where spoken words go when ⌥ is released: into the draft at the caret,
/// unsent, with a space either side where the neighbours are not already
/// whitespace, and nothing replaced (interaction rule 7).
public enum ComposerText {
    /// `caret` is a UTF-16 offset — what `NSTextView.selectedRange` reports.
    public static func insert(_ spoken: String, into draft: String, at caret: Int) -> (draft: String, caret: Int) {
        let text = draft as NSString
        let at = boundary(in: draft, at: caret)
        let before = text.substring(to: at)
        let after = text.substring(from: at)
        let padLeft = !before.isEmpty && !(before.last?.isWhitespace ?? true)
        let padRight = !after.isEmpty && !(after.first?.isWhitespace ?? true)
        let inserted = (padLeft ? " " : "") + spoken + (padRight ? " " : "")
        let lead = (padLeft ? " " : "") + spoken
        let caretAfter = (before as NSString).length + (lead as NSString).length
        return (before + inserted + after, caretAfter)
    }

    /// The draft either side of where `spoken` would land, as `insert` would pad it, so the bar can
    /// draw the line it will be while ⌥ is held: the draft stays in view and the words grow in place
    /// (3a-ii walk: a second hold hid what the first had landed, and the operator said it again).
    /// Nothing heard yet: the draft, split at the caret, unpadded.
    public static func around(_ spoken: String, in draft: String, at caret: Int) -> (before: String, after: String) {
        guard !spoken.isEmpty else {
            let text = draft as NSString
            let at = boundary(in: draft, at: caret)
            return (text.substring(to: at), text.substring(from: at))
        }
        let landed = insert(spoken, into: draft, at: caret)
        let text = landed.draft as NSString
        let start = landed.caret - (spoken as NSString).length
        return (text.substring(to: start), text.substring(from: landed.caret))
    }

    /// `caret`, clamped to the draft and moved back to the start of the grapheme it falls inside
    /// (surrogate pair, CRLF, base + combining mark). Walks Swift Characters: NSString's
    /// composed-sequence API does not join CRLF.
    private static func boundary(in draft: String, at caret: Int) -> Int {
        let at = max(0, min(caret, (draft as NSString).length))
        var boundary = 0
        for ch in draft {
            let next = boundary + ch.utf16.count
            if next > at { break }
            boundary = next
        }
        return boundary
    }
}

/// What the composer bar draws (prototype variant A).
public enum ComposerBarContent: Sendable, Equatable {
    case draft(hint: String)
    /// The words heard so far, drawn in the draft where they will land: `before` and `after` are
    /// the draft either side of them (`ComposerText.around`).
    case hearing(before: String, settled: String, volatile: String, after: String, hint: String)
    /// A sentence in place of the words; `draft` is what the line already holds, still drawn.
    case notice(String, draft: String, hint: String)

    /// The idle hint, naming the chords in force: Open… and Run a Command… as the operator has
    /// them now (Decision 50). A command with no chord drops out rather than naming a key that
    /// does nothing. ⌥ is the dictation key and is not rebindable.
    public static func keysHint(_ keymap: Keymap) -> String {
        var parts = [homeKeysHint]
        if let open = keymap.chord("window.open") { parts.append("\(open.text) open") }
        if let actions = keymap.chord("window.commands") { parts.append("\(actions.text) actions") }
        return parts.joined(separator: " · ")
    }
    /// The keys hint on the home (workspaces, amendment 2026-10-30): only ⌥ to speak.
    public static let homeKeysHint = "Hold ⌥ to speak"

    /// `hint` as the home's composer draws it: the keys hint, whatever chords it names, shortened
    /// to ⌥ alone; any other as it is.
    public static func onHome(_ hint: String) -> String {
        hint.hasPrefix(homeKeysHint) ? homeKeysHint : hint
    }
    public static let landedHint = "heard · Return sends · edit first"
    public static let releaseHint = "release to put it in the line"

    /// `draft` and `caret` are the line's: a hold draws over the field, and must keep what it holds
    /// in view.
    public static func make(machine: ListeningMachine, landedUnsent: Bool,
                            draft: String = "", caret: Int = 0,
                            keymap: Keymap = Keymap(overrides: [:])) -> ComposerBarContent {
        let keysHint = keysHint(keymap)
        guard machine.isListening else {
            if let standing = machine.standingNotice {
                return .notice(sentence(for: standing), draft: draft, hint: keysHint)
            }
            return .draft(hint: landedUnsent ? landedHint : keysHint)
        }
        if let notice = machine.notice { return .notice(sentence(for: notice), draft: draft, hint: releaseHint) }
        let around = ComposerText.around(machine.heard, in: draft, at: caret)
        return .hearing(before: around.before, settled: machine.settled, volatile: machine.volatile,
                        after: around.after, hint: releaseHint)
    }

    public static func sentence(for notice: ListeningMachine.Notice) -> String {
        switch notice {
        case .heardNothing(let device):
            return "Hearing nothing from \(device)"
        case .denied:
            return "Wakil can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone"
        case .permissionPending:
            return "Allow Wakil to use the microphone in the macOS prompt, then hold ⌥ again"
        case .downloading(let fraction, let total):
            let percent = Int((fraction * 100).rounded())
            guard total > 0 else { return "Downloading the English speech model — \(percent)% · Esc cancels" }
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "Downloading the English speech model — \(percent)% of \(size) · Esc cancels"
        }
    }
}
