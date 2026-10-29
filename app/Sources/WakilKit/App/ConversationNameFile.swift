import Foundation

/// A conversation's two names, kept under its lineage root: the one the operator typed and the one the
/// model gave. Either may be absent.
public struct StoredConversationName: Codable, Sendable, Equatable {
    public var `operator`: String?
    public var ai: String?
    public init(operator: String? = nil, ai: String? = nil) {
        self.operator = `operator`; self.ai = ai
    }
}

/// `conversation-names.json` exists but cannot be read; it is never written over.
public struct ConversationNamesUnreadable: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "conversation names: \(path) is unreadable: \(reason)" }
}

/// The organisation has no directory, so there is nowhere to keep names (none is created).
public struct ConversationNamesNoOrganisation: Error, Sendable, Equatable, CustomStringConvertible {
    public let org: String
    public var description: String { "conversation names: organisation \"\(org)\" has no directory." }
}

/// `~/.wakil/orgs/<org>/conversation-names.json`: `{"<lineageRoot>": {"operator": …, "ai": …}}`.
public struct ConversationNameFile: Sendable {
    public let org: String
    private let home: URL

    /// `home` is the `.wakil` directory.
    public init(org: String, home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        .appendingPathComponent(".wakil", isDirectory: true)) {
        self.org = org
        self.home = home
    }

    private var directory: URL {
        home.appendingPathComponent("orgs", isDirectory: true).appendingPathComponent(org, isDirectory: true)
    }

    public var path: String { directory.appendingPathComponent("conversation-names.json").path }

    /// Every stored name by lineage root; `[:]` when the file is missing. A file that is there but cannot
    /// be read or parsed throws `ConversationNamesUnreadable`.
    public func read() throws -> [String: StoredConversationName] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        } catch {
            throw ConversationNamesUnreadable(path: path, reason: error.localizedDescription)
        }
        do { return try JSONDecoder().decode([String: StoredConversationName].self, from: data) }
        catch { throw ConversationNamesUnreadable(path: path, reason: error.localizedDescription) }
    }

    /// `.none` leaves a slot as it is, `.some(nil)` clears it, `.some(name)` sets it. An entry left with
    /// neither name is removed. The organisation's directory must exist; the file is never written over
    /// one that cannot be read.
    public func set(root: String, operator: String??, ai: String??) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConversationNamesNoOrganisation(org: org)
        }
        var all = try read()
        var entry = all[root] ?? StoredConversationName()
        if let slot = `operator` { entry.operator = slot }
        if let slot = ai { entry.ai = slot }
        if entry.operator == nil && entry.ai == nil { all[root] = nil } else { all[root] = entry }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
