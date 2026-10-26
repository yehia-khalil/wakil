import Foundation

// A download's name and its size line (3c-i): pure rules, so they are tested here and the
// window's download strip only draws them.

/// Where a download lands: `<downloads>/<name>`, or — when that is taken — `name 2.ext`,
/// `name 3.ext`, as Finder names a copy. The suggested name is cut to its last path component, so
/// a page cannot write outside the folder.
public func browserDownloadDestination(in folder: URL, suggested: String, exists: (URL) -> Bool) -> URL {
    var name = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name == "." || name == ".." || name == "/" { name = "download" }
    let first = folder.appendingPathComponent(name)
    guard exists(first) else { return first }
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    var n = 2
    while true {
        let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        if !exists(candidate) { return candidate }
        n += 1
    }
}

/// The strip's size line: `12.4 of 80 MB` while running with a known size, the size alone when it
/// is unknown or the download ended — decimal units, as Finder counts.
public func browserDownloadSize(received: Int64, expected: Int64, state: BrowserDownload.State) -> String {
    let total = expected > 0 ? expected : received
    let (unit, name): (Double, String) = total >= 1_000_000_000 ? (1e9, "GB") : total >= 1_000_000 ? (1e6, "MB") : (1e3, "KB")
    func number(_ bytes: Int64) -> String {
        let value = Double(bytes) / unit
        if value >= 100 { return String(format: "%.0f", value) }
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    if state == .running, expected > 0 { return "\(number(received)) of \(number(expected)) \(name)" }
    return "\(number(state == .finished ? total : received)) \(name)"
}
