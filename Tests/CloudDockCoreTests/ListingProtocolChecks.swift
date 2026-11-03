import Foundation
import Security
import CloudDockCore

private actor ListingResponseFixture {
    var requests: [URLRequest] = []
    let data: Data
    init(_ body: String) { data = Data(body.utf8) }
    func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor GoogleResponseFixture {
    let key: SecKey
    var authentications = 0, listings = 0
    init(key: SecKey) { self.key = key }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.url!.host == "oauth2.googleapis.com" {
            authentications += 1
            let form = URLComponents(string: "https://fixture.invalid/?" + String(decoding: request.httpBody!, as: UTF8.self))!
            let assertion = try required(form.queryItems?.first { $0.name == "assertion" }?.value)
            let parts = assertion.split(separator: ".").map(String.init)
            func decode(_ value: String) -> Data {
                let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                return Data(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4))!
            }
            expectEqual(parts.count, 3)
            expectTrue(SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, decode(parts[2]) as CFData, nil))
            let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
            expectEqual(claims["aud"] as? String, "https://oauth2.googleapis.com/token")
            expectEqual(claims["scope"] as? String, "https://www.googleapis.com/auth/devstorage.read_only")
            body = "{\"access_token\":\"fixture-token\",\"expires_in\":3600}"
        } else {
            listings += 1
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expectEqual(query.first { $0.name == "maxResults" }?.value, "2")
            expectEqual(query.first { $0.name == "prefix" }?.value, "docs/")
            if listings == 2 { expectEqual(query.first { $0.name == "pageToken" }?.value, "g+/=&") }
            body = "{\"items\":[{\"name\":\"docs/hello.txt\",\"size\":\"12\",\"updated\":\"2026-10-29T00:00:00Z\"}],\"prefixes\":[\"docs/sub/\"],\"nextPageToken\":\"g+/=&\"}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class ListingProtocolChecks {
    func testMinIOEncodedNamesKeepDistinctObjectKeys() async throws {
        // MinIO 2025.5.24 uses QueryEscape: spaces become +, literal plus becomes %2B.
        let body = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>
          <Contents><Key>test/%E6%88%AA%E5%B1%8F2026-10-30+15.28.41.png</Key><Size>1</Size></Contents>
          <Contents><Key>test/%E6%88%AA%E5%B1%8F2026-10-30%2B15.28.41.png</Key><Size>2</Size></Contents>
          <Contents><Key>test/%252B+%E7%A9%BA+%E6%A0%BC%2B%26.txt</Key><Size>3</Size></Contents>
          <CommonPrefixes><Prefix>test/%E6%96%87%E4%BB%B6+%E5%A4%B9%2B%E5%8F%B7/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let fixture = ListingResponseFixture(body)
        let client = ObjectListingClient(transport: { await fixture.send($0) })
        let engine = StorageEngine(objectListing: client)
        let c = Connection(name: "MinIO fixture", provider: .minio, endpoint: "https://fixture.invalid")
        let secret = Credentials(accessKey: "fixture", secretKey: "fixture-secret")
        let page = try await engine.directoryPage(connection: c, credentials: secret, bucket: "fixture", prefix: "test")
        expectEqual(Set(page.entries.map(\.path)), Set(["截屏2026-10-30 15.28.41.png", "截屏2026-10-30+15.28.41.png", "%2B 空 格+&.txt", "文件 夹+号"]))
        expectEqual(page.entries.first { $0.size == 1 }?.path, "截屏2026-10-30 15.28.41.png")
        expectEqual(page.entries.first { $0.size == 2 }?.path, "截屏2026-10-30+15.28.41.png")
        expectTrue(page.entries.contains { $0.path == "文件 夹+号" && $0.isDirectory })

        // A response without EncodingType is already literal; preserve + and %2B.
        let literal = ListingResponseFixture("<ListBucketResult><Contents><Key>test/空 格+%2B.txt</Key><Size>4</Size></Contents></ListBucketResult>")
        let literalClient = ObjectListingClient(transport: { await literal.send($0) })
        let literalPage = try await literalClient.page(connection: c, credentials: secret, bucket: "fixture", prefix: "test/", recursive: false, token: nil, limit: 100)
        expectEqual(literalPage.entries.first?.path, "test/空 格+%2B.txt")

        // AWS/OSS percent encoding must retain its existing literal-plus semantics.
        let percent = ListingResponseFixture("<ListBucketResult><EncodingType>url</EncodingType><Contents><Key>test/a+b%20c%252B.txt</Key></Contents></ListBucketResult>")
        let percentClient = ObjectListingClient(transport: { await percent.send($0) })
        for provider in [Provider.aws, .aliyun] {
            var other = c; other.provider = provider
            let page = try await percentClient.page(connection: other, credentials: secret, bucket: "fixture", prefix: "test/", recursive: false, token: nil, limit: 100)
            expectEqual(page.entries.first?.path, "test/a+b c%2B.txt")
        }
    }

    func testLocalEndpointsUseConsistentBucketPaths() async throws {
        let fixture = ListingResponseFixture("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
        let client = ObjectListingClient(transport: { await fixture.send($0) })
        let engine = StorageEngine(objectListing: client)
        let secret = Credentials(accessKey: "test", secretKey: "test")
        for endpoint in ["http://localhost:4566", "http://127.0.0.1:4566", "http://[::1]:4566", "http://192.168.1.10:9000", "http://[fd00::1]:9000"] {
            let c = Connection(name: "local fixture", provider: .aws, endpoint: endpoint, region: "us-east-1", pathStyle: false)
            _ = try await client.page(connection: c, credentials: secret, bucket: "demo-bucket", prefix: "", recursive: false, token: nil, limit: 100)
            let request = try required(await fixture.requests.last)
            expectEqual(request.url?.host, URL(string: endpoint)?.host)
            expectEqual(request.url?.path, "/demo-bucket")
            expectNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "encoding-type" })
            expectEqual(engine.environment(connection: c, credentials: secret)["RCLONE_CONFIG_CLOUD_FORCE_PATH_STYLE"], "true")
            expectEqual(engine.environment(connection: c, credentials: secret)["RCLONE_CONFIG_CLOUD_PROVIDER"], "Other")
            expectFalse(c.pathStyle, "Effective addressing must not overwrite saved settings")
        }
        let aws = Connection(name: "AWS", provider: .aws, endpoint: "https://s3.us-east-1.amazonaws.com", pathStyle: false)
        _ = try await client.page(connection: aws, credentials: secret, bucket: "demo-bucket", prefix: "", recursive: false, token: nil, limit: 100)
        expectEqual(await fixture.requests.last?.url?.host, "demo-bucket.s3.us-east-1.amazonaws.com")
        let awsRequest = try required(await fixture.requests.last)
        expectEqual(URLComponents(url: awsRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "encoding-type" }?.value, "url")
        expectEqual(engine.environment(connection: aws, credentials: secret)["RCLONE_CONFIG_CLOUD_FORCE_PATH_STYLE"], "false")
        expectEqual(engine.environment(connection: aws, credentials: secret)["RCLONE_CONFIG_CLOUD_PROVIDER"], "AWS")
        let buckets = ListingResponseFixture("<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>")
        let wrongRoute = ObjectListingClient(transport: { await buckets.send($0) })
        do {
            _ = try await wrongRoute.page(connection: aws, credentials: secret, bucket: "demo-bucket", prefix: "", recursive: false, token: nil, limit: 100)
            fail("A bucket-list response must not be accepted as an object list")
        } catch { expectTrue(error.localizedDescription.contains("Path-style")) }
    }

    func testS3OSSSignaturesAndOpaqueTokens() async throws {
        let xml = "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>next%+/=&amp;</NextContinuationToken><NextMarker>%E8%B5%84%E6%96%99%2Fmarker%2B</NextMarker><Contents><Key>%E8%B5%84%E6%96%99%2Ffile%2B%26.txt</Key><Size>12</Size></Contents><CommonPrefixes><Prefix>%E8%B5%84%E6%96%99%2Ffolder%2F</Prefix></CommonPrefixes></ListBucketResult>"
        let fixture = ListingResponseFixture(xml)
        let client = ObjectListingClient(transport: { await fixture.send($0) }, now: { Date(timeIntervalSince1970: 1_369_353_600) })
        let credentials = Credentials(accessKey: "AKIDEXAMPLE", secretKey: "fixture-secret", sessionToken: "fixture-token")
        var connection = Connection(name: "signature fixture", provider: .aws, endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", pathStyle: false)
        let s3 = try await client.page(connection: connection, credentials: credentials, bucket: "examplebucket", prefix: "资料/", recursive: false, token: "a+/=&", limit: 2)
        expectEqual(s3.nextToken, "next%+/=&")
        expectEqual(Set(s3.entries.map(\.path)), Set(["资料/file+&.txt", "资料/folder"]))
        let request = try required(await fixture.requests.first)
        // Expected value independently generated with botocore S3SigV4Auth and a fixed UTC date.
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=5a6cf40a8d06082b0b881afc42024dfc0866a6d472f487d83f76d43461f9c604")
        expectEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "continuation-token" }?.value, "a+/=&")
        connection.provider = .aliyun; connection.endpoint = "https://oss-cn-hangzhou.aliyuncs.com"
        let oss = try await client.page(connection: connection, credentials: credentials, bucket: "examplebucket", prefix: "资料/", recursive: false, token: "资料/marker+", limit: 2)
        expectEqual(oss.nextToken, "资料/marker+")
        let ossRequest = try required(await fixture.requests.last)
        // oss2 2.19.1 ProviderAuth excludes ListObjects filters/marker from the V1 canonical resource.
        expectEqual(ossRequest.value(forHTTPHeaderField: "Authorization"), "OSS AKIDEXAMPLE:0ohATxzEgmYtGGTmhXmqxa1jUL4=")
        expectEqual(URLComponents(url: ossRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "marker" }?.value, "资料/marker+")
        _ = try await client.page(connection: connection, credentials: credentials, bucket: "examplebucket", prefix: "other/", recursive: true, token: nil, limit: 100)
        let otherOSSRequest = try required(await fixture.requests.last)
        expectEqual(otherOSSRequest.value(forHTTPHeaderField: "Authorization"), ossRequest.value(forHTTPHeaderField: "Authorization"))
    }

    func testGoogleJWTAndPagedObjects() async throws {
        let privateKey = try required(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try required(SecKeyCopyPublicKey(privateKey))
        let rsa = try required(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)
        func der(_ tag: UInt8, _ data: Data) -> Data {
            let count = data.count
            let length = count < 128 ? Data([UInt8(count)]) : Data([0x82, UInt8(count >> 8), UInt8(count & 255)])
            return Data([tag]) + length + data
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let pkcs8 = der(0x30, Data([0x02, 0x01, 0x00]) + algorithm + der(0x04, rsa))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString() + "\n-----END PRIVATE KEY-----"
        let account = try JSONSerialization.data(withJSONObject: ["type": "service_account", "client_email": "fixture@example.invalid", "private_key": pem])
        let credentials = Credentials(serviceAccountJSON: String(decoding: account, as: UTF8.self))
        let fixture = GoogleResponseFixture(key: publicKey)
        let client = ObjectListingClient(transport: { try await fixture.send($0) })
        let connection = Connection(name: "Google fixture", provider: .google)
        let page = try await client.page(connection: connection, credentials: credentials, bucket: "fixture", prefix: "docs/", recursive: false, token: nil, limit: 2)
        expectEqual(page.entries.count, 2); expectEqual(page.nextToken, "g+/=&")
        expectTrue(page.entries.contains { $0.path == "docs/sub" && $0.isDirectory })
        _ = try await client.page(connection: connection, credentials: credentials, bucket: "fixture", prefix: "docs/", recursive: false, token: page.nextToken, limit: 2)
        expectEqual(await fixture.authentications, 1); expectEqual(await fixture.listings, 2)
    }
}
