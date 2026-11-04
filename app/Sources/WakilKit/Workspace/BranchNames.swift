import Foundation

// Branch and folder names (decision 10's fallback, the child suffix, unique slugs).

/// The longest a slug runs.
let branchSlugLimit = 50

/// Lower case, accents folded, every run of anything but letters and digits one "-", trimmed, at
/// most 50 characters (cut at a "-" when one is near).
public func branchSlug(_ title: String) -> String {
    let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
    var out = ""
    var dash = false
    for ch in folded.unicodeScalars {
        if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
            if dash, !out.isEmpty { out.append("-") }
            out.unicodeScalars.append(ch)
            dash = false
        } else {
            dash = true
        }
    }
    guard out.count > branchSlugLimit else { return out }
    let cut = String(out.prefix(branchSlugLimit))
    if let i = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: i) > branchSlugLimit / 2 {
        return String(cut[..<i])
    }
    return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// `<KEY>-<slug of title>`, or the slug alone, or "work" when there is nothing to go on. A title
/// that already starts with the key (any case) has it once: the slug's copy of it is dropped.
public func fallbackBranchName(key: String?, title: String) -> String {
    var slug = branchSlug(title)
    if let key, !key.isEmpty {
        let k = branchSlug(key)
        if !k.isEmpty, slug == k {
            slug = ""
        } else if !k.isEmpty, slug.hasPrefix(k + "-") {
            slug = String(slug.dropFirst(k.count + 1))
        }
    }
    switch (key.flatMap { $0.isEmpty ? nil : $0 }, slug.isEmpty) {
    case (let k?, false): return "\(k)-\(slug)"
    case (let k?, true): return k
    case (nil, false): return slug
    case (nil, true): return "work"
    }
}

/// A child's branch: the parent's plus `--` and the first two characters of its conversation id,
/// one more character at a time until the name is unused.
public func childBranchName(_ parent: String, conversation: String, taken: Set<String>) -> String {
    let id = conversation.filter { $0.isLetter || $0.isNumber }.lowercased()
    var n = 2
    while true {
        let name = "\(parent)--\(id.prefix(n))"
        if !taken.contains(name) { return name }
        if n >= id.count { break }
        n += 1
    }
    var i = 2
    while taken.contains("\(parent)--\(id)\(i)") { i += 1 }
    return "\(parent)--\(id)\(i)"
}

/// `slug`, else `slug-2`, `slug-3` … the first not in `taken`.
public func uniqueSlug(_ slug: String, taken: Set<String>) -> String {
    let base = slug.isEmpty ? "work" : slug
    if !taken.contains(base) { return base }
    var i = 2
    while taken.contains("\(base)-\(i)") { i += 1 }
    return "\(base)-\(i)"
}

/// A branch the agent chose (workspace_start) with the ticket's key once: a key written twice in a
/// row (any case, joined by "-") keeps its first copy — `from-production/INI-1637-ini-1637-full-jwt`
/// is `from-production/INI-1637-full-jwt` (amendment 2026-10-30, the walk's key once).
public func branchWithKeyOnce(_ branch: String, key: String?) -> String {
    guard let key, !key.isEmpty else { return branch }
    let k = NSRegularExpression.escapedPattern(for: key)
    guard let twice = try? NSRegularExpression(pattern: "(\(k))-\(k)(?![A-Za-z0-9])", options: .caseInsensitive) else { return branch }
    var out = branch
    while true {
        let next = twice.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        if next == out { return out }
        out = next
    }
}
