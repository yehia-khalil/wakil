import Foundation
import SQLite3

/// One page the browser showed: its URL, last known title, how many visits finished on it, and
/// when the latest one did.
public struct BrowserHistoryEntry: Sendable, Equatable {
    public var url: String
    public var title: String
    public var count: Int
    public var last: Date

    public init(url: String, title: String, count: Int, last: Date) {
        self.url = url
        self.title = title
        self.count = count
        self.last = last
    }
}

public struct BrowserHistoryError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}

/// One organisation's browsing history: `visits(url PRIMARY KEY, title, count, last)` in a SQLite
/// file, one row per URL, 90 days kept. No connection is held: every call opens the file, works and
/// closes (WAL, 2 s busy timeout), so clearing browsing data deletes the files under no open handle.
/// Only SQL with bound parameters ever runs; typed text is never part of a statement.
public struct BrowserHistory: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// How long a visit is kept; older rows are deleted on every write.
    public static let keep: TimeInterval = 90 * 86_400

    /// Records the page `url` at `at`. Only `http` and `https` pages are recorded. With `newVisit`
    /// the URL's count goes up by one and its title and time are replaced; without, only an
    /// existing row's title changes (a title that arrives after the load is not a second visit).
    /// An empty title never replaces a known one.
    public func record(url page: String, title: String, at: Date, newVisit: Bool) throws {
        guard let scheme = URL(string: page)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try open(create: true)
        defer { sqlite3_close_v2(db) }
        try exec(db, "CREATE TABLE IF NOT EXISTS visits(url TEXT PRIMARY KEY, title TEXT NOT NULL, count INTEGER NOT NULL, last REAL NOT NULL)")
        try run(db, "DELETE FROM visits WHERE last < ?1", [.real(at.timeIntervalSince1970 - Self.keep)])
        if newVisit {
            try run(db, """
                INSERT INTO visits(url, title, count, last) VALUES(?1, ?2, 1, ?3)
                ON CONFLICT(url) DO UPDATE SET
                    title = CASE WHEN excluded.title = '' THEN visits.title ELSE excluded.title END,
                    count = visits.count + 1,
                    last = excluded.last
                """, [.text(page), .text(title), .real(at.timeIntervalSince1970)])
        } else if !title.isEmpty {
            try run(db, "UPDATE visits SET title = ?2 WHERE url = ?1", [.text(page), .text(title)])
        }
    }

    /// Rows where every word occurs in the URL or the title (case-insensitive, `%`, `_` and `\` in a
    /// word are literal), most visited first, then most recent. A missing file reads as no rows.
    public func matching(_ words: [String], limit: Int) throws -> [BrowserHistoryEntry] {
        guard !words.isEmpty, limit > 0, FileManager.default.fileExists(atPath: url.path) else { return [] }
        let db = try open(create: false)
        defer { sqlite3_close_v2(db) }
        var clauses: [String] = []
        var args: [Arg] = []
        for (i, word) in words.enumerated() {
            clauses.append("(url LIKE ?\(i + 1) ESCAPE '\\' OR title LIKE ?\(i + 1) ESCAPE '\\')")
            args.append(.text("%" + Self.escapeLike(word) + "%"))
        }
        let sql = "SELECT url, title, count, last FROM visits WHERE " + clauses.joined(separator: " AND ")
            + " ORDER BY count DESC, last DESC LIMIT ?\(words.count + 1)"
        args.append(.int(limit))
        var rows: [BrowserHistoryEntry] = []
        try query(db, sql, args) { statement in
            rows.append(BrowserHistoryEntry(
                url: String(cString: sqlite3_column_text(statement, 0)),
                title: String(cString: sqlite3_column_text(statement, 1)),
                count: Int(sqlite3_column_int64(statement, 2)),
                last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return rows
    }

    private static func escapeLike(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: SQLite plumbing

    private enum Arg { case text(String), real(Double), int(Int) }

    private func open(create: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            throw BrowserHistoryError(description: "history can't be opened (\(message))")
        }
        sqlite3_busy_timeout(db, 2000)
        do { try exec(db, "PRAGMA journal_mode=WAL") } catch { sqlite3_close_v2(db); throw error }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        // A statement with no parameters; `PRAGMA journal_mode` returns a row, which step() drains.
        try query(db, sql, []) { _ in }
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ args: [Arg]) throws {
        try query(db, sql, args) { _ in }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [Arg],
                       row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BrowserHistoryError(description: "history: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, transient)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .int(let n): sqlite3_bind_int64(statement, index, Int64(n))
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw BrowserHistoryError(description: "history: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }
}
