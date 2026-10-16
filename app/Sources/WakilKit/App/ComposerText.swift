import Foundation

/// Where spoken words go when ⌥ is released: into the draft at the caret,
/// unsent, with a space either side where the neighbours are not already
/// whitespace, and nothing replaced (interaction rule 7).
public enum ComposerText {
    /// `caret` is a UTF-16 offset — what `NSTextView.selectedRange` reports.
    public static func insert(_ spoken: String, into draft: String, at caret: Int) -> (draft: String, caret: Int) {
        let text = draft as NSString
        var at = max(0, min(caret, text.length))
        // Never split a grapheme (surrogate pair, CRLF, base + combining mark).
        // Walk Swift Characters (NSString's composed-sequence API does not join CRLF).
        var boundary = 0
        for ch in draft {
            let next = boundary + ch.utf16.count
            if next > at { break }
            boundary = next
        }
        at = boundary
        let before = text.substring(to: at)
        let after = text.substring(from: at)
        let padLeft = !before.isEmpty && !(before.last?.isWhitespace ?? true)
        let padRight = !after.isEmpty && !(after.first?.isWhitespace ?? true)
        let inserted = (padLeft ? " " : "") + spoken + (padRight ? " " : "")
        let lead = (padLeft ? " " : "") + spoken
        let caretAfter = (before as NSString).length + (lead as NSString).length
        return (before + inserted + after, caretAfter)
    }
}

/// What the composer bar draws (prototype variant A).
public enum ComposerBarContent: Sendable, Equatable {
    case draft(hint: String)
    case hearing(settled: String, volatile: String, hint: String)
    case notice(String, hint: String)

    public static let keysHint = "Hold ⌥ to speak · ⌘P open · ⌘K actions"
    public static let landedHint = "heard · Return sends · edit first"
    public static let releaseHint = "release to put it in the line"

    public static func make(machine: ListeningMachine, landedUnsent: Bool) -> ComposerBarContent {
        guard machine.isListening else {
            if let standing = machine.standingNotice { return .notice(sentence(for: standing), hint: keysHint) }
            return .draft(hint: landedUnsent ? landedHint : keysHint)
        }
        if let notice = machine.notice { return .notice(sentence(for: notice), hint: releaseHint) }
        return .hearing(settled: machine.settled, volatile: machine.volatile, hint: releaseHint)
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
