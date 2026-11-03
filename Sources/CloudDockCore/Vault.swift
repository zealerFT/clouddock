import Foundation
import Security
import LocalAuthentication

public struct KeychainCredentialStore: CredentialBackend {
    private static let service = "app.clouddock.credentials.v1"
    public init() {}
    public func save(_ credentials: Credentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    public func load(id: UUID) throws -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    public func remove(id: UUID, allowInteraction: Bool) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service, kSecAttrAccount as String: id.uuidString]
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> CloudError {
        switch status {
        case errSecUserCanceled:
            return .message("访问凭据的系统授权已取消。连接名称和地址仍保留，密钥尚未读取；请在编辑连接中重新授权或填写访问凭据。")
        case errSecAuthFailed:
            return .message("系统未允许 CloudDock 读取访问凭据。请在编辑连接中重新授权或填写访问凭据。")
        case errSecInteractionNotAllowed:
            return .message("钥匙串当前锁定或无法显示授权窗口。请解锁 Mac 后，在编辑连接中重试。")
        case errSecItemNotFound:
            return .message("未找到这个连接的访问凭据。请编辑连接，重新填写并保存。")
        default:
            return .message("访问凭据暂不可用（系统错误 \(status)）：" + ((SecCopyErrorMessageString(status, nil) as String?) ?? "请重试。"))
        }
    }
}
