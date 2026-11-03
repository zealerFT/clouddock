import Foundation
import CryptoKit

public struct ObjectPage: Sendable {
    public var entries: [RemoteEntry]
    public var nextToken: String?
    public init(entries: [RemoteEntry], nextToken: String? = nil) { self.entries = entries; self.nextToken = nextToken }
}

public typealias ListingTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Only listing uses the providers' page APIs. Transfers continue to use rclone.
public final class ObjectListingClient: @unchecked Sendable {
    private let transport: ListingTransport
    private let now: @Sendable () -> Date
    private let googleTokens = GoogleListingToken()
    private static let session = URLSession(configuration: .ephemeral, delegate: ListingRedirectPolicy(), delegateQueue: nil)
    public init(transport: ListingTransport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CloudError.message("存储服务没有返回 HTTP 响应。") }
            return (data, response)
        }
        self.now = now
    }
    /// List Google Cloud Storage buckets through the JSON API. This keeps local
    /// fake-gcs-server connections independent of rclone's root listing, which
    /// expects a hosted GCS endpoint layout and otherwise treats /storage/b as
    /// a local filesystem path.
    public func bucketPage(connection c: Connection, credentials: Credentials, token: String?, limit: Int) async throws -> ObjectPage {
        guard c.provider == .google, (1...1000).contains(limit) else { throw CloudError.message("分页参数不正确。") }
        try Task.checkCancellation()
        let localEndpoint = !c.endpoint.isEmpty && c.requiresPathStyle
        var parts: URLComponents
        var accessToken: String?
        if localEndpoint {
            guard let local = URLComponents(string: c.endpoint), local.host != nil else {
                throw CloudError.message("Google 本地测试 Endpoint 无效。")
            }
            parts = local
        } else {
            accessToken = try await googleTokens.token(credentials: credentials, transport: transport, now: now())
            parts = URLComponents(string: c.endpoint.isEmpty ? "https://storage.googleapis.com" : c.endpoint)!
        }
        let basePath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiRoot = basePath.hasSuffix("storage/v1") ? "/" + basePath : (basePath.isEmpty ? "" : "/" + basePath) + "/storage/v1"
        parts.percentEncodedPath = apiRoot + "/b"
        var query = [("project", c.projectNumber.isEmpty ? "0" : c.projectNumber),
                     ("maxResults", String(limit)),
                     ("fields", "items(name),nextPageToken")]
        if let token { query.append(("pageToken", token)) }
        parts.percentEncodedQuery = Self.query(query)
        guard let url = parts.url else { throw CloudError.message("无法构造 Google 存储桶请求。") }
        var request = URLRequest(url: url)
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let message = String(decoding: data.prefix(2048), as: UTF8.self)
            throw CloudError.message("读取存储桶失败（HTTP \(response.statusCode)）：\(credentials.redact(message))")
        }
        struct Item: Decodable { var name: String }
        struct Response: Decodable { var items: [Item]?; var nextPageToken: String? }
        let value = try JSONDecoder().decode(Response.self, from: data)
        let entries = (value.items ?? []).map { RemoteEntry(path: $0.name, isDirectory: true) }
        return ObjectPage(entries: Self.unique(entries), nextToken: value.nextPageToken?.isEmpty == false ? value.nextPageToken : nil)
    }
    public func page(connection c: Connection, credentials: Credentials, bucket: String, prefix: String,
                     recursive: Bool, token: String?, limit: Int) async throws -> ObjectPage {
        guard !bucket.isEmpty, (1...1000).contains(limit) else { throw CloudError.message("分页参数不正确。") }
        try Task.checkCancellation()
        var request: URLRequest
        if c.provider == .google {
            // A local GCS emulator has no Google OAuth endpoint. Existing real
            // connections keep the normal service-account flow; localhost/IP
            // endpoints are deliberately limited to the disposable test fixture.
            let localEndpoint = !c.endpoint.isEmpty && c.requiresPathStyle
            var parts: URLComponents
            var accessToken: String?
            if localEndpoint {
                guard let local = URLComponents(string: c.endpoint), local.host != nil else {
                    throw CloudError.message("Google 本地测试 Endpoint 无效。")
                }
                parts = local
            } else {
                accessToken = try await googleTokens.token(credentials: credentials, transport: transport, now: now())
                parts = URLComponents(string: c.endpoint.isEmpty ? "https://storage.googleapis.com" : c.endpoint)!
            }
            let basePath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let apiRoot = basePath.hasSuffix("storage/v1") ? "/" + basePath : (basePath.isEmpty ? "" : "/" + basePath) + "/storage/v1"
            parts.percentEncodedPath = apiRoot + "/b/" + Self.encode(bucket) + "/o"
            var query = [("prefix", prefix), ("maxResults", String(limit)), ("fields", "items(name,size,updated,contentType),prefixes,nextPageToken")]
            if !recursive { query.append(("delimiter", "/")) }
            if let token { query.append(("pageToken", token)) }
            parts.percentEncodedQuery = Self.query(query)
            request = URLRequest(url: parts.url!)
            if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        } else {
            let region = c.region.isEmpty ? "us-east-1" : c.region
            let domain = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
            let endpoint = c.endpoint.isEmpty ? "https://s3.\(region).\(domain)" : c.endpoint
            guard var parts = URLComponents(string: endpoint), parts.host != nil else { throw CloudError.message("Endpoint 无效。") }
            if c.usesPathStyle { parts.percentEncodedPath = "/" + Self.encode(bucket) + "/" }
            else { parts.host = bucket + "." + parts.host!; parts.percentEncodedPath = "/" }
            var query = [("prefix", prefix), ("max-keys", String(limit))]
            // LocalStack 3.x compares encoded names against raw continuation keys,
            // which drops Unicode objects on later pages. UTF-8 XML keeps both in
            // the same representation; continuation tokens still pass through verbatim.
            if !(c.provider == .aws && c.requiresPathStyle) { query.append(("encoding-type", "url")) }
            if !recursive { query.append(("delimiter", "/")) }
            if c.provider == .aliyun {
                if let token { query.append(("marker", token)) }
            } else {
                query.append(("list-type", "2"))
                if let token { query.append(("continuation-token", token)) }
            }
            parts.percentEncodedQuery = Self.query(query)
            guard let url = parts.url else { throw CloudError.message("无法构造分页请求。") }
            request = URLRequest(url: url)
            if c.provider == .aliyun { Self.signOSS(&request, bucket: bucket, credentials: credentials, date: now()) }
            else { Self.signS3(&request, region: region, credentials: credentials, date: now()) }
        }
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let message = String(decoding: data.prefix(2048), as: UTF8.self)
            throw CloudError.message("读取目录失败（HTTP \(response.statusCode)）：\(credentials.redact(message))")
        }
        if c.provider == .google { return try Self.googlePage(data) }
        let parser = ObjectListXML()
        let xml = XMLParser(data: data); xml.delegate = parser; xml.shouldResolveExternalEntities = false
        guard xml.parse() else { throw CloudError.message("存储服务返回的文件列表无法解析。") }
        if parser.rootName == "ListAllMyBucketsResult" {
            throw CloudError.message("服务端返回了存储桶列表，而非当前桶的文件列表。请在连接设置中开启 Path-style，或检查 Endpoint 的存储桶域名配置。")
        }
        guard parser.validRoot else { throw CloudError.message("存储服务返回的文件列表无法解析，请检查 Endpoint 是否为 S3 API 地址。") }
        let decode: (String) -> String = { value in
            guard parser.encoded else { return value }
            // MinIO encodes keys/prefixes with QueryEscape (+ for space, %2B for +).
            // Replace bare + before percent decoding, exactly once; tokens stay opaque.
            let encoded = c.provider == .minio ? value.replacingOccurrences(of: "+", with: " ") : value
            return encoded.removingPercentEncoding ?? value
        }
        let entries = parser.objects.map { item -> RemoteEntry in
            let key = decode(item.key), directory = key.hasSuffix("/")
            return RemoteEntry(path: directory ? String(key.dropLast()) : key, size: directory ? -1 : item.size,
                               modified: item.modified, isDirectory: directory)
        } + parser.prefixes.map { RemoteEntry(path: String(decode($0).dropLast()), isDirectory: true) }
        let next = parser.truncated ? (c.provider == .aliyun ? decode(parser.nextMarker) : parser.nextToken) : nil
        if parser.truncated, next?.isEmpty != false { throw CloudError.message("服务端声明还有文件，但没有返回下一页游标。请刷新后重试。") }
        return ObjectPage(entries: Self.unique(entries), nextToken: next)
    }
    private static func googlePage(_ data: Data) throws -> ObjectPage {
        struct Item: Decodable { var name: String; var size: String?; var updated: String?; var contentType: String? }
        struct Response: Decodable { var items: [Item]?; var prefixes: [String]?; var nextPageToken: String? }
        let value = try JSONDecoder().decode(Response.self, from: data)
        let entries = (value.items ?? []).map { item -> RemoteEntry in
            let directory = item.name.hasSuffix("/")
            return RemoteEntry(path: directory ? String(item.name.dropLast()) : item.name,
                               size: directory ? -1 : Int64(item.size ?? "") ?? 0, modified: item.updated ?? "", isDirectory: directory, mimeType: item.contentType)
        } + (value.prefixes ?? []).map { RemoteEntry(path: String($0.dropLast()), isDirectory: true) }
        return ObjectPage(entries: unique(entries), nextToken: value.nextPageToken?.isEmpty == false ? value.nextPageToken : nil)
    }
    private static func unique(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }
    static func query(_ pairs: [(String, String)]) -> String {
        let encoded = pairs.map { (encode($0.0), encode($0.1)) }
        let ordered = encoded.sorted { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        return ordered.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }
    private static func signS3(_ request: inout URLRequest, region: String, credentials c: Credentials, date: Date) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let host = parts.host! + (parts.port.map { ":\($0)" } ?? "")
        let payload = hex(SHA256.hash(data: Data()))
        var headers = [("host", host), ("x-amz-content-sha256", payload), ("x-amz-date", timestamp)]
        if !c.sessionToken.isEmpty { headers.append(("x-amz-security-token", c.sessionToken)) }
        headers.sort { $0.0 < $1.0 }
        let signed = headers.map(\.0).joined(separator: ";")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let canonical = "GET\n\(parts.percentEncodedPath)\n\(parts.percentEncodedQuery ?? "")\n"
            + headers.map { pair in pair.0 + ":" + pair.1 + "\n" }.joined() + "\n\(signed)\n\(payload)"
        let scope = "\(day)/\(region)/s3/aws4_request"
        let string = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(SHA256.hash(data: Data(canonical.utf8))))"
        func hmac(_ key: Data, _ value: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key))) }
        let key = hmac(hmac(hmac(hmac(Data(("AWS4" + c.secretKey).utf8), day), region), "s3"), "aws4_request")
        let signature = hex(hmac(key, string))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(c.accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(signature)", forHTTPHeaderField: "Authorization")
    }
    private static func signOSS(_ request: inout URLRequest, bucket: String, credentials c: Credentials, date: Date) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let timestamp = formatter.string(from: date)
        request.setValue(timestamp, forHTTPHeaderField: "Date")
        var headers = ""
        if !c.sessionToken.isEmpty {
            request.setValue(c.sessionToken, forHTTPHeaderField: "x-oss-security-token")
            headers = "x-oss-security-token:\(c.sessionToken)\n"
        }
        // OSS V1 ListObjects does not sign prefix, marker, delimiter, max-keys or encoding-type.
        // These are not subresources (verified against oss2 2.19.1 ProviderAuth).
        let value = "GET\n\n\n\(timestamp)\n\(headers)/\(bucket)/"
        let signature = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: Data(c.secretKey.utf8)))).base64EncodedString()
        request.setValue("OSS \(c.accessKey):\(signature)", forHTTPHeaderField: "Authorization")
    }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}

private final class ListingRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class ObjectListXML: NSObject, XMLParserDelegate {
    struct Item { var key = ""; var size: Int64 = 0; var modified = "" }
    var objects: [Item] = [], prefixes: [String] = []
    var truncated = false, encoded = false, validRoot = false
    var rootName = ""
    var nextToken = "", nextMarker = ""
    private var stack: [String] = [], text = "", item = Item()
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        stack.append(elementName); text = ""
        if stack.count == 1 { rootName = elementName; validRoot = elementName == "ListBucketResult" }
        if elementName == "Contents" { item = Item() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let parent = stack.dropLast().last
        if parent == "Contents" {
            switch elementName { case "Key": item.key = text; case "Size": item.size = Int64(text) ?? 0; case "LastModified": item.modified = text; default: break }
        }
        if elementName == "Contents" { objects.append(item) }
        if elementName == "Prefix", parent == "CommonPrefixes" { prefixes.append(text) }
        if parent == "ListBucketResult" {
            switch elementName {
            case "IsTruncated": truncated = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            case "EncodingType": encoded = text == "url"
            case "NextContinuationToken": nextToken = text
            case "NextMarker": nextMarker = text
            default: break
            }
        }
        _ = stack.popLast(); text = ""
    }
}
