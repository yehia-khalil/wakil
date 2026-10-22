import Foundation
import Observation

/// Rule 2's decision for a field saved when it is left: the typed text, when there is some, it
/// differs from what is stored, and no write of it is already in flight (Rule 5). Nil otherwise,
/// so a leave after Return — or a second report of the same leave — writes nothing twice.
public enum LeaveSave {
    public static func value(draft: String?, stored: String, saving: Bool) -> String? {
        guard let draft, draft != stored, !saving else { return nil }
        return draft
    }
}

/// A field edited where it stands and saved when it is left (Rule 2) — Settings' Name fields.
///
/// **Leaving is any route off the field**, and the one a view cannot rely on hearing is the field
/// going from screen: a tree click swaps the page in the same transaction, and SwiftUI reports
/// the focus change to no one because the view that would hear it is gone (2e-ii's first on-screen
/// run). So `disappeared` is a leave too, and a write that lands after it hands its refusal back
/// for the window's status rather than to a field nobody can see (Rule 8).
@MainActor
@Observable
public final class LeaveSavedField {
    /// What was typed, or nil while the field shows what is stored.
    public var draft: String?
    /// The last write's refusal, whole. The draft is kept beside it to be corrected.
    public private(set) var refusal: String?
    /// A write is in flight; a second leave starts none.
    public private(set) var saving = false
    /// Whether the field is on screen to show a refusal.
    public private(set) var onScreen = false

    public init() {}

    public func appeared() { onScreen = true }

    /// The field left the screen. Answers what to write, as `leave` does.
    public func disappeared(stored: String) -> String? {
        onScreen = false
        return leave(stored: stored)
    }

    /// Focus moved on or Return was pressed. Answers the text to write and marks the write in
    /// flight, or nil when there is nothing to write.
    public func leave(stored: String) -> String? {
        guard let value = LeaveSave.value(draft: draft, stored: stored, saving: saving) else { return nil }
        saving = true
        refusal = nil
        return value
    }

    /// The write's answer: nil saved it, a sentence refused it. Answers the refusal again when
    /// the field is no longer on screen, for the caller to say in the window's status.
    public func landed(_ refusal: String?) -> String? {
        saving = false
        self.refusal = refusal
        if refusal == nil { draft = nil }
        return onScreen ? nil : refusal
    }
}
