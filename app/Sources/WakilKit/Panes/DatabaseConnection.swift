import Foundation

/// What the settings pane's database form asks for, before it is a
/// connection string.
///
/// **The operator types parts; the driver's shape is this file's job.**
/// The form used to take the string itself, and the fixture's own
/// `mysql://e2e:secret@localhost/ledger` shows what that costs: URL form,
/// which `go-sql-driver`'s `ParseDSN` refuses at first use, nowhere near the
/// paste that caused it. Three drivers want three shapes, so the form asks
/// for what a person knows and this builds what the driver reads.
///
/// `db_set_dsn` is unchanged: it still stores one string in the Keychain,
/// redacted in the journal. Only the way the string is made moved.
public struct DatabaseConnectionFields: Equatable, Sendable {
    public var driver: String
    public var host: String
    public var port: String
    public var user: String
    public var password: String
    public var database: String
    /// SQLite's only part: it has no server, so no host, user or password.
    public var path: String

    public init(
        driver: String, host: String = "", port: String = "", user: String = "",
        password: String = "", database: String = "", path: String = ""
    ) {
        self.driver = driver
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.path = path
    }
}

/// A connection string, or the sentence saying why none could be built.
///
/// A refusal never quotes the password: it is drawn on screen.
public enum ConnectionStringResult: Equatable, Sendable {
    case built(String)
    case refused(String)
}

/// The drivers `wakilcore` registers, in the order the form offers them.
public let databaseDrivers = ["mysql", "mongo", "sqlite"]

/// The port each server driver listens on unless told otherwise.
public func defaultDatabasePort(for driver: String) -> String? {
    switch driver {
    case "mysql": return "3306"
    case "mongo": return "27017"
    default: return nil
    }
}

/// Whether `driver` is a server, and so asks for host, port, user and
/// password, rather than a file.
public func databaseDriverHasServer(_ driver: String) -> Bool {
    defaultDatabasePort(for: driver) != nil
}

/// Builds the connection string `fields.driver` reads.
///
/// **Refused rather than guessed.** Each shape has characters it treats as
/// structure and no way to escape some of them — MySQL splits a user from
/// its password on the FIRST `:` — so a part that would be read back as a
/// different part is refused in words, and nothing is stored.
public func databaseConnectionString(_ fields: DatabaseConnectionFields) -> ConnectionStringResult {
    switch fields.driver {
    case "sqlite":
        return fields.path.isEmpty
            ? .refused("a SQLite database needs the path to its file")
            : .built(fields.path)
    case "mysql", "mongo":
        return serverConnectionString(fields)
    default:
        return .refused("\(fields.driver.debugDescription) is not a driver Wakil has — "
            + "choose one of \(databaseDrivers.joined(separator: ", "))")
    }
}

private func serverConnectionString(_ fields: DatabaseConnectionFields) -> ConnectionStringResult {
    if fields.host.isEmpty { return .refused("a host is needed") }
    if fields.user.isEmpty { return .refused("a user is needed") }
    if fields.database.isEmpty { return .refused("a database name is needed") }

    let hostBreakers = CharacterSet(charactersIn: "/?#@()").union(.whitespacesAndNewlines)
    if fields.host.rangeOfCharacter(from: hostBreakers) != nil {
        return .refused("the host \(fields.host.debugDescription) contains a character "
            + "that would be read as part of the address — give the name or IP alone")
    }
    let databaseBreakers = CharacterSet(charactersIn: "/?#").union(.whitespacesAndNewlines)
    if fields.database.rangeOfCharacter(from: databaseBreakers) != nil {
        return .refused("the database name \(fields.database.debugDescription) cannot "
            + "contain / ? # or spaces")
    }

    let port = fields.port.isEmpty ? (defaultDatabasePort(for: fields.driver) ?? "") : fields.port
    guard port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber),
          let number = Int(port), (1...65535).contains(number)
    else {
        return .refused("the port must be a number from 1 to 65535")
    }

    if fields.driver == "mysql" {
        // `ParseDSN` takes the last `@` before the address and the first
        // `:` of what precedes it — so a password may carry anything and a
        // user may not carry a colon. The format has no escape for it.
        if fields.user.contains(":") {
            return .refused("a MySQL user cannot contain \":\" — the connection string "
                + "has no way to escape it")
        }
        return .built("\(fields.user):\(fields.password)@tcp(\(fields.host):\(port))/\(fields.database)")
    }
    return .built("mongodb://\(percentEncodedUserinfo(fields.user)):"
        + "\(percentEncodedUserinfo(fields.password))@\(fields.host):\(port)/\(fields.database)")
}

/// RFC 3986's unreserved characters stay; everything else is encoded, which
/// is stricter than a URI requires and exactly what a mongo URI's parser
/// decodes.
private func percentEncodedUserinfo(_ text: String) -> String {
    let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
}

/// The two strings the form's Save sends, or why it cannot send them.
public enum DatabaseFormCredentials: Equatable, Sendable {
    /// `write` is nil unless writes were granted.
    case built(read: String, write: String?)
    case refused(String)
}

/// Builds what `db_set_dsn` takes from the whole form.
///
/// **The write credential is a second login to the same server**, so it
/// shares host, port and database and changes only the user and password.
/// A SQLite file has no logins, so writing it is the same path again.
public func databaseFormCredentials(
    _ fields: DatabaseConnectionFields, grantWrite: Bool,
    writeUser: String, writePassword: String
) -> DatabaseFormCredentials {
    let read: String
    switch databaseConnectionString(fields) {
    case .refused(let reason): return .refused(reason)
    case .built(let string): read = string
    }
    guard grantWrite else { return .built(read: read, write: nil) }
    guard databaseDriverHasServer(fields.driver) else { return .built(read: read, write: read) }
    if writeUser.isEmpty {
        return .refused("allowing writes needs the write login's user — write authority is a "
            + "second credential the server granted, not the read one with a flag set")
    }
    var writeFields = fields
    writeFields.user = writeUser
    writeFields.password = writePassword
    switch databaseConnectionString(writeFields) {
    case .refused(let reason): return .refused("the write login: " + reason)
    case .built(let write): return .built(read: read, write: write)
    }
}
