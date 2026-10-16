import CryptoKit
import Foundation

/// Compound names and file names from each project root's tracked files
/// (spec: "rule 1" — every language, no per-language patterns). Capped
/// per root, most frequent first, and cached per root and git `HEAD`.
public struct CodeSource: IdentifierSource {
    public let kind = IdentifierSourceKind.code
    public let name = "code"
    let cacheDirectory: URL
    let cap: Int
    let git: String

    static let skippedDirectories = ["vendor/", "node_modules/", ".build/", "build/", "dist/", "generated/", "Generated/"]
    static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "pdf", "wav", "m4a", "caf", "aiff", "icns", "ttf", "otf",
        "woff", "woff2", "zip", "bin", "sum", "lock", "resolved", "metallib", "map",
    ]
    /// Files larger than this are not read: a cold scan of a big root must stay bounded.
    static let maxFileBytes = 512 * 1024
    /// snake_case, kebab-case, camelCase / PascalCase with two or more parts.
    static let compound = try! NSRegularExpression(pattern:
        "\\b(?:[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[A-Z]{2,}[a-z][A-Za-z0-9]*)\\b")

    public init(cacheDirectory: URL, cap: Int = 20_000, git: String = "/usr/bin/git") {
        self.cacheDirectory = cacheDirectory
        self.cap = cap
        self.git = git
    }

    public static func defaultCacheDirectory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".wakil", isDirectory: true)
            .appendingPathComponent("vocabulary", isDirectory: true)
    }

    public static func compoundNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return compound.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    public func identifiers(for context: ContextStore.ActiveContext) async throws -> [Identifier] {
        try await gather(for: context).names
    }

    /// A root that is not a git repository, or has no commits, contributes
    /// nothing and is reported; the other roots still answer. Throws only
    /// when every root failed.
    public func gather(for context: ContextStore.ActiveContext) async throws -> IdentifierGathering {
        var out: [Identifier] = []
        var failures: [String] = []
        for root in context.rootPaths {
            let origin = "\(context.project)/\(URL(fileURLWithPath: root).lastPathComponent)"
            do {
                out += try names(root: root).map { Identifier(text: $0, kind: .code, origin: origin, source: .code) }
            } catch let error as CancellationError {
                throw error
            } catch {
                failures.append(String(describing: error))
            }
        }
        if !failures.isEmpty, failures.count == context.rootPaths.count {
            throw CodeSourceError(message: failures.joined(separator: "; "))
        }
        return IdentifierGathering(names: out, failures: failures)
    }

    func names(root: String) throws -> [String] {
        let head = try run(["-C", root, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data((root + "@" + head + "@" + String(cap)).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fileName = "v1-" + digest + ".txt"
        let cacheFile = cacheDirectory.appendingPathComponent(fileName)
        if let cached = try? String(contentsOf: cacheFile, encoding: .utf8) {
            // First line is the root path (used to prune); the rest are names.
            return cached.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map(String.init)
        }
        var counts: [String: Int] = [:]
        for path in try run(["-C", root, "ls-files", "-z"]).split(separator: "\0").map(String.init) {
            try Task.checkCancellation()
            if Self.skippedDirectories.contains(where: { path.hasPrefix($0) || path.contains("/" + $0) }) { continue }
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            if Self.skippedExtensions.contains(url.pathExtension.lowercased()) { continue }
            if url.lastPathComponent.hasSuffix(".min.js") { continue }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            // A link's own size is not its target's: following it would bypass the cap.
            if values?.isSymbolicLink == true { continue }
            counts[url.lastPathComponent, default: 0] += 1
            if let size = values?.fileSize, size > Self.maxFileBytes { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in Self.compoundNames(in: text) { counts[name, default: 0] += 1 }
        }
        let kept = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(cap).map(\.key)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        pruneCache(root: root, keeping: fileName)
        try? ([root] + kept).joined(separator: "\n").write(to: cacheFile, atomically: true, encoding: .utf8)
        return kept
    }

    /// Drops this root's cache files from earlier HEADs.
    private func pruneCache(root: String, keeping: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        for file in files where file.hasPrefix("v1-") && file.hasSuffix(".txt") && file != keeping {
            let url = cacheDirectory.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) == root
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        let out = Pipe()
        // stderr goes to a file, not a pipe, so a chatty git can never fill it and deadlock.
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("codesource-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? errHandle.close() }
        process.standardOutput = out
        process.standardError = errHandle
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw CodeSourceError(message: "git \(arguments.dropFirst(2).joined(separator: " ")) in \(arguments[1]): \(message)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CodeSourceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
