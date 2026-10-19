import Foundation

/// One schema table with its column names, regrouped from the flat identifier list.
public struct GhostTable: Sendable, Equatable {
    public let name: String
    public let columns: [String]

    public init(name: String, columns: [String]) {
        self.name = name
        self.columns = columns
    }
}

/// Which schema tables the file in front of the caret talks about, and how they travel to the model.
public enum GhostSchema {
    /// A `.table` or `.collection` opens a table; the `.column`s after it join it.
    public static func tables(from names: [Identifier]) -> [GhostTable] {
        var out: [GhostTable] = []
        var name: String?
        var columns: [String] = []
        func flush() {
            if let name { out.append(GhostTable(name: name, columns: columns)) }
        }
        for id in names where id.source == .schema {
            switch id.kind {
            case .table, .collection:
                flush()
                name = id.text
                columns = []
            case .column:
                if name != nil { columns.append(id.text) }
            default:
                break
            }
        }
        flush()
        return out
    }

    /// Tables the text names, in schema order: singular or plural, snake (`booking_item`) or camel (`BookingItem`).
    public static func matching(_ tables: [GhostTable], in text: String, limit: Int = 5) -> [GhostTable] {
        // Every spelling a table can take: plural, each singular, and each with the underscores dropped (camel).
        func forms(_ table: GhostTable) -> Set<String> {
            let plural = table.name.lowercased()
            var out: Set<String> = [plural, plural.replacingOccurrences(of: "_", with: "")]
            for singular in singularForms(plural) {
                out.insert(singular)
                out.insert(singular.replacingOccurrences(of: "_", with: ""))
            }
            return out
        }
        let known = tables.reduce(into: Set<String>()) { $0.formUnion(forms($1)) }
        // The longest run of leading parts that names a table wins and the rest is a trailing part
        // (`booking_item_id` -> booking_item); with no such prefix every part counts as a word (`guest_id`).
        var seen = Set<String>()
        for run in splitRuns(text, keepUnderscore: true) {
            let parts = camelParts(run).map { $0.lowercased() }
            guard !parts.isEmpty else { continue }
            let hit = stride(from: parts.count, through: 1, by: -1).lazy
                .map { Array(parts.prefix($0)) }
                .first { known.contains($0.joined(separator: "_")) || known.contains($0.joined()) }
            if let hit {
                seen.insert(hit.joined(separator: "_"))
                seen.insert(hit.joined())
            } else {
                seen.insert(run.lowercased())
                seen.insert(parts.joined())
                seen.formUnion(parts)
            }
        }
        var found: [GhostTable] = []
        for table in tables {
            let hit = !forms(table).isDisjoint(with: seen)
            if hit {
                found.append(table)
                if found.count == limit { break }
            }
        }
        return found
    }

    public static func extra(_ tables: [GhostTable]) -> QuickExtra? {
        if tables.isEmpty { return nil }
        let text = tables.map { "CREATE TABLE \($0.name) (\($0.columns.joined(separator: ", ")));\n" }.joined()
        return QuickExtra(name: "schema.sql", text: text)
    }

    /// Runs of letters and digits; `_` joins a run only when `keepUnderscore`.
    private static func splitRuns(_ text: String, keepUnderscore: Bool) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || (keepUnderscore && $0 == "_")) }).map(String.init)
    }

    /// `BookingItem` -> booking, item; `HTTPServer` -> HTTP, Server; `guest_id` -> guest, id.
    private static func camelParts(_ run: String) -> [String] {
        var parts: [String] = []
        var current: [Character] = []
        let chars = Array(run)
        for (i, ch) in chars.enumerated() {
            if ch == "_" {
                if !current.isEmpty { parts.append(String(current)); current = [] }
                continue
            }
            if ch.isUppercase, let prev = current.last {
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    parts.append(String(current)); current = []
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(String(current)) }
        return parts
    }

    /// Candidate singulars; "-ses" is ambiguous (`statuses` -> status, `databases` -> database), so it gives both.
    private static func singularForms(_ n: String) -> [String] {
        if n.hasSuffix("ies"), n.count > 3 { return [String(n.dropLast(3)) + "y"] }
        if n.hasSuffix("sses") || n.hasSuffix("xes") || n.hasSuffix("ches") || n.hasSuffix("shes") { return [String(n.dropLast(2))] }
        if n.hasSuffix("ses") { return [String(n.dropLast(2)), String(n.dropLast())] }
        if n.hasSuffix("s"), !n.hasSuffix("ss"), n.count > 1 { return [String(n.dropLast())] }
        return [n]
    }
}

private let prefixWindow = 6_000
private let suffixWindow = 2_000
private let multilineMaxLines = 6

/// Builds the infill request for a caret: windows cut at line boundaries, the schema tables the file names, and
/// whether the caret sits on an empty line (so the model may write several lines).
public func ghostRequest(text: String, caret: String.Index, path: String, language: String, schema: [GhostTable]) -> InfillRequest {
    var prefix = String(text[..<caret])
    if prefix.count > prefixWindow {
        let window = prefix.suffix(prefixWindow)
        let startsLine = prefix[prefix.index(prefix.endIndex, offsetBy: -prefixWindow - 1)].isNewline
        prefix = startsLine ? String(window)
            : window.firstIndex(where: \.isNewline).map { String(window[window.index(after: $0)...]) } ?? String(window)
    }
    var suffix = String(text[caret...])
    if suffix.count > suffixWindow {
        let window = suffix.prefix(suffixWindow)
        let endsLine = suffix[suffix.index(suffix.startIndex, offsetBy: suffixWindow)].isNewline
        suffix = endsLine ? String(window)
            : window.lastIndex(where: \.isNewline).map { String(window[..<$0]) } ?? String(window)
    }
    let lineBefore = text[..<caret].reversed().prefix(while: { !$0.isNewline })
    let lineAfter = text[caret...].prefix(while: { !$0.isNewline })
    let multiline = lineBefore.allSatisfy(\.isWhitespace) && lineAfter.allSatisfy(\.isWhitespace)
    let extras = [GhostSchema.extra(GhostSchema.matching(schema, in: prefix + suffix))].compactMap { $0 }
    return InfillRequest(prefix: prefix, suffix: suffix, path: path, language: language, extras: extras, multiline: multiline)
}

/// Trims what the model echoed from the suffix, trailing whitespace, and anything past the line allowance.
public func ghostClean(_ reply: String, suffix: String, multiline: Bool) -> String {
    var text = reply
    while let last = text.last, last.isWhitespace { text.removeLast() }
    let limit = min(text.count, suffix.count)
    if limit > 0 {
        for n in stride(from: limit, through: 1, by: -1) where text.hasSuffix(suffix.prefix(n)) {
            text = String(text.dropLast(n))
            break
        }
    }
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
        var l = Substring(line)
        while let last = l.last, last.isWhitespace { l = l.dropLast() }
        return String(l)
    }
    while let first = lines.first, first.isEmpty { lines.removeFirst() }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    lines = Array(lines.prefix(multiline ? multilineMaxLines : 1))
    let out = lines.joined(separator: "\n")
    return out.allSatisfy(\.isWhitespace) ? "" : out
}

/// One ghost-text conversation: each request supersedes the last, waits out the debounce, asks, and answers only
/// if nothing newer arrived. A superseded caller is released at once, even while its model call is still running.
public actor GhostTextSession {
    private let suggest: @Sendable (InfillRequest) async throws -> String
    private let debounce: @Sendable () async -> Duration
    private var generation = 0
    private var held: Task<Void, Never>?
    private var waiter: CheckedContinuation<String?, Never>?

    public init(suggest: @escaping @Sendable (InfillRequest) async throws -> String,
                debounce: @escaping @Sendable () async -> Duration) {
        self.suggest = suggest
        self.debounce = debounce
    }

    /// Cancels whatever is in flight; waits the debounce; asks; returns the cleaned suggestion, or nil if superseded, empty or failed.
    public func request(_ r: InfillRequest) async -> String? {
        supersede()
        let mine = generation
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            waiter = cont
            held = Task { await self.run(r, generation: mine) }
        }
    }

    public func cancel() { supersede() }

    private func supersede() {
        generation += 1
        held?.cancel()
        held = nil
        waiter?.resume(returning: nil)
        waiter = nil
    }

    private func run(_ r: InfillRequest, generation mine: Int) async {
        let wait = await debounce()
        if mine != generation { return }
        if wait > .zero {
            try? await Task.sleep(for: wait)
            if mine != generation { return }
        }
        let reply = try? await suggest(r)
        guard mine == generation, let waiter else { return }
        self.waiter = nil
        held = nil
        let clean = reply.map { ghostClean($0, suffix: r.suffix, multiline: r.multiline) } ?? ""
        waiter.resume(returning: clean.isEmpty ? nil : clean)
    }
}
