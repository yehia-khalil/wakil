import Foundation

/// `passwords-never.json` exists but cannot be read; it is never written over (3c-iii Ruling 4).
public struct BrowserNeverSaveUnreadable: Error, Sendable, Equatable {
    public let reason: String
}

extension BrowserOrgFiles {
    private var neverSaveURL: URL { directory.appendingPathComponent("passwords-never.json") }

    /// The sites the operator said never to offer saving a password for, sorted; `[]` when the file is
    /// missing. A file that is there but cannot be read or parsed throws `BrowserNeverSaveUnreadable`.
    /// The file holds site keys only, never a credential.
    public func neverSave() throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: neverSaveURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw BrowserNeverSaveUnreadable(reason: error.localizedDescription)
        }
        do { return try JSONDecoder().decode([String].self, from: data) }
        catch { throw BrowserNeverSaveUnreadable(reason: error.localizedDescription) }
    }

    /// Adds (`on` true) or removes (`on` false) `site`; the result is the list afterwards. Nothing is
    /// written when nothing changes. An unreadable file is refused, not replaced.
    @discardableResult
    public func setNeverSave(site: String, on: Bool) throws -> [String] {
        var all = try neverSave()
        let exists = all.contains(site)
        guard on != exists else { return all }
        if on { all.append(site); all.sort() } else { all.removeAll { $0 == site } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(all).write(to: neverSaveURL, options: .atomic)
        return all
    }
}
