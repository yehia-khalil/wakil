import Foundation

/// What a known name is. Shown in the note, so a reader can tell a
/// column from a code name with the same spelling.
public enum IdentifierKind: String, Sendable {
    case table, column, collection, code, file, action, org, project, environment, endpoint, path
}

/// Which source supplied a name. The raw value is the candidate ranking
/// the spec fixes: what is on screen first, code last.
public enum IdentifierSourceKind: Int, Sendable, Comparable {
    case panes = 0, schema = 1, wakil = 2, code = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One name Wakil knows is in scope.
public struct Identifier: Sendable, Hashable {
    public let text: String
    public let kind: IdentifierKind
    /// Where it came from, as the note prints it: `staging · core db`, `wakil/app`.
    public let origin: String
    public let source: IdentifierSourceKind

    public init(text: String, kind: IdentifierKind, origin: String, source: IdentifierSourceKind) {
        self.text = text
        self.kind = kind
        self.origin = origin
        self.source = source
    }
}

/// The fold `2d-stt-probe.md` §6.2 measured and §10 re-measured:
/// lowercase, then keep only letters, digits and dots. Spaces, hyphens,
/// underscores, apostrophes and slashes all fold away; dots stay so
/// `paths.go` keeps its extension.
public func identifierFold(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "."
    }.map(Character.init))
}

/// Every source's names, indexed by folded form. Immutable: a rebuild
/// replaces it whole, so a reader never sees half of one org's names.
public struct Vocabulary: Sendable {
    private let byFold: [String: [Identifier]]
    public let count: Int
    /// Every name as gathered, in order and with repeats. Ghost-text regroups a schema's columns
    /// under the table before them (`GhostSchema.tables`), which the folded index cannot give back.
    public let names: [Identifier]

    public static let empty = Vocabulary([])

    public init(_ identifiers: [Identifier]) {
        var seen = Set<Identifier>()
        var byFold: [String: [Identifier]] = [:]
        for identifier in identifiers where seen.insert(identifier).inserted {
            let key = identifierFold(identifier.text)
            guard !key.isEmpty else { continue }
            byFold[key, default: []].append(identifier)
        }
        self.byFold = byFold
        self.count = seen.count
        self.names = identifiers
    }

    public func names(folded: String) -> [Identifier] { byFold[folded] ?? [] }
}
