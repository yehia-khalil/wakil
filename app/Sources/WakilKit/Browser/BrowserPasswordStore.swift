import Foundation
import Security

/// 3d-iv: browser passwords in the macOS Keychain, read and written in-process.
///
/// WHY THIS FILE READS THE KEYCHAIN IN SWIFT when `ProviderCredentialsLookup.swift` says Swift does not.
/// That header is about provider tokens, which Go stores through `/usr/bin/security`, so the `security`
/// binary is on those items' access list. That is right for a token only Go needs. It is wrong for a
/// website password: the agent has a bare shell, so it could run `security find-generic-password -w` on a
/// Go-written item and read the value with no prompt. An item that `SecItemAdd` creates from Wakil.app
/// trusts Wakil.app only, so any other program that asks for its value raises the system's prompt
/// (planner's ruling 1). The naming and the org check are not copied from Go's secrets scheme but
/// shared with it: `BrowserPasswords.service` uses Go's `orgFileTokenPattern`, and `BrowserPasswords.check`
/// runs on every item that comes back.
///
/// A value never reaches an error. Errors are built from the `OSStatus` and `SecCopyErrorMessageString`
/// only. Listing reads attributes only, so it never asks for permission.
///
/// With `keychainFile` set (tests, and e2e through `WAKIL_KEYCHAIN`) every call names that file keychain
/// and nothing else, and says "never show UI", so a locked or deleted keychain fails instead of asking.
/// A file that does not exist is refused, not created.
public enum BrowserSaveOutcome: Sendable, Equatable { case added, updated, unchanged }

public struct BrowserPasswordStore: Sendable {
    public let keychainFile: String?

    public init(keychainFile: String?) {
        self.keychainFile = (keychainFile?.isEmpty ?? true) ? nil : keychainFile
    }

    public init(environment: [String: String]) {
        self.init(keychainFile: environment["WAKIL_KEYCHAIN"])
    }

    // MARK: Reads

    public func logins(org: String, site: String?) throws -> [BrowserLogin] {
        let service = try BrowserPasswords.service(org: org)
        var query = try base(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try require(status, "list")
        var logins: [BrowserLogin] = []
        for item in (result as? [[String: Any]]) ?? [] {
            let itemService = item[kSecAttrService as String] as? String ?? ""
            let account = item[kSecAttrAccount as String] as? String ?? ""
            try BrowserPasswords.check(service: itemService, account: account, org: org, site: nil)
            guard let parsed = BrowserPasswords.parseAccount(account) else {
                throw BrowserPasswordError.wrongOrganisation(expected: org)
            }
            if let site, parsed.site != site { continue }
            logins.append(BrowserLogin(org: org, site: parsed.site, username: parsed.username,
                                       modified: item[kSecAttrModificationDate as String] as? Date))
        }
        return logins.sorted { ($0.site, $0.username) < ($1.site, $1.username) }
    }

    public func password(org: String, site: String, username: String) throws -> String {
        guard let value = try read(org: org, site: site, username: username) else {
            throw BrowserPasswordError.notFound(site: site, username: username, org: org)
        }
        return value
    }

    // MARK: Writes

    @discardableResult
    public func save(org: String, site: String, username: String, password: String) throws -> BrowserSaveOutcome {
        let service = try BrowserPasswords.service(org: org)
        let account = BrowserPasswords.account(site: site, username: username)
        if let existing = try read(org: org, site: site, username: username) {
            if existing == password { return .unchanged }
            var query = try base(service: service)
            query[kSecAttrAccount as String] = account
            let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            try require(SecItemUpdate(query as CFDictionary, update as CFDictionary), "update")
            return .updated
        }
        var item = try base(service: service, forAdd: true)
        item[kSecAttrAccount as String] = account
        item[kSecAttrLabel as String] = "\(site) — Wakil (\(org))"
        item[kSecValueData as String] = Data(password.utf8)
        try require(SecItemAdd(item as CFDictionary, nil), "save")
        return .added
    }

    /// The new item is written before the old one goes, so a failure loses nothing.
    public func rename(org: String, site: String, from: String, to: String, password: String?) throws {
        let value = try password ?? self.password(org: org, site: site, username: from)
        if from == to { try save(org: org, site: site, username: to, password: value); return }
        try save(org: org, site: site, username: to, password: value)
        try delete(org: org, site: site, username: from)
    }

    public func delete(org: String, site: String, username: String) throws {
        let service = try BrowserPasswords.service(org: org)
        var query = try base(service: service)
        query[kSecAttrAccount as String] = BrowserPasswords.account(site: site, username: username)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw BrowserPasswordError.notFound(site: site, username: username, org: org)
        }
        try require(status, "delete")
    }

    // MARK: Internals

    /// Nil when there is no such item. Every item that comes back is checked (ruling 4).
    private func read(org: String, site: String, username: String) throws -> String? {
        let service = try BrowserPasswords.service(org: org)
        let account = BrowserPasswords.account(site: site, username: username)
        var query = try base(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try require(status, "read")
        guard let item = result as? [String: Any] else {
            throw BrowserPasswords.error(operation: "read", status: errSecInternalError)
        }
        try BrowserPasswords.check(service: item[kSecAttrService as String] as? String ?? "",
                                   account: item[kSecAttrAccount as String] as? String ?? "",
                                   org: org, site: site)
        guard let data = item[kSecValueData as String] as? Data else {
            throw BrowserPasswords.error(operation: "read", status: errSecInternalError)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func base(service: String, forAdd: Bool = false) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        guard let keychainFile else { return query }
        guard FileManager.default.fileExists(atPath: keychainFile) else {
            throw BrowserPasswordError.noKeychainFile(keychainFile)
        }
        let keychain = try Self.openKeychain(keychainFile)
        if forAdd { query[kSecUseKeychain as String] = keychain }
        else { query[kSecMatchSearchList as String] = [keychain] }
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    /// An unreadable file still opens as a reference, and an add naming it would fall back to the default
    /// (login) keychain. So the status is asked for first, and a file that is not a keychain is refused.
    static func openKeychain(_ path: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let opened = SecKeychainOpen(path, &keychain)
        guard opened == errSecSuccess, let keychain else {
            throw keychainError(operation: "open the keychain", status: opened)
        }
        var keychainStatus: SecKeychainStatus = 0
        let statusResult = SecKeychainGetStatus(keychain, &keychainStatus)
        guard statusResult == errSecSuccess else {
            throw keychainError(operation: "open the keychain", status: statusResult)
        }
        return keychain
    }

    private func require(_ status: OSStatus, _ operation: String) throws {
        guard status == errSecSuccess else { throw Self.keychainError(operation: operation, status: status) }
    }

    /// From the status and the system's own sentence only; nothing the caller held can reach it.
    static func keychainError(operation: String, status: OSStatus) -> BrowserPasswordError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
        return .keychain(operation: operation, status: status, message: message)
    }
}

private extension BrowserPasswords {
    static func error(operation: String, status: OSStatus) -> BrowserPasswordError {
        BrowserPasswordStore.keychainError(operation: operation, status: status)
    }
}
