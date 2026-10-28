import Foundation
import Testing
@testable import WakilKit

struct BrowserPasswordStoreTests {
    private func withStore(_ body: (BrowserPasswordStore, TemporaryKeychain) throws -> Void) throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.remove() }
        try body(BrowserPasswordStore(keychainFile: keychain.path), keychain)
    }

    @Test func aSavedLoginReadsBack() throws {
        try withStore { store, _ in
            let outcome = try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
            #expect(outcome == .added)
            #expect(try store.password(org: "initech", site: "example.com", username: "ann") == "walk-test-pass-1")
        }
    }

    @Test func savingTheSamePasswordIsUnchangedAndANewOneUpdates() throws {
        try withStore { store, _ in
            try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
            #expect(try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1") == .unchanged)
            #expect(try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-2") == .updated)
            #expect(try store.password(org: "initech", site: "example.com", username: "ann") == "walk-test-pass-2")
        }
    }

    @Test func loginsListsAttributesOnlySortedBySite() throws {
        try withStore { store, _ in
            try store.save(org: "initech", site: "b.com", username: "zed", password: "walk-test-pass-1")
            try store.save(org: "initech", site: "a.com", username: "bob", password: "walk-test-pass-1")
            try store.save(org: "initech", site: "a.com", username: "amy two", password: "walk-test-pass-1")
            let all = try store.logins(org: "initech", site: nil)
            #expect(all.map(\.site) == ["a.com", "a.com", "b.com"])
            #expect(all.map(\.username) == ["amy two", "bob", "zed"])
            #expect(all.allSatisfy { $0.org == "initech" && $0.modified != nil })
            #expect(try store.logins(org: "initech", site: "b.com").map(\.username) == ["zed"])
            #expect(try store.logins(org: "initech", site: "c.com").isEmpty)
        }
    }

    @Test func anotherOrganisationsLoginIsNeverReturned() throws {
        try withStore { store, _ in
            try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
            try store.save(org: "umbrella", site: "example.com", username: "ann", password: "walk-test-pass-2")
            #expect(try store.logins(org: "initech", site: nil).count == 1)
            #expect(try store.logins(org: "umbrella", site: nil).count == 1)
            #expect(try store.password(org: "initech", site: "example.com", username: "ann") == "walk-test-pass-1")
            #expect(try store.password(org: "umbrella", site: "example.com", username: "ann") == "walk-test-pass-2")
        }
    }

    @Test func anOrganisationWithAColonIsRefused() throws {
        try withStore { store, _ in
            #expect(throws: BrowserPasswordError.badOrganisation("a:b")) {
                try store.save(org: "a:b", site: "example.com", username: "ann", password: "walk-test-pass-1")
            }
            #expect(throws: BrowserPasswordError.badOrganisation("a:b")) { try store.logins(org: "a:b", site: nil) }
        }
    }

    @Test func renameMovesTheItemAndDeletesTheOld() throws {
        try withStore { store, _ in
            try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
            try store.rename(org: "initech", site: "example.com", from: "ann", to: "ann b", password: nil)
            #expect(try store.logins(org: "initech", site: nil).map(\.username) == ["ann b"])
            #expect(try store.password(org: "initech", site: "example.com", username: "ann b") == "walk-test-pass-1")
            try store.rename(org: "initech", site: "example.com", from: "ann b", to: "cy", password: "walk-test-pass-2")
            #expect(try store.logins(org: "initech", site: nil).map(\.username) == ["cy"])
            #expect(try store.password(org: "initech", site: "example.com", username: "cy") == "walk-test-pass-2")
        }
    }

    @Test func deleteRemovesOneLogin() throws {
        try withStore { store, _ in
            try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
            try store.save(org: "initech", site: "example.com", username: "bob", password: "walk-test-pass-1")
            try store.delete(org: "initech", site: "example.com", username: "ann")
            #expect(try store.logins(org: "initech", site: nil).map(\.username) == ["bob"])
        }
    }

    @Test func aMissingLoginIsNotFoundNamingTheOrg() throws {
        try withStore { store, _ in
            #expect(throws: BrowserPasswordError.notFound(site: "example.com", username: "ann", org: "initech")) {
                try store.password(org: "initech", site: "example.com", username: "ann")
            }
            #expect(throws: BrowserPasswordError.notFound(site: "example.com", username: "ann", org: "initech")) {
                try store.delete(org: "initech", site: "example.com", username: "ann")
            }
        }
    }

    @Test func aMissingKeychainFileIsRefusedNotReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wakil-nokc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("absent.keychain-db").path
        let store = BrowserPasswordStore(keychainFile: path)
        #expect(throws: BrowserPasswordError.noKeychainFile(path)) {
            try store.save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        }
        #expect(throws: BrowserPasswordError.noKeychainFile(path)) { try store.logins(org: "initech", site: nil) }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func theStoreWritesOnlyToItsKeychainFile() throws {
        let first = try TemporaryKeychain()
        let second = try TemporaryKeychain()
        defer { first.remove(); second.remove() }
        try BrowserPasswordStore(keychainFile: first.path)
            .save(org: "initech", site: "example.com", username: "ann", password: "walk-test-pass-1")
        #expect(try BrowserPasswordStore(keychainFile: second.path).logins(org: "initech", site: nil).isEmpty)
        #expect(try BrowserPasswordStore(keychainFile: first.path).logins(org: "initech", site: nil).count == 1)
    }

    @Test func theEnvironmentNamesTheKeychainAndEmptyMeansUnset() throws {
        let keychain = try TemporaryKeychain()
        defer { keychain.remove() }
        #expect(BrowserPasswordStore(environment: ["WAKIL_KEYCHAIN": keychain.path]).keychainFile == keychain.path)
        #expect(BrowserPasswordStore(environment: ["WAKIL_KEYCHAIN": ""]).keychainFile == nil)
        #expect(BrowserPasswordStore(environment: [:]).keychainFile == nil)
    }

    @Test func keychainErrorsNeverCarryTheValue() throws {
        let keychain = try TemporaryKeychain()
        let store = BrowserPasswordStore(keychainFile: keychain.path)
        // A keychain deleted under the store fails every call without a lock or a dialog.
        try TemporaryKeychain.security(["delete-keychain", keychain.path])
        defer { keychain.remove() }
        let password = "walk-test-pass-1"
        do {
            try store.save(org: "initech", site: "example.com", username: "ann", password: password)
            Issue.record("a save on a deleted keychain should have thrown")
        } catch {
            for text in [String(describing: error), error.localizedDescription, "\(error)", String(reflecting: error)] {
                #expect(!text.contains(password))
            }
        }
    }

    @Test func aKeychainFileThatIsNotOneFailsWithTheStatusAndNotTheValue() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wakil-junk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("junk.keychain-db").path
        try Data("not a keychain".utf8).write(to: URL(fileURLWithPath: path))
        let password = "walk-test-pass-1"
        do {
            try BrowserPasswordStore(keychainFile: path)
                .save(org: "initech", site: "example.com", username: "ann", password: password)
            Issue.record("a save on a file that is not a keychain should have thrown")
        } catch let error as BrowserPasswordError {
            guard case .keychain = error else { Issue.record("expected .keychain, got \(error)"); return }
            #expect(!String(describing: error).contains(password))
            #expect(!error.localizedDescription.contains(password))
        }
    }

    @Test func theErrorBuiltFromAStatusCarriesNoValue() {
        let error = BrowserPasswordStore.keychainError(operation: "save", status: -25308)
        guard case .keychain(let operation, let status, let message) = error else {
            Issue.record("expected .keychain"); return
        }
        #expect(operation == "save")
        #expect(status == -25308)
        #expect(!message.isEmpty)
        #expect(!String(describing: error).contains("walk-test-pass-1"))
    }
}
