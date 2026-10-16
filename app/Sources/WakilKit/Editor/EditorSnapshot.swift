import Foundation

/// What a tab holds: a file under one of the project's roots, or a numbered scratch buffer.
public enum EditorTabSubject: Sendable, Equatable, Hashable {
    case file(path: String, root: String)
    case scratch(number: Int)
    /// A Changes diff (3b-iii): `path` relative to `root`, in one group. Read-only, never saved.
    case diff(root: String, path: String, group: GitGroup)
}

public enum EditorDiskState: String, Sendable, Equatable { case inSync, changedOnDisk, deleted }

/// A span between two positions (1-based, UTF-16 columns). `EditorPosition` lives in `Layout/Pane.swift`.
public struct EditorRange: Sendable, Equatable, Codable {
    public var start: EditorPosition
    public var end: EditorPosition
    public init(start: EditorPosition, end: EditorPosition) {
        self.start = start
        self.end = end
    }
}

/// The agent's last edit to a tab, so the renderer can apply it once (by `serial`).
public struct EditorAgentEdit: Sendable, Equatable {
    public var serial: Int
    public var range: EditorRange
    public var text: String
    public init(serial: Int, range: EditorRange, text: String) {
        self.serial = serial
        self.range = range
        self.text = text
    }
}

public struct EditorTab: Sendable, Equatable {
    public var subject: EditorTabSubject
    public var text: String
    /// Last read or written; `dirty` is `text != savedText`.
    public var savedText: String
    public var language: String
    public var diskState: EditorDiskState
    public var mtime: Int64
    public var cursor: EditorPosition
    public var selection: EditorRange?
    /// 1-based lines.
    public var visibleRange: ClosedRange<Int>?
    public var scrollTop: Double
    /// Over cap, binary, not UTF-8, write failure — whole text.
    public var notice: String?
    /// Over cap, binary, not UTF-8.
    public var readOnly: Bool
    public var saving: Bool
    /// Bumps on every text change; the renderer's edit counter.
    public var edits: Int
    public var lastAgentEdit: EditorAgentEdit?
    /// Opened by a single click and replaced by the next one, until pinned.
    public var preview: Bool
    public var dirty: Bool { text != savedText }
    /// A diff tab's two sides; nil for every other tab.
    public var diffState: GitDiffState?

    public init(
        subject: EditorTabSubject, text: String, savedText: String, language: String,
        diskState: EditorDiskState, mtime: Int64, cursor: EditorPosition, selection: EditorRange?,
        visibleRange: ClosedRange<Int>?, scrollTop: Double, notice: String?, readOnly: Bool,
        saving: Bool, edits: Int, lastAgentEdit: EditorAgentEdit?, preview: Bool = false, diffState: GitDiffState? = nil
    ) {
        self.subject = subject
        self.text = text
        self.savedText = savedText
        self.language = language
        self.diskState = diskState
        self.mtime = mtime
        self.cursor = cursor
        self.selection = selection
        self.visibleRange = visibleRange
        self.scrollTop = scrollTop
        self.notice = notice
        self.readOnly = readOnly
        self.saving = saving
        self.edits = edits
        self.lastAgentEdit = lastAgentEdit
        self.preview = preview
        self.diffState = diffState
    }
}

public struct EditorSnapshot: Sendable, Equatable {
    public var tabs: [EditorTab]
    public var active: Int?
    /// The left column (3b-ii); nil until this pane sets one — it then follows the layout's default.
    public var column: EditorColumnState?
    public var search: EditorSearchState
    /// The last find the agent asked for; the renderer opens Monaco's bar once per serial.
    public var find: EditorFindRequest?
    /// What Monaco's find bar last said (a view report, like the cursor).
    public var findReport: EditorFindReport?
    public static let empty = EditorSnapshot(tabs: [], active: nil)
    public init(tabs: [EditorTab], active: Int?, column: EditorColumnState? = nil,
                search: EditorSearchState = .empty, find: EditorFindRequest? = nil,
                findReport: EditorFindReport? = nil) {
        self.tabs = tabs
        self.active = active
        self.column = column
        self.search = search
        self.find = find
        self.findReport = findReport
    }
}

extension EditorTab {
    /// A file tab as just read: clean, in sync, cursor at 1:1.
    public static func file(path: String, root: String, text: String, mtime: Int64, language: String) -> EditorTab {
        EditorTab(subject: .file(path: path, root: root), text: text, savedText: text, language: language,
                  diskState: .inSync, mtime: mtime, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                  visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                  lastAgentEdit: nil)
    }

    /// An empty scratch tab.
    public static func scratch(number: Int, language: String) -> EditorTab {
        EditorTab(subject: .scratch(number: number), text: "", savedText: "", language: language,
                  diskState: .inSync, mtime: 0, cursor: EditorPosition(line: 1, column: 1), selection: nil,
                  visibleRange: nil, scrollTop: 0, notice: nil, readOnly: false, saving: false, edits: 0,
                  lastAgentEdit: nil)
    }

    /// A diff tab, its two sides loading. Read-only and never dirty: its text is not a buffer.
    public static func diff(root: String, path: String, group: GitGroup) -> EditorTab {
        let language = editorLanguage(forPath: path)
        return EditorTab(subject: .diff(root: root, path: path, group: group), text: "", savedText: "",
                         language: language, diskState: .inSync, mtime: 0, cursor: EditorPosition(line: 1, column: 1),
                         selection: nil, visibleRange: nil, scrollTop: 0, notice: nil, readOnly: true, saving: false,
                         edits: 0, lastAgentEdit: nil, diffState: .loading(language))
    }

    public var path: String? { if case .file(let p, _) = subject { p } else { nil } }
    public var isScratch: Bool { if case .scratch = subject { true } else { false } }
}
