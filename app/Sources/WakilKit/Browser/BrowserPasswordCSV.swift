import Foundation

/// One row of the Passwords app's export. Held only in the import sheet's view state (ruling 17).
public struct BrowserImportRow: Sendable, Equatable, Identifiable {
    /// The line the record starts on, the header being line 1.
    public let id: Int
    public let title: String
    public let site: String?
    public let url: String
    public let username: String
    public let password: String
    public let skipped: String?

    public init(id: Int, title: String, site: String?, url: String, username: String, password: String,
                skipped: String?) {
        self.id = id; self.title = title; self.site = site; self.url = url
        self.username = username; self.password = password; self.skipped = skipped
    }
}

/// No case carries a value from the file, so no error's text can hold a password.
public enum BrowserPasswordCSVError: Error, Equatable {
    case noHeader
}

public enum BrowserPasswordCSV {
    static let noURL = "no URL"
    static let noPassword = "no password"
    static let notWeb = "not a web address"
    static let replaced = "a later row for the same login replaces this one"

    /// Reads bytes, writes nothing. Ruling 17: skips, `https://` for a bare host, the later row wins.
    public static func parse(_ data: Data) throws -> [BrowserImportRow] {
        let records = records(String(decoding: data, as: UTF8.self))
        guard let header = records.first else { throw BrowserPasswordCSVError.noHeader }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let urlAt = names.firstIndex(of: "url"), let passwordAt = names.firstIndex(of: "password") else {
            throw BrowserPasswordCSVError.noHeader
        }
        let titleAt = names.firstIndex(of: "title"), userAt = names.firstIndex(of: "username")

        var rows: [BrowserImportRow] = []
        for record in records.dropFirst() {
            func field(_ at: Int?) -> String {
                guard let at, at < record.fields.count else { return "" }
                return record.fields[at]
            }
            let rawURL = field(urlAt).trimmingCharacters(in: .whitespacesAndNewlines)
            let password = field(passwordAt)
            let url = rawURL.isEmpty || hasScheme(rawURL) ? rawURL : "https://" + rawURL
            let site = rawURL.isEmpty ? nil : BrowserPasswords.siteKey(url)
            let skipped: String? =
                rawURL.isEmpty ? noURL : password.isEmpty ? noPassword : site == nil ? notWeb : nil
            rows.append(BrowserImportRow(id: record.line, title: field(titleAt), site: site, url: url,
                                         username: field(userAt), password: password, skipped: skipped))
        }

        var lastIndex: [String: Int] = [:]
        for (i, row) in rows.enumerated() where row.skipped == nil {
            lastIndex[(row.site ?? "") + " " + row.username] = i
        }
        for (i, row) in rows.enumerated() where row.skipped == nil {
            if lastIndex[(row.site ?? "") + " " + row.username] != i {
                rows[i] = BrowserImportRow(id: row.id, title: row.title, site: row.site, url: row.url,
                                           username: row.username, password: row.password, skipped: replaced)
            }
        }
        return rows
    }

    private static func hasScheme(_ s: String) -> Bool { s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil }

    private struct Record { var line: Int; var fields: [String] }

    /// RFC 4180 over characters. A leading BOM is dropped; CRLF is one line break; blank lines are ignored.
    private static func records(_ text: String) -> [Record] {
        var out: [Record] = []
        var fields: [String] = [], field = "", quoted = false, wasQuoted = false
        var line = 1, start = 1
        func endField() { fields.append(field); field = ""; wasQuoted = false }
        func endRecord() {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) { out.append(Record(line: start, fields: fields)) }
            fields = []
        }
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append(c); i += 1 }
                    else { quoted = false }
                } else {
                    if c == "\n" { line += 1 }
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" && field.isEmpty && !wasQuoted {
                quoted = true; wasQuoted = true
            } else if c == "," {
                endField()
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRecord(); line += 1; start = line
            } else {
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !fields.isEmpty || wasQuoted { endRecord() }
        return out
    }
}
