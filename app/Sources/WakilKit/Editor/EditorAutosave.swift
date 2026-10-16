import Foundation

/// Whether autosave may write `tab` (3b-v): a file, dirty, in sync with disk, writable, and not
/// already saving. A tab marked changed on disk or deleted is the operator's to resolve —
/// autosave would overwrite the disk or recreate the file without them choosing to (3b-i's
/// Reload, Compare and ⌘S stay theirs).
public func editorAutosaveEligible(_ tab: EditorTab) -> Bool {
    !tab.isScratch && tab.dirty && tab.diskState == .inSync && !tab.readOnly && !tab.saving
}

/// What one look at a pane asks autosave to do, by path.
public struct EditorAutosaveStep: Sendable, Equatable {
    /// Tabs edited since the last look, in `pause` mode: their timers (re)start.
    public var arm: [String]
    /// Tabs to save now: in `focus` mode, the dirty tab the pane switched away from.
    public var saveNow: [String]
    public init(arm: [String], saveNow: [String]) {
        self.arm = arm
        self.saveNow = saveNow
    }
}

/// Autosave's memory (3b-v): per pane, each file tab's edit counter and the active tab, so a new
/// look at a snapshot can say what changed. It decides; the window keeps the timers and saves.
/// An edit is any change to a tab's `edits` counter — the operator's typing and the agent's
/// edits alike, since both bump it.
public struct EditorAutosave: Sendable {
    private var edits: [String: [String: Int]] = [:]
    private var active: [String: String] = [:]

    public init() {}

    /// Arming is on any edit to a writable file tab (even one saving or changed on disk): whether
    /// the tab may be written is decided when the timer fires, so an edit made during a save is
    /// not left unsaved until the next one. A timer that fires while a save is in flight in its
    /// pane waits for that save to end and then decides (`WindowModel.autosave`): the tab is
    /// written if it is still eligible, and nothing is written if that save was cancelled.
    /// Tab-switch saves stay on full eligibility.
    public mutating func observe(pane: String, snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> EditorAutosaveStep {
        var step = EditorAutosaveStep(arm: [], saveNow: [])
        let seen = edits[pane]
        var now: [String: Int] = [:]
        for tab in snapshot.tabs {
            guard let path = tab.path else { continue }
            now[path] = tab.edits
            // A tab seen for the first time has nothing to compare with, so it never arms.
            if mode == .pause, !tab.readOnly, let before = seen?[path], before != tab.edits {
                step.arm.append(path)
            }
        }
        let current = snapshot.active.flatMap { snapshot.tabs.indices.contains($0) ? editorTabKey(snapshot.tabs[$0]) : nil }
        if mode == .focus, let previous = active[pane], previous != current,
           let left = snapshot.tabs.first(where: { editorTabKey($0) == previous }),
           editorAutosaveEligible(left), let path = left.path {
            step.saveNow.append(path)
        }
        edits[pane] = now
        active[pane] = current
        return step
    }

    public mutating func forget(pane: String) {
        edits[pane] = nil
        active[pane] = nil
    }

    public mutating func reset() {
        edits = [:]
        active = [:]
    }

    /// The tabs to save when a pane loses focus, or Wakil stops being the active app.
    public static func focusLeft(_ snapshot: EditorSnapshot, mode: EditorAutosaveMode) -> [String] {
        guard mode == .focus else { return [] }
        return snapshot.tabs.filter(editorAutosaveEligible).compactMap(\.path)
    }
}
