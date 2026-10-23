import Foundation

/// What the settings pane's database card asks for: the parts of a
/// connection, never the string.
///
/// **The operator types parts; the driver's shape is Go's job (2e-iv).**
/// The form once took the string itself, and the fixture's own
/// `mysql://e2e:secret@localhost/ledger` showed what that costs: URL form,
/// which `go-sql-driver`'s `ParseDSN` refuses at first use. The parts went
/// to a Swift builder in 2e-ii; since 2e-iv they go to `db_set_connection`
/// whole, and `wakilcore.BuildConnectionString` builds and refuses, so the
/// shell, the agent's tools and this card share one builder.
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

/// The card in edit mode (2e-iv): **Edit** on a row fills the ADD OR REPLACE A DATABASE card with
/// everything known about that database but its password(s), which are never read back.
///
/// It also remembers what was there, so a password prompt can say `unchanged` only while that is
/// true: Go keeps a stored password only for the same driver and the same user, and a prompt that
/// promised otherwise would be refused at Save.
public struct DatabaseCardEdit: Equatable, Sendable {
    /// The database being edited, as the row names it.
    public let name: String
    /// Saved as one string (no `connection`): nothing to show, and every login must be typed.
    public let legacy: Bool
    /// The card's fields as Edit fills them. Passwords empty.
    public let fields: DatabaseConnectionFields
    /// Pre-checked on a writable record: saving without it would drop nothing (Go keeps the
    /// writeRef) but a legacy writable record is refused without it, so the card starts where a
    /// save works.
    public let grantWrite: Bool
    public let writeUser: String
    private let writable: Bool
    private let originalDriver: String
    private let storedUser: String
    private let storedWriteUser: String

    public init(editing database: SettingsDatabase) {
        name = database.name
        let driver = databaseDrivers.contains(database.driver) ? database.driver : "mysql"
        legacy = database.connection == nil
        let connection = database.connection ?? SettingsDatabaseConnection()
        fields = DatabaseConnectionFields(
            driver: driver, host: connection.host, port: connection.port, user: connection.user,
            database: connection.database, path: connection.path)
        grantWrite = database.writable
        writable = database.writable
        writeUser = database.writable ? connection.writeUser : ""
        storedUser = connection.user
        storedWriteUser = database.writable ? connection.writeUser : ""
        originalDriver = driver
    }

    /// Whether the card still edits this database: its NAME has not been changed. A different
    /// name saves as another database, so nothing stored for this one carries over.
    public func isEditing(name: String) -> Bool { name == self.name }

    /// `EDIT <name>` while the card edits this database; the add title once NAME moves away.
    public func title(name: String) -> String {
        isEditing(name: name) ? DatabaseWording.editTitle(name: self.name) : DatabaseWording.cardTitle
    }

    /// `unchanged` while leaving the password empty keeps the stored one: a split server record,
    /// the same name, the same driver, the same user. Otherwise no prompt — the password is needed.
    public func passwordPrompt(name: String, driver: String, user: String) -> String {
        !legacy && isEditing(name: name) && databaseDriverHasServer(driver) && driver == originalDriver
            && !storedUser.isEmpty && user == storedUser
            ? DatabaseWording.unchanged : ""
    }

    /// The same for the write login: a split record that already writes through `writeUser`.
    public func writePasswordPrompt(name: String, driver: String, writeUser: String) -> String {
        !legacy && isEditing(name: name) && databaseDriverHasServer(driver) && driver == originalDriver
            && !storedWriteUser.isEmpty && writeUser == storedWriteUser
            ? DatabaseWording.unchanged : ""
    }

    /// Whether the card offers **Allow writes**. Not while editing a writable database: Go keeps
    /// its write login when a save does not grant, so unchecking would revoke nothing. Revoking
    /// is the row's **Remove write access**. Granting from Edit is fine.
    public func showsAllowWrites(name: String) -> Bool {
        !(writable && isEditing(name: name))
    }

    /// Whether the card still has a database to edit: one renamed or removed from its row has left
    /// the list, and the card goes back to adding.
    public func isListed(in names: [String]) -> Bool { names.contains(name) }

    /// Where Edit puts the keyboard (Rule 3): the first connection field — the host, or the file
    /// for SQLite. Not NAME: a database is renamed on its row, and a name typed here saves as a
    /// second database.
    public var focus: DatabaseConnectionFields.CredentialField {
        databaseDriverHasServer(fields.driver) ? .host : .path
    }
}
