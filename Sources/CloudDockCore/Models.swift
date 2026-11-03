import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case minio, aws, aliyun, google, compatible
    /// Providers exposed by the connection creation form.
    public static var newConnectionCases: [Provider] { allCases }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .minio: return "MinIO"
        case .aws: return "Amazon S3"
        case .aliyun: return "阿里云 OSS"
        case .google: return "Google Cloud Storage"
        case .compatible: return "S3 兼容存储"
        }
    }
    public var shortName: String {
        switch self {
        case .minio: return "MINIO"
        case .aws: return "AWS"
        case .aliyun: return "OSS"
        case .google: return "GCS"
        case .compatible: return "S3"
        }
    }
    public var rcloneProvider: String {
        switch self {
        case .minio: return "Minio"
        case .aws: return "AWS"
        case .aliyun: return "Alibaba"
        default: return "Other"
        }
    }
}

public enum CredentialStorage: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, keychain
    public var id: String { rawValue }
    public var title: String { self == .local ? "软件本机" : "macOS 钥匙串" }
}

public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: Provider
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var projectNumber: String
    public var pathStyle: Bool
    public var credentialStorage: CredentialStorage
    public init(id: UUID = UUID(), name: String = "", provider: Provider = .minio,
                endpoint: String = "", region: String = "", bucket: String = "",
                projectNumber: String = "", pathStyle: Bool = true, credentialStorage: CredentialStorage = .local) {
        self.id = id; self.name = name; self.provider = provider; self.endpoint = endpoint
        self.region = region; self.bucket = bucket; self.projectNumber = projectNumber; self.pathStyle = pathStyle
        self.credentialStorage = credentialStorage
    }
    enum CodingKeys: String, CodingKey {
        case id, name, provider, endpoint, region, bucket, projectNumber, pathStyle, credentialStorage
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decode(Provider.self, forKey: .provider)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        region = try values.decode(String.self, forKey: .region)
        bucket = try values.decode(String.self, forKey: .bucket)
        projectNumber = try values.decode(String.self, forKey: .projectNumber)
        pathStyle = try values.decode(Bool.self, forKey: .pathStyle)
        credentialStorage = try values.decodeIfPresent(CredentialStorage.self, forKey: .credentialStorage) ?? .keychain
    }
    /// Literal IPs and localhost cannot reliably route bucket-prefixed hostnames.
    /// Apply this at request time too, so existing saved connections need no migration.
    public var requiresPathStyle: Bool {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else { return false }
        if host == "localhost" || host.contains(":") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (0...255).contains(Int($0) ?? -1) }
    }
    public var usesPathStyle: Bool { pathStyle || requiresPathStyle }
    public var isLocalGoogleEndpoint: Bool { provider == .google && !endpoint.isEmpty && requiresPathStyle }
    /// rclone resolves relative JSON API paths against this URL, so the suffix
    /// and trailing slash are required even for connections saved by older apps.
    public var googleAPIEndpoint: String {
        guard isLocalGoogleEndpoint, var parts = URLComponents(string: endpoint) else { return endpoint }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "storage/v1" else { return endpoint }
        parts.path = "/storage/v1/"
        return parts.url?.absoluteString ?? endpoint
    }
    public func validate(_ secrets: Credentials) throws {
        try validateConfiguration()
        if provider == .google {
            // The local fake-gcs-server fixture exposes the JSON API without
            // Google OAuth. Keep this exception limited to localhost/IP
            // endpoints; hosted Google connections still require a service
            // account JSON document.
            if !endpoint.isEmpty && requiresPathStyle { return }
            guard let data = secrets.serviceAccountJSON.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["type"] as? String == "service_account",
                  (value["client_email"] as? String)?.isEmpty == false,
                  (value["private_key"] as? String)?.isEmpty == false else {
                throw CloudError.message("请选择有效的 Google 服务账号 JSON（包含 client_email 和 private_key）。")
            }
        } else if secrets.accessKey.isEmpty || secrets.secretKey.isEmpty {
            throw CloudError.message("请填写 Access Key ID 和 Secret Access Key。")
        }
    }
    public func validateConfiguration() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.message("请填写连接名称。") }
        if !bucket.isEmpty { try ObjectPath.validateComponent(bucket) }
        if !endpoint.isEmpty {
            let path = URLComponents(string: endpoint)?.path ?? ""
            let isLocalGoogleAPI = provider == .google && requiresPathStyle
                && path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "storage/v1"
            guard let url = URLComponents(string: endpoint), ["https", "http"].contains(url.scheme),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" || isLocalGoogleAPI else {
                throw CloudError.message(isLocalGoogleAPI
                    ? "本地 Google Endpoint 应使用 http(s)://主机:端口/storage/v1/。"
                    : "Endpoint 应为 http(s)://主机:端口，不含 bucket、路径或密钥。")
            }
        } else if [.minio, .aliyun, .compatible].contains(provider) {
            throw CloudError.message("请填写该服务的 Endpoint。")
        }
    }
}

public struct Credentials: Codable, Equatable, Sendable {
    public var accessKey: String = ""
    public var secretKey: String = ""
    public var sessionToken: String = ""
    public var serviceAccountJSON: String = ""
    public var isEmpty: Bool { accessKey.isEmpty && secretKey.isEmpty && sessionToken.isEmpty && serviceAccountJSON.isEmpty }
    public init(accessKey: String = "", secretKey: String = "", sessionToken: String = "", serviceAccountJSON: String = "") {
        self.accessKey = accessKey; self.secretKey = secretKey; self.sessionToken = sessionToken; self.serviceAccountJSON = serviceAccountJSON
    }
    public func redact(_ text: String) -> String {
        var value = text
        for secret in [accessKey, secretKey, sessionToken, serviceAccountJSON] where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        if let data = serviceAccountJSON.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["private_key", "private_key_id", "client_email"] {
                if let secret = json[key] as? String, !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[已隐藏]") }
            }
        }
        return value
    }
}

public enum CloudError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public enum ObjectPath {
    public static func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CloudError.message("名称不能是空白、.、.. 或包含斜杠及空字符。")
        }
    }
    public static func validateRelative(_ path: String) throws {
        if path.isEmpty { return }
        guard !path.hasPrefix("/") else { throw CloudError.message("对象路径不能以 / 开头。") }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) { try validateComponent(String(segment)) }
    }
    public static func join(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : parent.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + child
    }
    public static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    public static func remote(bucket: String, key: String = "") throws -> String {
        if !bucket.isEmpty { try validateComponent(bucket) }
        try validateRelative(key)
        guard !bucket.isEmpty || key.isEmpty else { throw CloudError.message("请先选择存储桶。") }
        return "cloud:" + join(bucket, key)
    }
}

public struct RemoteEntry: Decodable, Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let size: Int64
    public let modified: String
    public let isDirectory: Bool
    public let mimeType: String?
    public init(path: String, name: String? = nil, size: Int64 = -1, modified: String = "", isDirectory: Bool = false, mimeType: String? = nil) {
        self.path = path; self.name = name ?? path.split(separator: "/").last.map(String.init) ?? path
        self.size = size; self.modified = modified; self.isDirectory = isDirectory; self.mimeType = mimeType
    }
    public var id: String { (isDirectory ? "directory:" : "object:") + path }
    enum CodingKeys: String, CodingKey {
        case path = "Path", name = "Name", size = "Size", modified = "ModTime", isDirectory = "IsDir", mimeType = "MimeType"
    }
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: modified) ?? ISO8601DateFormatter().date(from: modified)
    }
}

public struct Favorite: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var connectionID: UUID
    public var bucket: String
    public var prefix: String
    public var title: String
    public init(connectionID: UUID, bucket: String, prefix: String, title: String) {
        self.connectionID = connectionID; self.bucket = bucket; self.prefix = prefix; self.title = title
    }
}

public struct TransferStats: Decodable, Sendable {
    public var bytes: Int64?
    public var totalBytes: Int64?
    public var speed: Double?
    public var eta: Double?
    public var transfers: Int?
    public var totalTransfers: Int?
    public var checks: Int?
}

public struct CommandResult: Sendable {
    public let data: Data
    public let stats: TransferStats?
}

public struct TransferSummary: Sendable {
    public let status: AuditStatus
    public let detail: String
    public init(stats: TransferStats?, skipsExisting: Bool, singleFile: Bool = false) {
        guard let stats, let count = stats.transfers else {
            status = .completed; detail = "操作已完成，未取得文件计数。"; return
        }
        // rclone copyto returns before incrementing checks when an existing file is skipped.
        // A successful single-file command with zero transfers therefore skipped that file.
        let skipped = skipsExisting ? max(stats.checks ?? 0, singleFile && count == 0 ? 1 : 0) : 0
        if count == 0 && skipped > 0 {
            status = .skipped; detail = "跳过 \(skipped) 个同名文件，已有内容保持不变。"
        } else if count > 0 && skipped > 0 {
            status = .mixed; detail = "已传输 \(count) 个文件，跳过 \(skipped) 个同名文件。"
        } else {
            status = .completed; detail = count == 0 ? "目录处理完成，没有文件需要传输。" : "已传输 \(count) 个文件。"
        }
    }
}
