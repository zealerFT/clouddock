import Foundation
import CloudDockCore

private final class FixtureCredentialBackend: CredentialBackend {
    var values: [UUID: Credentials] = [:]
    var reads = 0, writes = 0, removals = 0
    var denyRead = false, denyWrite = false, denyRemove = false
    var removalInteraction: [Bool] = []
    func load(id: UUID) throws -> Credentials? {
        reads += 1
        if denyRead { throw CloudError.message("fixture read denied") }
        return values[id]
    }
    func save(_ credentials: Credentials, id: UUID) throws {
        writes += 1
        if denyWrite { throw CloudError.message("fixture write denied") }
        values[id] = credentials
    }
    func remove(id: UUID, allowInteraction: Bool) throws {
        removals += 1; removalInteraction.append(allowInteraction)
        if denyRemove { throw CloudError.message("fixture remove denied") }
        values.removeValue(forKey: id)
    }
}

final class CredentialChecks {
    private let original = Credentials(accessKey: "fixture-access", secretKey: "fixture-secret", sessionToken: "fixture-token", serviceAccountJSON: "fixture-json")
    private let replacement = Credentials(accessKey: "new-fixture-access", secretKey: "new-fixture-secret")
    private func connection(storage: CredentialStorage = .local) -> Connection {
        Connection(name: "credential fixture", endpoint: "http://127.0.0.1:9000", credentialStorage: storage)
    }

    func testDefaultsAndLegacyConnectionDecoding() throws {
        let current = connection()
        expectEqual(current.credentialStorage, .local)
        let encoded = try JSONEncoder().encode(current)
        expectEqual(try JSONDecoder().decode(Connection.self, from: encoded), current)
        var legacy = try required(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "credentialStorage")
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONSerialization.data(withJSONObject: legacy))
        expectEqual(decoded.credentialStorage, .keychain)
        expectEqual(decoded.id, current.id)
        var explicit = current; explicit.credentialStorage = .keychain
        expectEqual(try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(explicit)), explicit)
        legacy["credentialStorage"] = "unknown-store"
        expectThrows(try JSONDecoder().decode(Connection.self, from: JSONSerialization.data(withJSONObject: legacy)))
        expectFalse(String(decoding: encoded, as: UTF8.self).contains("secretKey"))
    }

    func testLocalEncryptionPersistenceAndIntegrity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clouddock-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = LocalCredentialStore(directory: folder)
        let first = UUID(), second = UUID()
        expectNil(try local.load(id: first))
        expectFalse(FileManager.default.fileExists(atPath: folder.path))
        try local.save(original, id: first)
        expectEqual(try LocalCredentialStore(directory: folder).load(id: first), original)
        let file = folder.appendingPathComponent(first.uuidString + ".vault")
        let initial = try Data(contentsOf: file)
        expectNil(initial.range(of: Data(original.secretKey.utf8)))
        expectNil(initial.range(of: Data(original.accessKey.utf8)))
        expectNil(initial.range(of: Data(original.serviceAccountJSON.utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        expectEqual(permissions?.intValue, 0o700)
        for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let mode = try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions] as? NSNumber
            expectEqual(mode?.intValue, 0o600)
        }
        try local.save(replacement, id: first)
        expectEqual(try local.load(id: first), replacement)
        let updated = try Data(contentsOf: file)
        expectFalse(updated == initial)
        try local.save(original, id: second)
        let otherFile = folder.appendingPathComponent(second.uuidString + ".vault")
        try updated.write(to: otherFile)
        expectThrows(try local.load(id: second), "Ciphertext copied across connection IDs must fail authentication")
        var tampered = updated; tampered[tampered.count - 1] ^= 1
        try tampered.write(to: file)
        expectThrows(try local.load(id: first))
        expectEqual(try Data(contentsOf: file), tampered)
        try updated.write(to: file)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("encryption.key"))
        expectThrows(try local.load(id: first))
        expectThrows(try local.save(original, id: first))
        expectEqual(try Data(contentsOf: file), updated)
        expectFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("encryption.key").path))
        try local.remove(id: first, allowInteraction: false)
        expectNil(try local.load(id: first))
    }

    func testLocalIsolationAndMetadataOnlyChanges() throws {
        let local = FixtureCredentialBackend(), keychain = FixtureCredentialBackend()
        keychain.denyRead = true; keychain.denyWrite = true; keychain.denyRemove = true
        let store = CredentialStore(local: local, keychain: keychain)
        let c = connection()
        var commits = 0
        try store.save(original, connection: c, replacing: nil) { commits += 1 }
        expectEqual(try store.read(for: c), original)
        try store.save(replacement, connection: c, replacing: c) { commits += 1 }
        expectEqual(try store.read(for: c), replacement)
        try store.remove(c) { commits += 1 }
        expectEqual(commits, 3)
        expectEqual(keychain.reads + keychain.writes + keychain.removals, 0)
        // Changing only a saved connection name must not trigger Keychain authorization.
        let old = connection(storage: .keychain)
        var renamed = old; renamed.name = "renamed"
        try store.save(nil, connection: renamed, replacing: old) { commits += 1 }
        expectEqual(keychain.reads + keychain.writes + keychain.removals, 0)
        var moved = old; moved.credentialStorage = .local
        expectThrows(try store.save(nil, connection: moved, replacing: old) { commits += 1 })
        expectEqual(commits, 4)
        expectThrows(try store.read(for: c))
        expectEqual(keychain.reads, 0, file: #file, line: #line)
    }

    func testMigrationAndRollback() throws {
        let local = FixtureCredentialBackend(), keychain = FixtureCredentialBackend()
        let store = CredentialStore(local: local, keychain: keychain)
        let old = connection(storage: .keychain)
        var moved = old; moved.credentialStorage = .local
        keychain.values[old.id] = original
        keychain.denyRead = true
        // User can re-enter credentials and switch to local even when old Keychain reads are denied.
        let warning = try store.save(replacement, connection: moved, replacing: old) {
            expectEqual(keychain.values[old.id], self.original)
            expectEqual(local.values[old.id], self.replacement)
        }
        expectNil(warning)
        expectEqual(keychain.reads, 0)
        expectEqual(keychain.removalInteraction, [false])
        expectNil(keychain.values[old.id])
        expectEqual(try store.read(for: moved), replacement)

        keychain.denyRead = false; keychain.denyWrite = true
        var committed = false
        expectThrows(try store.save(original, connection: old, replacing: moved) { committed = true })
        expectFalse(committed)
        expectEqual(local.values[old.id], replacement)
        keychain.denyWrite = false
        try store.save(original, connection: old, replacing: moved) {
            expectEqual(local.values[old.id], self.replacement)
            expectEqual(keychain.values[old.id], self.original)
        }
        expectNil(local.values[old.id])
        expectEqual(try store.read(for: old), original)

        // Configuration-save failure restores any prior target value and preserves the source.
        local.values[old.id] = replacement
        expectThrows(try store.save(original, connection: moved, replacing: old) { throw CloudError.message("fixture commit denied") })
        expectEqual(local.values[old.id], replacement)
        expectEqual(keychain.values[old.id], original)
        local.values.removeValue(forKey: old.id)
        expectThrows(try store.save(original, connection: moved, replacing: old) { throw CloudError.message("fixture commit denied") })
        expectNil(local.values[old.id])
        expectEqual(keychain.values[old.id], original)

        // Cleanup denial does not undo a committed migration or discard either copy.
        keychain.denyRemove = true
        let cleanup = try store.save(replacement, connection: moved, replacing: old) { committed = true }
        expectTrue(committed)
        expectTrue(cleanup?.contains("旧凭据副本未能移除") == true)
        expectEqual(keychain.values[old.id], original)
        expectEqual(try store.read(for: moved), replacement)
        expectThrows(try store.remove(moved) { throw CloudError.message("fixture delete commit denied") })
        expectEqual(try store.read(for: moved), replacement)
    }
}
