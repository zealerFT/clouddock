import Foundation
import CryptoKit

enum GoogleDownloadShare {
    static func create(connection: Connection, credentials: Credentials, bucket: String, key: String,
                       seconds: Int, now: Date) throws -> DownloadShare {
        try connection.validateConfiguration()
        if connection.isLocalGoogleEndpoint {
            // The emulator is anonymous and ignores signatures/expiration. Use
            // its media API and do not claim this URL has an enforced expiry.
            guard var parts = URLComponents(string: connection.googleAPIEndpoint) else {
                throw CloudError.message("Google 本地测试 Endpoint 无效。")
            }
            parts.percentEncodedPath = "/download/storage/v1/b/" + ObjectListingClient.encode(bucket) + "/o/" + ObjectListingClient.encode(key)
            parts.percentEncodedQuery = "alt=media"
            guard let address = parts.url?.absoluteString else { throw CloudError.message("无法构造下载地址。") }
            return try DownloadShare(localEmulatorAddress: address)
        }

        // V4 signed URLs use the XML endpoint, not /storage/v1 or an OAuth token.
        let account = try GoogleServiceAccount(credentials: credentials)
        guard var parts = URLComponents(string: connection.endpoint.isEmpty ? "https://storage.googleapis.com" : connection.endpoint),
              let host = parts.host else { throw CloudError.message("Google Endpoint 无效。") }
        parts.percentEncodedPath = "/" + ([bucket] + key.components(separatedBy: "/")).map(ObjectListingClient.encode).joined(separator: "/")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        let scope = String(stamp.prefix(8)) + "/auto/storage/goog4_request"
        let query = ObjectListingClient.query([
            ("X-Goog-Algorithm", "GOOG4-RSA-SHA256"), ("X-Goog-Credential", account.email + "/" + scope),
            ("X-Goog-Date", stamp), ("X-Goog-Expires", String(seconds)), ("X-Goog-SignedHeaders", "host")
        ])
        let authority = host + (parts.port.map { ":\($0)" } ?? "")
        let canonical = "GET\n\(parts.percentEncodedPath)\n\(query)\nhost:\(authority)\n\nhost\nUNSIGNED-PAYLOAD"
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let signing = "GOOG4-RSA-SHA256\n\(stamp)\n\(scope)\n\(digest)"
        let signature = try account.sign(Data(signing.utf8)).map { String(format: "%02x", $0) }.joined()
        parts.percentEncodedQuery = query + "&X-Goog-Signature=" + signature
        guard let address = parts.url?.absoluteString else { throw CloudError.message("无法构造 Google 签名下载地址。") }
        return try DownloadShare(address: address, now: now)
    }
}
