import Foundation
import Testing

/// `WakilKit`'s folders and which use which: a type, or a top-level function or
/// constant, declared in folder A and named in a file of folder B is a link B -> A.
/// Comments and string literals are stripped first, keeping what is inside an
/// interpolation. A name declared in two folders, or a generic nested name, is
/// skipped and listed rather than guessed at.
struct FolderGraph {
    struct Edge: Hashable, Comparable, CustomStringConvertible {
        let from: String
        let to: String
        var description: String { "\(from) -> \(to)" }
        static func < (a: Edge, b: Edge) -> Bool { (a.from, a.to) < (b.from, b.to) }
    }

    /// Each link, with the first file and type that made it, for messages.
    var edges: [Edge: (file: String, type: String)] = [:]
    var skipped: Set<String> = []

    /// `handle` is `MCPServer`'s top-level function and a common local name.
    static let genericNames: Set<String> = ["CodingKeys", "Source", "Contents", "Kind", "State", "handle"]

    /// `files`: path relative to the source root ("Panes/PaneStore.swift") → its text.
    static func build(files: [String: String]) -> FolderGraph {
        var declaredIn: [String: Set<String>] = [:]
        var stripped: [String: String] = [:]
        for (path, text) in files {
            let clean = strip(text)
            stripped[path] = clean
            for name in matches(declarationPattern, in: clean) + matches(topLevelSymbolPattern, in: clean) {
                declaredIn[name, default: []].insert(folder(of: path))
            }
        }
        var graph = FolderGraph()
        var owner: [String: String] = [:]
        for (name, folders) in declaredIn {
            if folders.count == 1, !genericNames.contains(name) { owner[name] = folders.first! }
            else { graph.skipped.insert(name) }
        }
        for (path, clean) in stripped.sorted(by: { $0.key < $1.key }) {
            let from = folder(of: path)
            for word in Set(matches(#"\b([A-Za-z_]\w*)\b"#, in: clean)).sorted() {
                guard let to = owner[word], to != from else { continue }
                let edge = Edge(from: from, to: to)
                if graph.edges[edge] == nil { graph.edges[edge] = (path, word) }
            }
        }
        return graph
    }

    static func folder(of path: String) -> String {
        path.contains("/") ? String(path.split(separator: "/")[0]) : "(root)"
    }

    /// Removes comments and string literals, keeping the code inside each `\( )`
    /// interpolation. A scanner rather than regexes, so a `/*` inside a `//` comment
    /// or a string, a `\"`, a raw string and a nested block comment all read as Swift does.
    static func strip(_ text: String) -> String {
        var scanner = Stripper(Array(text.unicodeScalars))
        scanner.code(untilParen: false)
        return String(String.UnicodeScalarView(scanner.out))
    }

    private struct Stripper {
        let c: [Unicode.Scalar]
        var i = 0
        var out: [Unicode.Scalar] = []
        init(_ c: [Unicode.Scalar]) { self.c = c }

        func at(_ k: Int) -> Unicode.Scalar? { k < c.count ? c[k] : nil }
        func starts(_ s: String, _ k: Int) -> Bool {
            var k = k
            for u in s.unicodeScalars { guard at(k) == u else { return false }; k += 1 }
            return true
        }

        /// Copies code; inside an interpolation, stops after its closing paren.
        mutating func code(untilParen: Bool) {
            var depth = 0
            while let ch = at(i) {
                if starts("//", i) {
                    while let x = at(i), x != "\n" { i += 1 }
                } else if starts("/*", i) {
                    var nest = 0
                    repeat {
                        if starts("/*", i) { nest += 1; i += 2 }
                        else if starts("*/", i) { nest -= 1; i += 2 }
                        else { i += 1 }
                    } while nest > 0 && i < c.count
                    out.append(" ")
                } else if ch == "#" || ch == "\"" {
                    var hashes = 0
                    while at(i + hashes) == "#" { hashes += 1 }
                    guard at(i + hashes) == "\"" else { out.append(ch); i += 1; continue }
                    i += hashes
                    string(hashes: hashes)
                } else if untilParen && ch == "(" {
                    depth += 1; out.append(ch); i += 1
                } else if untilParen && ch == ")" {
                    i += 1
                    if depth == 0 { return }
                    depth -= 1; out.append(ch)
                } else {
                    out.append(ch); i += 1
                }
            }
        }

        /// At the opening quote; leaves `""` and any interpolated code behind.
        mutating func string(hashes: Int) {
            let multiline = starts("\"\"\"", i)
            let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            i += multiline ? 3 : 1
            out.append("\""); out.append("\"")
            while let ch = at(i) {
                if starts(close, i) { i += close.unicodeScalars.count; return }
                if !multiline && ch == "\n" { return }
                if starts(escape, i) {
                    i += escape.unicodeScalars.count
                    if at(i) == "(" {
                        i += 1
                        out.append(" ")
                        code(untilParen: true)
                        out.append(" ")
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }
    }

    static let declarationPattern =
        #"(?m)^\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+(?:\([^)]*\))?)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w+)"#

    /// Top-level (unindented) functions and constants: `confirmationDescription`,
    /// `wakilShimServerName`. Members are reached through their type, which is the link;
    /// `private` and `fileprivate` ones cannot leave their file, so they are not indexed.
    static let topLevelSymbolPattern =
        #"(?m)^(?:(?:public|internal|nonisolated|@\w+(?:\([^)]*\))?)\s+)*(?:func|let|var)\s+([A-Za-z_]\w*)"#

    static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

struct LayeringVerdict {
    var intoApp: [String] = []
    var coreUsesOthers: [String] = []
    var unlisted: [String] = []
    var stale: [String] = []
    var isClean: Bool { intoApp.isEmpty && coreUsesOthers.isEmpty && unlisted.isEmpty && stale.isEmpty }
}

/// The rules: nothing uses `App/` (WindowModel stays on top); `Core/` uses no
/// other folder and any folder may use it; every other link is on the
/// allow-list; and every allow-list entry is still a real link, so the list
/// only shrinks.
func layeringVerdict(_ graph: FolderGraph, allowed: Set<String>) -> LayeringVerdict {
    var verdict = LayeringVerdict()
    for edge in graph.edges.keys.sorted() {
        let witness = graph.edges[edge]!
        let line = "\(edge) (\(witness.file) uses \(witness.type))"
        if edge.to == "App" { verdict.intoApp.append(line) }
        else if edge.from == "Core" { verdict.coreUsesOthers.append(line) }
        else if edge.to == "Core" { continue }
        else if !allowed.contains(edge.description) { verdict.unlisted.append(line) }
    }
    let real = Set(graph.edges.keys.map(\.description))
    verdict.stale = allowed.subtracting(real).sorted()
    return verdict
}

private let fakeTree: [String: String] = [
    "App/Model.swift": "final class AppThing {}",
    "Panes/Pane.swift": "struct PaneThing { var a: AppThing }",
    "Layout/Layout.swift": "struct LayoutThing { var p: PaneThing }",
    "Core/Value.swift": "struct CoreThing { var l: LayoutThing }",
    "Terminal/Term.swift": """
        struct TermThing { var c: CoreThing }
        // a LayoutThing in a comment does not count
        let s = "nor a LayoutThing in a string"
        """,
    "Api/A.swift": "struct Twin {}",
    "Git/B.swift": "struct Twin {}\nlet t = Twin()",
]

@Test func aLinkIntoAppFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes"])
    #expect(verdict.intoApp == ["Panes -> App (Panes/Pane.swift uses AppThing)"])
}

@Test func anUnlistedLinkFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: [])
    #expect(verdict.unlisted == ["Layout -> Panes (Layout/Layout.swift uses PaneThing)"])
}

@Test func aStaleAllowedLinkFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes", "Gone -> Away"])
    #expect(verdict.stale == ["Gone -> Away"])
}

@Test func coreUsingAnotherFolderFails() {
    let verdict = layeringVerdict(FolderGraph.build(files: fakeTree), allowed: ["Layout -> Panes"])
    #expect(verdict.coreUsesOthers == ["Core -> Layout (Core/Value.swift uses LayoutThing)"])
}

@Test func anyFolderMayUseCoreAndCommentsAndStringsDoNotCount() {
    let graph = FolderGraph.build(files: fakeTree)
    let fromTerminal = graph.edges.keys.filter { $0.from == "Terminal" }.map(\.description)
    #expect(fromTerminal == ["Terminal -> Core"])
    #expect(layeringVerdict(graph, allowed: ["Layout -> Panes"]).unlisted.isEmpty)
}

@Test func aNameDeclaredInTwoFoldersIsSkippedNotGuessed() {
    let graph = FolderGraph.build(files: fakeTree)
    #expect(graph.skipped.contains("Twin"))
    #expect(!graph.edges.keys.contains { $0.to == "Api" || $0.to == "Git" })
}

/// What the type-only scanner missed (code review of the stack): free functions and
/// constants, names used only inside an interpolation, and code after a `/*` that sits
/// inside a `//` comment.
private let symbolTree: [String: String] = [
    "App/Support.swift": "func appHelper() -> Int { 1 }\npublic let appName = \"wakil\"\n",
    "Panes/Calls.swift": "struct Caller { func f() -> Int { appHelper() } }",
    "Harness/Names.swift": #"let tool = "mcp__\(appName)__run""#,
    "MCP/Comment.swift": "// a `/*` in a line comment\nstruct Hidden { let n = appHelper() }\n",
    "Terminal/Private.swift": "private func string(_ n: Int) -> String { \"\" }\nfileprivate let hidden = 1\n",
    "Query/Locals.swift": "func string(_ n: Int) -> Int { n }\nlet h = hidden",
    "Git/Strings.swift": ##"let a = "say \"appName\" here"; let b = #"appHelper() \(x)"#"##,
]

@Test func aFreeFunctionOrConstantMakesALinkToo() {
    let graph = FolderGraph.build(files: symbolTree)
    #expect(graph.edges[.init(from: "Panes", to: "App")]?.type == "appHelper")
}

@Test func aNameUsedOnlyInsideAnInterpolationCounts() {
    let graph = FolderGraph.build(files: symbolTree)
    #expect(graph.edges[.init(from: "Harness", to: "App")]?.type == "appName")
}

@Test func aBlockCommentOpenerInsideALineCommentHidesNothing() {
    let graph = FolderGraph.build(files: symbolTree)
    #expect(graph.edges[.init(from: "MCP", to: "App")]?.type == "appHelper")
}

@Test func escapedQuotesAndRawStringsStayStrings() {
    // `\(x)` is not an interpolation inside a raw string, and `\"` does not end a string.
    let graph = FolderGraph.build(files: symbolTree)
    #expect(!graph.edges.keys.contains { $0.from == "Git" })
}

@Test func aPrivateTopLevelNameLinksNothing() {
    // Visible only in its own file, so another folder's `string(...)` is its own.
    let graph = FolderGraph.build(files: symbolTree)
    #expect(!graph.edges.keys.contains { $0.to == "Terminal" })
}

@Test func aSourceRootBehindASymlinkReadsTheSameRelativePaths() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("layering-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try "struct A {}".write(to: real.appendingPathComponent("Sub/a.swift"), atomically: true, encoding: .utf8)
    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(Array(readTree(real).keys) == ["Sub/a.swift"])
    #expect(Array(readTree(link).keys) == ["Sub/a.swift"])
}

@Test func aMissingAllowListSaysSoRatherThanListingEveryLink() {
    let missing = URL(fileURLWithPath: "/nonexistent/layering-allowed.txt")
    #expect(throws: (any Error).self) { try readAllowed(missing) }
}

private let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let sourceRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/WakilKit")
private let allowedFile = testsDir.appendingPathComponent("Fixtures/layering-allowed.txt")

/// Paths relative to `root`, which may be (or sit under) a symlink: the walk
/// starts from the resolved root and asks for relative paths, never cutting one
/// absolute path by the length of another.
func readTree(_ root: URL) -> [String: String] {
    let resolved = root.resolvingSymlinksInPath()
    var files: [String: String] = [:]
    for rel in FileManager.default.subpaths(atPath: resolved.path) ?? [] where rel.hasSuffix(".swift") {
        files[rel] = try! String(contentsOf: resolved.appendingPathComponent(rel), encoding: .utf8)
    }
    return files
}

/// Throws when the file cannot be read, so a missing allow-list says so instead
/// of reporting every link in the tree as new.
func readAllowed(_ file: URL) throws -> Set<String> {
    let text = try String(contentsOf: file, encoding: .utf8)
    return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}

@Test func wakilKitKeepsItsLayering() throws {
    let graph = FolderGraph.build(files: readTree(sourceRoot))
    let verdict = layeringVerdict(graph, allowed: try readAllowed(allowedFile))
    #expect(verdict.intoApp.isEmpty, "Nothing in WakilKit may use App/ (WindowModel stays on top):\n\(verdict.intoApp.joined(separator: "\n"))")
    #expect(verdict.coreUsesOthers.isEmpty, "Core/ may use no other folder:\n\(verdict.coreUsesOthers.joined(separator: "\n"))")
    #expect(verdict.unlisted.isEmpty, """
        New folder links. If each is intended, add it to Fixtures/layering-allowed.txt \
        (the reviewer sees it); otherwise remove the dependency:
        \(verdict.unlisted.map { String($0.prefix(while: { $0 != "(" })).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
        """)
    #expect(verdict.stale.isEmpty, "These allowed links no longer exist; delete them from Fixtures/layering-allowed.txt:\n\(verdict.stale.joined(separator: "\n"))")
    print("layering: \(graph.edges.count) links; skipped names: \(graph.skipped.sorted().joined(separator: ", "))")
}
