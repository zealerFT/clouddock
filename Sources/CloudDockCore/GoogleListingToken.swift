import Foundation
import CryptoKit

actor GoogleListingToken {
    private var cache: [String: (String, Date)] = [:]
    func token(credentials: Credentials, transport: ListingTransport, now: Date) async throws -> String {
        let identity = SHA256.hash(data: Data(credentials.serviceAccountJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        if let (token, expiry) = cache[identity], expiry > now.addingTimeInterval(60) { return token }
        let account = try GoogleServiceAccount(credentials: credentials)
        let endpoint = "https://oauth2.googleapis.com/token"
        func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let header = base64(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: .sortedKeys))
        let claim: [String: Any] = ["iss": account.email, "scope": "https://www.googleapis.com/auth/devstorage.read_only", "aud": endpoint,
                                    "iat": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 3600]
        let signing = header + "." + base64(try JSONSerialization.data(withJSONObject: claim, options: .sortedKeys))
        let signature = try account.sign(Data(signing.utf8))
        var request = URLRequest(url: URL(string: endpoint)!); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(ObjectListingClient.query([("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"), ("assertion", signing + "." + base64(signature))]).utf8)
        let (response, status) = try await transport(request)
        guard status.statusCode == 200, let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let token = value["access_token"] as? String, !token.isEmpty else { throw CloudError.message("Google 服务账号授权失败（HTTP \(status.statusCode)），请检查密钥及设备时间。") }
        let expiry = now.addingTimeInterval((value["expires_in"] as? Double) ?? 3600)
        cache[identity] = (token, expiry)
        return token
    }
}
