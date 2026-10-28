import Foundation

/// A file keychain in a temporary directory, with a random password, unlocked and never locking again.
/// It is never added to the search list, so nothing but the store handed its `path` can see it, and it
/// is never the login keychain. A test calls `remove()` when it is done.
struct TemporaryKeychain {
    let path: String
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakil-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("test.keychain-db").path
        let password = UUID().uuidString
        try Self.security(["create-keychain", "-p", password, path])
        try Self.security(["unlock-keychain", "-p", password, path])
        // Without this the keychain relocks after 300 s or on sleep (see e2e/driver/launch.go).
        try Self.security(["set-keychain-settings", path])
    }

    func remove() {
        _ = try? Self.security(["delete-keychain", path])
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func security(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TemporaryKeychain", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "security \(arguments.first ?? ""): \(text)"])
        }
        return text
    }
}
