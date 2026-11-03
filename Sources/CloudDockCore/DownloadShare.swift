import Foundation

public enum ShareTimeUnit: String, CaseIterable, Identifiable, Sendable {
    case minutes = "分钟", hours = "小时", days = "天"
    public var id: String { rawValue }
    public var seconds: Int { self == .minutes ? 60 : self == .hours ? 3600 : 86400 }
}

public enum SharePolicy {
    public static let maximumSeconds = 7 * 24 * 60 * 60
    public static func duration(amount: Int, unit: ShareTimeUnit) throws -> Int {
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: unit.seconds)
        guard !overflow else { throw CloudError.message("分享有效期应为 1 分钟至 7 天。") }
        try validate(seconds: seconds)
        return seconds
    }
    public static func validate(seconds: Int) throws {
        guard seconds >= 60, seconds <= maximumSeconds else { throw CloudError.message("分享有效期应为 1 分钟至 7 天。") }
    }
}

public struct DownloadShare: Sendable {
    /// Preserve the signed bytes exactly for copy, QR and download; never rebuild the URL.
    public let address: String
    /// nil only for anonymous local emulator links, which do not enforce expiry.
    public let expiresAt: Date?

    public init(address: String, now: Date = Date()) throws {
        let parts = try Self.validateAddress(address)
        let parameters = Dictionary((parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { _, _ in "" })
        let expiration: Date?
        let prefix = parameters["x-goog-signature"] != nil ? "x-goog-" : parameters["x-oss-signature"] != nil ? "x-oss-" : "x-amz-"
        if prefix == "x-goog-" {
            guard parameters["x-goog-algorithm"] == "GOOG4-RSA-SHA256",
                  parameters["x-goog-credential"]?.isEmpty == false,
                  parameters["x-goog-signedheaders"]?.split(separator: ";").contains("host") == true else {
                throw CloudError.message("Google 下载分享签名参数不完整。")
            }
        }
        if let stamp = parameters[prefix + "date"],
           let durationText = parameters[prefix + "expires"], let duration = Int(durationText),
           duration > 0, duration <= SharePolicy.maximumSeconds,
           let signature = parameters[prefix + "signature"], !signature.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.isLenient = false
            expiration = formatter.date(from: stamp)?.addingTimeInterval(TimeInterval(duration))
        } else if let value = parameters["expires"], let timestamp = TimeInterval(value), timestamp.isFinite,
                  let signature = parameters["signature"], !signature.isEmpty {
            expiration = Date(timeIntervalSince1970: timestamp)
        } else { expiration = nil }
        guard let expiration, expiration > now, expiration.timeIntervalSince(now) <= Double(SharePolicy.maximumSeconds + 60) else {
            throw CloudError.message("该服务未返回可验证有效期的临时签名地址，无法创建下载分享。")
        }
        self.address = address; expiresAt = expiration
    }

    init(localEmulatorAddress address: String) throws {
        _ = try Self.validateAddress(address)
        self.address = address; expiresAt = nil
    }

    private static func validateAddress(_ address: String) throws -> URLComponents {
        guard let parts = URLComponents(string: address), let url = parts.url,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              !(parts.host?.isEmpty ?? true), parts.user == nil, parts.password == nil,
              parts.fragment == nil, url.absoluteString == address else {
            throw CloudError.message("存储服务未返回有效的下载地址。")
        }
        return parts
    }
}

extension StorageEngine {
    public func shareDownload(connection: Connection, credentials: Credentials, bucket: String, key: String,
                              validFor seconds: Int, now: Date = Date()) async throws -> DownloadShare {
        try SharePolicy.validate(seconds: seconds)
        try Task.checkCancellation()
        guard !bucket.isEmpty, !key.isEmpty else { throw CloudError.message("请选择要分享的文件。") }
        let remote = try ObjectPath.remote(bucket: bucket, key: key)
        if connection.provider == .google {
            return try GoogleDownloadShare.create(connection: connection, credentials: credentials, bucket: bucket, key: key,
                                                  seconds: seconds, now: now)
        }
        let data = try await run(["link", remote, "--expire", "\(seconds)s"], connection: connection, credentials: credentials)
        let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try DownloadShare(address: address)
    }
}
