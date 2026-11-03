import Foundation

public protocol CredentialBackend {
    func load(id: UUID) throws -> Credentials?
    func save(_ credentials: Credentials, id: UUID) throws
    func remove(id: UUID, allowInteraction: Bool) throws
}

/// Routes by connection. A local connection never falls back to Keychain.
public final class CredentialStore {
    private let local: any CredentialBackend
    private let keychain: any CredentialBackend
    public init(local: any CredentialBackend = LocalCredentialStore(), keychain: any CredentialBackend = KeychainCredentialStore()) {
        self.local = local; self.keychain = keychain
    }
    private func backend(_ storage: CredentialStorage) -> any CredentialBackend { storage == .local ? local : keychain }
    public func read(for connection: Connection) throws -> Credentials {
        guard let credentials = try backend(connection.credentialStorage).load(id: connection.id) else {
            throw CloudError.message("未找到这个连接的访问凭据。请编辑连接，重新填写并保存。")
        }
        return credentials
    }

    /// Commit configuration only after target credentials are durable. Never remove the source first.
    /// nil means retain the existing secret without reading it (e.g. renaming a Keychain connection).
    @discardableResult
    public func save(_ credentials: Credentials?, connection: Connection, replacing previous: Connection?,
                     commit: () throws -> Void) throws -> String? {
        try connection.validateConfiguration()
        if let previous, previous.id != connection.id { throw CloudError.message("连接标识不匹配，未修改凭据。") }
        guard let credentials else {
            guard let previous, previous.credentialStorage == connection.credentialStorage, previous.provider == connection.provider else {
                throw CloudError.message("切换保存方式或存储服务前，请读取已保存凭据，或重新填写完整访问凭据。")
            }
            try commit()
            return nil
        }
        try connection.validate(credentials)
        let destination = backend(connection.credentialStorage)
        let backup = try destination.load(id: connection.id)
        try destination.save(credentials, id: connection.id)
        do { try commit() }
        catch {
            do {
                if let backup { try destination.save(backup, id: connection.id) }
                else { try destination.remove(id: connection.id, allowInteraction: true) }
            } catch let rollback {
                throw CloudError.message("连接保存失败，凭据恢复也未完成，请检查后重试：\(error.localizedDescription)；\(rollback.localizedDescription)")
            }
            throw error
        }
        if let previous, previous.credentialStorage != connection.credentialStorage {
            do { try backend(previous.credentialStorage).remove(id: previous.id, allowInteraction: false) }
            catch {
                return "连接已改为\(connection.credentialStorage.title)保存；原\(previous.credentialStorage.title)中的旧凭据副本未能移除。当前连接使用新位置，旧副本仍保留。"
            }
        }
        return nil
    }

    public func remove(_ connection: Connection, commit: () throws -> Void) throws {
        let source = backend(connection.credentialStorage)
        let backup = try source.load(id: connection.id)
        try source.remove(id: connection.id, allowInteraction: true)
        do { try commit() }
        catch {
            if let backup {
                do { try source.save(backup, id: connection.id) }
                catch let rollback { throw CloudError.message("移除连接失败，凭据恢复也未完成：\(error.localizedDescription)；\(rollback.localizedDescription)") }
            }
            throw error
        }
    }
}
