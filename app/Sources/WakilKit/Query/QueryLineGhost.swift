import Foundation

/// 3b-viii ghost-text in the DB pane's query line: the keys a ghost changes.
public enum QueryLineKey: Sendable { case tab, escape, returnKey }

/// What a key does in the query line. Only Tab and Esc look at the ghost; Return runs what was typed.
public enum QueryLineGhostKey: Equatable, Sendable { case accept, leaveLine, dismiss, cancelRead, passThrough }

/// Tab accepts the ghost while one shows, and otherwise leaves the line. Esc drops the ghost first,
/// then cancels a running read, then leaves the line. Return never accepts: it is handled as before.
public func queryLineGhostKey(_ key: QueryLineKey, ghostShowing: Bool, readRunning: Bool) -> QueryLineGhostKey {
    switch key {
    case .tab: return ghostShowing ? .accept : .leaveLine
    case .escape: return ghostShowing ? .dismiss : readRunning ? .cancelRead : .leaveLine
    case .returnKey: return .passThrough
    }
}

/// Ruling R2: the line asks for a ghost only with the caret at the end of its line — nothing but
/// whitespace after it up to the next line break. A line with nothing typed yet asks nothing.
public func queryLineAsksForGhost(text: String, caret: String.Index) -> Bool {
    guard text.contains(where: { !$0.isWhitespace }) else { return false }
    let rest = text[caret...]
    let lineRest = rest.prefix { !$0.isNewline }
    return lineRest.allSatisfy(\.isWhitespace)
}

/// Whether `key` drops the ghost and its pending request before it does anything else. Every Esc
/// does — dismissing, cancelling a read or leaving the line — so no suggestion lands after one
/// (Rule 4); Tab does too, accepting or leaving. Return runs what was typed and moves no caret.
public func queryLineKeyDropsGhost(_ key: QueryLineKey) -> Bool {
    key != .returnKey
}

/// Whether a ghost at `caret` may run past its first line: only with nothing but whitespace after
/// the caret in the whole text, so its further lines never draw over real text below.
public func queryLineGhostIsMultiline(text: String, caret: String.Index) -> Bool {
    text[caret...].allSatisfy(\.isWhitespace)
}

/// What of `suggestion` the line shows: its first line alone unless `multiline`, and nil when
/// that leaves nothing.
public func queryLineGhostShown(_ suggestion: String, multiline: Bool) -> String? {
    let shown = multiline ? suggestion : String(suggestion.prefix { !$0.isNewline })
    return shown.isEmpty ? nil : shown
}
