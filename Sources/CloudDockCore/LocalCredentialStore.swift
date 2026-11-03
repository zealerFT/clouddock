import Foundation
import CryptoKit
import Darwin

/// Local encryption prevents credentials leaking through state.json or casual inspection.
/// The encryption key is also local: protection ultimately depends on the macOS user account.
public final class LocalCredentialStore: CredentialBackend, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let magic = Data("CDV1".utf8)
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudDock/Credentials", isDirectory: true)
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".vault") }
    private var keyFile: URL { directory.appendingPathComponent("encryption.key") }

    public func load(id: UUID) throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: file(id).path) else { return nil }
        let data = try Data(contentsOf: file(id))
        let key = try encryptionKey(create: false)
        do {
            guard data.starts(with: magic) else { throw CloudError.message("格式不符") }
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count)))
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
            return try JSONDecoder().decode(Credentials.self, from: plaintext)
        } catch { throw CloudError.message("本机凭据无法解密，原文件已保留。请从备份恢复完整的 Credentials 凭据目录。") }
    }
    public func save(_ credentials: Credentials, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        let key = try encryptionKey(create: true)
        let box = try AES.GCM.seal(JSONEncoder().encode(credentials), using: key, authenticating: Data(id.uuidString.utf8))
        guard let combined = box.combined else { throw CloudError.message("无法加密本机凭据。") }
        try writePrivate(magic + combined, to: file(id))
    }
    public func remove(id: UUID, allowInteraction: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: file(id).path) { try FileManager.default.removeItem(at: file(id)) }
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CloudError.message("凭据目录不可用，请检查本机文件权限。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyFile.path) {
            let data = try Data(contentsOf: keyFile)
            guard data.count == 32 else { throw CloudError.message("本机凭据的加密密钥已损坏，请从备份恢复 Credentials 目录。") }
            return SymmetricKey(data: data)
        }
        guard create else { throw CloudError.message("本机凭据的加密密钥缺失，请从备份恢复 Credentials 目录。") }
        let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !existing.contains(where: { $0.pathExtension == "vault" }) else {
            throw CloudError.message("已有加密凭据但解密密钥缺失，未生成替代密钥。请从备份恢复 Credentials 目录。")
        }
        let key = SymmetricKey(size: .bits256)
        try writePrivate(key.withUnsafeBytes { Data($0) }, to: keyFile)
        return key
    }
    private func writePrivate(_ data: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CloudError.message("无法创建本机凭据文件，请检查目录权限。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw CloudError.message("无法保存本机凭据，原文件保持不变。") }
    }
}
